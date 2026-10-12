;;; harness-ui-secrets.el --- Redact a secret, and name the secrets to mask  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; The user's side of keeping secrets out of what the harness stores
;; (harness-redact.el and harness-secrets.el do the work in the harness
;; process).
;;
;; `harness-redact-secret' takes a secret out of every copy the harness
;; keeps of a transcript: node logs, the search index, the conversation
;; logs of Claude Code and Copilot, transcript files, task records and
;; logs.  The secret is named by where it can be read, so that it is
;; never typed, shown or sent unless you choose to type it:
;;
;; - a JSON path in a file.  The paths to choose from come from the keys
;;   and types of the file (`_harness/secrets/shape'), never from its
;;   values;
;; - a regexp with one capture group around the secret, in a file;
;; - an environment variable of the harness;
;; - a command that prints it, run by the harness, whose output is
;;   not recorded;
;; - the value itself, typed with `read-passwd': never echoed, never in
;;   a history or a message, sent only to a harness on this machine, and
;;   cleared from memory once the request is done.
;;
;; It then asks for a label (the name the placeholder carries, with the
;; first 8 hex digits of the secret's SHA-256), the sessions to clean --
;; every session, the project's, the current session and its forks, or
;; sessions named by id -- and a reason, which is kept in the records.
;; The harness scans first and the buffer *harness redaction* shows what
;; the scan found, counts and ids only, never a snippet of text.  Nothing
;; changes until you confirm, and the question says what the redaction
;; costs in prompt cache: a session on a hosted provider (Claude Code,
;; Copilot) whose conversation held the secret starts a new one, and the
;; cache of the old one goes with it, so its next message asks what goes
;; first.  The redaction then runs and the buffer shows its report, which
;; says what is left, if anything.  The requests have no deadline: the
;; harness rebuilds and vacuums the search index before it answers, which
;; can take minutes for a large one, and the buffer says that it is
;; working until the report arrives.  A session
;; that runs a turn is cleaned at once, but its provider conversation
;; starts over only when the turn ends: the report lists such sessions,
;; says that the redaction is not complete yet, and the harness goes on
;; by itself afterwards.
;;
;; `harness-secrets-add-source' adds a source to the registry of secrets
;; that tool output is masked of, before anything keeps it
;; (`harness-secrets-sources' holds the sources of your init file).
;; `harness-secrets-list-sources' lists them, with the fingerprints of
;; their values and why one could not be read: `d' stops masking a source
;; added by hand, `a' adds one, `g' reads them again.  `harness-redactions'
;; lists the redactions the harness has run: when, who asked, why, which
;; secrets (by label and fingerprint) and how many occurrences in each
;; store; RET shows one whole.
;;
;; What the harness announces is followed here:
;;
;; - `session/redacted': the chat of that session loads its transcript
;;   again, so it shows what is stored now (and the hint that says what
;;   was redacted) rather than what it drew before.  The UI cannot see
;;   the redacted nodes any other way.
;; - `secrets/redacted': the harness's own log buffers are cleaned in the
;;   harness, but this Emacs has buffers of its own that hold logs:
;;   *harness-log* (the harness's log lines are copied into it),
;;   *Messages*, and every buffer named *harness... that visits no file.
;;   When the secret was named by a file or a variable that this Emacs can
;;   read too, it reads the secret itself, checks that its fingerprint is
;;   one the harness redacted, and takes it out of those buffers.  A
;;   secret it cannot read, or whose fingerprint differs, leaves them
;;   alone, and so does a harness on another machine.  A buffer that
;;   visits a file is never touched.
;;
;; Redaction cannot recall what the model provider already received, and
;; it cannot reach a copy kept outside Emacs and the harness: a kill
;; ring, a terminal's scrollback, a screenshot.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'crm)
(require 'tabulated-list)
(require 'transient)
(require 'harness-core)
(require 'harness-util)
(require 'harness-redaction)
(require 'harness-ui)

(declare-function harness-chat--buffer-for "harness-ui-chat" (sid))
(declare-function harness-chat--load "harness-ui-chat" (&optional keep-bottom))

(defgroup harness-ui-secrets nil
  "Redacting secrets from what the harness stored." :group 'harness-ui)

(defcustom harness-ui-secrets-report-buffer-name "*harness redaction*"
  "Name of the buffer that shows what a redaction found and did."
  :type 'string :group 'harness-ui-secrets)

(defcustom harness-ui-secrets-sources-buffer-name "*harness secrets*"
  "Name of the buffer that lists the sources of the secrets masked."
  :type 'string :group 'harness-ui-secrets)

(defcustom harness-ui-secrets-log-buffer-name "*harness redactions*"
  "Name of the buffer that lists the redactions the harness has run."
  :type 'string :group 'harness-ui-secrets)

(defconst harness-ui-secrets--names-limit 4
  "Most secrets a prompt or a message names before it counts the rest.")

(defconst harness-ui-secrets--fingerprints-limit 4
  "Most fingerprints a row of the sources list shows before it counts the rest.")

(defconst harness-ui-secrets--source-width 46
  "Width of the Source column of the sources list, unless a source needs more.")

(defconst harness-ui-secrets--source-width-limit 100
  "Widest the Source column grows to, for a source with a long file name.")

;;;; Small helpers

(defun harness-ui-secrets--n (n word)
  "Return N and WORD, with an s when N is not 1."
  (format "%d %s%s" n word (if (= n 1) "" "s")))

(defun harness-ui-secrets--error-text (err)
  "Describe ERR without its data, which could quote what a request held.
A rejection of the harness reads as its message, which the harness
writes for a method that takes a secret without the secret in it; a Lisp
error reads as its kind."
  (cond ((and (eq (car-safe err) 'acp-error) (stringp (nth 2 err)) (not (string-empty-p (nth 2 err))))
         (nth 2 err))
        ((and (consp err) (symbolp (car err))
              (memq 'harness-error (get (car err) 'error-conditions))
              (stringp (cadr err)) (null (cddr err)))
         (cadr err))
        ((and (consp err) (symbolp (car err))) (format "%s" (car err)))
        (t "an error")))

(defun harness-ui-secrets--callback (thunk &optional on-abort)
  "Call THUNK, the rest of a command that an answer from the harness continues.
A `user-error' or a quit ends it with a message, and any other error is
logged by its kind and message, never by its data, which could quote a
secret: nothing here may let one into the log.  ON-ABORT is called when
THUNK did not finish."
  (let ((done nil))
    (unwind-protect
        (condition-case err
            (prog1 (funcall thunk) (setq done t))
          (user-error (message "%s" (error-message-string err)))
          (quit (message "Cancelled"))
          (error (let ((text (harness-ui-secrets--error-text err)))
                   (harness-log 'error "secrets: %s" text)
                   (message "Harness: that failed: %s" text))))
      (unless done
        (when on-abort (funcall on-abort))))))

(defun harness-ui-secrets--address-host ()
  "Return the host of the harness the UI talks to, or nil for this machine's own."
  (let ((address harness-ui-connection-address))
    (cond ((consp address) (format "%s" (car address)))
          ((stringp address)
           (let ((host (if (string-match "\\`\\(.*\\):[0-9]+\\'" address)
                           (match-string 1 address)
                         address)))
             (string-trim host "\\[" "\\]"))))))

(defun harness-ui-secrets--local-p ()
  "Non-nil when the harness the UI talks to runs on this machine.
That is the harness of this Emacs (`harness-ui-connection-address' nil),
the harness process it manages (`process'), or a harness at a loopback
address: 127.0.0.1, localhost or ::1."
  (let ((address harness-ui-connection-address))
    (cond ((or (null address) (eq address 'process)) t)
          (t (let ((host (harness-ui-secrets--address-host)))
               (and host
                    (or (member host '("localhost" "::1"))
                        ;; An address, not a name that starts like one.
                        (string-match-p "\\`127\\.[0-9]+\\.[0-9]+\\.[0-9]+\\'" host))
                    t))))))

(defun harness-ui-secrets--require-local (what)
  "Signal a `user-error' unless the harness is on this machine.
WHAT is what would be sent to it."
  (unless (harness-ui-secrets--local-p)
    (user-error "%s goes only to a harness on this machine, and this UI talks to %s: name where the secret can be read instead (a file with a JSON path or a regexp, or an environment variable)"
                what (or (harness-ui-secrets--address-host) "another one"))))

(defun harness-ui-secrets--names (secrets)
  "Describe SECRETS, plists with a :label and a :fingerprint, by those two."
  (let* ((secrets (append secrets nil))
         (shown (take harness-ui-secrets--names-limit secrets))
         (text (mapconcat (lambda (s) (format "%s (sha256:%s)" (plist-get s :label) (plist-get s :fingerprint)))
                          shown ", ")))
    (if (> (length secrets) (length shown))
        (format "%s and %d more" text (- (length secrets) (length shown)))
      text)))

;;;; Where the secret is

(defconst harness-ui-secrets--kinds
  '(("File and JSON path" . json)
    ("File and regexp" . regexp)
    ("Environment variable" . env)
    ("Type it (hidden)" . literal)
    ("Command output" . command))
  "The ways to name a secret, as the prompt offers them.")

(defun harness-ui-secrets--path-label (path)
  "Return a label for JSON PATH: its last segment that says what it is, or nil.
The `value' of a Terraform output and an index say nothing."
  (cl-find-if (lambda (segment)
                (not (or (string= segment "value") (string-match-p "\\`[0-9]+\\'" segment))))
              (nreverse (split-string path "[^[:alnum:]_-]+" t))))

(defun harness-ui-secrets--default-label (ref)
  "Return the label REF, a reference to a secret, gets unless you choose another."
  (cond ((and (stringp (plist-get ref :json-path)) (stringp (plist-get ref :file)))
         (or (harness-ui-secrets--path-label (plist-get ref :json-path))
             (file-name-base (plist-get ref :file))))
        ((stringp (plist-get ref :file)) (file-name-base (plist-get ref :file)))
        ((stringp (plist-get ref :env)) (plist-get ref :env))
        ((plist-member ref :command) "command output")
        (t "secret")))

(defun harness-ui-secrets--source (ref &rest props)
  "Return the source made of REF, a reference, and PROPS.
It is (:ref REF :label DEFAULT-LABEL :ui-secrets unknown PROPS...).  PROPS
may have :unsafe, which says the harness has to be allowed to take REF (a
typed secret or a command), and :value, the typed secret, which
`harness-ui-secrets--forget' clears.  :ui-secrets keeps the secrets this
Emacs works out for itself (`harness-ui-secrets--ui-secrets')."
  (append (list :ref ref :label (harness-ui-secrets--default-label ref) :ui-secrets 'unknown)
          props))

(defun harness-ui-secrets--forget (source)
  "Clear the typed secret of SOURCE from memory, if it has one.
It is the same string the request holds, so this runs only when the last
request that carries it has been answered."
  (let ((value (plist-get source :value)))
    (when (stringp value)
      (clear-string value))))

(defun harness-ui-secrets--read-file (prompt)
  "Read the name of a file with PROMPT; return it as the harness should read it.
For a harness on this machine the name is completed and expanded here.
The file of a harness on another machine is on that machine, so the name
is typed, and sent as typed for the harness to expand."
  (let* ((local (harness-ui-secrets--local-p))
         (file (if local
                   (read-file-name prompt nil nil nil)
                 (string-trim (read-string (concat prompt "(a path on the harness's machine) "))))))
    (when (or (string-empty-p file) (directory-name-p file))
      (user-error "Name a file"))
    (if local (expand-file-name file) file)))

(defun harness-ui-secrets--read-regexp ()
  "Read a regexp with one capture group around the secret."
  (let ((regexp (read-string "Regexp with one group around the secret, \\(...\\): ")))
    (when (string-empty-p regexp)
      (user-error "Give a regexp"))
    ;; A group that captures: \( not followed by ?, or by ?N: (a numbered
    ;; one).  A shy group, \(?:, does not.
    (unless (string-match-p "\\\\(\\(?:[^?]\\|\\?[0-9]+:\\)" regexp)
      (user-error "The regexp needs a capture group, \\(...\\), around the secret"))
    regexp))

(defun harness-ui-secrets--choose-path (file shape)
  "Ask which JSON path of FILE holds the secret; return it, or nil if you decline.
SHAPE is what `_harness/secrets/shape' says of FILE: the path and the
type of every node, never a value.  Only objects, arrays and strings can
hold a secret, so only they are offered, in the order of the document.
The root, the whole document, is the default; since that makes every
string in the file a secret, it is asked about again."
  (let* ((entries (cl-remove-if-not (lambda (e) (member (plist-get e :type) '("object" "array" "string")))
                                    (append (plist-get shape :paths) nil)))
         (truncated (harness-json-true-p (plist-get shape :truncated)))
         (types (make-hash-table :test 'equal))
         (candidates (mapcar (lambda (e) (plist-get e :path)) entries)))
    (dolist (e entries) (puthash (plist-get e :path) (plist-get e :type) types))
    (when (and (not truncated) (not (cl-some (lambda (e) (equal (plist-get e :type) "string")) entries)))
      (user-error "%s holds no string that could be a secret" (abbreviate-file-name file)))
    (let* ((root (or (car candidates) "$"))
           (table (lambda (string pred action)
                    (if (eq action 'metadata)
                        (list 'metadata
                              (cons 'display-sort-function #'identity)
                              (cons 'cycle-sort-function #'identity)
                              (cons 'annotation-function
                                    (lambda (candidate)
                                      (when-let* ((type (gethash candidate types)))
                                        (propertize (format "  %s" type) 'face 'harness-dim-face)))))
                      (complete-with-action action candidates string pred))))
           (path (completing-read (format "JSON path in %s (RET: the whole file): "
                                          (file-name-nondirectory file))
                                  table nil (not truncated) nil nil root))
           (path (if (string-empty-p path) root path)))
      (if (and (member path (list root "$" ""))
               (not (yes-or-no-p (format "%s names every string in %s. Redact them all? "
                                         path (file-name-nondirectory file)))))
          nil
        path))))

(defun harness-ui-secrets--read-json (k)
  "Ask for a JSON file and a path in it, then call K with the source.
The file's shape comes from the harness, which reads the file: the paths
are keys and types, never values.  K runs when the answer arrives."
  (let ((file (harness-ui-secrets--read-file "JSON file that holds the secret: ")))
    (message "Reading the keys of %s…" (abbreviate-file-name file))
    (harness-ui-call
     "_harness/secrets/shape" (list :file file)
     (lambda (shape)
       (message nil)
       (harness-ui-secrets--callback
        (lambda ()
          (when-let* ((path (harness-ui-secrets--choose-path file shape)))
            (funcall k (harness-ui-secrets--source (list :file file :json-path path)))))))
     (lambda (err)
       (unless (harness-ui-connection-replaced-p err)
         (message "Harness: cannot read the keys of %s: %s" (abbreviate-file-name file)
                  (harness-ui-secrets--error-text err)))))))

(defun harness-ui-secrets--read-source (allow-literal k)
  "Ask where the secret is, then call K with the source.
ALLOW-LITERAL says whether it may be typed; a secret typed in is for a
harness on this machine only.  K is called at once, except for a JSON
file, whose keys come from the harness first."
  (let* ((choices (cl-remove-if (lambda (c) (and (not allow-literal) (eq (cdr c) 'literal)))
                                harness-ui-secrets--kinds))
         (choice (completing-read "Where is the secret? " (mapcar #'car choices) nil t nil nil (caar choices)))
         (kind (cdr (assoc choice choices))))
    (pcase kind
      ('json (harness-ui-secrets--read-json k))
      ('regexp
       (let* ((file (harness-ui-secrets--read-file "File that holds the secret: "))
              (regexp (harness-ui-secrets--read-regexp)))
         (funcall k (harness-ui-secrets--source (list :file file :regexp regexp)))))
      ('env
       (let ((name (string-trim (read-string "Environment variable of the harness: "))))
         (when (string-empty-p name) (user-error "Give the name of a variable"))
         (funcall k (harness-ui-secrets--source (list :env name)))))
      ('literal
       (harness-ui-secrets--require-local "A typed secret")
       (let ((value (read-passwd "Secret to redact (hidden): " t)))
         (when (string-empty-p value) (user-error "Nothing was typed"))
         (funcall k (harness-ui-secrets--source (list :literal value) :unsafe t :value value))))
      ('command
       (let ((command (string-trim (read-string "Shell command that prints the secret (the harness runs it): "))))
         (when (string-empty-p command) (user-error "Give a command"))
         (funcall k (harness-ui-secrets--source (list :command command) :unsafe t))))
      (_ (user-error "Unknown way to name a secret")))))

(defun harness-ui-secrets--read-label (source)
  "Ask for the label of SOURCE's placeholder; its default comes from the path."
  (let* ((default (plist-get source :label))
         (input (read-string (format "Label for the placeholder (default %s): " default) nil nil default)))
    (if (string-blank-p input) default (string-trim input))))

(defun harness-ui-secrets--read-reason ()
  "Ask why the secret is redacted; return the answer, or nil if it is empty."
  (let ((reason (string-trim (read-string "Reason (kept in the records, may stay empty): "))))
    (unless (string-empty-p reason) reason)))

;;;; Which sessions

(defun harness-ui-secrets--read-scope ()
  "Ask which sessions to clean; return the scope.
The scope is (:scope SCOPE ...): `all'; `project' with the :project
directory; or `session' with the :sessions ids, whose forks are cleaned
too.  The current session and its forks are offered in a buffer that
shows a session."
  (let* ((sid harness-ui-session-id)
         (choices (append '("All sessions" "This project")
                          (and sid '("This session and its forks"))
                          '("Sessions…")))
         (choice (completing-read "Clean: " choices nil t nil nil (car choices))))
    (pcase choice
      ("All sessions" (list :scope "all"))
      ("This project"
       (let ((project (or (and sid (plist-get (harness-ui-session sid) :project))
                          (if (harness-ui-secrets--local-p)
                              (read-directory-name "Project directory: " default-directory nil t)
                            (read-string "Project directory (on the harness's machine): ")))))
         (when (or (not (stringp project)) (string-empty-p (string-trim project)))
           (user-error "Name a project directory"))
         (list :scope "project"
               :project (directory-file-name (if (harness-ui-secrets--local-p)
                                                 (expand-file-name project)
                                               (string-trim project))))))
      ("This session and its forks" (list :scope "session" :sessions (list sid)))
      (_
       (let* ((names (mapcar (lambda (s) (cons (plist-get s :id) (harness-ui-session-label s)))
                             (harness-ui-sessions)))
              (completion-extra-properties
               (list :annotation-function
                     (lambda (id) (format "  %s" (or (cdr (assoc id names)) "")))))
              (ids (completing-read-multiple "Session ids, separated by commas: "
                                             (mapcar #'car names)))
              (ids (delete-dups (cl-remove-if #'string-empty-p (mapcar #'string-trim ids)))))
         (unless ids (user-error "Name at least one session"))
         (list :scope "session" :sessions ids))))))

;;;; Redacting

(defun harness-ui-secrets--params (source label scope reason mode)
  "Return the params of `_harness/secrets/redact' that do MODE, \"scan\" or \"redact\".
SOURCE, LABEL, SCOPE and REASON are as `harness-ui-secrets-redact' takes
them.  The request comes from the user, and says so."
  (list :params
        (append
         (list :source (plist-get source :ref)
               :scope (plist-get scope :scope)
               :mode mode
               :origin (list :kind "user"))
         (and label (not (string-empty-p label)) (list :label label))
         (and reason (list :reason reason))
         (and (plist-get scope :project) (list :project (plist-get scope :project)))
         (and (plist-get scope :sessions)
              (list :sessions (harness-json-array (plist-get scope :sessions)) :include-forks t))
         (and (plist-get source :unsafe) (list :allow-unsafe-sources t)))))

(defun harness-ui-secrets--log-buffers ()
  "Return the buffers of this Emacs that hold logs, for a redaction to clean.
They are *Messages*, *harness-log* and every live buffer whose name
starts with \"*harness\" and that visits no file, nor is an indirect
buffer of one that does."
  (cl-remove-if-not
   (lambda (buffer)
     (let ((name (buffer-name buffer)))
       (and name
            (or (equal name "*Messages*") (string-prefix-p "*harness" name))
            (null (buffer-file-name buffer))
            (let ((base (buffer-base-buffer buffer)))
              (null (and base (buffer-file-name base)))))))
   (buffer-list)))

(defun harness-ui-secrets--clean-buffers (secrets &optional dry-run)
  "Take SECRETS out of the log buffers of this Emacs; return (COUNT . NAMES).
COUNT is the occurrences found and NAMES the buffers that held some.
With DRY-RUN only count them."
  (let ((count 0) (names nil))
    (dolist (buffer (harness-ui-secrets--log-buffers))
      (condition-case err
          (let ((n (harness-redaction-buffer buffer secrets dry-run)))
            (when (> n 0)
              (cl-incf count n)
              (push (buffer-name buffer) names)))
        (error (harness-log 'warn "secrets: %s could not be cleaned: %s"
                            (buffer-name buffer) (harness-ui-secrets--error-text err)))))
    (cons count (nreverse names))))

(defun harness-ui-secrets--named (secret named)
  "Return the entry of NAMED that has the fingerprint of SECRET, or nil.
NAMED are plists with a :label and a :fingerprint, SECRET one with a
:fingerprint."
  (cl-find (plist-get secret :fingerprint) named
           :key (lambda (n) (plist-get n :fingerprint)) :test #'equal))

(defun harness-ui-secrets--matching (ref named)
  "Return the secrets REF names that this Emacs reads as the harness did.
NAMED are the secrets the harness redacted, plists with a :label and a
:fingerprint.  REF is resolved here (`harness-redaction-resolve'); the
result is nil unless every secret it gives has a fingerprint among NAMED,
so a file or a variable that differs here from there is left alone.  Each
secret has the label the harness gave it, which its placeholder carries."
  (let ((resolved (condition-case nil
                      (plist-get (harness-redaction-resolve ref) :secrets)
                    (error nil)))
        (named (append named nil)))
    (when (and resolved
               (cl-every (lambda (s) (harness-ui-secrets--named s named)) resolved))
      (mapcar (lambda (s)
                (let ((label (plist-get (harness-ui-secrets--named s named) :label)))
                  (if (stringp label) (plist-put (copy-sequence s) :label label) s)))
              resolved))))

(defun harness-ui-secrets--ui-secrets (source named)
  "Return the secrets of SOURCE this Emacs knows by itself.
That is the typed secret, and the output of a command, which the harness
ran and this Emacs runs again: the harness cannot clean the buffers of
this Emacs, so the command does.  Each has the label the harness gave
it.  NAMED are the secrets the harness reports, plists with a :label
and a :fingerprint."
  (let ((ref (plist-get source :ref)))
    (cond
     ((stringp (plist-get ref :literal))
      (let* ((value (plist-get ref :literal))
             (label (plist-get (harness-ui-secrets--named
                                (list :fingerprint (harness-redaction-fingerprint value))
                                (append named nil))
                               :label)))
        (list (harness-redaction-secret value (if (stringp label) label (plist-get source :label))))))
     ;; The command is the harness's to run where it is; a harness on
     ;; another machine would print another machine's secret here.
     ((and (stringp (plist-get ref :command)) named (harness-ui-secrets--local-p))
      (harness-ui-secrets--matching ref named)))))

(defun harness-ui-secrets--safe-text (text source)
  "Return TEXT without the typed secret of SOURCE, which a message could quote."
  (let ((value (plist-get (plist-get source :ref) :literal)))
    (if (and (stringp value) (stringp text))
        (car (harness-redaction-string text (list (harness-redaction-secret value "secret"))))
      text)))

;;;; The report

(defvar harness-ui-secrets-report-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map harness-ui-view-map)
    (define-key map (kbd "?") #'harness-menu)
    map)
  "Keymap of `harness-ui-secrets-report-mode'.")

(define-derived-mode harness-ui-secrets-report-mode special-mode "Redaction"
  "Major mode of the buffer that reports a redaction: what it found and did.
The report is made of labels, fingerprints, session ids and counts; it
holds no secret and no snippet of the text that held one.  q buries it.

\\{harness-ui-secrets-report-mode-map}"
  (setq truncate-lines nil))

(defun harness-ui-secrets--ui-lines (ui-hits dry)
  "Return the text that says what UI-HITS, (COUNT . BUFFER-NAMES), found in Emacs.
DRY says it was a count and nothing changed."
  (if (or (null ui-hits) (zerop (car ui-hits)))
      ""
    (format "Buffers of this Emacs: %s %s in %s.\n"
            (harness-ui-secrets--n (car ui-hits) "occurrence")
            (if dry "found" "found and redacted")
            (mapconcat #'identity (cdr ui-hits) ", "))))

(defun harness-ui-secrets--show-report (status &optional report ui-hits dry)
  "Show STATUS in the redaction report buffer, then REPORT's text and UI-HITS.
REPORT is what `_harness/secrets/redact' answered, UI-HITS the count
of the buffers of this Emacs, (COUNT . NAMES), and DRY says that was a
count.  Return the buffer."
  (let ((buffer (get-buffer-create harness-ui-secrets-report-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'harness-ui-secrets-report-mode)
        (harness-ui-secrets-report-mode))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "Redaction of a secret" 'face 'bold) "\n"
                (propertize status 'face 'harness-dim-face) "\n\n")
        (when report
          (insert (let ((text (plist-get report :text)))
                    (if (stringp text) text "The harness gave no report."))
                  "\n"))
        (when ui-hits
          (insert (harness-ui-secrets--ui-lines ui-hits dry)))
        (goto-char (point-min))))
    (unless (get-buffer-window buffer 'visible)
      (harness-ui-display-view buffer))
    buffer))

(defun harness-ui-secrets--cache-cost (report)
  "Return the clause of the question that says what REPORT's redaction costs.
REPORT is the scan.  The clause is \"; 2 provider conversations start
over, dropping ~126k tokens of prompt cache\" for the sessions the scan
says a reset would drop the cache of (`:cache-would-drop'), the tokens
being their `:context'; it is \"\" when the scan names none.  A
conversation that starts over with no cache to drop costs nothing more,
so it is not counted."
  (let* ((drops (cl-remove-if-not (lambda (s) (harness-json-true-p (plist-get s :cache-would-drop)))
                                  (append (plist-get report :sessions) nil)))
         (n (length drops))
         (tokens (apply #'+ (mapcar (lambda (s) (let ((c (plist-get s :context))) (if (numberp c) c 0)))
                                    drops))))
    (if (zerop n)
        ""
      (format "; %s %s over, dropping %s"
              (harness-ui-secrets--n n "provider conversation")
              (if (= n 1) "starts" "start")
              (if (> tokens 0)
                  (format "~%s %s of prompt cache" (harness-format-tokens tokens)
                          (if (= tokens 1) "token" "tokens"))
                "their prompt cache")))))

(defun harness-ui-secrets--prompt (report ui-count)
  "Return the question that asks whether to redact what REPORT found.
UI-COUNT is the occurrences found in the buffers of this Emacs.  It ends
with what the redaction would cost in prompt cache, when it would drop
some (`harness-ui-secrets--cache-cost'): the user is told before the
conversations start over, not after."
  (format "Redact %s of %s from %s%s%s? "
          (harness-ui-secrets--n (or (plist-get report :total) 0) "occurrence")
          (harness-ui-secrets--names (plist-get report :secrets))
          (or (plist-get report :scope) "the sessions chosen")
          (if (> ui-count 0)
              (format ", and %s in the buffers of this Emacs" (harness-ui-secrets--n ui-count "occurrence"))
            "")
          (harness-ui-secrets--cache-cost report)))

(defun harness-ui-secrets--refresh-logs ()
  "Read the redactions log again in the buffers that show it."
  (dolist (buffer (buffer-list))
    (when (eq (buffer-local-value 'major-mode buffer) 'harness-ui-secrets-log-mode)
      (harness-ui-secrets--refresh-log buffer))))

(defun harness-ui-secrets--failed (source what err clean)
  "Say that WHAT failed with ERR, then forget SOURCE's typed secret.
With CLEAN the buffers of this Emacs are cleaned first of the secret it knows."
  (harness-ui-secrets--callback
   (lambda ()
     (unless (harness-ui-connection-replaced-p err)
       (let ((text (harness-ui-secrets--safe-text (harness-ui-secrets--error-text err) source))
             (ui-hits (and clean (when-let* ((secrets (harness-ui-secrets--ui-secrets source nil)))
                                   (harness-ui-secrets--clean-buffers secrets)))))
         (harness-ui-secrets--show-report (format "%s failed: %s" what text) nil ui-hits)
         (message "Harness: %s failed: %s" (downcase what) text))))
   nil)
  (harness-ui-secrets--forget source))

(defun harness-ui-secrets--redacted (source report)
  "Show REPORT, what the redaction of SOURCE did, and clean this Emacs.
A typed secret and a command's output are known here, so the buffers
that hold them are cleaned now; those of a file or a variable are
cleaned when the harness announces the redaction (`secrets/redacted')."
  (let* ((ui-hits (when-let* ((secrets (harness-ui-secrets--ui-secrets source (plist-get report :secrets))))
                    (harness-ui-secrets--clean-buffers secrets)))
         (complete (harness-json-true-p (plist-get report :complete)))
         (total (or (plist-get report :total) 0)))
    (harness-ui-secrets--show-report
     (if complete "Done: nothing found is left in the stores covered." "Not complete: see what is left below.")
     report ui-hits)
    (harness-ui-secrets--refresh-logs)
    (message "%s" (if complete
                      (format "Redacted %s of %s from %s"
                              (harness-ui-secrets--n total "occurrence")
                              (harness-ui-secrets--names (plist-get report :secrets))
                              (or (plist-get report :scope) "the sessions chosen"))
                    (format "The redaction of %s is not complete: see %s"
                            (harness-ui-secrets--names (plist-get report :secrets))
                            harness-ui-secrets-report-buffer-name)))))

(defun harness-ui-secrets--scanned (source label scope reason report)
  "Go on with the redaction of SOURCE after its scan found REPORT.
Nothing found ends it; otherwise the user is asked, and a yes redacts.
LABEL, SCOPE and REASON are those the scan had."
  (let* ((ui-secrets (harness-ui-secrets--ui-secrets source (plist-get report :secrets)))
         (ui-hits (and ui-secrets (harness-ui-secrets--clean-buffers ui-secrets t)))
         (ui-count (or (car ui-hits) 0))
         (total (or (plist-get report :total) 0)))
    (harness-ui-secrets--show-report "Scanned: nothing has changed yet." report ui-hits t)
    (cond
     ((and (zerop total) (zerop ui-count))
      (message "%s" (if (plist-get report :errors)
                        (format "The scan found nothing, but some of it failed: see %s"
                                harness-ui-secrets-report-buffer-name)
                      (format "Nothing to redact in %s" (or (plist-get report :scope) "the sessions chosen"))))
      (harness-ui-secrets--forget source))
     ((not (yes-or-no-p (harness-ui-secrets--prompt report ui-count)))
      (message "Nothing was redacted")
      (harness-ui-secrets--forget source))
     (t
      (harness-ui-secrets--show-report
       "Redacting…  The harness answers when it is done; a large search index, rebuilt and vacuumed, takes minutes."
       report ui-hits t)
      (harness-ui-call
       "_harness/secrets/redact" (harness-ui-secrets--params source label scope reason "redact")
       (lambda (done)
         (harness-ui-secrets--callback
          (lambda () (harness-ui-secrets--redacted source done))
          (lambda () (harness-ui-secrets--forget source)))
         (harness-ui-secrets--forget source))
       (lambda (err) (harness-ui-secrets--failed source "The redaction" err t)))))))

;;;###autoload
(defun harness-ui-secrets-redact (source label scope reason)
  "Scan every store for the secret SOURCE names, ask, and redact it.
SOURCE is (:ref REFERENCE ...), as the prompts of `harness-redact-secret'
make it, LABEL the name of the placeholder, SCOPE the sessions to clean
\(:scope all, or project with :project, or session with :sessions) and
REASON why, or nil.  The harness scans first, counting and changing
nothing; the buffer *harness redaction* shows the report, and you are
asked before the redaction runs.  The calls have no deadline.  A typed
secret in SOURCE (:value) is cleared once the last answer is in."
  ;; The placeholders this Emacs writes read as the user named the secret,
  ;; unless the harness says otherwise in its report.
  (let ((source (if (and (stringp label) (not (string-blank-p label)))
                    (plist-put (copy-sequence source) :label label)
                  source)))
    (condition-case err
        (progn
          (harness-ui-secrets--show-report "Scanning: nothing is changed by a scan.")
          (harness-ui-call
           "_harness/secrets/redact" (harness-ui-secrets--params source label scope reason "scan")
           (lambda (report)
             (harness-ui-secrets--callback
              (lambda () (harness-ui-secrets--scanned source label scope reason report))
              (lambda () (harness-ui-secrets--forget source))))
           (lambda (err) (harness-ui-secrets--failed source "The scan" err nil))))
      (error (harness-ui-secrets--forget source)
             (signal (car err) (cdr err))))))

;;;###autoload
(defun harness-redact-secret ()
  "Take a secret out of everything the harness stored of its sessions.
You are asked where the secret is -- a JSON path in a file, a regexp
with a group around it in a file, an environment variable of the harness,
a command that prints it, or you type it, hidden -- what to call it, which
sessions to clean and why.  The harness then scans, and the buffer
*harness redaction* shows counts and session ids, never the text around
a secret; you are asked before anything is changed, and told what the
redaction costs in prompt cache.  The secret is replaced by [redacted:
LABEL sha256:FINGERPRINT] in the node logs, the search index, the
conversation logs of Claude Code and Copilot, transcript files, task
records and logs, and a session whose provider conversation held it
carries on from the redacted transcript, in a new conversation whose
prompt cache is empty.  Every redaction is recorded (`harness-redactions').

A typed secret goes only to a harness on this machine and is cleared
from memory afterwards; a command is run by the harness, where it is.
Redacting cannot recall what the model provider already received."
  (interactive)
  (harness-ui-secrets--read-source
   t
   (lambda (source)
     (let ((handed nil))
       (unwind-protect
           (let* ((label (harness-ui-secrets--read-label source))
                  (scope (harness-ui-secrets--read-scope))
                  (reason (harness-ui-secrets--read-reason)))
             (setq handed t)
             (harness-ui-secrets-redact source label scope reason))
         (unless handed
           (harness-ui-secrets--forget source)))))))

;;;; The registry of secrets to mask

(defun harness-ui-secrets--fingerprints (entry)
  "Return the fingerprints of ENTRY, a source or a secret list, as one text."
  (let* ((fingerprints (append (plist-get entry :fingerprints) nil))
         (shown (take harness-ui-secrets--fingerprints-limit fingerprints))
         (text (string-join shown " ")))
    (if (> (length fingerprints) (length shown))
        (format "%s +%d" text (- (length fingerprints) (length shown)))
      text)))

(defvar-local harness-ui-secrets--entries nil
  "The sources last fetched for this buffer, plists without a value.")

(defun harness-ui-secrets--refresh-sources (&optional buffer)
  "Read the sources again in BUFFER, or in every buffer that lists them."
  (dolist (b (if buffer (list buffer) (buffer-list)))
    (when (eq (buffer-local-value 'major-mode b) 'harness-ui-secrets-sources-mode)
      (harness-ui-call
       "_harness/secrets/sources" nil
       (lambda (sources)
         (when (buffer-live-p b)
           (with-current-buffer b
             (setq harness-ui-secrets--entries (append sources nil))
             (harness-ui-secrets--render-sources))))))))

(defun harness-ui-secrets--source-row (source)
  "Return the tabulated list entry for SOURCE, a plist `secrets/sources' gave."
  (list (plist-get source :id)
        (vector (or (plist-get source :label) "")
                (or (plist-get source :source) "")
                (number-to-string (or (plist-get source :values) 0))
                (harness-ui-secrets--fingerprints source)
                (format "%s" (or (plist-get source :origin) ""))
                (if-let* ((error (plist-get source :error)))
                    (propertize (format "%s" error) 'face 'harness-status-blocked-face)
                  ""))))

(defun harness-ui-secrets--fit-source-column ()
  "Make the Source column as wide as the longest source needs, within limits.
A source reads \"file PATH, JSON path P\": what tells two sources of one
file apart comes after the file name, so a column cut at a fixed width
hid it (the cut is a `display' ellipsis, which the text of the buffer
does not show)."
  (let* ((needed (cl-loop for source in harness-ui-secrets--entries
                          maximize (string-width (format "%s" (or (plist-get source :source) "")))))
         (width (min harness-ui-secrets--source-width-limit
                     (max harness-ui-secrets--source-width (or needed 0)))))
    (unless (eql width (cadr (aref tabulated-list-format 1)))
      (setf (cadr (aref tabulated-list-format 1)) width)
      (tabulated-list-init-header))))

(defun harness-ui-secrets--render-sources ()
  "Draw the sources of the current buffer."
  (harness-ui-secrets--fit-source-column)
  (setq tabulated-list-entries (mapcar #'harness-ui-secrets--source-row harness-ui-secrets--entries))
  (tabulated-list-print t)
  (when (null harness-ui-secrets--entries)
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char (point-max))
        (insert (propertize " No source yet: a adds one.  Until then only the formats the\n harness knows (tokens, keys, PEM blocks) are masked.\n"
                            'face 'harness-hint-face))))))

(defvar harness-ui-secrets-sources-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "a") #'harness-secrets-add-source)
    (define-key map (kbd "d") #'harness-ui-secrets-remove-source)
    (define-key map (kbd "l") #'harness-redactions)
    (define-key map (kbd "g") #'harness-ui-secrets-reload)
    (define-key map (kbd "q") #'harness-ui-quit-view)
    (define-key map (kbd "?") #'harness-menu)
    map)
  "Keymap of `harness-ui-secrets-sources-mode'.")

(define-derived-mode harness-ui-secrets-sources-mode tabulated-list-mode "Secrets"
  "Major mode listing the sources of the secrets the harness masks.
A source is where a secret can be read; the harness reads the values
itself and masks them, and the formats of common tokens, in everything
a tool returns before it is stored.  The list shows each source's
fingerprints (the first 8 hex digits of the SHA-256 of each value), never
a value.

\\{harness-ui-secrets-sources-mode-map}"
  (setq tabulated-list-format (vector (list "Label" 26 t)
                                      (list "Source" harness-ui-secrets--source-width t)
                                      (list "Values" 6 nil :right-align t)
                                      (list "Fingerprints" 38 nil)
                                      (list "Origin" 7 t)
                                      (list "Error" 0 nil))
        tabulated-list-padding 1)
  (tabulated-list-init-header))

(put 'harness-ui-secrets-sources-mode 'harness-menu-group
     '("Secret sources"
       ["Sources"
        (". a" "Add a source" harness-secrets-add-source)
        (". d" "Stop masking the source at point" harness-ui-secrets-remove-source)
        (". l" "Redactions that were run" harness-redactions)
        (". g" "Read the sources again" harness-ui-secrets-reload)]))

;;;###autoload
(defun harness-secrets-list-sources ()
  "List the sources of the secrets that tool output is masked of.
Each row has the label, where the secret is read, how many values it
holds, their fingerprints, whether it comes from `harness-secrets-sources'
\(config) or was added here (stored), and why it cannot be read, if so.
There is never a value in it."
  (interactive)
  (let ((buffer (get-buffer-create harness-ui-secrets-sources-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'harness-ui-secrets-sources-mode)
        (harness-ui-secrets-sources-mode)))
    (harness-ui-display-view buffer)
    (harness-ui-secrets--refresh-sources buffer)
    buffer))

(defun harness-ui-secrets-reload ()
  "Read the sources again."
  (interactive)
  (harness-ui-secrets--refresh-sources (current-buffer)))

(defun harness-ui-secrets-remove-source ()
  "Stop masking the source at point, one added with `harness-secrets-add-source'.
The sources of `harness-secrets-sources' are the option's to change."
  (interactive)
  (let* ((id (or (tabulated-list-get-id) (user-error "No source at point")))
         (source (cl-find id harness-ui-secrets--entries
                          :key (lambda (e) (plist-get e :id)) :test #'equal))
         (label (or (plist-get source :label) id)))
    (when (equal (format "%s" (plist-get source :origin)) "config")
      (user-error "%s comes from harness-secrets-sources: change that option instead" label))
    (when (y-or-n-p (format "Stop masking %s? " label))
      (harness-ui-call "_harness/secrets/remove-source" (list :id id)
                       (lambda (_)
                         (message "No longer masking %s" label)
                         (harness-ui-secrets--refresh-sources))))))

;;;###autoload
(defun harness-secrets-add-source ()
  "Add a source to the secrets that tool output is masked of.
You say where the secret can be read -- a JSON path in a file, a regexp
with a group around it in a file, an environment variable of the harness
or a command that prints it -- and what to call it.  The harness reads
the value now, to prove the source names one, and again whenever the
file or the variable changes; it keeps the source, never the value, and
replaces every occurrence of the value in what a tool returns by
[redacted: LABEL sha256:FINGERPRINT] before anything stores or shows it.
A secret cannot be typed here: that would put it on disk.  The sources
are listed by `harness-secrets-list-sources'."
  (interactive)
  (harness-ui-secrets--read-source
   nil
   (lambda (source)
     (let ((label (harness-ui-secrets--read-label source)))
       (harness-ui-call
        "_harness/secrets/add-source"
        (list :ref (append (plist-get source :ref) (list :label label)))
        (lambda (added)
          (harness-ui-secrets--callback
           (lambda ()
             (let ((count (or (plist-get added :values) 0)))
               (if (plist-get added :error)
                   (message "Added %s, but it cannot be read now: %s" label (plist-get added :error))
                 (message "Masking %s of %s: sha256 %s"
                          (harness-ui-secrets--n count "value") label
                          (string-join (append (plist-get added :fingerprints) nil) ", "))))
             (harness-ui-secrets--refresh-sources))))
        (lambda (err)
          (unless (harness-ui-connection-replaced-p err)
            (message "Harness: the source was not added: %s" (harness-ui-secrets--error-text err)))))))))

;;;; The redactions that were run

(defvar-local harness-ui-secrets--log-entries nil
  "The redactions last fetched for this buffer, newest first.")

(defvar-local harness-ui-secrets--log-limit nil
  "How many redactions this buffer asked for, or nil for the harness's own number.")

(defun harness-ui-secrets--time (entry)
  "Return when ENTRY, a redaction of the log, was run."
  (let ((ts (plist-get entry :ts)))
    (cond ((numberp ts) (format-time-string "%Y-%m-%d %H:%M" ts))
          ((stringp (plist-get entry :time)) (plist-get entry :time))
          (t ""))))

(defun harness-ui-secrets--origin (origin)
  "Return who asked, ORIGIN, the session or the user."
  (if (equal (format "%s" (plist-get origin :kind)) "session")
      (format "session %s" (if (stringp (plist-get origin :id)) (harness-ui-session-name (plist-get origin :id)) "?"))
    "you"))

(defun harness-ui-secrets--totals (entry)
  "Return the occurrences ENTRY redacted, with the stores that held them."
  (let ((total (or (plist-get entry :total) 0))
        (parts (delq nil (mapcar (lambda (row)
                                   (when (> (or (plist-get row :count) 0) 0)
                                     (format "%s %d" (plist-get row :store) (plist-get row :count))))
                                 (append (plist-get entry :totals) nil)))))
    (if parts (format "%d (%s)" total (string-join parts ", ")) (number-to-string total))))

(defun harness-ui-secrets--log-row (entry index)
  "Return the tabulated list entry for ENTRY, the redaction number INDEX."
  (list index
        (vector (harness-ui-secrets--time entry)
                (harness-ui-secrets--origin (plist-get entry :origin))
                (or (plist-get entry :reason) "")
                (mapconcat (lambda (s) (format "%s sha256:%s" (plist-get s :label) (plist-get s :fingerprint)))
                           (append (plist-get entry :secrets) nil) ", ")
                (harness-ui-secrets--totals entry)
                (if (harness-json-true-p (plist-get entry :complete)) "" "not complete"))))

(defun harness-ui-secrets--render-log ()
  "Draw the redactions of the current buffer."
  (let ((index -1))
    (setq tabulated-list-entries
          (mapcar (lambda (e) (harness-ui-secrets--log-row e (cl-incf index))) harness-ui-secrets--log-entries)))
  (tabulated-list-print t)
  (when (null harness-ui-secrets--log-entries)
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char (point-max))
        (insert (propertize " No redaction has been run.\n" 'face 'harness-hint-face))))))

(defun harness-ui-secrets--refresh-log (buffer)
  "Read the redactions again in BUFFER."
  (harness-ui-call
   "_harness/secrets/log"
   (and (buffer-local-value 'harness-ui-secrets--log-limit buffer)
        (list :limit (buffer-local-value 'harness-ui-secrets--log-limit buffer)))
   (lambda (entries)
     (when (buffer-live-p buffer)
       (with-current-buffer buffer
         (setq harness-ui-secrets--log-entries (append entries nil))
         (harness-ui-secrets--render-log))))))

(defun harness-ui-secrets--entry-text (entry)
  "Return ENTRY, a redaction of the log, as text for a person to read."
  (let ((lines nil))
    (cl-flet ((add (&rest strings) (dolist (s strings) (push s lines))))
      (add (format "Redaction of %s" (harness-ui-secrets--time entry))
           (format "Asked by: %s" (harness-ui-secrets--origin (plist-get entry :origin))))
      (when (plist-get entry :reason) (add (format "Reason: %s" (plist-get entry :reason))))
      (add (format "Scope: %s" (or (plist-get entry :scope) "?")) "Secrets:")
      (dolist (s (append (plist-get entry :secrets) nil))
        (add (format "  %s (sha256:%s): %s" (plist-get s :label) (plist-get s :fingerprint)
                     (or (plist-get s :source) "unknown source"))))
      (add (format "Occurrences: %s" (harness-ui-secrets--totals entry)))
      (let ((ids (append (plist-get entry :sessions) nil)))
        (when ids (add (format "Sessions (%d): %s" (or (plist-get entry :sessions-total) (length ids))
                               (string-join ids ", ")))))
      (let ((files (append (plist-get entry :files) nil)))
        (when files (add (format "Files (%d):" (or (plist-get entry :files-total) (length files))))
              (dolist (f files) (add (concat "  " f)))))
      (when-let* ((deferred (append (plist-get entry :deferred) nil)))
        (add (format "Waiting for a running turn to end: %s" (string-join deferred ", "))))
      (dolist (e (append (plist-get entry :errors) nil)) (add (format "Failed: %s" e)))
      (dolist (e (append (plist-get entry :remaining) nil)) (add (format "Left: %s" e)))
      (add (format "Complete: %s" (if (harness-json-true-p (plist-get entry :complete)) "yes" "no")))
      (when-let* ((v (plist-get entry :verification)))
        (add (format "Verification: %s, %s found afterwards, %d explained"
                     (if (harness-json-true-p (plist-get v :ok)) "ok" "NOT ok")
                     (harness-ui-secrets--n (or (plist-get v :total) 0) "occurrence")
                     (or (plist-get v :explained) 0)))))
    (concat (string-join (nreverse lines) "\n") "\n")))

(defun harness-ui-secrets-log-visit ()
  "Show the redaction at point whole."
  (interactive)
  (let* ((index (or (tabulated-list-get-id) (user-error "No redaction at point")))
         (entry (nth index harness-ui-secrets--log-entries))
         (buffer (get-buffer-create (format "%s: %s*" (string-remove-suffix "*" harness-ui-secrets-log-buffer-name)
                                            (harness-ui-secrets--time entry)))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'harness-ui-secrets-report-mode)
        (harness-ui-secrets-report-mode))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (harness-ui-secrets--entry-text entry))
        (goto-char (point-min))))
    (harness-ui-display-view buffer)))

(defvar harness-ui-secrets-log-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'harness-ui-secrets-log-visit)
    (define-key map (kbd "s") #'harness-secrets-list-sources)
    (define-key map (kbd "g") #'harness-ui-secrets-log-reload)
    (define-key map (kbd "q") #'harness-ui-quit-view)
    (define-key map (kbd "?") #'harness-menu)
    map)
  "Keymap of `harness-ui-secrets-log-mode'.")

(define-derived-mode harness-ui-secrets-log-mode tabulated-list-mode "Redactions"
  "Major mode listing the redactions the harness has run, newest first.
Each row says when, who asked, why, which secrets (label and fingerprint)
and how many occurrences were found, in all and per store.  There is never
a secret in it.

\\{harness-ui-secrets-log-mode-map}"
  (setq tabulated-list-format (vector (list "When" 17 nil)
                                      (list "Asked by" 18 nil)
                                      (list "Reason" 30 nil)
                                      (list "Secrets" 40 nil)
                                      (list "Found" 36 nil)
                                      (list "" 0 nil))
        tabulated-list-padding 1)
  (tabulated-list-init-header))

(put 'harness-ui-secrets-log-mode 'harness-menu-group
     '("Redactions"
       ["Redactions"
        (". RET" "Show the redaction at point" harness-ui-secrets-log-visit)
        (". s" "Sources of the secrets masked" harness-secrets-list-sources)
        (". g" "Read the log again" harness-ui-secrets-log-reload)]))

(defun harness-ui-secrets-log-reload ()
  "Read the redactions again."
  (interactive)
  (harness-ui-secrets--refresh-log (current-buffer)))

;;;###autoload
(defun harness-redactions (&optional limit)
  "List the redactions the harness has run, newest first.
With a numeric prefix argument LIMIT, that many; otherwise the harness's
own number.  RET shows one whole.  A redaction is recorded with its time,
who asked, why, the secrets by label and fingerprint, and the occurrences
in each store: never a secret."
  (interactive "P")
  (let ((buffer (get-buffer-create harness-ui-secrets-log-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'harness-ui-secrets-log-mode)
        (harness-ui-secrets-log-mode))
      (setq harness-ui-secrets--log-limit (and limit (prefix-numeric-value limit))))
    (harness-ui-display-view buffer)
    (harness-ui-secrets--refresh-log buffer)
    buffer))

;;;; Following the harness

(defun harness-ui-secrets--on-session-redacted (args)
  "Load the chat of the session ARGS name again: its transcript was redacted.
ARGS is (SESSION-ID RECORD).  The chat shows what it drew from the nodes
before, which held the secret; the hint the redaction wrote is new too."
  (let ((sid (car args)))
    (when (and (stringp sid) (fboundp 'harness-chat--buffer-for) (fboundp 'harness-chat--load))
      (when-let* ((buffer (harness-chat--buffer-for sid)))
        (with-current-buffer buffer
          (harness-chat--load t))))))

(defun harness-ui-secrets--on-secrets-redacted (summary)
  "Clean the buffers of this Emacs after the redaction SUMMARY.
SUMMARY is (:source REFERENCE :secrets ((:label :fingerprint)...) :sessions
IDS).  When REFERENCE is a file or a variable that this Emacs reads
itself, and every secret it gives is among those the harness redacted,
they are taken out of *harness-log*, *Messages* and every buffer named
*harness... that visits no file.  A harness on another machine reads
other files, so it is not followed."
  (when (and (consp summary) (harness-ui-secrets--local-p))
    (let ((ref (plist-get summary :source)))
      (when (and (consp ref)
                 (or (stringp (plist-get ref :file)) (stringp (plist-get ref :env))))
        (when-let* ((secrets (harness-ui-secrets--matching ref (plist-get summary :secrets))))
          (harness-ui-secrets--clean-buffers secrets))))))

(defun harness-ui-secrets--on-event (event args)
  "Follow EVENT with ARGS from the harness: a redacted session, a redaction."
  (when (member event '("session/redacted" "secrets/redacted"))
    (condition-case err
        (pcase event
          ("session/redacted" (harness-ui-secrets--on-session-redacted args))
          ("secrets/redacted" (harness-ui-secrets--on-secrets-redacted (car args))))
      (error (harness-log 'warn "secrets: following %s failed: %s"
                          event (harness-ui-secrets--error-text err))))))

;;;; Module

(defun harness-ui-secrets--suffix-command (key)
  "Return the command the harness menu has at KEY, or nil."
  (when-let* ((suffix (ignore-errors (transient-get-suffix 'harness-menu key))))
    (plist-get (if (keywordp (cadr suffix)) (cdr suffix) (car (last suffix))) :command)))

(defun harness-ui-secrets--menu-install ()
  "Put the commands of this module in the harness menu, after Log, in Tools."
  (condition-case err
      (let ((after "L"))
        (dolist (entry '(("x" "Redact a secret…" harness-redact-secret)
                         ("E" "Secret sources" harness-secrets-list-sources)))
          (pcase (harness-ui-secrets--suffix-command (car entry))
            ((pred null) (transient-append-suffix 'harness-menu after entry))
            ((pred (eq (nth 2 entry))) nil)
            (other (harness-log 'warn "secrets: the menu key %s is %s's: %s has no entry"
                                (car entry) other (nth 2 entry))))
          (setq after (car entry))))
    (error (harness-log 'warn "secrets: no menu entry: %s" (error-message-string err)))))

(defun harness-ui-secrets--menu-remove ()
  "Take the commands of this module out of the harness menu."
  (dolist (entry '(("x" . harness-redact-secret) ("E" . harness-secrets-list-sources)))
    (when (eq (harness-ui-secrets--suffix-command (car entry)) (cdr entry))
      (ignore-errors (transient-remove-suffix 'harness-menu (car entry))))))

(defun harness-ui-secrets--init ()
  "Follow the redactions of the harness, and put the commands in the menu.
`harness-redact-secret' is x in the harness menu and
`harness-secrets-list-sources' is E; the other commands are reached from
them and by name."
  (add-hook 'harness-ui-event-functions #'harness-ui-secrets--on-event)
  (harness-ui-secrets--menu-install))

(defun harness-ui-secrets--shutdown ()
  "Stop following the harness, and take the commands out of the menu."
  (remove-hook 'harness-ui-event-functions #'harness-ui-secrets--on-event)
  (harness-ui-secrets--menu-remove))

(harness-define-module 'ui-secrets
  :doc "Redact a secret from everything the harness stored, and name the secrets to mask."
  :requires '(ui)
  :init #'harness-ui-secrets--init
  :shutdown #'harness-ui-secrets--shutdown)

(provide 'harness-ui-secrets)
;;; harness-ui-secrets.el ends here
