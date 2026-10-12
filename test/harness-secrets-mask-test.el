;;; harness-secrets-mask-test.el --- Tests for masking secrets in tool output  -*- lexical-binding: t; -*-

;;; Commentary:

;; Tool output must not record a secret.  These tests run tools through
;; `tools/execute' (the real bash and write_file tools among them), the
;; agent's turn loop, the harness log and the guard against writing
;; placeholders, and check the secret is gone from every place the text
;; goes: the result, its meta, the file an oversized result is saved
;; to, the progress and note lines, the node log, what the provider is
;; sent.
;;
;; Every secret here is a fake one made when the test runs, and so is
;; every token-shaped string: a prefix and a run of one character put
;; together, so that no file of the repository holds a string that looks
;; like a real token.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-redaction)

(defvar harness-secrets-mask)
(defvar harness-secrets-sources)
(defvar harness-secrets-detectors)
(defvar harness-secrets-extra-detectors)
(defvar harness-secrets--refresh-interval)
(defvar harness-secrets--checked)
(defvar harness-secrets--entries)
(defvar harness-tools-max-output-chars)
(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent--turns)
(defvar harness-log-filter-function)
(declare-function harness-secrets-forget "harness-secrets")
(declare-function harness-secrets-mask-text "harness-secrets")
(declare-function harness-secrets--prime "harness-secrets")
(declare-function harness-secrets--install "harness-secrets")
(declare-function harness-secrets--filter-output "harness-secrets")
(declare-function harness-agent--record-builtin-result "harness-agent")
(declare-function harness-define-provider "harness-provider")
(declare-function harness-define-tool "harness-tools")
(declare-function harness-tool-get "harness-tools")
(declare-function harness-tool-ok "harness-tools")
(declare-function harness-session-flush "harness-session")
(declare-function harness-secrets--filter-log "harness-secrets")
(declare-function harness-secrets--write-guard "harness-secrets")

;;;; Setup

(defun harness-secrets-mask-test--allow (_decision next &rest _)
  "Permission stage that allows every call that reaches it.
NEXT continues the chain."
  (funcall next (list :behavior 'allow)))

(defun harness-secrets-mask-test--load ()
  "Load the modules the tests need on a fresh bus.
They are compiled in the state directory of the whole run, not in each
test's, so loading them again costs little."
  (harness-test-reset-bus)
  (dolist (m '(store tools tools-fs tools-shell secrets))
    (harness-test-load-module m))
  (cancel-function-timers #'harness-secrets--prime)
  (harness-add-filter 'permission/decide #'harness-secrets-mask-test--allow 10)
  (unless (harness-tool-get "mask_echo")
    (harness-define-tool "mask_echo" :label "Echo" :description "Return the text." :kind 'read
                         :handler (lambda (input _ctx) (harness-tool-ok (plist-get input :text))))
    (harness-define-tool "mask_write" :label "Write" :description "Pretend to write." :kind 'write
                         :handler (lambda (input _ctx) (harness-tool-ok (format "wrote %s" (plist-get input :text)))))
    (harness-define-tool "mask_report" :label "Report" :description "Report progress and a note." :kind 'read
                         :handler (lambda (input ctx)
                                    (funcall (plist-get ctx :report) (plist-get input :text))
                                    (funcall (plist-get ctx :note) (plist-get input :text))
                                    (harness-tool-ok "done")))))

(defvar harness-secrets-mask-test--dir nil
  "The directory the test writes its files to, which is its state directory.")

(defun harness-secrets-mask-test--clear-log ()
  "Empty the harness log, so that a test sees only the lines it caused."
  (with-current-buffer (get-buffer-create harness-log-buffer-name)
    (let ((inhibit-read-only t)) (erase-buffer))))

(defmacro harness-secrets-mask-test-with (&rest body)
  "Run BODY with masking on, no sources and the default detectors.
`dir' is a fresh state directory."
  (declare (indent 0))
  `(progn
     (harness-secrets-mask-test--load)
     (harness-test-with-temp-state
       (harness-secrets-forget)
       (harness-secrets-mask-test--clear-log)
       (let ((harness-secrets-mask t)
             (harness-secrets-sources nil)
             (harness-secrets-detectors 'default)
             (harness-secrets-extra-detectors nil)
             (harness-secrets--refresh-interval 5)
             (harness-log-level 'info)
             (harness-secrets-mask-test--dir dir)
             (default-directory dir))
         (unwind-protect (progn ,@body)
           (harness-secrets-forget))))))

(defun harness-secrets-mask-test--fake (&optional prefix)
  "Return a fake secret, a new one each time, starting with PREFIX (FAKE).
It holds letters, digits, a slash and a plus."
  (concat (or prefix "FAKE") "/"
          (substring (md5 (format "%s %s %s" (random) (float-time) (emacs-pid))) 0 24)
          "+Zz9"))

(defun harness-secrets-mask-test--json-file (name json)
  "Write the object JSON, a plist, as file NAME of the test's directory.
Return its path.  Writing the same NAME again changes the file."
  (let ((file (expand-file-name name harness-secrets-mask-test--dir)))
    (with-temp-file file (insert (harness-json-encode-text json)))
    file))

(defun harness-secrets-mask-test--key-file (secret &optional other)
  "Write a JSON file with SECRET at outputs.keys.value.secret; return its path.
OTHER is the access key id beside it."
  (harness-secrets-mask-test--json-file
   "keys.json"
   (list :outputs (list :keys (list :value (list :id (or other "id-0001") :secret secret))))))

(defun harness-secrets-mask-test--source (file &optional label)
  "Return the reference to the secret in FILE (see `--key-file'), labelled LABEL."
  (append (list :file file :json-path "outputs.keys.value.secret")
          (and label (list :label label))))

(defun harness-secrets-mask-test--placeholder (value label)
  "Return the placeholder that stands for VALUE, labelled LABEL."
  (harness-redaction-placeholder (harness-redaction-secret value label)))

