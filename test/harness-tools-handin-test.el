;;; harness-tools-handin-test.el --- Tests for what hand_in asks of a project  -*- lexical-binding: t; -*-

;;; Commentary:

;; A project can hold a hand-in to checks of its own: before the report
;; is recorded, `hand_in' runs the asynchronous filter
;; `task/before-hand-in', and a function of it can refuse with a text
;; that says what to do first.  The harness knows no project: these
;; tests give the filter functions of their own.  The checks of this
;; repository -- that its Flutter app was built -- are its plugin's, and
;; harness-client-check-test.el tests them.
;;
;; The rest of the tool is tested with the tasks (harness-tasks-test.el).

;;; Code:

(require 'harness-test-helpers)

(defvar harness-provider-demo--delay)

(defvar harness-tools-handin-test--task nil "The task `task/for-session' answers with.")
(defvar harness-tools-handin-test--handed-in nil "The reports `task/hand-in' got.")
(defvar harness-tools-handin-test--session nil "The id of the session of the last hand-in.")

(defmacro harness-tools-handin-test-with (&rest body)
  "Load the hand_in tool and run BODY, with no filter on a hand-in."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo tools session agent tools-handin))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-agent--turns)
     (let ((harness-provider-demo--delay 0.005)
           (default-directory dir))
       ,@body)))

