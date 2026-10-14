;;; harness-tools-session-info-test.el --- Tests for the session_info tool  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defvar harness-provider-demo--delay)

;; The sub-agents are there to give the session a child to name.
(defmacro harness-tools-session-info-test-with (&rest body)
  "Load the state layer with the demo provider, session_info and spawn_agent, run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo tools session agent tools-session-info tools-agent priority))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-agent--turns)
     (let ((harness-provider-demo--delay 0.005)
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       ,@body)))

(defun harness-tools-session-info-test-session ()
  "Create a demo session and return its id."
  (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted") :id))

(defun harness-tools-session-info-test-run (sid name input &optional call-id)
  "Execute tool NAME with INPUT in SID; return the promise.
CALL-ID, when given, is the call's id: the one a call node the session
recorded for it carries.  Otherwise the call gets a fresh one."
  (harness-call 'tools/execute sid (list :id (or call-id (harness-short-id)) :name name :input input)))

(ert-deftest harness-tools-session-info-registers-session-info ()
  (harness-tools-session-info-test-with
    (should (eq 'read (plist-get (harness-call 'tools/get "session_info") :kind)))))

(ert-deftest harness-tools-session-info-describes-the-session ()
  (harness-tools-session-info-test-with
    (let* ((sid (harness-tools-session-info-test-session)))
      (harness-call 'session/update sid :name "main work" :silent t)
      (harness-test-await (harness-tools-session-info-test-run sid "spawn_agent" '(:prompt "hi" :name "kid")))
      (let ((text (plist-get (harness-test-await (harness-tools-session-info-test-run sid "session_info" nil)) :content))
            (cid (plist-get (car (harness-call 'session/list (list :parent-id sid))) :id)))
        (should (string-match-p (concat "Session: " sid) text))
        (should (string-match-p "Name: main work" text))
        (should (string-match-p "Model: demo:scripted" text))
        (should (string-match-p (concat "^Temporary directory: " (regexp-quote (harness-call 'session/tmp-dir sid)) "$")
                                text))
        (should (string-match-p "Permission mode: ask" text))
        (should (string-match-p "^Non-interactive: off$" text))
        (should (string-match-p "Status: idle" text))
        (should (string-match-p "Parent: none" text))
        (should (string-match-p (concat "Children: " cid) text)))
      (harness-call 'session/update sid :non-interactive t :silent t)
      (should (string-match-p "^Non-interactive: on (the user is away"
                              (plist-get (harness-test-await (harness-tools-session-info-test-run sid "session_info" nil))
                                         :content))))))

(provide 'harness-tools-session-info-test)
;;; harness-tools-session-info-test.el ends here