(defun harness-secrets-mask-test--call (name &rest input)
  "Execute tool NAME with INPUT through `tools/execute', wait, return the result."
  (harness-await (harness-call 'tools/execute nil (list :id "c1" :name name :input input)) 20))

(defun harness-secrets-mask-test--hits (text)
  "Return the (LABEL . COUNT) of what masking TEXT hit, in order."
  (mapcar (lambda (h) (cons (plist-get h :label) (plist-get h :count)))
          (cdr (harness-secrets-mask-text text))))

(defun harness-secrets-mask-test--file-text (file)
  "Return the contents of FILE."
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

;;;; A registered value in a tool's output

(ert-deftest harness-secrets-mask-registered-value-in-a-tool-result ()
  "A value named by a file and a JSON path is masked in what a tool returns.
The result says so in its meta, with the fingerprint and no value."
  (harness-secrets-mask-test-with
    (let* ((secret (harness-secrets-mask-test--fake))
           (file (harness-secrets-mask-test--key-file secret))
           (harness-secrets-sources (list (harness-secrets-mask-test--source file "spaces-secret")))
           (fingerprint (harness-redaction-fingerprint secret))
           (events nil))
      (harness-on 'tools/finished (lambda (_sid _call result) (push result events)))
      (let ((result (harness-secrets-mask-test--call "mask_echo" :text (format "key=%s;" secret))))
        (should (equal (format "key=[redacted: spaces-secret sha256:%s];" fingerprint)
                       (plist-get result :content)))
        (should-not (string-search secret (format "%S" result)))
        (should (equal (list (list :label "spaces-secret" :fingerprint fingerprint :count 1))
                       (plist-get (plist-get result :meta) :masked)))
        ;; What the event announced is the masked result too.
        (should (equal (plist-get result :content) (plist-get (car events) :content)))))))

(ert-deftest harness-secrets-mask-unmasked-result-has-no-masked-meta ()
  "A result with nothing to mask is returned as it was."
  (harness-secrets-mask-test-with
    (let* ((secret (harness-secrets-mask-test--fake))
           (harness-secrets-sources (list (harness-secrets-mask-test--source
                                           (harness-secrets-mask-test--key-file secret)))))
      (let ((result (harness-secrets-mask-test--call "mask_echo" :text "nothing to hide here")))
        (should (equal "nothing to hide here" (plist-get result :content)))
        (should-not (plist-member (plist-get result :meta) :masked))))))

(ert-deftest harness-secrets-mask-oversized-result-spill-file-is-masked ()
  "The file an oversized result is saved to holds no secret either."
  (harness-secrets-mask-test-with
    (let* ((secret (harness-secrets-mask-test--fake))
           (file (harness-secrets-mask-test--key-file secret))
           (harness-secrets-sources (list (harness-secrets-mask-test--source file "spaces-secret")))
           (harness-tools-max-output-chars 200)
           (text (concat (make-string 500 ?x) "\nthe key: " secret "\n" (make-string 500 ?y))))
      (let* ((result (harness-secrets-mask-test--call "mask_echo" :text text))
             (path (plist-get (plist-get result :truncated) :path)))
        (should path)
        (should (file-in-directory-p path (expand-file-name "outputs" dir)))
        (let ((saved (harness-secrets-mask-test--file-text path)))
          (should-not (string-search secret saved))
          (should (string-search (harness-secrets-mask-test--placeholder secret "spaces-secret") saved))
          ;; The text shown is the head of the masked output.
          (should-not (string-search secret (plist-get result :content))))))))

(ert-deftest harness-secrets-mask-bash-output-is-masked-before-it-is-recorded ()
  "The real bash tool echoing a registered value returns a masked result."
  (harness-secrets-mask-test-with
    (let* ((secret (harness-secrets-mask-test--fake))
           (file (harness-secrets-mask-test--key-file secret))
           (harness-secrets-sources (list (harness-secrets-mask-test--source file "spaces-secret")))
           (chunks nil))
      (harness-on 'tools/progress (lambda (_sid _cid text) (push text chunks)))
      (let ((result (harness-secrets-mask-test--call
                     "bash" :command (format "echo %s; cat %s" (shell-quote-argument secret)
                                             (shell-quote-argument file)))))
        (should-not (plist-get result :is-error))
        (should-not (string-search secret (plist-get result :content)))
        (should (string-search (harness-secrets-mask-test--placeholder secret "spaces-secret")
                               (plist-get result :content)))
        (should (string-suffix-p "exit 0" (plist-get result :content)))
        ;; Both the echo and the JSON of the file: the value is the same.
        (should (= 2 (plist-get (car (plist-get (plist-get result :meta) :masked)) :count))))
      ;; The progress the command reported was masked as it came.
      (should chunks)
      (should-not (string-search secret (apply #'concat chunks)))
      (should (string-search "[redacted: spaces-secret" (apply #'concat chunks))))))

(ert-deftest harness-secrets-mask-progress-and-notes-are-masked ()
  "What a tool reports as progress or as a note is masked before it is announced."
  (harness-secrets-mask-test-with
    (let* ((secret (harness-secrets-mask-test--fake))
           (file (harness-secrets-mask-test--key-file secret))
           (harness-secrets-sources (list (harness-secrets-mask-test--source file "spaces-secret")))
           (progress nil) (notes nil))
      (harness-on 'tools/progress (lambda (_sid _cid text) (push text progress)))
      (harness-on 'tools/note (lambda (_sid _cid text) (push text notes)))
      (harness-secrets-mask-test--call "mask_report" :text (format "reading %s now" secret))
      (let ((placeholder (harness-secrets-mask-test--placeholder secret "spaces-secret")))
        (should (equal (list (format "reading %s now" placeholder)) progress))
        (should (equal (list (format "reading %s now" placeholder)) notes))))))

(ert-deftest harness-secrets-mask-json-escaped-value-is-masked ()
  "A value that JSON writes with escapes is found as written, and the JSON stays valid."
  (harness-secrets-mask-test-with
    (let* ((secret (concat "FAKE\"quoted\\back/slash\nline-" (substring (md5 (format "%s" (random))) 0 16)))
           (file (harness-secrets-mask-test--key-file secret))
           (harness-secrets-sources (list (harness-secrets-mask-test--source file "multi")))
           (json (harness-json-encode-text (list :k secret :other "kept")))
           (result (harness-secrets-mask-test--call "mask_echo" :text json))
           (content (plist-get result :content)))
      ;; The raw value does not appear, nor the text JSON wrote for it.
      (should-not (string-search secret content))
      (should-not (string-search (substring (harness-json-encode-text secret) 1 -1) content))
      (should (string-search "[redacted: multi" content))
      ;; Still a JSON document, with the placeholder in the value's place.
      (let ((parsed (json-parse-string content :object-type 'plist)))
        (should (string-prefix-p "[redacted: multi sha256:" (plist-get parsed :k)))
        (should (equal "kept" (plist-get parsed :other)))))))

(ert-deftest harness-secrets-mask-hits-count-each-value ()
  "Two secrets and a repeat are three hits of two entries, in order of first sight."
  (harness-secrets-mask-test-with
    (let* ((a (harness-secrets-mask-test--fake "AAA"))
           (b (harness-secrets-mask-test--fake "BBB"))
           (harness-secrets-sources (list (list :literal a :label "first") (list :literal b :label "second"))))
      (let ((masked (harness-secrets-mask-text (format "%s %s %s" b a b))))
        (should (equal '(("second" . 2) ("first" . 1))
                       (mapcar (lambda (h) (cons (plist-get h :label) (plist-get h :count))) (cdr masked))))
        (should-not (string-search a (car masked)))
        (should-not (string-search b (car masked)))))))

(ert-deftest harness-secrets-mask-leaves-clean-text-alone ()
  "Text with nothing to mask is returned as it is, the same object."
  (harness-secrets-mask-test-with
    (let ((harness-secrets-sources (list (list :literal (harness-secrets-mask-test--fake) :label "x")))
          (text (copy-sequence "an ordinary sentence with no secret")))
      (should (eq text (car (harness-secrets-mask-text text))))
      (should-not (cdr (harness-secrets-mask-text text)))
      (should (equal '(nil) (list (car (harness-secrets-mask-text nil)))))
      (should (equal "" (car (harness-secrets-mask-text "")))))))

(ert-deftest harness-secrets-mask-off-leaves-output-alone ()
  "With masking off, a result, a log line and a write go through untouched."
  (harness-secrets-mask-test-with
    (let* ((secret (harness-secrets-mask-test--fake))
           (file (harness-secrets-mask-test--key-file secret))
           (harness-secrets-sources (list (harness-secrets-mask-test--source file "spaces-secret")))
           (harness-secrets-mask nil)
           (path (expand-file-name "out.txt" dir))
           (placeholder "[redacted: x sha256:12345678]"))
      (let ((result (harness-secrets-mask-test--call "mask_echo" :text (format "key=%s" secret))))
        (should (equal (format "key=%s" secret) (plist-get result :content)))
        (should-not (plist-member (plist-get result :meta) :masked)))
      (harness-log 'info "the key is %s" secret)
      (should (string-search secret (with-current-buffer harness-log-buffer-name (buffer-string))))
      ;; The guard against writing a placeholder is off with it.
      (should-not (plist-get (harness-secrets-mask-test--call "write_file" :path path :content placeholder)
                             :is-error))
      (should (equal placeholder (harness-secrets-mask-test--file-text path))))))

;;;; The harness log

(ert-deftest harness-secrets-mask-log-is-masked ()
  "A secret in a log line is masked in the log buffer and in what the log hook gets."
  (harness-secrets-mask-test-with
    (let* ((secret (harness-secrets-mask-test--fake))
           (token (concat "dop_v1_" (make-string 64 ?a)))
           (harness-secrets-sources (list (list :literal secret :label "logged")))
           (hooked nil))
      (let ((harness-log-hook (list (lambda (_level msg) (push msg hooked)))))
        (harness-log 'warn "failed with %s and %s" secret token))
      (let ((logged (with-current-buffer harness-log-buffer-name (buffer-string))))
        (should-not (string-search secret logged))
        (should-not (string-search token logged))
        (should (string-search (harness-secrets-mask-test--placeholder secret "logged") logged))
        (should (string-search "[redacted: digitalocean-token" logged)))
      (should (= 1 (length hooked)))
      (should-not (string-search secret (car hooked)))
      (should-not (string-search token (car hooked))))))

(ert-deftest harness-secrets-mask-installs-once ()
  "Installing again, as a reload does, adds no second filter and keeps the log filter."
  (harness-secrets-mask-test-with
    (dotimes (_ 3) (harness-secrets--install))
    (dolist (name '(tools/output tools/output-text))
      (should (= 1 (length (gethash name harness--filters)))))
    (should (= 1 (cl-count #'harness-secrets--write-guard (gethash 'permission/decide harness--filters)
                           :key #'cdr)))
    (should (eq #'harness-secrets--filter-log harness-log-filter-function))))

;;;; The detectors

(defconst harness-secrets-mask-test--hex64 (make-string 64 ?0)
  "Stands for the 64 hex digits of a DigitalOcean token.")

(defun harness-secrets-mask-test--samples ()
  "Return (DETECTOR SECRET) pairs: text each detector must mask, made now."
  (let ((key16 (concat (make-string 8 ?A) (make-string 8 ?7)))
        (pem-body (concat (make-string 64 ?Q) "\n" (make-string 64 ?R) "\n" (make-string 20 ?S))))
    (append
     (mapcar (lambda (prefix) (list 'digitalocean-token (concat prefix "_v1_" harness-secrets-mask-test--hex64)))
             '("dop" "doo" "dor"))
     (mapcar (lambda (prefix) (list 'aws-access-key-id (concat prefix key16)))
             '("AKIA" "ASIA" "ABIA" "ACCA"))
     (list (list 'spaces-access-key-id (concat "DO00" (make-string 16 ?A)))
           (list 'spaces-access-key-id (concat "DO" (make-string 9 ?B) "42" (make-string 7 ?C))))
     (mapcar (lambda (kind) (list 'github-token (concat "gh" kind "_" (make-string 36 ?a))))
             '("p" "o" "u" "s" "r"))
     (list (list 'github-token (concat "github_pat_" (make-string 11 ?a) "_" (make-string 11 ?b)))
           (list 'anthropic-key (concat "sk-ant-api03-" (make-string 24 ?a)))
           (list 'openai-key (concat "sk-proj-" (make-string 20 ?a)))
           (list 'openai-key (concat "sk-svcacct-" (make-string 20 ?a)))
           (list 'openai-key (concat "sk-admin-" (make-string 20 ?a)))
           (list 'slack-token (concat "xoxb-" (make-string 10 ?1) "-" (make-string 10 ?2)))
           (list 'google-api-key (concat "AIza" (make-string 35 ?a)))
           (list 'stripe-key (concat "sk_live_" (make-string 24 ?a)))
           (list 'stripe-key (concat "rk_live_" (make-string 16 ?a)))
           (list 'private-key (concat "-----BEGIN RSA PRIVATE KEY-----\n" pem-body "\n-----END RSA PRIVATE KEY-----"))
           (list 'private-key (concat "-----BEGIN PRIVATE KEY-----\n" pem-body "\n-----END PRIVATE KEY-----"))
           (list 'private-key (concat "-----BEGIN OPENSSH PRIVATE KEY-----\n" pem-body "\n-----END OPENSSH PRIVATE KEY-----"))
           (list 'private-key (concat "-----BEGIN ENCRYPTED PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\n\n" pem-body
                                      "\n-----END ENCRYPTED PRIVATE KEY-----"))
           ;; As JSON writes a key: the lines joined by backslash-n.
           (list 'private-key (concat "-----BEGIN EC PRIVATE KEY-----\\n" (make-string 40 ?Q) "\\n-----END EC PRIVATE KEY-----"))))))

(ert-deftest harness-secrets-mask-detectors-mask-their-formats ()
  "Each built-in detector masks the token it is for, and only that, with its name."
  (harness-secrets-mask-test-with
    (dolist (sample (harness-secrets-mask-test--samples))
      (let* ((name (symbol-name (car sample)))
             (secret (cadr sample))
             (text (format "before %s after" secret))
             (masked (harness-secrets-mask-text text))
             (fingerprint (harness-redaction-fingerprint secret)))
        (ert-info ((format "%s: %d chars" name (length secret)))
          (should (equal (format "before [redacted: %s sha256:%s] after" name fingerprint) (car masked)))
          (should (equal (list (list :label name :fingerprint fingerprint :count 1)) (cdr masked))))))))

(ert-deftest harness-secrets-mask-detectors-leave_near-misses-alone ()
  "A string that is not quite a token is not masked."
  (harness-secrets-mask-test-with
    (let ((key16 (concat (make-string 8 ?A) (make-string 8 ?7))))
      (dolist (text (list (concat "dop_v1_" (make-string 63 ?0))       ; one digit short
                          (concat "dap_v1_" harness-secrets-mask-test--hex64) ; another prefix
                          (concat "dop_v1_" (make-string 64 ?G))      ; not hex
                          (concat "AKIA" (make-string 15 ?A))         ; short
                          (concat "AKIA" (make-string 17 ?A))         ; long: part of another word
                          (concat "xAKIA" key16)                      ; inside a word
                          (concat "AKIA" key16 "x")
                          (concat "AKIA" (downcase key16))            ; lower case
                          (concat "DO" (make-string 18 ?A))           ; no digit
                          (concat "DO0" (make-string 17 ?A))          ; one digit
                          (concat "DO00" (make-string 17 ?A))         ; one too many
                          (concat "ADO00" (make-string 16 ?A))
                          (concat "ghp_" (make-string 35 ?a))
                          (concat "ghx_" (make-string 36 ?a))
                          (concat "github_pat_" (make-string 21 ?a))
                          (concat "sk-ant-" (make-string 19 ?a))
                          (concat "sk-proj-" (make-string 19 ?a))
                          (concat "sk-other-" (make-string 30 ?a))
                          (concat "xoxz-" (make-string 12 ?1))
                          (concat "xoxb-" (make-string 9 ?1))
                          (concat "AIza" (make-string 34 ?a))
                          (concat "sk_test_" (make-string 24 ?a))
                          (concat "sk_live_" (make-string 15 ?a))
                          ;; Only the header of a key: nothing of it to hide.
                          "-----BEGIN RSA PRIVATE KEY-----"
                          "-----BEGIN PUBLIC KEY-----\nMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8A\n-----END PUBLIC KEY-----"
                          "a README line about AKIA keys and dop_v1_ tokens"))
        (ert-info ((format "%S" (truncate-string-to-width text 40)))
          (should (eq text (car (harness-secrets-mask-text text)))))))))

(ert-deftest harness-secrets-mask-private-key-block ()
  "A PEM block is masked whole, wherever its lines are, and the text around it stays."
  (harness-secrets-mask-test-with
    (let* ((body (concat (make-string 64 ?Q) "\n" (make-string 64 ?R)))
           (key (concat "-----BEGIN RSA PRIVATE KEY-----\n" body "\n-----END RSA PRIVATE KEY-----"))
           (text (format "first\n%s\nbetween\n%s\nlast" key key))
           (masked (harness-secrets-mask-text text)))
      (should (equal (format "first\n[redacted: private-key sha256:%s]\nbetween\n[redacted: private-key sha256:%s]\nlast"
                             (harness-redaction-fingerprint key) (harness-redaction-fingerprint key))
                     (car masked)))
      (should (equal '(("private-key" . 2)) (harness-secrets-mask-test--hits text))))
    ;; Cut short before its END line: the key lines that follow are masked, the rest is not.
    (let* ((text (concat "-----BEGIN RSA PRIVATE KEY-----\n" (make-string 64 ?Q) "\n" (make-string 64 ?R)
                         "\nand then the output goes on: done\n"))
           (masked (car (harness-secrets-mask-text text))))
      (should-not (string-search (make-string 64 ?Q) masked))
      (should-not (string-search (make-string 64 ?R) masked))
      (should (string-search "[redacted: private-key" masked))
      (should (string-suffix-p "\nand then the output goes on: done\n" masked)))
    ;; A key in a JSON string: the backslash-n joins its lines.
    (let* ((json (harness-json-encode-text
                  (list :private_key (concat "-----BEGIN PRIVATE KEY-----\n" (make-string 64 ?Q)
                                             "\n-----END PRIVATE KEY-----\n"))))
           (masked (car (harness-secrets-mask-text json))))
      (should-not (string-search (make-string 64 ?Q) masked))
      (should (json-parse-string masked)))))

(ert-deftest harness-secrets-mask-secret-assignment ()
  "A value of 16 or more characters assigned to a secret-looking name is masked, only the value."
  (harness-secrets-mask-test-with
    (let ((value (concat "Ab1" (make-string 20 ?x))))
      (dolist (template '("secret_key: %s" "secret_key=%s" "SECRET_KEY = '%s'" "{\"secret_key\": \"%s\"}"
                          "export AWS_SECRET_ACCESS_KEY=%s" "api_key: \"%s\"" "apikey=%s" "API-KEY: %s"
                          "X-Api-Key: %s" "client_secret=%s" "clientSecret: %s" "password = \"%s\""
                          "passwd=%s" "token: %s" "\"access_token\":\"%s\"" "refresh_token=%s"
                          "auth_token => '%s'" "private_key: %s" "?token=%s&x=1" "secret: %s"
                          ;; JSON inside a JSON string: the quotes carry backslashes.
                          "{\\\"api_key\\\": \\\"%s\\\"}"))
        (let* ((text (format template value))
               (masked (car (harness-secrets-mask-text text)))
               (placeholder (harness-secrets-mask-test--placeholder value "secret-assignment")))
          (ert-info (template)
            (should-not (string-search value masked))
            (should (equal (format template placeholder) masked))))))
    ;; Base64 padding belongs to the value.
    (let ((text (concat "secret: Ab1" (make-string 20 ?x) "==")))
      (should (string-match-p "\\`secret: \\[redacted: secret-assignment sha256:[0-9a-f]\\{8\\}\\]\\'"
                              (car (harness-secrets-mask-text text)))))))

(ert-deftest harness-secrets-mask-secret-assignment-leaves-plain-values-alone ()
  "Short values, plain words, variables and templates are not secrets."
  (harness-secrets-mask-test-with
    (dolist (text (list "password: hunter2"                               ; short
                        "password: hunter2hunter2"                        ; 15 characters
                        "token: abcdefghijklmnopqrstuvwxyz"               ; no digit
                        "token: 12345678901234567890"                     ; no letter
                        "token: $SOME_TOKEN_VARIABLE_1234"                ; a variable
                        "token: <your-token-1234567890abcd>"              ; a placeholder for the user
                        "token: {{ vault.token1234567890 }}"              ; a template
                        "api_key = os.environ[\"API_KEY_1234567890abc\"]" ; a lookup
                        "max_tokens: 4096"
                        "tokenizer: abcdefghijklmnop1234"                 ; another name
                        "secret_name: abcdefghijklmnop1234"
                        "password_hash=abcdefghijklmnop1234"
                        "the token abcdefghijklmnop1234 is mentioned"     ; no separator
                        "token==="
                        (make-string 2000 ?=)
                        (concat "token:" (make-string 40 ?\s) "x")))
      (ert-info ((format "%S" (truncate-string-to-width text 40)))
        (should (eq text (car (harness-secrets-mask-text text))))))))

(ert-deftest harness-secrets-mask-jwt-is-off-by-default ()
  "A JWT is masked only when its detector is asked for."
  (harness-secrets-mask-test-with
    (let ((jwt (concat "eyJ" (make-string 20 ?a) ".eyJ" (make-string 20 ?b) "." (make-string 20 ?c))))
      (should (eq jwt (car (harness-secrets-mask-text jwt))))
      (let ((harness-secrets-detectors t))
        (should (equal '(("jwt" . 1)) (harness-secrets-mask-test--hits jwt))))
      (let ((harness-secrets-detectors '(jwt)))
        (should (equal '(("jwt" . 1)) (harness-secrets-mask-test--hits jwt)))))))

(ert-deftest harness-secrets-mask-detector-choice ()
  "The setting picks the detectors: a list of names, none, all."
  (harness-secrets-mask-test-with
    (let* ((do (concat "dop_v1_" harness-secrets-mask-test--hex64))
           (gh (concat "ghp_" (make-string 36 ?a)))
           (text (format "%s %s" do gh)))
      (let ((harness-secrets-detectors '(github-token)))
        (should (equal '(("github-token" . 1)) (harness-secrets-mask-test--hits text)))
        (should (string-search do (car (harness-secrets-mask-text text)))))
      (let ((harness-secrets-detectors nil))
        (should (eq text (car (harness-secrets-mask-text text)))))
      (let ((harness-secrets-detectors 'default))
        (should (equal '(("digitalocean-token" . 1) ("github-token" . 1))
                       (harness-secrets-mask-test--hits text)))))))

(ert-deftest harness-secrets-mask-extra-detectors ()
  "Patterns of your own mask what they match, the whole match or a group, whatever the setting."
  (harness-secrets-mask-test-with
    (let ((harness-secrets-detectors nil)
          (harness-secrets-extra-detectors
           '(("internal" "corp_[0-9]\\{6\\}")
             ("kv" "id=\\([a-z]+\\)&" 1)
             ("broken" "\\(")
             ("also-broken"))))
      (should (equal "a [redacted: internal sha256:" (substring (car (harness-secrets-mask-text "a corp_123456 b")) 0 29)))
      (let ((masked (car (harness-secrets-mask-text "id=abcdef&rest"))))
        (should (string-match-p "\\`id=\\[redacted: kv sha256:[0-9a-f]\\{8\\}\\]&rest\\'" masked)))
      ;; The broken pattern is skipped, once logged, and the others still work.
      (should (equal '(("internal" . 1)) (harness-secrets-mask-test--hits "corp_654321")))
      (should (= 1 (with-current-buffer harness-log-buffer-name
                     (let ((n 0))
                       (goto-char (point-min))
                       (while (re-search-forward "the broken detector failed" nil t) (cl-incf n))
                       n)))))))

(ert-deftest harness-secrets-mask-placeholders-are-never-masked-again ()
  "Nothing is masked inside a placeholder, so masking text twice changes nothing."
  (harness-secrets-mask-test-with
    (let* ((secret (harness-secrets-mask-test--fake))
           (harness-secrets-sources (list (list :literal secret :label "mine")))
           (token (concat "AKIA" (make-string 8 ?A) (make-string 8 ?7)))
           (text (format "keep [redacted: db sha256:12345678] and [redacted: %s sha256:12345678] and [redacted: %s sha256:12345678]"
                         token secret)))
      ;; A label that holds a token, or the very secret, is left as it is.
      (should (eq text (car (harness-secrets-mask-text text))))
      (let* ((once (harness-secrets-mask-text (format "%s and %s and %s" secret token secret)))
             (twice (harness-secrets-mask-text (car once))))
        (should (eq (car once) (car twice)))
        (should-not (cdr twice))))))

(ert-deftest harness-secrets-mask-leaves-no-part-of-a-secret-beside-a-placeholder ()
  "A secret that holds a placeholder, or a registered value, is masked in its other parts."
  (harness-secrets-mask-test-with
    (let* ((q (make-string 64 ?Q))
           (r (make-string 64 ?R))
           (placeholder "[redacted: part sha256:12345678]")
           (text (format "-----BEGIN RSA PRIVATE KEY-----\n%s\n%s\n%s\n-----END RSA PRIVATE KEY-----\n"
                         q placeholder r))
           (masked (car (harness-secrets-mask-text text))))
      ;; The placeholder stays where it was; the key lines around it do not.
      (should-not (string-search q masked))
      (should-not (string-search r masked))
      (should (string-search placeholder masked))
      ;; Two pieces of the key, each with a fingerprint of its own.
      (should (equal '(("private-key" . 1) ("private-key" . 1)) (harness-secrets-mask-test--hits text)))
      (should (string-suffix-p "\n" masked)))
    ;; A line of the key is a registered value: it is masked as that, and the rest as the key.
    (let* ((q (make-string 64 ?Q))
           (r (make-string 64 ?R))
           (harness-secrets-sources (list (list :literal r :label "line")))
           (text (format "-----BEGIN RSA PRIVATE KEY-----\n%s\n%s\n-----END RSA PRIVATE KEY-----" q r))
           (masked (car (harness-secrets-mask-text text))))
      (should-not (string-search q masked))
      (should-not (string-search r masked))
      (should (string-search (harness-secrets-mask-test--placeholder r "line") masked))
      (should (equal '(("private-key" . 1) ("line" . 1) ("private-key" . 1))
                     (harness-secrets-mask-test--hits text))))))

(ert-deftest harness-secrets-mask-glued-secrets-are-all-masked ()
  "Masking one secret does not leave the one glued to it, and masking twice is masking once."
  (harness-secrets-mask-test-with
    (let* ((spaces (concat "DO00" (make-string 16 ?D)))
           (anthropic (concat "sk-ant-" (make-string 30 ?c)))
           (text (concat "=" spaces anthropic "x")))
      ;; The key id is no word of its own until the token beside it is gone.
      (let ((masked (harness-secrets-mask-text text)))
        (should-not (string-search spaces (car masked)))
        (should-not (string-search anthropic (car masked)))
        (should (equal '(("anthropic-key" . 1) ("spaces-access-key-id" . 1))
                       (sort (mapcar (lambda (h) (cons (plist-get h :label) (plist-get h :count))) (cdr masked))
                             (lambda (a b) (string< (car a) (car b))))))
        (should (equal (car masked) (car (harness-secrets-mask-text (car masked)))))))))

(ert-deftest harness-secrets-mask-random-text-never-leaks-and-is-stable ()
  "Random text made of secrets, placeholders and punctuation is masked whole and only once."
  (harness-secrets-mask-test-with
    (random "harness-secrets-mask-test")
    (let* ((registered (list (harness-secrets-mask-test--fake "REG") (harness-secrets-mask-test--fake "REGTWO")))
           (harness-secrets-sources (list (list :literal (car registered) :label "one")
                                          (list :literal (cadr registered) :label "two")))
           (harness-secrets-detectors t)
           (pem-line (make-string 64 ?Q))
           ;; Whatever stands next to it, each of these is found.  (A key id such as
           ;; AKIA... is a word of its own only where letters and digits do not
           ;; touch it, so it is left out of what must never remain.)
           (secrets (append registered
                            (list (concat "dop_v1_" (make-string 64 ?a)) (concat "ghp_" (make-string 36 ?b))
                                  (concat "sk-ant-" (make-string 30 ?c)))))
           (pieces (append
                    (list (concat "-----BEGIN RSA PRIVATE KEY-----\n" pem-line "\n-----END RSA PRIVATE KEY-----")
                          (concat "\"password\": \"Pw1" (make-string 20 ?p) "\"")
                          "[redacted: some-label sha256:0123abcd]" "[redacted: " (json-serialize (vector (car registered)))
                          (concat "AKIA" (make-string 16 ?A)) (concat "DO00" (make-string 16 ?D)))
                    secrets
                    '("hello" " " "\n" "=" ":" "\"" "'" "token" "secret" "-----BEGIN " "DO" "AKIA" "ghp_" "sk-ant-"
                      "\\" "/" "+" "_" "-" "\t" "é")))
           (all (length pieces)))
      (dotimes (_ 400)
        (let ((text (apply #'concat (cl-loop repeat (1+ (random 12)) collect (nth (random all) pieces)))))
          (let* ((once (car (harness-secrets-mask-text text)))
                 (twice (car (harness-secrets-mask-text once))))
            (ert-info (text)
              (dolist (secret secrets)
                (should-not (string-search secret once)))
              (should (equal once twice)))))))))

(ert-deftest harness-secrets-mask-registry-comes-before-detectors ()
  "A value both the registry and a detector find is labelled by its source."
  (harness-secrets-mask-test-with
    (let* ((value (concat "Ab1" (make-string 20 ?x)))
           (harness-secrets-sources (list (list :literal value :label "mine"))))
      (should (equal '(("mine" . 1)) (harness-secrets-mask-test--hits (format "api_key=%s" value))))
      (should (equal (format "api_key=%s" (harness-secrets-mask-test--placeholder value "mine"))
                     (car (harness-secrets-mask-text (format "api_key=%s" value))))))))

;;;; The guard against writing a placeholder

(ert-deftest harness-secrets-mask-guard-refuses-writes-of-a-placeholder ()
  "A write whose input holds a placeholder is refused, and nothing is written."
  (harness-secrets-mask-test-with
    (let* ((placeholder "[redacted: spaces-secret sha256:0123abcd]")
           (path (expand-file-name "config.txt" dir))
           (result (harness-secrets-mask-test--call "write_file" :path path
                                                    :content (format "secret = %s\n" placeholder))))
      (should (plist-get result :is-error))
      (should (plist-get result :denied))
      (should (string-prefix-p "Denied: " (plist-get result :content)))
      (should (string-search "placeholder" (plist-get result :content)))
      (should-not (file-exists-p path))
      ;; Any write tool, and wherever in its input the placeholder is.
      (should (plist-get (harness-secrets-mask-test--call "mask_write" :text placeholder) :denied))
      (should (plist-get (harness-secrets-mask-test--call "edit_file" :path path :old_string placeholder
                                                           :new_string "x")
                         :denied)))))

(ert-deftest harness-secrets-mask-guard-leaves-other-calls-alone ()
  "A write without a placeholder, a text that only looks like one, and a read go through."
  (harness-secrets-mask-test-with
    (let ((path (expand-file-name "config.txt" dir)))
      (should-not (plist-get (harness-secrets-mask-test--call "write_file" :path path :content "plain\n")
                             :is-error))
      (should (equal "plain\n" (harness-secrets-mask-test--file-text path)))
      ;; Not a placeholder: no fingerprint, or no label.
      (dolist (text '("[redacted: <label> sha256:<8 hex>]" "[redacted: x sha256:1234]" "[redacted:  sha256:" "redacted"))
        (should-not (plist-get (harness-secrets-mask-test--call "mask_write" :text text) :is-error)))
      ;; A read may name one: the model asks about it.
      (let ((result (harness-secrets-mask-test--call "mask_echo" :text "[redacted: spaces-secret sha256:0123abcd]")))
        (should-not (plist-get result :denied))
        (should (equal "[redacted: spaces-secret sha256:0123abcd]" (plist-get result :content)))))))

;;;; The sources

(ert-deftest harness-secrets-mask-sources-list-no-value ()
  "`secrets/sources' says where each value is read and its fingerprint, never the value."
  (harness-secrets-mask-test-with
    (let* ((a (harness-secrets-mask-test--fake "AAA"))
           (b (harness-secrets-mask-test--fake "BBB"))
           (c (harness-secrets-mask-test--fake "CCC"))
           (file (harness-secrets-mask-test--key-file a))
           (process-environment (cons (concat "HARNESS_MASK_TEST_SECRET=" b) process-environment))
           (harness-secrets-sources (list (harness-secrets-mask-test--source file "from-file")
                                          (list :env "HARNESS_MASK_TEST_SECRET" :label "from-env")
                                          (list :literal c :label "typed")
                                          (list :file (expand-file-name "missing.json" dir) :json-path "a.b"
                                                :label "gone"))))
      (let* ((sources (harness-call 'secrets/sources))
             (text (format "%S" sources)))
        (dolist (value (list a b c))
          (should-not (string-search value text)))
        (should (equal '("config-1" "config-2" "config-3" "config-4")
                       (mapcar (lambda (s) (plist-get s :id)) sources)))
        (should (equal '("from-file" "from-env" "typed" "gone")
                       (mapcar (lambda (s) (plist-get s :label)) sources)))
        (should (equal (list (list (harness-redaction-fingerprint a)) (list (harness-redaction-fingerprint b))
                             (list (harness-redaction-fingerprint c)) nil)
                       (mapcar (lambda (s) (plist-get s :fingerprints)) sources)))
        (should (equal '(1 1 1 0) (mapcar (lambda (s) (plist-get s :values)) sources)))
        (should (cl-every (lambda (s) (eq 'config (plist-get s :origin))) sources))
        ;; The one that cannot be read says why, and does not stop the others.
        (should (string-match-p "Cannot read" (plist-get (nth 3 sources) :error)))
        (should-not (plist-get (nth 0 sources) :error))
        (should (string-search "JSON path outputs.keys.value.secret" (plist-get (nth 0 sources) :source)))
        (should (equal "environment variable HARNESS_MASK_TEST_SECRET" (plist-get (nth 1 sources) :source)))
        (should (equal "typed by the user" (plist-get (nth 2 sources) :source)))
        (should (string-search "[redacted: from-env" (car (harness-secrets-mask-text b))))))))

(ert-deftest harness-secrets-mask-add-source-refuses-a-literal ()
  "A literal would put a value on disk: it is refused, and nothing is stored."
  (harness-secrets-mask-test-with
    (let ((secret (harness-secrets-mask-test--fake)))
      (dolist (ref (list (list :literal secret :label "typed")
                         (list :literal secret)
                         (list :file "/x" :literal secret)))
        (let ((err (should-error (harness-call 'secrets/add-source ref) :type 'harness-error)))
          (should (string-search "literal" (cadr err)))
          (should-not (string-search secret (format "%S" err)))))
      (should-not (harness-call 'secrets/sources))
      (should-not (file-exists-p (expand-file-name "secret-sources.json" dir))))))

(ert-deftest harness-secrets-mask-add-and-remove-a-stored-source ()
  "A source added by reference is kept as a reference, masks its value, and can be removed."
  (harness-secrets-mask-test-with
    (let* ((secret (harness-secrets-mask-test--fake))
           (file (harness-secrets-mask-test--key-file secret))
           (entry (harness-call 'secrets/add-source
                                ;; As a client's JSON spells it.
                                (list :file file :jsonPath "outputs.keys.value.secret" :label "stored"))))
      (should (eq 'stored (plist-get entry :origin)))
      (should (string-prefix-p "src-" (plist-get entry :id)))
      (should (equal (list (harness-redaction-fingerprint secret)) (plist-get entry :fingerprints)))
      (should-not (string-search secret (format "%S" entry)))
      ;; What is on disk is the reference.
      (let ((stored (harness-secrets-mask-test--file-text (expand-file-name "secret-sources.json" dir))))
        (should-not (string-search secret stored))
        (should (string-search "outputs.keys.value.secret" stored))
        (should (string-search "\"json-path\"" stored)))
      (should (string-search "[redacted: stored" (car (harness-secrets-mask-text secret))))
      ;; Adding it again is no second source.
      (should (equal (plist-get entry :id)
                     (plist-get (harness-call 'secrets/add-source
                                              (list :file file :json-path "outputs.keys.value.secret" :label "stored"))
                                :id)))
      (should (= 1 (length (harness-call 'secrets/sources))))
      ;; A new start reads the same from the file.
      (harness-secrets-forget)
      (should (string-search "[redacted: stored" (car (harness-secrets-mask-text secret))))
      ;; Removed, it masks nothing more.
      (should (equal (list :id (plist-get entry :id) :removed t)
                     (harness-call 'secrets/remove-source (plist-get entry :id))))
      (should (eq secret (car (harness-secrets-mask-text secret))))
      (should-error (harness-call 'secrets/remove-source (plist-get entry :id)) :type 'harness-error))))

(ert-deftest harness-secrets-mask-add-source-validates-the-reference ()
  "A reference that names no value, or holds the value itself, is refused."
  (harness-secrets-mask-test-with
    (let* ((secret (harness-secrets-mask-test--fake))
           (file (harness-secrets-mask-test--key-file secret)))
      (should-error (harness-call 'secrets/add-source (list :file file :json-path "no.such.path"))
                    :type 'harness-error)
      (should-error (harness-call 'secrets/add-source (list :file (expand-file-name "nope.json" dir)
                                                            :json-path "a"))
                    :type 'harness-error)
      (should-error (harness-call 'secrets/add-source (list :env "HARNESS_MASK_TEST_UNSET_VARIABLE"))
                    :type 'harness-error)
      (should-error (harness-call 'secrets/add-source '(:label "nothing")) :type 'harness-error)
      ;; A regexp that spells the value out puts it on disk.
      (let ((err (should-error (harness-call 'secrets/add-source
                                             (list :file file :regexp (format "\\(%s\\)" (regexp-quote secret))))
                               :type 'harness-error)))
        (should-not (string-search secret (format "%S" err))))
      (should-not (harness-call 'secrets/sources))
      ;; A source of the setting is the setting's to remove.
      (let ((harness-secrets-sources (list (list :literal secret :label "set"))))
        (should (string-search "harness-secrets-sources"
                               (cadr (should-error (harness-call 'secrets/remove-source "config-1")
                                                   :type 'harness-error))))))))

;;;; The registry follows its sources

(ert-deftest harness-secrets-mask-registry-follows-the-file ()
  "A file source is read again when the file changes, at most every few seconds."
  (harness-secrets-mask-test-with
    (let* ((first (harness-secrets-mask-test--fake "ONE"))
           (second (harness-secrets-mask-test--fake "TWO-and-longer"))
           (file (harness-secrets-mask-test--key-file first))
           (harness-secrets-sources (list (harness-secrets-mask-test--source file "rotating"))))
      (should (string-search "[redacted: rotating" (car (harness-secrets-mask-text first))))
      ;; The file changes; within the interval nobody looks.
      (harness-secrets-mask-test--key-file second)
      (should (eq second (car (harness-secrets-mask-text second))))
      ;; Once the interval is over, the new value is read.
      (setq harness-secrets--checked 0.0)
      (should (string-search "[redacted: rotating" (car (harness-secrets-mask-text second))))
      (should (equal (list (harness-redaction-fingerprint second))
                     (plist-get (car (harness-call 'secrets/sources)) :fingerprints))))
    ;; With no interval, every call looks.
    (let* ((harness-secrets--refresh-interval 0)
           (third (harness-secrets-mask-test--fake "THREE"))
           (file (harness-secrets-mask-test--key-file (harness-secrets-mask-test--fake)))
           (harness-secrets-sources (list (harness-secrets-mask-test--source file "rotating"))))
      (harness-secrets-mask-text "warm up")
      (harness-secrets-mask-test--key-file third)
      (should (string-search "[redacted: rotating" (car (harness-secrets-mask-text third)))))))

(ert-deftest harness-secrets-mask-registry-keeps-values-of-a-file-it-cannot-read ()
  "A file that goes away or breaks is reported, and its last values keep being masked."
  (harness-secrets-mask-test-with
    (let* ((secret (harness-secrets-mask-test--fake))
           (file (harness-secrets-mask-test--key-file secret))
           (harness-secrets--refresh-interval 0)
           (harness-secrets-sources (list (harness-secrets-mask-test--source file "fragile"))))
      (should (string-search "[redacted: fragile" (car (harness-secrets-mask-text secret))))
      (with-temp-file file (insert "{ not json"))
      (should (string-search "[redacted: fragile" (car (harness-secrets-mask-text secret))))
      (let ((entry (car (harness-call 'secrets/sources))))
        (should (string-search "not valid JSON" (plist-get entry :error)))
        (should (= 1 (plist-get entry :values))))
      (delete-file file)
      (should (string-search "[redacted: fragile" (car (harness-secrets-mask-text secret))))
      ;; Logged once for each reason, however often it is looked at.
      (dotimes (_ 3) (harness-secrets-mask-text "again"))
      (let ((logged (with-current-buffer harness-log-buffer-name (buffer-string))))
        (should (= 2 (with-temp-buffer
                       (insert logged)
                       (goto-char (point-min))
                       (let ((case-fold-search nil) (n 0))
                         (while (search-forward "secrets: cannot read" nil t) (cl-incf n))
                         n))))
        (should-not (string-search secret logged))))))

(ert-deftest harness-secrets-mask-environment-source-follows-the-variable ()
  "A variable is read again when its value changes."
  (harness-secrets-mask-test-with
    (let* ((first (harness-secrets-mask-test--fake "ENV1"))
           (second (harness-secrets-mask-test--fake "ENV2"))
           (harness-secrets--refresh-interval 0)
           (process-environment (cons (concat "HARNESS_MASK_TEST_VAR=" first) process-environment))
           (harness-secrets-sources (list (list :env "HARNESS_MASK_TEST_VAR" :label "var"))))
      (should (string-search "[redacted: var" (car (harness-secrets-mask-text first))))
      (setenv "HARNESS_MASK_TEST_VAR" second)
      (should (string-search "[redacted: var" (car (harness-secrets-mask-text second)))))))

(ert-deftest harness-secrets-mask-command-source-runs-once ()
  "A command runs when the source is first read, and again only if the source changes."
  (harness-secrets-mask-test-with
    (let* ((secret (harness-secrets-mask-test--fake))
           (counter (expand-file-name "runs" dir))
           (command (format "echo ran >> %s; printf '%%s\\n' %s" (shell-quote-argument counter)
                            (shell-quote-argument secret)))
           (harness-secrets--refresh-interval 0)
           (harness-secrets-sources (list (list :command command :label "from-command"))))
      (dotimes (_ 3)
        (should (string-search "[redacted: from-command" (car (harness-secrets-mask-text secret)))))
      (should (= 1 (length (split-string (harness-secrets-mask-test--file-text counter) "\n" t))))
      ;; The command is not in what the sources show.
      (should-not (string-search "echo ran" (format "%S" (harness-call 'secrets/sources))))
      ;; Another source joining the list does not run it again.
      (push (list :literal (harness-secrets-mask-test--fake) :label "other") harness-secrets-sources)
      (harness-secrets-mask-text "x")
      (should (= 1 (length (split-string (harness-secrets-mask-test--file-text counter) "\n" t)))))))

(ert-deftest harness-secrets-mask-regexp-source ()
  "Group 1 of each match of a regexp in a file is a secret."
  (harness-secrets-mask-test-with
    (let* ((a (harness-secrets-mask-test--fake "RX1"))
           (b (harness-secrets-mask-test--fake "RX2"))
           (file (expand-file-name "creds.env" dir))
           (harness-secrets-sources (list (list :file file :regexp "^KEY_[AB]=\\(.*\\)$" :label "env-file"))))
      (with-temp-file file (insert (format "KEY_A=%s\nOTHER=1\nKEY_B=%s\n" a b)))
      (should (equal '(("env-file.1" . 1) ("env-file.2" . 1))
                     (harness-secrets-mask-test--hits (format "%s %s" a b)))))))

;;;; Through the agent

(defmacro harness-secrets-mask-test-with-agent (&rest body)
  "Run BODY with the agent, the demo provider, bash and masking loaded."
  (declare (indent 0))
  `(progn
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo tools tools-shell session agent secrets))
       (harness-test-load-module m))
     (cancel-function-timers #'harness-secrets--prime)
     (harness-test-with-temp-state
       (clrhash harness-sessions)
       (clrhash harness-agent--turns)
       (harness-secrets-forget)
       (let ((harness-provider-demo--delay 0.005)
             (harness-secrets-mask t)
             (harness-secrets-sources nil)
             (harness-secrets-detectors 'default)
             (harness-secrets-extra-detectors nil)
             (harness-provider-demo-script-override nil)
             (default-directory dir))
         (harness-add-filter 'permission/decide #'harness-secrets-mask-test--allow 10)
         (unwind-protect (progn ,@body)
           (harness-secrets-forget))))))

(ert-deftest harness-secrets-mask-agent-records-and-sends-masked-output ()
  "A turn whose bash call prints a registered value stores and sends the placeholder.
The model's call names the file, not the value, so no copy of the value
is in the node log, in the record, or in the next request to the model."
  (harness-secrets-mask-test-with-agent
    (let* ((secret (harness-secrets-mask-test--fake))
           (file (harness-secrets-mask-test--key-file secret))
           (harness-secrets-sources (list (harness-secrets-mask-test--source file "spaces-secret")))
           (placeholder (harness-secrets-mask-test--placeholder secret "spaces-secret"))
           (id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted") :id))
           (requests nil))
      (setq harness-provider-demo-script-override
            (lambda (request)
              (push (plist-get request :messages) requests)
              (if (cl-some (lambda (m) (cl-some (lambda (b) (equal "tool_result" (plist-get b :type)))
                                                (plist-get m :content)))
                           (plist-get request :messages))
                  '((:type text :delta "Read it.") (:type done :stop-reason end-turn))
                `((:type tool-call :id "c1" :name "bash"
                         :input (:command ,(format "cat %s" (shell-quote-argument file))))
                  (:type done :stop-reason tool-use)))))
      (harness-await (harness-call 'agent/prompt id "show the keys") 30)
      (should (>= (length requests) 2))
      ;; The result node holds the placeholder and says what was masked.
      (let ((result (cl-find 'tool-result (harness-call 'session/nodes id)
                             :key (lambda (n) (plist-get n :kind)))))
        (should (string-search placeholder (plist-get result :output)))
        (should-not (string-search secret (plist-get result :output)))
        (should (equal (list (list :label "spaces-secret"
                                   :fingerprint (harness-redaction-fingerprint secret) :count 1))
                       (plist-get (plist-get result :meta) :masked))))
      ;; What the model was sent after the call is the masked result.
      (let ((sent (format "%S" requests)))
        (should (string-search placeholder sent))
        (should-not (string-search secret sent)))
      ;; And on disk: the node log, the record, the saved output.
      (harness-session-flush)
      (dolist (name (list (format "sessions/%s.nodes.jsonl" id) (format "sessions/%s.json" id)))
        (should-not (string-search secret (harness-secrets-mask-test--file-text (expand-file-name name dir)))))
      ;; The log says what was masked, by fingerprint.
      (should (string-search (format "\"fingerprint\":\"%s\"" (harness-redaction-fingerprint secret))
                             (harness-secrets-mask-test--file-text
                              (expand-file-name (format "sessions/%s.nodes.jsonl" id) dir)))))))

(ert-deftest harness-secrets-mask-hosted-loop-is-answered-with-the-masked-result ()
  "A hosted loop, which the agent answers through `:respond', is given the masked output.
That is how Claude Code, whose CLI keeps the conversation, learns what a
tool printed."
  (harness-secrets-mask-test-with-agent
    (let* ((secret (harness-secrets-mask-test--fake))
           (file (harness-secrets-mask-test--key-file secret))
           (harness-secrets-sources (list (harness-secrets-mask-test--source file "spaces-secret")))
           (placeholder (harness-secrets-mask-test--placeholder secret "spaces-secret"))
           (answers nil))
      (harness-define-provider 'hosted
        :label "Hosted"
        :capabilities '(:hosted-loop t)
        :complete
        (lambda (request)
          (let ((on-event (plist-get request :on-event)))
            (funcall on-event '(:type start))
            (run-at-time
             0.005 nil
             (lambda ()
               (funcall on-event
                        (list :type 'tool-call :id "h1" :name "bash"
                              :input (list :command (format "cat %s" (shell-quote-argument file)))
                              :respond (lambda (result)
                                         (push (plist-get result :content) answers)
                                         (run-at-time 0.005 nil
                                                      (lambda ()
                                                        (funcall on-event '(:type text :delta "Read it."))
                                                        (funcall on-event '(:type done :stop-reason end-turn)))))))))
            (list :cancel #'ignore))))
      (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "hosted:loop") :id)))
        (harness-await (harness-call 'agent/prompt id "show the keys") 30)
        (should (= 1 (length answers)))
        (should (string-search placeholder (car answers)))
        (should-not (string-search secret (car answers)))
        (let ((result (cl-find 'tool-result (harness-call 'session/nodes id)
                               :key (lambda (n) (plist-get n :kind)))))
          (should (equal (plist-get result :output) (car answers)))
          (should-not (string-search secret (plist-get result :output))))))))

(ert-deftest harness-secrets-mask-agent-masks-the-output-of-a-providers-own-tool ()
  "The output of a call the provider ran itself is masked as it is recorded."
  (harness-secrets-mask-test-with-agent
    (let* ((secret (harness-secrets-mask-test--fake))
           (harness-secrets-sources (list (list :literal secret :label "builtin-seen")))
           (id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted") :id)))
      (harness-agent--record-builtin-result id (list "b1" :started (float-time))
                                            (format "1. a result mentioning %s" secret) nil)
      (let ((result (cl-find 'tool-result (harness-call 'session/nodes id)
                             :key (lambda (n) (plist-get n :kind)))))
        (should (equal (format "1. a result mentioning %s"
                               (harness-secrets-mask-test--placeholder secret "builtin-seen"))
                       (plist-get result :output)))))))

(provide 'harness-secrets-mask-test)
;;; harness-secrets-mask-test.el ends here
