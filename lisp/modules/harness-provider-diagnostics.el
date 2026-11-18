;;; harness-provider-diagnostics.el --- Content-free prompt-prefix and serving diagnostics  -*- lexical-binding: t; -*-

;;; Commentary:

;; A provider's prompt cache is only as good as the prefix the harness
;; sends it.  When a warm conversation reads 80k cached tokens on one
;; request and none on the next, the cause can be a changed request
;; prefix (a tool schema, a system prompt, a re-rendered message) or the
;; provider's own routing and cache shards.  The harness log said
;; nothing about either, so the two could not be told apart.
;;
;; This module logs, for every OpenAI-compatible completion attempt and
;; every ChatGPT Responses attempt, a content-free description of the
;; request prefix that actually went on the wire, and what the provider
;; said answered it.  It hashes a
;; versioned, length-prefixed serialization of the final request body:
;; the model, the cache-affecting settings, the system messages, the
;; tool schema and every message in order.  The serialization is a chain
;; of HMAC-SHA256 states, one per segment, so a checkpoint that matches
;; an earlier request's checkpoint proves the segments through it are
;; byte-for-byte the same serialized material.  A whole-request digest
;; would change on every appended turn; the checkpoints keep the
;; preserved prefix visible.
;;
;; Nothing raw is logged.  Message text, tool descriptions, tool
;; arguments, request bodies, keys and the HMAC key never enter a log
;; line.  The key is 32 random bytes from /dev/urandom, kept in the
;; state directory (mode 0600) and shared across restarts so checkpoints
;; stay comparable; `harness-provider-diagnostics-rotate-key` deletes
;; it and starts a new key whose checkpoints are not comparable with the old
;; ones.  The log names the key by its first eight hex digits.  Without
;; a key file and without a system random source, hashing is off: there
;; is no unsalted fallback.
;;
;; Comparability is deliberately narrow.  The scope is one session: the
;; HMAC subkey is derived from the session id, so two sessions that send
;; the same prompt do not get the same digests.  Within a session the
;; subkey survives a restart, and the log says which process
;; (`boot=') and which attempt wrote a line.  Across a key rotation or a
;; scope change, checkpoints are not comparable and say so by their key
;; id.
;;
;; The diagnostic order is a reviewed model of a prompt prefix, not a
;; claim about a provider's internal cache key: model, settings,
;; leading system messages, tool schema, then the remaining messages in
;; request order.  A provider may serialize those fields differently or
;; include fields the harness cannot see.  A matching checkpoint means
;; the harness sent the same material; it does not prove the provider
;; kept it, or that the same host served the next request.  That is why
;; the response line keeps the observed provider and model separate from
;; the configured route, and leaves either unknown when the response
;; did not supply it.  A provider name is not a geography, a training
;; policy or a stable cache shard.
;;
;; Reading a line: `prefix=appended' says every serialized segment of the
;; previous request is present unchanged; `preserved=N' says how many of
;; the common checkpoints matched; `diverged' names the first that
;; differs, `at=INDEX:TAG`; `prev=` names the attempt it was compared
;; with; `first' says this process had no earlier request for the
;; session; `shorter' says the new request has fewer chunks.  The
;; response line's `expected-cold=' is the prediction the request line
;; made, and `cache-read=' is the provider's own token reading, not a
;; ratio the harness inferred.  Missing cache or cost fields read
;; `unknown', never zero.  `cost-source=provider' is provider-reported
;; cost; `cost-source=plan' is a subscription's zero; `unknown' means no
;; estimate was invented.  `response-id=' is any id the response gave,
;; and `generation=' repeats it only when it has OpenRouter's `gen-'
;; shape; `request-id=' is an `x-request-id' header.  `provider=' and
;; `served-model=' are what the response named, never the configured
;; route.
;;
;; The module never sends a request of its own, never changes a route or
;; a privacy setting, and never adds usage: it reads the attempt and
;; writes one bounded log line at its start and one at its end.  The
;; existing harness log's retention (5000 lines, 4 MiB) bounds it.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-instance)

(defvar harness-state-directory)
(defvar harness-disabled-modules)

(defun harness-provider-diagnostics-enabled-p ()
  "Non-nil when diagnostics should hash and log.
That is `harness-provider-diagnostics-enabled' and not the module named
in `harness-disabled-modules'.  The latter is checked here because
`provider-openai' requires this file whatever the module loader
selected, so disabling the module must still silence it."
  (and harness-provider-diagnostics-enabled
       (not (and (boundp 'harness-disabled-modules)
                 (memq 'provider-diagnostics harness-disabled-modules)))))

(defcustom harness-provider-diagnostics-enabled t
  "Whether provider request-prefix diagnostics are logged.
When nil, no prefix is hashed and no diagnostic line is written; a
provider call behaves exactly as it would without this module.  Naming
`provider-diagnostics' in `harness-disabled-modules' turns it off the
same way, even though the provider loads this file itself."
  :type 'boolean
  :group 'harness)

(defcustom harness-provider-diagnostics-key-file nil
  "File holding the diagnostic HMAC key, or nil for the state directory.
The default is `provider-diagnostics.key' under
`harness-state-directory'.  The file is created with mode 0600 and is
never logged."
  :type '(choice (const :tag "State directory" nil) file)
  :group 'harness)

(defcustom harness-provider-diagnostics-max-checkpoints 16
  "Most prefix checkpoints one request line keeps.
The model, settings, the leading system messages, the tool schema and
the final chunk are always kept; the previous request's end boundary
and a geometric spread through the messages fill what is left."
  :type 'integer
  :group 'harness)

(defcustom harness-provider-diagnostics-max-bytes (* 16 1024 1024)
  "Largest serialized request body diagnostics will hash, in bytes.
A larger body is not hashed; the line says `skipped=large' and the
request itself is unaffected.  This bounds the extra encoding work."
  :type 'integer
  :group 'harness)

(defcustom harness-provider-diagnostics-max-line-chars 2000
  "Longest diagnostic line kept, in characters.
A longer line is cut at this many characters and ends with `…'.  The
harness log's own entry limit is larger; this keeps one line readable
and bounded even with many checkpoints."
  :type 'integer
  :group 'harness)

(defcustom harness-provider-diagnostics-log-level 'info
  "Log level of diagnostic request and response lines."
  :type '(choice (const debug) (const info) (const warn))
  :group 'harness)

(defconst harness-provider-diagnostics-version 1
  "Version of the diagnostic serialization and log format.")

(defconst harness-provider-diagnostics--key-prefix "hpd1:"
  "What a diagnostic key file starts with.")

(defconst harness-provider-diagnostics--key-bytes 32
  "Bytes in the diagnostic HMAC key.")

(defconst harness-provider-diagnostics--key-name "provider-diagnostics.key"
  "Default diagnostic key file name under the state directory.")

(defconst harness-provider-diagnostics--max-last 128
  "Most sessions whose last request record is kept.")

(defvar harness-provider-diagnostics--key 'unset
  "Cached HMAC key, `unset', or nil when diagnostics cannot hash.
`unset' means not read yet; nil means the key file is absent or invalid
and no unsalted fallback is used.")

(defvar harness-provider-diagnostics--last (make-hash-table :test 'equal)
  "Session -> the last diagnostic attempt started for it.
At most `harness-provider-diagnostics--max-last' sessions are kept; a
session whose record was evicted reads `first' rather than a guess.")

(defvar harness-provider-diagnostics--last-order nil
  "Sessions in `harness-provider-diagnostics--last', oldest first.")

(defvar harness-provider-diagnostics--sequence 0
  "Attempts started in this process, for unique attempt ids.")

(defvar harness-provider-diagnostics--requests 0
  "Attempts opened in this process since the last reset.
It is a count of every attempt, not a per-session one, and it is what
says which request of the process a miss record describes.")

(defvar harness-provider-diagnostics--in-flight (make-hash-table :test 'equal)
  "Session -> how many attempts of it are open right now.
A retry, a keep-warm request and two turns of one session can be in
flight together; the count is what a miss record keeps as
\=`concurrency=\=', so a reader can tell one request from several
sharing a prefix.  It is process state and never reaches a provider.")

(defvar harness-provider-diagnostics--warned nil
  "Non-nil once a missing or invalid key has been logged.
One warning per process, not one per request.")

(defvar harness-provider-diagnostics--random-bytes-function
  #'harness-provider-diagnostics--random-bytes
  "Function returning N random bytes, or nil when none can be had.
Tests bind this to simulate a system with no secure random source.")

(defvar harness-provider-diagnostics--boot
  (concat "b-" (harness-short-id 6))
  "Short label of this process, so a restart is visible in the log.
It is not secret and is not used as key material.")

;;;; Key lifecycle

(defun harness-provider-diagnostics--random-bytes (n)
  "Return N cryptographically random bytes, or nil.
Only the kernel's /dev/urandom is used: a fallback from Emacs's
`random' is not cryptographically strong, and an unsalted hash would
weaken the privacy the key exists for.  A system without it disables
hashing instead."
  (condition-case nil
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally "/dev/urandom" nil nil n)
        (and (= (buffer-size) n) (buffer-string)))
    (error nil)))

(defun harness-provider-diagnostics-key-file ()
  "Return the file that holds the diagnostic HMAC key.
Nil when no state directory is known, which disables hashing rather
than putting a key somewhere unpredictable."
  (or harness-provider-diagnostics-key-file
      (and (boundp 'harness-state-directory)
           (stringp harness-state-directory)
           (not (string-empty-p harness-state-directory))
           (expand-file-name harness-provider-diagnostics--key-name
                             harness-state-directory))))

(defun harness-provider-diagnostics--warn-once (fmt &rest args)
  "Log FMT with ARGS once per process, at warning level."
  (unless harness-provider-diagnostics--warned
    (setq harness-provider-diagnostics--warned t)
    (harness-log 'warn "provider-diagnostics: %s" (apply #'format-message fmt args))))

(defun harness-provider-diagnostics--decode-key (text)
  "Return the 32-byte key encoded in TEXT, or nil when it is not one."
  (when (and (stringp text) (string-prefix-p harness-provider-diagnostics--key-prefix text))
    (let ((raw (ignore-errors
                 (base64-decode-string
                  (string-trim (substring text (length harness-provider-diagnostics--key-prefix)))))))
      (and (= (length raw) harness-provider-diagnostics--key-bytes) raw))))

(defun harness-provider-diagnostics--write-key (key)
  "Write KEY to the key file with mode 0600; return KEY or nil.
A failure to write is logged once and disables hashing: the key is not
used without a place to keep it, since an in-memory key would make
checkpoints incomparable after a restart without saying so."
  (let ((file (harness-provider-diagnostics-key-file)))
    (condition-case err
        (progn
          (unless file
            (error "no state directory for a diagnostic key"))
          (harness-write-file-atomically
           file (concat harness-provider-diagnostics--key-prefix
                        (base64-encode-string key t) "\n"))
          (set-file-modes file #o600)
          key)
      (error (harness-provider-diagnostics--warn-once
              "cannot write the key file %s: %s; hashing is off"
              file (harness-error-message err))
             nil))))

(defun harness-provider-diagnostics-key ()
  "Return the diagnostic HMAC key, or nil when hashing is off.
The key is read from `harness-provider-diagnostics-key-file', created
from 32 bytes of /dev/urandom when the file is absent, and cached for
the process.  An existing but invalid file disables hashing rather than
being replaced: a wrong key is safer than a silently new comparability
scope.  The key is never logged."
  (cond
   ((not (harness-provider-diagnostics-enabled-p)) nil)
   ((not (eq harness-provider-diagnostics--key 'unset))
    harness-provider-diagnostics--key)
   (t
    (let* ((file (harness-provider-diagnostics-key-file))
           (exists (and file (file-exists-p file)))
           (text (and exists (harness-read-file file)))
           (existing (and text (harness-provider-diagnostics--decode-key text))))
      (cond
       (existing (setq harness-provider-diagnostics--key existing))
       ((or exists text)
        (harness-provider-diagnostics--warn-once
         "the key file %s is not a valid diagnostic key; hashing is off (delete it to rotate)"
         file)
        (setq harness-provider-diagnostics--key nil))
       (t
        (let ((fresh (funcall harness-provider-diagnostics--random-bytes-function
                              harness-provider-diagnostics--key-bytes)))
          (if (not (and (stringp fresh)
                        (= (length fresh) harness-provider-diagnostics--key-bytes)))
              (progn
                (harness-provider-diagnostics--warn-once
                 "no secure random bytes for a diagnostic key; hashing is off")
                (setq harness-provider-diagnostics--key nil))
            (setq harness-provider-diagnostics--key
                  (harness-provider-diagnostics--write-key fresh))))))))))

(defun harness-provider-diagnostics--hex (bytes)
  "Return BYTES as lower-case hexadecimal text."
  (mapconcat (lambda (byte) (format "%02x" byte)) (string-to-list bytes) ""))

(defun harness-provider-diagnostics--hmac (key text)
  "Return HMAC-SHA256 of TEXT under KEY, as raw bytes."
  (harness-instance-hmac-sha256 key text))

(defun harness-provider-diagnostics--key-id (key)
  "Return the public short id of KEY."
  (substring (harness-provider-diagnostics--hex
              (harness-provider-diagnostics--hmac key "harness-provider-diagnostics/key-id"))
             0 8))

(defun harness-provider-diagnostics--scope (session)
  "Return the comparability scope of SESSION.
A session id is its own scope.  A call with no session is scoped to
this process, so its digests are not comparable with another process's
anonymous calls."
  (or (and (stringp session) (not (string-empty-p session)) session)
      (concat "anonymous:" harness-provider-diagnostics--boot)))

(defun harness-provider-diagnostics--scope-id (key scope)
  "Return a short public id of SCOPE under KEY."
  (substring (harness-provider-diagnostics--hex
              (harness-provider-diagnostics--hmac
               key (concat "harness-provider-diagnostics/scope\0" scope)))
             0 8))

(defun harness-provider-diagnostics--subkey (key scope)
  "Return the HMAC subkey for SCOPE under KEY.
It is derived each time rather than cached, so the module keeps no
state per session beyond the bounded last-request table."
  (harness-provider-diagnostics--hmac
   key (concat "harness-provider-diagnostics/subkey\0" scope)))

(defun harness-provider-diagnostics-reset ()
  "Forget the cached key and every in-memory prefix comparison.
The key file is left as it is.  A restart has the same effect on the
in-memory records; the key file makes the next checkpoints comparable
with the ones already logged."
  (interactive)
  (setq harness-provider-diagnostics--key 'unset
        harness-provider-diagnostics--last (make-hash-table :test 'equal)
        harness-provider-diagnostics--last-order nil
        harness-provider-diagnostics--sequence 0
        harness-provider-diagnostics--warned nil))

(defun harness-provider-diagnostics-rotate-key ()
  "Delete the diagnostic key file and forget every cached prefix state.
Checkpoints logged after this are not comparable with earlier ones:
their `key=' id changes.  Return non-nil when the file was removed or
did not exist."
  (interactive)
  (let ((file (harness-provider-diagnostics-key-file)))
    (cond
     ((null file)
      (harness-provider-diagnostics-reset)
      nil)
     ((not (file-exists-p file))
      (harness-provider-diagnostics-reset)
      (harness-log 'info "provider-diagnostics: key rotated; earlier prefix digests are not comparable")
      t)
     ((ignore-errors (delete-file file) t)
      (harness-provider-diagnostics-reset)
      (harness-log 'info "provider-diagnostics: key rotated; earlier prefix digests are not comparable")
      t)
     (t
      (harness-provider-diagnostics--warn-once "cannot delete the key file %s" file)
      nil))))

;;;; Serialization

(defun harness-provider-diagnostics--json (value)
  "Return VALUE encoded as JSON bytes."
  (harness-json-encode value))

(defun harness-provider-diagnostics--role (message)
  "Return MESSAGE's role as a string, or nil."
  (when (listp message)
    (let ((role (plist-get message :role)))
      (and role (format "%s" role)))))

(defun harness-provider-diagnostics--system-p (message)
  "Non-nil when MESSAGE is a system message."
  (equal (harness-provider-diagnostics--role message) "system"))

(defun harness-provider-diagnostics--item-type (item)
  "Return ITEM's type as a string, or nil."
  (when (listp item)
    (let ((type (plist-get item :type)))
      (and type (format "%s" type)))))

(defun harness-provider-diagnostics--item-chunk (item index)
  "Return the diagnostic chunk for input ITEM at INDEX.
An `additional_tools' item carries the tool schema; anything else is a
message-like item.  The item type and role are labels only: the HMAC
covers the whole item's JSON."
  (let* ((type (harness-provider-diagnostics--item-type item))
         (role (harness-provider-diagnostics--role item)))
    (cond
     ((and (equal type "additional_tools") (plist-get item :tools))
      (list :tag "tools" :role nil
            :bytes (harness-provider-diagnostics--json (plist-get item :tools))))
     ((and (member type '("message" "function_call_output" "function_call"
                          "reasoning" "item_reference" nil))
           (plist-get item :role))
      (let ((role (plist-get item :role)))
        (if (equal (format "%s" role) "system")
            (list :tag (format "system/%d" index) :role "system"
                  :bytes (harness-provider-diagnostics--json item))
          (list :tag (format "message/%d" index) :role (format "%s" role)
                :bytes (harness-provider-diagnostics--json item)))))
     (t (list :tag (format "item/%d" index) :role role
              :bytes (harness-provider-diagnostics--json item))))))

(defun harness-provider-diagnostics--chunks (body &optional max-bytes)
  "Return the diagnostic chunks of the post-transformation BODY.
Each chunk is (:tag TAG :role ROLE :bytes BYTES), in the reviewed
diagnostic order: model, settings, the system prompt (a leading system
message, or Responses' `instructions'), the tool schema, then every
remaining item in request order.  Both an OpenAI chat-completions body
\(`messages') and a Responses body (`input') are read; the values are
the exact body values, JSON-encoded, in a length-prefixed chain.
MAX-BYTES stops the work as soon as the encoded chunks pass it: the
result is the symbol `large` rather than a body-sized encoding."
  (catch 'large
    (let* ((messages (let ((messages (plist-get body :messages)))
                       (if (vectorp messages) (append messages nil) messages)))
           (input (let ((in (plist-get body :input)))
                    (cond ((vectorp in) (append in nil))
                          ((listp in) in))))
           (instructions (plist-get body :instructions))
           (tools (plist-get body :tools))
           (settings nil)
           (system nil)
           (tool-chunks nil)
           (rest nil)
           (leading t)
           (index 0)
           (total 0))
      (cl-labels ((add (chunk chunks)
                    (cl-incf total (length (plist-get chunk :bytes)))
                    (when (and max-bytes (> total max-bytes))
                      (throw 'large 'large))
                    (push chunk chunks)))
        ;; The top-level wire order too: reordering fields is a wire change
        ;; even when each value is the same.
        (setq settings
              (add (list :tag "settings" :role nil
                         :bytes (harness-provider-diagnostics--json
                                 (append
                                  (list (format "keys=%s"
                                                (harness-json-encode-text
                                                 (cl-loop for (key _) on body by #'cddr
                                                          collect (symbol-name key)))))
                                  (cl-loop for (key value) on body by #'cddr
                                           unless (memq key '(:model :messages :input
                                                              :tools :instructions))
                                           collect (format "%s=%s" (symbol-name key)
                                                           (harness-json-encode-text value))))))
                    nil))
        (when (and (stringp instructions) (not (string-empty-p instructions)))
          (setq system
                (add (list :tag "system/0" :role "system"
                           :bytes (harness-provider-diagnostics--json instructions))
                     system)))
        (cond
         (messages
          (dolist (message messages)
            (let ((role (harness-provider-diagnostics--role message))
                  (chunk (list :tag nil :role nil
                               :bytes (harness-provider-diagnostics--json message))))
              (cond
               ((and leading (equal role "system"))
                (plist-put chunk :tag (format "system/%d" (length system)))
                (plist-put chunk :role role)
                (setq system (add chunk system)))
               (t
                (setq leading nil)
                (plist-put chunk :tag (format "message/%d" index))
                (plist-put chunk :role role)
                (setq rest (add chunk rest))))
              (cl-incf index))))
         (input
          (dolist (item input)
            (let ((chunk (harness-provider-diagnostics--item-chunk item index)))
              (cond
               ((equal (plist-get chunk :tag) "tools")
                (setq tool-chunks (add chunk tool-chunks)))
               ((and leading (stringp (plist-get chunk :tag))
                     (string-prefix-p "system/" (plist-get chunk :tag)))
                (setq system (add chunk system)))
               (t
                (setq leading nil)
                (setq rest (add chunk rest)))))
            (cl-incf index))))
        (when tools
          (setq tool-chunks
                (add (list :tag "tools" :role nil
                           :bytes (harness-provider-diagnostics--json tools))
                     tool-chunks)))
        (let ((model (add (list :tag "model" :role nil
                                :bytes (harness-provider-diagnostics--json
                                        (plist-get body :model)))
                          nil)))
          (append model settings (nreverse system) (nreverse tool-chunks)
                  (nreverse rest)))))))

(defun harness-provider-diagnostics--select (chunks previous)
  "Return the chunk indices to checkpoint for CHUNKS and PREVIOUS.
The structural boundaries are always kept -- model, settings, every
leading system message, the tool schema -- and so is the final chunk.
The previous attempt's final chunk is kept when the cap leaves room, so
an append can be recognized without a checkpoint at that exact index in
the current selection.  Powers of two and every sixteenth chunk fill the
rest; the result is at most
`harness-provider-diagnostics-max-checkpoints' and sorted."
  (let* ((n (length chunks))
         (max (max 6 harness-provider-diagnostics-max-checkpoints))
         (last (1- n))
         (carry (and previous (harness-provider-diagnostics-attempt-final-index previous)))
         (carry (and (integerp carry) (>= carry 0) (< carry n) carry))
         (structural nil))
    (cl-loop for chunk in chunks
             for i from 0
             do (let ((tag (plist-get chunk :tag)))
                  (cond ((member tag '("model" "settings" "tools"))
                         (push i structural))
                        ((and (stringp tag) (string-prefix-p "system/" tag))
                         (push i structural)))))
    (setq structural (sort (delete-dups structural) #'<))
    (let* ((required (delete-dups (append structural (list last))))
           (keep (if (<= (length required) max)
                     required
                   ;; Keep the model/settings/tools boundaries and the
                   ;; final one before any extra system message.
                   (let* ((core (cl-loop for chunk in chunks for i from 0
                                         when (member (plist-get chunk :tag)
                                                      '("model" "settings" "tools"))
                                         collect i))
                          (systems (cl-loop for chunk in chunks for i from 0
                                            when (and (stringp (plist-get chunk :tag))
                                                      (string-prefix-p "system/" (plist-get chunk :tag)))
                                            collect i))
                          (room (max 1 (- max (1+ (length core))))))
                     (sort (delete-dups (append core (cl-subseq systems 0 (min room (length systems)))
                                                (list last)))
                           #'<)))))
      ;; Fill with the previous end boundary first, then geometric
      ;; spread, but never beyond the cap.
      (dolist (i (append (and carry (list carry))
                         (cl-loop for j from 2 below n
                                  when (or (= 0 (logand j (1- j))) (= 0 (% j 16)))
                                  collect j)))
        (when (and (< (length keep) max) (not (memq i keep)))
          (push i keep)))
      (sort (delete-dups keep) #'<))))

(defun harness-provider-diagnostics--chain (subkey chunks)
  "Return the HMAC chain state after every chunk of CHUNKS under SUBKEY."
  (let ((state (harness-provider-diagnostics--hmac
                subkey (concat "harness-provider-diagnostics/"
                               (number-to-string harness-provider-diagnostics-version)
                               "\0init")))
        (states nil)
        (at 0))
    (dolist (chunk chunks)
      (setq state (harness-provider-diagnostics--hmac
                   subkey
                   (concat "chunk\0"
                           (plist-get chunk :tag) "\0"
                           (number-to-string (length (plist-get chunk :bytes))) "\0"
                           (harness-provider-diagnostics--hex state)
                           (plist-get chunk :bytes)))
            at (+ at (length (plist-get chunk :bytes))))
      (push (list :state state :at at) states))
    (nreverse states)))

(defun harness-provider-diagnostics--checkpoints (chunks indices states)
  "Return checkpoint plists for CHUNKS at INDICES, given chain STATES."
  (cl-loop for index in indices
           for chunk = (nth index chunks)
           for state = (nth index states)
           collect (list :index index
                         :tag (plist-get chunk :tag)
                         :role (plist-get chunk :role)
                         :at (plist-get state :at)
                         :hash (harness-provider-diagnostics--hex
                                (plist-get state :state)))))

(defun harness-provider-diagnostics--compare (previous checkpoints final-index)
  "Compare CHECKPOINTS with the last attempt PREVIOUS.
Return (:kind KIND :at INDEX :tag TAG :preserved N), where KIND is
`first' (no previous record), `unknown' (a previous record with no
checkpoints, or no common checkpoint), `identical' (same final checkpoint and
index), `appended' (every chunk of PREVIOUS is unchanged and the new
request has more), `diverged' (a common checkpoint differs), or
`shorter' (the new request ends before the previous one).  A comparison
needs a common checkpoint; when none exists it returns `unknown'
instead of guessing."
  (cond
   ((null previous)
    (list :kind 'first :at nil :tag nil :preserved 0))
   ((null (harness-provider-diagnostics-attempt-checkpoints previous))
    ;; The previous attempt was skipped (too large or unencodable): there
    ;; is nothing to compare, and no guess is made.
    (list :kind 'unknown :at nil :tag nil :preserved 0))
   (t
    (let* ((old (harness-provider-diagnostics-attempt-checkpoints previous))
           (old-final (harness-provider-diagnostics-attempt-final-index previous))
           (new-map nil))
      (dolist (checkpoint checkpoints)
        (push (cons (plist-get checkpoint :index) checkpoint) new-map))
      (let ((difference nil)
            (matched 0))
        (dolist (checkpoint old)
          (let ((now (cdr (assq (plist-get checkpoint :index) new-map))))
            (when now
              (if (equal (plist-get checkpoint :hash) (plist-get now :hash))
                  (cl-incf matched)
                (unless difference
                  (setq difference (list (plist-get checkpoint :index)
                                         (plist-get now :tag))))))))
        (cond
         (difference
          (list :kind 'diverged :at (car difference) :tag (cadr difference)
                :preserved matched))
         ((and (> matched 0) (integerp old-final) (> old-final final-index))
          (list :kind 'shorter :at old-final :tag nil :preserved matched))
         ((and (integerp old-final) (= old-final final-index)
               (equal (harness-provider-diagnostics-attempt-final previous)
                      (plist-get (car (last checkpoints)) :hash)))
          (list :kind 'identical :at final-index
                :tag (plist-get (car (last checkpoints)) :tag) :preserved matched))
         ((and (integerp old-final)
               (let ((now (cdr (assq old-final new-map))))
                 (and now (equal (harness-provider-diagnostics-attempt-final previous)
                                 (plist-get now :hash)))))
          (list :kind 'appended :at old-final
                :tag (plist-get (cdr (assq old-final new-map)) :tag)
                :preserved matched))
         (t (list :kind 'unknown :at nil :tag nil :preserved matched))))))))

(defun harness-provider-diagnostics--expected-cold (request previous comparison)
  "Return the expected-cold label for REQUEST after PREVIOUS and COMPARISON.
This is the request line's prediction, not evidence: `compaction' when
the session says its cache was reset, `first' when this process has no
earlier attempt, `model-change', `settings-change', `system-change',
`tools-change' or `prefix-diverged' from the first differing checkpoint,
`concurrent' when the earlier request was still in flight (no evidence
either way, and not the client's doing), `idle' when the session's stamp
says the reported lifetime passed, else `warm'."
  (let* ((session (plist-get request :session))
         (usage (and (listp session) (plist-get session :usage)))
         (usage (and (listp usage) usage))
         (pending (and (listp usage) (harness-json-true-p (plist-get usage :cache-pending))))
         (at (and (listp usage) (plist-get usage :cache-at)))
         (ttl (and (listp usage) (plist-get usage :cache-ttl)))
         (idle (and (numberp at) (- (float-time) at))))
    (cond
     (pending "compaction")
     ((null previous) "first")
     ((eq (plist-get comparison :kind) 'first) "unknown")
     ;; The earlier request had not finished when this one was sent, so this
     ;; one was not sent after it but beside it.  What the comparison found
     ;; is still what the bytes say -- `diverged', `appended' -- but the
     ;; difference is no evidence of a client change: a retry, a keep-warm
     ;; refresh and two turns of one session can overlap.  The cause is
     ;; known and it is not the client's, so it is named apart from `warm'
     ;; (which would claim a preserved prefix) and from `unknown' (which
     ;; would claim nothing is known at all).
     ((not (harness-provider-diagnostics-attempt-responded previous)) "concurrent")
     ((eq (plist-get comparison :kind) 'diverged)
      (let ((index (plist-get comparison :at))
            (tag (plist-get comparison :tag)))
        (cond ((equal tag "model") "model-change")
              ((equal tag "settings") "settings-change")
              ((equal tag "tools") "tools-change")
              ((and (stringp tag) (string-prefix-p "system/" tag)) "system-change")
              ((and (integerp index) (= index 0)) "model-change")
              (t "prefix-diverged"))))
     ((eq (plist-get comparison :kind) 'unknown) "unknown")
     ((eq (plist-get comparison :kind) 'shorter) "prefix-shorter")
     ((and (numberp idle) (numberp ttl) (> idle ttl)) "idle")
     (t "warm"))))

;;;; Formatting

(defun harness-provider-diagnostics--number (value)
  "Return VALUE as decimal text, or `unknown'."
  (if (numberp value) (number-to-string value) "unknown"))

(defun harness-provider-diagnostics--name (value)
  "Return VALUE as a quoted log field, or `unknown'.
A response field that is absent, JSON false, or not a string or number
is no reading: `:false` is not an id, and a list is not a provider."
  (if (or (null value) (eq value :false) (eq value t)
          (and (not (stringp value)) (not (numberp value)) (not (symbolp value)))
          (and (stringp value) (string-empty-p value)))
      "unknown"
    (let ((text (format "%s" value)))
      (if (string-match-p "[^A-Za-z0-9._:/@+-]" text)
          (format "%S" text)
        text))))

(defun harness-provider-diagnostics--identity (value)
  "Return VALUE as a log field when it is an identifier, else `unknown'.
An identifier is a non-empty string; a number, `:false' or a list from
malformed JSON is not one, and is not turned into one."
  (if (and (stringp value) (not (string-empty-p value)))
      (harness-provider-diagnostics--name value)
    "unknown"))

(defun harness-provider-diagnostics--checkpoint-field (checkpoint)
  "Return CHECKPOINT as a compact log field."
  (format "%d:%s@%d:%s"
          (plist-get checkpoint :index)
          (plist-get checkpoint :tag)
          (plist-get checkpoint :at)
          (substring (plist-get checkpoint :hash) 0 32)))

(defun harness-provider-diagnostics--line (text)
  "Return TEXT cut to `harness-provider-diagnostics-max-line-chars'."
  (let ((max (max 64 harness-provider-diagnostics-max-line-chars)))
    (if (<= (length text) max)
        text
      (concat (substring text 0 (1- max)) "…"))))

(defun harness-provider-diagnostics--log (level fmt &rest args)
  "Log FMT with ARGS at LEVEL, bounded to the diagnostic line size."
  (let ((text (apply #'format-message fmt args)))
    (harness-log level "%s" (harness-provider-diagnostics--line text))))

;;;; Attempts

(cl-defstruct (harness-provider-diagnostics-attempt (:copier nil))
  "One diagnostic request attempt and what its response said.
RESPONSE is the reading `harness-provider-diagnostics-response' took, or
nil until the attempt ends: the observed provider, model, cache and cost
readings and the outcome, kept so that a caller can correlate them
without parsing the log."
  id session boot key-id scope scope-id configured route host started
  chunks bytes checkpoints final final-index final-at prefix preserved
  diverged-at expected-cold previous-id skipped responded response
  request-number concurrency warm)

(defun harness-provider-diagnostics--remember (attempt)
  "Remember ATTEMPT as the last request of its session.
A keep-warm refresh (`:cache-refresh' on the request, set by
`harness-cache-warm') is not remembered: it is the same request plus a
short message that is never answered into the conversation, so making it
the next request's comparison basis would report the real step that
follows as a changed prefix when nothing the user did changed."
  (let ((session (harness-provider-diagnostics-attempt-session attempt)))
    (when (and (stringp session) (not (string-empty-p session))
               (not (harness-provider-diagnostics-attempt-warm attempt)))
      (puthash session attempt harness-provider-diagnostics--last)
      (setq harness-provider-diagnostics--last-order
            (append (delete session harness-provider-diagnostics--last-order)
                    (list session)))
      (while (> (length harness-provider-diagnostics--last-order)
                harness-provider-diagnostics--max-last)
        (remhash (car harness-provider-diagnostics--last-order)
                 harness-provider-diagnostics--last)
        (setq harness-provider-diagnostics--last-order
              (cdr harness-provider-diagnostics--last-order))))))

(defun harness-provider-diagnostics--session (request)
  "Return REQUEST's session id, or nil."
  (let ((session (plist-get request :session)))
    (cond ((stringp session) session)
          ((listp session) (plist-get session :id))
          (t nil))))

(defun harness-provider-diagnostics--configured (request body)
  "Return the configured route text for REQUEST and BODY.
It names the endpoint and model the harness asked for, never the
serving provider the response reports."
  (or (plist-get request :diagnostics-configured)
      (format "%s:%s"
              (or (plist-get request :diagnostics-endpoint) "unknown")
              (or (plist-get body :model) "unknown"))))

(defun harness-provider-diagnostics--request-line (attempt body)
  "Log the request line of ATTEMPT for BODY and REQUEST."
  (harness-provider-diagnostics--log
   harness-provider-diagnostics-log-level
   "provider-diagnostics: request attempt=%s session=%s boot=%s model=%s configured=%s route=%s host=%s key=%s scope=%s v=%d chunks=%d bytes=%d prefix=%s preserved=%d at=%s expected-cold=%s prev=%s cps=%s final=%d@%d:%s"
   (harness-provider-diagnostics-attempt-id attempt)
   (or (harness-provider-diagnostics-attempt-session attempt) "-")
   (harness-provider-diagnostics-attempt-boot attempt)
   (harness-provider-diagnostics--name (plist-get body :model))
   (harness-provider-diagnostics--name
    (harness-provider-diagnostics-attempt-configured attempt))
   (or (harness-provider-diagnostics-attempt-route attempt) "unknown")
   (or (harness-provider-diagnostics-attempt-host attempt) "unknown")
   (harness-provider-diagnostics-attempt-key-id attempt)
   (harness-provider-diagnostics-attempt-scope-id attempt)
   harness-provider-diagnostics-version
   (harness-provider-diagnostics-attempt-chunks attempt)
   (harness-provider-diagnostics-attempt-bytes attempt)
   (harness-provider-diagnostics-attempt-prefix attempt)
   (harness-provider-diagnostics-attempt-preserved attempt)
   (or (harness-provider-diagnostics-attempt-diverged-at attempt) "-")
   (harness-provider-diagnostics-attempt-expected-cold attempt)
   (or (harness-provider-diagnostics-attempt-previous-id attempt) "-")
   (mapconcat #'harness-provider-diagnostics--checkpoint-field
              (harness-provider-diagnostics-attempt-checkpoints attempt) ",")
   (harness-provider-diagnostics-attempt-final-index attempt)
   (harness-provider-diagnostics-attempt-final-at attempt)
   (substring (harness-provider-diagnostics-attempt-final attempt) 0 16)))

(defun harness-provider-diagnostics--skipped-line (attempt body reason)
  "Log ATTEMPT as skipped for BODY and REQUEST, with REASON."
  (harness-provider-diagnostics--log
   harness-provider-diagnostics-log-level
   "provider-diagnostics: request attempt=%s session=%s boot=%s model=%s configured=%s route=%s host=%s key=%s v=%d prefix=skipped-%s bytes=%d"
   (harness-provider-diagnostics-attempt-id attempt)
   (or (harness-provider-diagnostics-attempt-session attempt) "-")
   (harness-provider-diagnostics-attempt-boot attempt)
   (harness-provider-diagnostics--name (plist-get body :model))
   (harness-provider-diagnostics--name
    (harness-provider-diagnostics-attempt-configured attempt))
   (or (harness-provider-diagnostics-attempt-route attempt) "unknown")
   (or (harness-provider-diagnostics-attempt-host attempt) "unknown")
   (harness-provider-diagnostics-attempt-key-id attempt)
   harness-provider-diagnostics-version reason
   (or (harness-provider-diagnostics-attempt-bytes attempt) 0)))

(defun harness-provider-diagnostics--start (key session scope attempt body request)
  "Fill and log ATTEMPT from BODY for REQUEST under KEY, SESSION and SCOPE."
  (let* ((subkey (harness-provider-diagnostics--subkey key scope))
         (previous (and session (gethash session harness-provider-diagnostics--last)))
         (limit (max 1 harness-provider-diagnostics-max-bytes))
         (chunks (harness-provider-diagnostics--chunks body limit))
         (bytes (if (eq chunks 'large)
                    limit
                  (cl-loop for chunk in chunks
                           sum (length (plist-get chunk :bytes))))))
    (setf (harness-provider-diagnostics-attempt-bytes attempt) bytes
          (harness-provider-diagnostics-attempt-previous-id attempt)
          (and previous (harness-provider-diagnostics-attempt-id previous)))
    (cond
     ((eq chunks 'large)
      (setf (harness-provider-diagnostics-attempt-skipped attempt) 'large)
      (harness-provider-diagnostics--skipped-line attempt body "large"))
     (t
      (let* ((states (harness-provider-diagnostics--chain subkey chunks))
             (indices (harness-provider-diagnostics--select chunks previous))
             (checkpoints (harness-provider-diagnostics--checkpoints
                           chunks indices states))
             (final-index (1- (length chunks)))
             (final-at (plist-get (nth final-index states) :at))
             (final (harness-provider-diagnostics--hex
                     (plist-get (nth final-index states) :state)))
             (comparison (harness-provider-diagnostics--compare
                          previous checkpoints final-index))
             (expected (harness-provider-diagnostics--expected-cold
                        request previous comparison)))
        (setf (harness-provider-diagnostics-attempt-chunks attempt) (length chunks)
              (harness-provider-diagnostics-attempt-checkpoints attempt) checkpoints
              (harness-provider-diagnostics-attempt-final attempt) final
              (harness-provider-diagnostics-attempt-final-index attempt) final-index
              (harness-provider-diagnostics-attempt-final-at attempt) final-at
              (harness-provider-diagnostics-attempt-prefix attempt)
              (symbol-name (plist-get comparison :kind))
              (harness-provider-diagnostics-attempt-preserved attempt)
              (plist-get comparison :preserved)
              (harness-provider-diagnostics-attempt-diverged-at attempt)
              (when (plist-get comparison :at)
                (format "%d:%s" (plist-get comparison :at)
                        (or (plist-get comparison :tag) "?")))
              (harness-provider-diagnostics-attempt-expected-cold attempt) expected)
        (harness-provider-diagnostics--request-line attempt body))))
    (harness-provider-diagnostics--remember attempt)
    attempt))

(defun harness-provider-diagnostics--open (attempt)
  "Count ATTEMPT as in flight; return how many of its session are."
  (let ((session (harness-provider-diagnostics-attempt-session attempt)))
    (if (not (and (stringp session) (not (string-empty-p session))))
        0
      (let ((count (1+ (or (gethash session harness-provider-diagnostics--in-flight) 0))))
        (puthash session count harness-provider-diagnostics--in-flight)
        count))))

(defun harness-provider-diagnostics--close (attempt)
  "Take ATTEMPT out of the in-flight count of its session."
  (let ((session (harness-provider-diagnostics-attempt-session attempt)))
    (when (and (stringp session) (not (string-empty-p session)))
      (let ((count (1- (or (gethash session harness-provider-diagnostics--in-flight) 0))))
        (if (> count 0)
            (puthash session count harness-provider-diagnostics--in-flight)
          (remhash session harness-provider-diagnostics--in-flight))))))

(cl-defun harness-provider-diagnostics-request
    (body request &key configured route host)
  "Start a diagnostic attempt for BODY, the final wire body of REQUEST.
CONFIGURED names the route the harness asked for, ROUTE its dialect and
HOST its configured host.  Return an attempt, or nil when diagnostics
are disabled.  The request line is logged here, before the request is
sent; `harness-provider-diagnostics-response' closes the attempt.
Nothing in BODY's text is logged: only keyed, truncated digests of a
versioned serialization and its lengths.  A diagnostic failure is
logged once and never reaches the provider call."
  (when (harness-provider-diagnostics-enabled-p)
    (condition-case err
        (let* ((key (harness-provider-diagnostics-key))
               (session (harness-provider-diagnostics--session request))
               (scope (harness-provider-diagnostics--scope session)))
          (when key
            (cl-incf harness-provider-diagnostics--sequence)
            (let ((attempt
                   (make-harness-provider-diagnostics-attempt
                    :id (format "pd-%s-%d" harness-provider-diagnostics--boot
                                harness-provider-diagnostics--sequence)
                    :session session :boot harness-provider-diagnostics--boot
                    :key-id (harness-provider-diagnostics--key-id key)
                    :scope scope
                    :scope-id (harness-provider-diagnostics--scope-id key scope)
                    :configured (or configured
                                    (harness-provider-diagnostics--configured request body))
                    :route (and route (format "%s" route))
                    :host host :started (float-time))))
              ;; Taken once ATTEMPT is a value: a `let' init form cannot see
              ;; the variable it binds, so opening it there counts nothing.
              ;; A keep-warm refresh is marked by the request itself
              ;; (`:cache-refresh', set by `harness-cache-warm'), so that
              ;; `--remember' can keep it from becoming the session's basis.
              (setf (harness-provider-diagnostics-attempt-request-number attempt)
                    (cl-incf harness-provider-diagnostics--requests)
                    (harness-provider-diagnostics-attempt-concurrency attempt)
                    (harness-provider-diagnostics--open attempt)
                    (harness-provider-diagnostics-attempt-warm attempt)
                    (and (harness-json-true-p (plist-get request :cache-refresh)) t))
              ;; The attempt is counted above, so a failure from here on --
              ;; writing the request line, most of all -- must give the
              ;; count back: no attempt is returned, so nothing else would
              ;; ever close it, and every later request of the session
              ;; would read as overlapping a request that is long over.
              (condition-case err
                  (harness-provider-diagnostics--start
                   key session scope attempt body request)
                (error
                 (harness-provider-diagnostics--close attempt)
                 (signal (car err) (cdr err)))))))
      (error
       (harness-provider-diagnostics--warn-once
        "request diagnostics failed: %s" (harness-error-message err))
       nil))))

;;;; Usage and response

(defun harness-provider-diagnostics--raw (usage key)
  "Return KEY of USAGE when it is a token count, else nil."
  (and (listp usage)
       (let ((value (plist-get usage key)))
         (and (harness-token-count-p value) value))))

(defun harness-provider-diagnostics--details (usage key)
  "Return KEY of USAGE's prompt or input details when it is a token count.
OpenAI chat completions says `prompt_tokens_details'; the Responses
route says `input_tokens_details'."
  (let ((details (and (listp usage)
                      (or (plist-get usage :prompt_tokens_details)
                          (plist-get usage :input_tokens_details)))))
    (and (listp details)
         (let ((value (plist-get details key)))
           (and (harness-token-count-p value) value)))))

(defun harness-provider-diagnostics-usage (usage usage-event &optional currency)
  "Return the diagnostic reading of raw USAGE and its USAGE-EVENT.
USAGE is the provider's raw usage object; USAGE-EVENT is what the
provider emitted for accounting, or nil.  CURRENCY is the currency the
provider reports costs in, when known.  Missing fields are `unknown',
never zero: a provider that reports no cache field has no reading, and a
cache write no provider reports is not a zero write.  Cost is included
only when it is provider-reported; the event's `subscription' billing
is named as a plan, and no estimate is made here."
  (let* ((prompt (or (harness-provider-diagnostics--raw usage :prompt_tokens)
                     (harness-provider-diagnostics--raw usage :input_tokens)))
         (completion (or (harness-provider-diagnostics--raw usage :completion_tokens)
                         (harness-provider-diagnostics--raw usage :output_tokens)))
         (hit (or (harness-provider-diagnostics--raw usage :prompt_cache_hit_tokens)
                  (harness-provider-diagnostics--details usage :cached_tokens)))
         (write (harness-provider-diagnostics--details usage :cache_write_tokens))
         (reported-cost (and (listp usage) (numberp (plist-get usage :cost))
                             (plist-get usage :cost)))
         (event-cost (and (listp usage-event) (plist-get usage-event :cost)))
         (billing (and (listp usage-event) (plist-get usage-event :billing)))
         (source (cond ((numberp reported-cost) 'provider)
                       ((eq billing 'subscription) 'plan)
                       (t nil)))
         (miss (harness-provider-diagnostics--raw usage :prompt_cache_miss_tokens))
         (input (cond ((and (listp usage-event)
                            (harness-token-count-p (plist-get usage-event :input)))
                       (plist-get usage-event :input))
                      (miss miss)
                      ((and (numberp hit) (numberp prompt) (<= hit prompt))
                       (- prompt hit))
                      (t prompt)))
         (output completion)
         (context prompt)
         (cost (cond ((numberp reported-cost) reported-cost)
                     ((eq billing 'subscription) event-cost)
                     (t nil))))
    (list :prompt prompt :input input :cache-read hit :cache-write write
          :output output :context context
          :cost cost :cost-source source
          :currency (if (and (eq source 'provider) currency) currency "unknown")
          :billing (if billing (format "%s" billing) "unknown"))))

(cl-defun harness-provider-diagnostics-response
    (attempt &key status generation request-id provider served-model usage usage-event currency
             outcome stop error-kind retry-after http-retries)
  "Close diagnostic ATTEMPT with what the provider's response said.
STATUS is the HTTP status; GENERATION the response id (OpenRouter's
generation id is the response id; a field `generation=' is only filled
when it has OpenRouter's `gen-' prefix); REQUEST-ID an HTTP request id
the response supplied; PROVIDER and SERVED-MODEL are only what the
response itself reported,
never inferred from the configured route.  USAGE is the raw usage
object and USAGE-EVENT the event emitted for accounting.  OUTCOME is
`ok', `error' or `cancelled'; STOP the provider's stop reason, and
ERROR-KIND its classified failure.  RETRY-AFTER and HTTP-RETRIES are
numbers when known.  Missing values log `unknown'.  A second call for
the same attempt logs nothing.  No error text, body or prompt is
logged."
  (when (and attempt (not (harness-provider-diagnostics-attempt-responded attempt)))
    (setf (harness-provider-diagnostics-attempt-responded attempt) t)
    ;; The attempt is over, so it no longer shares its session's prefix with
    ;; a request in flight.  Closed before the logging below, so a failure to
    ;; log still releases the count.
    (harness-provider-diagnostics--close attempt)
    (condition-case err
        (let* ((reading (harness-provider-diagnostics-usage usage usage-event currency))
           (outcome-name (cond ((eq outcome 'cancelled) "cancelled")
                               ((eq outcome 'error) "error")
                               (t "ok")))
           (source (plist-get reading :cost-source))
           (response-id (and (stringp generation) (not (string-empty-p generation))
                             generation))
           (generation-id (and response-id
                               (string-prefix-p "gen-" response-id)
                               response-id)))
      (harness-provider-diagnostics--log
       harness-provider-diagnostics-log-level
       "provider-diagnostics: response attempt=%s session=%s boot=%s key=%s status=%s response-id=%s generation=%s request-id=%s provider=%s served-model=%s configured=%s route=%s host=%s outcome=%s stop=%s error-kind=%s retry-after=%s http-retries=%s prompt=%s input=%s cache-read=%s cache-write=%s output=%s context=%s cost=%s cost-source=%s currency=%s billing=%s expected-cold=%s prefix=%s"
       (harness-provider-diagnostics-attempt-id attempt)
       (or (harness-provider-diagnostics-attempt-session attempt) "-")
       (harness-provider-diagnostics-attempt-boot attempt)
       (harness-provider-diagnostics-attempt-key-id attempt)
       (harness-provider-diagnostics--number status)
       (harness-provider-diagnostics--identity response-id)
       (harness-provider-diagnostics--identity generation-id)
       (harness-provider-diagnostics--identity request-id)
       (harness-provider-diagnostics--identity provider)
       (harness-provider-diagnostics--identity served-model)
       (harness-provider-diagnostics--name
        (harness-provider-diagnostics-attempt-configured attempt))
       (or (harness-provider-diagnostics-attempt-route attempt) "unknown")
       (or (harness-provider-diagnostics-attempt-host attempt) "unknown")
       outcome-name
       (harness-provider-diagnostics--name stop)
       (harness-provider-diagnostics--name (or error-kind 'unknown))
       (harness-provider-diagnostics--number retry-after)
       (harness-provider-diagnostics--number http-retries)
       (harness-provider-diagnostics--number (plist-get reading :prompt))
       (harness-provider-diagnostics--number (plist-get reading :input))
       (harness-provider-diagnostics--number (plist-get reading :cache-read))
       (harness-provider-diagnostics--number (plist-get reading :cache-write))
       (harness-provider-diagnostics--number (plist-get reading :output))
       (harness-provider-diagnostics--number (plist-get reading :context))
       (harness-provider-diagnostics--number (plist-get reading :cost))
       (if source (format "%s" source) "unknown")
       (plist-get reading :currency)
       (plist-get reading :billing)
       (or (harness-provider-diagnostics-attempt-expected-cold attempt) "unknown")
       (or (harness-provider-diagnostics-attempt-prefix attempt)
           (if (harness-provider-diagnostics-attempt-skipped attempt)
               (format "skipped-%s" (harness-provider-diagnostics-attempt-skipped attempt))
             "unknown")))
      ;; Keep the reading, so a caller can correlate an attempt with what
      ;; the provider said without parsing the log.  The unknowns the line
      ;; says are unknowns here too; nothing is filled in.
      (setf (harness-provider-diagnostics-attempt-response attempt)
            (list :status status
                  :response-id (and (stringp response-id) response-id)
                  :generation (and (stringp generation-id) generation-id)
                  :request-id (and (stringp request-id) request-id)
                  :provider (and (stringp provider) provider)
                  :served-model (and (stringp served-model) served-model)
                  :configured (harness-provider-diagnostics-attempt-configured attempt)
                  :outcome outcome
                  :stop stop
                  :error-kind error-kind
                  :prefix (harness-provider-diagnostics-attempt-prefix attempt)
                  :preserved (harness-provider-diagnostics-attempt-preserved attempt)
                  :expected-cold (harness-provider-diagnostics-attempt-expected-cold attempt)
                  :prompt (plist-get reading :prompt)
                  :cache-read (plist-get reading :cache-read)
                  :cache-write (plist-get reading :cache-write)
                  :output (plist-get reading :output)
                  :cost (plist-get reading :cost)
                  :cost-source source
                  :currency (plist-get reading :currency)
                  :billing (plist-get reading :billing)
                  :at (float-time))))
      (error
       (harness-provider-diagnostics--warn-once
        "response diagnostics failed: %s" (harness-error-message err))))))

;;;; Reading an attempt back

(defun harness-provider-diagnostics-last-attempt (session)
  "Return the last attempt diagnostics recorded for SESSION, or nil.
The answer is a `harness-provider-diagnostics-attempt'; `...-summary'
turns it into a plist a caller can keep.  A session diagnostics never
saw, or one whose record was evicted from the bounded table, answers nil
rather than a guess."
  (and (stringp session) (not (string-empty-p session))
       (gethash session harness-provider-diagnostics--last)))

(defun harness-provider-diagnostics-summary (attempt)
  "Return ATTEMPT as a content-free plist, or nil.
The plist is `(:attempt :at :prefix :preserved :expected-cold
:configured :route :host :response)': RESPONSE is the reading
`harness-provider-diagnostics-response' took, or nil when the attempt did
not end.  Nothing raw is in it -- no prompt text, tool text, body,
credential or key -- so a caller may keep or log it."
  (when attempt
    (list :attempt (harness-provider-diagnostics-attempt-id attempt)
          :at (harness-provider-diagnostics-attempt-started attempt)
          :prefix (harness-provider-diagnostics-attempt-prefix attempt)
          :preserved (harness-provider-diagnostics-attempt-preserved attempt)
          :expected-cold (harness-provider-diagnostics-attempt-expected-cold attempt)
          :configured (harness-provider-diagnostics-attempt-configured attempt)
          :route (harness-provider-diagnostics-attempt-route attempt)
          :host (harness-provider-diagnostics-attempt-host attempt)
          :response (harness-provider-diagnostics-attempt-response attempt))))

(defun harness-provider-diagnostics-session-summary (session)
  "Return `harness-provider-diagnostics-summary' of SESSION's last attempt, or nil.
Nil says diagnostics have no record of the session -- the module is off,
the session made no request in this process, or its record was evicted --
which is unknown, never a reading of zero."
  (harness-provider-diagnostics-summary
   (harness-provider-diagnostics-last-attempt session)))

(defconst harness-provider-diagnostics-client-cold-causes
  '("first" "compaction" "model-change" "settings-change" "system-change"
    "tools-change" "prefix-diverged" "prefix-shorter" "idle")
  "The `expected-cold' labels that name a cause on the client's side.
A label in this list says the harness changed something the provider's
prefix cache would key on, or that no earlier request existed.  `warm'
says the harness preserved the prefix and recorded no client cause; it
does not prove the provider kept it.")

(defun harness-provider-diagnostics-cold-cause (summary)
  "Return what SUMMARY says about a request's cold read, or `unknown'.
SUMMARY is `harness-provider-diagnostics-summary' output, or nil.
The answer is the request line's `expected-cold' label when it is one of
`harness-provider-diagnostics-client-cold-causes' -- a cause on the
client's side, which the harness can fix -- `warm' when the harness
preserved the prefix and recorded no client cause, and `unknown' when
diagnostics have no record of the request.  `warm' with a zero cache read
is the provider-side case; neither label is proof of a cause on its own,
and `unknown' is not evidence that nothing changed."
  (let ((label (and summary (plist-get summary :expected-cold))))
    (cond ((member label harness-provider-diagnostics-client-cold-causes) label)
          ((equal label "warm") "warm")
          (t "unknown"))))

(defun harness-provider-diagnostics-miss-cause (session)
  "Return the cold-cause label for SESSION's last request, or `unknown'.
See `harness-provider-diagnostics-cold-cause'; nil is `unknown' because
diagnostics have no record of the session, never because nothing
changed."
  (harness-provider-diagnostics-cold-cause
   (harness-provider-diagnostics-session-summary session)))


(harness-define-module 'provider-diagnostics
  :doc "Content-free request-prefix and observed serving-provider diagnostics.")

(provide 'harness-provider-diagnostics)
;;; harness-provider-diagnostics.el ends here
