;;; harness-redaction-test.el --- Tests for finding secrets and taking them out of text  -*- lexical-binding: t; -*-

;;; Commentary:

;; Every secret here is a fake one, built when the test runs, so that
;; no value that looks real is committed.  A test that fails shows the
;; values it compared; they are made up.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-redaction)

(defvar harness-redaction--chunk-size)
(defvar harness-redaction--max-file-size)

(defconst harness-redaction-test--id (concat "FAKEID" (make-string 14 ?x))
  "A fake access key id.")

(defconst harness-redaction-test--key (concat "FAKE/key+" (make-string 30 ?k) "\"q")
  "A fake secret key, with a slash and a quote for JSON to escape.")

(defconst harness-redaction-test--tag (concat "tag-" "abcdefgh")
  "A fake value of 12 characters.")

(defun harness-redaction-test--secrets ()
  "Return the fake key and id as secrets, labelled."
  (list (harness-redaction-secret harness-redaction-test--key "spaces key")
        (harness-redaction-secret harness-redaction-test--id "spaces id")))

(defun harness-redaction-test--placeholder (index)
  "Return the placeholder of the secret INDEX of `harness-redaction-test--secrets'."
  (harness-redaction-placeholder (nth index (harness-redaction-test--secrets))))

(defmacro harness-redaction-test--with-dir (var &rest body)
  "Run BODY with VAR bound to a fresh directory, removed afterwards."
  (declare (indent 1))
  `(let ((,var (harness-test-temp-dir)))
     (unwind-protect (progn ,@body)
       (ignore-errors (delete-directory ,var t)))))

(defun harness-redaction-test--write (file text)
  "Write TEXT to FILE as UTF-8 and return FILE."
  (let ((coding-system-for-write 'utf-8-unix))
    (write-region text nil file nil 'silent))
  file)

(defun harness-redaction-test--write-bytes (file bytes)
  "Write BYTES, a unibyte string, to FILE as they are and return FILE."
  (let ((coding-system-for-write 'no-conversion))
    (write-region (string-to-unibyte bytes) nil file nil 'silent))
  file)

(defun harness-redaction-test--read (file)
  "Return the content of FILE, read as UTF-8."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8-unix)) (insert-file-contents file))
    (buffer-string)))

(defun harness-redaction-test--bytes (file)
  "Return the bytes of FILE."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(defun harness-redaction-test--state (dir)
  "Write a JSON file shaped like a terraform state in DIR and return it."
  (harness-redaction-test--write
   (expand-file-name "state.json" dir)
   (json-serialize
    `((version . 4)
      (outputs . ((spaces . ((value . ((access_key . ,harness-redaction-test--id)
                                       (secret_key . ,harness-redaction-test--key)
                                       (region . "ams3")
                                       (port . 443)
                                       (tags . [,harness-redaction-test--tag])))
                             (type . "object")
                             (sensitive . :false)))
                  (note . ((value . "short")))))
      (items . [((token . ,(concat "TOKEN-A-" (make-string 10 ?a))))
                ((token . ,(concat "TOKEN-B-" (make-string 12 ?b))))])
      (,(intern "weird.key") . ((v . ,(concat "WEIRD-" (make-string 10 ?w)))))
      (,(intern "0") . ,(concat "DIGITKEY-" (make-string 10 ?d)))))))

(defun harness-redaction-test--labels (resolved)
  "Return the labels of the secrets in RESOLVED, as `harness-redaction-resolve' gave it."
  (mapcar (lambda (s) (plist-get s :label)) (plist-get resolved :secrets)))

