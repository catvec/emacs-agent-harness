;;; harness-ui-navigation-test.el --- Bounded harness view navigation  -*- lexical-binding: t; -*-

;;; Commentary:

;; Tool navigation has a fixed vocabulary, not an interactive command
;; runner.  Availability follows running UI modules rather than stale
;; function definitions.  The answer distinguishes a displayed buffer
;; from a page only queued while its data is on the way.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-ui)

(defmacro harness-ui-navigation-test-with-views (&rest body)
  "Run BODY with every fixed view ready and its entry point recorded.
The lexical variables calls and buffer hold calls and the returned
buffer.  No real page, module initialiser, model or server is started."
  (declare (indent 0))
  `(let ((harness--modules (make-hash-table :test 'eq))
         (harness-ui-open-session-function #'ignore)
         (calls nil)
         (buffer (generate-new-buffer " *harness-navigation-test*")))
     (unwind-protect
         (progn
           (dolist (entry harness-ui-tool--views)
             (dolist (module (plist-get entry :modules))
               (puthash module (make-harness-module :name module :state 'ready) harness--modules)))
           (cl-letf ,(mapcar (lambda (function)
                              `((symbol-function ',function)
                                (lambda (&rest args)
                                  (push (list ',function args default-directory current-prefix-arg) calls)
                                  buffer)))
                            '(harness-sessions harness-ui-display-session harness-tasks
                              harness-ui-report-popout harness-ui-pending-popout harness-tree
                              harness-access harness-worktrees harness-settings harness-server
                              harness-usage harness-slots))
             ,@body))
       (kill-buffer buffer))))

(defun harness-ui-navigation-test-error (function)
  "Return the exact message of the error FUNCTION signals."
  (condition-case err
      (progn (funcall function) (ert-fail "Missing navigation error"))
    (user-error (error-message-string err))))

(ert-deftest harness-ui-navigation-catalogue-copy-and-targets ()
  "The catalogue's exact labels and target names are the public tool copy."
  (harness-ui-navigation-test-with-views
    (should
     (equal
      '((:view "sessions" :label "Sessions" :available t :requires "project")
        (:view "session" :label "Session" :available t :requires "session")
        (:view "tasks" :label "Tasks" :available t :requires "project")
        (:view "report" :label "Task report" :available t :requires "task")
        (:view "pending" :label "Pending requests" :available t :requires "session")
        (:view "tree" :label "Conversation tree" :available t :requires "session")
        (:view "access" :label "Access" :available t :requires "session")
        (:view "worktrees" :label "Worktrees" :available t :requires "project")
        (:view "settings" :label "Settings" :available t :requires "project")
        (:view "server" :label "Server" :available t :requires nil)
        (:view "usage" :label "Usage" :available t :requires nil)
        (:view "slots" :label "Task slots" :available t :requires "project"))
      (harness-ui-tool-views)))
    (should-not calls)))

