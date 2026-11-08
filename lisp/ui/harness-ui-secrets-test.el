;;; harness-ui-secrets-test.el --- Tests for the secret redaction commands of the UI  -*- lexical-binding: t; -*-

;;; Commentary:

;; The user's side of redacting a secret: `harness-redact-secret' asks
;; where the secret is read (a JSON path in a file, a regexp, a variable, a
;; command, or typed hidden), which sessions to clean and why, scans, asks,
;; and redacts; `harness-secrets-add-source' and the lists of sources and
;; of redactions; the events that clean the chats and the log buffers of
;; this Emacs.
;;
;; Most tests stub `harness-ui-call' and answer it as the harness would,
;; so what the UI sends is what is checked.  One drives the real engine
;; through the UI's own connection, to check that the two halves agree on
;; the names of the methods, their parameters and the shape of the report.
;;
;; Every secret here is a fake one, built when the test runs, so that no
;; value that looks real is committed.  Nothing the UI shows, messages or
;; logs may hold one, whatever the test: they are checked.

;;; Code:

(require 'cl-lib)
(require 'harness-test-helpers)
(require 'harness-redaction)

(defvar harness-acp-token)
(defvar harness-acp--server-enabled)
(defvar harness-sessions)
(defvar harness-providers)
(defvar harness-ui--sessions)
(defvar harness-chat--buffers)
(defvar harness-ui-connection-address)
(defvar harness-ui-event-functions)
(defvar harness-ui-session-id)
(defvar harness-ui-secrets--entries)
(defvar harness-ui-secrets--log-entries)
(defvar harness-ui-secrets-report-buffer-name)

(declare-function harness-redact-secret "harness-ui-secrets")
(declare-function harness-secrets-add-source "harness-ui-secrets")
(declare-function harness-secrets-list-sources "harness-ui-secrets")
(declare-function harness-redactions "harness-ui-secrets")
(declare-function harness-ui-secrets-redact "harness-ui-secrets")
(declare-function harness-ui-secrets-remove-source "harness-ui-secrets")
(declare-function harness-ui-secrets-log-visit "harness-ui-secrets")
(declare-function harness-ui-secrets--source "harness-ui-secrets")
(declare-function harness-ui-secrets--local-p "harness-ui-secrets")
(declare-function harness-ui-secrets--default-label "harness-ui-secrets")
(declare-function harness-ui-secrets--choose-path "harness-ui-secrets")
(declare-function harness-ui-secrets--error-text "harness-ui-secrets")
(declare-function harness-ui-secrets--read-source "harness-ui-secrets")
(declare-function harness-ui-secrets--suffix-command "harness-ui-secrets")
(declare-function harness-ui-secrets--init "harness-ui-secrets")
(declare-function harness-ui-secrets--prompt "harness-ui-secrets")
(declare-function harness-provider--forget "harness-provider")
(declare-function harness-ui-secrets--shutdown "harness-ui-secrets")
(declare-function harness-ui-secrets--on-event "harness-ui-secrets")
(declare-function harness-chat-buffer "harness-ui-chat")

;;;; The fake secrets

(defconst harness-ui-secrets-test--key (concat "FAKE-UI/key+" (make-string 20 ?k) "7")
  "A fake secret key, made up for these tests.")

(defconst harness-ui-secrets-test--id (concat "FAKEUIID" (make-string 12 ?x))
  "A fake access key id, made up for these tests.")

(defun harness-ui-secrets-test--fp (value)
  "Return the fingerprint of the fake VALUE."
  (harness-redaction-fingerprint value))

(defun harness-ui-secrets-test--secrets ()
  "Return the fake key and id as secrets."
  (list (harness-redaction-secret harness-ui-secrets-test--key "keys.secret_key")
        (harness-redaction-secret harness-ui-secrets-test--id "keys.access_key")))

(defun harness-ui-secrets-test--holds-p (text)
  "Non-nil when TEXT, a string, holds a fake secret."
  (and (stringp text)
       (or (string-search harness-ui-secrets-test--key text)
           (string-search harness-ui-secrets-test--id text))
       t))

(defun harness-ui-secrets-test--state-file ()
  "Write a fake state file, which holds the fake id and key; return its name."
  (let ((file (expand-file-name "state.json" (harness-test-temp-dir))))
    (with-temp-file file
      (insert (harness-json-encode-text
               (list :outputs (list :keys (list :value (list :access_key harness-ui-secrets-test--id
                                                             :secret_key harness-ui-secrets-test--key)))
                     :other "unrelated"))))
    file))

(defun harness-ui-secrets-test--text (buffer)
  "Return the text of BUFFER, without properties."
  (with-current-buffer buffer (buffer-substring-no-properties (point-min) (point-max))))

;;;; The environment

(defconst harness-ui-secrets-test--buffers
  '("*harness redaction*" "*harness secrets*" "*harness redactions*"
    "*harness-log*" "*Messages*")
  "Buffers by name that tests make and that are killed afterwards.")

(defun harness-ui-secrets-test--cleanup ()
  "Kill the buffers the tests made and reset what they set."
  (dolist (b (buffer-list))
    (let ((name (buffer-name b)))
      (when (and name (or (member name harness-ui-secrets-test--buffers)
                          (string-prefix-p "*harness-test" name)
                          (string-prefix-p "*harness redactions: " name)))
        (with-current-buffer b (set-buffer-modified-p nil))
        (ignore-errors (let ((kill-buffer-query-functions nil)) (kill-buffer b)))))))

(defmacro harness-ui-secrets-test-with (&rest body)
  "Load the UI, its chat and the secrets module in a fresh state, then run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (harness-test-load-module 'acp))
     (let ((harness-acp-token nil)
           (default-directory dir))
       (harness-test-load-module 'ui)
       (harness-test-load-module 'ui-chat)
       (harness-test-load-module 'ui-secrets)
       (clrhash harness-ui--sessions)
       (unwind-protect (progn ,@body)
         (harness-ui-secrets-test--cleanup)
         (clrhash harness-ui--sessions)))))

;;;; Stand-ins for the harness, the prompts and the echo area

(defvar harness-ui-secrets-test--sent nil
  "The calls the stand-in `harness-ui-call' got, (METHOD PARAMS), newest first.")

(defvar harness-ui-secrets-test--answers nil
  "Alist of method names and functions of the params that give the answer.
An answer that is (harness-ui-secrets-test--fail ERROR) rejects the call
with ERROR.")

(defun harness-ui-secrets-test--call (method params callback &optional on-error)
  "Stand in for `harness-ui-call' for METHOD, PARAMS, CALLBACK and ON-ERROR.
Note the call and answer it from the table."
  (push (list method params) harness-ui-secrets-test--sent)
  (let* ((fn (cdr (assoc method harness-ui-secrets-test--answers)))
         (answer (and fn (funcall fn params))))
    (if (eq (car-safe answer) 'harness-ui-secrets-test--fail)
        (if on-error
            (funcall on-error (cadr answer))
          (message "Harness: %s failed: %s" method (harness-error-message (cadr answer))))
      (funcall callback answer))))

(defmacro harness-ui-secrets-test-answering (answers &rest body)
  "Run BODY with the harness answering as ANSWERS say, and its calls noted.
The calls are forgotten when BODY starts and stay in
`harness-ui-secrets-test--sent' after it, for a test to look at."
  (declare (indent 1))
  `(let ((harness-ui-secrets-test--answers ,answers))
     (setq harness-ui-secrets-test--sent nil)
     (cl-letf (((symbol-function 'harness-ui-call) #'harness-ui-secrets-test--call))
       ,@body)))

(defun harness-ui-secrets-test--calls (&optional method)
  "Return the calls made, oldest first, those of METHOD only when it is given."
  (cl-remove-if-not (lambda (c) (or (null method) (equal method (car c))))
                    (reverse harness-ui-secrets-test--sent)))

(defvar harness-ui-secrets-test--prompts nil
  "The prompts asked, (FUNCTION . PROMPT), newest first.")

(defvar harness-ui-secrets-test--replies nil
  "Alist of prompt starts and replies.
A reply that is a function is called with the prompt and the other
arguments of the reader; any other is the answer itself.")

(defun harness-ui-secrets-test--reply (reader prompt &rest args)
  "Answer the PROMPT of READER from the replies; an unexpected prompt is an error."
  (push (cons reader prompt) harness-ui-secrets-test--prompts)
  (let ((entry (cl-find-if (lambda (e) (string-prefix-p (car e) prompt))
                           harness-ui-secrets-test--replies)))
    (unless entry
      (error "Unexpected prompt from %s: %s" reader prompt))
    (if (functionp (cdr entry))
        (apply (cdr entry) prompt args)
      (cdr entry))))

(defmacro harness-ui-secrets-test-asking (replies &rest body)
  "Run BODY with every reader answered by REPLIES, an alist of prompt starts.
A prompt REPLIES do not know fails the test.  The prompts asked are
forgotten when BODY starts and stay in `harness-ui-secrets-test--prompts'
after it."
  (declare (indent 1))
  `(let ((harness-ui-secrets-test--replies ,replies))
     (setq harness-ui-secrets-test--prompts nil)
     (cl-letf (((symbol-function 'completing-read)
                (lambda (prompt &rest args)
                  (apply #'harness-ui-secrets-test--reply 'completing-read prompt args)))
               ((symbol-function 'completing-read-multiple)
                (lambda (prompt &rest args)
                  (apply #'harness-ui-secrets-test--reply 'completing-read-multiple prompt args)))
               ((symbol-function 'read-string)
                (lambda (prompt &rest args)
                  (apply #'harness-ui-secrets-test--reply 'read-string prompt args)))
               ((symbol-function 'read-file-name)
                (lambda (prompt &rest args)
                  (apply #'harness-ui-secrets-test--reply 'read-file-name prompt args)))
               ((symbol-function 'read-directory-name)
                (lambda (prompt &rest args)
                  (apply #'harness-ui-secrets-test--reply 'read-directory-name prompt args)))
               ((symbol-function 'read-passwd)
                (lambda (prompt &rest args)
                  (apply #'harness-ui-secrets-test--reply 'read-passwd prompt args)))
               ((symbol-function 'yes-or-no-p)
                (lambda (prompt)
                  (harness-ui-secrets-test--reply 'yes-or-no-p prompt)))
               ((symbol-function 'y-or-n-p)
                (lambda (prompt)
                  (harness-ui-secrets-test--reply 'y-or-n-p prompt))))
       ,@body)))

(defun harness-ui-secrets-test--asked (reader)
  "Return the prompts READER asked, oldest first."
  (cl-loop for p in (reverse harness-ui-secrets-test--prompts)
           when (eq (car p) reader) collect (cdr p)))

(defvar harness-ui-secrets-test--messages nil
  "The messages shown, newest first.")

(defmacro harness-ui-secrets-test-collecting (&rest body)
  "Run BODY with the messages it shows kept in `harness-ui-secrets-test--messages'.
They stay there after BODY."
  (declare (indent 0))
  `(progn
     (setq harness-ui-secrets-test--messages nil)
     (cl-letf (((symbol-function 'message)
                (lambda (format-string &rest args)
                  (when format-string
                    (push (apply #'format format-string args) harness-ui-secrets-test--messages)
                    (car harness-ui-secrets-test--messages)))))
       ,@body)))

(defun harness-ui-secrets-test--said ()
  "Return the messages shown so far, oldest first."
  (reverse harness-ui-secrets-test--messages))

(defun harness-ui-secrets-test--engine (params)
  "Answer `_harness/secrets/redact' with PARAMS as the engine does: 3 found.
The secret reported has the fingerprint of the value when the source
gives it, as the engine works it out, else a made-up one."
  (let* ((p (plist-get params :params))
         (literal (plist-get (plist-get p :source) :literal))
         (redact (equal (plist-get p :mode) "redact")))
    (list :mode (plist-get p :mode)
          :secrets (list (list :label (or (plist-get p :label) "secret")
                               :fingerprint (if (stringp literal)
                                                (harness-redaction-fingerprint literal)
                                              "0a1b2c3d")
                               :source "file state.json"))
          :scope "all sessions (4 sessions)"
          :total 3
          :sessions (list (list :id "s1" :count 3))
          :complete (if redact t :false)
          :text (if redact "REDACTED-TEXT" "SCANNED-TEXT"))))

(defun harness-ui-secrets-test--engine-answers ()
  "Return the answers of a harness whose redaction finds 3 occurrences."
  (list (cons "_harness/secrets/redact" #'harness-ui-secrets-test--engine)))

;;;; Where the secret is

(ert-deftest harness-ui-secrets-redact-scans-asks-then-redacts ()
  "A scan comes first and changes nothing; a yes redacts; both are the user's."
  (harness-ui-secrets-test-with
    (let ((source (harness-ui-secrets--source
                   (list :file "/data/state.json" :json-path "outputs.keys.value")))
          (asked nil))
      (harness-ui-secrets-test-collecting
        (harness-ui-secrets-test-answering (harness-ui-secrets-test--engine-answers)
          (harness-ui-secrets-test-asking
              (list (cons "Redact " (lambda (prompt) (push prompt asked) t)))
            (harness-ui-secrets-redact source "keys" '(:scope "all") "leaked in a diff"))
          (let* ((calls (harness-ui-secrets-test--calls))
                 (scan (plist-get (cadr (nth 0 calls)) :params))
                 (redact (plist-get (cadr (nth 1 calls)) :params)))
            (should (equal '("_harness/secrets/redact" "_harness/secrets/redact") (mapcar #'car calls)))
            (should (equal '("scan" "redact") (list (plist-get scan :mode) (plist-get redact :mode))))
            (dolist (p (list scan redact))
              (should (equal '(:file "/data/state.json" :json-path "outputs.keys.value")
                             (plist-get p :source)))
              (should (equal "all" (plist-get p :scope)))
              (should (equal "keys" (plist-get p :label)))
              (should (equal "leaked in a diff" (plist-get p :reason)))
              ;; The user asks: not a session.
              (should (equal '(:kind "user") (plist-get p :origin)))
              ;; A reference is safe for any harness: no leave to take the unsafe kinds.
              (should-not (plist-member p :allow-unsafe-sources))
              (should-not (plist-member p :sessions)))))
        ;; One question, which says how many and of what, by label and fingerprint.
        (should (= 1 (length asked)))
        (should (string-match-p "3 occurrences" (car asked)))
        (should (string-match-p "keys (sha256:0a1b2c3d)" (car asked)))
        (should (string-match-p "all sessions (4 sessions)" (car asked)))
        ;; The whole question: the scope says how many, in words.
        (should (equal "Redact 3 occurrences of keys (sha256:0a1b2c3d) from all sessions (4 sessions)? "
                       (car asked)))
        ;; The report buffer ends with the redaction's own report.
        (let ((text (harness-ui-secrets-test--text harness-ui-secrets-report-buffer-name)))
          (should (string-match-p "REDACTED-TEXT" text))
          (should-not (string-match-p "SCANNED-TEXT" text))
          (should (string-match-p "Done" text)))
        (with-current-buffer harness-ui-secrets-report-buffer-name
          (should (derived-mode-p 'special-mode)))
        (should (cl-some (lambda (m) (string-match-p "Redacted 3 occurrences of keys (sha256:0a1b2c3d)" m))
                         (harness-ui-secrets-test--said)))))))

(ert-deftest harness-ui-secrets-redact-shows-the-scan-before-asking ()
  "The question is asked with the scan's report on screen."
  (harness-ui-secrets-test-with
    (let ((source (harness-ui-secrets--source (list :env "SOME_TOKEN_VARIABLE")))
          (shown nil))
      (harness-ui-secrets-test-collecting
        (harness-ui-secrets-test-answering (harness-ui-secrets-test--engine-answers)
          (harness-ui-secrets-test-asking
              (list (cons "Redact " (lambda (_prompt)
                                      (setq shown (harness-ui-secrets-test--text
                                                   harness-ui-secrets-report-buffer-name))
                                      nil)))
            (harness-ui-secrets-redact source "token" '(:scope "all") nil))))
      (should (string-match-p "SCANNED-TEXT" shown))
      (should (string-match-p "nothing has changed yet" shown)))))

(ert-deftest harness-ui-secrets-redact-question-says-what-the-reset-costs ()
  "The question names the provider conversations that start over and the cache they lose.
Only the sessions the scan says a reset would drop the prompt cache of
count, with the tokens that cache holds; a conversation that starts over
with no cache to lose costs nothing more."
  (harness-ui-secrets-test-with
    (let ((source (harness-ui-secrets--source (list :env "SOME_TOKEN_VARIABLE")))
          (asked nil))
      (harness-ui-secrets-test-collecting
        (harness-ui-secrets-test-answering
            (list (cons "_harness/secrets/redact"
                        (lambda (params)
                          (plist-put (harness-ui-secrets-test--engine params) :sessions
                                     (list (list :id "s1" :count 2 :would-reset t
                                                 :cache-would-drop t :context 84000)
                                           (list :id "s2" :count 1 :would-reset t)
                                           (list :id "s3" :count 1 :would-reset t
                                                 :cache-would-drop t :context 42000))))))
          (harness-ui-secrets-test-asking
              (list (cons "Redact " (lambda (prompt) (push prompt asked) nil)))
            (harness-ui-secrets-redact source "keys" '(:scope "all") nil))
          ;; The whole question: the clause comes last, before the question mark.
          (should (equal (concat "Redact 3 occurrences of keys (sha256:0a1b2c3d) from all sessions (4 sessions)"
                                 "; 2 provider conversations start over, dropping ~126k tokens of prompt cache? ")
                         (car asked)))
          (should (member "Nothing was redacted" (harness-ui-secrets-test--said))))))))

(ert-deftest harness-ui-secrets-redact-question-reads-right-for-one-and-for-none ()
  "The clause counts and conjugates, and is left out when no cache would go.
It follows the buffers of this Emacs, when the scan found some there."
  (harness-ui-secrets-test-with
    (let* ((secrets '((:label "keys" :fingerprint "0a1b2c3d")))
           (report (lambda (&rest sessions)
                     (list :total 3 :secrets secrets :scope "all sessions (4 sessions)" :sessions sessions)))
           (plain "Redact 3 occurrences of keys (sha256:0a1b2c3d) from all sessions (4 sessions)"))
      ;; One session: singular, and the tokens as the harness writes them.
      (should (equal (concat plain "; 1 provider conversation starts over, dropping ~84.0k tokens of prompt cache? ")
                     (harness-ui-secrets--prompt
                      (funcall report '(:id "s1" :would-reset t :cache-would-drop t :context 84000)) 0)))
      ;; After the buffers of this Emacs.
      (should (equal (concat plain ", and 2 occurrences in the buffers of this Emacs"
                             "; 1 provider conversation starts over, dropping ~84.0k tokens of prompt cache? ")
                     (harness-ui-secrets--prompt
                      (funcall report '(:id "s1" :would-reset t :cache-would-drop t :context 84000)) 2)))
      ;; Conversations that start over with no cache to lose, or none: the question is as it was.
      (dolist (sessions (list nil
                              (list '(:id "s1" :count 3 :would-reset t))
                              (list '(:id "s1" :count 3 :cache-would-drop :false :context 84000))))
        (should (equal (concat plain "? ")
                       (harness-ui-secrets--prompt (apply report sessions) 0))))
      ;; A scan that gave no tokens still says what goes.
      (should (equal (concat plain "; 1 provider conversation starts over, dropping their prompt cache? ")
                     (harness-ui-secrets--prompt
                      (funcall report '(:id "s1" :would-reset t :cache-would-drop t)) 0)))
      ;; One token is not tokens.
      (should (equal (concat plain "; 1 provider conversation starts over, dropping ~1 token of prompt cache? ")
                     (harness-ui-secrets--prompt
                      (funcall report '(:id "s1" :would-reset t :cache-would-drop t :context 1)) 0))))))

(ert-deftest harness-ui-secrets-redact-says-nothing-found-without-asking ()
  "A scan that finds nothing ends there: no question, no redaction."
  (harness-ui-secrets-test-with
    (let ((source (harness-ui-secrets--source (list :env "SOME_TOKEN_VARIABLE"))))
      (harness-ui-secrets-test-collecting
        (harness-ui-secrets-test-answering
            (list (cons "_harness/secrets/redact"
                        (lambda (_)
                          (list :mode "scan" :total 0 :scope "all sessions (4 sessions)"
                                :secrets (list (list :label "token" :fingerprint "0a1b2c3d"))
                                :text "NOTHING-FOUND-TEXT"))))
          ;; No prompt is expected: any would fail the test.
          (harness-ui-secrets-test-asking nil
            (harness-ui-secrets-redact source "token" '(:scope "all") nil))
          (should (= 1 (length (harness-ui-secrets-test--calls))))
          (should (cl-some (lambda (m) (string-match-p "Nothing to redact in all sessions (4 sessions)" m))
                           (harness-ui-secrets-test--said)))
          (should (string-match-p "NOTHING-FOUND-TEXT"
                                  (harness-ui-secrets-test--text harness-ui-secrets-report-buffer-name))))))))

(ert-deftest harness-ui-secrets-redact-declined-changes-nothing ()
  "A no after the scan sends no redaction."
  (harness-ui-secrets-test-with
    (let ((source (harness-ui-secrets--source (list :env "SOME_TOKEN_VARIABLE"))))
      (harness-ui-secrets-test-collecting
        (harness-ui-secrets-test-answering (harness-ui-secrets-test--engine-answers)
          (harness-ui-secrets-test-asking (list (cons "Redact " nil))
            (harness-ui-secrets-redact source "token" '(:scope "all") nil))
          (should (equal '("scan") (mapcar (lambda (c) (plist-get (plist-get (cadr c) :params) :mode))
                                           (harness-ui-secrets-test--calls))))
          (should (member "Nothing was redacted" (harness-ui-secrets-test--said))))))))

(ert-deftest harness-ui-secrets-redact-not-complete-says-so ()
  "A redaction that left something behind is reported as not complete."
  (harness-ui-secrets-test-with
    (let ((source (harness-ui-secrets--source (list :env "SOME_TOKEN_VARIABLE"))))
      (harness-ui-secrets-test-collecting
        (harness-ui-secrets-test-answering
            (list (cons "_harness/secrets/redact"
                        (lambda (params)
                          (let ((report (harness-ui-secrets-test--engine params)))
                            (if (equal "redact" (plist-get (plist-get params :params) :mode))
                                (plist-put (plist-put report :complete :false)
                                           :text "LEFT-OVER-TEXT")
                              report)))))
          (harness-ui-secrets-test-asking (list (cons "Redact " t))
            (harness-ui-secrets-redact source "token" '(:scope "all") nil))
          (let ((text (harness-ui-secrets-test--text harness-ui-secrets-report-buffer-name)))
            (should (string-match-p "Not complete" text))
            (should (string-match-p "LEFT-OVER-TEXT" text)))
          (should (cl-some (lambda (m) (string-match-p "not complete" m))
                           (harness-ui-secrets-test--said))))))))

(ert-deftest harness-ui-secrets-redact-failure-shows-the-message-not-the-data ()
  "A rejected request shows the harness's message; the data it carries stays out."
  (harness-ui-secrets-test-with
    (let ((source (harness-ui-secrets--source (list :env "SOME_TOKEN_VARIABLE"))))
      (harness-ui-secrets-test-collecting
        (harness-ui-secrets-test-answering
            (list (cons "_harness/secrets/redact"
                        (lambda (_)
                          (list 'harness-ui-secrets-test--fail
                                (list 'acp-error -32000 "SOME_TOKEN_VARIABLE is not set"
                                      (list :type "harness-error"
                                            :quoted harness-ui-secrets-test--key))))))
          (harness-ui-secrets-test-asking nil
            (harness-ui-secrets-redact source "token" '(:scope "all") nil))
          (should (= 1 (length (harness-ui-secrets-test--calls))))
          (should (cl-some (lambda (m) (string-match-p "SOME_TOKEN_VARIABLE is not set" m))
                           (harness-ui-secrets-test--said)))
          (dolist (m (harness-ui-secrets-test--said))
            (should-not (harness-ui-secrets-test--holds-p m)))
          (should-not (harness-ui-secrets-test--holds-p
                       (harness-ui-secrets-test--text harness-ui-secrets-report-buffer-name))))))))

(ert-deftest harness-ui-secrets-redact-scope-parameters ()
  "Each scope sends what the engine needs of it, and a session also its forks."
  (harness-ui-secrets-test-with
    (let ((source (harness-ui-secrets--source (list :env "SOME_TOKEN_VARIABLE"))))
      (harness-ui-secrets-test-collecting
        (harness-ui-secrets-test-answering
            (list (cons "_harness/secrets/redact"
                        (lambda (params)
                          (list :mode "scan" :total 0 :text "none"
                                :secrets (list (list :label "t" :fingerprint "0a1b2c3d"))
                                :scope (plist-get (plist-get params :params) :scope)))))
          (harness-ui-secrets-test-asking nil
            (harness-ui-secrets-redact source "t" '(:scope "project" :project "/data/funkyboy") nil)
            (harness-ui-secrets-redact source "t" '(:scope "session" :sessions ("s1" "s2")) nil))
          (let ((project (plist-get (cadr (nth 0 (harness-ui-secrets-test--calls))) :params))
                (sessions (plist-get (cadr (nth 1 (harness-ui-secrets-test--calls))) :params)))
            (should (equal "project" (plist-get project :scope)))
            (should (equal "/data/funkyboy" (plist-get project :project)))
            (should-not (plist-member project :sessions))
            (should (equal "session" (plist-get sessions :scope)))
            (should (equal '("s1" "s2") (append (plist-get sessions :sessions) nil)))
            ;; The forks of a session hold copies of its transcript.
            (should (eq t (plist-get sessions :include-forks)))))))))

;;;; Asking

(defun harness-ui-secrets-test--engine-and-shape-answers (file)
  "Return the answers of a harness that has the state FILE and finds 3 occurrences."
  (append (harness-ui-secrets-test--engine-answers)
          (list (cons "_harness/secrets/shape"
                      (lambda (params)
                        (should (equal file (plist-get params :file)))
                        (let ((shape (harness-redaction-shape file)))
                          (list :file file
                                :paths (apply #'vector (cl-remove-if-not (lambda (e) (plist-member e :path)) shape))
                                :truncated :false)))))))

(ert-deftest harness-ui-secrets-asks-for-a-json-path-from-the-shape-of-the-file ()
  "The paths offered are the keys and types of the file; the label comes from the path."
  (harness-ui-secrets-test-with
    (let* ((file (harness-ui-secrets-test--state-file))
           (offered nil) (annotations nil) (required nil) (labels nil))
      (harness-ui-secrets-test-collecting
        (harness-ui-secrets-test-answering (harness-ui-secrets-test--engine-and-shape-answers file)
          (harness-ui-secrets-test-asking
              (list (cons "Where is the secret?" "File and JSON path")
                    (cons "JSON file that holds the secret" file)
                    (cons "JSON path in state.json"
                          (lambda (_prompt table _pred require-match &rest _)
                            (setq offered (all-completions "" table)
                                  required require-match)
                            (let ((annotate (completion-metadata-get
                                             (completion-metadata "" table nil) 'annotation-function)))
                              (setq annotations (mapcar annotate offered)))
                            (cl-find-if (lambda (c) (string-suffix-p "keys.value" c)) offered)))
                    (cons "Label for the placeholder" "")
                    (cons "Clean:" "All sessions")
                    (cons "Reason" "found in a diff")
                    (cons "Redact " t))
            (harness-redact-secret)
            (setq labels (harness-ui-secrets-test--asked 'read-string)))
          ;; Objects, arrays and strings, in the order of the document, and their types.
          (should offered)
          (should (equal "$" (car offered)))
          (should (cl-every (lambda (a) (member a '("  object" "  array" "  string"))) annotations))
          (should (member "  string" annotations))
          (should required)
          (should-not (cl-some #'harness-ui-secrets-test--holds-p offered))
          ;; The label comes from the path (`value' says nothing); RET kept it.
          (let ((scan (plist-get (cadr (nth 0 (harness-ui-secrets-test--calls "_harness/secrets/redact"))) :params)))
            (should (equal "keys" (plist-get scan :label)))
            (should (equal "all" (plist-get scan :scope)))
            (should (equal "found in a diff" (plist-get scan :reason)))
            (should (equal file (plist-get (plist-get scan :source) :file)))
            (should (string-suffix-p "keys.value" (plist-get (plist-get scan :source) :json-path))))
          (should (member "Label for the placeholder (default keys): " labels)))))))

(ert-deftest harness-ui-secrets-the-whole-file-is-asked-about-again ()
  "RET on the root names every string of the file; the user is asked before that."
  (harness-ui-secrets-test-with
    (let ((file (harness-ui-secrets-test--state-file)))
      (harness-ui-secrets-test-collecting
        (harness-ui-secrets-test-answering (harness-ui-secrets-test--engine-and-shape-answers file)
          ;; Declined: no label, scope or reason is asked, and nothing is scanned.
          (harness-ui-secrets-test-asking
              (list (cons "Where is the secret?" "File and JSON path")
                    (cons "JSON file that holds the secret" file)
                    (cons "JSON path in state.json" "")
                    (cons "$ names every string in state.json" nil))
            (harness-redact-secret))
          (should (equal '("_harness/secrets/shape") (mapcar #'car (harness-ui-secrets-test--calls))))
          (should-not (harness-ui-secrets-test--asked 'read-string)))))))

(ert-deftest harness-ui-secrets-a-file-with-no-string-is-refused ()
  "A file whose shape has no string to be a secret ends the command with a message."
  (harness-ui-secrets-test-with
    (harness-ui-secrets-test-asking nil
      (should-error
       (harness-ui-secrets--choose-path
        "/data/numbers.json"
        (list :paths (vector (list :path "$" :type "object") (list :path "$.n" :type "number"))
              :truncated :false))
       :type 'user-error))))

(defvar harness-ui-secrets-test--kinds nil
  "The ways to name a secret the stand-in prompt answers with, in turn.")

(ert-deftest harness-ui-secrets-asks-for-a-regexp-a-variable-and-a-command ()
  "The other ways to name a secret make the references the engine reads."
  (harness-ui-secrets-test-with
    (let ((sources nil))
      (harness-ui-secrets-test-asking
          (list (cons "Where is the secret?"
                      (lambda (_prompt choices &rest _)
                        (should (member "Type it (hidden)" choices))
                        (pop harness-ui-secrets-test--kinds)))
                (cons "File that holds the secret" "/data/.env")
                (cons "Regexp with one group" "TOKEN=\\(.*\\)")
                (cons "Environment variable" " SOME_TOKEN_VARIABLE ")
                (cons "Shell command" " pass show spaces "))
        (let ((harness-ui-secrets-test--kinds
               '("File and regexp" "Environment variable" "Command output")))
          (dotimes (_ 3)
            (harness-ui-secrets--read-source t (lambda (s) (push s sources))))))
      (setq sources (nreverse sources))
      (should (equal '(:file "/data/.env" :regexp "TOKEN=\\(.*\\)") (plist-get (nth 0 sources) :ref)))
      (should (equal '(:env "SOME_TOKEN_VARIABLE") (plist-get (nth 1 sources) :ref)))
      (should (equal '(:command "pass show spaces") (plist-get (nth 2 sources) :ref)))
      ;; Only the command is the harness's to be allowed to run.
      (should-not (plist-get (nth 0 sources) :unsafe))
      (should-not (plist-get (nth 1 sources) :unsafe))
      (should (plist-get (nth 2 sources) :unsafe))
      ;; The default labels.
      (should (equal ".env" (plist-get (nth 0 sources) :label)))
      (should (equal "SOME_TOKEN_VARIABLE" (plist-get (nth 1 sources) :label)))
      (should (equal "command output" (plist-get (nth 2 sources) :label))))))

(ert-deftest harness-ui-secrets-regexp-needs-a-group ()
  "A regexp without a capture group is refused before anything is sent."
  (harness-ui-secrets-test-with
    (dolist (regexp '("TOKEN=.*" "TOKEN=\\(?:.*\\)"))
      (harness-ui-secrets-test-asking
          (list (cons "Where is the secret?" "File and regexp")
                (cons "File that holds the secret" "/data/.env")
                (cons "Regexp with one group" regexp))
        (should-error (harness-ui-secrets--read-source t #'ignore) :type 'user-error)))
    ;; A group that captures, numbered or not, is taken.
    (dolist (regexp '("TOKEN=\\(.*\\)" "TOKEN=\\(?1:.*\\)" "\\(?:A\\|B\\)=\\(.*\\)"))
      (let ((sources nil))
        (harness-ui-secrets-test-asking
            (list (cons "Where is the secret?" "File and regexp")
                  (cons "File that holds the secret" "/data/.env")
                  (cons "Regexp with one group" regexp))
          (harness-ui-secrets--read-source t (lambda (s) (push s sources))))
        (should (equal regexp (plist-get (plist-get (car sources) :ref) :regexp)))))))

(ert-deftest harness-ui-secrets-default-labels-come-from-the-path ()
  "The label offered is the last name in the path that says what the secret is."
  (should (equal "velero_k8s_backup_spaces_keys"
                 (harness-ui-secrets--default-label
                  (list :file "/s/terraform.tfstate"
                        :json-path "outputs.velero_k8s_backup_spaces_keys.value"))))
  (should (equal "access_key"
                 (harness-ui-secrets--default-label
                  (list :file "/s/terraform.tfstate" :json-path "outputs.keys.value[0].access_key"))))
  (should (equal "keys"
                 (harness-ui-secrets--default-label
                  (list :file "/s/terraform.tfstate" :json-path "$.outputs.keys.value[0]"))))
  (should (equal "terraform"
                 (harness-ui-secrets--default-label (list :file "/s/terraform.tfstate" :json-path "$.value"))))
  (should (equal ".env" (harness-ui-secrets--default-label (list :file "/s/.env" :regexp "\\(x\\)"))))
  (should (equal "TOKEN" (harness-ui-secrets--default-label (list :env "TOKEN"))))
  (should (equal "secret" (harness-ui-secrets--default-label (list :literal "x")))))

(ert-deftest harness-ui-secrets-asks-which-sessions ()
  "The scope offers the current session only in a session's buffer."
  (harness-ui-secrets-test-with
    (puthash "s-one" (list :id "s-one" :name "One" :status "idle" :project "/data/funkyboy")
             harness-ui--sessions)
    (puthash "s-two" (list :id "s-two" :name "Two" :status "idle" :project "/data/other")
             harness-ui--sessions)
    (let ((offered nil))
      (cl-flet ((choose (answer)
                  (harness-ui-secrets-test-asking
                      (list (cons "Clean:" (lambda (_prompt choices &rest _)
                                             (setq offered choices)
                                             answer))
                            (cons "Session ids" (lambda (&rest _) '(" s-one" "s-two" "s-one" ""))))
                    (harness-ui-secrets--read-scope))))
        ;; Away from a session: all, the project, named sessions.
        (should (equal '("All sessions" "This project" "Sessions…")
                       (progn (choose "All sessions") offered)))
        (should (equal '(:scope "all") (choose "All sessions")))
        (should (equal '(:scope "session" :sessions ("s-one" "s-two")) (choose "Sessions…")))
        ;; In a session: that session and its forks, and its project.
        (with-temp-buffer
          (setq-local harness-ui-session-id "s-one")
          (should (equal '(:scope "session" :sessions ("s-one"))
                         (choose "This session and its forks")))
          (should (member "This session and its forks" offered))
          (should (equal '(:scope "project" :project "/data/funkyboy") (choose "This project"))))))))

;;;; A secret typed in

(defun harness-ui-secrets-test--typed-flow (typed)
  "Run `harness-redact-secret' with the value TYPED, a string, typed hidden.
Return the calls' literals as copies made when each was sent."
  (let ((literals nil))
    (harness-ui-secrets-test-answering
        (list (cons "_harness/secrets/redact"
                    (lambda (params)
                      (push (copy-sequence (plist-get (plist-get (plist-get params :params) :source) :literal))
                            literals)
                      (harness-ui-secrets-test--engine params))))
      (harness-ui-secrets-test-asking
          (list (cons "Where is the secret?" "Type it (hidden)")
                (cons "Secret to redact" typed)
                (cons "Label for the placeholder" "typed key")
                (cons "Clean:" "All sessions")
                (cons "Reason" "pasted by mistake")
                (cons "Redact " t))
        (harness-redact-secret)))
    (nreverse literals)))

(ert-deftest harness-ui-secrets-typed-secret-goes-only-to-this-machine ()
  "A typed secret is sent, flagged unsafe, to a harness here; it is cleared afterwards."
  (harness-ui-secrets-test-with
    (let ((typed (copy-sequence harness-ui-secrets-test--key))
          (fp (harness-ui-secrets-test--fp harness-ui-secrets-test--key)))
      (harness-ui-secrets-test-collecting
        (let ((literals (harness-ui-secrets-test--typed-flow typed))
              (calls (harness-ui-secrets-test--calls "_harness/secrets/redact")))
          ;; Scan and redaction both carried it, with the leave to take it.
          (should (equal (list harness-ui-secrets-test--key harness-ui-secrets-test--key) literals))
          (dolist (c calls)
            (should (eq t (plist-get (plist-get (cadr c) :params) :allow-unsafe-sources)))
            (should (equal "typed key" (plist-get (plist-get (cadr c) :params) :label))))
          ;; Wiped from memory once the last answer was in.
          (should (cl-every #'zerop typed))
          ;; Nothing shown or said holds it.
          (dolist (m (harness-ui-secrets-test--said))
            (should-not (harness-ui-secrets-test--holds-p m)))
          (should-not (harness-ui-secrets-test--holds-p
                       (harness-ui-secrets-test--text harness-ui-secrets-report-buffer-name)))
          (should (string-match-p (regexp-quote fp)
                                  (mapconcat #'identity (harness-ui-secrets-test--said) "\n"))))))))

(ert-deftest harness-ui-secrets-typed-secret-is-wiped-when-declined ()
  "A no, or a quit, leaves no copy of the typed secret behind."
  (harness-ui-secrets-test-with
    (harness-ui-secrets-test-collecting
      ;; Declined after the scan.
      (let ((typed (copy-sequence harness-ui-secrets-test--key)))
        (harness-ui-secrets-test-answering (harness-ui-secrets-test--engine-answers)
          (harness-ui-secrets-test-asking
              (list (cons "Where is the secret?" "Type it (hidden)")
                    (cons "Secret to redact" typed)
                    (cons "Label for the placeholder" "")
                    (cons "Clean:" "All sessions")
                    (cons "Reason" "")
                    (cons "Redact " nil))
            (harness-redact-secret)))
        (should (cl-every #'zerop typed)))
      ;; Quit at the scope prompt.
      (let ((typed (copy-sequence harness-ui-secrets-test--key)))
        (harness-ui-secrets-test-answering (harness-ui-secrets-test--engine-answers)
          (harness-ui-secrets-test-asking
              (list (cons "Where is the secret?" "Type it (hidden)")
                    (cons "Secret to redact" typed)
                    (cons "Label for the placeholder" "")
                    (cons "Clean:" (lambda (&rest _) (signal 'quit nil))))
            ;; `should-error' does not catch a quit.
            (should (eq 'quit (condition-case nil (harness-redact-secret) (quit 'quit))))
            (should-not (harness-ui-secrets-test--calls))))
        (should (cl-every #'zerop typed))))))

(defun harness-ui-secrets-test--typed-replies (typed &optional confirm)
  "Return the replies of a user who types TYPED, hidden, and answers CONFIRM at the end."
  (list (cons "Where is the secret?" "Type it (hidden)")
        (cons "Secret to redact" typed)
        (cons "Label for the placeholder" "typed key")
        (cons "Clean:" "All sessions")
        (cons "Reason" "")
        (cons "Redact " confirm)))

(ert-deftest harness-ui-secrets-typed-secret-is-wiped-when-the-harness-fails ()
  "A scan or a redaction the harness rejects leaves no copy of the typed secret.
The error the harness gives is shown with its message, without the data
it carries.  A redaction that failed still cleans the buffers of this
Emacs, where the value is known; a scan that failed changes nothing."
  (harness-ui-secrets-test-with
    (dolist (failing '("scan" "redact"))
      (let ((typed (copy-sequence harness-ui-secrets-test--key))
            (log (get-buffer-create "*harness-log*")))
        (with-current-buffer log
          (erase-buffer)
          (insert (format "token %s was shown\n" harness-ui-secrets-test--key)))
        (harness-ui-secrets-test-collecting
          (harness-ui-secrets-test-answering
              (list (cons "_harness/secrets/redact"
                          (lambda (params)
                            (if (equal failing (plist-get (plist-get params :params) :mode))
                                (list 'harness-ui-secrets-test--fail
                                      (list 'acp-error -32000 "the index is locked"
                                            (list :quoted harness-ui-secrets-test--key)))
                              (harness-ui-secrets-test--engine params)))))
            (harness-ui-secrets-test-asking (harness-ui-secrets-test--typed-replies typed t)
              (harness-redact-secret)))
          (should (cl-every #'zerop typed))
          (should (cl-some (lambda (m) (string-match-p "the index is locked" m))
                           (harness-ui-secrets-test--said)))
          (dolist (m (harness-ui-secrets-test--said))
            (should-not (harness-ui-secrets-test--holds-p m)))
          (should-not (harness-ui-secrets-test--holds-p
                       (harness-ui-secrets-test--text harness-ui-secrets-report-buffer-name)))
          (should (eq (equal failing "redact")
                      (not (harness-ui-secrets-test--holds-p (harness-ui-secrets-test--text log))))))))))

(ert-deftest harness-ui-secrets-typed-secret-is-wiped-when-nothing-is-found ()
  "A typed secret no store holds is scanned for, not asked about, and wiped."
  (harness-ui-secrets-test-with
    (let ((typed (copy-sequence harness-ui-secrets-test--key)))
      (harness-ui-secrets-test-collecting
        (harness-ui-secrets-test-answering
            (list (cons "_harness/secrets/redact"
                        (lambda (params)
                          (plist-put (harness-ui-secrets-test--engine params) :total 0))))
          ;; No confirmation is expected: the reply for it would be consulted if it were asked.
          (harness-ui-secrets-test-asking (butlast (harness-ui-secrets-test--typed-replies typed))
            (harness-redact-secret))
          (should (= 1 (length (harness-ui-secrets-test--calls))))))
      (should (cl-every #'zerop typed)))))

(ert-deftest harness-ui-secrets-typed-secret-cleans-the-buffers-of-this-emacs ()
  "The value being known here, the log buffers and chats of this Emacs lose it too."
  (harness-ui-secrets-test-with
    (let* ((typed (copy-sequence harness-ui-secrets-test--key))
           (fp (harness-ui-secrets-test--fp harness-ui-secrets-test--key))
           (log (get-buffer-create "*harness-log*"))
           (chat (get-buffer-create "*harness-test chat*"))
           (file (expand-file-name "notes.txt" (harness-test-temp-dir)))
           (visiting nil)
           (other (get-buffer-create "*harness-test other*")))
      (with-temp-file file (insert (format "my notes: %s\n" harness-ui-secrets-test--key)))
      (setq visiting (find-file-noselect file))
      (with-current-buffer visiting (rename-buffer "*harness-test visiting*"))
      (dolist (b (list log chat))
        (with-current-buffer b
          (insert (format "token %s was shown\n" harness-ui-secrets-test--key))))
      ;; A buffer the harness does not own is not this command's.
      (with-current-buffer other (rename-buffer "scratch-of-the-user" t))
      (with-current-buffer other (insert (format "%s\n" harness-ui-secrets-test--key)))
      (harness-ui-secrets-test-collecting
        (harness-ui-secrets-test--typed-flow typed))
      (dolist (b (list log chat))
        (let ((text (harness-ui-secrets-test--text b)))
          (should-not (harness-ui-secrets-test--holds-p text))
          (should (string-search (format "[redacted: typed key sha256:%s]" fp) text))))
      ;; A buffer that visits a file is never touched, the user's own neither.
      (should (harness-ui-secrets-test--holds-p (harness-ui-secrets-test--text visiting)))
      (should (harness-ui-secrets-test--holds-p (harness-ui-secrets-test--text other)))
      (with-current-buffer visiting (set-buffer-modified-p nil))
      (kill-buffer visiting)
      (kill-buffer other))))

(ert-deftest harness-ui-secrets-typed-secret-placeholder-carries-the-users-label ()
  "A report that names no matching secret leaves the label the user typed."
  (harness-ui-secrets-test-with
    (let* ((typed (copy-sequence harness-ui-secrets-test--key))
           (fp (harness-ui-secrets-test--fp harness-ui-secrets-test--key))
           (log (get-buffer-create "*harness-log*")))
      (with-current-buffer log
        (insert (format "token %s was shown\n" harness-ui-secrets-test--key)))
      (harness-ui-secrets-test-collecting
        (harness-ui-secrets-test-answering
            (list (cons "_harness/secrets/redact"
                        (lambda (params)
                          (plist-put (harness-ui-secrets-test--engine params) :secrets
                                     (list (list :label "engine label" :fingerprint "deadbeef"))))))
          (harness-ui-secrets-test-asking
              (list (cons "Where is the secret?" "Type it (hidden)")
                    (cons "Secret to redact" typed)
                    (cons "Label for the placeholder" "typed key")
                    (cons "Clean:" "All sessions")
                    (cons "Reason" "")
                    (cons "Redact " t))
            (harness-redact-secret))))
      (let ((text (harness-ui-secrets-test--text log)))
        (should-not (harness-ui-secrets-test--holds-p text))
        (should (string-search (format "[redacted: typed key sha256:%s]" fp) text))))))

(ert-deftest harness-ui-secrets-typed-secret-refused-for-another-machine ()
  "A harness on another machine is never sent a typed secret; nothing is asked."
  (harness-ui-secrets-test-with
    (dolist (address '("198.51.100.7:4242" "harness.example.org:4242" "127.example.com:4242"
                       "localhost.example.com:4242"))
      (let ((harness-ui-connection-address address))
        (harness-ui-secrets-test-collecting
          (harness-ui-secrets-test-answering (harness-ui-secrets-test--engine-answers)
            ;; The kind is asked; the secret itself is not: read-passwd would fail the test.
            (harness-ui-secrets-test-asking
                (list (cons "Where is the secret?" "Type it (hidden)"))
              (let ((err (should-error (harness-redact-secret) :type 'user-error)))
                (should (string-match-p "this machine" (cadr err)))
                (should (string-match-p "environment variable" (cadr err))))
              (should-not (harness-ui-secrets-test--asked 'read-passwd))
              (should-not (harness-ui-secrets-test--calls)))))))))

(ert-deftest harness-ui-secrets-local-harness-addresses ()
  "The harness of this Emacs, its process and a loopback address are on this machine."
  (dolist (address (list nil 'process "127.0.0.1:4242" "localhost:4242" "[::1]:4242" "127.1.2.3:9"))
    (let ((harness-ui-connection-address address))
      (should (harness-ui-secrets--local-p))))
  (dolist (address '("198.51.100.7:4242" "harness.example.org:4242" "127.example.com:4242"
                     "localhost.example.com:4242" "10.0.0.5:4242" "[2001:db8::1]:4242"))
    (let ((harness-ui-connection-address address))
      (should-not (harness-ui-secrets--local-p)))))

(ert-deftest harness-ui-secrets-another-machine-gets-paths-as-typed ()
  "The file of a remote harness is on its machine: the name is not expanded here."
  (harness-ui-secrets-test-with
    (let ((harness-ui-connection-address "198.51.100.7:4242")
          (sources nil))
      (harness-ui-secrets-test-asking
          (list (cons "Where is the secret?" "File and regexp")
                (cons "File that holds the secret" "~/.secrets/spaces.env ")
                (cons "Regexp with one group" "KEY=\\(.*\\)"))
        (harness-ui-secrets--read-source t (lambda (s) (push s sources))))
      (should (equal '(:file "~/.secrets/spaces.env" :regexp "KEY=\\(.*\\)")
                     (plist-get (car sources) :ref)))
      ;; read-file-name would complete against the files of this machine.
      (should-not (harness-ui-secrets-test--asked 'read-file-name)))))

;;;; Following the harness

(defun harness-ui-secrets-test--dispatch (event &rest args)
  "Deliver EVENT with ARGS to the UI as the harness's notification does."
  (run-hook-with-args 'harness-ui-event-functions event args))

(ert-deftest harness-ui-secrets-redacted-session-reloads-its-chat ()
  "The open chat of a redacted session loads its transcript again; others are left."
  (harness-ui-secrets-test-with
    (let ((open (generate-new-buffer "*harness-test chat open*"))
          (other (generate-new-buffer "*harness-test chat other*"))
          (loads nil))
      (with-current-buffer open (setq-local harness-ui-session-id "s-open"))
      (with-current-buffer other (setq-local harness-ui-session-id "s-other"))
      (puthash "s-open" open harness-chat--buffers)
      (puthash "s-other" other harness-chat--buffers)
      (unwind-protect
          (cl-letf (((symbol-function 'harness-chat--load)
                     (lambda (&optional keep-bottom)
                       (push (list (current-buffer) keep-bottom) loads))))
            (harness-ui-secrets-test--dispatch
             "session/redacted" "s-open" (list :labels '("keys") :count 3))
            (should (equal (list (list open t)) loads))
            ;; A session no chat shows has nothing to load; a malformed event does no harm.
            (harness-ui-secrets-test--dispatch "session/redacted" "s-closed" nil)
            (harness-ui-secrets-test--dispatch "session/redacted")
            (should (= 1 (length loads)))
            ;; Other events are not this module's.
            (harness-ui-secrets-test--dispatch "config/changed" "s-open")
            (should (= 1 (length loads))))
        (remhash "s-open" harness-chat--buffers)
        (remhash "s-other" harness-chat--buffers)
        (kill-buffer open)
        (kill-buffer other)))))

(defun harness-ui-secrets-test--summary (ref &optional secrets)
  "Return the summary the harness announces for a redaction of REF's SECRETS.
SECRETS default to those REF resolves to, as the engine named them."
  (let ((secrets (or secrets (plist-get (harness-redaction-resolve ref) :secrets))))
    (list :source ref
          :secrets (mapcar (lambda (s) (list :label (plist-get s :label)
                                             :fingerprint (plist-get s :fingerprint)))
                           secrets)
          :sessions '("s1"))))

(defmacro harness-ui-secrets-test-with-log-buffers (&rest body)
  "Run BODY with buffers that hold the fake key, bound to the variables below.
`log' is *harness-log*, `messages' is *Messages*, `extra' another buffer of
the harness's, `visiting' a buffer of the harness's name that visits a file,
and `plain' a buffer of the user's."
  (declare (indent 0))
  `(let* ((log (get-buffer-create "*harness-log*"))
          (messages (get-buffer-create "*Messages*"))
          (extra (get-buffer-create "*harness-test extra*"))
          (plain (get-buffer-create "*harness-test plain*"))
          (file (expand-file-name "notes.txt" (harness-test-temp-dir)))
          (visiting (progn (with-temp-file file (insert (format "note: %s\n" harness-ui-secrets-test--key)))
                           (find-file-noselect file))))
     (with-current-buffer plain (rename-buffer "user-scratch" t))
     (setq plain (get-buffer "user-scratch"))
     (with-current-buffer visiting (rename-buffer "*harness-test visiting*"))
     (dolist (b (list log messages extra plain))
       (with-current-buffer b
         (let ((inhibit-read-only t))
           (goto-char (point-max))
           (insert (format "line: %s and %s\n" harness-ui-secrets-test--key harness-ui-secrets-test--id)))))
     (unwind-protect (progn ,@body)
       (dolist (b (list visiting plain))
         (when (buffer-live-p b)
           (with-current-buffer b (set-buffer-modified-p nil))
           (kill-buffer b))))))

(ert-deftest harness-ui-secrets-redaction-event-cleans-the-log-buffers ()
  "A file this Emacs reads as the harness did gives the secrets to clean its buffers of."
  (harness-ui-secrets-test-with
    (let* ((file (harness-ui-secrets-test--state-file))
           (ref (list :file file :json-path "outputs.keys.value" :label "keys"))
           (fps (mapcar (lambda (s) (plist-get s :fingerprint)) (harness-ui-secrets-test--secrets))))
      (harness-ui-secrets-test-with-log-buffers
        (harness-ui-secrets-test--dispatch "secrets/redacted" (harness-ui-secrets-test--summary ref))
        (dolist (b (list log messages extra))
          (let ((text (harness-ui-secrets-test--text b)))
            (should-not (harness-ui-secrets-test--holds-p text))
            (dolist (fp fps)
              (should (string-search (format "sha256:%s]" fp) text)))))
        ;; A buffer that visits a file is not touched, nor is one that is not the harness's.
        (should (harness-ui-secrets-test--holds-p (harness-ui-secrets-test--text visiting)))
        (should (harness-ui-secrets-test--holds-p (harness-ui-secrets-test--text plain)))))))

(ert-deftest harness-ui-secrets-redaction-event-uses-the-label-the-harness-gave ()
  "The placeholders this Emacs writes read as the harness's own."
  (harness-ui-secrets-test-with
    (let* ((file (harness-ui-secrets-test--state-file))
           (ref (list :file file :json-path "outputs.keys.value"))
           (secrets (plist-get (harness-redaction-resolve ref) :secrets))
           (named (mapcar (lambda (s) (list :label (format "named-%s" (plist-get s :fingerprint))
                                            :fingerprint (plist-get s :fingerprint)))
                          secrets)))
      (harness-ui-secrets-test-with-log-buffers
        (harness-ui-secrets-test--dispatch "secrets/redacted"
                                           (list :source ref :secrets named :sessions nil))
        (let ((text (harness-ui-secrets-test--text log)))
          (dolist (s secrets)
            (should (string-search (format "[redacted: named-%s sha256:%s]"
                                           (plist-get s :fingerprint) (plist-get s :fingerprint))
                                   text))))))))

(ert-deftest harness-ui-secrets-redaction-event-follows-a-variable ()
  "A variable this Emacs has too, with the fingerprint the harness named, is cleaned."
  (harness-ui-secrets-test-with
    (let* ((process-environment (cons (concat "HARNESS_UI_SECRETS_TEST_KEY=" harness-ui-secrets-test--key)
                                      process-environment))
           (ref (list :env "HARNESS_UI_SECRETS_TEST_KEY" :label "key")))
      (harness-ui-secrets-test-with-log-buffers
        (harness-ui-secrets-test--dispatch "secrets/redacted" (harness-ui-secrets-test--summary ref))
        (let ((text (harness-ui-secrets-test--text log)))
          ;; The key only: the id was not in the variable.
          (should-not (string-search harness-ui-secrets-test--key text))
          (should (string-search harness-ui-secrets-test--id text))
          (should (string-search (format "[redacted: key sha256:%s]"
                                         (harness-ui-secrets-test--fp harness-ui-secrets-test--key))
                                 text)))))))

(ert-deftest harness-ui-secrets-redaction-event-leaves-the-buffers-when-unsure ()
  "A fingerprint that differs, a source this Emacs cannot read, or another machine: no change."
  (harness-ui-secrets-test-with
    (let* ((file (harness-ui-secrets-test--state-file))
           (ref (list :file file :json-path "outputs.keys.value" :label "keys"))
           (secrets (plist-get (harness-redaction-resolve ref) :secrets))
           (good (harness-ui-secrets-test--summary ref secrets)))
      (harness-ui-secrets-test-with-log-buffers
        (let ((before (mapcar #'harness-ui-secrets-test--text (list log messages extra))))
          (cl-flet ((unchanged ()
                      (should (equal before (mapcar #'harness-ui-secrets-test--text
                                                    (list log messages extra))))))
            ;; The harness redacted another secret than the one this Emacs reads.
            (harness-ui-secrets-test--dispatch
             "secrets/redacted"
             (list :source ref :secrets (list (list :label "keys" :fingerprint "deadbeef")) :sessions nil))
            (unchanged)
            ;; The file holds more than the harness redacted: a different file.
            (harness-ui-secrets-test--dispatch
             "secrets/redacted"
             (list :source ref :secrets (list (car (plist-get good :secrets))) :sessions nil))
            (unchanged)
            ;; A file this Emacs does not have.
            (harness-ui-secrets-test--dispatch
             "secrets/redacted"
             (list :source (list :file (expand-file-name "nope.json" (file-name-directory file))
                                 :json-path "outputs.keys.value")
                   :secrets (plist-get good :secrets) :sessions nil))
            (unchanged)
            ;; A variable this Emacs lacks.
            (harness-ui-secrets-test--dispatch
             "secrets/redacted"
             (list :source (list :env "HARNESS_UI_SECRETS_TEST_UNSET")
                   :secrets (plist-get good :secrets) :sessions nil))
            (unchanged)
            ;; A typed secret or a command: not a reference to read here.
            (harness-ui-secrets-test--dispatch
             "secrets/redacted"
             (list :source (list :kind "literal") :secrets (plist-get good :secrets) :sessions nil))
            (unchanged)
            ;; Malformed events do no harm.
            (harness-ui-secrets-test--dispatch "secrets/redacted")
            (harness-ui-secrets-test--dispatch "secrets/redacted" "not a summary")
            (unchanged)
            ;; A harness on another machine has other files: its references are not followed.
            (let ((harness-ui-connection-address "198.51.100.7:4242"))
              (harness-ui-secrets-test--dispatch "secrets/redacted" good))
            (unchanged)
            ;; Sure, it cleans.
            (harness-ui-secrets-test--dispatch "secrets/redacted" good)
            (should-not (equal before (mapcar #'harness-ui-secrets-test--text (list log messages extra))))))))))

(ert-deftest harness-ui-secrets-event-failure-is-logged-without-data ()
  "A handler that fails says what failed, not what it was given."
  (harness-ui-secrets-test-with
    (let ((logged nil))
      (cl-letf (((symbol-function 'harness-ui-secrets--on-secrets-redacted)
                 (lambda (_summary)
                   (signal 'wrong-type-argument (list 'stringp harness-ui-secrets-test--key))))
                ((symbol-function 'harness-log)
                 (lambda (_level fmt &rest args) (push (apply #'format fmt args) logged))))
        (harness-ui-secrets-test--dispatch "secrets/redacted" (list :source nil))
        (should logged)
        (dolist (line logged)
          (should-not (harness-ui-secrets-test--holds-p line)))))))

(ert-deftest harness-ui-secrets-error-text-leaves-the-data-out ()
  "An error is described by the harness's own message or by its kind, not its data."
  (let ((key harness-ui-secrets-test--key))
    (should (equal "no such variable"
                   (harness-ui-secrets--error-text (list 'acp-error -32000 "no such variable" (list :x key)))))
    (should (equal "wrong-type-argument"
                   (harness-ui-secrets--error-text (list 'wrong-type-argument 'stringp key))))
    (should (equal "Nothing to redact"
                   (harness-ui-secrets--error-text '(harness-error "Nothing to redact"))))
    ;; A harness-error with data besides its message may quote it: only its kind is said.
    (should (equal "harness-error"
                   (harness-ui-secrets--error-text (list 'harness-error "Quoted" key))))
    (should (equal "error" (harness-ui-secrets--error-text (cons 'error (list key)))))
    (should (equal "an error" (harness-ui-secrets--error-text nil)))))

;;;; The path to a secret in a file

(ert-deftest harness-ui-secrets-offers-objects-arrays-and-strings-of-the-shape ()
  "Only nodes that can hold a secret are offered, each with its type; never a value."
  (harness-ui-secrets-test-with
    (let ((shape (list :file "/data/state.json"
                       :paths (vector (list :path "$" :type "object")
                                      (list :path "$.a" :type "string")
                                      (list :path "$.n" :type "number")
                                      (list :path "$.list" :type "array")
                                      (list :path "$.list[0]" :type "string")
                                      (list :path "$.ok" :type "boolean"))
                       :truncated :false))
          (offered nil) (annotated nil))
      (harness-ui-secrets-test-asking
          (list (cons "JSON path in state.json"
                      (lambda (_prompt table _pred _required _initial _hist default)
                        (setq offered (all-completions "" table)
                              annotated (funcall (completion-metadata-get
                                                  (completion-metadata "" table nil)
                                                  'annotation-function)
                                                 "$.list[0]"))
                        (should (equal "$" default))
                        "$.list[0]")))
        (should (equal "$.list[0]" (harness-ui-secrets--choose-path "/data/state.json" shape))))
      (should (equal '("$" "$.a" "$.list" "$.list[0]") offered))
      (should (equal "  string" annotated)))))

(ert-deftest harness-ui-secrets-a-big-file-lets-you-type-the-path ()
  "When the shape was cut short, a path that is not offered may be typed."
  (harness-ui-secrets-test-with
    (let ((required :unset))
      (harness-ui-secrets-test-asking
          (list (cons "JSON path in big.json"
                      (lambda (_prompt _table _pred require-match &rest _)
                        (setq required require-match)
                        "$.deep.down")))
        (should (equal "$.deep.down"
                       (harness-ui-secrets--choose-path
                        "/data/big.json"
                        (list :paths (vector (list :path "$" :type "object")
                                             (list :path "$.a" :type "string"))
                              :truncated t)))))
      (should-not required))))

;;;; The registry of secrets to mask

(defun harness-ui-secrets-test--sources ()
  "Return the sources a harness lists."
  (list (list :id "config-1" :label "api token" :source "environment variable API_TOKEN"
              :origin "config" :values 1 :fingerprints '("11111111"))
        (list :id "src-abc" :label "spaces" :source "file /s/state.json, JSON path outputs.keys.value"
              :origin "stored" :values 2 :fingerprints '("22222222" "33333333"))
        (list :id "src-bad" :label "gone" :source "file /s/gone.json, JSON path a"
              :origin "stored" :values 0 :fingerprints nil :error "no value at a")))

(ert-deftest harness-ui-secrets-lists-sources-without-values ()
  "The list shows label, source, values, fingerprints, origin and error; `d' removes a stored one."
  (harness-ui-secrets-test-with
    (harness-ui-secrets-test-collecting
      (harness-ui-secrets-test-answering
          (list (cons "_harness/secrets/sources" (lambda (_) (harness-ui-secrets-test--sources)))
                (cons "_harness/secrets/remove-source"
                      (lambda (params) (list :id (plist-get params :id) :removed t))))
        (harness-secrets-list-sources)
        (with-current-buffer "*harness secrets*"
          (should (derived-mode-p 'harness-ui-secrets-sources-mode))
          (let ((text (buffer-substring-no-properties (point-min) (point-max))))
            (dolist (wanted '("api token" "environment variable API_TOKEN" "22222222" "33333333"
                              "spaces" "no value at a" "config" "stored"))
              (should (string-match-p (regexp-quote wanted) text))))
          (should (eq 'harness-ui-secrets-remove-source (key-binding (kbd "d"))))
          (should (eq 'harness-secrets-add-source (key-binding (kbd "a"))))
          (should (eq 'harness-ui-quit-view (key-binding (kbd "q"))))
          ;; A source of the setting is the setting's to change.
          (goto-char (point-min))
          (while (and (not (eobp)) (not (equal "config-1" (tabulated-list-get-id)))) (forward-line 1))
          (should (equal "config-1" (tabulated-list-get-id)))
          (let ((err (should-error (harness-ui-secrets-remove-source) :type 'user-error)))
            (should (string-match-p "harness-secrets-sources" (cadr err))))
          (should-not (harness-ui-secrets-test--calls "_harness/secrets/remove-source"))
          ;; A stored one asks, then goes; the list is read again.
          (goto-char (point-min))
          (while (and (not (eobp)) (not (equal "src-abc" (tabulated-list-get-id)))) (forward-line 1))
          (let ((reads (length (harness-ui-secrets-test--calls "_harness/secrets/sources"))))
            (harness-ui-secrets-test-asking (list (cons "Stop masking spaces" t))
              (harness-ui-secrets-remove-source))
            (should (equal '((:id "src-abc"))
                           (mapcar #'cadr (harness-ui-secrets-test--calls "_harness/secrets/remove-source"))))
            (should (> (length (harness-ui-secrets-test--calls "_harness/secrets/sources")) reads))))
        (should (cl-some (lambda (m) (string-match-p "No longer masking spaces" m))
                         (harness-ui-secrets-test--said)))))))

(defun harness-ui-secrets-test--cut-cells ()
  "Return how many cells of the current list show a cut text: an ellipsis `display'."
  (let ((pos (point-min)) (cut 0))
    (while (setq pos (next-single-property-change pos 'display))
      (when (stringp (get-text-property pos 'display))
        (cl-incf cut)))
    cut))

(ert-deftest harness-ui-secrets-sources-list-shows-the-json-path-that-tells-sources-apart ()
  "The Source column grows to the longest source, so a long file name does not hide the path.
The cut of a cell is a `display' ellipsis, which the text of the buffer
does not show; the column stops growing at its limit."
  (harness-ui-secrets-test-with
    (let* ((short "environment variable API_TOKEN")
           (long (concat "file ~/infra/terraform-output.json, JSON path "
                         "outputs.demo_spaces_keys.value.secret_key"))
           (huge (concat "file /" (make-string 150 ?x) ".json, JSON path a"))
           (sources (list (list :id "config-1" :label "api token" :source short
                                :origin "config" :values 1 :fingerprints '("11111111"))
                          (list :id "src-1" :label "spaces" :source long
                                :origin "stored" :values 1 :fingerprints '("22222222")))))
      (harness-ui-secrets-test-collecting
        (harness-ui-secrets-test-answering
            (list (cons "_harness/secrets/sources" (lambda (_) sources)))
          (harness-secrets-list-sources)
          (with-current-buffer "*harness secrets*"
            ;; As wide as the longest source, no cell cut: the path is on show.
            (should (= (string-width long) (cadr (aref tabulated-list-format 1))))
            (should (= 0 (harness-ui-secrets-test--cut-cells)))
            ;; Short sources keep the usual width.
            (setq sources (list (car sources)))
            (harness-ui-secrets-reload)
            (should (= harness-ui-secrets--source-width (cadr (aref tabulated-list-format 1))))
            (should (= 0 (harness-ui-secrets-test--cut-cells)))
            ;; A very long one stops at the limit, and its cell is cut there.
            (setq sources (list (list :id "src-2" :label "far" :source huge :origin "stored"
                                      :values 1 :fingerprints '("33333333"))))
            (harness-ui-secrets-reload)
            (should (= harness-ui-secrets--source-width-limit (cadr (aref tabulated-list-format 1))))
            (should (= 1 (harness-ui-secrets-test--cut-cells)))))))))

(ert-deftest harness-ui-secrets-add-source-sends-a-reference-never-a-value ()
  "A source is named by where it is read; typing the secret is not offered."
  (harness-ui-secrets-test-with
    (harness-ui-secrets-test-collecting
      (harness-ui-secrets-test-answering
          (list (cons "_harness/secrets/add-source"
                      (lambda (params)
                        (list :id "src-new" :label (plist-get (plist-get params :ref) :label)
                              :values 2 :fingerprints '("aaaaaaaa" "bbbbbbbb"))))
                (cons "_harness/secrets/sources" (lambda (_) nil)))
        (harness-ui-secrets-test-asking
            (list (cons "Where is the secret?"
                        (lambda (_prompt choices &rest _)
                          (should-not (member "Type it (hidden)" choices))
                          (should (member "Command output" choices))
                          "Environment variable"))
                  (cons "Environment variable" "MY_TOKEN")
                  (cons "Label for the placeholder" "my token"))
          (harness-secrets-add-source))
        (let ((call (car (harness-ui-secrets-test--calls "_harness/secrets/add-source"))))
          (should (equal '(:ref (:env "MY_TOKEN" :label "my token")) (cadr call))))
        (should-not (harness-ui-secrets-test--asked 'read-passwd))
        (should (member "Masking 2 values of my token: sha256 aaaaaaaa, bbbbbbbb"
                        (harness-ui-secrets-test--said)))))))

(ert-deftest harness-ui-secrets-add-source-failure-is-reported ()
  "A source that cannot be read is not added, and the harness's message says why."
  (harness-ui-secrets-test-with
    (harness-ui-secrets-test-collecting
      (harness-ui-secrets-test-answering
          (list (cons "_harness/secrets/add-source"
                      (lambda (_)
                        (list 'harness-ui-secrets-test--fail
                              (list 'acp-error -32000 "MY_TOKEN is not set" nil)))))
        (harness-ui-secrets-test-asking
            (list (cons "Where is the secret?" "Environment variable")
                  (cons "Environment variable" "MY_TOKEN")
                  (cons "Label for the placeholder" ""))
          (harness-secrets-add-source))
        (should (cl-some (lambda (m) (string-match-p "was not added: MY_TOKEN is not set" m))
                         (harness-ui-secrets-test--said)))))))

(ert-deftest harness-ui-secrets-redactions-lists-what-was-run ()
  "The log shows when, who asked, why, the secrets by fingerprint and the counts."
  (harness-ui-secrets-test-with
    (let ((entries (list (list :ts 1700000000.0 :time "2023-11-14T22:13:20Z"
                               :origin (list :kind "session" :id "5a5a5a5a-aaaa")
                               :reason "shown in a diff" :scope "all sessions (4 sessions)"
                               :secrets (list (list :label "keys" :fingerprint "0a1b2c3d"
                                                    :source "file state.json"))
                               :total 5
                               :totals (list (list :store "node logs" :count 3)
                                             (list :store "search index" :count 2)
                                             (list :store "tasks" :count 0))
                               :sessions '("s1" "s2") :files '("/x/y.jsonl")
                               :complete t
                               :verification (list :ok t :total 0 :explained 0))
                         (list :ts 1700003600.0 :origin (list :kind "user") :reason nil
                               :secrets (list (list :label "token" :fingerprint "ffff0000"))
                               :total 1 :totals nil :complete :false
                               :errors '("search index: failed")
                               :remaining '("claude log is busy")))))
      (harness-ui-secrets-test-collecting
        (harness-ui-secrets-test-answering
            (list (cons "_harness/secrets/log" (lambda (_) entries)))
          (harness-redactions)
          (with-current-buffer "*harness redactions*"
            (should (derived-mode-p 'harness-ui-secrets-log-mode))
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (dolist (wanted (list (format-time-string "%Y-%m-%d %H:%M" 1700000000.0)
                                    "session 5a5a5a5a" "shown in a diff"
                                    "keys sha256:0a1b2c3d" "5 (node logs 3, search index 2)"
                                    "token sha256:ffff0000" "not complete"))
                (should (string-match-p (regexp-quote wanted) text))))
            ;; RET shows one whole, in a buffer of its own.
            (goto-char (point-min))
            (while (and (not (eobp)) (not (equal 0 (tabulated-list-get-id)))) (forward-line 1))
            (harness-ui-secrets-log-visit))
          (let* ((buffer (cl-find-if (lambda (b) (string-prefix-p "*harness redactions: " (buffer-name b)))
                                     (buffer-list)))
                 (text (harness-ui-secrets-test--text buffer)))
            (dolist (wanted '("Reason: shown in a diff" "keys (sha256:0a1b2c3d): file state.json"
                              "Occurrences: 5 (node logs 3, search index 2)" "Sessions (2): s1, s2"
                              "/x/y.jsonl" "Complete: yes" "Verification: ok"))
              (should (string-match-p (regexp-quote wanted) text)))))))))

(ert-deftest harness-ui-secrets-redactions-with-a-prefix-asks-for-that-many ()
  "A numeric prefix limits the entries the harness gives."
  (harness-ui-secrets-test-with
    (harness-ui-secrets-test-answering (list (cons "_harness/secrets/log" (lambda (_) nil)))
      (harness-redactions 7)
      (should (equal '(:limit 7) (cadr (car (harness-ui-secrets-test--calls "_harness/secrets/log")))))
      (with-current-buffer "*harness redactions*"
        (should (string-match-p "No redaction has been run"
                                (buffer-substring-no-properties (point-min) (point-max))))))))

;;;; The module

(ert-deftest harness-ui-secrets-menu-entries-and-hook-come-and-go-with-the-module ()
  "The commands are in the harness menu and the events are followed while it runs."
  (harness-ui-secrets-test-with
    (should (eq 'harness-redact-secret (harness-ui-secrets--suffix-command "x")))
    (should (eq 'harness-secrets-list-sources (harness-ui-secrets--suffix-command "E")))
    (should (memq 'harness-ui-secrets--on-event harness-ui-event-functions))
    ;; Starting again changes nothing.
    (harness-ui-secrets--init)
    (should (eq 'harness-redact-secret (harness-ui-secrets--suffix-command "x")))
    (harness-ui-secrets--shutdown)
    (should-not (harness-ui-secrets--suffix-command "x"))
    (should-not (harness-ui-secrets--suffix-command "E"))
    (should-not (memq 'harness-ui-secrets--on-event harness-ui-event-functions))
    (harness-ui-secrets--init)
    (should (eq 'harness-redact-secret (harness-ui-secrets--suffix-command "x")))
    (should (memq 'harness-ui-secrets--on-event harness-ui-event-functions))))

(ert-deftest harness-ui-secrets-menu-groups-teach-the-keys-of-the-buffers ()
  "Each command the menu lists for a view is on that key, behind `.', in the view."
  (harness-ui-secrets-test-with
    (dolist (mode '(harness-ui-secrets-sources-mode harness-ui-secrets-log-mode))
      (let ((group (get mode 'harness-menu-group))
            (map (symbol-value (intern (format "%s-map" mode))))
            (keys nil))
        (should group)
        (dolist (column (cdr group))
          (dolist (item (append column nil))
            (when (and (consp item) (stringp (car item)))
              (let* ((events (kbd (car item)))
                     (own (substring events 1)))
                (ert-info ((format "%s: %s" mode (car item)))
                  ;; One plain key behind `.', which the menu's own groups leave free.
                  (should (equal "." (key-description (substring events 0 1))))
                  (should (= 2 (length events)))
                  (should (commandp (nth 2 item)))
                  (should-not (member (car item) keys))
                  (push (car item) keys)
                  (should (eq (nth 2 item) (lookup-key map own))))))))))))

(ert-deftest harness-ui-secrets-menu-key-of-another-command-is-left-alone ()
  "A key the menu gives to another command is not taken over."
  (harness-ui-secrets-test-with
    (harness-ui-secrets--shutdown)
    (transient-append-suffix 'harness-menu "L" '("x" "Something else" ignore))
    (unwind-protect
        (progn
          (harness-ui-secrets--init)
          (should (eq 'ignore (harness-ui-secrets--suffix-command "x")))
          ;; The other command still gets its place.
          (should (eq 'harness-secrets-list-sources (harness-ui-secrets--suffix-command "E")))
          ;; And shutting down removes only what is ours.
          (harness-ui-secrets--shutdown)
          (should (eq 'ignore (harness-ui-secrets--suffix-command "x")))
          (should-not (harness-ui-secrets--suffix-command "E")))
      (ignore-errors (transient-remove-suffix 'harness-menu "x"))
      (harness-ui-secrets--init))))

;;;; Against the engine

(defvar harness-ui-secrets-test--engine-modules
  '(store project config provider session secrets redact)
  "The modules of the harness's half that the round trip needs.")

(defmacro harness-ui-secrets-test-with-engine (&rest body)
  "Run BODY with the real engine, and the UI connected to it, in a fresh state."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m (append harness-ui-secrets-test--engine-modules '(acp)))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (let ((harness-acp-token nil)
           (default-directory dir))
       (dolist (m '(ui ui-chat ui-secrets))
         (harness-test-load-module m))
       (clrhash harness-ui--sessions)
       (unwind-protect (progn ,@body)
         (dolist (b (buffer-list))
           (when (memq (buffer-local-value 'major-mode b) '(harness-chat-mode))
             (ignore-errors (let ((kill-buffer-query-functions nil)) (kill-buffer b)))))
         (harness-ui-secrets-test--cleanup)
         (clrhash harness-ui--sessions)))))

(defun harness-ui-secrets-test--session (name &rest nodes)
  "Create a session called NAME with NODES appended; return its id."
  (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :name name) :id)))
    (dolist (n nodes) (harness-call 'session/append id n))
    id))

(defun harness-ui-secrets-test--stored-count ()
  "Return how many times the fake secrets occur in the bytes of the state directory."
  (cl-loop for file in (directory-files-recursively harness-state-directory "")
           sum (harness-redaction-file-count file (harness-ui-secrets-test--secrets))))

(ert-deftest harness-ui-secrets-round-trip-through-the-engine ()
  "The command finds, asks, redacts and cleans, against the real engine."
  (harness-ui-secrets-test-with-engine
    (let* ((file (harness-ui-secrets-test--state-file))
           (fp-key (harness-ui-secrets-test--fp harness-ui-secrets-test--key))
           (dirty (harness-ui-secrets-test--session
                   "step qr"
                   (list :kind 'user :content (format "diff shows %s" harness-ui-secrets-test--key))
                   (list :kind 'tool-result :call-id "c1"
                         :output (format "AccessKeyId: %s\nvalue: %s\n"
                                         harness-ui-secrets-test--id harness-ui-secrets-test--key))
                   '(:kind assistant :content "Noted.")))
           (clean (harness-ui-secrets-test--session "clean" '(:kind user :content "nothing here")))
           (asked nil))
      (harness-session-flush)
      (should (> (harness-ui-secrets-test--stored-count) 0))
      ;; The chat of the dirty session is open and shows the key.
      (harness-ui-refresh-sessions)
      (harness-test-wait (lambda () (harness-ui-session dirty)) 5 "the session list")
      (let ((chat (harness-chat-buffer dirty)))
        (harness-test-wait (lambda () (harness-ui-secrets-test--holds-p
                                       (harness-ui-secrets-test--text chat)))
                           5 "the chat to show the transcript")
        (harness-ui-secrets-test-collecting
          (harness-ui-secrets-test-asking
              (list (cons "Where is the secret?" "File and JSON path")
                    (cons "JSON file that holds the secret" file)
                    (cons "JSON path in state.json"
                          (lambda (_prompt table &rest _)
                            (cl-find-if (lambda (c) (string-suffix-p "keys.value" c))
                                        (all-completions "" table))))
                    (cons "Label for the placeholder" "")
                    (cons "Clean:" "All sessions")
                    (cons "Reason" "pasted in a diff")
                    (cons "Redact " (lambda (prompt) (push prompt asked) t)))
            (harness-redact-secret)
            (harness-test-wait
             (lambda () (and (get-buffer harness-ui-secrets-report-buffer-name)
                             (string-match-p "Done" (harness-ui-secrets-test--text
                                                     harness-ui-secrets-report-buffer-name))))
             30 "the redaction to finish"))
          ;; The scan counted before the question; the question names no value.
          (should (= 1 (length asked)))
          ;; The label is the one given with the path below it, with the fingerprints.
          (should (string-match-p
                   (format "keys\\.secret_key (sha256:%s)" (harness-ui-secrets-test--fp harness-ui-secrets-test--key))
                   (car asked)))
          (should (string-match-p
                   (format "keys\\.access_key (sha256:%s)" (harness-ui-secrets-test--fp harness-ui-secrets-test--id))
                   (car asked)))
          (should-not (harness-ui-secrets-test--holds-p (car asked)))
          ;; Every copy is gone: files, memory, the open chat, the report, the messages.
          (harness-session-flush)
          (should (= 0 (harness-ui-secrets-test--stored-count)))
          (dolist (n (harness-call 'session/nodes dirty))
            (should-not (harness-ui-secrets-test--holds-p (prin1-to-string n t))))
          (let ((report (harness-ui-secrets-test--text harness-ui-secrets-report-buffer-name)))
            (should-not (harness-ui-secrets-test--holds-p report))
            (should (string-search (format "sha256:%s" fp-key) report))
            (should (string-match-p (regexp-quote (substring dirty 0 8)) report)))
          (dolist (m (harness-ui-secrets-test--said))
            (should-not (harness-ui-secrets-test--holds-p m)))
          ;; The chat loaded the redacted transcript again, with the hint the engine wrote.
          (harness-test-wait
           (lambda () (and (not (harness-ui-secrets-test--holds-p (harness-ui-secrets-test--text chat)))
                           (string-search (format "sha256:%s" fp-key) (harness-ui-secrets-test--text chat))))
           10 "the chat to load the redacted transcript")
          ;; The record of the redaction is in the session, and the clean one is untouched.
          (should (plist-get (plist-get (harness-call 'session/get dirty) :ext) :redactions))
          (should-not (plist-get (plist-get (harness-call 'session/get clean) :ext) :redactions))
          ;; The log lists it for `harness-redactions'.
          (harness-redactions)
          (harness-test-wait
           (lambda () (string-search (format "sha256:%s" fp-key)
                                     (harness-ui-secrets-test--text "*harness redactions*")))
           10 "the list of redactions")
          (should-not (harness-ui-secrets-test--holds-p (harness-ui-secrets-test--text "*harness redactions*"))))))))

(ert-deftest harness-ui-secrets-round-trip-the-question-names-the-cache-a-reset-drops ()
  "Against the engine: the scan's report reaches the question, and the redaction drops the cache.
A session on a hosted loop that holds the secret and has a warm prompt
cache starts a new conversation, and the cache of the old one goes.  The
question says so before anything is changed, over the real connection; the
report afterwards names the session; the session reports the cache dropped."
  (harness-ui-secrets-test-with-engine
    (unwind-protect
        (let* ((file (harness-ui-secrets-test--state-file))
               (asked nil)
               (sid nil))
          (harness-define-provider
           'hosted
           :label "Hosted"
           :models (lambda ()
                     (harness-resolved (list (list :name "m" :label "M" :context-window 200000))))
           :complete (lambda (_request) (list :cancel #'ignore))
           :capabilities '(:hosted-loop t :resume t :fork t))
          (setq sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :name "hosted"
                                             :model "hosted:m")
                               :id))
          (harness-call 'session/append sid (list :kind 'user
                                                  :content (format "diff shows %s" harness-ui-secrets-test--key)))
          (harness-call 'session/set-provider-state sid (list :cli-session-id "cli-1"))
          (harness-call 'session/usage-add sid (list :input 10 :output 10 :cache-read 3000 :context 3020
                                                     :cache-at (- (float-time) 10)))
          (should-not (plist-get (plist-get (harness-call 'session/get sid) :cache) :dropped))
          (harness-ui-secrets-test-collecting
            (harness-ui-secrets-test-asking
                (list (cons "Redact " (lambda (prompt) (push prompt asked) t)))
              (harness-ui-secrets-redact
               (harness-ui-secrets--source (list :file file :json-path "outputs.keys.value"))
               "keys" '(:scope "all") nil)
              (harness-test-wait
               (lambda () (and (get-buffer harness-ui-secrets-report-buffer-name)
                               (string-match-p "Done" (harness-ui-secrets-test--text
                                                       harness-ui-secrets-report-buffer-name))))
               30 "the redaction to finish")))
          ;; The question, asked on the scan, names the cost.
          (should (= 1 (length asked)))
          (should (string-suffix-p "; 1 provider conversation starts over, dropping ~3.0k tokens of prompt cache? "
                                   (car asked)))
          (should-not (harness-ui-secrets-test--holds-p (car asked)))
          ;; The redaction did it: the conversation started over and the cache went.
          (should-not (plist-get (harness-call 'session/get sid) :provider-state))
          (should (numberp (plist-get (plist-get (harness-call 'session/get sid) :cache) :dropped)))
          (let ((report (harness-ui-secrets-test--text harness-ui-secrets-report-buffer-name)))
            (should (string-search
                     (format "The prompt cache of 1 session went with it: %s (~3.0k tokens)." (substring sid 0 8))
                     report))
            (should-not (harness-ui-secrets-test--holds-p report))))
      (remhash 'hosted harness-providers)
      (harness-provider--forget 'hosted))))

(ert-deftest harness-ui-secrets-round-trip-nothing-found ()
  "A secret no session holds is scanned and not asked about."
  (harness-ui-secrets-test-with-engine
    (let ((file (harness-ui-secrets-test--state-file)))
      (harness-ui-secrets-test--session "clean" '(:kind user :content "nothing here"))
      (harness-ui-secrets-test-collecting
        (harness-ui-secrets-test-asking
            (list (cons "Where is the secret?" "File and JSON path")
                  (cons "JSON file that holds the secret" file)
                  (cons "JSON path in state.json"
                        (lambda (_prompt table &rest _)
                          (cl-find-if (lambda (c) (string-suffix-p "keys.value" c))
                                      (all-completions "" table))))
                  (cons "Label for the placeholder" "")
                  (cons "Clean:" "All sessions")
                  (cons "Reason" ""))
          (harness-redact-secret)
          (harness-test-wait
           (lambda () (cl-some (lambda (m) (string-match-p "Nothing to redact" m))
                               (harness-ui-secrets-test--said)))
           30 "the scan to finish"))
        (should-not (harness-ui-secrets-test--asked 'yes-or-no-p))))))

(ert-deftest harness-ui-secrets-round-trip-failure-names-the-reference-not-the-value ()
  "A reference the engine cannot read ends with its message, which holds no value."
  (harness-ui-secrets-test-with-engine
    (let ((file (harness-ui-secrets-test--state-file)))
      (harness-ui-secrets-test-collecting
        (harness-ui-secrets-redact
         (harness-ui-secrets--source (list :file file :json-path "outputs.nope.value"))
         "nope" '(:scope "all") nil)
        (harness-test-wait
         (lambda () (cl-some (lambda (m) (string-match-p "scan failed" m))
                             (harness-ui-secrets-test--said)))
         30 "the scan to fail")
        (dolist (m (harness-ui-secrets-test--said))
          (should-not (harness-ui-secrets-test--holds-p m)))))))

(provide 'harness-ui-secrets-test)
;;; harness-ui-secrets-test.el ends here