(defun harness-redaction-test--holds-p (object value)
  "Non-nil when OBJECT, printed either way, holds the string VALUE.
A string prints with its quotes and backslashes escaped by `prin1' and
as it is without: a value with a quote in it hides from a search of the
first, so both are searched."
  (and (or (string-search value (prin1-to-string object t))
           (string-search (substring (prin1-to-string value) 1 -1) (prin1-to-string object)))
       t))

(defun harness-redaction-test--error-message (thunk)
  "Return the message of the error THUNK signals, or fail."
  (condition-case err
      (progn (funcall thunk) (ert-fail "no error was signalled"))
    (harness-error (harness-error-message err))))

;;;; The helpers the other tests lean on

(ert-deftest harness-redaction-test-holds-p-finds-a-value-printed-either-way ()
  "The checks that a value is nowhere are worth something only if this one sees it."
  (let ((value harness-redaction-test--key))
    (should (string-search "\"" value))
    (should (harness-redaction-test--holds-p value value))
    (should (harness-redaction-test--holds-p (list :a (list "x" value)) value))
    (should (harness-redaction-test--holds-p (vector 1 (cons "k" value)) value))
    (should-not (harness-redaction-test--holds-p (list :a "x" "FAKE/key+") value))
    (should-not (harness-redaction-test--holds-p nil value))))

;;;; Fingerprints and placeholders

(ert-deftest harness-redaction-fingerprint-is-eight-hex-digits-of-the-sha256 ()
  (should (equal (harness-redaction-fingerprint harness-redaction-test--id)
                 (substring (secure-hash 'sha256 (encode-coding-string harness-redaction-test--id 'utf-8))
                            0 8)))
  (should (string-match-p "\\`[0-9a-f]\\{8\\}\\'" (harness-redaction-fingerprint "abc")))
  ;; The digest is of UTF-8 bytes, so a character is the same wherever it is read.
  (should (equal (harness-redaction-fingerprint (concat "caf" (string #xe9)))
                 (substring (secure-hash 'sha256 "caf\303\251") 0 8))))

(ert-deftest harness-redaction-placeholder-names-the-label-and-the-fingerprint ()
  (let ((secret (harness-redaction-secret harness-redaction-test--id "my label")))
    (should (equal (harness-redaction-placeholder secret)
                   (format "[redacted: my label sha256:%s]"
                           (harness-redaction-fingerprint harness-redaction-test--id))))
    (should (equal (plist-get secret :fingerprint)
                   (harness-redaction-fingerprint harness-redaction-test--id)))
    ;; A secret made by hand, without a fingerprint, gets one worked out.
    (should (equal (harness-redaction-placeholder (list :value harness-redaction-test--id :label "x"))
                   (format "[redacted: x sha256:%s]"
                           (harness-redaction-fingerprint harness-redaction-test--id))))))

(ert-deftest harness-redaction-labels-are-safe-for-a-placeholder ()
  (let ((label (lambda (l) (plist-get (harness-redaction-secret harness-redaction-test--id l) :label))))
    (should (equal (funcall label "a]b\nc\td") "a)b c d"))
    (should (equal (funcall label "  padded  ") "padded"))
    (should (equal (funcall label nil) "secret"))
    (should (equal (funcall label "\n\n") "secret"))
    (should (equal (length (funcall label (make-string 200 ?a))) 80))
    ;; Whatever the label, a placeholder ends at its one closing bracket.
    (let ((placeholder (harness-redaction-placeholder
                        (harness-redaction-secret harness-redaction-test--id "x] y\n"))))
      (should (= 1 (cl-count ?\] placeholder)))
      (should-not (string-search "\n" placeholder)))))

(ert-deftest harness-redaction-describes-a-source-without-a-value ()
  (should (equal (harness-redaction-describe-source '(:file "/tmp/a.json" :json-path "a.b"))
                 "file /tmp/a.json, JSON path a.b"))
  (should (equal (harness-redaction-describe-source '(:file "/tmp/a.txt" :regexp "k=\\(.*\\)"))
                 "file /tmp/a.txt, regexp k=\\(.*\\)"))
  (should (equal (harness-redaction-describe-source '(:env "SOME_VAR"))
                 "environment variable SOME_VAR"))
  (should (equal (harness-redaction-describe-source (list :literal harness-redaction-test--key))
                 "typed by the user"))
  (should (equal (harness-redaction-describe-source (list :command (concat "echo " harness-redaction-test--key)))
                 "command output")))

;;;; JSON paths

(ert-deftest harness-redaction-json-path-parse-reads-segments ()
  (should (equal (harness-redaction-json-path-parse "outputs.spaces.value")
                 '("outputs" "spaces" "value")))
  (should (equal (harness-redaction-json-path-parse "$.outputs.spaces") '("outputs" "spaces")))
  (should (equal (harness-redaction-json-path-parse ".outputs.spaces") '("outputs" "spaces")))
  ;; The root has no segments, however it is written.
  (dolist (root '("" "$" "." "$." "  "))
    (should (null (harness-redaction-json-path-parse root))))
  ;; A number is an array index, and a star is every element.
  (should (equal (harness-redaction-json-path-parse "items.0.token") '("items" 0 "token")))
  (should (equal (harness-redaction-json-path-parse "items.*.token") '("items" * "token")))
  (should (equal (harness-redaction-json-path-parse "items[1].token") '("items" 1 "token")))
  (should (equal (harness-redaction-json-path-parse "items[*]") '("items" *)))
  ;; A bracketed key may hold dots, brackets, spaces and digits.
  (should (equal (harness-redaction-json-path-parse "a[\"b.c\"].d") '("a" "b.c" "d")))
  (should (equal (harness-redaction-json-path-parse "a['b c']") '("a" "b c")))
  (should (equal (harness-redaction-json-path-parse "[\"0\"]") '("0")))
  (should (equal (harness-redaction-json-path-parse "a[\"q\\\"r\"]") '("a" "q\"r")))
  (should (equal (harness-redaction-json-path-parse "a.[\"b\"]") '("a" "b")))
  ;; A $ that starts a name is part of the key.
  (should (equal (harness-redaction-json-path-parse "$schema.type") '("$schema" "type")))
  (should (equal (harness-redaction-json-path-parse "  a . b ") '("a" "b"))))

(ert-deftest harness-redaction-json-path-parse-signals-on-bad-syntax ()
  (dolist (bad '("a..b" "a." ".." "a[" "a[\"b" "a[b]" "a[]" "a]b" "a[\"b\"]c" "a[\"b\" x]"))
    (should-error (harness-redaction-json-path-parse bad) :type 'harness-error))
  (should-error (harness-redaction-json-path-parse nil) :type 'harness-error)
  (should (string-match-p "Invalid JSON path" (harness-redaction-test--error-message
                                               (lambda () (harness-redaction-json-path-parse "a..b"))))))

;;;; Resolving references

(ert-deftest harness-redaction-resolve-an-object-selects-every-string-under-it ()
  (harness-redaction-test--with-dir dir
    (let* ((file (harness-redaction-test--state dir))
           (r (harness-redaction-resolve (list :file file :json-path "outputs.spaces.value"))))
      ;; The region is shorter than the minimum, the port is no string.
      (should (= 1 (plist-get r :skipped)))
      (should (equal (plist-get r :source)
                     (format "file %s, JSON path outputs.spaces.value" (abbreviate-file-name file))))
      (should (equal (mapcar (lambda (s) (plist-get s :value)) (plist-get r :secrets))
                     (list harness-redaction-test--key harness-redaction-test--id
                           harness-redaction-test--tag)))
      ;; Labelled by the path from the root.
      (should (equal (harness-redaction-test--labels r)
                     '("outputs.spaces.value.secret_key" "outputs.spaces.value.access_key"
                       "outputs.spaces.value.tags.0")))
      (dolist (s (plist-get r :secrets))
        (should (equal (plist-get s :fingerprint) (harness-redaction-fingerprint (plist-get s :value))))
        (should (equal (plist-get s :source) (plist-get r :source))))
      ;; With a label, each is labelled with it and what lies below the selection.
      (let ((labelled (harness-redaction-resolve
                       (list :file file :json-path "$.outputs.spaces.value" :label "spaces"))))
        (should (equal (harness-redaction-test--labels labelled)
                       '("spaces.secret_key" "spaces.access_key" "spaces.tags.0")))))))

(ert-deftest harness-redaction-resolve-a-single-string ()
  (harness-redaction-test--with-dir dir
    (let* ((file (harness-redaction-test--state dir))
           (path "outputs.spaces.value.access_key")
           (r (harness-redaction-resolve (list :file file :json-path path))))
      (should (equal (harness-redaction-test--labels r) (list path)))
      (should (equal (plist-get (car (plist-get r :secrets)) :value) harness-redaction-test--id))
      (should (= 0 (plist-get r :skipped)))
      ;; Alone, it takes the label given whole.
      (should (equal (harness-redaction-test--labels
                      (harness-redaction-resolve (list :file file :json-path path :label "id")))
                     '("id")))
      ;; The keys may be spelt as a tool call spells them.
      (should (equal (harness-redaction-test--labels
                      (harness-redaction-resolve (list :file file :json_path path)))
                     (list path))))))

(ert-deftest harness-redaction-resolve-a-wildcard-an-index-and-a-bracketed-key ()
  (harness-redaction-test--with-dir dir
    (let ((file (harness-redaction-test--state dir)))
      (let ((r (harness-redaction-resolve (list :file file :json-path "items.*.token"))))
        (should (equal (harness-redaction-test--labels r) '("items.1.token" "items.0.token")))
        (should (equal (mapcar (lambda (s) (plist-get s :value)) (plist-get r :secrets))
                       (list (concat "TOKEN-B-" (make-string 12 ?b))
                             (concat "TOKEN-A-" (make-string 10 ?a))))))
      ;; With a label, the part that the wildcard fills in tells them apart.
      (should (equal (harness-redaction-test--labels
                      (harness-redaction-resolve (list :file file :json-path "items.*.token" :label "tok")))
                     '("tok.1.token" "tok.0.token")))
      (should (equal (harness-redaction-test--labels
                      (harness-redaction-resolve (list :file file :json-path "items.1.token")))
                     '("items.1.token")))
      (should (equal (harness-redaction-test--labels
                      (harness-redaction-resolve (list :file file :json-path "items[0].token")))
                     '("items.0.token")))
      (should (equal (harness-redaction-test--labels
                      (harness-redaction-resolve (list :file file :json-path "[\"weird.key\"].v")))
                     '("weird.key.v")))
      ;; A number on an object is the key of that number.
      (should (equal (harness-redaction-test--labels
                      (harness-redaction-resolve (list :file file :json-path "[\"0\"]")))
                     '("0")))
      (should (equal (harness-redaction-test--labels
                      (harness-redaction-resolve (list :file file :json-path "0")))
                     '("0"))))))

(ert-deftest harness-redaction-resolve-counts-a-value-once ()
  (harness-redaction-test--with-dir dir
    (let ((file (harness-redaction-test--write
                 (expand-file-name "dup.json" dir)
                 (json-serialize `((a . ,harness-redaction-test--id)
                                   (b . ,harness-redaction-test--id)
                                   (c . [,harness-redaction-test--id]))))))
      (let ((r (harness-redaction-resolve (list :file file :json-path "$"))))
        (should (= 1 (length (plist-get r :secrets))))
        (should (equal (harness-redaction-test--labels r) '("a")))))))

(ert-deftest harness-redaction-resolve-group-1-of-each-match-of-a-regexp ()
  (harness-redaction-test--with-dir dir
    (let ((file (harness-redaction-test--write
                 (expand-file-name "config.txt" dir)
                 (concat "access = \"" harness-redaction-test--id "\"\n"
                         "secret = \"" harness-redaction-test--tag "\"\n"
                         "other = \"short\"\n"
                         "access = \"" harness-redaction-test--id "\"\n")))
          (regexp "= \"\\([^\"]+\\)\""))
      (let ((r (harness-redaction-resolve (list :file file :regexp regexp))))
        (should (equal (mapcar (lambda (s) (plist-get s :value)) (plist-get r :secrets))
                       (list harness-redaction-test--id harness-redaction-test--tag)))
        (should (= 1 (plist-get r :skipped)))
        ;; Several values are numbered after the file, in the order they are met.
        (should (equal (harness-redaction-test--labels r) '("config.txt.1" "config.txt.2")))
        (should (equal (plist-get r :source)
                       (format "file %s, regexp %s" (abbreviate-file-name file) regexp))))
      (should (equal (harness-redaction-test--labels
                      (harness-redaction-resolve (list :file file :regexp regexp :label "cfg")))
                     '("cfg.1" "cfg.2")))
      ;; One value takes the label as it is.
      (should (equal (harness-redaction-test--labels
                      (harness-redaction-resolve
                       (list :file file :regexp "access = \"\\([^\"]+\\)\"" :label "id")))
                     '("id")))
      (should (string-match-p
               "matches nothing"
               (harness-redaction-test--error-message
                (lambda () (harness-redaction-resolve (list :file file :regexp "nope \\(x\\)"))))))
      (should (string-match-p
               "no group 1"
               (harness-redaction-test--error-message
                (lambda () (harness-redaction-resolve (list :file file :regexp "access"))))))
      (should (string-match-p
               "Invalid regexp"
               (harness-redaction-test--error-message
                (lambda () (harness-redaction-resolve (list :file file :regexp "\\(a")))))))))

(ert-deftest harness-redaction-resolve-env-literal-and-command ()
  (let ((process-environment (cons (concat "HARNESS_REDACTION_TEST_VAR=" harness-redaction-test--key)
                                   process-environment)))
    (let ((r (harness-redaction-resolve '(:env "HARNESS_REDACTION_TEST_VAR"))))
      (should (equal (plist-get (car (plist-get r :secrets)) :value) harness-redaction-test--key))
      (should (equal (harness-redaction-test--labels r) '("HARNESS_REDACTION_TEST_VAR")))
      (should (equal (plist-get r :source) "environment variable HARNESS_REDACTION_TEST_VAR")))
    (should (equal (harness-redaction-test--labels
                    (harness-redaction-resolve '(:env "HARNESS_REDACTION_TEST_VAR" :label "k")))
                   '("k")))
    ;; The command's text names the variable, not the value; its output
    ;; lost its newline, and the description does not name the command.
    (let ((r (harness-redaction-resolve
              '(:command "printf '%s\\n\\n' \"$HARNESS_REDACTION_TEST_VAR\"" :label "cmd"))))
      (should (equal (plist-get (car (plist-get r :secrets)) :value) harness-redaction-test--key))
      (should (equal (harness-redaction-test--labels r) '("cmd")))
      (should (equal (plist-get r :source) "command output"))))
  (let ((r (harness-redaction-resolve (list :literal harness-redaction-test--id :label "typed"))))
    (should (equal (plist-get (car (plist-get r :secrets)) :value) harness-redaction-test--id))
    (should (equal (harness-redaction-test--labels r) '("typed")))
    (should (equal (plist-get r :source) "typed by the user")))
  (should (equal (harness-redaction-test--labels (harness-redaction-resolve (list :literal harness-redaction-test--id)))
                 '("secret"))))

(ert-deftest harness-redaction-resolve-errors-say-nothing-of-a-value ()
  (harness-redaction-test--with-dir dir
    (let* ((file (harness-redaction-test--state dir))
           (values (list harness-redaction-test--id harness-redaction-test--key harness-redaction-test--tag))
           (process-environment (cons (concat "HARNESS_REDACTION_TEST_VAR=" harness-redaction-test--key)
                                      process-environment))
           (messages
            (list
             ;; Nothing at the path, nothing that is a string, no such file, not JSON.
             (harness-redaction-test--error-message
              (lambda () (harness-redaction-resolve (list :file file :json-path "outputs.nope"))))
             (harness-redaction-test--error-message
              (lambda () (harness-redaction-resolve (list :file file :json-path "outputs.spaces.value.port"))))
             (harness-redaction-test--error-message
              (lambda () (harness-redaction-resolve (list :file (expand-file-name "missing.json" dir)
                                                          :json-path "a"))))
             (harness-redaction-test--error-message
              (lambda () (harness-redaction-resolve
                          (list :file (harness-redaction-test--write
                                       (expand-file-name "bad.json" dir)
                                       (concat "{\"a\": \"" harness-redaction-test--key))
                                :json-path "a"))))
             (harness-redaction-test--error-message
              (lambda () (harness-redaction-resolve '(:env "HARNESS_REDACTION_TEST_UNSET"))))
             ;; A command that fails after printing, and one that prints nothing.
             (harness-redaction-test--error-message
              (lambda () (harness-redaction-resolve
                          '(:command "printf '%s' \"$HARNESS_REDACTION_TEST_VAR\"; exit 3"))))
             (harness-redaction-test--error-message
              (lambda () (harness-redaction-resolve '(:command "true"))))
             ;; Everything too short.
             (harness-redaction-test--error-message
              (lambda () (harness-redaction-resolve (list :file file :json-path "outputs.spaces.value.region"))))
             (harness-redaction-test--error-message
              (lambda () (harness-redaction-resolve '(:literal "tiny"))))
             (harness-redaction-test--error-message
              (lambda () (harness-redaction-resolve '(:file "/nonexistent/x"))))
             (harness-redaction-test--error-message
              (lambda () (harness-redaction-resolve '(:nothing "x")))))))
      (dolist (message messages)
        (dolist (value values)
          (should-not (harness-redaction-test--holds-p message value))))
      (should (string-match-p "No value at JSON path outputs.nope" (nth 0 messages)))
      (should (string-match-p "selects no string" (nth 1 messages)))
      (should (string-match-p "Cannot read" (nth 2 messages)))
      (should (string-match-p "not valid JSON" (nth 3 messages)))
      (should (string-match-p "HARNESS_REDACTION_TEST_UNSET is not set" (nth 4 messages)))
      (should (string-match-p "command failed (exit status 3)" (nth 5 messages)))
      (should (string-match-p "printed nothing" (nth 6 messages)))
      ;; A value too short is skipped, and when none is left the error
      ;; names its label and fingerprint.
      (should (string-match-p (regexp-quote (format "outputs.spaces.value.region (sha256:%s)"
                                                    (harness-redaction-fingerprint "ams3")))
                              (nth 7 messages)))
      (should (string-match-p "shorter than 8 characters" (nth 7 messages)))
      (should (string-match-p "secret (sha256:" (nth 8 messages))))))

(ert-deftest harness-redaction-resolve-min-length-is-an-option ()
  (let ((harness-redaction-min-length 13))
    (let ((r (harness-redaction-resolve (list :literal harness-redaction-test--id))))
      (should (= 0 (plist-get r :skipped))))
    ;; 12 characters are too few now.
    (should-error (harness-redaction-resolve (list :literal harness-redaction-test--tag))
                  :type 'harness-error))
  (let ((harness-redaction-min-length 2))
    (should (= 1 (length (plist-get (harness-redaction-resolve '(:literal "ab")) :secrets))))))

(ert-deftest harness-redaction-resolve-orders-longest-first ()
  (harness-redaction-test--with-dir dir
    (let* ((file (harness-redaction-test--write
                  (expand-file-name "o.json" dir)
                  (json-serialize `((a . "abcdefgh") (b . "abcdefghijkl") (c . "abcdefghij")))))
           (values (mapcar (lambda (s) (plist-get s :value))
                           (plist-get (harness-redaction-resolve (list :file file :json-path "$")) :secrets))))
      (should (equal values '("abcdefghijkl" "abcdefghij" "abcdefgh"))))))

;;;; Shape

(ert-deftest harness-redaction-shape-lists-paths-and-types-never-values ()
  (harness-redaction-test--with-dir dir
    (let* ((file (harness-redaction-test--state dir))
           (all (harness-redaction-shape file)))
      (should (equal (car all) '(:path "$" :type "object")))
      (dolist (entry '((:path "outputs.spaces.value.access_key" :type "string")
                       (:path "outputs.spaces.value.port" :type "number")
                       (:path "outputs.spaces.value.tags" :type "array")
                       (:path "outputs.spaces.value.tags.0" :type "string")
                       (:path "outputs.spaces.sensitive" :type "boolean")
                       (:path "items.1.token" :type "string")
                       (:path "[\"weird.key\"].v" :type "string")
                       (:path "[\"0\"]" :type "string")))
        (should (member entry all)))
      ;; Not a value, nor a length, anywhere in what it says.
      (dolist (value (list harness-redaction-test--id harness-redaction-test--key
                           harness-redaction-test--tag "ams3" "short" "WEIRD-" "TOKEN-" "DIGITKEY-"))
        (should-not (harness-redaction-test--holds-p all value)))
      (should-not (harness-redaction-test--holds-p all ":length"))
      (dolist (entry all) (should (equal '(:path :type) (cl-loop for (k _) on entry by #'cddr collect k))))
      ;; Depth first: a node comes before the nodes under it, and its siblings after them.
      (should (< (cl-position '(:path "outputs" :type "object") all :test #'equal)
                 (cl-position '(:path "outputs.spaces" :type "object") all :test #'equal)
                 (cl-position '(:path "outputs.note" :type "object") all :test #'equal)
                 (cl-position '(:path "items" :type "array") all :test #'equal)))
      ;; The paths it gives are paths that resolve.
      (dolist (path '("items.1.token" "[\"weird.key\"].v" "[\"0\"]" "outputs.spaces.value.tags.0"))
        (should (= 1 (length (plist-get (harness-redaction-resolve (list :file file :json-path path))
                                        :secrets))))))))

(ert-deftest harness-redaction-shape-under-a-path ()
  (harness-redaction-test--with-dir dir
    (let* ((file (harness-redaction-test--state dir))
           (under (harness-redaction-shape file "outputs.spaces.value")))
      (should (equal (car under) '(:path "outputs.spaces.value" :type "object")))
      (should (member '(:path "outputs.spaces.value.secret_key" :type "string") under))
      (should-not (member '(:path "items" :type "array") under))
      (should-not (cl-find-if (lambda (e) (equal (plist-get e :type) "boolean")) under))
      ;; A wildcard shows each node it selects.
      (should (equal (harness-redaction-shape file "items.*")
                     '((:path "items.0" :type "object") (:path "items.0.token" :type "string")
                       (:path "items.1" :type "object") (:path "items.1.token" :type "string"))))
      (should-error (harness-redaction-shape file "nope") :type 'harness-error))))

(ert-deftest harness-redaction-shape-stops-at-a-thousand-entries ()
  (harness-redaction-test--with-dir dir
    (let* ((file (harness-redaction-test--write
                  (expand-file-name "big.json" dir)
                  (json-serialize (apply #'vector (number-sequence 1 1500)))))
           (entries (harness-redaction-shape file)))
      (should (= 1001 (length entries)))
      (should (equal (car (last entries)) '(:truncated t)))
      (should (equal (car entries) '(:path "$" :type "array")))
      (should (equal (nth 1000 entries) '(:truncated t)))
      ;; Exactly a thousand is not truncated.
      (let ((exact (harness-redaction-shape
                    (harness-redaction-test--write (expand-file-name "exact.json" dir)
                                                   (json-serialize (apply #'vector (number-sequence 1 999)))))))
        (should (= 1000 (length exact)))
        (should-not (plist-member (car (last exact)) :truncated))))))

;;;; Needles and replacements

(ert-deftest harness-redaction-needles-are-the-value-as-json-escapes-it ()
  (let* ((secret (harness-redaction-secret harness-redaction-test--key "k"))
         (needles (harness-redaction-needles secret)))
    ;; The value, then with the quote escaped, then with the slash escaped too.
    (should (equal needles
                   (list harness-redaction-test--key
                         (string-replace "\"" "\\\"" harness-redaction-test--key)
                         (string-replace "/" "\\/" (string-replace "\"" "\\\"" harness-redaction-test--key)))))
    ;; What JSON writes is what the escaped needle is.
    (should (equal (nth 1 needles)
                   (let ((json (harness-json-encode-text (list harness-redaction-test--key))))
                     (substring json 2 -2)))))
  ;; A value that needs no escape has the one needle.
  (should (equal (harness-redaction-needles (harness-redaction-secret harness-redaction-test--id "i"))
                 (list harness-redaction-test--id)))
  ;; A value with a slash alone has two.
  (should (equal (harness-redaction-needles (harness-redaction-secret "abcd/efgh" "i"))
                 '("abcd/efgh" "abcd\\/efgh")))
  ;; A newline is escaped, as JSON does it.
  (should (equal (harness-redaction-needles (harness-redaction-secret "line one\nline two" "i"))
                 '("line one\nline two" "line one\\nline two"))))

(ert-deftest harness-redaction-pairs-escape-the-placeholder-as-the-needle ()
  (let* ((secrets (list (harness-redaction-secret harness-redaction-test--key "a/b\"c")
                        (harness-redaction-secret harness-redaction-test--id "id")))
         (pairs (harness-redaction-pairs secrets))
         (placeholder (harness-redaction-placeholder (car secrets)))
         (escaped (string-replace "\"" "\\\"" placeholder)))
    ;; The longest needle first.
    (should (equal (mapcar (lambda (p) (length (car p))) pairs)
                   (sort (mapcar (lambda (p) (length (car p))) pairs) #'>)))
    (should (equal (cdr (assoc harness-redaction-test--key pairs)) placeholder))
    (should (equal (cdr (assoc (string-replace "\"" "\\\"" harness-redaction-test--key) pairs)) escaped))
    (should (equal (cdr (assoc (string-replace "/" "\\/" (string-replace "\"" "\\\"" harness-redaction-test--key))
                               pairs))
                   (string-replace "/" "\\/" escaped)))
    (should (equal (cdr (assoc harness-redaction-test--id pairs))
                   (harness-redaction-placeholder (cadr secrets))))
    ;; A needle two secrets share belongs to the first.
    (let ((again (harness-redaction-pairs
                  (list (harness-redaction-secret harness-redaction-test--id "first")
                        (harness-redaction-secret harness-redaction-test--id "second")))))
      (should (= 1 (length again)))
      (should (string-match-p "first" (cdar again))))
    (should (null (harness-redaction-pairs (list (list :value "" :label "x")))))))

;;;; Strings

(ert-deftest harness-redaction-count-counts-every-spelling-once-per-position ()
  (let* ((secrets (harness-redaction-test--secrets))
         (needles (harness-redaction-needles (car secrets)))
         (text (concat "a " harness-redaction-test--key " b " (nth 1 needles) " c " (nth 2 needles)
                       " d " harness-redaction-test--id)))
    (should (= 4 (harness-redaction-count text secrets)))
    (should (= 0 (harness-redaction-count "nothing" secrets)))
    (should (= 0 (harness-redaction-count text nil)))
    ;; A value inside a longer one counts only where it stands alone.
    (let ((nested (list (harness-redaction-secret "abcdefgh1234" "long")
                        (harness-redaction-secret "abcdefgh" "short"))))
      (should (= 2 (harness-redaction-count "abcdefgh1234 abcdefgh" nested)))
      (should (= 1 (harness-redaction-count "abcdefgh1234" nested)))
      (should (= 3 (harness-redaction-count "abcdefgh abcdefgh12 abcdefgh1234" nested))))))

(ert-deftest harness-redaction-string-replaces-raw-values ()
  (let* ((secrets (harness-redaction-test--secrets))
         (result (harness-redaction-string
                  (concat "k=" harness-redaction-test--key ", i=" harness-redaction-test--id
                          ", k=" harness-redaction-test--key)
                  secrets)))
    (should (= 3 (cdr result)))
    (should (equal (car result)
                   (format "k=%s, i=%s, k=%s" (harness-redaction-test--placeholder 0)
                           (harness-redaction-test--placeholder 1) (harness-redaction-test--placeholder 0))))
    ;; It is text, not JSON: an escaped spelling is not looked for.
    (let ((escaped (nth 1 (harness-redaction-needles (car secrets)))))
      (should (= 0 (cdr (harness-redaction-string escaped secrets)))))
    ;; Nothing found, the very string back.
    (let ((text (concat "nothing " "here")))
      (let ((same (harness-redaction-string text secrets)))
        (should (eq (car same) text))
        (should (= 0 (cdr same)))))
    ;; A placeholder is never searched, even for a value it spells.
    (let ((odd (list (harness-redaction-secret "redacted" "odd")))
          (count nil))
      (setq count (harness-redaction-string "the redacted word and redacted again" odd))
      (should (equal (car count)
                     (format "the %s word and %s again"
                             (harness-redaction-placeholder (car odd))
                             (harness-redaction-placeholder (car odd))))))))

;;;; Scanning

(defun harness-redaction-test--naive-hits (text needles)
  "Return where NEEDLES occur in TEXT, the plain way: (START END INDEX)...
At each position the longest needle that starts there wins (the first
of those of one length), and the scan goes on after it."
  (let ((sorted (sort (cl-loop for n in needles for i from 0 collect (cons n i))
                      (lambda (a b) (> (length (car a)) (length (car b))))))
        (pos 0) (hits nil))
    (while (< pos (length text))
      (let ((found (cl-find-if (lambda (c) (string-prefix-p (car c) (substring text pos))) sorted)))
        (if found
            (progn (push (list pos (+ pos (length (car found))) (cdr found)) hits)
                   (setq pos (+ pos (length (car found)))))
          (setq pos (1+ pos)))))
    (nreverse hits)))

(ert-deftest harness-redaction-scan-agrees-with-the-plain-way-on-random-text ()
  "The finder, with its cached positions, finds what a naive scan finds."
  (random "harness-redaction")
  (dotimes (_ 300)
    (let* ((alphabet "ab/\"")
           (word (lambda (min max)
                   (apply #'string (cl-loop repeat (+ min (random (1+ (- max min))))
                                            collect (aref alphabet (random (length alphabet)))))))
           (needles (cl-remove-duplicates
                     (cl-loop repeat (1+ (random 5)) collect (funcall word 1 5)) :test #'equal))
           (text (funcall word 0 60))
           (pairs (cl-loop for n in needles for i from 0 collect (cons n (format "<%d>" i))))
           (secrets (mapcar (lambda (n) (list :value n :label "x" :fingerprint "00000000")) needles))
           (expected (harness-redaction-test--naive-hits text needles))
           (hits (harness-redaction--string-hits
                  text (harness-redaction--sort-pairs pairs))))
      (should (equal (mapcar (lambda (h) (list (car h) (cadr h))) hits)
                     (mapcar (lambda (h) (list (nth 0 h) (nth 1 h))) expected)))
      ;; What replaces each is the pair of the needle it found.
      (should (equal (mapcar #'cddr hits)
                     (mapcar (lambda (h) (format "<%d>" (nth 2 h))) expected)))
      ;; The same holds in a buffer.
      (with-temp-buffer
        (insert text)
        (should (equal (mapcar (lambda (h) (list (1- (car h)) (1- (cadr h))))
                               (harness-redaction--buffer-hits (harness-redaction--sort-pairs pairs)))
                       (mapcar (lambda (h) (list (nth 0 h) (nth 1 h))) expected))))
      (ignore secrets))))

(ert-deftest harness-redaction-string-buffer-and-file-redact-alike ()
  (harness-redaction-test--with-dir dir
    (let* ((secrets (list (harness-redaction-secret "abcdefgh1234" "long")
                          (harness-redaction-secret "abcdefgh" "short")
                          (harness-redaction-secret "xyzxyzxyz" "rep")))
           (text (concat "abcdefgh abcdefgh1234 xyzxyzxyzxyzxyzxyz abcdefgh12 tail\n"))
           (expected (car (harness-redaction-string text secrets)))
           (file (harness-redaction-test--write (expand-file-name "t.txt" dir) text)))
      (should (= 5 (harness-redaction-count text secrets)))
      (harness-redaction-file file secrets)
      (should (equal (harness-redaction-test--read file) expected))
      (with-temp-buffer
        (insert text)
        (harness-redaction-buffer (current-buffer) secrets)
        (should (equal (buffer-string) expected)))
      (should (equal (car (harness-redaction-jsonl text secrets)) expected)))))

;;;; Lisp values

(ert-deftest harness-redaction-value-walks-conses-and-vectors ()
  (let* ((secrets (harness-redaction-test--secrets))
         (key harness-redaction-test--key)
         (id harness-redaction-test--id)
         (placeholder-key (harness-redaction-test--placeholder 0))
         (placeholder-id (harness-redaction-test--placeholder 1))
         (value (list :kind "tool-result"
                      :output (concat "got " key)
                      :meta (list :tags (list "a" (concat "id " id) "b"))
                      :pair (cons "name" (concat "dotted " key))
                      :alist (list (cons "k" (concat id "!")) (cons 'sym "plain"))
                      :vec (vector 1 "two" (concat "three " key))
                      :n 42))
         (result (harness-redaction-value value secrets))
         (new (car result)))
    (should (= 5 (cdr result)))
    (should (equal (plist-get new :output) (concat "got " placeholder-key)))
    (should (equal (plist-get (plist-get new :meta) :tags)
                   (list "a" (concat "id " placeholder-id) "b")))
    (should (equal (plist-get new :pair) (cons "name" (concat "dotted " placeholder-key))))
    (should (equal (plist-get new :alist)
                   (list (cons "k" (concat placeholder-id "!")) (cons 'sym "plain"))))
    (should (equal (plist-get new :vec) (vector 1 "two" (concat "three " placeholder-key))))
    (should (= 42 (plist-get new :n)))
    ;; Copy on write: the original keeps its secrets, what did not change is shared.
    (should (string-search key (plist-get value :output)))
    (should (eq (plist-get new :kind) (plist-get value :kind)))
    (should (eq (cdr (cadr (plist-get new :alist))) (cdr (cadr (plist-get value :alist)))))
    ;; The whole object is the same one when nothing changed.
    (let* ((plain (list :a "one" :b (vector "two" (cons "x" "y")) :c (list 1 2 3)))
           (same (harness-redaction-value plain secrets)))
      (should (eq (car same) plain))
      (should (= 0 (cdr same))))
    (let ((same (harness-redaction-value "plain" secrets)))
      (should (equal same '("plain" . 0))))
    (should (eq (car (harness-redaction-value nil secrets)) nil))
    (should (eq (car (harness-redaction-value 5 secrets)) 5))))

(ert-deftest harness-redaction-value-leaves-records-functions-and-hash-tables ()
  (let* ((secrets (harness-redaction-test--secrets))
         (key harness-redaction-test--key)
         (table (let ((h (make-hash-table :test 'equal))) (puthash "k" key h) h))
         (record (record 'harness-redaction-test-rec key))
         (fn (let ((captured key)) (lambda () captured)))
         (value (list table record fn (concat "in a list " key)))
         (result (harness-redaction-value value secrets)))
    (should (= 1 (cdr result)))
    (should (eq (nth 0 (car result)) table))
    (should (equal (gethash "k" table) key))
    (should (eq (nth 1 (car result)) record))
    (should (eq (nth 2 (car result)) fn))
    (should-not (string-search key (nth 3 (car result))))))

(ert-deftest harness-redaction-value-stops-at-the-depth-limit-and-survives-a-cycle ()
  (let* ((secrets (harness-redaction-test--secrets))
         (key harness-redaction-test--key)
         (nest (lambda (depth)
                 (let ((v (concat "deep " key)))
                   (dotimes (_ depth) (setq v (list v)))
                   v))))
    (should (= 1 (cdr (harness-redaction-value (funcall nest 50) secrets))))
    (let ((too-deep (funcall nest 150)))
      (should (= 0 (cdr (harness-redaction-value too-deep secrets))))
      (should (eq (car (harness-redaction-value too-deep secrets)) too-deep))))
  (let* ((secrets (harness-redaction-test--secrets))
         (circular (list (concat "one " harness-redaction-test--key) "two")))
    (setcdr (cdr circular) circular)
    (let ((result (harness-redaction-value circular secrets)))
      (should (eq (car result) circular))
      (should (= 0 (cdr result))))))

;;;; JSON lines

(defun harness-redaction-test--harness-line (&rest plist)
  "Return PLIST as a line of a node log."
  (harness-json-encode-text plist))

(defun harness-redaction-test--log ()
  "Return (TEXT . UNTOUCHED) for a log with the fake secrets in some lines.
UNTOUCHED are the lines without a secret, formatted as nothing in the
harness would write them, so that a line written again shows."
  (let* ((key harness-redaction-test--key)
         (id harness-redaction-test--id)
         (odd1 "{\"a\" :  1,\"b\":\"\\u00e9\"  ,\"c\":[1,  2]}")
         (odd2 "  {\"keep\":   \"as is\" }  ")
         (lines (list odd1
                      ;; The key in a result, and the id twice in a call.
                      (harness-redaction-test--harness-line
                       :id "n-1" :kind "tool-result" :output (concat "token " key " end")
                       :meta (list :duration 0.5 :denied :false))
                      (harness-redaction-test--harness-line
                       :id "n-2" :kind "tool-call" :tool "bash"
                       :input (list :command (concat "echo " id " " id)) :title "Run")
                      ;; A writer that escapes slashes.
                      (string-replace "/" "\\/" (harness-redaction-test--harness-line
                                                 :id "n-3" :kind "assistant" :content (concat "k: " key)))
                      odd2
                      ;; Not JSON at all, and JSON that was cut short.
                      (concat "plain text " key)
                      (concat "{\"id\": \"n-4\", \"output\": \"" key)
                      (harness-redaction-test--harness-line :id "n-5" :kind "user" :content "no secret here"))))
    (cons (concat (mapconcat #'identity lines "\n") "\n")
          (list odd1 odd2 (nth 7 lines)))))

(ert-deftest harness-redaction-jsonl-redacts-only-the-lines-that-hold-a-secret ()
  (let* ((secrets (harness-redaction-test--secrets))
         (log (harness-redaction-test--log))
         (text (car log))
         (result (harness-redaction-jsonl text secrets :style 'foreign))
         (new (car result))
         (lines (split-string new "\n"))
         (old-lines (split-string text "\n")))
    ;; The key is in lines 1, 3, 5 and 6, the id twice in line 2.
    (should (equal (cdr result) '(:count 6 :lines 5)))
    (should (= 0 (harness-redaction-count new secrets)))
    (should (string-suffix-p "\n" new))
    ;; Untouched lines are kept byte for byte, where they stand.
    (dolist (i '(0 4 7))
      (should (equal (nth i lines) (nth i old-lines))))
    (should (equal (cdr log) (list (nth 0 lines) (nth 4 lines) (nth 7 lines))))
    ;; A changed line is JSON still, with the placeholder in the place of the secret.
    (let ((line (json-parse-string (nth 1 lines) :object-type 'alist)))
      (should (equal (alist-get 'output line)
                     (concat "token " (harness-redaction-test--placeholder 0) " end")))
      (should (equal (alist-get 'id line) "n-1")))
    (let ((call (json-parse-string (nth 2 lines) :object-type 'alist)))
      (should (equal (alist-get 'command (alist-get 'input call))
                     (format "echo %s %s" (harness-redaction-test--placeholder 1)
                             (harness-redaction-test--placeholder 1)))))
    ;; The escaped slash is read as a slash, and written as one.
    (should (equal (alist-get 'content (json-parse-string (nth 3 lines) :object-type 'alist))
                   (concat "k: " (harness-redaction-test--placeholder 0))))
    ;; What does not parse has the secret replaced as text.
    (should (equal (nth 5 lines) (concat "plain text " (harness-redaction-test--placeholder 0))))
    (should (equal (nth 6 lines)
                   (concat "{\"id\": \"n-4\", \"output\": \"" (harness-redaction-test--placeholder 0))))))

(ert-deftest harness-redaction-jsonl-keeps-a-missing-final-newline-and-handles-carriage-returns ()
  (let* ((secrets (harness-redaction-test--secrets))
         (line (harness-redaction-test--harness-line :id "n-1" :content (concat "k " harness-redaction-test--id)))
         (result (harness-redaction-jsonl (concat "{\"x\":1}\r\n" line "\r\n" line) secrets)))
    (should (equal (cdr result) '(:count 2 :lines 2)))
    (let ((lines (split-string (car result) "\n")))
      (should (equal (nth 0 lines) "{\"x\":1}\r"))
      (should (string-suffix-p "\r" (nth 1 lines)))
      ;; No newline at the end before, none after.
      (should-not (string-suffix-p "\n" (car result)))
      (should (= 0 (harness-redaction-count (car result) secrets)))))
  (should (equal (harness-redaction-jsonl "" (harness-redaction-test--secrets))
                 '("" :count 0 :lines 0))))

(ert-deftest harness-redaction-jsonl-in-the-style-of-the-harness ()
  (let* ((secrets (harness-redaction-test--secrets))
         (key harness-redaction-test--key)
         (line (harness-redaction-test--harness-line
                :id "n-1" :kind "tool-result" :call-id "c1"
                :output (concat "key " key)
                :meta (list :duration 0.25 :denied :false :tags (list "x" "y"))))
         (result (harness-redaction-jsonl (concat line "\n") secrets :style 'harness))
         (parsed (harness-json-parse (car result))))
    (should (equal (cdr result) '(:count 1 :lines 1)))
    (should (equal (plist-get parsed :output) (concat "key " (harness-redaction-test--placeholder 0))))
    ;; The rest of the node reads as it did.
    (should (equal (plist-get parsed :meta) (list :duration 0.25 :denied :false :tags (list "x" "y"))))
    (should (equal (plist-get parsed :call-id) "c1"))))

(ert-deftest harness-redaction-jsonl-rewritten-lines-mean-what-they-meant ()
  "A line written again reads as it did, the secret apart, in either style."
  (let* ((secrets (harness-redaction-test--secrets))
         (escaped (nth 1 (harness-redaction-needles (car secrets))))
         (line (concat "{\"id\":\"n-9\",\"flags\":[false,true],\"empty\":{},\"list\":[],\"none\":null,"
                       "\"nested\":{\"a\":[1,2.5,{\"b\":null,\"c\":false}]},\"big\":12345678901234567890,"
                       "\"uni\":\"caf\\u00e9 \\ud83d\\ude00\",\"out\":\"k " escaped " and " harness-redaction-test--id "\"}")))
    (dolist (style '(harness foreign))
      (let* ((read (lambda (text)
                     (if (eq style 'harness)
                         (harness-json-parse text)
                       (json-parse-string text :object-type 'alist :array-type 'array
                                          :null-object :null :false-object :false))))
             (result (harness-redaction-jsonl (concat line "\n") secrets :style style))
             (new (string-trim-right (car result))))
        (should (equal (cdr result) '(:count 2 :lines 1)))
        (should (equal (funcall read new)
                       (car (harness-redaction-value (funcall read line) secrets))))
        (should (= 0 (harness-redaction-count new secrets)))))))

(ert-deftest harness-redaction-jsonl-keeps-a-line-it-cannot-write-again-as-it-means ()
  "A key twice in an object is lost by writing the object again: the line is cleaned as text."
  (let* ((secrets (harness-redaction-test--secrets))
         (line (concat "{\"a\":1,\"a\":2,\"out\":\"id " harness-redaction-test--id "\"}")))
    (dolist (style '(harness foreign))
      (let ((result (harness-redaction-jsonl (concat line "\n") secrets :style style)))
        (should (equal (cdr result) '(:count 1 :lines 1)))
        (should (equal (car result)
                       (concat "{\"a\":1,\"a\":2,\"out\":\"id " (harness-redaction-test--placeholder 1) "\"}\n")))))))

(ert-deftest harness-redaction-jsonl-calls-the-hook-for-each-changed-line-that-parsed ()
  (let* ((secrets (harness-redaction-test--secrets))
         (text (car (harness-redaction-test--log)))
         (seen nil))
    (harness-redaction-jsonl text secrets :style 'harness
                             :on-line (lambda (old new count) (push (list old new count) seen)))
    (setq seen (nreverse seen))
    ;; Three lines parsed and changed; the other two that changed did not parse.
    (should (= 3 (length seen)))
    (should (equal (mapcar (lambda (s) (plist-get (car s) :id)) seen) '("n-1" "n-2" "n-3")))
    (should (equal (mapcar #'caddr seen) '(1 2 1)))
    (let ((first (nth 0 seen)))
      (should (string-search harness-redaction-test--key (plist-get (nth 0 first) :output)))
      (should (equal (plist-get (nth 1 first) :output)
                     (concat "token " (harness-redaction-test--placeholder 0) " end")))
      (should (equal (plist-get (nth 1 first) :id) "n-1")))
    ;; In the foreign style the objects are alists.
    (let ((foreign nil))
      (harness-redaction-jsonl text secrets :on-line (lambda (old new count) (push (list old new count) foreign)))
      (should (= 3 (length foreign)))
      (should (string-search harness-redaction-test--key (alist-get 'output (car (car (last foreign))))))
      (should (equal (alist-get 'output (cadr (car (last foreign))))
                     (concat "token " (harness-redaction-test--placeholder 0) " end"))))))

(ert-deftest harness-redaction-jsonl-dry-run-counts-and-changes-nothing ()
  (let* ((secrets (harness-redaction-test--secrets))
         (text (car (harness-redaction-test--log)))
         (hooked 0)
         (dry (harness-redaction-jsonl text secrets :dry-run t :on-line (lambda (&rest _) (cl-incf hooked))))
         (real (harness-redaction-jsonl text secrets)))
    (should (eq (car dry) text))
    (should (equal (cdr dry) (cdr real)))
    (should (= 3 hooked))
    (should (equal (cdr dry) '(:count 6 :lines 5)))
    (should-error (harness-redaction-jsonl text secrets :style 'other) :type 'harness-error)))

(ert-deftest harness-redaction-jsonl-finds-a-secret-in-a-key ()
  (let* ((secrets (harness-redaction-test--secrets))
         (line (concat "{\"" harness-redaction-test--id "\":\"value\",\"n\":1}"))
         (result (harness-redaction-jsonl (concat line "\n") secrets)))
    (should (equal (cdr result) '(:count 1 :lines 1)))
    (should (equal (car result)
                   (format "{\"%s\":\"value\",\"n\":1}\n" (harness-redaction-test--placeholder 1))))))

;;;; Files

(ert-deftest harness-redaction-rewrite-file-is-atomic-and-keeps-the-modes ()
  (harness-redaction-test--with-dir dir
    (let ((file (harness-redaction-test--write (expand-file-name "log.txt" dir) "old")))
      (set-file-modes file #o640)
      (should (equal file (harness-redaction-rewrite-file file (concat "new " (string #xe9) "\n"))))
      (should (equal (harness-redaction-test--read file) (concat "new " (string #xe9) "\n")))
      (should (= #o640 (file-modes file)))
      ;; No temporary file is left beside it.
      (should (equal (directory-files dir nil "\\`[^.]\\|\\`\\.[^.]") '("log.txt")))
      (set-file-modes file #o600)
      (harness-redaction-rewrite-file file "again")
      (should (= #o600 (file-modes file))))))

(ert-deftest harness-redaction-rewrite-file-follows-a-link ()
  (harness-redaction-test--with-dir dir
    (let ((real (harness-redaction-test--write (expand-file-name "real.txt" dir) "old"))
          (link (expand-file-name "link.txt" dir)))
      (make-symbolic-link real link)
      (harness-redaction-rewrite-file link "new")
      (should (file-symlink-p link))
      (should (equal (harness-redaction-test--read real) "new")))))

(ert-deftest harness-redaction-rewrite-file-refuses-a-file-that-changed ()
  (harness-redaction-test--with-dir dir
    (let* ((file (harness-redaction-test--write (expand-file-name "log.txt" dir) "old"))
           (signature (harness-redaction--signature file)))
      ;; Unchanged since it was read, it is written.
      (harness-redaction-rewrite-file file "same" signature)
      (should (equal (harness-redaction-test--read file) "same"))
      ;; Someone appended since it was read: nothing is written, nothing is left over.
      (let ((read (harness-redaction--signature file)))
        (write-region "more" nil file t 'silent)
        (should-error (harness-redaction-rewrite-file file "lost" read) :type 'harness-redaction-changed)
        (should-error (harness-redaction-rewrite-file file "lost" read) :type 'harness-error))
      (should (equal (harness-redaction-test--read file) "samemore"))
      (should (equal (directory-files dir nil "\\`[^.]\\|\\`\\.[^.]") '("log.txt"))))))

(ert-deftest harness-redaction-file-count-sees-a-needle-across-every-chunk-boundary ()
  (harness-redaction-test--with-dir dir
    (let* ((secrets (harness-redaction-test--secrets))
           (escaped (nth 1 (harness-redaction-needles (car secrets))))
           (text (concat "..." harness-redaction-test--key "--" harness-redaction-test--key
                         "......." harness-redaction-test--id harness-redaction-test--id
                         "|" escaped "|tail"))
           (file (harness-redaction-test--write (expand-file-name "data.bin" dir) text)))
      (should (= 5 (harness-redaction-file-count file secrets)))
      (dolist (size '(1 2 3 5 7 16 33 64 4096))
        (let ((harness-redaction--chunk-size size))
          (should (= 5 (harness-redaction-file-count file secrets)))))
      (should (= 0 (harness-redaction-file-count (expand-file-name "missing" dir) secrets)))
      (should (= 0 (harness-redaction-file-count dir secrets)))
      (should (= 0 (harness-redaction-file-count file nil)))
      (should (= 0 (harness-redaction-file-count (harness-redaction-test--write
                                                  (expand-file-name "empty" dir) "")
                                                 secrets))))))

(ert-deftest harness-redaction-file-count-looks-for-utf-8-bytes-in-any-file ()
  (harness-redaction-test--with-dir dir
    (let* ((value (concat "caf" (string #xe9) "-secret-" (string #x20ac) "-value"))
           (secrets (list (harness-redaction-secret value "accents")))
           (file (expand-file-name "db.sqlite" dir)))
      ;; A binary file with the value's UTF-8 bytes in it, and a NUL.
      (harness-redaction-test--write-bytes
       file (concat "SQLite format 3\0\1\2" (encode-coding-string value 'utf-8) "\0\377"
                    (encode-coding-string value 'utf-8)))
      (should (= 2 (harness-redaction-file-count file secrets)))
      (let ((harness-redaction--chunk-size 4))
        (should (= 2 (harness-redaction-file-count file secrets)))))))

(ert-deftest harness-redaction-file-redacts-text-in-every-spelling ()
  (harness-redaction-test--with-dir dir
    (let* ((secrets (harness-redaction-test--secrets))
           (needles (harness-redaction-needles (car secrets)))
           (before (concat "line one\nraw " harness-redaction-test--key "\n"
                           "escaped " (nth 1 needles) "\nslashed " (nth 2 needles) "\n"
                           "id " harness-redaction-test--id " caf" (string #xe9) "\r\nlast"))
           (file (harness-redaction-test--write (expand-file-name "notes.txt" dir) before)))
      (set-file-modes file #o640)
      (let ((dry (harness-redaction-file file secrets :dry-run t)))
        (should (equal dry (list :file file :count 4 :changed nil)))
        (should (equal (harness-redaction-test--read file) before)))
      (should (equal (harness-redaction-file file secrets) (list :file file :count 4 :changed t)))
      (should (= #o640 (file-modes file)))
      (should (= 0 (harness-redaction-file-count file secrets)))
      (should (equal (harness-redaction-test--read file)
                     (format "line one\nraw %1$s\nescaped %1$s\nslashed %1$s\nid %2$s caf%3$c\r\nlast"
                             (harness-redaction-test--placeholder 0) (harness-redaction-test--placeholder 1) #xe9)))
      ;; Done, there is nothing more to do.
      (should (equal (harness-redaction-file file secrets) (list :file file :count 0 :changed nil))))))

(ert-deftest harness-redaction-file-redacts-json-lines-and-keeps-the-rest ()
  (harness-redaction-test--with-dir dir
    (let* ((secrets (harness-redaction-test--secrets))
           (log (harness-redaction-test--log))
           (file (harness-redaction-test--write (expand-file-name "session.jsonl" dir) (car log)))
           (hooked 0))
      (let ((result (harness-redaction-file file secrets :style 'jsonl
                                            :on-line (lambda (&rest _) (cl-incf hooked)))))
        (should (equal result (list :file file :count 6 :changed t)))
        (should (= 3 hooked)))
      (let ((lines (split-string (harness-redaction-test--read file) "\n")))
        (should (equal (list (nth 0 lines) (nth 4 lines) (nth 7 lines)) (cdr log))))
      (should (= 0 (harness-redaction-file-count file secrets))))))

(ert-deftest harness-redaction-file-redacts-a-json-document ()
  (harness-redaction-test--with-dir dir
    (let* ((secrets (harness-redaction-test--secrets))
           (doc (json-serialize `((outputs . ((keys . ((id . ,harness-redaction-test--id)
                                                       (key . ,harness-redaction-test--key)
                                                       (other . [1 :null ,(concat "x " harness-redaction-test--id)]))))))))
           (file (harness-redaction-test--write (expand-file-name "doc.json" dir) (concat doc "\n"))))
      (let ((result (harness-redaction-file file secrets :style 'json)))
        (should (equal result (list :file file :count 3 :changed t))))
      (let* ((text (harness-redaction-test--read file))
             (parsed (json-parse-string text :object-type 'alist :array-type 'array)))
        (should (string-suffix-p "\n" text))
        (should (= 0 (harness-redaction-count text secrets)))
        (should (equal (alist-get 'id (alist-get 'keys (alist-get 'outputs parsed)))
                       (harness-redaction-test--placeholder 1))))
      ;; A file that is no JSON is cleaned as text.
      (let ((plain (harness-redaction-test--write (expand-file-name "plain.txt" dir)
                                                  (concat "not json " harness-redaction-test--id "\n"))))
        (should (equal (harness-redaction-file plain secrets :style 'json)
                       (list :file plain :count 1 :changed t)))
        (should (equal (harness-redaction-test--read plain)
                       (concat "not json " (harness-redaction-test--placeholder 1) "\n")))))))

(ert-deftest harness-redaction-file-never-changes-a-binary-file ()
  (harness-redaction-test--with-dir dir
    (let* ((secrets (harness-redaction-test--secrets))
           (file (expand-file-name "search.db" dir)))
      (harness-redaction-test--write-bytes
       file (concat "SQLite format 3\0" harness-redaction-test--key "\0" harness-redaction-test--id "\377"))
      (let ((bytes (harness-redaction-test--bytes file)))
        (should (equal (harness-redaction-file file secrets)
                       (list :file file :count 2 :changed nil :binary t)))
        (should (equal (harness-redaction-file file secrets :style 'jsonl :dry-run t)
                       (list :file file :count 2 :changed nil :binary t)))
        (should (equal (harness-redaction-test--bytes file) bytes))))))

(ert-deftest harness-redaction-file-handles-a-missing-file-and-bad-arguments ()
  (harness-redaction-test--with-dir dir
    (let ((secrets (harness-redaction-test--secrets))
          (missing (expand-file-name "missing.log" dir)))
      (should (equal (harness-redaction-file missing secrets) (list :file missing :count 0 :changed nil)))
      (should-error (harness-redaction-file dir secrets) :type 'harness-error)
      (should-error (harness-redaction-file missing secrets :style 'other) :type 'harness-error))))

(ert-deftest harness-redaction-file-tries-again-when-the-file-changes-under-it ()
  (harness-redaction-test--with-dir dir
    (let* ((secrets (harness-redaction-test--secrets))
           (file (harness-redaction-test--write (expand-file-name "live.log" dir)
                                                (concat "a " harness-redaction-test--id "\n")))
           (appended nil))
      ;; The first time through, something appends after the file was read.
      (cl-letf* ((original (symbol-function 'harness-redaction-rewrite-file))
                 ((symbol-function 'harness-redaction-rewrite-file)
                  (lambda (path text &optional expect)
                    (unless appended
                      (setq appended t)
                      (with-temp-buffer
                        (insert "b " harness-redaction-test--id "\n")
                        (write-region nil nil path t 'silent)))
                    (funcall original path text expect))))
        (should (equal (harness-redaction-file file secrets) (list :file file :count 2 :changed t))))
      (should (= 0 (harness-redaction-file-count file secrets)))
      (should (= 2 (cl-count ?\n (harness-redaction-test--read file)))))))

;;;; More files

(ert-deftest harness-redaction-file-keeps-what-is-not-text-as-it-was ()
  "Bytes that are no UTF-8, a byte order mark and carriage returns survive."
  (harness-redaction-test--with-dir dir
    (let* ((secrets (harness-redaction-test--secrets))
           (before (concat "\357\273\277" "bom line\r\n" "latin \351 and \377\376 bytes\r\n"
                           "key " harness-redaction-test--id "\r\n" "tail"))
           (file (harness-redaction-test--write-bytes (expand-file-name "odd.txt" dir) before)))
      (should (equal (harness-redaction-file file secrets) (list :file file :count 1 :changed t)))
      (should (equal (harness-redaction-test--bytes file)
                     (string-replace harness-redaction-test--id (harness-redaction-test--placeholder 1)
                                     before))))))

(ert-deftest harness-redaction-file-redacts-a-secret-of-several-lines ()
  (harness-redaction-test--with-dir dir
    (let* ((pem (concat "-----BEGIN FAKE KEY-----\nabcdefghijklmnop\nqrstuvwxyz012345\n-----END FAKE KEY-----"))
           (secrets (list (harness-redaction-secret pem "pem")))
           (line (harness-redaction-test--harness-line :id "n-1" :output (concat "here:\n" pem "\nthere")))
           (jsonl (harness-redaction-test--write (expand-file-name "pem.jsonl" dir) (concat line "\n")))
           (text (harness-redaction-test--write (expand-file-name "pem.txt" dir) (concat "before\n" pem "\nafter\n"))))
      ;; In JSON the newlines are \n, so the escaped needle is on one line.
      (should (string-search "\\n" line))
      (should-not (string-search pem line))
      (should (equal (harness-redaction-file jsonl secrets :style 'jsonl) (list :file jsonl :count 1 :changed t)))
      (should (equal (alist-get 'output (json-parse-string (string-trim (harness-redaction-test--read jsonl))
                                                           :object-type 'alist))
                     (format "here:\n%s\nthere" (harness-redaction-placeholder (car secrets)))))
      (should (equal (harness-redaction-file text secrets) (list :file text :count 1 :changed t)))
      (should (equal (harness-redaction-test--read text)
                     (format "before\n%s\nafter\n" (harness-redaction-placeholder (car secrets)))))
      (should (= 0 (harness-redaction-file-count jsonl secrets)))
      (should (= 0 (harness-redaction-file-count text secrets))))))

(ert-deftest harness-redaction-file-json-style-of-the-harness ()
  (harness-redaction-test--with-dir dir
    (let* ((secrets (harness-redaction-test--secrets))
           (line (harness-redaction-test--harness-line :id "n-1" :kind "tool-result"
                                                       :output (concat "k " harness-redaction-test--key)
                                                       :meta (list :tags nil)))
           (file (harness-redaction-test--write (expand-file-name "n.jsonl" dir) (concat line "\n")))
           (seen nil))
      (harness-redaction-file file secrets :style 'jsonl :json-style 'harness
                              :on-line (lambda (old _new _count) (push (plist-get old :id) seen)))
      (should (equal seen '("n-1")))
      (should (equal (plist-get (harness-json-parse (harness-redaction-test--read file)) :output)
                     (concat "k " (harness-redaction-test--placeholder 0))))
      (should-error (harness-redaction-file file secrets :json-style 'other) :type 'harness-error))))

(ert-deftest harness-redaction-file-and-file-count-follow-a-link ()
  (harness-redaction-test--with-dir dir
    (let* ((secrets (harness-redaction-test--secrets))
           (real (harness-redaction-test--write
                  (expand-file-name "real.log" dir)
                  (concat "id " harness-redaction-test--id " and " harness-redaction-test--id "\n")))
           (link (expand-file-name "link.log" dir)))
      (make-symbolic-link real link)
      ;; The size of the link itself is the length of its target's name.
      (should (= 2 (harness-redaction-file-count link secrets)))
      (should (equal (harness-redaction-file link secrets) (list :file link :count 2 :changed t)))
      (should (file-symlink-p link))
      (should (= 0 (harness-redaction-file-count real secrets)))
      (should (string-search "[redacted: spaces id" (harness-redaction-test--read real))))))

(ert-deftest harness-redaction-file-refuses-a-text-file-too-large-for-memory ()
  (harness-redaction-test--with-dir dir
    (let* ((secrets (harness-redaction-test--secrets))
           (file (harness-redaction-test--write (expand-file-name "big.txt" dir)
                                                (concat "key " harness-redaction-test--id "\n"))))
      (let ((harness-redaction--max-file-size 4))
        (should-error (harness-redaction-file file secrets) :type 'harness-error)
        (should-error (harness-redaction-file file secrets :dry-run t) :type 'harness-error))
      ;; Not touched, and counted all the same when it is counted as bytes.
      (should (= 1 (harness-redaction-file-count file secrets)))
      (should (string-search harness-redaction-test--id (harness-redaction-test--read file))))))

;;;; Buffers

(ert-deftest harness-redaction-buffer-replaces-in-a-read-only-buffer ()
  (let ((secrets (harness-redaction-test--secrets))
        (buffer (generate-new-buffer " *redaction test*")))
    (unwind-protect
        (with-current-buffer buffer
          (insert (propertize (concat "key " harness-redaction-test--key) 'face 'bold)
                  "\nplain " harness-redaction-test--id "\n")
          (put-text-property (point-min) (+ (point-min) 3) 'read-only t)
          (setq buffer-read-only t)
          (goto-char (point-max))
          (let ((before (buffer-string)))
            (should (= 2 (harness-redaction-buffer buffer secrets t)))
            (should (equal (buffer-string) before)))
          (should (= 2 (harness-redaction-buffer buffer secrets)))
          (should (equal (buffer-substring-no-properties (point-min) (point-max))
                         (format "key %s\nplain %s\n" (harness-redaction-test--placeholder 0)
                                 (harness-redaction-test--placeholder 1))))
          ;; The placeholder keeps the look of the text it replaced.
          (should (eq 'bold (get-text-property (+ (point-min) 5) 'face)))
          (should buffer-read-only)
          (should (= (point) (point-max)))
          (should (= 0 (harness-redaction-buffer buffer secrets))))
      (kill-buffer buffer))))

(ert-deftest harness-redaction-buffer-forgets-the-undo-history-that-holds-a-secret ()
  (let ((secrets (harness-redaction-test--secrets))
        (buffer (generate-new-buffer "*redaction undo test*")))
    (unwind-protect
        (with-current-buffer buffer
          (buffer-enable-undo)
          (insert "one " harness-redaction-test--key " two\n")
          (undo-boundary)
          (delete-region 1 5)
          (undo-boundary)
          (erase-buffer)
          (insert "kept " harness-redaction-test--id)
          ;; The history holds what was erased, secret and all.
          (should (harness-redaction-test--holds-p buffer-undo-list harness-redaction-test--key))
          (should (= 1 (harness-redaction-buffer buffer secrets)))
          (should-not (harness-redaction-test--holds-p buffer-undo-list harness-redaction-test--key))
          (should-not (harness-redaction-test--holds-p buffer-undo-list harness-redaction-test--id))
          (should-not (eq buffer-undo-list t)))
      (kill-buffer buffer))))

(ert-deftest harness-redaction-buffer-ignores-narrowing ()
  (let ((secrets (harness-redaction-test--secrets)))
    (with-temp-buffer
      (insert "head " harness-redaction-test--id "\nbody " harness-redaction-test--id "\n")
      (narrow-to-region 1 5)
      (should (= 2 (harness-redaction-buffer (current-buffer) secrets)))
      (should (= 1 (point-min)))
      (should (= 5 (point-max)))
      (widen)
      (should (= 0 (harness-redaction-count (buffer-string) secrets))))))

;;;; The module

(ert-deftest harness-redaction-secrets-shape-method-answers-without-a-value ()
  (harness-test-reset-bus)
  (harness-test-load-module 'store)
  (harness-test-load-module 'secrets)
  (should (harness-module-ready-p 'secrets))
  (harness-redaction-test--with-dir dir
    (let* ((file (harness-redaction-test--state dir))
           (answer (harness-call 'secrets/shape file)))
      (should (equal (plist-get answer :file) (expand-file-name file)))
      (should (vectorp (plist-get answer :paths)))
      (should-not (plist-get answer :truncated))
      (should (member '(:path "outputs.spaces.value.access_key" :type "string")
                      (append (plist-get answer :paths) nil)))
      (dolist (value (list harness-redaction-test--id harness-redaction-test--key harness-redaction-test--tag))
        (should-not (harness-redaction-test--holds-p answer value)))
      ;; Under a path, and over the wire as JSON.
      (let ((under (harness-call 'secrets/shape file "outputs.spaces.value.tags")))
        (should (equal (append (plist-get under :paths) nil)
                       '((:path "outputs.spaces.value.tags" :type "array")
                         (:path "outputs.spaces.value.tags.0" :type "string"))))
        (should (equal (harness-json-parse (harness-json-encode under))
                       (list :file (expand-file-name file)
                             :paths (list (list :path "outputs.spaces.value.tags" :type "array")
                                          (list :path "outputs.spaces.value.tags.0" :type "string"))
                             :truncated nil))))
      (let ((big (harness-redaction-test--write (expand-file-name "big.json" dir)
                                                (json-serialize (apply #'vector (number-sequence 1 1200))))))
        (let ((cut (harness-call 'secrets/shape big)))
          (should (= 1000 (length (plist-get cut :paths))))
          (should (eq t (plist-get cut :truncated)))))
      (should-error (harness-call 'secrets/shape (expand-file-name "missing.json" dir)) :type 'harness-error))))

(provide 'harness-redaction-test)
;;; harness-redaction-test.el ends here
