;;; harness-perms-test.el --- Tests for permissions and auto mode -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Noah Huppert

;; This file is not part of GNU Emacs.

;;; Code:

(require 'ert)
(require 'harness-perms)
(require 'harness-mock-provider)
(require 'harness-test-util)

(defun harness-perms-test--call (name args &optional session)
  "Build a tool call for NAME with ARGS."
  (let ((call (harness-tool-call-create
               :name name :args-string (harness-json-write args))))
    (harness-tool-call-parse-args call)
    (ignore session)
    call))

(defmacro harness-perms-test-with-session (&rest body)
  "Run BODY with a live `session'."
  (declare (indent 0))
  `(harness-test-with-temp-session-dir
     (let ((session (harness-session-create '(:name "perms" :model "mock-model"))))
       ,@body)))

(ert-deftest harness-perms-test-default-policy ()
  "The default policy allows reads and asks about execution and edits."
  (harness-perms-test-with-session
    (let ((harness-permission-policy '((:category read :action allow)
                                       (:tool "bash" :action ask)
                                       (:default ask)))
          (harness-permission-rules nil))
      (should (eq (harness-permission-check
                   (harness-perms-test--call "read" '(:file_path "x")) session)
                  'allow))
      (should (eq (harness-permission-check
                   (harness-perms-test--call "bash" '(:command "ls")) session)
                  'ask)))))

(ert-deftest harness-perms-test-first-rule-wins ()
  "Rules are tried in order."
  (harness-perms-test-with-session
    (let ((harness-permission-rules nil)
          (harness-permission-policy '((:tool "bash" :match "\\`git " :action allow)
                                       (:tool "bash" :action deny)
                                       (:default ask))))
      (should (eq (harness-permission-check
                   (harness-perms-test--call "bash" '(:command "git status")) session)
                  'allow))
      (should (eq (harness-permission-check
                   (harness-perms-test--call "bash" '(:command "rm -rf /")) session)
                  'deny)))))

(ert-deftest harness-perms-test-subject ()
  "The subject is the command for bash and the path for edits."
  (should (equal (harness-perms-subject
                  (harness-perms-test--call "bash" '(:command "ls -la")))
                 "ls -la"))
  (should (equal (harness-perms-subject
                  (harness-perms-test--call "edit" '(:file_path "src/a.el" :old_string "a"
                                                     :new_string "b")))
                 "src/a.el"))
  (should (equal (harness-perms-subject
                  (harness-perms-test--call "todo" '(:todos (vector))))
                 "todo")))

(ert-deftest harness-perms-test-remember-pins-subject ()
  "Remembered rules allow only the exact command they were created for."
  (harness-perms-test-with-session
    (let ((harness-permission-rules nil)
          (harness-permission-rules-file nil)
          (harness-permission-policy '((:default ask))))
      (harness-perms-remember
       (harness-perms-test--call "bash" '(:command "npm test")) session)
      (should (eq (harness-permission-check
                   (harness-perms-test--call "bash" '(:command "npm test")) session)
                  'allow))
      (should (eq (harness-permission-check
                   (harness-perms-test--call "bash" '(:command "npm publish")) session)
                  'ask))
      ;; Remembered rules can be persisted and reloaded.
      (let ((file (make-temp-file "perms" nil ".json"))
            (harness-permission-rules-file nil))
        (setq harness-permission-rules-file file)
        (harness-permission-rules-save)
        (setq harness-permission-rules nil)
        (harness-permission-rules-load)
        (should (= (length harness-permission-rules) 1))
        (should (equal (harness-plist-or-alist-get :tool (car harness-permission-rules))
                       "bash"))
        (delete-file file)))))

(ert-deftest harness-perms-test-deny-path ()
  "A denied call reports the reason to the callback."
  (harness-perms-test-with-session
    (let ((harness-permission-rules nil)
          (harness-permission-policy '((:default deny)))
          (seen nil))
      (harness-perms-authorize (harness-perms-test--call "bash" '(:command "x")) session
                               (lambda (allowed reason remember)
                                 (setq seen (list allowed reason remember))))
      (should (equal (car seen) nil))
      (should (string-match-p "denied" (cadr seen))))))

(ert-deftest harness-perms-test-tool-approval-allow-skips-asking ()
  "A tool whose `:approval' is `allow' never consults the policy."
  (harness-perms-test-with-session
    (let ((harness-permission-rules nil)
          (harness-permission-policy '((:default ask)))
          (seen nil))
      (harness-perms-authorize (harness-perms-test--call "read" '(:file_path "x")) session
                               (lambda (allowed _reason _remember)
                                 (setq seen allowed)))
      (should seen)
      (should-not (harness-session-approvals session)))))

(ert-deftest harness-perms-test-parse-decision ()
  "Classifier answers are read leniently."
  (should (eq (harness-perms--parse-decision "allow") 'allow))
  (should (eq (harness-perms--parse-decision "Allow.") 'allow))
  (should (eq (harness-perms--parse-decision "DENY") 'deny))
  (should (eq (harness-perms--parse-decision "ask") 'ask))
  (should (eq (harness-perms--parse-decision "I am not sure") 'ask))
  (should (eq (harness-perms--parse-decision "") 'ask)))

(ert-deftest harness-perms-test-auto-mode-allows ()
  "In auto mode the classifier decides, and its answer is believed."
  (harness-test-with-temp-session-dir
    (let* ((harness-providers '((:name mock :kind harness-test
                                 :script ((:text "allow")))))
           (harness-models '((:provider mock :id "cheap-model")))
           (harness-auto-mode t)
           (harness-auto-mode-model "cheap-model")
           (harness-permission-rules nil)
           (harness-permission-policy '((:default ask)))
           (session (harness-session-create '(:name "auto" :model "mock-model"
                                                     :provider mock)))
           (seen nil))
      (harness-provider-setup)
      (harness-perms-authorize
       (harness-perms-test--call "bash" '(:command "ls")) session
       (lambda (allowed reason _remember) (setq seen (list allowed reason))))
      (should (harness-test-wait-for (lambda () seen) 10))
      (should (car seen))
      (should (string-match-p "auto mode" (cadr seen)))
      (should-not (harness-session-approvals session))
      (let ((request (car (harness-test-provider-requests (harness-provider-default)))))
        (should (equal (harness-provider-request-model request) "cheap-model"))
        (should (string-match-p "security gate"
                                (harness-provider-request-system request)))))))

(ert-deftest harness-perms-test-auto-mode-denies ()
  "A denial from the classifier becomes a denial for the tool call."
  (harness-test-with-temp-session-dir
    (let* ((harness-providers '((:name mock :kind harness-test
                                 :script ((:text "deny")))))
           (harness-models '((:provider mock :id "cheap-model")))
           (harness-auto-mode t)
           (harness-auto-mode-model "cheap-model")
           (harness-permission-rules nil)
           (harness-permission-policy '((:default ask)))
           (session (harness-session-create '(:name "auto-deny" :model "mock-model"
                                                        :provider mock)))
           (seen nil))
      (harness-provider-setup)
      (harness-perms-authorize
       (harness-perms-test--call "bash" '(:command "rm -rf /")) session
       (lambda (allowed reason _remember) (setq seen (list allowed reason))))
      (should (harness-test-wait-for (lambda () seen) 10))
      (should-not (car seen))
      (should (string-match-p "auto mode" (cadr seen))))))

(ert-deftest harness-perms-test-auto-mode-ask-falls-back ()
  "When the classifier is unsure the user is asked."
  (harness-test-with-temp-session-dir
    (let* ((harness-providers '((:name mock :kind harness-test
                                 :script ((:text "ask")))))
           (harness-models '((:provider mock :id "cheap-model")))
           (harness-auto-mode t)
           (harness-auto-mode-model "cheap-model")
           (harness-permission-rules nil)
           (harness-permission-policy '((:default ask)))
           (session (harness-session-create '(:name "auto-ask" :model "mock-model"
                                                       :provider mock))))
      (harness-provider-setup)
      (harness-perms-authorize (harness-perms-test--call "bash" '(:command "cat x")) session
                               (lambda (&rest _) nil))
      (should (harness-test-wait-for
               (lambda () (harness-session-approvals session)) 10))
      (should (eq (harness-session-status session) 'awaiting-approval))
      ;; Answering resumes the callback.
      (let ((resolved nil))
        (setf (harness-approval-callback (car (harness-session-approvals session)))
              (lambda (decision) (setq resolved decision)))
        (harness-perms-resolve (car (harness-session-approvals session)) 'deny)
        (should (eq resolved 'deny))))))

(ert-deftest harness-perms-test-classifier-failure-asks ()
  "A broken classifier degrades to asking, never to allowing."
  (harness-test-with-temp-session-dir
    (let* ((harness-providers '((:name mock :kind harness-test
                                 :script ((:error "model down")))))
           (harness-models '((:provider mock :id "cheap-model")))
           (harness-auto-mode t)
           (harness-auto-mode-model "cheap-model")
           (harness-permission-rules nil)
           (harness-permission-policy '((:default ask)))
           (session (harness-session-create '(:name "auto-fail" :model "mock-model"
                                                        :provider mock))))
      (harness-provider-setup)
      (harness-perms-authorize (harness-perms-test--call "bash" '(:command "ls")) session
                               (lambda (&rest _) nil))
      (should (harness-test-wait-for
               (lambda () (harness-session-approvals session)) 10)))))

(provide 'harness-perms-test)
;;; harness-perms-test.el ends here
