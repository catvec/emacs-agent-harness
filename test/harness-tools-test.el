;;; harness-tools-test.el --- Tests for the tool registry -*- lexical-binding: t; -*-

;;; Commentary:

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'harness-core)
(require 'harness-tools)
(require 'harness-test-helpers)

(harness-module-load 'harness-tools)

(add-to-list 'load-path
             (expand-file-name "fixtures" (file-name-directory (or load-file-name buffer-file-name))))

(defun harness-tools-test--reset ()
  "Remove every registered tool."
  (clrhash harness-tools--registry))

(defvar harness-tools-test--called nil)

(defun harness-tools-test--register-simple (&rest properties)
  "Register a tool called \"test-tool\" with PROPERTIES."
  (harness-tool-register
   "test-tool"
   :description "A test tool."
   :schema '(:type "object"
             :properties (:text (:type "string")
                                :count (:type "integer")
                                :flag (:type "boolean")
                                :items (:type "array"))
             :required ["text"])
   :module 'harness-tools-test
   :kind 'read
   :read-only t
   :handler (lambda (arguments _context)
              (setq harness-tools-test--called arguments)
              (or (plist-get properties :handler-result) "ok"))
   properties))

(defun harness-tools-test--run (name arguments &optional context)
  "Execute NAME with ARGUMENTS and return the settled result."
  (let ((deferred (harness-tools-execute name arguments context)))
    (harness-test-settle deferred)
    (harness-deferred-value deferred)))

(ert-deftest harness-tools-register-and-list ()
  (harness-tools-test--reset)
  (harness-tools-test--register-simple)
  (should (harness-tool-get "test-tool"))
  (should (equal (harness-tool-name (harness-tool-get "test-tool")) "test-tool"))
  (should (member "test-tool" (mapcar #'harness-tool-name (harness-tool-list))))
  (harness-tool-unregister "test-tool")
  (should-not (harness-tool-get "test-tool")))

(ert-deftest harness-tools-specs-shape ()
  (harness-tools-test--reset)
  (harness-tools-test--register-simple)
  (let* ((specs (harness-tools-specs))
         (spec (aref specs 0)))
    (should (vectorp specs))
    (should (equal (plist-get spec :name) "test-tool"))
    (should (equal (plist-get spec :description) "A test tool."))
    (should (equal (plist-get (plist-get spec :input-schema) :type) "object")))
  ;; Tools without a schema get an empty object schema.
  (harness-tool-register "bare" :description "Bare." :module 'harness-tools-test
                         :handler #'ignore)
  (let ((spec (seq-find (lambda (spec) (equal (plist-get spec :name) "bare"))
                        (append (harness-tools-specs) nil))))
    (should (equal (plist-get (plist-get spec :input-schema) :type) "object"))))

(ert-deftest harness-tools-validation ()
  (harness-tools-test--reset)
  (harness-tools-test--register-simple)
  (let ((tool (harness-tool-get "test-tool")))
    (should-not (harness-tools-validate tool '(:text "hi" :count 3)))
    (should (harness-tools-validate tool '(:count 3)))
    (should (harness-tools-validate tool '(:text 3)))
    (should (harness-tools-validate tool '(:text "hi" :count "3")))
    (should (harness-tools-validate tool '(:text "hi" :flag "yes")))
    (should (harness-tools-validate tool '(:text "hi" :items "no")))
    (should (equal (harness-tools-validate tool nil)
                   '("Missing required argument `text'.")))))

(ert-deftest harness-tools-execute-validates-before-calling ()
  (harness-tools-test--reset)
  (setq harness-tools-test--called nil)
  (harness-tools-test--register-simple)
  (let ((result (harness-tools-test--run "test-tool" nil)))
    (should (plist-get result :is-error))
    (should-not harness-tools-test--called)
    (should (string-match-p "Missing required argument" (harness-tools--text-of (plist-get result :content))))))

(ert-deftest harness-tools-execute-string-result ()
  (harness-tools-test--reset)
  (harness-tools-test--register-simple)
  (let ((result (harness-tools-test--run "test-tool" '(:text "hi"))))
    (should-not (plist-get result :is-error))
    (should (equal (harness-tools--text-of (plist-get result :content)) "ok"))
    (should (equal harness-tools-test--called '(:text "hi")))))

(ert-deftest harness-tools-execute-deferred-result ()
  (harness-tools-test--reset)
  (harness-tool-register
   "slow" :description "Slow." :module 'harness-tools-test
   :handler (lambda (_arguments _context)
              (let ((deferred (harness-deferred-new)))
                (run-at-time 0.01 nil (lambda () (harness-deferred-resolve deferred "late")))
                deferred)))
  (let ((result (harness-tools-test--run "slow" nil)))
    (should (equal (harness-tools--text-of (plist-get result :content)) "late"))))

(ert-deftest harness-tools-execute-handler-error ()
  (harness-tools-test--reset)
  (harness-tool-register
   "boom" :description "Boom." :module 'harness-tools-test
   :handler (lambda (_arguments _context) (error "kaboom")))
  (let ((result (harness-tools-test--run "boom" nil)))
    (should (plist-get result :is-error))
    (should (string-match-p "kaboom" (harness-tools--text-of (plist-get result :content))))))

(ert-deftest harness-tools-execute-deferred-rejection ()
  (harness-tools-test--reset)
  (harness-tool-register
   "reject" :description "Reject." :module 'harness-tools-test
   :handler (lambda (_arguments _context)
              (let ((deferred (harness-deferred-new)))
                (harness-deferred-reject deferred '(harness-tool-error "nope"))
                deferred)))
  (let ((result (harness-tools-test--run "reject" nil)))
    (should (plist-get result :is-error))))

(ert-deftest harness-tools-execute-unknown ()
  (harness-tools-test--reset)
  (let ((result (harness-tools-test--run "no-such-tool" nil)))
    (should (plist-get result :is-error))
    (should (string-match-p "No such tool" (harness-tools--text-of (plist-get result :content))))))

(ert-deftest harness-tools-context-bomb-refuses-when-ranges-exist ()
  (harness-tools-test--reset)
  (let ((harness-tools-max-output-bytes 100))
    (harness-tool-register
     "paged" :description "Paged." :module 'harness-tools-test
     :range-params '("offset" "limit")
     :handler (lambda (_arguments _context) (make-string 500 ?x)))
    (let* ((result (harness-tools-test--run "paged" nil))
           (text (harness-tools--text-of (plist-get result :content))))
      (should (plist-get result :truncated))
      (should (string-match-p "offset, limit" text))
      (should-not (string-match-p "xxxxx" text)))))

(ert-deftest harness-tools-context-bomb-truncates-without-ranges ()
  (harness-tools-test--reset)
  (let ((harness-tools-max-output-bytes 100)
        (harness-tools-truncated-bytes 20))
    (harness-tool-register
     "dump" :description "Dump." :module 'harness-tools-test
     :handler (lambda (_arguments _context) (make-string 500 ?x)))
    (let* ((result (harness-tools-test--run "dump" nil))
           (text (harness-tools--text-of (plist-get result :content))))
      (should (plist-get result :truncated))
      (should (string-match-p "output truncated" text))
      (should (= (length (car (split-string text "\n"))) 20)))))

(ert-deftest harness-tools-context-bomb-respects-unbounded ()
  (harness-tools-test--reset)
  (let ((harness-tools-max-output-bytes 100))
    (harness-tool-register
     "wide" :description "Wide." :module 'harness-tools-test
     :unbounded t
     :handler (lambda (_arguments _context) (make-string 500 ?x)))
    (let ((result (harness-tools-test--run "wide" nil)))
      (should-not (plist-get result :truncated))
      (should (= (length (harness-tools--text-of (plist-get result :content))) 500)))))

(ert-deftest harness-tools-context-helpers ()
  (let* ((abort (harness-deferred-new))
         (context (harness-tool-context-create
                   :session-id "s1" :cwd "/tmp/project" :abort abort))
         (cancelled nil))
    (should (equal (harness-tool-context-path context "src/main.el")
                   "/tmp/project/src/main.el"))
    (should-not (harness-tool-context-cancelled-p context))
    (harness-tool-context-on-cancel context (lambda () (setq cancelled t)))
    (harness-deferred-cancel abort)
    (should cancelled)
    (should (harness-tool-context-cancelled-p context))))

(ert-deftest harness-tools-module-cleanup ()
  (harness-module-load 'harness-fixture-tools)
  (should (harness-tool-get "fixture-echo"))
  (harness-module-unload 'harness-fixture-tools)
  (should-not (harness-tool-get "fixture-echo")))

(ert-deftest harness-tools-service-surface ()
  (harness-tools-test--reset)
  (harness-tools-test--register-simple)
  (should (vectorp (harness-service-call "tool" 'list)))
  (should (vectorp (harness-service-call "tool" 'specs)))
  (let ((declaration (harness-service-call "tool" 'get :name "test-tool")))
    (should (equal (plist-get declaration :name) "test-tool"))
    (should (equal (plist-get declaration :kind) "read")))
  (let* ((deferred (harness-service-call "tool" 'execute
                                         :name "test-tool"
                                         :arguments '(:text "svc")
                                         :session-id "s1"
                                         :cwd "/tmp"))
         (result (progn (harness-test-settle deferred) (harness-deferred-value deferred))))
    (should-not (plist-get result :is-error))
    (should (equal harness-tools-test--called '(:text "svc")))))

(ert-deftest harness-tools-service-keeps-the-callers-context ()
  ;; The agent executes tools through the service; rebuilding the context
  ;; there silently dropped the session id that session-aware tools need.
  (harness-tool-register "context-probe"
                         :description "Records the context it received."
                         :schema '(:type "object" :properties (:x (:type "string")))
                         :kind 'read :read-only t :module 'harness-tools-test
                         :handler (lambda (_arguments context)
                                    (let ((deferred (harness-deferred-new)))
                                      (harness-deferred-resolve
                                       deferred (harness-tool-context-session-id context))
                                      deferred)))
  (unwind-protect
      (let* ((context (harness-tool-context-create :session-id "session-7" :cwd "/tmp"))
             (deferred (harness-service-call "tool" 'execute
                                             :name "context-probe"
                                             :arguments '(:x "1")
                                             :context context)))
        (harness-test-settle deferred 5)
        (should (equal (harness-tools--text-of
                        (plist-get (harness-deferred-value deferred) :content))
                       "session-7")))
    (harness-tool-unregister "context-probe")))

(provide 'harness-tools-test)
;;; harness-tools-test.el ends here
