;;; harness-util.el --- Small shared helpers for the harness  -*- lexical-binding: t; -*-

;;; Commentary:

;; JSON conventions used everywhere in the harness:
;;
;; - Parsed JSON objects are plists with keyword keys, arrays are
;;   lists, `null' is nil and `false' is `:false'.
;; - When encoding, a list whose first element is a keyword is an
;;   object, any other list is an array, `nil' is null, `t' is true,
;;   `:false' is false, `:empty' is an empty object, and vectors are
;;   arrays.  Use `harness-json-array' for an empty array.
;; - `harness-json-encode' returns bytes for a process, a file or an
;;   HTTP body: since Emacs 30 `json-serialize' gives unibyte UTF-8.
;;   JSON that goes inside other text (a prompt, a tool result) or
;;   inside other JSON as a string value comes from
;;   `harness-json-encode-text': the bytes would turn into raw-byte
;;   characters there, which the next `json-serialize' rejects.
;; - A string can hold a raw byte: binary data read as if it were
;;   text -- `cat' of a JPEG into a tool result, say -- which looks
;;   like ordinary Lisp text until `json-serialize' refuses the whole
;;   value for it.  `harness-json-encode' repairs that rather than
;;   fail (see `harness-valid-text'), since nothing downstream given
;;   no answer at all can tell that from a provider or a UI that will
;;   never get one and waits forever; a tool result is also cleaned at
;;   the source (`harness-tools--normalise-result'), so the repair
;;   mostly shows up only where that cannot reach: a title, a prompt,
;;   a transcript already holding one.
;;
;; Everything else here is plumbing: ids, time, paths and formatting.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)

;;;; JSON

