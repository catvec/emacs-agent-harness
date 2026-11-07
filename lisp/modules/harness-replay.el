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
;; The files are the session's, in the state directory:
;; sessions/ID.responses.jsonl, one response a line, and
;; sessions/ID.request.jsonl, one JSON document.  The document is read
;; losslessly (`harness-replay--read'): the harness's own reading of
;; JSON maps an empty object and an empty array to nil both, and a
;; request written again with null where it had {} or [] is not the
;; request the provider cached.

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
kept for a request that names no session, one whose messages hold a
picture's bytes, or one over `harness-replay-request-max-bytes'."
  (let* ((session (plist-get request :session))
         (id (plist-get session :id))
         (messages (plist-get request :messages)))
    (when (and (stringp id) (consp messages)
               (not (harness-replay--image-data-p messages)))
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
    (when (and hit (not dry-run))
      (harness-replay--forget-memory id))
    (list :count count :files (nreverse files))))

(defun harness-replay--on-session-deleted (id &rest _)
  "Delete what is kept for the session ID that is gone."
  (ignore-errors (harness-call 'replay/forget id)))

(defun harness-replay--on-compaction (id &rest _)
  "Drop the last request of session ID: the conversation it was made of is gone.
The request that follows is rendered from the compaction, and its
payload kept again."
  (ignore-errors
    (harness-call 'store/delete (harness-replay--request-name id))))

;;;; Module

(defun harness-replay--init ()
  "Subscribe to what makes a kept payload wrong: a deletion, a compaction."
  (harness-on 'session/deleted #'harness-replay--on-session-deleted)
  (harness-on 'compaction/done #'harness-replay--on-compaction))

(harness-define-module 'replay
  :doc "Keeps what a session's model was sent: the responses it made and the payload of its last request, so that a restart and a change of the rendering code keep the prompt cache."
  :requires '(store session)
  :init #'harness-replay--init)

(provide 'harness-replay)
;;; harness-replay.el ends here