(ert-deftest harness-ui-navigation-disabled-modules-are-unavailable-with-stale-functions ()
  "A defined function from a module that stopped cannot be called by a tool."
  (harness-ui-navigation-test-with-views
    (dolist (entry harness-ui-tool--views)
      (let* ((view (plist-get entry :view))
             (module (gethash (car (plist-get entry :modules)) harness--modules)))
        (dolist (state '(registered disabled failed))
          (setf (harness-module-state module) state)
          (let ((spec (cl-find view (harness-ui-tool-views)
                               :key (lambda (item) (plist-get item :view)) :test #'equal)))
            (should (eq :false (plist-get spec :available))))
          (should
           (equal (format "Harness view unavailable: %s" view)
                  (harness-ui-navigation-test-error
                   (lambda () (harness-ui-tool-open-view (list :view view)))))))
        (setf (harness-module-state module) 'ready)))
    ;; The popout is an independently optional dependency for both views.
    (setf (harness-module-state (gethash 'ui-popout harness--modules)) 'disabled)
    (dolist (view '("pending" "report"))
      (should (equal (format "Harness view unavailable: %s" view)
                     (harness-ui-navigation-test-error
                      (lambda () (harness-ui-tool-open-view (list :view view)))))))
    (should-not calls)))

(ert-deftest harness-ui-navigation-never-loads-an-autoload-or-a-missing-view ()
  (harness-ui-navigation-test-with-views
    (cl-letf (((symbol-function 'harness-server) '(autoload "harness-ui-server" nil t))
              ((symbol-function 'harness-usage) nil)
              ((symbol-function 'load) (lambda (&rest _) (ert-fail "Unexpected module load"))))
      (dolist (view '("server" "usage"))
        (should (equal (format "Harness view unavailable: %s" view)
                       (harness-ui-navigation-test-error
                        (lambda () (harness-ui-tool-open-view (list :view view))))))))
    (let ((harness-ui-open-session-function nil))
      (should (equal "Harness view unavailable: session"
                     (harness-ui-navigation-test-error
                      (lambda () (harness-ui-tool-open-view '(:view "session" :session "s1")))))))
    (should-not calls)))

(ert-deftest harness-ui-navigation-explicit-targets-and-no-interactive-commands ()
  (harness-ui-navigation-test-with-views
    (let ((default-directory "/original/")
          (current-prefix-arg '(4)))
      (cl-letf (((symbol-function 'call-interactively)
                 (lambda (&rest _) (ert-fail "Unexpected interactive command")))
                ((symbol-function 'read-string)
                 (lambda (&rest _) (ert-fail "Unexpected prompt")))
                ((symbol-function 'completing-read)
                 (lambda (&rest _) (ert-fail "Unexpected target picker")))
                ((symbol-function 'harness-ui-visit-session)
                 (lambda (&rest _) (ert-fail "Unexpected workspace switch"))))
        (cl-letf (((symbol-function 'harness-ui-request)
                   (lambda (method params)
                     (should (equal '("_harness/session/get" (:id "s1")) (list method params)))
                     (harness-resolved '(:id "s1" :pending nil))))
                  ((symbol-function 'harness-ui-pending-sync) #'ignore))
          (dolist (case '(("sessions" :project "/project" harness-sessions (nil) "/project/")
                          ("session" :session "s1" harness-ui-display-session ("s1") "/original/")
                          ("tasks" :project "/project" harness-tasks ("/project") "/project/")
                          ("pending" :session "s1" harness-ui-pending-popout ("s1") "/original/")
                          ("tree" :session "s1" harness-tree ("s1") "/original/")
                          ("access" :session "s1" harness-access ("s1") "/original/")
                          ("worktrees" :project "/project" harness-worktrees ("/project") "/project/")
                          ("settings" :project "/project" harness-settings ("/project") "/project/")
                          ("server" nil nil harness-server nil "/original/")
                          ("usage" nil nil harness-usage nil "/original/")
                          ("slots" :project "/project" harness-slots ("/project") "/project/")))
            (let* ((view (nth 0 case))
                   (params (append (list :view view) (and (nth 1 case) (list (nth 1 case) (nth 2 case))))))
              (setq calls nil)
              (let ((answer (harness-ui-tool-open-view params)))
                (should (equal (list :view view :buffer (buffer-name buffer) :status "opened")
                               (if (harness-promise-p answer) (harness-test-await answer) answer))))
              (should (equal (list (list (nth 3 case) (nth 4 case) (nth 5 case) nil)) calls))))
          (should (equal "/original/" default-directory))
          (should (equal '(4) current-prefix-arg)))))))

(ert-deftest harness-ui-navigation-validation-copy-and-fixed-vocabulary ()
  (harness-ui-navigation-test-with-views
    (dolist (case '(((:view "shell-command" :command "touch file") "Unknown harness view: shell-command")
                    ((:view "tasks") "Missing project")
                    ((:view "session" :session " ") "Missing session")
                    ((:view "report") "Missing task")
                    ((:view "tasks" :project "relative") "Invalid project directory")
                    ((:view "tasks" :project "/ssh:host:/project/") "Invalid project directory")))
      (should (equal (nth 1 case)
                     (harness-ui-navigation-test-error
                      (lambda () (harness-ui-tool-open-view (car case)))))))
    (cl-letf (((symbol-function 'harness-ui-request)
               (lambda (_method _params) (harness-resolved '(:id "s1" :pending nil))))
              ((symbol-function 'harness-ui-pending-sync) #'ignore)
              ((symbol-function 'harness-ui-pending-popout) (lambda (_sid) nil)))
      (should (equal "No pending requests"
                     (harness-ui-navigation-test-error
                      (lambda () (harness-test-await
                                  (harness-ui-tool-open-view '(:view "pending" :session "s1"))))))))
    (should-not calls)))

(ert-deftest harness-ui-navigation-buffer-result-does-not-claim-an-unseen-page ()
  (harness-ui-navigation-test-with-views
    (save-window-excursion
      (switch-to-buffer buffer)
      (cl-letf (((symbol-function 'harness-server) (lambda () nil)))
        (should (equal '(:view "server" :buffer nil :status "loading")
                       (harness-ui-tool-open-view '(:view "server"))))
        ;; A command may return a refresh promise after displaying a real
        ;; page.  That buffer exists, even though its data is still loading.
        (with-current-buffer buffer (setq major-mode 'harness-ui-server-mode))
        (should (equal (list :view "server" :buffer (buffer-name buffer) :status "opened")
                       (harness-ui-tool-open-view '(:view "server"))))))))

(ert-deftest harness-ui-navigation-report-awaits-task-and-displays-real-buffer ()
  (harness-ui-navigation-test-with-views
    (let ((request (harness-make-promise))
          requested)
      (cl-letf (((symbol-function 'harness-ui-request)
                 (lambda (method params)
                   (setq requested (list method params))
                   request)))
        (let ((result (harness-ui-tool-open-view '(:view "report" :task "t1"))))
          (should (harness-promise-p result))
          (should-not (harness-promise-settled-p result))
          (should-not calls)
          (should (equal '("_harness/task/get" (:id "t1")) requested))
          (harness-resolve request '(:id "t1" :report (:summary "Evidence")))
          (should (equal (list :view "report" :buffer (buffer-name buffer) :status "opened")
                         (harness-test-await result)))
          (should (equal '(harness-ui-report-popout ((:id "t1" :report (:summary "Evidence"))))
                         (seq-take (car calls) 2))))))))

(ert-deftest harness-ui-navigation-report-refuses-missing-or-replaced-target ()
  (harness-ui-navigation-test-with-views
    (dolist (task '(nil (:id "another-task")))
      (cl-letf (((symbol-function 'harness-ui-request)
                 (lambda (_method _params) (harness-resolved task))))
        (should (equal "Unknown task: t1"
                       (harness-ui-navigation-test-error
                        (lambda ()
                          (harness-test-await
                           (harness-ui-tool-open-view '(:view "report" :task "t1")))))))))
    (should-not calls)))

(ert-deftest harness-ui-navigation-report-rechecks-disabled-module-after-fetch ()
  (harness-ui-navigation-test-with-views
    (let ((request (harness-make-promise)))
      (cl-letf (((symbol-function 'harness-ui-request) (lambda (_method _params) request)))
        (let ((result (harness-ui-tool-open-view '(:view "report" :task "t1"))))
          (setf (harness-module-state (gethash 'ui-report harness--modules)) 'disabled)
          (harness-resolve request '(:id "t1"))
          (should (equal "Harness view unavailable: report"
                         (harness-ui-navigation-test-error
                          (lambda () (harness-test-await result)))))
          (should-not calls))))))

(ert-deftest harness-ui-navigation-pending-uses-authoritative-session ()
  "A stale UI cache cannot turn an authoritative pending request into none."
  (harness-ui-navigation-test-with-views
    (let (synced)
      (cl-letf (((symbol-function 'harness-ui-request)
                 (lambda (method params)
                   (should (equal '("_harness/session/get" (:id "s1")) (list method params)))
                   (harness-resolved '(:id "s1" :pending ((:id "q1" :kind "question"))))))
                ((symbol-function 'harness-ui-pending-sync)
                 (lambda (sid items) (setq synced (list sid items)) t))
                ((symbol-function 'harness-ui-pending-popout) (lambda (sid) (should (equal "s1" sid)) buffer)))
        (should (equal (list :view "pending" :buffer (buffer-name buffer) :status "opened")
                       (harness-test-await (harness-ui-tool-open-view '(:view "pending" :session "s1")))))
        (should (equal '("s1" ((:id "q1" :kind "question"))) synced))))))

(provide 'harness-ui-navigation-test)
;;; harness-ui-navigation-test.el ends here
