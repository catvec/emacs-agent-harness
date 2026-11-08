;;; harness-tools-todo-test.el --- Tests for the todo_write tool  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defvar harness-provider-demo--delay)

(defmacro harness-tools-todo-test-with (&rest body)
  "Load the state layer with the demo provider and todo_write, run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo tools session agent tools-todo))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-agent--turns)
     (let ((harness-provider-demo--delay 0.005)
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       ,@body)))

(defun harness-tools-todo-test-session ()
  "Create a demo session and return its id."
  (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted") :id))

(defun harness-tools-todo-test-run (sid name input &optional call-id)
  "Execute tool NAME with INPUT in SID; return the promise.
CALL-ID, when given, is the call's id: the one a call node the session
recorded for it carries.  Otherwise the call gets a fresh one."
  (harness-call 'tools/execute sid (list :id (or call-id (harness-short-id)) :name name :input input)))

(ert-deftest harness-tools-todo-write-replaces-the-list ()
  (harness-tools-todo-test-with
    (let* ((sid (harness-tools-todo-test-session))
           (result (harness-test-await
                    (harness-tools-todo-test-run
                     sid "todo_write"
                     '(:todos ((:id "a" :text "Read the code" :status "done")
                               (:id "b" :text "Edit it" :status "in-progress")
                               "Run the tests"))))))
      (should-not (plist-get result :is-error))
      (should (string-match-p "\\[x\\] Read the code" (plist-get result :content)))
      (should (string-match-p "\\[~\\] Edit it" (plist-get result :content)))
      (should (string-match-p "\\[ \\] Run the tests" (plist-get result :content)))
      (should (string-match-p "3 todos: 1 done, 1 in progress, 1 pending" (plist-get result :content)))
      (let ((todos (plist-get (harness-call 'session/get sid) :todos)))
        (should (= 3 (length todos)))
        (should (equal '("a" "b" "t3") (mapcar (lambda (td) (plist-get td :id)) todos)))
        (should (equal '(done in-progress pending) (mapcar (lambda (td) (plist-get td :status)) todos)))
        (should (equal "Run the tests" (plist-get (nth 2 todos) :text)))))))

(provide 'harness-tools-todo-test)
;;; harness-tools-todo-test.el ends here