(defun harness-tools-handin-test--hand-in (&rest input)
  "Call hand_in with INPUT, a problem, a summary and a note as evidence, for a task.
Return the result.  `harness-tools-handin-test--handed-in' holds the
reports that were recorded."
  (setq harness-tools-handin-test--task (list :id "t1" :worktree "/work/t1/" :base "main")
        harness-tools-handin-test--handed-in nil)
  (harness-register-method 'task/for-session (lambda (_sid) harness-tools-handin-test--task))
  (harness-register-method 'task/hand-in
                           (lambda (id report)
                             (push (cons id report) harness-tools-handin-test--handed-in)
                             t))
  (let ((sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                      :model "demo:scripted")
                        :id)))
    (harness-add-filter 'permission/decide
                        (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
    (setq harness-tools-handin-test--session sid)
    (harness-test-await
     (harness-call 'tools/execute sid
                   (list :id "h1" :name "hand_in"
                         :input (append input
                                        (list :problem "The parser" :summary "# Done"
                                              :evidence '("the tests pass"))))))))

;;;; The filter

(ert-deftest harness-tools-handin-takes-work-as-it-always-did-when-the-project-asks-nothing ()
  "With nothing on the filter, a hand-in is recorded and ends the turn."
  (harness-tools-handin-test-with
    (should-not (memq 'task/before-hand-in (harness-filters)))
    (let ((result (harness-tools-handin-test--hand-in)))
      (should-not (plist-get result :is-error))
      (should (plist-get result :end-turn))
      (should (= 1 (length harness-tools-handin-test--handed-in)))
      (should (equal "t1" (caar harness-tools-handin-test--handed-in))))))

(ert-deftest harness-tools-handin-refusal-of-a-project-check-stops-the-hand-in ()
  "A function that refuses answers the call with its text, as an error; nothing is recorded."
  (harness-tools-handin-test-with
    (let ((handle (harness-add-filter
                   'task/before-hand-in
                   (lambda (_refusal _next _task _session)
                     (harness-resolved "Run the project's checks first: make check."))
                   50)))
      (let ((result (harness-tools-handin-test--hand-in)))
        (should (plist-get result :is-error))
        (should-not (plist-get result :end-turn))
        (should (equal "Run the project's checks first: make check." (plist-get result :content)))
        (should-not harness-tools-handin-test--handed-in))
      ;; The task goes on working; once the check is content, the same work is recorded.
      (harness-remove-filter (car handle) (cdr handle))
      (let ((result (harness-tools-handin-test--hand-in)))
        (should-not (plist-get result :is-error))
        (should harness-tools-handin-test--handed-in)))))

(ert-deftest harness-tools-handin-project-check-is-asked-with-the-task-and-its-session ()
  "A function gets what was refused so far (nil), a way on, the task, and its session's plist."
  (harness-tools-handin-test-with
    (let ((seen nil))
      (harness-add-filter 'task/before-hand-in
                          (lambda (refusal next task session)
                            (setq seen (list refusal (functionp next) task
                                             (plist-get session :id) (plist-get session :cwd)))
                            ;; Calling NEXT is the other way to pass a value on.
                            (funcall next refusal))
                          50)
      (let ((result (harness-tools-handin-test--hand-in)))
        (should-not (plist-get result :is-error))
        (should harness-tools-handin-test--handed-in))
      (should (equal (list nil t harness-tools-handin-test--task harness-tools-handin-test--session)
                     (cl-subseq seen 0 4)))
      (should (stringp (nth 4 seen))))))

(ert-deftest harness-tools-handin-project-checks-add-to-each-others-refusals ()
  "A second function sees what the first refused with, and its answer is what is told."
  (harness-tools-handin-test-with
    (harness-add-filter 'task/before-hand-in
                        (lambda (refusal _next _task _session)
                          (harness-resolved (concat refusal "first")))
                        10)
    (harness-add-filter 'task/before-hand-in
                        (lambda (refusal _next _task _session)
                          (harness-resolved (concat refusal " and second")))
                        20)
    (let ((result (harness-tools-handin-test--hand-in)))
      (should (plist-get result :is-error))
      (should (equal "first and second" (plist-get result :content))))))

(ert-deftest harness-tools-handin-a-check-with-nothing-to-say-lets-the-hand-in-through ()
  "A function that hands the value on as it was, or a blank text, refuses nothing."
  (harness-tools-handin-test-with
    (harness-add-filter 'task/before-hand-in
                        (lambda (refusal _next _task _session) (harness-resolved refusal))
                        10)
    (let ((result (harness-tools-handin-test--hand-in)))
      (should-not (plist-get result :is-error))
      (should harness-tools-handin-test--handed-in))
    (harness-add-filter 'task/before-hand-in
                        (lambda (_refusal _next _task _session) (harness-resolved "  \n"))
                        20)
    (let ((result (harness-tools-handin-test--hand-in)))
      (should-not (plist-get result :is-error))
      (should harness-tools-handin-test--handed-in))))

(ert-deftest harness-tools-handin-a-check-that-fails-refuses-nothing ()
  "A check that signals, or whose promise is rejected, does not keep the work from the user."
  (harness-tools-handin-test-with
    (harness-add-filter 'task/before-hand-in
                        (lambda (_refusal _next _task _session) (error "The linter fell over"))
                        10)
    (harness-add-filter 'task/before-hand-in
                        (lambda (_refusal _next _task _session)
                          (harness-rejected '(harness-error "No network")))
                        20)
    (let ((result (harness-tools-handin-test--hand-in)))
      (should-not (plist-get result :is-error))
      (should (plist-get result :end-turn))
      (should harness-tools-handin-test--handed-in))))

(ert-deftest harness-tools-handin-a-chain-that-itself-fails-refuses-nothing ()
  "Should the chain itself be rejected, the work is recorded all the same."
  (harness-tools-handin-test-with
    (harness-add-filter 'task/before-hand-in
                        (lambda (refusal _next _task _session) (harness-resolved refusal))
                        50)
    (cl-letf (((symbol-function 'harness-run-filter-async)
               (lambda (&rest _) (harness-rejected '(harness-error "The chain broke")))))
      (let ((result (harness-tools-handin-test--hand-in)))
        (should-not (plist-get result :is-error))
        (should (plist-get result :end-turn))
        (should harness-tools-handin-test--handed-in)))))

(ert-deftest harness-tools-handin-a-task-that-cannot-continue-is-not-put-to-the-checks ()
  "A task that cannot continue, or has nothing to merge, is not asked; work to merge is."
  (harness-tools-handin-test-with
    (let ((asked 0))
      (harness-add-filter 'task/before-hand-in
                          (lambda (_refusal _next _task _session)
                            (cl-incf asked)
                            (harness-resolved "Not yet."))
                          50)
      (let ((result (harness-tools-handin-test--hand-in :cannot_continue t)))
        (should-not (plist-get result :is-error))
        (should (plist-get (cdar harness-tools-handin-test--handed-in) :cannot-continue)))
      (let ((result (harness-tools-handin-test--hand-in :no_merge t)))
        (should-not (plist-get result :is-error))
        (should (plist-get (cdar harness-tools-handin-test--handed-in) :no-merge)))
      (should (= 0 asked))
      (let ((result (harness-tools-handin-test--hand-in)))
        (should (plist-get result :is-error)))
      (should (= 1 asked)))))

(ert-deftest harness-tools-handin-a-malformed-hand-in-is-told-so-before-any-check-is-asked ()
  "What is wrong with the report itself is told first; the project's checks wait for a report."
  (harness-tools-handin-test-with
    (let ((asked 0))
      (harness-add-filter 'task/before-hand-in
                          (lambda (_refusal _next _task _session)
                            (cl-incf asked)
                            (harness-resolved "Not yet."))
                          50)
      (let ((result (harness-tools-handin-test--hand-in :summary "")))
        (should (plist-get result :is-error))
        (should (string-prefix-p "hand_in needs summary" (plist-get result :content))))
      (should (= 0 asked)))))

(ert-deftest harness-tools-handin-knows-no-project ()
  "Nothing of any project is in the tool: no app, no SDK, no licence."
  (harness-tools-handin-test-with
    (let ((description (plist-get (harness-call 'tools/get "hand_in") :description)))
      (should (string-match-p "A project can refuse a hand-in until a check of its own has passed"
                              description))
      (dolist (word '("Flutter" "Android" "licen" "harness_client" "check_build"))
        (should-not (string-match-p word description))))
    (let ((source (with-temp-buffer
                    (insert-file-contents (locate-library "harness-tools-handin.el"))
                    (buffer-string))))
      (dolist (word '("Android" "harness_client" "check_build" "licence" "stamp"))
        (should-not (string-match-p word source))))))

(provide 'harness-tools-handin-test)
;;; harness-tools-handin-test.el ends here
