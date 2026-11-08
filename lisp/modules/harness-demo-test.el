;;; harness-demo-test.el --- Starting a hand-in's demo where it is reviewed  -*- lexical-binding: t; -*-

;;; Commentary:

;; A hand-in's demo is started from the review, bound to the report it
;; was handed in with, run on the workspace computer it names, and shown
;; through that computer's VNC endpoint, with a presenter that drives it.
;; The box itself is another module (the workspace work); these tests
;; stand in for it with recorded methods, so what is checked is this
;; module's own promises: the right workspace, the reviewed commit, the
;; same run for a second tap, stop that stops only its run, control that
;; is the reviewer's or the presenter's, and the truth said when any of
;; it is missing.

;;; Code:

(require 'harness-test-helpers)

(require 'harness-demo)

(defvar harness-demo-test--calls nil
  "What the stand-in box was asked, newest first: (METHOD . ARGS).")

(defmacro harness-demo-test-with-methods (methods &rest body)
  "Run BODY with bus METHODS ((NAME FN)...) in place, then put back what was.
The methods the harness had under those names are restored afterwards,
so a test says what it stubs and no other test sees it."
  (declare (indent 1))
  `(let ((saved (mapcar (lambda (m) (cons (car m) (gethash (car m) harness--methods)))
                        ,methods)))
     (unwind-protect
         (progn
           (dolist (m ,methods) (harness-register-method (car m) (cdr m)))
           ,@body)
       (dolist (entry saved)
         (if (cdr entry)
             (puthash (car entry) (cdr entry) harness--methods)
           (remhash (car entry) harness--methods))))))

(defun harness-demo-test--record (method value)
  "Return a stub of METHOD that records its arguments and returns VALUE.
VALUE is called with the arguments when it is a function."
  (lambda (&rest args)
    (push (cons method args) harness-demo-test--calls)
    (if (functionp value) (apply value args) value)))

(defun harness-demo-test--called (method)
  "Return the newest (METHOD . ARGS) the stand-in box recorded, or nil."
  (cl-find method harness-demo-test--calls :key #'car :test #'eq))

(defun harness-demo-test--called-p (method)
  "Return non-nil when the stand-in box was asked METHOD."
  (and (harness-demo-test--called method) t))

;;;; The world the tests start a demo in

(defun harness-demo-test--task (report &optional directory)
  "Return the task whose report is REPORT, working in DIRECTORY."
  (let ((dir (or directory (harness-test-temp-dir))))
    (list :id "t1" :session "s1" :prompt "Show how the cradle swings"
          :project dir :worktree dir :cwd dir
          :report (append (list :problem "The cradle swings") report))))

(defun harness-demo-test--demo (&rest plist)
  "Return a demo evidence item, as `hand_in' records it, from PLIST."
  (append plist
          (list :kind "demo" :id "demo-1" :title "Newton's cradle"
                :command '("python3" "serve.py")
                :cwd-name "demo" :name "demo/index.html"
                :url "http://localhost:8000" :narration "Start on the left ball.")))

(defun harness-demo-test--box-status (&rest plist)
  "Return what the stand-in box says of itself, from PLIST.
A key in PLIST wins over the default, as a plist's first key does."
  (append plist (list :running t :health "running")))

(defmacro harness-demo-test-with-world (spec &rest body)
  "Run BODY in a temporary world SPEC describes, with a stand-in box.
SPEC is a plist: `:demo' overrides of the demo evidence, `:evidence'
more evidence after it, `:report' more of the report, `:workspace' the
workspace (nil for none), `:workspace-list' what `workspace/list'
answers, `:box' the box's status (nil for no box methods), `:vnc' the
VNC endpoint, `:browser' non-nil to have `workspace/browser/open', and
`:git' a function standing in for `harness-demo--git'."
  (declare (indent 1))
  `(harness-test-with-temp-state
     (setq harness-demo-test--calls nil)
     ;; No run of another world is this world's run.
     (clrhash harness-demo--runs)
     (clrhash harness-demo--by-key)
     (let* ((spec ,spec)
            (dir (harness-test-temp-dir))
            (demo-dir (make-directory (expand-file-name "demo" dir) t))
            (demo (apply #'harness-demo-test--demo
                         (append (list :cwd (expand-file-name "demo" dir))
                                 (plist-get spec :demo))))
            (report (append (list :problem "The cradle swings" :summary "It swings."
                                  :evidence (cons demo (plist-get spec :evidence)))
                            (plist-get spec :report)))
            (task (harness-demo-test--task report dir))
            (workspace (let ((asked (plist-get spec :workspace)))
                         (and asked
                              (plist-put (copy-sequence asked) :root
                                         (or (plist-get asked :root) dir)))))
            (workspace-list (pcase (plist-get spec :workspace-list)
                              ('t (list workspace (copy-sequence workspace)))
                              ('nil (and workspace (list workspace)))
                              (other other)))
            (box (let ((asked (plist-get spec :box)))
                   (and asked
                        (if (eq (plist-get asked :mounts) t)
                            (plist-put (copy-sequence asked) :mounts
                                       (list (list :host dir :box "/work")))
                          asked))))
            (vnc (or (plist-get spec :vnc)
                     (list :url "http://127.0.0.1:6080/vnc.html?autoconnect=1"
                           :state "agent" :token "tok")))
            (methods
             (append
              (list (cons 'task/for-session (lambda (_sid) task))
                    (cons 'session/get (lambda (_sid) (list :model "demo:scripted")))
                    (cons 'session/btw (lambda (_sid name _model)
                                         (list :id "btw-1" :name name)))
                    (cons 'session/hint (lambda (_sid _text) t))
                    (cons 'agent/prompt
                          (lambda (_sid blocks)
                            (push (cons 'agent/prompt blocks) harness-demo-test--calls)
                            nil)))
              (when workspace
                (list (cons 'workspace/get (lambda (_id) workspace))
                      (cons 'workspace/list (lambda () workspace-list))))
              (when box
                (list (cons 'workspace/box/status
                            (harness-demo-test--record 'workspace/box/status box))
                      (cons 'workspace/box/vnc
                            (harness-demo-test--record 'workspace/box/vnc vnc))
                      (cons 'workspace/box/exec
                            (harness-demo-test--record
                             'workspace/box/exec
                             (lambda (&rest _) (list :stdout "" :stderr "" :status nil))))
                      (cons 'workspace/box/take-over
                            (harness-demo-test--record 'workspace/box/take-over t))
                      (cons 'workspace/box/return-control
                            (harness-demo-test--record 'workspace/box/return-control t))
                      (cons 'workspace/box/click
                            (harness-demo-test--record 'workspace/box/click t))
                      (cons 'workspace/box/key
                            (harness-demo-test--record 'workspace/box/key t))
                      (cons 'workspace/box/type
                            (harness-demo-test--record 'workspace/box/type t))
                      (cons 'workspace/box/windows
                            (harness-demo-test--record 'workspace/box/windows '(:windows ())))))
              (when (plist-get spec :browser)
                (list (cons 'workspace/browser/open
                            (harness-demo-test--record 'workspace/browser/open t)))))))
       (harness-demo-test-with-methods methods
         (if-let* ((git (plist-get spec :git)))
             (cl-letf (((symbol-function 'harness-demo--git) git)) ,@body)
           ,@body)))))

(defun harness-demo-test--kitchen ()
  "Return the workspace the tests run demos on.
Its root is the task's own directory, which the world fills in."
  (list :id "w-1" :name "Kitchen"))

;;;; Starting

(ert-deftest harness-demo-start-runs-on-the-bound-workspace ()
  "A demo bound to a workspace starts there: its box runs the command, its
screen is the endpoint the app speaks to, and a presenter is briefed."
  (harness-demo-test-with-world
      (list :workspace (harness-demo-test--kitchen)
            :box (harness-demo-test--box-status :mounts t))
    (let ((answer (harness-call 'demo/start "s1" "demo-1")))
      (should (equal "running" (plist-get answer :state)))
      (should (equal "workspace" (plist-get answer :placement)))
      (should (equal "w-1" (plist-get answer :workspace)))
      (should (equal "Kitchen" (plist-get answer :workspace-name)))
      (should (equal "demo-1" (plist-get answer :demo)))
      (should (equal "t1" (plist-get answer :task)))
      (should (equal "btw-1" (plist-get (plist-get answer :presenter) :session)))
      (should (equal "agent" (plist-get answer :control)))
      (should (harness-json-true-p (plist-get (plist-get answer :vnc) :available)))
      (should (equal "ws://127.0.0.1:6080/websockify"
                     (plist-get (plist-get answer :vnc) :socket)))
      ;; The command runs in the box's own path for the demo's directory.
      (let ((exec (harness-demo-test--called 'workspace/box/exec)))
        (should exec)
        (should (equal "w-1" (nth 0 (cdr exec))))
        (should (equal "python3 serve.py" (nth 1 (cdr exec))))
        (should (equal "/work/demo" (plist-get (nthcdr 2 (cdr exec)) :cwd))))
      ;; The page is opened on that computer too.
      (should-not (harness-demo-test--called-p 'workspace/browser/open))
      ;; The presenter is told the run, the computer and the tool it drives.
      (let* ((prompt (cdr (harness-demo-test--called 'agent/prompt)))
             (text (plist-get (car prompt) :text)))
        (should (listp prompt))
        (should (string-match-p "present_demo" text))
        (should (string-match-p (plist-get answer :run) text))
        (should (string-match-p "workspace computer Kitchen" text))))))

(ert-deftest harness-demo-start-finds-the-workspace-that-holds-the-task ()
  "A demo that names no workspace runs on the one workspace whose root holds
the task's project; a task two workspaces hold is not guessed."
  (harness-demo-test-with-world
      (list :workspace (harness-demo-test--kitchen)
            :box (harness-demo-test--box-status))
    (should (equal "workspace"
                   (plist-get (harness-call 'demo/start "s1" "demo-1") :placement))))
  (harness-demo-test-with-world
      (list :workspace (harness-demo-test--kitchen)
            :workspace-list t
            :box (harness-demo-test--box-status))
    (should (equal "host"
                   (plist-get (harness-call 'demo/start "s1" "demo-1") :placement)))))

(ert-deftest harness-demo-start-says-what-is-missing ()
  "Without the box's methods, a demo bound to a workspace is not started, and
the answer names the methods the harness does not have."
  (harness-demo-test-with-world
      (list :workspace (harness-demo-test--kitchen))
    (let ((answer (harness-call 'demo/start "s1" "demo-1")))
      (should (equal "not-ready" (plist-get answer :state)))
      (should (equal "box-methods-missing"
                     (plist-get (plist-get answer :reason) :code)))
      (should (string-match-p "workspace/box/status"
                              (plist-get (plist-get answer :reason) :text)))
      (should-not (harness-demo-test--called-p 'agent/prompt)))))

(ert-deftest harness-demo-start-refuses-a-worktree-that-moved ()
  "A reviewed worktree with changes since the hand-in is not run."
  (harness-demo-test-with-world
      (list :workspace (harness-demo-test--kitchen)
            :box (harness-demo-test--box-status)
            :git (lambda (_dir &rest args)
                   (if (equal args '("rev-parse" "--verify" "HEAD"))
                       "abc1234"
                     " M src/x.el")))
    (let ((answer (harness-call 'demo/start "s1" "demo-1")))
      (should (equal "not-ready" (plist-get answer :state)))
      (should (equal "worktree-dirty" (plist-get (plist-get answer :reason) :code)))
      (should-not (harness-demo-test--called-p 'workspace/box/exec)))))

(ert-deftest harness-demo-start-refuses-a-box-on-another-commit ()
  "A box checked out somewhere else is not showing the reviewed work."
  (harness-demo-test-with-world
      (list :workspace (harness-demo-test--kitchen)
            :box (harness-demo-test--box-status :commit "bbbbbbbbbbbb")
            :git (lambda (_dir &rest args)
                   (and (equal args '("rev-parse" "--verify" "HEAD")) "aaaaaaaaaaaa")))
    (let ((answer (harness-call 'demo/start "s1" "demo-1")))
      (should (equal "not-ready" (plist-get answer :state)))
      (should (equal "commit-mismatch" (plist-get (plist-get answer :reason) :code)))
      (should-not (harness-demo-test--called-p 'workspace/box/exec)))))

(ert-deftest harness-demo-start-says-when-the-box-cannot-run-it ()
  "A box that is not running, and one that does not hold the demo's directory,
are not started."
  (harness-demo-test-with-world
      (list :workspace (harness-demo-test--kitchen)
            :box (harness-demo-test--box-status :running :false))
    (let ((answer (harness-call 'demo/start "s1" "demo-1")))
      (should (equal "not-ready" (plist-get answer :state)))
      (should (equal "box-not-running" (plist-get (plist-get answer :reason) :code)))))
  (harness-demo-test-with-world
      (list :workspace (harness-demo-test--kitchen)
            :box (harness-demo-test--box-status
                  :mounts (list (list :host "/somewhere/else" :box "/work"))))
    (let ((answer (harness-call 'demo/start "s1" "demo-1")))
      (should (equal "not-ready" (plist-get answer :state)))
      (should (equal "mount-missing" (plist-get (plist-get answer :reason) :code)))
      (should-not (harness-demo-test--called-p 'workspace/box/exec)))))

(ert-deftest harness-demo-answer-is-what-the-app-reads ()
  "The start's answer is JSON the app reads: state, placement, vnc socket,
control and the presenter's session."
  (harness-demo-test-with-world
      (list :workspace (harness-demo-test--kitchen)
            :box (harness-demo-test--box-status))
    (let* ((answer (harness-call 'demo/start "s1" "demo-1"))
           (wire (harness-json-parse (harness-json-encode answer))))
      (should (equal "running" (plist-get wire :state)))
      (should (equal "workspace" (plist-get wire :placement)))
      (should (equal "demo-1" (plist-get wire :demo)))
      (should (equal "agent" (plist-get wire :control)))
      (should (harness-json-true-p (plist-get (plist-get wire :vnc) :available)))
      (should (equal "ws://127.0.0.1:6080/websockify"
                     (plist-get (plist-get wire :vnc) :socket)))
      (should (equal "btw-1" (plist-get (plist-get wire :presenter) :session)))
      (should-not (harness-json-true-p (plist-get wire :commit-verified)))
      (should-not (harness-json-true-p (plist-get wire :stopped))))))

(ert-deftest harness-demo-start-twice-is-one-run ()
  "A second tap while the demo runs answers the run the first made."
  (harness-demo-test-with-world
      (list :workspace (harness-demo-test--kitchen)
            :box (harness-demo-test--box-status))
    (let* ((first (harness-call 'demo/start "s1" "demo-1"))
           (again (harness-call 'demo/start "s1" "demo-1")))
      (should (equal (plist-get first :run) (plist-get again :run)))
      (should (equal "already-running"
                     (plist-get (plist-get again :reason) :code)))
      (should (= 1 (cl-count 'workspace/box/exec harness-demo-test--calls
                             :key #'car))))))

(ert-deftest harness-demo-start-without-a-workspace-runs-on-the-host ()
  "A demo bound to no workspace runs where the harness does, and says so."
  (harness-demo-test-with-world (list)
    (let* ((answer (harness-call 'demo/start "s1" "demo-1"))
           (run (harness-demo--run (plist-get answer :run))))
      (should (equal "running" (plist-get answer :state)))
      (should (equal "host" (plist-get answer :placement)))
      (should-not (plist-get answer :vnc))
      (should (process-live-p (plist-get run :process)))
      ;; Stopping it kills that process and nothing else.
      (should (equal "stopped" (plist-get (harness-call 'demo/stop (plist-get answer :run)) :state)))
      (should-not (process-live-p (plist-get run :process)))
      (should-not (harness-demo-test--called-p 'workspace/box/return-control)))))

(ert-deftest harness-demo-stop-returns-control-and-keeps-the-box ()
  "Stopping a run on a computer gives control back, and stops no box."
  (harness-demo-test-with-world
      (list :workspace (harness-demo-test--kitchen)
            :box (harness-demo-test--box-status)
            :vnc (list :url "ws://127.0.0.1:5901" :state "user"))
    (let* ((answer (harness-call 'demo/start "s1" "demo-1"))
           (run (plist-get answer :run))
           (stopped (harness-call 'demo/stop run)))
      (should (equal "user" (plist-get answer :control)))
      (should (equal "stopped" (plist-get stopped :state)))
      (should (harness-json-true-p (plist-get stopped :stopped)))
      (should (harness-demo-test--called-p 'workspace/box/return-control))
      (should-not (harness-demo-test--called-p 'workspace/box/stop))
      ;; Stopping it again is the same stopped run.
      (should (equal "stopped" (plist-get (harness-call 'demo/stop run) :state)))
      (should (= 1 (cl-count 'workspace/box/return-control harness-demo-test--calls
                             :key #'car))))))

(ert-deftest harness-demo-control-takes-and-returns ()
  "The reviewer takes the computer, and gives it back."
  (harness-demo-test-with-world
      (list :workspace (harness-demo-test--kitchen)
            :box (harness-demo-test--box-status))
    (let* ((answer (harness-call 'demo/start "s1" "demo-1"))
           (run (plist-get answer :run)))
      (should (equal "user" (plist-get (harness-call 'demo/control run "user") :control)))
      (should (harness-demo-test--called-p 'workspace/box/take-over))
      (should (equal "agent" (plist-get (harness-call 'demo/control run "agent") :control)))
      (should (harness-demo-test--called-p 'workspace/box/return-control))
      (should (equal "control-unknown"
                     (plist-get (plist-get (harness-call 'demo/control run "somebody") :reason)
                                :code))))))

(ert-deftest harness-demo-presenter-drives-only-when-it-has-control ()
  "The presenter clicks the computer it was given, and is refused while the
reviewer is using it."
  (harness-demo-test-with-world
      (list :workspace (harness-demo-test--kitchen)
            :box (harness-demo-test--box-status))
    (let* ((answer (harness-call 'demo/start "s1" "demo-1"))
           (run (plist-get answer :run)))
      (let ((result (harness-demo--present (list :run run :action "click" :x 12 :y 34) nil)))
        (should-not (plist-get result :is-error))
        (should (equal '("w-1" 12 34) (cdr (harness-demo-test--called 'workspace/box/click)))))
      (harness-call 'demo/control run "user")
      (setq harness-demo-test--calls nil)
      (let ((result (harness-demo--present (list :run run :action "click" :x 1 :y 2) nil)))
        (should (plist-get result :is-error))
        (should (string-match-p "reviewer has control" (plist-get result :content)))
        (should-not (harness-demo-test--called-p 'workspace/box/click))))))

(ert-deftest harness-demo-status-of-an-unknown-run-is-lost ()
  "A run this harness did not make is lost, not running."
  (let ((answer (harness-call 'demo/status "run-gone")))
    (should (equal "lost" (plist-get answer :state)))
    (should (equal "unknown-run" (plist-get (plist-get answer :reason) :code)))))

(ert-deftest harness-demo-vnc-socket-is-the-page-s-websocket ()
  "The box's noVNC page names the socket an RFB client speaks to."
  (should (equal "ws://127.0.0.1:6080/websockify"
                 (harness-demo--socket "http://127.0.0.1:6080/vnc.html?autoconnect=1")))
  (should (equal "wss://box.test/websockify"
                 (harness-demo--socket "https://box.test/vnc.html")))
  (should (equal "ws://127.0.0.1:5901" (harness-demo--socket "ws://127.0.0.1:5901")))
  (should-not (harness-demo--socket "not a url")))

(provide 'harness-demo-test)
;;; harness-demo-test.el ends here