(defun harness--json-prepare (obj)
  "Convert OBJ from the harness plist convention into `json-serialize' input."
  (cond
   ((null obj) :null)
   ((eq obj t) t)
   ((eq obj :false) :false)
   ((eq obj :null) :null)
   ((eq obj :empty) (make-hash-table :test 'equal :size 1))
   ((stringp obj) obj)
   ((numberp obj) obj)
   ((symbolp obj) (symbol-name obj))
   ((hash-table-p obj)
    (let ((h (make-hash-table :test 'equal :size (hash-table-count obj))))
      (maphash (lambda (k v) (puthash (if (symbolp k) (string-remove-prefix ":" (symbol-name k)) k)
                                      (harness--json-prepare v) h))
               obj)
      h))
   ((vectorp obj) (apply #'vector (mapcar #'harness--json-prepare (append obj nil))))
   ((and (consp obj) (keywordp (car obj)))
    (let ((h (make-hash-table :test 'equal :size (/ (length obj) 2))))
      (cl-loop for (k v) on obj by #'cddr
               do (puthash (string-remove-prefix ":" (symbol-name k))
                           (harness--json-prepare v) h))
      h))
   ((consp obj)
    ;; Improper lists such as (2 . 30) become two-element arrays.
    (let (items)
      (while (consp obj) (push (harness--json-prepare (car obj)) items) (setq obj (cdr obj)))
      (when obj (push (harness--json-prepare obj) items))
      (apply #'vector (nreverse items))))
   (t (format "%s" obj))))

(defconst harness--raw-byte-re "[\x3fff80-\x3fffff]"
  "Regexp matching one raw byte: a byte read as text that is not real text.
A buffer or a string in Emacs holds such a byte, outside ASCII, as one
character in this range rather than refuse it (Info node `(elisp) Text
Representations'); it looks like an ordinary character until something
checks the text is valid Unicode and refuses it, `json-serialize' and
so `harness-json-encode' among them.")

(defun harness--valid-text-repair (string)
  "Replace every raw byte of multibyte STRING with U+FFFD.
See `harness-valid-text'."
  ;; Not `replace-regexp-in-string': on a multibyte string each match
  ;; from an index converts characters to bytes from the start, so a
  ;; long string with many raw bytes took time quadratic in its length
  ;; (a few megabytes of transcript wedged the server for good).
  (if (string-match-p harness--raw-byte-re string)
      (with-temp-buffer
        (insert string)
        (goto-char (point-min))
        (while (re-search-forward harness--raw-byte-re nil t)
          (replace-match "�" t t))
        (buffer-string))
    string))

(defun harness-valid-text (string)
  "Return STRING as valid Unicode text, repairing any raw byte in it.
A tool, a buffer or a process can hand back raw bytes that only look
like text -- `cat' of a binary file, say, or a transcript that already
holds some -- which is ordinary Lisp text until something, such as
`json-serialize', checks it is valid Unicode and refuses the whole
value for it.  A unibyte STRING outside ASCII is decoded as UTF-8
first, recovering the real characters of any well-formed run in it;
what is left invalid, in STRING or after that, is one raw byte per
character, each replaced with the replacement character, U+FFFD.
Return STRING itself, without copying, when it already is valid: a
multibyte string with no raw byte, or a unibyte one that is plain
ASCII, which is both already and needs no decoding."
  (cond
   ((multibyte-string-p string) (harness--valid-text-repair string))
   ((string-match-p "[^[:ascii:]]" string) (harness--valid-text-repair (decode-coding-string string 'utf-8)))
   (t string)))

(defun harness--json-clean (value)
  "Return VALUE, already in `json-serialize' form, with every string repaired.
VALUE is what `harness--json-prepare' gives: a hash table, a vector, a
string, or something else `json-serialize' already takes as it is.
Walked recursively, with `harness-valid-text' applied to each string;
see `harness-json-encode'."
  (cond
   ((stringp value) (harness-valid-text value))
   ((hash-table-p value)
    (let ((h (make-hash-table :test 'equal :size (hash-table-count value))))
      (maphash (lambda (k v) (puthash k (harness--json-clean v) h)) value)
      h))
   ((vectorp value) (apply #'vector (mapcar #'harness--json-clean (append value nil))))
   (t value)))

(defun harness-json-encode (obj)
  "Encode OBJ (plist/list convention, see Commentary) as a JSON string.
Since Emacs 30 the string is unibyte, the UTF-8 bytes, ready for a
process, a file or an HTTP body.  Use `harness-json-encode-text' for
JSON that goes inside other text or inside other JSON.

Never fails on a raw byte: a string of OBJ can hold one -- binary data
read as if it were text, somewhere upstream that could not clean it at
the source -- which makes `json-serialize' refuse the whole value,
signalling `wrong-type-argument' with `json-value-p' naming it.  OBJ is
then repaired with `harness-valid-text' (see `harness--json-clean') and
encoded again: logged, short, rather than left to signal, since a
provider or a UI given no answer at all because of one bad string deep
inside OBJ waits for it for good.  Any other failure to encode still
signals."
  (let ((prepared (harness--json-prepare obj)))
    (condition-case err
        (json-serialize prepared)
      (wrong-type-argument
       (if (eq (nth 1 err) 'json-value-p)
           (progn
             (when (fboundp 'harness-log)
               (harness-log 'warn "json: a value had a raw byte invalid as UTF-8; repaired it to encode"))
             (json-serialize (harness--json-clean prepared)))
         (signal (car err) (cdr err)))))))

(defun harness-json-encode-text (obj)
  "Encode OBJ like `harness-json-encode', as text rather than bytes.
The result is a multibyte string of characters, so it can be put into
other text with `format' or `concat', and into other JSON as a string
value.  The bytes `harness-json-encode' returns would turn into
raw-byte characters there (\"\\342\\234\\227\" for U+2717), which
`json-serialize' rejects."
  (let ((json (harness-json-encode obj)))
    (if (multibyte-string-p json) json (decode-coding-string json 'utf-8-unix))))

(defun harness-json-parse (string)
  "Parse JSON STRING into the plist convention.  Return nil on empty input."
  ;; Not `string-trim': its search for trailing whitespace takes time
  ;; quadratic in a long run of spaces inside STRING.
  (unless (or (null string) (string-blank-p string))
    (json-parse-string string :object-type 'plist :array-type 'list
                       :null-object nil :false-object :false)))

(defun harness-json-parse-buffer ()
  "Parse the JSON value after point in the current buffer, advancing point."
  (json-parse-buffer :object-type 'plist :array-type 'list
                     :null-object nil :false-object :false))

(defun harness-json-array (list)
  "Return LIST as a vector so it encodes as a JSON array even when empty."
  (apply #'vector list))

(defun harness-json-true-p (value)
  "Non-nil when parsed JSON VALUE is truthy (not nil and not :false)."
  (and value (not (eq value :false))))

(defun harness-setting-equal-p (key a b)
  "Non-nil when A and B are the same value of session setting KEY.
Values may come over JSON: `:non-interactive' compares as a boolean
\(nil, `:false' and an absent value are all off), and a symbol equals
its name, as a permission mode is a symbol in a session and a string
in a request.  Anything else compares with `equal'."
  (let ((name (lambda (v) (if (and v (symbolp v) (not (keywordp v))) (symbol-name v) v))))
    (if (eq key :non-interactive)
        (eq (and (harness-json-true-p a) t) (and (harness-json-true-p b) t))
      (equal (funcall name a) (funcall name b)))))

;;;; Plists

(defun harness-plist-get-in (plist path)
  "Get the value at PATH (a list of keywords) inside nested PLIST."
  (let ((v plist))
    (dolist (k path v)
      (setq v (and (listp v) (plist-get v k))))))

(defun harness-plist-merge (&rest plists)
  "Merge PLISTS left to right; later keys win.  Return a fresh plist."
  (let (out)
    (dolist (pl plists)
      (cl-loop for (k v) on pl by #'cddr
               do (setq out (plist-put out k v))))
    out))

(defun harness-plist-remove (plist &rest keys)
  "Return a copy of PLIST without KEYS."
  (let (out)
    (cl-loop for (k v) on plist by #'cddr
             unless (memq k keys) do (setq out (plist-put out k v)))
    out))

(defun harness-plist-keys (plist)
  "Return the keys of PLIST."
  (cl-loop for (k _) on plist by #'cddr collect k))

(defun harness-alist-to-plist (alist)
  "Convert ALIST with symbol or string keys into a keyword plist."
  (let (out)
    (dolist (cell alist out)
      (let ((k (car cell)))
        (setq out (plist-put out (if (keywordp k) k
                                   (intern (concat ":" (if (symbolp k) (symbol-name k) k))))
                             (cdr cell)))))))

;;;; Ids and time

(defun harness-uuid ()
  "Return a random version 4 UUID string."
  (let ((f (lambda (n) (random (expt 2 n)))))
    (format "%08x-%04x-4%03x-%04x-%012x"
            (funcall f 32) (funcall f 16) (funcall f 12)
            (logior #x8000 (funcall f 14)) (funcall f 48))))

(defun harness-short-id (&optional len)
  "Return a short random alphanumeric id of LEN characters (default 8)."
  (let ((chars "abcdefghijklmnopqrstuvwxyz0123456789") (out ""))
    (dotimes (_ (or len 8) out)
      (setq out (concat out (string (aref chars (random (length chars)))))))))

(defun harness-now ()
  "Return the current time as a float."
  (float-time))

(defun harness-iso-time (&optional time)
  "Format TIME (default now) as an ISO 8601 UTC string."
  (format-time-string "%Y-%m-%dT%H:%M:%SZ" time t))

(defun harness-relative-time (time)
  "Describe TIME (float seconds) relative to now, like \"3m ago\"."
  (let ((d (- (float-time) time)))
    (cond ((< d 5) "just now")
          ((< d 60) (format "%ds ago" (truncate d)))
          ((< d 3600) (format "%dm ago" (truncate (/ d 60))))
          ((< d 86400) (format "%dh ago" (truncate (/ d 3600))))
          ((< d (* 7 86400)) (format "%dd ago" (truncate (/ d 86400))))
          (t (format-time-string "%Y-%m-%d" time)))))

(defun harness-format-duration (seconds)
  "Format SECONDS as a compact duration."
  (cond ((< seconds 1) (format "%dms" (truncate (* seconds 1000))))
        ((< seconds 60) (format "%.1fs" seconds))
        ((< seconds 3600) (format "%dm%02ds" (truncate (/ seconds 60)) (truncate (mod seconds 60))))
        (t (format "%dh%02dm" (truncate (/ seconds 3600)) (truncate (/ (mod seconds 3600) 60))))))

;;;; Formatting

(defun harness-format-tokens (n)
  "Format token count N compactly: 950, 12.3k, 1.2M."
  (let ((n (or n 0)))
    (cond ((< n 1000) (format "%d" n))
          ((< n 100000) (format "%.1fk" (/ n 1000.0)))
          ((< n 1000000) (format "%dk" (round (/ n 1000.0))))
          (t (format "%.2fM" (/ n 1000000.0))))))

(defun harness-format-tokens-compact (n)
  "Format token count N as `harness-format-tokens' does, but \"96k\" for \"96.0k\".
Whole thousands read without the decimal part, which a hint about a
window or a limit is easier to read as."
  (replace-regexp-in-string "\\.0+\\([kM]\\)\\'" "\\1" (harness-format-tokens n)))

(defun harness-format-cost (usd)
  "Format USD amount compactly."
  (let ((usd (or usd 0)))
    (cond ((zerop usd) "$0")
          ((< usd 0.01) (format "$%.4f" usd))
          ((< usd 1) (format "$%.3f" usd))
          (t (format "$%.2f" usd)))))

;;;; Billing

(defun harness-billing-of (usage)
  "Return how USAGE was paid: `api', `subscription', `extra-usage' or nil.
USAGE is a usage record, a session's usage totals or a usage row; the
value may have travelled over the wire as a string.  nil means the
provider did not say, which reads as per-token billing."
  (let ((b (plist-get usage :billing)))
    (cond ((and b (symbolp b) (not (eq b :false))) b)
          ((and (stringp b) (not (string-empty-p b))) (intern b)))))

(defun harness-plan-name (plan)
  "Return the display name of subscription PLAN (\"max\" gives \"Max\"), or nil."
  (and (stringp plan) (not (string-empty-p plan))
       (capitalize (replace-regexp-in-string "_" " " plan))))

(defun harness-usage-list-cost (usage)
  "Return what USAGE costs at API list prices: its `:list-cost', else its `:cost'."
  (let ((list-cost (plist-get usage :list-cost)) (cost (plist-get usage :cost)))
    (float (cond ((numberp list-cost) list-cost) ((numberp cost) cost) (t 0)))))

(defun harness-usage-covered (usage)
  "Return the part of USAGE a subscription paid for, at API list prices."
  (max 0.0 (- (harness-usage-list-cost usage) (float (or (plist-get usage :cost) 0)))))

(defun harness-format-spend (usage)
  "Describe in words what USAGE cost, saying when a subscription paid.
Per-token billing reads \"$1.20\"; usage a plan paid for reads
\"$3.40 at API prices, covered by the Max plan\"."
  (let* ((cost (float (or (plist-get usage :cost) 0)))
         (covered (harness-usage-covered usage))
         (name (harness-plan-name (plist-get usage :plan)))
         (payer (if name (format "the %s plan" name) "the subscription")))
    (cond ((<= covered 0) (harness-format-cost cost))
          ((> cost 0) (format "%s billed, plus %s at API prices covered by %s"
                              (harness-format-cost cost) (harness-format-cost covered) payer))
          (t (format "%s at API prices, covered by %s" (harness-format-cost covered) payer)))))

(defun harness-budget-outside-text (status &optional all)
  "Say what budget STATUS spent that the harness did not record, or nil.
STATUS is a `usage/budget-status' plist.  The text reads \"incl. $5.00
reported by Claude Code, $2.00 baseline\": what providers reported was
billed beyond the harness's records, and who reported it, then the
baseline set by hand.  A reported $0 is left out unless ALL, which
shows that providers were asked; nil when there is nothing to say."
  (let* ((sources (plist-get status :sources))
         (reported (or (plist-get status :reported) 0))
         (baseline (or (plist-get status :baseline) 0))
         (labels (delete-dups
                  (mapcar (lambda (s) (plist-get s :label))
                          (or (seq-filter (lambda (s) (> (or (plist-get s :outside) 0) 0)) sources)
                              sources))))
         (parts (delq nil
                      (list (and labels (or all (> reported 0))
                                 (format "%s reported by %s" (harness-format-cost reported)
                                         (if (cdr labels)
                                             (concat (string-join (butlast labels) ", ") " and " (car (last labels)))
                                           (car labels))))
                            (and (> baseline 0) (format "%s baseline" (harness-format-cost baseline)))))))
    (and parts (concat "incl. " (string-join parts ", ")))))

(defun harness-format-bytes (n)
  "Format byte count N as a human readable size."
  (file-size-human-readable (or n 0) 'iec " "))

(defun harness-truncate-middle (string max)
  "Shorten STRING to at most MAX characters by eliding the middle."
  (if (<= (length string) max)
      string
    (let* ((ell "…")
           (keep (- max (length ell)))
           (head (ceiling keep 2))
           (tail (floor keep 2)))
      (concat (substring string 0 head) ell (substring string (- (length string) tail))))))

(defun harness-truncate-end (string max)
  "Shorten STRING to at most MAX characters, eliding the end."
  (if (<= (length string) max) string
    (concat (substring string 0 (max 0 (1- max))) "…")))

(defun harness-first-line (string &optional max)
  "Return the first non-blank line of STRING, truncated to MAX characters."
  (let* ((lines (split-string (or string "") "\n" t "[ \t]+"))
         (line (or (car lines) "")))
    (if max (harness-truncate-end line max) line)))

(defun harness-estimate-tokens (string)
  "Cheap token estimate for STRING (about four characters per token)."
  (ceiling (length (or string "")) 4))

;;;; Senders
;;
;; A user message the user did not write says who sent it: its node's
;; `:meta' holds `:from', a sender plist.  Kind `system' is the harness
;; itself, with `:source' naming the part of it that sent the message
;; ("tasks", "merge queue"); kind `session' is the agent of another
;; session, with its `:id' and its `:name' at the time.  No `:from'
;; means the user wrote the message.  The kind may have travelled as a
;; string (over the wire, or through a node log), so read it with
;; `harness-sender-kind'.

(defun harness-sender-system (source)
  "Return the sender of a message the harness sends on its own.
SOURCE names the part of the harness that sends it, in words people
read, such as \"tasks\" or \"merge queue\"."
  (list :kind 'system :source source))

(defun harness-sender-session (session)
  "Return the sender of a message the agent of SESSION (a plist) sends."
  (list :kind 'session :id (plist-get session :id) :name (plist-get session :name)))

(defun harness-sender-kind (from)
  "Return the kind of sender FROM, `system' or `session', or nil.
FROM is who sent a message (see `harness-node-sender'); nil, or a value
without a kind, means the user did."
  (let ((kind (and (consp from) (plist-get from :kind))))
    (cond ((and (stringp kind) (not (string-empty-p kind))) (intern kind))
          ((and kind (symbolp kind) (not (eq kind :false))) kind))))

(defun harness-node-sender (node)
  "Return who sent NODE, a user message, when it was not the user, or nil.
That is NODE's `:meta' `:from': (:kind system :source SOURCE) for the
harness itself, made by `harness-sender-system', or (:kind session :id
ID :name NAME) for another session's agent, made by
`harness-sender-session'."
  (let ((from (plist-get (plist-get node :meta) :from)))
    (and (harness-sender-kind from) from)))

(defun harness-outside-node-p (node)
  "Non-nil when NODE is a tool call or result the session's model did not make.
The harness records some of the work it does for a session on its own
as a tool call and its result in the session's transcript, so that it
shows like the session's own: the merge queue's conflict resolver shows
as a spawn_agent call in the session whose branch it merges.  Such a
node says who recorded it as its `:meta' `:from', a sender (see
`harness-node-sender').  The model never asked for the call, so it is
not part of the conversation: `session/messages' and a handoff leave
it out, and nothing waits for its result."
  (and (member (plist-get node :kind) '(tool-call tool-result "tool-call" "tool-result"))
       (harness-node-sender node)
       t))

(defun harness-sender-description (from)
  "Describe FROM, who sent a message, in a few words, as transcripts read.
The harness reads \"the harness (SOURCE)\", another session's agent
\"session ID \\\"NAME\\\"\", and nil, the user, \"the user\"."
  (pcase (harness-sender-kind from)
    ('system (let ((source (plist-get from :source)))
               (if (and (stringp source) (not (string-blank-p source)))
                   (format "the harness (%s)" source)
                 "the harness")))
    ('session (format "session %s%s" (or (plist-get from :id) "?")
                      (if (and (stringp (plist-get from :name)) (not (string-blank-p (plist-get from :name))))
                          (format " %S" (plist-get from :name))
                        "")))
    ('nil "the user")
    (kind (format "the %s" kind))))

;;;; Thinking levels

(defconst harness-thinking-level-order
  '("none" "minimal" "low" "medium" "high" "xhigh" "max")
  "Every thinking level the harness knows, weakest first.
A model offers some of these (its `:thinking-levels'), and whatever has
to order levels or tell which of two is stronger -- the thinking menu,
the level a BTW is given, the effort a provider asks a model for --
goes by this one list, so there is a single idea of what is stronger.
A level that is not in it ranks after all that are (see
`harness-thinking-level-rank').")

(defun harness-thinking-level-rank (level)
  "Return how strong thinking LEVEL is, as a number: a higher one thinks harder.
That is its place in `harness-thinking-level-order'.  A level that is
not there ranks after every one that is."
  (or (cl-position level harness-thinking-level-order :test #'equal)
      most-positive-fixnum))

(defun harness-thinking-level-fit (level levels)
  "Return the one of thinking LEVELS that stands for LEVEL, or nil.
This is the one rule the harness fits a level to what a model offers
by: a BTW's level, the reasoning effort Copilot is asked for and the
effort Bedrock's adaptive models are asked for all go through it, so
that nothing thinks harder than it was asked to.  LEVELS are what a
model offers (its `:thinking-levels').  That is LEVEL itself when
LEVELS has it; else the strongest of LEVELS weaker than LEVEL, the
nearest the model comes to it without thinking harder; else, every one
of LEVELS being stronger, the weakest of them.  Strength is that of
`harness-thinking-level-order': a level that is not in it ranks after
every one that is.  Entries of LEVELS that are not strings are ignored.
nil when LEVEL is not a string or LEVELS has no string."
  (let ((levels (cl-remove-if-not #'stringp levels)))
    (when (and (stringp level) levels)
      (if (member level levels)
          level
        (let* ((rank (harness-thinking-level-rank level))
               ;; Weakest first, the order of LEVELS kept among equals.
               (sorted (sort (copy-sequence levels)
                             (lambda (a b) (< (harness-thinking-level-rank a)
                                              (harness-thinking-level-rank b)))))
               (weaker (cl-remove-if-not (lambda (l) (< (harness-thinking-level-rank l) rank))
                                         sorted)))
          (if weaker (car (last weaker)) (car sorted)))))))

;;;; Models and provider state
;;
;; A model id is "PROVIDER:NAME".  A session's provider state (the CLI
;; session id Claude Code resumes, say) belongs to the provider that
;; wrote it and says so as `:provider', a string as it travels through
;; JSON anyway: another provider cannot continue it.  A state written
;; before states named their provider has no `:provider'; see
;; `session/provider-state' for how such a state is attributed.  A user
;; message the harness wrote to hand a conversation over to a model of
;; another provider says so in its `:meta' `:handoff'.

(defun harness-model-provider (model-id)
  "Return the provider of MODEL-ID, \"PROVIDER:NAME\", as a symbol, or nil."
  (and (stringp model-id)
       (string-match "\\`\\([a-z0-9_-]+\\):." model-id)
       (intern (match-string 1 model-id))))

(defun harness-provider-state-owner (state)
  "Return the provider that provider STATE names as its own, a symbol, or nil.
Nil for no state, and for a state written before states named their
provider."
  (let ((p (and (consp state) (plist-get state :provider))))
    (cond ((and (stringp p) (not (string-empty-p p))) (intern p))
          ((and p (symbolp p) (not (memq p '(t :false :null)))) p))))

(defun harness-tag-provider-state (state model-id)
  "Return provider STATE marked as belonging to the provider of MODEL-ID.
A state of no provider, or MODEL-ID naming none, is returned as it is."
  (let ((provider (harness-model-provider model-id)))
    (if (and (consp state) provider)
        (append (harness-plist-remove state :provider)
                (list :provider (symbol-name provider)))
      state)))

(defun harness-node-handoff (node)
  "Return the handoff NODE records, a plist, or nil.
A user message the harness wrote to carry a conversation over to a
model of another provider holds (:mode transcript|compact :file PATH
:from MODEL :to MODEL) in its `:meta' `:handoff'."
  (let ((h (plist-get (plist-get node :meta) :handoff)))
    (and (consp h) h)))

(defun harness-node-compaction-kind (node)
  "Return the kind of compaction NODE is, as a string, or nil for no compaction.
That is its `:meta' `:compaction': \"summary\", \"brief\" (a summary of the
conversation's narrative, tool calls in brief), \"transcript\" (a note
pointing at
the conversation written to the file of its `:meta' `:file'),
\"fresh\" (a note saying nothing of the conversation was carried over)
or \"truncate\" (a note saying the oldest nodes were cut).  A
compaction node from before there were kinds is a \"summary\"; so is
one a handoff's old model wrote, while the new model's is \"brief\".
NODE's kind may be the symbol or, as a client hears it, its name."
  (when (equal (format "%s" (plist-get node :kind)) "compaction")
    (let* ((meta (plist-get node :meta))
           (kind (plist-get meta :compaction)))
      (cond ((and kind (symbolp kind) (not (memq kind '(t :null :false)))) (symbol-name kind))
            ((and (stringp kind) (not (string-empty-p kind))) kind)
            ((equal (format "%s" (plist-get meta :context)) "sample") "brief")
            (t "summary")))))

;;;; Notes of lasting permission answers
;;
;; An answer to a permission request that holds beyond the call (for
;; the session, or always) records a rule or grants a directory.  The
;; harness then writes a hint into the session's transcript, which the
;; chat shows under the call, and which says in its `:meta'
;; `:permission' what the answer recorded, so that it can be undone
;; (`permission/undo').

(defun harness-node-permission (node)
  "Return what the lasting permission answer NODE notes recorded, or nil.
NODE is the hint the harness writes after an answer for the session
or always.  Its `:meta' `:permission' holds (:scope session|always
:rule RULE) for a rule (see `harness-perms-rules'), or (:scope
session|always :dir DIR) for a directory granted, DIR as the grant
keeps it.  `:undo' is `offered' while the answer can still be undone,
then how its undo went, `undone', `changed' or `gone', with `:result'
saying so in a sentence; there is none when the answer recorded
nothing new.  Symbols may have travelled as strings."
  (let ((p (plist-get (plist-get node :meta) :permission)))
    (and (consp p) p)))

(defun harness-permission-undo-state (record)
  "Return the `:undo' of RECORD, a symbol, or nil.
RECORD is what `harness-node-permission' returns."
  (let ((u (and (consp record) (plist-get record :undo))))
    (cond ((and (stringp u) (not (string-empty-p u))) (intern u))
          ((and u (symbolp u) (not (memq u '(t :false :null)))) u))))

;;;; Lasting decisions
;;
;; An answer that lasts -- a permission answer for the session or
;; always, an "always" answer to the cold-cache question -- is a
;; decision the harness keeps (harness-decisions.el), with an undo and
;; a redo.  A note refers to one by its id: the note that tells of the
;; decision where it was made holds it in its `:meta' `:decision', and a
;; hint or tool result written later where the decision took effect, in
;; any session, in its `:meta' `:decided-by'.

(defconst harness-decision-states '(done undone changed gone)
  "Where a lasting decision stands.
`done' while what it changed is in effect, so it can be undone;
`undone' once it was taken back, so it can be redone; `changed' or
`gone' once what it changed was changed by something else or is no
longer there, so it offers nothing more.")

(defun harness-decision-state (value)
  "Return the decision state VALUE names, a symbol, or nil.
VALUE may have travelled over JSON, as a string; anything that is no
state in `harness-decision-states' is nil."
  (let ((s (cond ((and (stringp value) (not (string-empty-p value))) (intern-soft value))
                 ((and value (symbolp value) (not (keywordp value))) value))))
    (and (memq s harness-decision-states) s)))

(defun harness--node-meta-id (node key)
  "Return the id NODE's `:meta' holds under KEY, a non-empty string, or nil."
  (let ((id (plist-get (plist-get node :meta) key)))
    (and (stringp id) (not (string-empty-p id)) id)))

(defun harness-node-decision (node)
  "Return the id of the lasting decision NODE tells of, or nil.
NODE is the note written where the decision was made, such as the
hint after a permission answer for the session or always."
  (harness--node-meta-id node :decision))

(defun harness-node-decided-by (node)
  "Return the id of the lasting decision that made NODE happen, or nil.
NODE is a hint or a tool result written where a decision made earlier,
perhaps in another session, took effect: a cold cache compacted
unasked as the default it set says, or a call its rule denied."
  (harness--node-meta-id node :decided-by))

;;;; The note of the session judge

;; A new session's opening message may be judged -- read by a cheap model
;; that says whether the job is a supervising one or a hands-on one
;; (harness-supervisor.el).  The harness then writes a hint into the
;; session's transcript saying how the message was read, in its own
;; voice, and the hint holds in its `:meta' `:supervisor' what the chat's
;; buttons act on: the two things the user can do about the choice, and
;; how far each has got.  `harness-node-supervisor' reads it, the chat
;; draws the buttons from it (harness-ui-chat.el), and `supervisor/act'
;; is what they call.

(defun harness-node-supervisor (node)
  "Return the session judge's note record of NODE, or nil.
NODE is the hint written when a session's opening message was judged.
Its `:meta' `:supervisor' holds

  (:judged t|:false   ; what the judge read; absent when it gave no answer
   :model MODEL       ; the model that read the message
   :mode t|:false     ; the mode the note left the session in
   :setting KEY       ; the setting that decides how sessions start
   :cwd DIR           ; where that setting is written
   :actions ACTIONS)  ; (:action NAME :label LABEL :help HELP :state STATE)

where each action's STATE is nil while it was not taken, `done' once it
was, and `undone' once it was taken back, and NAME, with \"always\" and
\"mode\" the two of them, is what `supervisor/act' is asked to do.
Names, labels and symbols may have travelled as strings; the states read
back as symbols."
  (let ((record (plist-get (plist-get node :meta) :supervisor)))
    (when (and (consp record) (plist-get record :actions))
      (plist-put (copy-sequence record) :actions
                 (mapcar (lambda (action)
                           (plist-put (copy-sequence action) :state
                                      (harness-supervisor-note-state (plist-get action :state))))
                         (plist-get record :actions))))))

(defun harness-supervisor-note-state (value)
  "Return the judge's note action state VALUE names, a symbol, or nil.
VALUE may have travelled over JSON, as a string."
  (let ((s (cond ((and (stringp value) (not (string-empty-p value))) (intern value))
                 ((and value (symbolp value) (not (memq value '(t :false :null)))) value))))
    (and (memq s '(done undone)) s)))

;;;; Hints that fold

;; Something the harness has to say again and again -- the machine's
;; load moving the tool slots up and down (harness-tool-slots-load.el)
;; -- would fill a transcript with hints.  The part of the harness that
;; says it keeps what it said in one hint instead and adds to it as
;; there is more to say.  That hint holds in its `:meta' `:fold' the
;; title it shows folded and the lines under it, and the chat draws it
;; as one line that opens to them (harness-ui-chat.el).  Its `:content'
;; says the same in plain text, the title and then a line to an item,
;; for whatever does not know the fold.

(defun harness-node-fold (node)
  "Return what the folding hint NODE holds, or nil for any other node.
That is the `:meta' `:fold' of NODE:

  (:key KEY      ; the part of the harness that writes it, which finds
                 ; the hint again to add to it
   :title TITLE  ; what the hint says while it is folded
   :items ITEMS) ; the lines under it, oldest first, each (:ts TIME :text TEXT)

An item with no text is left out, and a hint with no title or no item
is no fold.  Strings and numbers may have travelled over JSON."
  (let ((fold (plist-get (plist-get node :meta) :fold)))
    (when (and (consp fold) (keywordp (car fold)))
      (let ((title (plist-get fold :title))
            (items (delq nil
                         (mapcar (lambda (item)
                                   (let ((text (and (consp item) (plist-get item :text)))
                                         (ts (and (consp item) (plist-get item :ts))))
                                     (and (stringp text) (not (string-empty-p text))
                                          (list :ts (and (numberp ts) ts) :text text))))
                                 (let ((items (plist-get fold :items)))
                                   (and (sequencep items) (append items nil)))))))
        (when (and (stringp title) (not (string-empty-p title)) items)
          (list :key (plist-get fold :key) :title title :items items))))))

;;;; Messages
;;
;; A message is content blocks: text, images, files, and the text of an
;; attachment such as a task.  The compose box's attachments become
;; blocks through `harness-attachments-to-blocks', and the node that
;; records a user message reads as the text `harness-blocks-text' makes
;; of its blocks, keeping those that are not text.  The agent records
;; messages so (harness-agent.el); a UI that draws a message before it
;; goes -- a queued one -- reads it as the same node
;; (`harness-queued-message-node'), so it looks as it will once sent.

(defun harness-image-label (block)
  "Return the label of image BLOCK (image 1), or nil when it has none.
The compose box labels the images it attaches and puts their tokens,
[image 1], in the message's text."
  (let ((label (and (equal (plist-get block :type) "image") (plist-get block :label))))
    (and (stringp label) (not (string-empty-p label)) label)))

(defun harness-names-file-p (text name)
  "Non-nil when TEXT holds an @ reference to a file called NAME.
That is a word of its own starting with @, whose last part is NAME:
@notes.el, @lisp/notes.el or @~/work/notes.el, but for punctuation
ending a sentence or a bracket after it, as the compose box reads one."
  (and (stringp name) (not (string-empty-p name))
       (let ((case-fold-search nil))
         (string-match-p (concat "\\(?:\\`\\|[ \t\n]\\)@\\(?:[^ \t\n]*/\\)?" (regexp-quote name)
                                 "[]),.;:!?'\"`>}]*\\(?:[ \t\n]\\|\\'\\)")
                         text))))

(defun harness-attached-text-p (block)
  "Non-nil when BLOCK is the text of an attachment, such as a task attached.
The compose box marks it (`harness-compose-attachment-block'), and so does
`harness-attachments-to-blocks'."
  (and (equal (plist-get block :type) "text") (plist-get block :attached)))

(defun harness-blocks-text (blocks)
  "Return the plain text of BLOCKS for a transcript node.
An image reads [image], or its token, [image 1], when it has a label;
nothing when the text holds its token already, as the compose box's
does.  A file reads @ and its name, nothing when the text has an @
reference to it already, as the compose box's does.  The replies in
threads (`harness-thread-block-p') follow the words, and the text of an
attachment (`harness-attached-text-p') follows them, each a paragraph
apart, rather than running on from the user's words: a quote starts a
line."
  (let* ((attached (cl-remove-if-not #'harness-attached-text-p blocks))
         (threads (cl-remove-if-not #'harness-thread-block-p blocks))
         (blocks (cl-remove-if (lambda (b) (or (harness-attached-text-p b) (harness-thread-block-p b))) blocks))
         (text (mapconcat (lambda (b) (if (equal (plist-get b :type) "text") (or (plist-get b :text) "") ""))
                          blocks " "))
         (words (mapconcat
                 #'identity
                 (delq nil (mapcar (lambda (b)
                                     (pcase (plist-get b :type)
                                       ("text" (plist-get b :text))
                                       ("file" (let ((name (file-name-nondirectory (or (plist-get b :path) ""))))
                                                 (unless (harness-names-file-p text name)
                                                   (format "@%s" name))))
                                       ("image" (let ((label (harness-image-label b)))
                                                  (cond ((null label) "[image]")
                                                        ((string-search (format "[%s]" label) text) nil)
                                                        (t (format "[%s]" label)))))
                                       ("audio" "[audio]")
                                       (_ "")))
                                   blocks))
                 " ")))
    (mapconcat #'identity
               (cl-remove-if #'string-empty-p
                             (cons words (delq nil (mapcar (lambda (b) (plist-get b :text))
                                                           (append threads attached)))))
               "\n\n")))

(defun harness-attachments-to-blocks (attachments)
  "Turn ATTACHMENTS, attachment plists, into content blocks.
A reply in a thread, an attachment with `:thread' and the `:response'
under it, is the text block of that reply (`harness-thread-block').
An image keeps its `:label', which its token in the text names.  An
attachment that carries its own `:text' and no `:path' -- a task the
user attached, say, which is described rather than stored in a file --
is that text as a text block, none when the text is blank, marked
`:attached' so that the transcript sets it apart from the user's words
\(`harness-blocks-text')."
  (delq nil
        (mapcar (lambda (a)
                  (let ((mime (or (plist-get a :mime) "")))
                    (cond ((plist-get a :thread)
                           (harness-thread-block (plist-get a :thread) (plist-get a :response)))
                          ((and (stringp (plist-get a :text)) (null (plist-get a :path)))
                           (unless (harness-string-blank-p (plist-get a :text))
                             (list :type "text" :text (plist-get a :text) :attached t)))
                          ((string-prefix-p "image/" mime)
                           (append (list :type "image" :mime mime :path (plist-get a :path))
                                   (and (stringp (plist-get a :label)) (list :label (plist-get a :label)))))
                          ((string-prefix-p "audio/" mime)
                           (list :type "audio" :mime mime :path (plist-get a :path)))
                          (t (list :type "file" :path (plist-get a :path) :size (plist-get a :size)
                                   :mime mime :name (plist-get a :name))))))
                attachments)))

;;;; Threads
;;
;; A THREAD is a reply the user starts on purpose, with C-c >, to a region
;; of something on the screen: part of a message in the chat, several
;; messages, lines of a diff.  The reply is a text block that carries the
;; thread's DATA, a plist, as `:thread':
;;
;;   (:refs (REF ...)          where the reply is from, in order
;;    :response TEXT           what the user wrote under it
;;    :reply (:thread T :comment C)    the thread of the review it follows
;;    :id T :comment C)        set once the review made it a thread
;;
;; A REF says which region, and where it is from.  Of the chat it is
;; (:kind "chat" :node ID :who WHO :label LABEL :from N :to M :text
;; EXCERPT): the node, who wrote it, the offsets of the part in what the
;; node says, and the part itself.  Of a diff it is (:kind "diff" :file F
;; :side "old"|"new" :line L :end E :revision R :text EXCERPT); of any
;; other buffer (:kind "buffer" :name NAME :file F :line L :end E :text
;; EXCERPT).  The keys are single words, so they pass through JSON and the
;; ACP `_harness' extension as they are.
;;
;; The block's `:text' says it all, as a mail does: the quotes of the
;; refs, then the response, then, once the thread is a comment in the
;; review of the task, the thread's marker line -- [thread t-3f2a1b09:
;; answer with review_comment].  That is what the agent reads: it tells
;; the agent the thread to answer in, and with which tool.  A UI that
;; knows threads draws the data -- the card -- instead.  The plain
;; [thread ID] lines of the feedback that sends a task back are another
;; thing, and no marker.

(defconst harness-thread-marker-regexp
  "^[ \t]*\\[thread \\([A-Za-z0-9][A-Za-z0-9_.-]*\\): answer with review_comment\\][ \t]*$"
  "Regexp matching the marker line of a reply that is a comment in a thread.
Group 1 is the thread's id.  See `harness-thread-marker'.")

(defun harness-thread-marker (id)
  "Return the marker line of thread ID, which a reply in that thread ends with."
  (format "[thread %s: answer with review_comment]" id))

(defun harness-thread-marker-ids (text)
  "Return the ids of the threads TEXT names with marker lines, in order.
Nil for a TEXT with none, or that is no string."
  (when (and (stringp text) (string-search "[thread " text))
    (let ((pos 0) (ids nil))
      (while (string-match harness-thread-marker-regexp text pos)
        (push (match-string 1 text) ids)
        (setq pos (match-end 0)))
      (nreverse ids))))

(defun harness-thread-block-p (block)
  "Non-nil when BLOCK is a reply in a thread: a text block with thread data."
  (and (consp block) (equal (plist-get block :type) "text") (plist-get block :thread) t))

(defun harness-thread-ref-kind (ref)
  "Return the kind of REF, a region's reference, as a string: chat, diff or buffer."
  (let ((kind (plist-get ref :kind)))
    (cond ((symbolp kind) (and kind (symbol-name kind)))
          ((stringp kind) kind))))

(defun harness-thread-refs (data)
  "Return the references of the thread DATA, a list of plists, in order.
Whatever a JSON array parsed as, a vector or a list, is a list now."
  (let ((refs (plist-get data :refs)))
    (cl-remove-if-not (lambda (ref) (and (consp ref) (keywordp (car ref))))
                      (if (vectorp refs) (append refs nil) refs))))

(defun harness-thread-normalize (data)
  "Return the thread DATA with its references as a list, as the harness keeps it.
Keys without a value are dropped, so the data reads the same whether it
came over JSON or was made here."
  (let (out)
    (cl-loop for (key value) on data by #'cddr
             do (let ((value (if (eq key :refs)
                                 (mapcar #'harness-thread-normalize (harness-thread-refs data))
                               value)))
                  (when (and value (not (eq value :false)))
                    (push key out)
                    (push value out))))
    (nreverse out)))

(defun harness-thread-line-label (ref)
  "Return the lines REF names as text: \"12\", \"12-15\", or nil without a line."
  (let ((line (plist-get ref :line)) (end (plist-get ref :end)))
    (cond ((not (integerp line)) nil)
          ((and (integerp end) (> end line)) (format "%d-%d" line end))
          (t (format "%d" line)))))

(defun harness-thread-ref-header (ref)
  "Return the line that opens the quote of REF, a region's reference, or nil.
The words of the agent need none: a quote says whose they are.  Anything
else says where the quote is from, as the agent could not tell otherwise:
the message of the user's own, the file and lines of a diff, a buffer."
  (let ((lines (harness-thread-line-label ref)))
    (pcase (harness-thread-ref-kind ref)
      ("diff"
       (let ((revision (and (plist-get ref :revision) (format "%s" (plist-get ref :revision)))))
         (format "In %s%s (%s%s):"
                 (or (plist-get ref :file) "the change")
                 (if lines (format ", line%s %s" (if (string-search "-" lines) "s" "") lines) "")
                 (if (equal (format "%s" (plist-get ref :side)) "old") "before the change" "after the change")
                 (if revision (format ", at %s" (substring revision 0 (min 8 (length revision)))) ""))))
      ("buffer"
       (format "In %s%s:"
               (or (plist-get ref :file) (plist-get ref :name) "a buffer")
               (if lines (format ", line%s %s" (if (string-search "-" lines) "s" "") lines) "")))
      (_ (when (member (format "%s" (plist-get ref :who)) '("you" "user"))
           "My earlier message:")))))

(defun harness-thread-quote-lines (text)
  "Return TEXT as a block quote: \"> \" before each line, \">\" for a blank one."
  (mapconcat (lambda (line) (if (string-blank-p line) ">" (concat "> " line)))
             (split-string (string-trim-right (or text "") "[ \t\n]+") "\n")
             "\n"))

(defun harness-thread-quote (data)
  "Return the quotes of the thread DATA's references, the way a mail quotes.
Each reference is a block quote -- the line that says where it is from
\(`harness-thread-ref-header') first, if it has one -- and a blank line
parts two.  Every line of it starts with \">\": a reader that takes a
reply apart, quotes and answers, finds the quote whole."
  (mapconcat (lambda (ref)
               (let ((text (plist-get ref :text)))
                 (harness-thread-quote-lines
                  (string-join (delq nil (list (harness-thread-ref-header ref)
                                               (and (stringp text) (not (string-blank-p text)) text)))
                               "\n\n"))))
             (harness-thread-refs data) "\n\n"))

(defun harness-thread-text (data)
  "Return the text of a reply in the thread DATA: quotes, response, marker.
The marker line follows once the thread has an `:id'."
  (string-join
   (cl-remove-if #'string-empty-p
                 (list (harness-thread-quote data)
                       (string-trim (let ((response (plist-get data :response))) (if (stringp response) response "")))
                       (if-let* ((id (plist-get data :id))) (harness-thread-marker id) "")))
   "\n\n"))

(defun harness-thread-block (data &optional response)
  "Return the text block of a reply in the thread DATA, with the RESPONSE it holds.
RESPONSE, else DATA's `:response', is what the user wrote under the
quotes.  The block's `:text' is all of the reply as a mail would have it
\(`harness-thread-text'); `:thread' is DATA to draw it from."
  (let ((data (harness-thread-normalize
               (if response (plist-put (copy-sequence data) :response response) data))))
    (list :type "text" :text (harness-thread-text data) :thread data)))

(defun harness-blocks-only-text-p (blocks)
  "Non-nil when every block of BLOCKS is plain text: no picture, no thread.
A node keeps the `:blocks' of a message that is more than its text
\(`harness-agent--only-text-p'): a reply in a thread (`harness-thread-block-p')
is text that has data to draw it from."
  (cl-every (lambda (b) (and (equal (plist-get b :type) "text") (not (harness-thread-block-p b)))) blocks))

(defun harness-thread-response (block)
  "Return what the user wrote in BLOCK, a reply in a thread, under the quotes."
  (let ((response (plist-get (plist-get block :thread) :response)))
    (if (stringp response) response "")))

(defun harness-queued-message-node (item)
  "Return the user node queued ITEM will be once sent, to draw it before.
ITEM is a message waiting in a session's queue (`session/queue'): its
`:text', then its `:attachments' as blocks, read as the agent records a
message (`harness-blocks-text'), and its `:from' when the user did not
write it.  The node has ITEM's `:id'.  The images of messages sent
together are numbered across them as they go (`agent/send-queue'):
ITEM alone keeps its own numbers, as the user wrote them.

ITEM may also be a message that waits for the running turn's next step
\(`session/set-steering'), which holds its content blocks as `:blocks'
when it is more than text: the node then has those, as the turn will
record them."
  (let* ((text (or (plist-get item :text) ""))
         (blocks (or (let ((given (plist-get item :blocks)))
                       (and given (append given nil)))
                     (append (unless (harness-string-blank-p text) (list (list :type "text" :text text)))
                             (harness-attachments-to-blocks (plist-get item :attachments)))))
         (from (plist-get item :from)))
    (append (list :id (plist-get item :id) :kind 'user :content (harness-blocks-text blocks)
                  ;; As the agent's node: the blocks, unless they are all text.
                  :blocks (unless (harness-blocks-only-text-p blocks) blocks))
            (and (harness-sender-kind from) (list :meta (list :from from))))))

;;;; A session that waits for the user

(defun harness-session-waiting-on-user-p (session)
  "Non-nil when SESSION waits for the user to answer something.
SESSION is a session plist, as a method or an event gives it or as a UI
holds it from JSON: its status a symbol or a string, its `:pending' a
list or a vector.  It waits when a request is pending on it -- a
permission, an ask_user question, a question the harness asks itself,
such as the one a message meets when its session's prompt cache went
cold -- or its status says `blocked'.  A session's status is `blocked'
exactly while a request is pending (`session/pending-add'), so the two
say the same: this takes either, so that a view that reads one and a
view that reads the other cannot disagree.  What every view that says
who waits for the user -- the session list's blocked filter, the
mode line's count, the task board's needs-input column, the task slots
-- asks, rather than each deciding for itself."
  (and (listp session)
       (let ((pending (plist-get session :pending)))
         (or (and (seqp pending) (> (length pending) 0))
             (equal (format "%s" (plist-get session :status)) "blocked")))
       t))

;;;; Paths

(defun harness-path-normalize (path)
  "Return PATH expanded and with symlinks resolved when local."
  (let ((expanded (expand-file-name path)))
    (if (file-remote-p expanded)
        expanded
      (condition-case nil (file-truename expanded) (error expanded)))))

(defun harness-path-within-p (dir path)
  "Non-nil when PATH is DIR or lies inside it (after normalisation)."
  (let ((dir (file-name-as-directory (harness-path-normalize dir)))
        (path (harness-path-normalize path)))
    (or (string= (file-name-as-directory path) dir)
        (string-prefix-p dir path))))

;;;;; Remote home directories
;;
;; A TRAMP name whose local part starts with a tilde, /ssh:HOST:~/ or
;; /ssh:HOST:~/src, is in the home directory of the login on HOST, and
;; only HOST knows where that is.  Expanding such a name connects to
;; HOST: `expand-file-name', `file-truename', `file-in-directory-p' and
;; `abbreviate-file-name' (which asks whether the file system is case
;; sensitive) all do.  Expanding its local part as if it were a local name
;; gives the home directory of the user on THIS machine instead.  And
;; `file-remote-p' expands it too, when TRAMP is connected to HOST
;; already, so its local part is the home directory in one moment and
;; "~/" in the next.  The permission chain may do none of this: it may not
;; wait on the network, and what it decides may not depend on whether a
;; connection happens to be open.  So it takes such a name as a place of
;; its own and works on its text, which the functions below do; they are
;; here and not in the permission module because the views draw such
;; names too.  Nothing here connects, expands a name or looks one up.

(declare-function tramp-tramp-file-p "tramp" (name))
(declare-function tramp-dissect-file-name "tramp" (name &optional nodefault))
(declare-function tramp-file-name-localname "tramp" (vec))
(declare-function tramp-make-tramp-file-name "tramp" (&rest args))

(defun harness-remote-parts (name)
  "Return (PREFIX . LOCAL) for NAME, a TRAMP file name, or nil for any other.
PREFIX is NAME up to its local part and LOCAL the local part, both as
they are written: the jump hosts stay in PREFIX (`file-remote-p' leaves
them out), a ~ stays in LOCAL.  The name is read and not expanded: unlike
`file-remote-p', this never turns the ~ of a name into the home directory
of a host TRAMP is connected to."
  (when (and (stringp name) (find-file-name-handler name 'file-remote-p))
    (require 'tramp)
    (condition-case nil
        (when (tramp-tramp-file-p name)
          (let* ((vec (tramp-dissect-file-name name))
                 (local (or (tramp-file-name-localname vec) "")))
            (cons (if (string-suffix-p local name)
                      (substring name 0 (- (length name) (length local)))
                    (tramp-make-tramp-file-name vec 'noloc))
                  local)))
      (error nil))))

(defun harness-remote-home-p (name)
  "Non-nil when NAME is a TRAMP name in a home directory on its host.
That is a remote name whose local part starts with a tilde, such as
/ssh:box:~/ or /ssh:box:~/src/a.el.  Only the host knows where its
home directories are, so nothing here may expand NAME.  Nothing
connects."
  (let ((parts (harness-remote-parts name)))
    (and parts (string-prefix-p "~" (cdr parts)))))

(defun harness-file-remote-p (name &optional identification connected)
  "Like `file-remote-p', but a name in a home directory is not expanded.
`file-remote-p' expands NAME when TRAMP is connected to its host, which
turns a ~ into the home directory there (and may ask the host for it);
this returns what it returns for the same name without a connection:
the host, or with IDENTIFICATION `localname' the local part as written.
See `harness-remote-home-p'.  CONNECTED is as for `file-remote-p'."
  (let ((parts (harness-remote-parts name)))
    (cond ((not (and parts (string-prefix-p "~" (cdr parts))))
           (file-remote-p name identification connected))
          ((eq identification 'localname) (and (not connected) (cdr parts)))
          (t (file-remote-p (concat (car parts) "/") identification connected)))))

(defun harness-remote-prefix (name)
  "Return the TRAMP prefix of remote NAME as it is written, or nil.
That is NAME up to its local part, jump hosts and all
\(\"/ssh:jump|ssh:box:\"): `file-remote-p' leaves the hops out.  Nothing
connects."
  (car (harness-remote-parts name)))

(defun harness-remote-home-parts (name)
  "Return (PREFIX TILDE REST) for NAME, a name in a remote home directory, or nil.
PREFIX is the host's TRAMP prefix (\"/ssh:u@box:\"; see
`harness-remote-prefix'), TILDE the ~ or ~USER the local part starts
with and REST what follows it: empty, or starting with a slash.  See
`harness-remote-home-p'."
  (let* ((parts (harness-remote-parts name))
         (local (cdr parts)))
    (when (and parts (string-match "\\`~[^/]*" local))
      (list (car parts) (match-string 0 local) (substring local (match-end 0))))))

(defun harness-remote-home-tidy-local (local)
  "Return LOCAL, the local part of a name in a remote home, tidied, or nil.
LOCAL starts with ~ or ~USER and goes on with a slash or not at all.
The result has its `.' and `..' resolved and starts with the same
tilde, \"~/\" for the home itself, and keeps a trailing slash.  Nil when
LOCAL is no such local part, or when a `..' leaves the home: where that
goes only the host knows."
  (when (string-match "\\`~[^/]*" local)
    (let* ((tilde (match-string 0 local))
           (rest (substring local (match-end 0)))
           (directory (or (string-empty-p rest) (string-suffix-p "/" rest)
                          (string-suffix-p "/." rest) (string-suffix-p "/.." rest)))
           (stack nil)
           (inside t))
      (dolist (component (split-string rest "/" t))
        (cond ((equal component "."))
              ((equal component "..") (if stack (pop stack) (setq inside nil)))
              (t (push component stack))))
      (when inside
        (concat tilde "/" (string-join (reverse stack) "/") (if (and stack directory) "/" ""))))))

(defun harness-remote-home-tidy (name)
  "Return NAME, in a remote home directory, with `.' and `..' resolved, or nil.
The result is PREFIX~/ for the home itself and PREFIX~/a/b for what lies
in it, a trailing slash kept; nothing is looked up, nothing connects.
Nil when NAME is in no remote home directory, or when a `..' leaves the
home (see `harness-remote-home-tidy-local')."
  (when-let* ((parts (harness-remote-home-parts name))
              (local (harness-remote-home-tidy-local (concat (nth 1 parts) (nth 2 parts)))))
    (concat (car parts) local)))

(defun harness-absolute-file-name (name &optional dir)
  "Return NAME made absolute against DIR, as `expand-file-name' does.
A remote NAME in a home directory is only tidied (`harness-remote-home-tidy'),
since expanding it would connect to its host; NAME comes back as it is
when a `..' leaves the home.  A host with no directory, /ssh:box:, is
its login's home directory to TRAMP, so it comes back as /ssh:box:~/.
A relative NAME against such a DIR is put inside it likewise.  Anything
else is `expand-file-name''s."
  (let ((in-home (and dir (harness-remote-home-p dir)))
        (parts (harness-remote-parts name)))
    (cond
     ((harness-remote-home-p name) (or (harness-remote-home-tidy name) name))
     ;; A host with no directory, /ssh:box:, is its login's home directory to
     ;; TRAMP, which asks the host for it.
     ((and parts (string-empty-p (cdr parts))) (concat (car parts) "~/"))
     ;; DIR plays no part for an absolute NAME; keep it out of the way.
     ((and in-home (file-name-absolute-p name)) (expand-file-name name "/"))
     (in-home (let ((joined (concat (file-name-as-directory dir) name)))
                (or (harness-remote-home-tidy joined) joined)))
     (t (expand-file-name name dir)))))

(defun harness-abbreviate-file-name (name)
  "Return NAME abbreviated for a message, as `abbreviate-file-name' does.
A remote name is left as it is.  TRAMP expands one in a home directory
\(see `harness-remote-home-p') on the host to find the home, which
connects, and, once it is connected to the host, asks it whether its file
system is case sensitive before it abbreviates any other: a round trip
to the host that no message is worth.  Use this, not
`abbreviate-file-name', for any path a permission prompt or a message
about one may name."
  (if (harness-remote-parts name) name (abbreviate-file-name name)))

(defun harness-remote-parent-dir (dir)
  "Return the directory that holds directory DIR on its host, or nil.
DIR is a remote directory name, and so is the result.  Nil for a local
name and for the root of the host.  The directory above a home
directory is the root of the host: what lies between the two is for the
host to say.  Nothing is looked up."
  (when-let* ((parts (harness-remote-parts dir)))
    (let* ((local (file-name-as-directory (if (string-empty-p (cdr parts)) "/" (cdr parts))))
           (up (file-name-directory (directory-file-name local))))
      (cond ((equal local "/") nil)
            ((null up) (concat (car parts) "/"))
            (t (concat (car parts) up))))))

(defun harness-glob-regexp (pattern &optional no-classes)
  "Translate glob PATTERN into a regexp that matches a whole string.
`*' matches any run of characters but `/', `**' any run across
directories (`**/' also matches no directory at all), `?' one
character but `/', and `[...]' one character of a class (`[!...]'
negates it), unless NO-CLASSES is non-nil: then a bracket matches
itself, as in a directory called \"Photos [2024]\".  Every other
character matches itself.  Match with `case-fold-search' nil: file
names are case-sensitive."
  (let ((i 0) (n (length pattern)) (out (list "\\`")))
    (while (< i n)
      (let* ((c (aref pattern i))
             ;; A class: `[', maybe `!' or `^', then at least one
             ;; character before its `]', so `[]]' holds a `]'.
             (negated (and (eq c ?\[) (< (1+ i) n) (memq (aref pattern (1+ i)) '(?! ?^))))
             (body (+ i (if negated 2 1)))
             (end (and (eq c ?\[) (not no-classes) (< body n) (string-search "]" pattern (1+ body)))))
        (cond
         ((and (eq c ?*) (< (1+ i) n) (eq (aref pattern (1+ i)) ?*))
          (if (and (< (+ i 2) n) (eq (aref pattern (+ i 2)) ?/))
              (progn (push "\\(?:.*/\\)?" out) (cl-incf i 3))
            (push ".*" out) (cl-incf i 2)))
         ((eq c ?*) (push "[^/]*" out) (cl-incf i))
         ((eq c ??) (push "[^/]" out) (cl-incf i))
         (end
          (push (concat "[" (if negated "^" "") (substring pattern body end) "]") out)
          (setq i (1+ end)))
         (t (push (regexp-quote (string c)) out) (cl-incf i)))))
    (push "\\'" out)
    (apply #'concat (nreverse out))))

(defun harness-relative-path (root path)
  "Return PATH relative to ROOT when inside it, else PATH abbreviated."
  (if (and root (harness-path-within-p root path))
      (let ((rel (file-relative-name (expand-file-name path) (expand-file-name root))))
        (if (string= rel ".") "" rel))
    (abbreviate-file-name path)))

(defun harness-file-size (path)
  "Return the size of PATH in bytes, or nil."
  (let ((attrs (file-attributes path)))
    (and attrs (file-attribute-size attrs))))

(defun harness-ensure-directory (dir)
  "Create DIR if needed and return it."
  (unless (file-directory-p dir) (make-directory dir t))
  dir)

(defun harness-write-file-atomically (path string)
  "Write STRING to PATH via a temporary file and rename."
  (harness-ensure-directory (file-name-directory path))
  (let ((tmp (concat path ".tmp" (harness-short-id 4)))
        (coding-system-for-write 'utf-8-unix))
    (with-temp-file tmp (insert string))
    (rename-file tmp path t)))

(defun harness-read-file (path)
  "Return the contents of PATH as a string, or nil when unreadable."
  (when (file-readable-p path)
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8))
        (insert-file-contents path))
      (buffer-string))))

;;;; Image sizes

(defun harness--image-header-size ()
  "Return (WIDTH . HEIGHT) of the image whose bytes the buffer holds, or nil.
The buffer is unibyte, the image's header at its start."
  (cl-labels ((byte (pos) (char-after pos))
              (u16le (pos) (+ (byte pos) (* 256 (byte (1+ pos)))))
              (u16be (pos) (+ (* 256 (byte pos)) (byte (1+ pos))))
              (u24le (pos) (+ (u16le pos) (* 65536 (byte (+ pos 2)))))
              (u32le (pos) (+ (u16le pos) (* 65536 (u16le (+ pos 2)))))
              (u32be (pos) (+ (* 65536 (u16be pos)) (u16be (+ pos 2))))
              (at (pos string) (and (<= (+ pos (length string)) (point-max))
                                    (string= string (buffer-substring pos (+ pos (length string)))))))
    (let ((size
           (cond
            ((and (at 1 "\211PNG\r\n\032\n") (at 13 "IHDR"))
             (cons (u32be 17) (u32be 21)))
            ((or (at 1 "GIF87a") (at 1 "GIF89a"))
             (cons (u16le 7) (u16le 9)))
            ((and (at 1 "RIFF") (at 9 "WEBP"))
             (cond ((and (at 13 "VP8 ") (at 24 "\235\001\052"))
                    (cons (logand (u16le 27) #x3fff) (logand (u16le 29) #x3fff)))
                   ((at 13 "VP8L")
                    (let ((b0 (byte 22)) (b1 (byte 23)) (b2 (byte 24)) (b3 (byte 25)))
                      (cons (1+ (logior (ash (logand b1 #x3f) 8) b0))
                            (1+ (logior (ash (logand b3 #x0f) 10) (ash b2 2) (ash (logand b1 #xc0) -6))))))
                   ((at 13 "VP8X") (cons (1+ (u24le 25)) (1+ (u24le 28))))))
            ((at 1 "BM")
             (if (= (u32le 15) 12)
                 (cons (u16le 19) (u16le 21))
               (let ((h (u32le 23)))
                 ;; A height below zero, in two's complement, is a top-down image.
                 (cons (u32le 19) (if (>= h #x80000000) (- #x100000000 h) h)))))
            ((at 1 "\377\330")
             ;; JPEG: the size is in the frame header, after the segments
             ;; before it (EXIF, colour profiles...), each saying its length.
             (let ((pos 3) found)
               (while (and (not found) (< (+ pos 8) (point-max)) (= (byte pos) #xff))
                 (let ((marker (byte (1+ pos))))
                   (cond ((= marker #xff) (cl-incf pos))
                         ((and (<= #xc0 marker #xcf) (not (memq marker '(#xc4 #xc8 #xcc))))
                          (setq found (cons (u16be (+ pos 7)) (u16be (+ pos 5)))))
                         ((or (memq marker '(#x01 #xd8)) (<= #xd0 marker #xd7)) (cl-incf pos 2))
                         (t (cl-incf pos (+ 2 (u16be (+ pos 2))))))))
               found)))))
      (and size (> (car size) 0) (> (cdr size) 0) size))))

(defun harness-image-pixel-size (file &optional bytes)
  "Return (WIDTH . HEIGHT) of the image FILE, in its own pixels, or nil.
It is read from the file's header, without decoding the image, so it
costs the same for any size.  BYTES, the image's bytes as a unibyte
string, are read instead of FILE when given.  PNG, GIF, JPEG, WebP and
BMP are known; nil for other formats (an SVG has no size of its own),
and when the file cannot be read."
  (condition-case nil
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (if bytes
            (insert bytes)
          (insert-file-contents-literally file nil 0 65536))
        (or (harness--image-header-size)
            ;; Other headers fit in the first few dozen bytes, but the
            ;; segments before a JPEG's size (EXIF, colour profiles) may
            ;; be longer.
            (and (not bytes) (= (buffer-size) 65536)
                 (equal (buffer-substring 1 3) "\377\330")
                 (progn (erase-buffer)
                        (insert-file-contents-literally file nil 0 (* 4 1024 1024))
                        (harness--image-header-size)))))
    (error nil)))

(defun harness--bmp-head-p (head)
  "Non-nil when HEAD, the start of a file as a unibyte string, is a BMP's.
\"BM\" alone is no proof: the file header's reserved fields are zero, and
the header after it has one of the sizes a bitmap's has."
  (and (>= (length head) 26)
       (string-prefix-p "BM" head)
       (= 0 (aref head 6) (aref head 7) (aref head 8) (aref head 9))
       (= 0 (aref head 16) (aref head 17))
       (memq (+ (aref head 14) (ash (aref head 15) 8)) '(12 40 52 56 64 108 124))
       t))

(defun harness-image-mime-of-bytes (head)
  "Return the media type of the picture that starts with the bytes HEAD, or nil.
HEAD is a unibyte string, the start of a file.  Give it a few KiB: an
SVG is known by its `<svg' tag, which may come after a prolog.  PNG,
JPEG, GIF, WebP and BMP are known by their headers (a text that begins
with \"BM\" is no bitmap).  Nil for anything else, a file named for a
picture that is none included: this says what the bytes are, not what
the name claims."
  (let ((case-fold-search nil))
    (cond ((string-prefix-p "\211PNG\r\n\032\n" head) "image/png")
          ((string-prefix-p "\377\330\377" head) "image/jpeg")
          ((or (string-prefix-p "GIF87a" head) (string-prefix-p "GIF89a" head)) "image/gif")
          ((and (>= (length head) 12) (string-prefix-p "RIFF" head)
                (equal (substring head 8 12) "WEBP"))
           "image/webp")
          ((harness--bmp-head-p head) "image/bmp")
          ((string-match-p "<svg[ \t\r\n/>]" head) "image/svg+xml"))))

;;;; Strings

(defun harness-fuzzy-score (query candidate)
  "Score how well QUERY matches CANDIDATE as a subsequence, or nil.
Higher is better; consecutive and word-start matches score more."
  (let ((qi 0) (ci 0) (score 0) (prev -2)
        (ql (length query)) (cl (length candidate))
        (query (downcase query)) (cand (downcase candidate)))
    (while (and (< qi ql) (< ci cl))
      (when (eq (aref query qi) (aref cand ci))
        (cl-incf score (cond ((= ci (1+ prev)) 3)
                             ((or (= ci 0) (memq (aref cand (1- ci)) '(?/ ?- ?_ ?. ?\s))) 2)
                             (t 1)))
        (setq prev ci)
        (cl-incf qi))
      (cl-incf ci))
    (when (= qi ql)
      (- score (/ cl 100.0)))))

(defun harness-fuzzy-filter (query candidates &optional key limit)
  "Return CANDIDATES fuzzy-matching QUERY, best first.
KEY extracts the string to match; LIMIT caps the result count."
  (let ((scored nil))
    (dolist (c candidates)
      (let ((s (harness-fuzzy-score query (if key (funcall key c) c))))
        (when s (push (cons s c) scored))))
    (let ((sorted (mapcar #'cdr (sort scored (lambda (a b) (> (car a) (car b)))))))
      (if limit (seq-take sorted limit) sorted))))

(defun harness-string-blank-p (s)
  "Non-nil when S is nil or only whitespace."
  (or (null s) (string-blank-p s)))

(defun harness-safe-substring (string from &optional to)
  "Like `substring' on STRING, but clamps FROM and TO into its range."
  (let* ((len (length string))
         (from (max 0 (min from len)))
         (to (if to (max from (min to len)) len)))
    (substring string from to)))

;;;; Processes

(defvar harness--process-kill-grace 3
  "Seconds between TERM and KILL when a timed-out command is killed.
Internal, not an option (see docs/configuration-audit.md).  A command
runs in its own process group, so a timeout kills its children too: the
group gets TERM, then KILL when anything in it is still alive after
this many seconds.")

(defun harness--process-children (pid)
  "Return the direct children of PID, from the system process table.
Empty when the table cannot be read (no /proc, a sandbox), which leaves
the group kill in `harness-process-tree' as the only mechanism.  PID
is a process of this machine, a remote command's too (the ssh that
runs it), so the table is this machine's whatever buffer is current:
with a remote `default-directory' it would be the remote host's."
  (when (fboundp 'list-system-processes)
    (let ((default-directory "/")
          children)
      (dolist (candidate (ignore-errors (list-system-processes)))
        (let ((attrs (ignore-errors (process-attributes candidate))))
          (when (eql pid (alist-get 'ppid attrs))
            (push candidate children))))
      children)))

(defun harness-process-tree (pid group)
  "Return the process tree rooted at PID as a plist.
The plist is (:pid PID :group GROUP :children PIDS): the descendants are
collected now, before anything is signalled, because a killed parent
cannot be asked for them again and they are reparented as it dies.
Every command Emacs spawns gets its own process group, so a group kill
alone misses a grandchild that a child Emacs spawned with `call-process';
walking the process table catches it."
  (let (children queue)
    (setq queue (list pid))
    (while queue
      (dolist (child (harness--process-children (pop queue)))
        (push child children)
        (push child queue)))
    (list :pid pid :group group :children (nreverse children))))

(defun harness-kill-process-tree (tree &optional signal)
  "Send SIGNAL (TERM by default) to every process in TREE.
TREE is what `harness-process-tree' returned: the root and its group
\(when local) and the descendants collected with it.  Best-effort: a
process that is already gone is not an error."
  (let ((sig (or signal 'term))
        (pid (plist-get tree :pid))
        (group (plist-get tree :group)))
    (when (and (integerp pid) (> pid 0))
      (dolist (child (plist-get tree :children))
        (ignore-errors (signal-process child sig)))
      (when group
        (ignore-errors (signal-process (- pid) sig)))
      (ignore-errors (signal-process pid sig)))))

(defun harness--sentinel-in-plain-buffer (sentinel process event)
  "Call SENTINEL with PROCESS and EVENT in a buffer that has no process.
It goes around the sentinel of a remote command whose standard error
has a buffer.  TRAMP's part of that sentinel deletes the process that
reads standard error, as `delete-process' of `get-buffer-process'; when
that reader has exited already, that is `delete-process' of nil, which
deletes the current buffer's process.  The sentinel runs inside
whatever is waiting for output then: often a TRAMP call, in the buffer
of the connection it waits on, which would die under it."
  (with-temp-buffer (funcall sentinel process event)))

;;;;; Writing to a process without nesting

(declare-function harness-log "harness-core" (level fmt &rest args))

(defvar harness-process-send-slow 10
  "Seconds a write to a process waits for room before it is logged.
Internal, not an option: the log names the process that stopped
reading, the first thing to know when the harness slows down.")

(cl-defstruct (harness--send (:constructor harness--send-create) (:copier nil))
  "A write under way to a process, and what waits to go out behind it."
  (queue nil :documentation "Strings that wait, newest first.")
  (start (float-time) :documentation "When the write began, a `float-time'.")
  (eof nil :documentation "Non-nil when end-of-file goes out after the queue.")
  (warned nil :documentation "Non-nil once the wait was logged."))

(defun harness-process-sending-p (proc)
  "Non-nil while a write to PROC is under way, further up some stack.
What is written to PROC meanwhile waits in line behind it (see
`harness-process-send')."
  (and (process-get proc 'harness--send) t))

(defun harness--process-send-wait (proc state string limit)
  "Put STRING in line behind STATE, the write under way to PROC.
Log once that the write is slow; past LIMIT seconds, give up on PROC."
  (push string (harness--send-queue state))
  (let ((waited (- (float-time) (harness--send-start state))))
    (when (and (> waited harness-process-send-slow)
               (not (harness--send-warned state)))
      (setf (harness--send-warned state) t)
      (when (fboundp 'harness-log)
        (harness-log 'warn "process: a write to %s has waited %.0fs for room; what comes meanwhile waits behind it"
                     (process-name proc) waited)))
    (when (and limit (> waited limit) (process-live-p proc))
      (when (fboundp 'harness-log)
        (harness-log 'warn "process: %s has not read for %.0fs; closing it" (process-name proc) waited))
      ;; The write under way then fails, and its caller drops PROC.
      (delete-process proc))))

(defun harness-process-send (proc string &optional limit)
  "Write STRING to PROC after what waits to go out to it, without nesting.
`process-send-string' to a process that reads more slowly than it is
written to -- a client that stopped reading, a program busy elsewhere
-- fills its input and then waits for room, running the timers due and
process output meanwhile.  What those wrote to the same process would
wait inside that write, each inside the one before, until Lisp nesting
exceeded `max-lisp-eval-depth' and every timer, filter and sentinel
failed; in the harness process, the error of a sentinel then killed it,
as batch Emacs exits on one (see `harness-server--command-error').  So
a write to a process already being written to waits in line instead,
and the write under way sends what waits once it is done, in order.

LIMIT, when non-nil, is how many seconds a write may wait for room:
past that, the next write to PROC deletes it, since a peer that has not
read for so long is gone (a phone asleep), and the write under way
then fails.  A write that waits that long is logged either way, after
`harness-process-send-slow' seconds.

Return non-nil.  Signal the error of a failed write to its caller, the
one under way; what waited behind it is dropped with it."
  (let ((state (process-get proc 'harness--send)))
    (if state
        (harness--process-send-wait proc state string limit)
      (setq state (harness--send-create))
      (process-put proc 'harness--send state)
      (unwind-protect
          (let ((chunk string))
            (while chunk
              (process-send-string proc chunk)
              ;; What came meanwhile, in one write.
              (setq chunk (and (harness--send-queue state)
                               (apply #'concat (nreverse (harness--send-queue state)))))
              (setf (harness--send-queue state) nil))
            (when (harness--send-eof state)
              (process-send-eof proc)))
        (process-put proc 'harness--send nil)
        (let ((waited (- (float-time) (harness--send-start state))))
          (when (and (> waited harness-process-send-slow) (fboundp 'harness-log))
            (harness-log 'info "process: a write to %s waited %.0fs for room" (process-name proc) waited)))))
    t))

(defun harness-process-send-eof (proc)
  "Send end-of-file to PROC once what waits to go out to it has gone.
A write under way to PROC (see `harness-process-send') sends it after
the strings that wait behind it; else it goes out now."
  (let ((state (process-get proc 'harness--send)))
    (if state
        (setf (harness--send-eof state) t)
      (process-send-eof proc))))

(cl-defun harness-run-command (command &key cwd (timeout 120) stdin on-output name env
                                       merge-remote-stderr)
  "Run COMMAND (a list of strings) asynchronously and return a promise.
The promise resolves to (:exit CODE :stdout STRING :stderr STRING).
CWD defaults to `default-directory'; a remote (TRAMP) CWD runs the
command on that host.  STDIN, when given, is sent to the process.  ENV,
an alist, is prepended to `process-environment' for the command.
ON-OUTPUT is called with every chunk of standard output as it arrives.
After TIMEOUT seconds the process is killed -- its whole process group
on a local CWD, so children cannot outlive it -- and :exit is
`timeout'.

MERGE-REMOTE-STDERR non-nil leaves the standard error of a command on a
remote CWD in :stdout, as the command wrote it, and :stderr empty.
TRAMP keeps standard error apart through a FIFO on the host, read over
a connection of its own and deleted from the sentinel, so in the middle
of whatever TRAMP call is running then; a caller that only shows the
output is better off without all that."
  (harness-with-promise (resolve reject)
    (ignore reject)
    (let* ((default-directory (file-name-as-directory (expand-file-name (or cwd default-directory))))
           (remote (file-remote-p default-directory))
           (group (not remote))
           (chunks nil)
           (stderr-buf (unless (and remote merge-remote-stderr)
                         (generate-new-buffer " *harness-cmd-stderr*" t)))
           (done nil) (timer nil) (kill-timer nil) (pid nil) (proc nil) (tree nil)
           (finish (lambda (code)
                     (unless done
                       (setq done t)
                       (when timer (cancel-timer timer))
                       (when kill-timer (cancel-timer kill-timer))
                       (let ((err (and (buffer-live-p stderr-buf)
                                       (with-current-buffer stderr-buf (buffer-string)))))
                         (when (buffer-live-p stderr-buf) (kill-buffer stderr-buf))
                         (funcall resolve (list :exit code
                                                :stdout (apply #'concat (nreverse chunks))
                                                :stderr (or err ""))))))))
      (let ((process-environment (if env
                                     (append (mapcar (lambda (pair)
                                                       (format "%s=%s" (car pair) (cdr pair)))
                                                     env)
                                             process-environment)
                                   process-environment)))
        (setq proc (condition-case err
                       (make-process :name (or name "harness-cmd")
                                     :command command
                                     :connection-type 'pipe
                                     :noquery t
                                     :file-handler t
                                     :stderr stderr-buf
                                     :filter (lambda (_p chunk)
                                               (push chunk chunks)
                                               (when on-output (funcall on-output chunk)))
                                     :sentinel (lambda (p _e)
                                                 (unless (process-live-p p)
                                                   (funcall finish (process-exit-status p)))))
                     ;; No process, such as a TRAMP host that cannot be
                     ;; reached: the promise rejects, and nothing reads
                     ;; the buffer for its standard error.
                     (error (when stderr-buf (kill-buffer stderr-buf))
                            (signal (car err) (cdr err)))))
        (setq pid (process-id proc)))
      (when-let* ((ep (and stderr-buf (get-buffer-process stderr-buf))))
        (set-process-query-on-exit-flag ep nil)
        (set-process-sentinel ep #'ignore))
      (when (and remote stderr-buf)
        (add-function :around (process-sentinel proc) #'harness--sentinel-in-plain-buffer))
      (setq timer (run-at-time timeout nil
                               (lambda ()
                                 (setq tree (harness-process-tree pid group))
                                 (funcall finish 'timeout)
                                 (harness-kill-process-tree tree 'term)
                                 (setq kill-timer
                                       (run-at-time harness--process-kill-grace nil
                                                    (lambda ()
                                                      (harness-kill-process-tree tree 'kill)))))))
      (when stdin (harness-process-send proc stdin))
      (when (process-live-p proc) (harness-process-send-eof proc)))))

(defun harness-grep-hit (line suffix)
  "Split LINE of `grep -H' output into (NAME . TEXT), or return nil.
LINE is FILE:TEXT where FILE's name ends in SUFFIX (such as
\".nodes.jsonl\"); NAME is that name without its directory and SUFFIX.
LINE is cut where SUFFIX and a colon first appear together, by a plain
search, not a regexp: TEXT can be megabytes long (a node log holds a
whole node on each line), and a regexp that backtracks over it
overflows the matcher."
  (let ((cut (string-search (concat suffix ":") line)))
    (and cut
         (cons (file-name-nondirectory (substring line 0 cut))
               (substring line (+ cut (length suffix) 1))))))

;;;; User options

(declare-function harness-policy-refuse "harness-policy" (option))

(defun harness-save-user-option (symbol value)
  "Set SYMBOL to VALUE here and persist it in the user's custom file.
The custom file belongs to the Emacs showing the UI, which may not be
this one (see harness-server.el), so the save is asked of the UI over
`client/request'; without a UI it is done here when a custom file is
in use.  Signal an error, changing nothing, when the policy sets SYMBOL
\(see harness-policy.el).  Returns nothing useful; failures to save are
logged."
  (when (fboundp 'harness-policy-refuse)
    (harness-policy-refuse symbol))
  (customize-set-variable symbol value)
  (if (and (fboundp 'harness-method-exists-p) (harness-method-exists-p 'client/request))
      (harness-catch (harness-call-async 'client/request "_harness/client/customize-save"
                                         (list :symbol (symbol-name symbol)
                                               :value (let ((print-length nil) (print-level nil))
                                                        (prin1-to-string value))))
                     (lambda (e) (harness-log 'warn "could not save %s: %s" symbol (harness-error-message e))))
    (when (and custom-file (not noninteractive))
      (condition-case err
          (customize-save-variable symbol value)
        (error (harness-log 'warn "could not save %s: %S" symbol err)))))
  nil)

(defun harness-renew-default (symbol &rest old)
  "Give option SYMBOL its default again when it holds one of OLD.
OLD are the defaults it had before.  A reload evaluates a `defcustom'
again without changing the value it has, so a default that changed
would stay as it was until Emacs restarts, and would look like a choice
of the user's meanwhile, which the UI passes on to its harness process.
A value the user saved through Customize is theirs and stays; so does
any other value.  Return non-nil when the default was given again."
  (when (and (default-boundp symbol)
             (member (default-value symbol) old)
             (get symbol 'standard-value))
    (custom-reevaluate-setting symbol)
    t))

;;;; Errors

(defun harness-error-message (err)
  "Return a readable message for ERR (an error data list or string).
An ACP error, (acp-error CODE MESSAGE DATA), reads as its MESSAGE.  A
list whose first element is no defined error type and whose second is a
string, (curl MESSAGE :code 56), reads as that string: the details would
otherwise print as \"peculiar error: \\\"...\\\", :code, 56\".  A defined
error type keeps its own message, (harness-no-such-method NAME) reading
as \"No such harness method: NAME\"."
  (cond ((stringp err) err)
        ((and (eq (car-safe err) 'acp-error) (stringp (nth 2 err)) (not (string-empty-p (nth 2 err))))
         (nth 2 err))
        ((and (consp err) (symbolp (car err)) (stringp (cadr err))
              (not (get (car err) 'error-conditions)))
         (cadr err))
        ((and (consp err) (symbolp (car err)))
         (condition-case nil (error-message-string err)
           (error (format "%S" err))))
        (t (format "%S" err))))

(defconst harness-error-message-limit 200
  "Longest error text the harness reports, in characters.
A message longer than this is cut where it is logged, hinted and shown:
an error that carries a whole transcript, prompt or request body as its
data would otherwise be repeated whole in *Messages*, in a session's
history and in the tree.")

(defun harness-error--cut (text limit)
  "Return TEXT cut to LIMIT characters, with an ellipsis when it was."
  (if (and (stringp text) (> (length text) limit))
      (concat (substring text 0 (max 0 (1- (max 1 limit)))) "…")
    text))

(defun harness-error--short-data (data limit &optional depth)
  "Return error DATA with long strings cut to LIMIT characters.
Lists and vectors are walked, so a string nested in a plist an error
carries is cut too.  DEPTH bounds the walk; deep data is left as a
placeholder rather than walked at all.  A record -- a `cl-defstruct'
instance, which an `args-out-of-range' or a `wrong-type-argument' names
whole -- is no text to print: it becomes the name of its type, as
\"#<review>\", for a record may hold a task's report, a branch's diff,
the whole of a session."
  (cond ((> (or depth 0) 4) (if (stringp data) (harness-error--cut data limit) "…"))
        ((stringp data) (harness-error--cut data limit))
        ((recordp data) (format "#<%s>" (type-of data)))
        ((consp data)
         (let ((items nil) (rest data) (n 0))
           (while (and (consp rest) (< n 20))
             (push (harness-error--short-data (car rest) limit (1+ (or depth 0))) items)
             (setq rest (cdr rest) n (1+ n)))
           (let ((items (nreverse items)))
             (if (null rest) items
               (append items (harness-error--short-data rest limit (1+ (or depth 0))))))))
        ((vectorp data)
         (apply #'vector
                (mapcar (lambda (d) (harness-error--short-data d limit (1+ (or depth 0))))
                        (cl-subseq (append data nil) 0 (min 20 (length data))))))
        (t data)))

(defun harness-error--one-line (text)
  "Return TEXT with runs of whitespace, newlines included, as single spaces.
A message reported in *Messages*, a hint or a tree row reads as one
line; the transcript an error may quote is full of newlines."
  (string-trim (replace-regexp-in-string "[ \t\n\r\f\v]+" " " (or text ""))))

(defun harness-error-short-message (err &optional limit)
  "Return a short, readable message for ERR, an error data list or string.
Like `harness-error-message', but long strings among ERR's data are cut
to LIMIT characters (`harness-error-message-limit' by default) and so is
the message.  An error whose data carries a whole transcript or request
body -- a `json-value-p' failure, say -- then reads in one short line in
*Messages*, in a session hint and in the tree, rather than repeating it."
  (let* ((limit (max 16 (or limit harness-error-message-limit)))
         (msg (cond ((stringp err) err)
                    ((and (eq (car-safe err) 'acp-error) (stringp (nth 2 err))
                          (not (string-empty-p (nth 2 err))))
                     (nth 2 err))
                    ((and (consp err) (symbolp (car err)))
                     (condition-case nil
                         ;; What is not cut above is printed bounded: data of a
                         ;; kind the walk does not know would print whole.
                         (let ((print-length 20) (print-level 6))
                           (error-message-string
                            (cons (car err) (harness-error--short-data (cdr err) limit))))
                       (error (harness-error--cut (let ((print-length 20) (print-level 6))
                                                    (format "%S" err))
                                                  limit))))
                    (t (harness-error--cut (let ((print-length 20) (print-level 6))
                                             (format "%S" err))
                                           limit)))))
    (harness-error--one-line (harness-error--cut msg limit))))

(defmacro harness-ignore-errors-logged (context &rest body)
  "Run BODY, logging any error with CONTEXT instead of signalling."
  (declare (indent 1))
  `(condition-case err
       (progn ,@body)
     (error (harness-log 'error "%s: %S" ,context err) nil)))

(provide 'harness-util)
;;; harness-util.el ends here
