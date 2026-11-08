;;; harness-tools-plan-test.el --- Tests for the plan tool  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defvar harness-provider-demo--delay)

(defmacro harness-tools-plan-test-with (&rest body)
  "Load the state layer with the demo provider and the plan tool, run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo tools session agent tools-plan))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-agent--turns)
     (let ((harness-provider-demo--delay 0.005)
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       ,@body)))

(defun harness-tools-plan-test-session ()
  "Create a demo session and return its id."
  (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted") :id))

(defun harness-tools-plan-test-run (sid name input &optional call-id)
  "Execute tool NAME with INPUT in SID; return the promise.
CALL-ID, when given, is the call's id: the one a call node the session
recorded for it carries.  Otherwise the call gets a fresh one."
  (harness-call 'tools/execute sid (list :id (or call-id (harness-short-id)) :name name :input input)))

(defun harness-tools-plan-test-kinds (id)
  (mapcar (lambda (n) (plist-get n :kind)) (harness-call 'session/nodes id)))

(ert-deftest harness-tools-plan-registers-plan ()
  (harness-tools-plan-test-with
    (should (eq 'meta (plist-get (harness-call 'tools/get "plan") :kind)))))

(ert-deftest harness-tools-plan-records-and-hints ()
  (harness-tools-plan-test-with
    (let* ((sid (harness-tools-plan-test-session))
           (plans nil))
      (harness-on 'session/plan (lambda (s text) (push (cons s text) plans)))
      (let ((result (harness-test-await
                     (harness-tools-plan-test-run sid "plan" '(:plan "1. read\n2. edit" :title "Fix it")))))
        (should-not (plist-get result :is-error))
        (should (string-match-p "Plan recorded" (plist-get result :content))))
      (should (equal "1. read\n2. edit" (plist-get (harness-call 'session/get sid) :plan)))
      (should (equal '(plan hint) (harness-tools-plan-test-kinds sid)))
      (let ((node (car (harness-call 'session/nodes sid))))
        (should (equal "Fix it" (plist-get node :title)))
        (should (equal "1. read\n2. edit" (plist-get node :content))))
      (should (equal "Plan updated" (plist-get (cadr (harness-call 'session/nodes sid)) :content)))
      (should (equal (list (cons sid "1. read\n2. edit")) plans)))))

(provide 'harness-tools-plan-test)
;;; harness-tools-plan-test.el ends here
