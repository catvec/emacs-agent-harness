;;; harness-replay.el --- What a session's model was sent, kept as it was  -*- lexical-binding: t; -*-

;;; Commentary:

;; A provider is sent a session's whole conversation with every request,
;; and keeps the start of the request it read last in its prompt cache.
;; Two things the harness sends can change without the transcript
;; changing, and each one makes every token after the change a fresh
;; read:
;;
;; - a response that called a tool goes back as the model delivered it,
;;   reasoning items included, and the provider that remembers those
;;   (`harness-provider-responses.el') remembered them in memory only.
;;   After a restart the message was built again from its blocks,
;;   without the reasoning and without the response's own ids: the
;;   model lost what it was thinking, and the prompt cache lost
;;   everything from that message on.  So each response is kept on disk,
;;   under the call ids it made, and read back into the provider's
;;   table the first time a session's transcript is rendered;
;; - the messages of a request are rendered from the transcript with
;;   every step.  A change of the code that renders them changes a
;;   prefix the provider had cached, though the conversation did not
;;   change at all.  So the messages of the last request are kept on
;;   disk as they were, and the next request sends them again plus the
;;   messages the nodes added since make (`replay/prefix').
;;
;; What is kept is the request's system prompt, tools and messages --
;; the payload the harness gives a provider -- and not the provider's
;; own body: what a provider makes of them is its own, and a change
;; there is a change of what the model is told, not of how the same
;; conversation is rendered.  A kept payload applies while the
;; session's transcript still starts with the nodes it was rendered
;; from and those nodes still render the same, which a digest of what
;; rendering reads of them says (`session/render-digest'): the nodes may
;; change in what a request never shows, such as the usage of a step,
;; without ending it.
;;
;; What is kept is not a second transcript.  It is dropped when a
;; compaction replaces the conversation, which is what the compaction
;; was for, and when the session is deleted.  A redaction cleans the
;; responses in place, since a message that lost its reasoning items
;; would change, and drops the last request, which costs nothing: the
;; next one is rendered from the redacted transcript, which the
;; redaction changed anyway.
;;
;; Not every request that names a session is a step of its conversation,
;; and what is frozen is the conversation's.  A one-off call
;; (`:ephemeral') neither splices nor is kept.  A request that only reads
;; the prefix and appends material the conversation does not hold -- a
;; compaction summary made from the prompt cache (`:replay-read-only') --
;; splices, because re-sending the bytes the provider read is what reads
;; the cache, and is never kept, because the conversation's next step
;; would diverge at what it appended.  Neither is a licence to change the
;; prefix: a body whose bytes changed under it is still refused.
;;
;; The files are the session's, in the state directory:
;; sessions/ID.responses.jsonl, one response a line, and
;; sessions/ID.request.jsonl, one JSON document.  The document is read
;; losslessly (`harness-replay--read'): the harness's own reading of
;; JSON maps an empty object and an empty array to nil both, and a
;; request written again with null where it had {} or [] is not the
;; request the provider cached.
;;
;; The neutral payload above is what the harness *means* to send.  What
;; a provider's prompt cache sees is the adapter's own body, which the
;; adapter builds afresh with every request (`harness-openai--body',
;; `harness-responses--body'): a change of that code -- a reordered
;; field, a new setting, a different image representation -- changes the
;; wire prefix while the neutral payload is identical, and nothing said
;; so.  So the components of the *final* body are kept as well, exactly
;; as they were encoded (`replay/frozen-splice'): the next request is
;; assembled from those bytes for every component already sent, and only
;; the components the new nodes add are encoded fresh.  The assembled
;; body is compared component by component with what was kept before it
;; is handed to the transport; a difference no recorded reset explains
;; is refused there, naming the first divergent component, and nothing is
;; sent.  The resets are explicit and recorded, each with its reason and
;; a new generation: a compaction, a change of model, route, system
;; prompt or tools, an adapter serialization version, a redaction,
;; images dropped from the history, a payload too large to keep, and a
;; store that could not be written.
;;
;; Identical components do not promise a provider cache hit: eviction,
;; retention and routing are the provider's, and the diagnostics module
;; (`harness-provider-diagnostics.el') is what records them.  This
;; module guarantees only what the harness sends.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'harness-core)
(require 'harness-util)
(require 'harness-redaction)

(defvar harness-state-directory)

(defcustom harness-replay-responses-limit 1000
  "Most responses kept for a session on disk.
A session's transcript is replayed from these: every assistant message
with a call goes back as the response delivered it, reasoning included.
Dropping one changes how a message the next request carries is
rendered, and from that message on the prompt cache cannot match, so
the newest are kept and the limit is high enough for a long turn.
`harness-provider-responses.el' keeps the table it reads in memory and
prunes that one too, at the same limit."
  :type 'integer :group 'harness)

(defcustom harness-replay-request-max-bytes (* 16 1024 1024)
  "Largest request payload kept for a session, in bytes.
Beyond it the conversation is rendered again with every request, as it
was before payloads were kept: a payload is written with every step,
and one of tens of megabytes would cost more to write than the cache
miss it saves.  A request of pictures is never kept, whatever its size."
  :type 'integer :group 'harness)

(defconst harness-replay--request-tag "request"
  "What the last request's document of a session is kept as.")

;;;; The session's files

(defun harness-replay--responses-name (id)
  "Return the store name of the responses kept for session ID."
  (format "sessions/%s.responses.jsonl" id))

(defun harness-replay--request-name (id)
  "Return the store name of the last request kept for session ID."
  (format "sessions/%s.request.jsonl" id))

(defun harness-replay--file (name)
  "Return the absolute name of the stored object NAME."
  (expand-file-name name harness-state-directory))

(defun harness-replay--write-lines (name records)
  "Write RECORDS to the stored object NAME, one JSON line each, atomically."
  (harness-write-file-atomically
   (harness-replay--file name)
   (mapconcat (lambda (record) (concat (harness-json-encode record) "\n")) records "")))

;;;; The responses, by the calls they made

(defun harness-replay--call-ids (items)
  "Return the call ids of the function calls among ITEMS, or nil.
ITEMS are a response's output items, as the model delivered them."
  (let ((ids (delq nil (mapcar (lambda (item)
                                 (and (equal (plist-get item :type) "function_call")
                                      (plist-get item :call_id)))
                               items))))
    (and ids (cons (car ids) ids))))

(harness-defmethod replay/responses (id)
  "Return the responses kept on disk for session ID, oldest first.
Each is a plist (:ids (CALL-ID...) :items (ITEM...)): the call ids the
response made, its first one first, and the output items it answered
with, as the model delivered them.  Only the newest
`harness-replay-responses-limit' are returned, and the file is cut back
to those when it holds more."
  (let* ((name (harness-replay--responses-name id))
         (records (harness-call 'store/read-all name))
         (limit harness-replay-responses-limit))
    (if (and (integerp limit) (>= limit 0) (> (length records) limit))
        (let ((kept (last records limit)))
          (harness-replay--write-lines name kept)
          kept)
      records)))

(harness-defmethod replay/responses-p (id)
  "Non-nil when the disk holds responses kept for session ID."
  (let ((path (harness-replay--file (harness-replay--responses-name id))))
    (and (file-regular-p path) (> (file-attribute-size (file-attributes path)) 0))))

(harness-defmethod replay/remember-response (id items)
  "Keep ITEMS, a response of session ID, on disk under the calls it made.
Nothing is kept for a response that called no tool: nothing else is
ever replayed.  Return non-nil when it was written."
  (when-let* ((ids (harness-replay--call-ids items)))
    (harness-call 'store/append (harness-replay--responses-name id)
                  (list :ids ids :items (harness-json-array items) :at (float-time)))
    t))

(harness-defmethod replay/keep-responses (id call-ids)
  "Keep only the responses of session ID whose every call is in CALL-IDS.
The provider's table prunes the responses it keeps in memory when there
are too many; the disk is cut back to the same ones here, so that a
restart reads back no response the running harness had dropped."
  (let* ((name (harness-replay--responses-name id))
         (records (harness-call 'store/read-all name))
         (kept (cl-remove-if-not (lambda (record)
                                   (cl-every (lambda (call-id) (member call-id call-ids))
                                             (plist-get record :ids)))
                                 records)))
    (when (< (length kept) (length records))
      (harness-replay--write-lines name kept))))

;;;; The frozen body, field by field
;;
;; A request's final body is a JSON object, and each of its fields is one
;; component: the model, the cache-affecting settings, the system
;; material, the tool schema and every message (or Responses input item).
;; Each component is kept as the exact bytes of its value, encoded once by
;; the adapter's own encoder, and the body the transport sends is those
;; bytes under their field names, in the order the adapter built them:
;;
;;   {"model":"...","messages":[...],"stream":true,...}
;;
;; So a field an earlier request of the same session already sent goes out
;; again as the very bytes the provider read -- not a re-encoding of equal
;; data, which would depend on the order a JSON object's keys came back
;; in.  Only the fields the request adds, and the new material at the end
;; of the message list, are encoded fresh.
;;
;; A body is frozen for a session only while it is the same conversation
;; and the same route: the components it kept are a prefix of the next
;; request's, the model and the route are the ones it was built for, and
;; its serialization version is the adapter's.  Anything else is a reset,
;; recorded with its reason, never a silent rebuild.
;;
;; Identical components do not promise a provider cache hit: eviction,
;; retention and routing are the provider's, and the diagnostics module
;; (`harness-provider-diagnostics.el') is what records them.  This module
;; guarantees only what the harness sends.

(defconst harness-replay-frozen-version 1
  "Version of the frozen-body layout and of the adapter seam.
An adapter that splices and checks a body names the version of the
serialization it produces.  A new version is a recorded reset: a body
kept by another one is neither compared with nor sent again.")

(defcustom harness-replay-frozen-max-bytes (* 32 1024 1024)
  "Largest frozen body kept for a session, in bytes.
Beyond it nothing is kept and every request is built fresh, as it was
before bodies were frozen, and a `too-large' reset says so: a body of tens
of megabytes costs more to write with every step than the cache miss it
saves.  A picture's bytes count: they are part of what was sent."
  :type 'integer :group 'harness)

(defcustom harness-replay-prompt-fields
  '("model" "system" "instructions" "messages" "input" "tools"
    "tool_choice" "functions" "function_call" "response_format"
    "reasoning" "reasoning_effort")
  "Fields of a request body that are the prompt the model is given.
Their bytes are what a provider's prompt cache reads, so they are the
fields that are frozen and continued.  Every other field of a body --
`stream', `stream_options', `include', `store', a token budget, a
temperature, a response format's own envelope -- is per-request
metadata: it is encoded fresh on every request, never compared with what
an earlier request sent, and never a reason to refuse one.

A cache is keyed on the prompt, not on how a request was transported.
Freezing the whole body would make a change of `max_tokens' look like a
change of the prompt, which is neither what a cache sees nor what the
harness should stop a turn for."
  :type '(repeat string) :group 'harness)

(defun harness-replay-prompt-field-p (name)
  "Non-nil when NAME, a body field, is part of the prompt."
  (member (format "%s" name) harness-replay-prompt-fields))

(defconst harness-replay-frozen-reset-reasons
  '(compaction system tools model route redaction images-pruned field-dropped
    diverged tool-definition adapter-version storage-failure too-large no-session)
  "Why a frozen body stops applying, as the reason a reset records.
Each is a change of what the model is sent, or of a store that could not
hold it, never an unexplained one: `compaction' a conversation replaced,
`system' the prompt, `tools' the schema, `model' the model or its
settings, `route' the endpoint or the account, `redaction' a secret taken
out, `images-pruned' pictures dropped from the history by
`harness-agent-history-images', `field-dropped' a prompt field the body
kept that this request no longer sends at all, `diverged' a prompt
component the rebuilt body no longer continues -- a value inside a field
that changed, such as the reasoning effort a model's listing named only
after the first request went out -- `tool-definition' a tool the body
kept whose definition the harness changed while the names the session
settled stayed the same, `adapter-version' another
serialization, `storage-failure' a body that could not be written,
`too-large' one over `harness-replay-frozen-max-bytes', and `no-session' a
request that names no session.

A reset says the next request is built fresh.  A prompt field that is
gone, the reasoning effort a model's listing named late, and a tool
definition the harness itself changed are all recorded by the splice
that finds them: the request goes out built fresh, since refusing it
forever would leave the session unable to make any request at all.
Every other divergence is refused by the boundary check and nothing is
sent, until something records why -- the two are never the same code
path.")

(defconst harness-replay--frozen-separator ","
  "What goes between two components of a body: the JSON comma.")

(defun harness-replay--frozen-name (id)
  "Return the store name of the frozen body kept for session ID."
  (format "sessions/%s.frozen.json" id))

(defun harness-replay--frozen-tag (value)
  "Return VALUE as the short tag a body is named by, or nil."
  (and value (format "%s" value)))


;;;; The pieces of a body
;;
;; A piece is what a body is made of: a value kept as the bytes it is sent
;; as, an array kept item by item, or an object kept field by field.  The
;; split follows `harness-json-encode' exactly: a list whose first element is
;; a keyword is an object, any other list and any vector an array, everything
;; else a value.  A piece is itself JSON -- a plist whose `:kind' is
;; "scalar", "array" or "object" -- so that a kept body is written and read
;; back exactly, an empty array and an empty object included.

(defun harness-replay--object-p (value)
  "Non-nil when VALUE is a plist, which `harness-json-encode' sends as an object."
  (and (consp value) (keywordp (car value)) (cl-evenp (length value))))

(defun harness-replay--piece (value)
  "Return VALUE as the piece of a body it is sent as.
An object is kept field by field, an array item by item, so that a body
that only grew keeps every byte it had; anything else is its own bytes."
  (cond
   ((eq value :empty) (list :kind "object" :fields (harness-json-array nil)))
   ((harness-replay--object-p value)
    (let (fields)
      (cl-loop for (key item) on value by #'cddr
               do (push (list :name (substring (symbol-name key) 1)
                              :piece (harness-replay--piece item))
                        fields))
      (list :kind "object" :fields (harness-json-array (nreverse fields)))))
   ((vectorp value)
    (list :kind "array"
          :items (harness-json-array (mapcar #'harness-replay--piece
                                             (append value nil)))))
   ((and (consp value) (proper-list-p value))
    (list :kind "array"
          :items (harness-json-array (mapcar #'harness-replay--piece value))))
   (t (list :kind "scalar" :bytes (harness-json-encode-text value)))))

(defconst harness-replay--piece-kinds '("scalar" "array" "object")
  "The kinds a piece can be.  A plist whose `:kind' is one of them is a
piece, never a body: a body's fields are the request's own names.")

(defun harness-replay--piece-p (value)
  "Non-nil when VALUE is a piece (`harness-replay--piece') rather than a body."
  (and (consp value)
       (member (plist-get value :kind) harness-replay--piece-kinds)
       t))

(defun harness-replay--as-piece (value)
  "Return VALUE as a piece: itself when it is one, else what it is sent as."
  (if (harness-replay--piece-p value) value (harness-replay--piece value)))

(defun harness-replay--piece-items (piece)
  "Return the items of PIECE, an array, as pieces."
  (let ((items (plist-get piece :items)))
    (cond ((vectorp items) (append items nil)) ((listp items) items) (t nil))))

(defun harness-replay--piece-fields (piece)
  "Return the fields of PIECE, an object, as ((:name NAME :piece PIECE)...)."
  (let ((fields (plist-get piece :fields)))
    (cond ((vectorp fields) (append fields nil)) ((listp fields) fields) (t nil))))

(defun harness-replay--field-name (field)
  "Return the name of FIELD, a field of an object piece."
  (format "%s" (plist-get field :name)))

(defun harness-replay--field-piece (field)
  "Return the piece of FIELD, a field of an object piece."
  (plist-get field :piece))

(defun harness-replay--piece-text (piece)
  "Return PIECE as JSON text; the HTTP transport encodes it as UTF-8.
The fragments are text because pieces are themselves stored inside JSON."
  (pcase (plist-get piece :kind)
    ("scalar" (or (plist-get piece :bytes) "null"))
    ("array" (concat "["
                     (mapconcat #'harness-replay--piece-text
                                (harness-replay--piece-items piece)
                                harness-replay--frozen-separator)
                     "]"))
    ("object" (concat "{"
                      (mapconcat (lambda (field)
                                   (concat (harness-json-encode-text
                                            (harness-replay--field-name field))
                                           ":"
                                           (harness-replay--piece-text
                                            (harness-replay--field-piece field))))
                                 (harness-replay--piece-fields piece)
                                 harness-replay--frozen-separator)
                      "}"))
    (_ "null")))

(defun harness-replay--dropped-prompt-fields (old new)
  "Return the names of the prompt fields OLD has that NEW does not.
OLD and NEW are the prompt objects of two bodies.  A field that is gone
is not the prompt's text changing: it is the request no longer sending a
component the provider already read -- the tool schema a session no
longer has, the reasoning effort of a thinking level that went nil -- and
`harness-replay--piece-diff' reports it as the bare path, which a refusal
prints as \"body\".  A caller can explain that with a recorded reset, as
it cannot explain a field whose bytes changed."
  (let ((news (harness-replay--piece-fields new)))
    (cl-loop for field in (harness-replay--piece-fields old)
             for name = (harness-replay--field-name field)
             unless (cl-find name news :key #'harness-replay--field-name
                             :test #'equal)
             collect name)))

(defun harness-replay--field-piece-named (name piece)
  "Return the piece of NAME's field in PIECE, an object, or nil."
  (let ((field (cl-find name (harness-replay--piece-fields piece)
                        :key #'harness-replay--field-name :test #'equal)))
    (and field (harness-replay--field-piece field))))

(defun harness-replay--scalar-text (piece)
  "Return PIECE, a scalar, as the value it was encoded from, or nil.
A scalar that cannot be read as JSON says nothing rather than signalling:
it is read to compare tool names, and a body this module cannot read is a
body it must not refuse a request for."
  (when (and (consp piece) (equal (plist-get piece :kind) "scalar")
             (plist-get piece :bytes))
    (condition-case nil
        (harness-json-parse (plist-get piece :bytes))
      (error nil))))

(defun harness-replay--tool-name (tool)
  "Return the name TOOL, a tool of a body, is called by, or nil.
The chat-completions route nests it under `function'; the Responses
route's `additional_tools' items carry it themselves."
  (or (harness-replay--scalar-text (harness-replay--field-piece-named "name" tool))
      (harness-replay--scalar-text
       (harness-replay--field-piece-named
        "name" (harness-replay--field-piece-named "function" tool)))))

(defun harness-replay--tool-names (prompt)
  "Return the names of the tools PROMPT, a body's prompt, carries.
They are read where each adapter keeps them -- the `tools' and `functions'
fields, and the `additional_tools' items of a Responses `input' -- so that
a body is read by its own shape and not by a name this module would have
to know.  The order is the body's."
  (let (names)
    (dolist (field (harness-replay--piece-fields prompt))
      (let ((name (harness-replay--field-name field))
            (piece (harness-replay--field-piece field)))
        (cond
         ((member name '("tools" "functions"))
          (dolist (tool (harness-replay--piece-items piece))
            (push (harness-replay--tool-name tool) names)))
         ((equal name "input")
          (dolist (item (harness-replay--piece-items piece))
            (when (equal (harness-replay--scalar-text
                          (harness-replay--field-piece-named "type" item))
                         "additional_tools")
              (dolist (tool (harness-replay--piece-items
                             (harness-replay--field-piece-named "tools" item)))
                (push (harness-replay--tool-name tool) names))))))))
    (delq nil (nreverse names))))

(defun harness-replay--changed-tool-field-p (path)
  "Non-nil when PATH is inside the tool schema of a body.
PATH is where `harness-replay--piece-diff' found a rebuilt body no longer
continuing the kept one, such as
\"tools[46].function.parameters.properties\".  The chat-completions route
keeps the tools in a field of the body; the Responses route brings them in
as an `additional_tools' item of `input', so the path reads
\"input[0].tools[0].description\" there.  Nothing else under `input' is a
tool: the conversation's items are the messages, and a change of one of
those is never a change of the schema."
  (when (stringp path)
    (let* ((segments (split-string path "\\." t))
           (root (and segments (car (split-string (car segments) "\\[" t))))
           (next (and (cdr segments)
                      (car (split-string (cadr segments) "\\[" t)))))
      (and (or (member root '("tools" "functions"))
               (and (equal root "input") (member next '("tools" "functions"))))
           t))))

(defun harness-replay--changed-tool-definition-p (old new path)
  "Non-nil when PATH's divergence is a tool definition the harness changed.
OLD and NEW are the prompt pieces of two bodies, and PATH is where
`harness-replay--piece-diff' found NEW no longer continuing OLD.  That is
a divergence inside the tool schema with no tool the kept body had
dropped: the definitions, and not the list.

A session settles the tool *names* it sends (`session/set-tool-schema'),
and their definitions are read from the registry with every request.  So
an upgrade that edits one -- a description, a property, a renamed
parameter -- rewrites the schema the provider already read, and no setting
announces it: the names did not change, so `session/set-tool-schema' was
never called.  Left to the refusal, that would stop every request the
session made afterwards, because a frozen body is only rewritten by a
request that is sent.

A tool the kept body had and the new one no longer sends is not this: the
list itself moved, which `session/set-tool-schema' announces with a
`tools' reset.  Nor is a tool added, which appends and diverges nowhere,
nor anything outside the tool schema."
  (and (harness-replay--changed-tool-field-p path)
       (let ((olds (harness-replay--tool-names old))
             (news (harness-replay--tool-names new)))
         (and (cl-subsetp olds news :test #'equal) t))))

(defun harness-replay--changed-effort-field-p (path)
  "Non-nil when PATH names the reasoning effort of a body.
PATH is where `harness-replay--piece-diff' found a rebuilt body no
longer continuing the kept one, such as \"reasoning.effort\" or
\"reasoning_effort\".  That is the one prompt component a change of
which no setting announces: it is not the session's thinking level but
the effort its adapter maps the level onto, and a model's listing that
arrives after the first request can map the same level to another
\(`harness-openai--effort').  The replay module records it as a reset
instead of leaving the session refused for good.

Everything else is left to the refusal: the conversation, the system
prompt and the tool schema each have a way of announcing a change of
theirs (`session/transition-system', `session/set-tool-schema',
`harness-replay-reset-changes'), and a rebuild that none of them
accounts for must not go out."
  (and (stringp path)
       (member (car (split-string path "\\." t))
               '("reasoning" "reasoning_effort"))
       t))

(defun harness-replay--prompt-only (piece)
  "Return PIECE, a body, with only the fields that are the prompt.
The result is what is compared and spliced: a metadata field is not part
of the prefix a cache reads, so it is neither kept nor checked."
  (if (not (equal (plist-get piece :kind) "object"))
      piece
    (list :kind "object"
          :fields (harness-json-array
                   (cl-remove-if-not
                    (lambda (field)
                      (harness-replay-prompt-field-p (harness-replay--field-name field)))
                    (harness-replay--piece-fields piece))))))

(defun harness-replay--metadata-fields (piece)
  "Return the fields of PIECE, a body, that are not part of the prompt."
  (if (not (equal (plist-get piece :kind) "object"))
      nil
    (cl-remove-if (lambda (field)
                    (harness-replay-prompt-field-p (harness-replay--field-name field)))
                  (harness-replay--piece-fields piece))))

(defun harness-replay--piece-diff (old new path)
  "Return where OLD, a kept piece, is not continued by NEW, or nil.
PATH is where OLD sits in the body, so a refusal names a field and an index
and never a prompt's text.  OLD is continued by NEW when every byte of it is
still sent, in the same place: a scalar must be the same bytes, an array may
only have grown -- the new material is appended, never inserted or replaced
-- and an object must have the very fields it had, in the same order, since
a field added or dropped changes the bytes of the object itself."
  (cond
   ((not (equal (plist-get old :kind) (plist-get new :kind))) path)
   ((equal (plist-get old :kind) "scalar")
    (unless (equal (plist-get old :bytes) (plist-get new :bytes)) path))
   ((equal (plist-get old :kind) "array")
    (let ((olds (harness-replay--piece-items old))
          (news (harness-replay--piece-items new))
          (i 0) found)
      (while (and (< i (length olds)) (not found))
        (setq found (if (>= i (length news))
                        (format "%s[%d]" path i)
                      (harness-replay--piece-diff
                       (nth i olds) (nth i news) (format "%s[%d]" path i))))
        (setq i (1+ i)))
      found))
   ((/= (length (harness-replay--piece-fields old))
        (length (harness-replay--piece-fields new)))
    (or path "body"))
   (t
    (let ((olds (harness-replay--piece-fields old))
          (news (harness-replay--piece-fields new))
          (i 0) found)
      (while (and (< i (length olds)) (not found))
        (let* ((field (nth i olds))
               (name (harness-replay--field-name field))
               (other (nth i news))
               (here (if (equal path "") name (format "%s.%s" path name))))
          (setq found
                (if (not (equal name (harness-replay--field-name other)))
                    here
                  (harness-replay--piece-diff
                   (harness-replay--field-piece field)
                   (harness-replay--field-piece other) here))))
        (setq i (1+ i)))
      found))))

(defun harness-replay--piece-splice (old new)
  "Return NEW with every byte of OLD it still sends put back as OLD's.
The result is the body to send: what the provider already read, byte for
byte, and the request's new material encoded fresh.  NEW must continue OLD
\(`harness-replay--piece-diff' answers nil for it)."
  (cond
   ((not (equal (plist-get old :kind) (plist-get new :kind))) new)
   ((equal (plist-get old :kind) "scalar") old)
   ((equal (plist-get old :kind) "array")
    (let ((olds (harness-replay--piece-items old))
          (news (harness-replay--piece-items new)))
      (list :kind "array"
            :items (harness-json-array
                    (append (cl-loop for old-item in olds
                                     for new-item in news
                                     collect (harness-replay--piece-splice
                                              old-item new-item))
                            (nthcdr (length olds) news))))))
   (t
    (let ((olds (harness-replay--piece-fields old))
          (news (harness-replay--piece-fields new)))
      (list :kind "object"
            :fields (harness-json-array
                     (append (cl-loop for old-field in olds
                                      for new-field in news
                                      collect (list
                                               :name (harness-replay--field-name new-field)
                                               :piece (harness-replay--piece-splice
                                                       (harness-replay--field-piece old-field)
                                                       (harness-replay--field-piece new-field))))
                             (nthcdr (length olds) news))))))))

;;;; What is kept, and where

(defun harness-replay--frozen-read (id)
  "Return the frozen body kept for session ID, or nil.
It is (:id ID :version N :generation N :reset REASON :at TIME :model M
:route R :body PIECE), as `replay/frozen-record' left it, the body's bytes
kept exactly."
  (when (stringp id)
    (let ((record (harness-replay--read (harness-replay--frozen-name id))))
      (when (and (consp record)
                 (equal (plist-get record :id) id)
                 (integerp (plist-get record :version))
                 (integerp (plist-get record :generation))
                 (consp (plist-get record :body)))
        record))))

(defun harness-replay--frozen-write (id record)
  "Write RECORD as the frozen body of session ID; non-nil when it was written.
A store that refuses it is logged, and the session is left without a frozen
body rather than with a wrong one: the next request builds its body fresh
and records a `storage-failure' reset."
  (condition-case err
      (progn
        (harness-write-file-atomically
         (harness-replay--file (harness-replay--frozen-name id))
         (harness-json-encode record))
        t)
    (error (harness-log 'warn "replay: cannot keep the body of %s: %s"
                        id (harness-error-short-message err))
           nil)))

(defun harness-replay--frozen-delete (id)
  "Delete the frozen body of session ID, if there is one."
  (ignore-errors (harness-call 'store/delete (harness-replay--frozen-name id))))

(harness-defmethod replay/frozen-reset (id reason &optional detail)
  "Record that session ID's frozen body no longer applies, and why.
REASON is one of `harness-replay-frozen-reset-reasons'; DETAIL says what
changed, for the log, never a prompt's text.  The record keeps the reason
and a new generation, so a difference the next check finds is explained by
what was recorded and one it does not find is refused.  Return the new
generation, or nil when there is nothing to record."
  (when (stringp id)
    (let* ((old (harness-replay--frozen-read id))
           (generation (1+ (or (and old (plist-get old :generation)) 0)))
           (record (list :id id :version harness-replay-frozen-version
                         :generation generation
                         :reset (harness-replay--frozen-tag reason)
                         :at (float-time)
                         :body (list :kind "\1" :fields nil))))
      (when (harness-replay--frozen-write id record)
        (harness-log 'debug "replay: %s starts a new frozen body (%s): %s"
                     id reason (or detail "-"))
        generation))))

(harness-defmethod replay/frozen-status (id)
  "Return what is frozen for session ID, or nil.
It is (:generation N :reset REASON :at TIME :bytes N), N being the
bytes of the body kept: 0 when nothing is, which a reset record leaves.
Nothing in it is a prompt's text."
  (when-let* ((record (harness-replay--frozen-read id)))
    (let ((body (plist-get record :body)))
      (list :generation (plist-get record :generation)
            :reset (plist-get record :reset)
            :at (plist-get record :at)
            :bytes (if (harness-replay--piece-fields body)
                       (string-bytes (harness-replay--piece-text body))
                     0)))))

(defun harness-replay--system-piece (record)
  "Return the system scalar of a chat-completions frozen RECORD.
Refuse other shapes rather than guessing where an adapter put instructions."
  (let* ((body (plist-get record :body))
         (field (cl-find "messages" (harness-replay--piece-fields body)
                         :key #'harness-replay--field-name :test #'equal))
         (messages (and field (harness-replay--field-piece field)))
         (first (car (harness-replay--piece-items messages)))
         (fields (harness-replay--piece-fields first))
         (role (harness-replay--field-piece
                (cl-find "role" fields :key #'harness-replay--field-name :test #'equal)))
         (content (harness-replay--field-piece
                   (cl-find "content" fields :key #'harness-replay--field-name :test #'equal))))
    (unless (and (equal (plist-get messages :kind) "array")
                 (equal (plist-get first :kind) "object")
                 (equal (plist-get role :kind) "scalar")
                 (equal (harness-json-parse (plist-get role :bytes)) "system")
                 (equal (plist-get content :kind) "scalar")
                 (stringp (harness-json-parse (plist-get content :bytes))))
      (signal 'harness-error '("Unsupported frozen system shape")))
    content))

(defun harness-replay--system-hash (text)
  "Return the SHA-256 of TEXT's exact UTF-8 bytes."
  (secure-hash 'sha256 (encode-coding-string text 'utf-8-unix t)))

(defun harness-replay--system-transition-state (id)
  "Read ID's frozen and actual current system, without changing either.
The current text is the one the session **settled** when it has one, not
a prompt built again now: a prompt rebuilt from the live stores -- the
memory index, a skills list, a granted directory -- is not what the
session sends, and approving it would freeze a prompt the session never
had.  A session that settled none is compared as it would be built, and
building it must not settle it: settling announces a reset, which would
empty the very frozen body this is reading."
  (unless (and (fboundp 'harness-agent--system-prompt)
               (harness-call 'session/exists-p id))
    (signal 'harness-error '("System transition unavailable")))
  (let* ((record (harness-replay--frozen-read id))
         (piece (harness-replay--system-piece record))
         (old (harness-json-parse (plist-get piece :bytes)))
         (session (harness-call 'session/get id))
         (settled (plist-get session :system))
         (current (if (and (stringp settled) (not (string-empty-p settled)))
                      settled
                    (harness-agent--system-prompt session))))
    (unless (and (integerp (plist-get record :generation))
                 (equal (plist-get record :version) harness-replay-frozen-version)
                 (stringp current))
      (signal 'harness-error '("System transition record unavailable")))
    (list :record record :current current
          :generation (plist-get record :generation)
          :old-sha256 (harness-replay--system-hash old)
          :new-sha256 (harness-replay--system-hash current))))

(harness-defmethod session/system-transition-status (id)
  "Return ID's frozen generation and old/current system SHA-256 hashes.
No prompt text is returned; this is an inspection, not an approval."
  (let ((state (harness-replay--system-transition-state id)))
    (list :generation (plist-get state :generation)
          :old-sha256 (plist-get state :old-sha256)
          :new-sha256 (plist-get state :new-sha256))))

(harness-defmethod session/transition-system (id generation old-sha256 new-sha256)
  "Explicitly approve only ID's current system text at GENERATION.
Both hashes must match the frozen and currently generated system exactly.
The session must be inactive.  Only the frozen system scalar is replaced;
all other fields and historical bytes remain protected by the normal
transport guard.  This records approval, not a claim that a request was sent."
  (when (or (not (fboundp 'harness-agent-running-p))
            (harness-agent-running-p id))
    (signal 'harness-error '("System transition requires an inactive session")))
  (let* ((state (harness-replay--system-transition-state id))
         (record (copy-tree (plist-get state :record) t)))
    (unless (and (integerp generation)
                 (= generation (plist-get state :generation))
                 (stringp old-sha256) (stringp new-sha256)
                 (equal old-sha256 (plist-get state :old-sha256))
                 (equal new-sha256 (plist-get state :new-sha256))
                 (not (equal old-sha256 new-sha256)))
      (signal 'harness-error '("System transition expectation mismatch")))
    ;; Prompt filters may consult services and yield.  Recheck after they
    ;; return, before committing approval to the same frozen generation.
    (when (or (harness-agent-running-p id)
              (not (equal (plist-get state :record) (harness-replay--frozen-read id))))
      (signal 'harness-error '("System transition changed during validation")))
    (setf (plist-get (harness-replay--system-piece record) :bytes)
          (harness-json-encode-text (plist-get state :current)))
    (let ((next (1+ generation))
          (audit (list :kind "system-transition-approved" :at (float-time)
                       :from-generation generation :old-sha256 old-sha256
                       :new-sha256 new-sha256)))
      (setq record (plist-put record :generation next))
      (setq record (plist-put record :reset "system"))
      (setq record (plist-put record :transition audit))
      (unless (harness-replay--frozen-write id record)
        (signal 'harness-error '("System transition could not be persisted")))
      (harness-log 'info "replay: %s approved system transition %s -> %s"
                   id generation next)
      (list :generation next :reason "system" :transition audit))))

(harness-defmethod replay/frozen-record (id body &optional model route)
  "Keep BODY, the body of session ID's request, as what that request sent.
BODY is the body as the harness holds it, a plist of the fields the adapter
built.  Only its **prompt** fields are kept (`harness-replay-prompt-fields'):
a per-request metadata field is not part of the prefix a cache reads, so it
is not stored and not compared.  MODEL and ROUTE name what it was built
for: a body kept for one model or one endpoint is not continued for
another.  A body over `harness-replay-frozen-max-bytes' is not kept and a
`too-large' reset is recorded instead.  Return the generation kept, or nil."
  (when (stringp id)
    (let* ((prompt (harness-replay--prompt-only (harness-replay--as-piece body)))
           (text (harness-replay--piece-text prompt))
           (old (harness-replay--frozen-read id))
           (generation (1+ (or (and old (plist-get old :generation)) 0))))
      (if (> (string-bytes text) harness-replay-frozen-max-bytes)
          (progn
            (harness-replay--frozen-delete id)
            (harness-log 'debug
                         "replay: the body of %s is too large to keep (%d bytes)"
                         id (string-bytes text))
            (harness-call 'replay/frozen-reset id 'too-large
                          (format "%d bytes" (string-bytes text)))
            nil)
        (when (harness-replay--frozen-write
               id (list :id id :version harness-replay-frozen-version
                        :generation generation :at (float-time)
                        :model (harness-replay--frozen-tag model)
                        :route (harness-replay--frozen-tag route)
                        ;; Keep the latest explicit approval after the accepted
                        ;; request is actually sent, without retaining text.
                        :transition (plist-get old :transition)
                        :body prompt))
          generation)))))
(harness-defmethod replay/frozen-splice (id model route body)
  "Return the body of session ID's next request, frozen where it may be.
BODY is the body the adapter built.  MODEL and ROUTE name what it is for.

Only the body's **prompt** fields are frozen (`harness-replay-prompt-fields'):
the model, the system material, the tool schema and every message.  A
per-request metadata field -- `stream', `stream_options', `include', a
token budget -- is encoded fresh on every request and is never compared,
because a provider's cache reads the prompt and not how a request was
transported.

The value is (:body PIECE :text TEXT :spliced BOOL :generation N :reset
REASON :divergence PATH :metadata N).  When a kept prompt applies, every
byte of it the request still sends is put back as it was, so the body
that goes out is the bytes the provider read plus the request's new
material encoded fresh.  SPLICED says whether that happened, RESET is the
reason the kept body was dropped instead, DIVERGENCE names the first place
the rebuilt body no longer continues it, and METADATA counts the fields
that were encoded fresh as metadata."
  (pcase-let* ((piece (harness-replay--as-piece body))
               (prompt (harness-replay--prompt-only piece))
               (old (and (stringp id) (harness-replay--frozen-read id)))
               (kept (and old
                          (= (or (plist-get old :version) 0)
                             harness-replay-frozen-version)
                          (equal (plist-get old :model)
                                 (harness-replay--frozen-tag model))
                          (equal (plist-get old :route)
                                 (harness-replay--frozen-tag route))
                          (plist-get old :body)))
               (divergence (and kept (harness-replay--piece-diff kept prompt "")))
               ;; The metadata fields this request carries: the ones the
         ;; adapter encoded fresh.  A field it always sends is still one,
         ;; and counting it says how much of the body is not the prompt.
         (metadata (length (harness-replay--metadata-fields piece))))
    (cond
     ((not (consp kept))
      (list :body prompt :text (harness-replay--piece-text piece) :spliced nil
            :generation (and old (plist-get old :generation))
            :reset (and old (plist-get old :reset))
            :metadata metadata))
     (divergence
      ;; A prompt field that is gone is a component the provider read and
      ;; this request no longer sends.  Nothing else can explain it: no
      ;; setting announces it (a thinking level that went nil, a session
      ;; whose tool list emptied), and the boundary check would refuse
      ;; every request this session ever makes again, because the frozen
      ;; body is only rewritten by a request that is sent.  It is recorded
      ;; here, with the field named, so the next request is built fresh
      ;; instead.  A field whose bytes changed is left to the refusal: that
      ;; is a rebuild the harness cannot account for, and it must not go
      ;; out.
      ;;
      ;; The exception is the reasoning effort, which no setting announces:
      ;; a model's listing can name the efforts it takes only after the
      ;; first request went out (`harness-openai--effort'), which maps the
      ;; same thinking level onto another effort.  Refusing that forever
      ;; leaves the session unable to make any request at all, so it is
      ;; recorded as the reset it is and the request goes out built fresh.
      ;; Nothing else is: the conversation, the system prompt and the tool
      ;; schema each have a way of announcing a change of theirs, and a
      ;; rebuild that none of them accounts for must not go out.
      (let ((dropped (harness-replay--dropped-prompt-fields kept prompt))
            (effort (harness-replay--changed-effort-field-p divergence))
            (definition (harness-replay--changed-tool-definition-p
                         kept prompt divergence)))
        (cond
         (dropped
          (harness-call 'replay/frozen-reset
                        id 'field-dropped
                        (format "no longer sent: %s"
                                (mapconcat #'identity dropped ", "))))
         (effort
          (harness-call 'replay/frozen-reset
                        id 'diverged
                        (format "changed: %s" divergence)))
         (definition
          (harness-call 'replay/frozen-reset
                        id 'tool-definition
                        (format "changed: %s" divergence)))))
      (list :body prompt :text (harness-replay--piece-text piece) :spliced nil
            :generation (plist-get old :generation)
            :reset 'diverged :divergence divergence
            :metadata metadata))
     (t
      ;; The prompt is spliced from the kept bytes; the metadata is this
      ;; request's own and goes out as the adapter just encoded it.
      (let* ((head (harness-replay--piece-splice kept prompt))
             (whole (harness-replay--with-metadata head piece)))
        (list :body head :text (harness-replay--piece-text whole) :spliced t
              :generation (plist-get old :generation)
              ;; How much of this request's prompt came from the kept bytes,
              ;; which is what a telemetry line reports as the prefix.
              :prefix-bytes (string-bytes (harness-replay--piece-text kept))
              :metadata metadata))))))

(defun harness-replay--with-metadata (prompt body)
  "Return PROMPT, a body's frozen prompt, with BODY's metadata fields.
The fields keep the adapter's own order, so the body that goes out has
the shape the adapter built: only the prompt's bytes come from the kept
record."
  (if (not (equal (plist-get body :kind) "object"))
      body
    (let ((fields (harness-replay--piece-fields body)))
      (list :kind "object"
            :fields (harness-json-array
                     (cl-loop for field in fields
                              if (harness-replay-prompt-field-p
                                  (harness-replay--field-name field))
                              collect (list :name (harness-replay--field-name field)
                                            :piece (or (harness-replay--field-piece
                                                        (cl-find (harness-replay--field-name field)
                                                                 (harness-replay--piece-fields prompt)
                                                                 :key #'harness-replay--field-name
                                                                 :test #'equal))
                                                       (harness-replay--field-piece field)))
                              else collect field))))))
(harness-defmethod replay/frozen-check (id body &optional generation)
  "Return why BODY may not be sent for session ID, or nil.
This is the transport boundary.  BODY is the body about to go out, as the
harness holds it, and the value is nil when every byte of it that was sent
before is still there, unchanged and in place: the request continues what
was frozen.  A recorded reset empties the frozen body, so a body that
differs from a non-empty one is a mutation nothing explains -- a rebuild
after the splice, a field changed on the way to the transport -- and the
string names the first place it happened.  The caller must then send
nothing.  GENERATION is the one the splice reported; it only sharpens the
message."
  (when-let* ((old (and (stringp id) (harness-replay--frozen-read id)))
              (kept (plist-get old :body))
              ((harness-replay--piece-fields kept)))
    ;; Only the prompt is compared: a metadata field the adapter encoded
    ;; differently is not a change of what the model is told, and refusing
    ;; a request for one would stop a turn the cache never cared about.
    (when-let* ((where (harness-replay--piece-diff
                        kept
                        (harness-replay--prompt-only (harness-replay--as-piece body))
                        "")))
      (format "prompt component %s changed with no recorded reset%s"
              (if (string-empty-p where) "body" where)
              (if (and (integerp generation)
                       (= generation (plist-get old :generation)))
                  ""
                (format "; the frozen body is generation %s, the splice reported %s"
                        (plist-get old :generation)
                        (or generation "none")))))))

;;;;
;;;; The seam an adapter uses

(defun harness-replay--session-id (request)
  "Return the id of REQUEST's session, or nil."
  (let ((session (plist-get request :session)))
    (cond ((stringp session) session)
          ((listp session) (plist-get session :id))
          (t nil))))

(defun harness-replay-route (request endpoint)
  "Return what a body is frozen for besides its model: REQUEST and ENDPOINT.
It names the endpoint and the account the request goes to, so that a body
kept for one route is not spliced into another's."
  (format "%s|%s|%s"
          (or (plist-get endpoint :id) "unknown")
          (or (plist-get request :account) "-")
          (or (plist-get endpoint :base-url) "-")))

(defun harness-replay--prompt-bytes (piece)
  "Return the bytes of PIECE, a body's prompt, as it is sent."
  (string-bytes (harness-replay--piece-text (harness-replay--prompt-only piece))))

(defun harness-replay--telemetry (_id model route frozen body)
  "Return the content-free record of one request's prefix decision.
It is what makes a future cache miss diagnosable without keeping a
prompt: no message text, no tool text, no digest of either.  The value
is (:generation N :decision SYMBOL :reason REASON :prefix-bytes N
:appended-bytes N :metadata N :model M :route R :at TIME), where
DECISION is `spliced', `fresh' or `diverged', REASON is why a fresh
body was built, PREFIX-BYTES is how much of the prompt was re-sent from
the kept bytes, and APPENDED-BYTES how much is new."
  (let* ((whole (harness-replay--as-piece body))
         (prompt (harness-replay--prompt-only whole))
         (total (harness-replay--prompt-bytes prompt))
         ;; What was actually continued: the prompt the kept body had, which
         ;; the splice put back byte for byte.  A body that diverged
         ;; continued nothing, whatever it was built from.
         ;; What was actually continued: the bytes of the prompt the
         ;; splice put back.  A body that diverged continued nothing.
         (kept (if (plist-get frozen :spliced)
                   (min total (or (plist-get frozen :prefix-bytes) 0))
                 0)))
    (list :generation (plist-get frozen :generation)
          :decision (cond ((plist-get frozen :spliced) 'spliced)
                          ((plist-get frozen :divergence) 'diverged)
                          (t 'fresh))
          :reason (plist-get frozen :reset)
          :divergence (plist-get frozen :divergence)
          :prefix-bytes (min kept total)
          :appended-bytes (max 0 (- total kept))
          :metadata (or (plist-get frozen :metadata) 0)
          :model (harness-replay--frozen-tag model)
          :route (harness-replay--frozen-tag route)
          :at (float-time))))
(defun harness-replay-conversation-p (request)
  "Non-nil when REQUEST is a request of its session's own conversation.
That is what may freeze a body, or be continued from one.  A
one-off call the harness makes on its own -- an auto-name, a
permission judge, a recap -- names a session but is not its
conversation: it carries another system prompt and another message
list, so splicing it into the session's prefix would rewrite what
the next step of the conversation has to continue, and keeping it
would make that step diverge.  It goes out as its adapter built it."
  (not (harness-json-true-p (plist-get request :ephemeral))))

(defun harness-replay-read-only-p (request)
  "Non-nil when REQUEST may read its session's frozen prefix but never replace it.
That is a request that sends the conversation as the next step would and
adds material of its own that the conversation does not hold: a
compaction summary made from the prompt cache
\(`harness-compaction--prefix-request'), which appends the summarisation
instruction after the conversation's last message.  It splices, because
re-sending the bytes the provider read is what reads the cache, and it is
never kept: the next real step would diverge at the message the
transcript never had, exactly as it would after a cache refresh.

The flag is the request's own (`:replay-read-only') and not
`:cache-refresh', which a warmer, the admission ranking and the Claude
provider each read for their own purposes, nor `:ephemeral', which says
a call is not the session's conversation at all and so may not splice
what it is not."
  (harness-json-true-p (plist-get request :replay-read-only)))

(defun harness-replay-keeps-prefix-p (request)
  "Non-nil when REQUEST may become the prefix its session continues.
A one-off call may not (`harness-replay-conversation-p'), and neither
may a cache refresh: it sends the conversation plus one short message
the conversation does not hold (harness-cache-warm.el), so keeping it
would make the next real step diverge at that message -- refused at
the transport, or re-rendered whole and paid for uncached.  A refresh
still splices: it re-sends the bytes the provider read, which is what
reads the cache, and only reads them.  A read-only request
\(`harness-replay-read-only-p') is excluded for the same reason: what it
appends is the summary's instruction, which the conversation's next step
never sends."
  (and (harness-replay-conversation-p request)
       (not (harness-json-true-p (plist-get request :cache-refresh)))
       (not (harness-replay-read-only-p request))))

(defun harness-replay-seam (request model route body)
  "Return (BODY . COMPLAINT) for the request BODY about to be sent.
MODEL and ROUTE name what BODY was built for.  The first value is the body
to send: every byte an earlier request of the same session sent is the
bytes that request sent, and only the request's new material is encoded
fresh.  COMPLAINT is nil, or a string saying that the body may not be sent
at all -- a prompt component changed and no recorded reset explains it --
and the caller must then send nothing.

Nothing is frozen for a request that names no session, for a one-off
call that is not its session's conversation (`harness-replay-conversation-p'),
or when the module that keeps frozen bodies is not loaded: the body is
returned as it is."
  (let ((id (harness-replay--session-id request)))
    (if (or (not (stringp id))
            (not (harness-replay-conversation-p request))
            (not (harness-method-exists-p 'replay/frozen-splice)))
        ;; Nothing is frozen for it, and the bytes are what the
        ;; adapter's own body encodes to: the seam always answers
        ;; with text.
        (cons (harness-replay--piece-text (harness-replay--piece body)) nil)
      (let* ((frozen (harness-call 'replay/frozen-splice id model route body))
             (piece (plist-get frozen :body))
             (complaint (harness-call 'replay/frozen-check id piece
                                      (plist-get frozen :generation))))
        (unless (plist-get frozen :spliced)
          (when-let* ((reset (plist-get frozen :reset)))
            (harness-log 'debug "replay: %s sends a fresh body (%s): %s"
                         id reset (or (plist-get frozen :divergence) "-"))))
        ;; One content-free line per request, so a cache miss can be read
        ;; later without a prompt ever being kept for it.
        (ignore-errors
          (harness-emit 'replay/prefix id
                        (harness-replay--telemetry id model route frozen body)))
        (cons (plist-get frozen :text) complaint)))))

(defun harness-replay-seam-keep (request model route body)
  "Keep BODY, the body just sent for REQUEST, as what that request sent.
MODEL and ROUTE name what it was built for.  Nothing is kept for a request
that names no session, and nothing for a one-off call that is not its
session's conversation (`harness-replay-conversation-p'): keeping one
would leave the conversation's next step diverging from a body it never
sent, and none for a cache refresh, which reads the cache and is no
step of the conversation (`harness-replay-keeps-prefix-p')."
  (let ((id (harness-replay--session-id request)))
    (when (and (stringp id) (harness-replay-keeps-prefix-p request)
               (harness-method-exists-p 'replay/frozen-record))
      (ignore-errors
        (harness-call 'replay/frozen-record id body model route)))))

(defun harness-replay-seam-reset (request reason &optional detail)
  "Record that REQUEST's session's frozen body no longer applies, and why.
REASON is one of `harness-replay-frozen-reset-reasons'.  Nil when the
request names no session or nothing keeps frozen bodies."
  (let ((id (harness-replay--session-id request)))
    (when (and (stringp id) (harness-method-exists-p 'replay/frozen-reset))
      (ignore-errors (harness-call 'replay/frozen-reset id reason detail)))))


;;;; The last request, as the provider was sent it

(defun harness-replay--thaw (value)
  "Return VALUE, read as raw JSON, in the form the harness holds it.
An object becomes a plist, but an empty one becomes `:empty'; an array
becomes a list, but an empty one stays a vector, so that it encodes as
an array again.  The harness's own reading of JSON maps both an empty
object and an empty array to nil, and a payload written again from that
would have null where the request had {} or [] -- not the request the
provider cached."
  (cond
   ((hash-table-p value)
    (if (zerop (hash-table-count value))
        :empty
      (let (out)
        (maphash (lambda (key item)
                   (push (intern (concat ":" key)) out)
                   (push (harness-replay--thaw item) out))
                 value)
        (nreverse out))))
   ((vectorp value)
    (if (zerop (length value))
        []
      (mapcar #'harness-replay--thaw (append value nil))))
   (t value)))

(defun harness-replay--read (name)
  "Return the JSON document NAME as the harness holds it, empties kept apart.
Nil when it is missing, or cannot be read as JSON.  See
`harness-replay--thaw'."
  (let ((text (harness-read-file (harness-replay--file name))))
    (when (and text (not (string-blank-p text)))
      (condition-case err
          (harness-replay--thaw
           (json-parse-string text :object-type 'hash-table :array-type 'array
                              :null-object nil :false-object :false))
        (error (harness-log 'warn "replay: cannot read %s: %s"
                            name (harness-error-message err))
               nil)))))

(defun harness-replay--intern-message (message)
  "Return MESSAGE, a message of a kept payload, as a request holds it.
Its role comes back from JSON as a string, and the harness holds a role
as a symbol (`user', `assistant'); a provider that pairs the two by name
expects that, and so does anything comparing messages."
  (if (and (consp message) (stringp (plist-get message :role)))
      (plist-put (copy-sequence message) :role
                 (intern (plist-get message :role)))
    message))

(defun harness-replay--request (id)
  "Return the payload of the last request of session ID, or nil.
It is a plist (:id ID :at TIME :model MODEL :thinking LEVEL :system TEXT
:tools SPECS :builtin-tools SPECS :messages MESSAGES :nodes IDS :digest
DIGEST), as `replay/save-request' left it, its messages as a request
holds them (`harness-replay--intern-message')."
  (when (stringp id)
    (let ((payload (harness-replay--read (harness-replay--request-name id))))
      (when (and (consp payload)
                 (equal (plist-get payload :id) id)
                 (listp (plist-get payload :nodes))
                 (listp (plist-get payload :messages)))
        (plist-put payload :messages
                   (mapcar #'harness-replay--intern-message
                           (plist-get payload :messages)))))))

(defun harness-replay--image-data-p (value)
  "Non-nil when VALUE holds the bytes of a picture, under a `:data' key.
A request that holds one is not kept: the images a conversation carries
are cut by its length (`harness-agent-history-images'), so a kept one
would hold pictures a later request drops, and the bytes are not the
transcript's to store twice."
  (cond
   ((vectorp value) (cl-some #'harness-replay--image-data-p (append value nil)))
   ((and (consp value) (proper-list-p value))
    (if (and (keywordp (car value)) (cl-evenp (length value)))
        (cl-loop for (key item) on value by #'cddr
                 thereis (or (eq key :data) (harness-replay--image-data-p item)))
      (cl-some #'harness-replay--image-data-p value)))
   (t nil)))

(defun harness-replay--same-json-p (a b)
  "Non-nil when A and B are the same JSON value.
A kept payload comes back from JSON, where a vector may be a list: what
matters is what the two encode to, which is what the model is sent."
  (equal (harness-json-encode a) (harness-json-encode b)))

(defun harness-replay--fits-p (request stored)
  "Non-nil when REQUEST may be continued from the kept payload STORED.
That is the same model and thinking level, the same system prompt and
the same tools, and messages to continue from."
  (let ((session (plist-get request :session)))
    (and stored
         (consp (plist-get stored :messages))
         (consp (plist-get stored :nodes))
         (equal (plist-get stored :id) (plist-get session :id))
         (harness-setting-equal-p :model (plist-get stored :model) (plist-get request :model))
         (harness-setting-equal-p :thinking (plist-get stored :thinking) (plist-get request :thinking))
         (equal (plist-get stored :system) (plist-get request :system))
         (harness-replay--same-json-p (plist-get stored :tools) (plist-get request :tools))
         (harness-replay--same-json-p (plist-get stored :builtin-tools)
                                      (plist-get request :builtin-tools)))))

(harness-defmethod replay/prefix (request)
  "Return how REQUEST continues the payload of its session's last request.
The value is a plist (:messages MESSAGES :suffix SUFFIX) when it does:
MESSAGES are the messages the last request sent, as it sent them, and
SUFFIX are the messages the nodes added since render as
\(`session/messages-from'), for the caller to prepare as the rest were
prepared.  Nil when there is nothing to continue, or when the payload
does not apply: another model, thinking level, system prompt or tools, a
transcript that no longer starts with the nodes it was rendered from, or
one of those nodes rendering differently since (a message delivered
after a later node, a result added to a message that had none).  Those
are changes of what the model is told or of the conversation, and the
request is rendered afresh for them."
  (let* ((session (plist-get request :session))
         (id (plist-get session :id))
         (stored (and id (harness-replay--request id))))
    (when (harness-replay--fits-p request stored)
      (let* ((nodes (plist-get stored :nodes))
             ;; One call says both that the transcript still starts with
             ;; those nodes and that they render as they did.
             (digest (harness-call 'session/render-digest id nodes)))
        (cond
         ((null digest)
          (harness-log 'debug "replay: %s no longer starts with the nodes of its last request" id)
          nil)
         ((not (equal digest (plist-get stored :digest)))
          (harness-log 'debug "replay: %s renders the nodes of its last request differently" id)
          nil)
         (t (pcase (harness-call 'session/messages-from id (car (last nodes)))
              (`(:ok t :messages ,suffix)
               (list :messages (plist-get stored :messages) :suffix suffix))
              (`(:ok nil :why ,why)
               (harness-log 'debug "replay: %s cannot be continued: %s" id why)
               nil)
              (_ nil))))))))

(harness-defmethod replay/save-request (request)
  "Keep REQUEST's payload for its session, to continue the next one from.
The payload is its model, thinking level, system prompt, tools and
messages, with the ids of the nodes `session/messages' rendered them
from and a digest of those nodes (`session/render-state').  Nothing is
kept for a request that names no session, or for one over
`harness-replay-request-max-bytes'."
  (let* ((session (plist-get request :session))
         (id (plist-get session :id))
         (messages (plist-get request :messages)))
    ;; Pictures are kept like any other part of the request: the copies
    ;; `harness-images.el' takes name them by the digest of their bytes,
    ;; so a result keeps sending the picture the tool returned, and a
    ;; file changed under it cannot change the prefix.  A request that
    ;; lost pictures is a recorded reset (`agent/images-pruned'), not a
    ;; reason to render everything again.
    (when (and (stringp id) (consp messages))
      (let* ((state (harness-call 'session/render-state id))
             (nodes (plist-get state :nodes)))
        (when (consp nodes)
          (let* ((payload (list :id id :at (float-time)
                                :model (plist-get request :model)
                                :thinking (let ((level (plist-get request :thinking)))
                                            (and level (if (symbolp level) (symbol-name level) level)))
                                :system (plist-get request :system)
                                :tools (plist-get request :tools)
                                :builtin-tools (plist-get request :builtin-tools)
                                :messages messages
                                :nodes (harness-json-array nodes)
                                :digest (plist-get state :digest)))
                 (text (harness-json-encode payload)))
            (if (> (string-bytes text) harness-replay-request-max-bytes)
                (progn
                  (harness-log 'debug "replay: the request of %s is too large to keep (%d bytes)"
                               id (string-bytes text))
                  nil)
              (harness-write-file-atomically (harness-replay--file (harness-replay--request-name id))
                                             text)
              t)))))))

;;;; The resets of a frozen body
;;
;; A frozen body stops applying when what the model is sent changes for a
;; reason the harness knows: a compaction replaces the conversation, a
;; redaction takes a secret out, pictures are dropped from the history, the
;; session moves to another model or route, its system prompt or tools
;; change, or the store could not hold the body.  Each is recorded as a
;; reset, with its reason and a new generation (`replay/frozen-reset'), so
;; that the next request is built fresh and the check at the transport
;; boundary can tell a recorded change from an unexplained one.

(defconst harness-replay-reset-changes
  '((:model . model) (:thinking . model) (:system . system)
    (:tools . tools) (:account . route) (:provider-state . route))
  "The session settings a frozen body cannot survive, and why.
A body kept for one model, one thinking level, one system prompt, one
tool set or one route is not what the next request sends, and a change of
any of them is recorded as a reset rather than left for the boundary
check to refuse.")

(defun harness-replay-reset-on-change (id changes)
  "Record why a frozen body of session ID stops applying, if it does.
CHANGES is what `session/updated' reports: the settings the session
changed.  The first of them a body cannot survive is recorded as the
reset's reason.  Return the reason recorded, or nil."
  (when (stringp id)
    (cl-loop for (key . reason) in harness-replay-reset-changes
             when (plist-member changes key)
             do (harness-call 'replay/frozen-reset id reason)
             and return reason)))

(defun harness-replay--on-session-updated (id changes)
  "Record a reset for the session ID whose CHANGES end its frozen body."
  (ignore-errors (harness-replay-reset-on-change id changes)))

(defun harness-replay--on-images-pruned (id &rest _)
  "Record that session ID's request lost pictures the provider was sent.
The images a conversation carries are cut by its length
(`harness-agent-history-images'), which rewrites the results that held
them: the bytes after one change, and the change is the pruning's."
  (ignore-errors (harness-call 'replay/frozen-reset id 'images-pruned)))

;;;; Redaction, compaction and deletion

(defun harness-replay--forget-memory (id)
  "Let the provider forget what it holds in memory for session ID.
The next request reads the responses again from the disk, which a
redaction has cleaned in the meantime."
  (when (fboundp 'harness-responses-forget-session)
    (harness-responses-forget-session id)))

(harness-defmethod replay/forget (id)
  "Delete what is kept for session ID: its responses and its last request."
  (harness-call 'store/delete (harness-replay--responses-name id))
  (harness-call 'store/delete (harness-replay--request-name id))
  (harness-replay--frozen-delete id)
  (harness-replay--forget-memory id))

(harness-defmethod replay/redact (id secrets &optional dry-run)
  "Take SECRETS out of the payload files of session ID, or count them (DRY-RUN).
Return (:count N :files (FILE...)): the occurrences found, and the
files that held one.  The responses are cleaned in place, a line with a
secret at a time, keeping every other line byte for byte: dropping them
would send the messages that made them without their reasoning items,
which is a different message.  The last request is dropped instead,
which costs no cache: the next request is rendered from the redacted
transcript, and the redaction changed that anyway."
  (let ((responses (harness-replay--file (harness-replay--responses-name id)))
        (request (harness-replay--file (harness-replay--request-name id)))
        (frozen (harness-replay--file (harness-replay--frozen-name id)))
        (count 0) (files nil) (hit nil))
    (when (file-regular-p responses)
      (let ((result (harness-redaction-file
                     responses secrets :style 'jsonl :json-style 'foreign :dry-run dry-run)))
        (when (> (or (plist-get result :count) 0) 0)
          (cl-incf count (plist-get result :count))
          (setq hit t)
          (push responses files))))
    (when (file-regular-p request)
      (let ((n (harness-redaction-file-count request secrets)))
        (when (> n 0)
          (cl-incf count n)
          (setq hit t)
          (push request files)
          (unless dry-run (delete-file request)))))
    ;; The frozen body holds the same text as the request it was made
    ;; from: it is counted, and it goes, so that the next request is
    ;; built from the redacted transcript.
    (when (file-regular-p frozen)
      (let ((n (harness-redaction-file-count frozen secrets)))
        (when (> n 0)
          (cl-incf count n)
          (setq hit t)
          (push frozen files))))
    (when (and hit (not dry-run))
      (harness-replay--forget-memory id)
      ;; The body kept for the session holds the same text: it is dropped,
      ;; and the next request is built from the redacted transcript, which
      ;; the redaction changed anyway.  The reset says so.
      (harness-replay--frozen-delete id)
      (when (harness-method-exists-p 'replay/frozen-reset)
        (harness-call 'replay/frozen-reset id 'redaction)))
    (list :count count :files (nreverse files))))

(defun harness-replay--on-session-deleted (id &rest _)
  "Delete what is kept for the session ID that is gone."
  (ignore-errors (harness-call 'replay/forget id)))

(defun harness-replay--on-compaction (id &rest _)
  "Drop the last request of session ID: the conversation it was made of is gone.
The request that follows is rendered from the compaction, and its payload
kept again.  The frozen body goes the same way, with `compaction' recorded
as the reason, so that the next request is built from the compaction and
the boundary check knows why it changed."
  (ignore-errors
    (harness-call 'store/delete (harness-replay--request-name id)))
  (ignore-errors
    (when (harness-method-exists-p 'replay/frozen-reset)
      (harness-call 'replay/frozen-reset id 'compaction))))

;;;; Module

(defun harness-replay--on-prefix (id info)
  "Remember session ID's prefix decision INFO, and nothing else.
The decision is what a later miss is read against; keeping it is a
hash-table entry, not a prompt."
  (ignore-errors (harness-replay-note-decision id info)))

(defun harness-replay--on-reuse (id info)
  "Read session ID's cache reuse INFO against its last prefix decision.
A miss on a spliced prefix is the provider's, and nothing is done about
it here: no re-render, no reset, no retry."
  (ignore-errors (harness-call 'replay/miss-note id info)))

(defun harness-replay--init ()
  "Subscribe to what makes a kept payload or a frozen body wrong.
That is a deletion, a compaction, a session setting the body was built
for, and the pictures a request lost when its history was pruned."
  (harness-on 'session/deleted #'harness-replay--on-session-deleted)
  (harness-on 'compaction/done #'harness-replay--on-compaction)
  (harness-on 'session/updated #'harness-replay--on-session-updated)
  (harness-on 'agent/images-pruned #'harness-replay--on-images-pruned)
  (harness-on 'replay/prefix #'harness-replay--on-prefix)
  (harness-on 'cache/reuse #'harness-replay--on-reuse))

;;;; A miss after identical bytes
;;
;; A request whose prompt was re-sent from the kept bytes and which the
;; provider still did not serve from cache is a fact about the provider,
;; not about the harness: eviction, retention and routing are its own.
;; The one thing the harness must not do is react by changing what it
;; sends -- re-rendering the prompt, resetting the frozen body, or
;; retrying -- because that would turn a provider miss into a client
;; drift as well.  So a miss is recorded and nothing else.

(defconst harness-replay--last-decisions (make-hash-table :test 'equal)
  "The last prefix decision of each session, for reading a miss against.")

(defun harness-replay-note-decision (id info)
  "Remember INFO, the `replay/prefix' decision of session ID."
  (when (and (stringp id) (listp info))
    (puthash id info harness-replay--last-decisions)))

(defun harness-replay-miss-after-identical-prefix-p (id)
  "Non-nil when session ID's last request sent a spliced prefix.
It says only that the bytes went out as they had before; whether the
provider had them cached is not something the harness can know."
  (eq (plist-get (gethash id harness-replay--last-decisions) :decision)
      'spliced))

(harness-defmethod replay/miss-note (id info)
  "Record that session ID's provider missed on INFO, a `cache/reuse'.
When the last request spliced an unchanged prefix, the miss is the
provider's: it is logged as such, and **nothing is re-sent, re-rendered
or reset** for it.  Return `provider' when the prefix was identical and
`unexplained' when it was not, so a caller can say which it was."
  (let ((identical (harness-replay-miss-after-identical-prefix-p id)))
    (harness-log (if identical 'info 'debug)
                 "replay: %s missed on %s%% of %s tokens after %s"
                 id (round (* 100 (or (plist-get info :ratio) 0)))
                 (or (plist-get info :previous) 0)
                 (if identical "an identical prefix" "a rebuilt one"))
    (if identical 'provider 'unexplained)))
(harness-declare-event 'replay/prefix "(SESSION-ID INFO) for every request whose body the replay module was asked to freeze, saying what it did with the prefix: INFO is (:generation N :decision SYMBOL :reason REASON :divergence PATH :prefix-bytes N :appended-bytes N :metadata N :model M :route R :at TIME).  DECISION is `spliced' when the prompt was re-sent from the kept bytes plus an appended suffix, `fresh' when no kept body applied, and `diverged' when the rebuilt prompt no longer continued it; REASON is why, one of `harness-replay-frozen-reset-reasons', or `diverged'.  Nothing in INFO is a prompt's text or a digest of one, so a cache miss can be diagnosed from it without a prompt ever being kept for that purpose.")

(harness-define-module 'replay
  :doc "Keeps what a session's model was sent: the responses it made, the payload of its last request, and the exact body of the final request field by field, so that a restart, a change of the rendering code and a change of the adapter's serialization keep the prompt cache; a body that changed with no recorded reset is refused before it is sent."
  :requires '(store session)
  :init #'harness-replay--init)

(provide 'harness-replay)
;;; harness-replay.el ends here
