;;; harness-ui-ask-test.el --- Tests for approval and question panels -*- lexical-binding: t; -*-

;;; Commentary:

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'harness)
(require 'harness-core)
(require 'harness-ui)
(require 'harness-ui-ask)
(require 'harness-tools)
(require 'harness-agent)
(require 'harness-test-helpers)

(harness-module-load 'harness-ui)
(harness-module-load 'harness-ui-ask)
(harness-module-load 'harness-tools)
(harness-module-load 'harness-agent)

(defun harness-ui-ask-test--reset ()
  "Clear pending panels."
  (setq harness-ui-ask--queue nil
        harness-ui-ask--current nil)
  (when-let* ((buffer (get-buffer "*harness-approval*")))
    (kill-buffer buffer)))

(defun harness-ui-ask-test--permission (responder &optional auto)
  "Send a permission request answered by RESPONDER."
  (harness-ui-ask--on-permission
   (list :session-id "s1"
         :tool-call (list :toolCallId "c1"
                          :title "Run bash"
                          :rawInput '(:command "rm -rf /tmp/x")
                          :content (vector (list :type "content"
                                                 :content (list :type "text"
                                                                :text "outside the session directory"))))
         :options (vector (list :optionId "allow-once" :name "Allow once" :kind "allow_once"))
         :respond responder)))

(defun harness-ui-ask-test--text ()
  "Return the panel text."
  (with-current-buffer (get-buffer "*harness-approval*")
    (buffer-substring-no-properties (point-min) (point-max))))

(ert-deftest harness-ui-ask-permission-panel-renders ()
  (harness-ui-ask-test--reset)
  (harness-ui-ask-test--permission #'ignore)
  (let ((text (harness-ui-ask-test--text)))
    (should (string-match-p "Approval needed" text))
    (should (string-match-p "Run bash" text))
    (should (string-match-p "outside the session directory" text))
    (should (string-match-p "Allow once" text))
    (should (string-match-p "Reject" text)))
  (harness-ui-ask-test--reset))

(ert-deftest harness-ui-ask-permission-keys-answer ()
  (harness-ui-ask-test--reset)
  (let ((answer nil))
    (harness-ui-ask-test--permission (lambda (value) (setq answer value)))
    (switch-to-buffer (get-buffer "*harness-approval*"))
      (execute-kbd-macro (kbd "a"))
    (should (equal answer "allow-always")))
  (harness-ui-ask-test--reset))

(ert-deftest harness-ui-ask-permission-buttons-answer ()
  (harness-ui-ask-test--reset)
  (let ((answer nil))
    (harness-ui-ask-test--permission (lambda (value) (setq answer value)))
    (with-current-buffer (get-buffer "*harness-approval*")
      (goto-char (point-min))
      (search-forward "Reject")
      (push-button (match-beginning 0)))
    (should (equal answer "reject-once")))
  (harness-ui-ask-test--reset))

(ert-deftest harness-ui-ask-permission-cancel-rejects ()
  (harness-ui-ask-test--reset)
  (let ((answer nil))
    (harness-ui-ask-test--permission (lambda (value) (setq answer value)))
    (switch-to-buffer (get-buffer "*harness-approval*"))
      (execute-kbd-macro (kbd "C-g"))
    (should (equal answer "reject-once")))
  (harness-ui-ask-test--reset))

(ert-deftest harness-ui-ask-queues-requests ()
  (harness-ui-ask-test--reset)
  (let ((answers nil))
    (harness-ui-ask-test--permission (lambda (value) (push value answers)))
    (harness-ui-ask-test--permission (lambda (value) (push value answers)))
    (should (= (length harness-ui-ask--queue) 2))
    (should (string-match-p "1 more waiting" (harness-ui-ask-test--text)))
    (harness-ui-ask-answer "allow-once")
    (should (= (length harness-ui-ask--queue) 1))
    ;; The second request is now shown and answerable.
    (harness-ui-ask-answer "reject-once")
    (should-not harness-ui-ask--queue)
    (should (equal (nreverse answers) '("allow-once" "reject-once"))))
  (harness-ui-ask-test--reset))

(ert-deftest harness-ui-ask-auto-answer ()
  (harness-ui-ask-test--reset)
  (let ((harness-ui-ask-auto-answer t)
        (answer nil))
    (harness-ui-ask-test--permission (lambda (value) (setq answer value)))
    (should (equal answer "allow-once"))
    (should-not harness-ui-ask--queue))
  (harness-ui-ask-test--reset))

(ert-deftest harness-ui-ask-question-options ()
  (harness-ui-ask-test--reset)
  (let ((answer nil))
    (harness-ui-ask--on-question
     (list :session-id "s1"
           :question "Which database should I use?"
           :options (vector "Postgres" "SQLite" "DuckDB")
           :freeform nil
           :respond (lambda (value) (setq answer value))))
    (should (string-match-p "Which database" (harness-ui-ask-test--text)))
    (switch-to-buffer (get-buffer "*harness-approval*"))
      (execute-kbd-macro (kbd "2"))
    (should (equal answer "SQLite")))
  (harness-ui-ask-test--reset))

(ert-deftest harness-ui-ask-question-freeform ()
  (harness-ui-ask-test--reset)
  (let ((answer nil))
    (harness-ui-ask--on-question
     (list :session-id "s1"
           :question "Anything else?"
           :options nil
           :freeform t
           :respond (lambda (value) (setq answer value))))
    (switch-to-buffer (get-buffer "*harness-approval*"))
    (goto-char (point-max))
    (insert "use sqlite please")
    (execute-kbd-macro (kbd "RET"))
    (should (equal answer "use sqlite please")))
  (harness-ui-ask-test--reset))

(ert-deftest harness-ui-ask-question-cancel-answers-nil ()
  (harness-ui-ask-test--reset)
  (let ((answer :unset))
    (harness-ui-ask--on-question
     (list :session-id "s1" :question "?" :options nil :freeform t
           :respond (lambda (value) (setq answer value))))
    (switch-to-buffer (get-buffer "*harness-approval*"))
      (execute-kbd-macro (kbd "C-g"))
    (should (null answer)))
  (harness-ui-ask-test--reset))

;;; The agent-side ask tool

(ert-deftest harness-agent-ask-tool-round-trip ()
  (let ((harness-agent-question-function
         (lambda (request)
           (should (equal (plist-get request :question) "Deploy now?"))
           (should (equal (append (plist-get request :options) nil) '("yes" "no")))
           (harness-test-resolved "yes")))
        (statuses nil))
    (cl-letf (((symbol-function 'harness-agent--set-status)
               (lambda (_session-id status) (push status statuses))))
      (let* ((context (harness-tool-context-create :session-id "s1" :cwd "/tmp"))
             (deferred (harness-tools-execute
                        "ask"
                        '(:question "Deploy now?" :options ["yes" "no"] :freeform t)
                        context)))
        (harness-test-settle deferred 5)
        (let ((result (harness-deferred-value deferred)))
          (should-not (plist-get result :is-error))
          (should (string-match-p "The user answered: yes"
                                  (harness-tools--text-of (plist-get result :content))))
          (should (equal (nreverse statuses) '("blocked" "running"))))))))

(ert-deftest harness-agent-ask-tool-without-ui ()
  (let ((harness-agent-question-function nil))
    (let* ((context (harness-tool-context-create :session-id "s1" :cwd "/tmp"))
           (deferred (harness-tools-execute "ask" '(:question "?") context)))
      (harness-test-settle deferred 5)
      (should (plist-get (harness-deferred-value deferred) :is-error)))))

(provide 'harness-ui-ask-test)
;;; harness-ui-ask-test.el ends here
