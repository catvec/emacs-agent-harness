;;; harness-subagents-test.el --- Tests for subagents -*- lexical-binding: t; -*-

;; Copyright (C) 2026 the emacs-agent-harness authors

;; This file is not part of GNU Emacs.

;;; Code:

(require 'ert)
(require 'harness-subagents)
(require 'harness-mock-provider)
(require 'harness-test-util)

(defmacro harness-subagents-test-with-parent (script &rest body)
  "Run BODY with a parent session whose provider plays SCRIPT.
BODY can refer to `session'."
  (declare (indent 1))
  `(harness-test-with-temp-session-dir
     (let* ((harness-providers (list (list :name 'mock :kind 'harness-test
                                           :script ,script)))
            (harness-models '((:provider mock :id "parent-model")
                              (:provider mock :id "review-model")))
            (harness-permission-policy '((:default allow)))
            (harness-permission-rules nil)
            (default-directory (file-name-as-directory harness-test--directory))
            (session (harness-session-create '(:name "parent" :model "parent-model"
                                                      :provider mock))))
       (harness-provider-setup)
       (unwind-protect
           (progn ,@body)
         ;; Children are sessions too, so clear them all.
         (dolist (child (harness-subagents-of session))
           (harness-session-remove child))
         (harness-session-remove session)))))

(defun harness-subagents-test--wait-idle (session)
  "Wait until SESSION is idle."
  (harness-test-wait-for
   (lambda () (memq (harness-session-status session) '(idle))) 20))

(ert-deftest harness-subagents-test-spawn-and-collect ()
  "A subagent runs in its own session and its answer returns to the parent."
  (harness-subagents-test-with-parent
      '((:tool-call ("spawn_subagent" (:prompt "look into it")))
        (:text "the child's answer")
        (:text "the parent's answer"))
    (harness-agent-send session "please delegate")
    (should (harness-subagents-test--wait-idle session))
    (let ((children (harness-subagents-of session)))
      (should (= (length children) 1))
      (let ((child (car children)))
        (should (equal (harness-session-parent child) (harness-session-id session)))
        (should (equal (harness-message-content (harness-session-last-message child))
                       "the child's answer"))
        (should (equal (harness-session-model child) "parent-model"))))
    (let* ((assistant (cadr (harness-session-messages session)))
           (call (car (harness-message-tool-calls assistant))))
      (should (eq (harness-tool-call-status call) 'ok))
      (should (string-match-p "the child's answer" (harness-tool-call-result call)))
      (should (equal (harness-message-content (harness-session-last-message session))
                     "the parent's answer")))))

(ert-deftest harness-subagents-test-personality-restricts-tools ()
  "A personality's tool list is enforced, not merely requested."
  (harness-subagents-test-with-parent
      '((:tool-call ("spawn_subagent" (:prompt "review it" :personality "reviewer")))
        (:text "reviewed")
        (:text "done"))
    (harness-agent-send session "get a review")
    (should (harness-subagents-test--wait-idle session))
    (let ((child (car (harness-subagents-of session))))
      (should (equal (plist-get (harness-session-meta child) :personality) 'reviewer))
      (should (equal (plist-get (harness-session-meta child) :tools)
                     '("read" "glob" "grep")))
      (let ((names (mapcar (lambda (spec)
                             (harness-alist-get :name (harness-alist-get :function spec)))
                           (harness-tools-specs child))))
        (should (member "read" names))
        (should-not (member "write" names))
        (should-not (member "edit" names)))
      ;; The general list is unrestricted.
      (should (member "write"
                      (mapcar (lambda (spec)
                                (harness-alist-get :name (harness-alist-get :function spec)))
                              (harness-tools-specs)))))))

(ert-deftest harness-subagents-test-personality-model-override ()
  "A personality can run the child on a different model."
  (harness-subagents-test-with-parent
      '((:tool-call ("spawn_subagent" (:prompt "plan" :personality "cheap-planner")))
        (:text "planned")
        (:text "ok"))
    (let ((harness-personalities
           (cons '(cheap-planner :description "cheap"
                                 :model "review-model"
                                 :system-prompt "Plan only."
                                 :tools ("read"))
                 harness-personalities)))
      (harness-agent-send session "plan this")
      (should (harness-subagents-test--wait-idle session))
      (let ((child (car (harness-subagents-of session))))
        (should (equal (harness-session-model child) "review-model"))
        ;; The personality prompt reaches the child's system prompt.
        (should (string-match-p "Plan only\\."
                                (harness-personality-prompt child)))))))

(ert-deftest harness-subagents-test-explicit-model-wins ()
  "An explicit model on the call beats the personality's."
  (harness-subagents-test-with-parent
      '((:tool-call ("spawn_subagent" (:prompt "x" :personality "reviewer"
                                               :model "parent-model")))
        (:text "child")
        (:text "parent"))
    (let ((harness-personalities
           (cons '(reviewer :description "r" :model "review-model"
                            :system-prompt "Review.")
                 harness-personalities)))
      (harness-agent-send session "go")
      (should (harness-subagents-test--wait-idle session))
      (should (equal (harness-session-model (car (harness-subagents-of session)))
                     "parent-model")))))

(ert-deftest harness-subagents-test-background ()
  "A background subagent returns immediately with its session id."
  (harness-subagents-test-with-parent
      '((:tool-call ("spawn_subagent" (:prompt "slow work" :background t)))
        (:text "the child's answer")
        (:text "carrying on"))
    (harness-agent-send session "delegate in the background")
    (should (harness-subagents-test--wait-idle session))
    (let* ((assistant (cadr (harness-session-messages session)))
           (call (car (harness-message-tool-calls assistant)))
           (detail (harness-tool-call-detail call)))
      (should (eq (harness-tool-call-status call) 'ok))
      (should (eq (plist-get detail :background) t))
      (should (harness-session-get (plist-get detail :session-id)))
      (should (equal (harness-message-content (harness-session-last-message session))
                     "carrying on")))))

(ert-deftest harness-subagents-test-unknown-personality ()
  "An unknown personality is an error result, not a signal."
  (harness-subagents-test-with-parent
      '((:tool-call ("spawn_subagent" (:prompt "x" :personality "nope"))))
    (harness-agent-send session "go")
    (should (harness-subagents-test--wait-idle session))
    (let* ((assistant (cadr (harness-session-messages session)))
           (call (car (harness-message-tool-calls assistant))))
      (should (eq (harness-tool-call-status call) 'error))
      (should (string-match-p "Unknown personality" (harness-tool-call-result call)))
      (should-not (harness-subagents-of session)))))

(ert-deftest harness-subagents-test-abort-propagates ()
  "Aborting a parent aborts its running children."
  (harness-subagents-test-with-parent '((:nothing))
    (let ((child (harness-session-create
                  '(:name "child" :model "parent-model" :provider mock
                    :parent (harness-session-id session))))
          (aborted nil))
      (unwind-protect
          (progn
            (setf (harness-session-children session) (list (harness-session-id child)))
            (harness-session-set-status child 'working)
            ;; Spy rather than fake a full child run: what matters is that the
            ;; abort reaches the child at all.
            (cl-letf (((symbol-function 'harness-agent-abort)
                       (lambda (victim)
                         (push (harness-session-id victim) aborted))))
              (harness-subagents--abort-children session))
            (should (equal aborted (list (harness-session-id child))))
            ;; And that the hook is actually installed.
            (should (memq #'harness-subagents--abort-children
                          harness-run-aborted-hook)))
        (harness-session-remove child)))))

(ert-deftest harness-subagents-test-system-prompt-mentions-subagent ()
  "A child's system prompt says it is a subagent."
  (harness-subagents-test-with-parent '((:nothing))
    (let ((child (harness-session-create
                  '(:name "child" :model "parent-model" :provider mock
                    :parent (harness-session-id session)))))
      (unwind-protect
          (progn
            (setf (harness-session-meta child)
                  (list :personality 'general))
            (should (string-match-p "subagent" (harness-personality-prompt child))))
        (harness-session-remove child)))))

(provide 'harness-subagents-test)
;;; harness-subagents-test.el ends here
