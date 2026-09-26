;;; harness-plan-test.el --- Tests for the plan tool -*- lexical-binding: t; -*-

;;; Commentary:

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'harness-core)
(require 'harness-session)
(require 'harness-tools)
(require 'harness-plan)
(require 'harness-test-helpers)

(harness-module-load 'harness-session)
(harness-module-load 'harness-tools)
(harness-module-load 'harness-plan)

(defun harness-plan-test--call (arguments session)
  "Run the plan tool with ARGUMENTS for SESSION and return the result."
  (let* ((context (harness-tool-context-create
                   :session-id (harness-session-id session)
                   :cwd (harness-session-cwd session)))
         (deferred (harness-tools-execute "plan" arguments context)))
    (harness-test-settle deferred 5)
    (harness-deferred-value deferred)))

(ert-deftest harness-plan-tool-is-read-only ()
  (let ((tool (harness-tool-get "plan")))
    (should tool)
    (should (harness-tool-read-only tool))
    (should (equal (harness-tool-kind tool) 'think))))

(ert-deftest harness-plan-records-an-entry-and-state ()
  (let ((harness-session-storage-directory (make-temp-file "harness-plan-" t)))
    (clrhash harness-session--active)
    (clrhash harness-session--project-ids)
    (let* ((session (harness-session-create :cwd (make-temp-file "harness-plan-dir-" t)))
           (result (harness-plan-test--call
                    '(:plan "# Approach\\n\\n1. Read the code\\n2. Patch it"
                      :title "Fix the bug")
                    session))
           (text (harness-tools--text-of (plist-get result :content)))
           (entries (harness-session-entries session))
           (plan-entry (seq-find (lambda (entry)
                                   (equal (plist-get entry :sessionUpdate) "plan"))
                                 (append entries nil))))
      (should-not (plist-get result :is-error))
      (should (string-match-p "recorded the plan" text))
      (should plan-entry)
      (should (equal (plist-get plan-entry :title) "Fix the bug"))
      (should (string-match-p "1\\. Read the code"
                              (plist-get (plist-get plan-entry :content) :text)))
      ;; The latest plan lives in session state for later turns.
      (let ((state (harness-service-call "session" 'state-get
                                        :session-id (harness-session-id session)
                                        :key 'plan)))
        (should state)
        (should (equal (plist-get state :title) "Fix the bug")))
      ;; A hint tells the user a plan is waiting.
      (should (seq-find (lambda (entry)
                          (and (equal (plist-get entry :sessionUpdate) "_harness/system_hint")
                               (string-match-p "waiting for approval"
                                               (plist-get (plist-get entry :content) :text))))
                        (append (harness-session-entries session) nil))))))

(ert-deftest harness-plan-refuses-empty-plans ()
  (let ((harness-session-storage-directory (make-temp-file "harness-plan-" t)))
    (clrhash harness-session--active)
    (let* ((session (harness-session-create :cwd (make-temp-file "harness-plan-dir-" t)))
           (result (harness-plan-test--call '(:plan "   ") session)))
      (should (plist-get result :is-error))
      (should (string-match-p "needs at least a sentence"
                              (harness-tools--text-of (plist-get result :content)))))))

(ert-deftest harness-plan-available-in-plan-mode ()
  ;; The agent's plan mode keeps read-only tools; the plan tool must be one.
  (should (harness-tool-read-only (harness-tool-get "plan"))))

(provide 'harness-plan-test)
;;; harness-plan-test.el ends here
