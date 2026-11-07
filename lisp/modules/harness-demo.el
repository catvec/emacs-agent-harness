;;; harness-demo.el --- Run a hand-in's demo on the workspace computer  -*- lexical-binding: t; -*-

;;; Commentary:

;; A hand-in's demo is evidence the reviewer can try, and the review
;; wants to try it where the work runs: on the workspace's computer,
;; with the reviewer watching that computer's screen and the presenter
;; talking them through it.  This module is that one flow.  The app's
;; Start demo asks for it (`demo/start'); the answer says what it got
;; and where, so the app can draw the computer's screen, or say plainly
;; why it cannot.
;;
;; The demo is bound, not guessed.  `demo/start' takes the session that
;; handed the work in, resolves its task (`task/for-session') and the
;; demo in the task's last hand-in report, and records that binding in
;; the run: the task, the demo, the reviewed commit of the task's
;; worktree, and the workspace.  The workspace is the one the demo names
;; in its evidence (`:workspace' on the demo, which `hand_in' records),
;; else the one workspace whose root holds the task's project; a start
;; that names none runs the demo where the harness does, and says so
;; (`:placement "host"').  A demo whose reviewed worktree has moved
;; (`:worktree-dirty'), or whose box is not on the reviewed commit, is
;; not started: it would be showing other source than the one reviewed.
;;
;; On a workspace the demo runs on its computer, through that module's
;; methods (`workspace/box/*': `status', `exec', `vnc', `take-over',
;; `return-control', `launch', `browser/open').  That module belongs to
;; the workspace work (task t-ies2341h) and is not in this branch yet:
;; when its methods are not registered the answer is
;; `not-ready'/`box-methods-missing', naming them, and nothing is
;; pretended.  The box's screen comes back as its VNC endpoint; the app
;; speaks RFB to the socket the endpoint's page uses (`:socket'), which
;; is the only way to show it without a web view.
;;
;; The presenter is a BTW of the task's session (`session/btw'), opened
;; and briefed by the start, so that the voice the reviewer talks to and
;; the demo they watch are the same run: the brief names the run id, the
;; workspace, the commit and the tool that drives it (`present_demo').
;; The tool calls the same box methods on the run's workspace and
;; refuses while the reviewer has control of the computer.
;;
;; A run is what one start made: the process, the launch or the box
;; exec it began, the workspace it used, the presenter it opened.
;; `demo/stop' stops that and nothing else -- not the box, not the
;; presenter's conversation -- and returns control to the agent when the
;; reviewer had it.  Runs are in memory: after a restart an old run id
;; is `lost', which the app shows rather than a stale screen.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-tools)
(require 'url-parse)

(defvar harness-demo--runs (make-hash-table :test 'equal)
  "Run id -> what `demo/start' made of it.")

(defvar harness-demo--by-key (make-hash-table :test 'equal)
  "Session, demo, placement and workspace -> the run still going for them.
A second Start demo for the same demo, while it runs, is the same run:
the tap twice is one demo.")

(defvar harness-demo--counter 0
  "Counts the runs made, to give each a name of its own.")

(defconst harness-demo--box-methods
  '(workspace/box/status workspace/box/vnc workspace/box/exec
    workspace/box/take-over workspace/box/return-control)
  "The box methods a start on a workspace needs.
`workspace/box/launch' and `workspace/browser/open' are used when they
are there, for a demo that is a page.")

(defconst harness-demo--key-names
  '((return . "Return") (enter . "Return") (backspace . "BackSpace")
    (tab . "Tab") (escape . "Escape") (space . "space")
    (delete . "Delete") (up . "Up") (down . "Down")
    (left . "Left") (right . "Right") (home . "Home") (end . "End")
    (page-up . "Prior") (page-down . "Next"))
  "The keys `present_demo' names, as an X server names them.")

;;;; Reasons

(defun harness-demo--reason (code text)
  "Return the reason a start or a status gives: CODE, and TEXT to read."
  (list :code code :text text))

(defconst harness-demo--error-codes '("spawn-failed" "box-status-failed" "control-failed")
  "Reason codes that are failures, not a workspace that is not ready.")

(defun harness-demo--failed (code text)
  "Return an answer that nothing runs, with reason CODE and TEXT.
A failure of the harness or the box is `error'; a demo that is not
ready to run is `not-ready'."
  (list :state (if (member code harness-demo--error-codes) "error" "not-ready")
        :reason (harness-demo--reason code text) :run nil))

(defun harness-demo--answer (state reason &rest rest)
  "Return an answer in STATE, with REASON and REST."
  (append (list :state state :reason reason) rest))

;;;; Runs

(defun harness-demo--new-run-id ()
  "Return an id no other run has."
  (format "run-%s-%04x"
          (format-time-string "%y%m%d%H%M%S")
          (cl-incf harness-demo--counter)))

(defun harness-demo--run (run)
  "Return the run record RUN (an id) has, or nil."
  (and (stringp run) (gethash run harness-demo--runs)))

(defun harness-demo--key (session demo placement workspace)
  "Return the key a run of DEMO of SESSION, on PLACEMENT and WORKSPACE, has."
  (format "%s|%s|%s|%s" session demo placement workspace))

(defun harness-demo--live-run (key)
  "Return the run KEY names while it runs, or nil."
  (let ((run (gethash key harness-demo--by-key)))
    (when (and run (equal (harness-demo--state run) "running"))
      run)))

(defun harness-demo--state (run)
  "Return the state of RUN now.
A host process that ended stopped; a box exec that failed was lost; a
run that was stopped stays stopped, whatever its process did after."
  (let ((state (plist-get run :state)))
    (cond
     ((equal state "stopped") "stopped")
     ((eq (plist-get run :exec-state) 'lost) "lost")
     ((eq (plist-get run :exec-state) 'done) "stopped")
     ((let ((process (plist-get run :process)))
        (and process (not (process-live-p process))))
      "stopped")
     (t "running"))))

(defun harness-demo--string (value)
  "Return VALUE as a non-blank string, or nil."
  (let ((text (and (stringp value) (string-trim value))))
    (and text (not (string-empty-p text)) text)))

;;;; The reviewed demo

(defun harness-demo--task (session)
  "Return the task whose session is SESSION, or nil."
  (when (and (harness-demo--string session)
             (harness-method-exists-p 'task/for-session))
    (ignore-errors (harness-call 'task/for-session session))))

(defun harness-demo--report (task)
  "Return the hand-in report of TASK, or nil."
  (let ((report (plist-get task :report)))
    (and (listp report) (plist-member report :evidence) report)))

(defun harness-demo--demos (report)
  "Return the demo evidence of REPORT, each with an `:id'.
A report written before demos had ids numbers them as the review does:
`demo-1' is the first demo among the evidence."
  (let ((n 0))
    (cl-loop for item in (plist-get report :evidence)
             when (equal (plist-get item :kind) "demo")
             collect (plist-put (copy-sequence item)
                                :id (or (harness-demo--string (plist-get item :id))
                                        (format "demo-%d" (cl-incf n)))))))

(defun harness-demo--demo (report id)
  "Return the demo of REPORT named ID, or nil."
  (cl-find id (harness-demo--demos report)
           :key (lambda (item) (plist-get item :id)) :test #'equal))

(defun harness-demo--title (item)
  "Return how ITEM, a demo, is named."
  (or (harness-demo--string (plist-get item :title)) "demo"))

(defun harness-demo--artifact (item)
  "Return what ITEM, a demo, is: its page, its place and how it starts."
  (list :name (plist-get item :name)
        :cwd (plist-get item :cwd)
        :url (plist-get item :url)
        :command (plist-get item :command)))

;;;; The workspace and its box

(defun harness-demo--workspace-roots (workspace)
  "Return the directories WORKSPACE says it holds."
  (delq nil (mapcar (lambda (key) (harness-demo--string (plist-get workspace key)))
                    '(:root :project :path :worktree :directory))))

(defun harness-demo--holds-p (root path)
  "Return non-nil when ROOT holds PATH."
  (let ((root (file-name-as-directory (expand-file-name root)))
        (path (file-name-as-directory (expand-file-name path))))
    (or (equal root path) (string-prefix-p root path))))

(defun harness-demo--workspace-match (task)
  "Return the one workspace whose root holds TASK's project, or nil.
A task that one workspace holds is bound to it without the report
naming it; a task no workspace holds, or that two do, is not."
  (when (and (harness-method-exists-p 'workspace/list)
             (harness-method-exists-p 'workspace/get))
    (let* ((places (delq nil (list (plist-get task :worktree)
                                   (plist-get task :project)
                                   (plist-get task :cwd))))
           (matches
            (cl-remove-if-not
             (lambda (workspace)
               (let ((roots (harness-demo--workspace-roots workspace)))
                 (and roots
                      (cl-some (lambda (root)
                                 (cl-some (lambda (place)
                                            (and (stringp place)
                                                 (harness-demo--holds-p root place)))
                                          places))
                               roots))))
             (ignore-errors (harness-call 'workspace/list)))))
      (and matches (null (cdr matches)) (car matches)))))

(defun harness-demo--workspace (task item argument)
  "Return (ID . NAME) of the workspace ITEM of TASK runs in, or nil, or `:unknown'.
ARGUMENT names a workspace, as the start was given one; it wins over
the demo's own, and over the workspace that holds the task."
  (let* ((asked (or (harness-demo--string argument)
                    (harness-demo--string (plist-get item :workspace))))
         (workspace (if (not asked)
                        (harness-demo--workspace-match task)
                      (and (harness-method-exists-p 'workspace/get)
                           (ignore-errors (harness-call 'workspace/get asked))))))
    (cond ((eq workspace :unknown) :unknown)
          ((null workspace) (and asked :unknown))
          (asked (cons (or (harness-demo--string (plist-get workspace :id)) asked)
                       (harness-demo--string (plist-get workspace :name))))
          (t (cons (harness-demo--string (plist-get workspace :id))
                   (harness-demo--string (plist-get workspace :name)))))))

(defun harness-demo--missing-box-methods ()
  "Return the box methods a start needs that this harness does not have."
  (cl-remove-if #'harness-method-exists-p harness-demo--box-methods))

(defun harness-demo--box-status (id)
  "Return the status of the box of workspace ID, or a reason it is not there."
  (condition-case err
      (let ((status (harness-call 'workspace/box/status id)))
        (cond ((harness-promise-p status)
               (harness-demo--reason "box-status-failed"
                                     "the box answered with a promise"))
              ((not (listp status))
               (harness-demo--reason "box-status-failed" "no answer from the box"))
              (t status)))
    (error (harness-demo--reason "box-status-failed"
                                 (harness-error-message err)))))

(defun harness-demo--box-running-p (status)
  "Return non-nil when STATUS says the box runs."
  (let ((running (plist-get status :running))
        (available (plist-get status :available))
        (health (harness-demo--string (plist-get status :health))))
    (cond ((harness-json-true-p running) t)
          ((eq running :false) nil)
          ((harness-json-true-p available) t)
          ((eq available :false) nil)
          (health (member (downcase health) '("running" "ready" "ok" "healthy")))
          ;; A status with neither says the box is there but says nothing
          ;; of whether it runs: a box that answered at all is taken as
          ;; up, and a start that fails says so.
          (t t))))

(defun harness-demo--mount (status host-cwd)
  "Return where HOST-CWD is inside the box STATUS describes, or nil.
A box that reports no mounts runs on this machine and sees HOST-CWD as
it is; a box that reports mounts and none holds the directory has not
got the reviewed source, and nil says so."
  (let ((mounts (plist-get status :mounts)))
    (cond
     ((null mounts) host-cwd)
     ((not (listp mounts)) host-cwd)
     (t (cl-loop
         for mount in mounts
         for host = (or (harness-demo--string (plist-get mount :host))
                        (harness-demo--string (car-safe mount)))
         for box = (or (harness-demo--string (plist-get mount :box))
                       (harness-demo--string (plist-get mount :target))
                       (and (consp mount) (stringp (cdr-safe mount))
                            (harness-demo--string (cdr-safe mount))))
         when (and host box (harness-demo--holds-p host host-cwd))
         return (expand-file-name (file-relative-name host-cwd host) box))))))

;;;; The reviewed commit

(defun harness-demo--git (directory &rest args)
  "Run git with ARGS in DIRECTORY; return its trimmed output, or nil.
A small query the start cannot wait for a promise to answer."
  (when (and (stringp directory) (file-directory-p directory))
    (with-temp-buffer
      (when (eq 0 (ignore-errors
                    (apply #'call-process "git" nil t nil
                           "-C" directory args)))
        (harness-demo--string (buffer-string))))))

(defun harness-demo--reviewed (task)
  "Return what TASK's worktree is now: its commit and whether it is dirty."
  (let ((directory (or (plist-get task :worktree) (plist-get task :project))))
    (list :commit (harness-demo--git directory "rev-parse" "--verify" "HEAD")
          :dirty (and (harness-demo--git directory "status" "--porcelain"
                                         "--untracked-files=no")
                      t))))

;;;; VNC

(defun harness-demo--socket (url)
  "Return the websocket URL an RFB client speaks to, from the box's URL.
The box publishes a noVNC page on a port of its own; the websocket the
page uses is that port's `/websockify'.  A URL that is already a
websocket is itself."
  (let ((uri (and (stringp url) (url-generic-parse-url url))))
    (when uri
      (let ((scheme (url-type uri))
            (host (url-host uri))
            (port (url-portspec uri)))
        (cond
         ((member scheme '("ws" "wss")) url)
         ((member scheme '("http" "https"))
          (format "%s://%s%s/websockify"
                  (if (equal scheme "https") "wss" "ws")
                  host
                  (if port (format ":%s" port) "")))
         (t nil))))))

(defun harness-demo--vnc (workspace-id)
  "Return the VNC endpoint of workspace WORKSPACE-ID, as the app needs it."
  (if (not (harness-method-exists-p 'workspace/box/vnc))
      (list :available :false :url nil :socket nil
            :reason (harness-demo--reason "box-methods-missing"
                                          "workspace box methods missing"))
    (condition-case err
        (let ((endpoint (harness-call 'workspace/box/vnc workspace-id)))
          (if (not (and (listp endpoint) (harness-demo--string (plist-get endpoint :url))))
              (list :available :false :url nil :socket nil
                    :reason (harness-demo--reason "vnc-unavailable"
                                                  "no VNC endpoint"))
            (let ((url (harness-demo--string (plist-get endpoint :url))))
              (list :url url
                    :socket (or (harness-demo--string (plist-get endpoint :socket))
                                (harness-demo--socket url))
                    :state (or (harness-demo--string (plist-get endpoint :state))
                               "agent")
                    :token (plist-get endpoint :token)
                    :available t
                    :reason nil))))
      (error
       (list :available :false :url nil :socket nil
             :reason (harness-demo--reason "vnc-unavailable"
                                           (harness-error-message err)))))))

;;;; Starting

(defun harness-demo--placement (argument workspace)
  "Return where a demo runs: \"workspace\" or \"host\".
ARGUMENT, when it names one, wins; a demo bound to a workspace runs
there; anything else runs where the harness does."
  (let ((asked (harness-demo--string argument)))
    (cond ((member asked '("workspace" "host")) asked)
          (workspace "workspace")
          (t "host"))))

(defun harness-demo--start-answer (run reason)
  "Return the answer for RUN, started, with REASON."
  (let ((view (harness-demo--view run)))
    (plist-put view :reason reason)))

(defun harness-demo--command-string (argv)
  "Return ARGV as one command line, each argument quoted for a shell."
  (mapconcat #'shell-quote-argument argv " "))

(defun harness-demo--start-host (task item run)
  "Start ITEM of TASK where the harness does, for RUN.
A demo that is a page is already served: nothing is started, and the
answer says where it is.  A demo with a command runs in a buffer of its
own, which the run owns and `demo/stop' stops."
  (let* ((command (plist-get item :command))
         (url (plist-get item :url))
         (cwd (or (harness-demo--string (plist-get item :cwd))
                  (plist-get task :worktree) (plist-get task :project))))
    (cond
     ((and (listp command) command)
      (if (not (and cwd (file-directory-p cwd)))
          (harness-demo--failed "demo-not-runnable" "no directory for the demo")
        (let* ((title (harness-demo--title item))
               (buffer (get-buffer-create (format "*harness demo: %s*" title))))
          (with-current-buffer buffer
            (let ((inhibit-read-only t))
              (erase-buffer)
              (insert (format "$ %s\n\n" (harness-demo--command-string command)))))
          (condition-case err
              (let ((default-directory cwd)
                    (process (make-process
                              :name (format "harness demo: %s" title)
                              :buffer buffer :stderr buffer
                              :command command :noquery t
                              :connection-type 'pipe
                              ;; The run asks its process when it is
                              ;; read: a demo that ended by itself is
                              ;; `stopped' the next time it is looked at.
                              :sentinel #'ignore)))
                (set-process-query-on-exit-flag process nil)
                (plist-put run :process process)
                (plist-put run :state "running")
                (harness-demo--start-answer
                 run (harness-demo--reason "started" "on the harness machine")))
            (error
             (harness-demo--failed "spawn-failed" (harness-error-message err)))))))
     (url
      (plist-put run :state "running")
      (harness-demo--start-answer
       run (harness-demo--reason "served" "served, on the harness machine")))
     (t (harness-demo--failed "demo-not-runnable"
                              "demo without a command or a page")))))

(defun harness-demo--exec-in-box (workspace-id command cwd run)
  "Run COMMAND on the box of WORKSPACE-ID in CWD, for RUN.
The box's exec may take the work in the background (`:background'), or
may not know that option and run it as the start's own call: the
promise is kept, and a demo that answers with an exit status is over
while one that answers nothing of the sort is still running."
  (let* ((background (harness-call-async 'workspace/box/exec workspace-id command
                                         :cwd cwd :background t))
         (settle (lambda (result)
                   (plist-put run :exec-state
                              (if (integerp (plist-get result :status)) 'done 'running))
                   (plist-put run :output result)
                   (unless (integerp (plist-get result :status))
                     (plist-put run :detached t))
                   nil))
         (lose (lambda (err)
                 (plist-put run :exec-state 'lost)
                 (plist-put run :reason
                            (harness-demo--reason "spawn-failed"
                                                  (harness-error-message
                                                   (if (stringp err) (list 'harness-error err) err))))
                 nil))
         (start (lambda (promise)
                  (harness-then promise settle
                                (lambda (err)
                                  ;; A box that does not know `:background'
                                  ;; runs the command without it.
                                  (if (string-match-p "background\\|unknown\\|unrecognized"
                                                      (format "%s" err))
                                      (harness-then
                                       (harness-call-async 'workspace/box/exec workspace-id command
                                                           :cwd cwd)
                                       settle lose)
                                    (funcall lose err)))))))
    (funcall start background)))

(defun harness-demo--open-in-box (workspace-id item run)
  "Open ITEM's page on the box of WORKSPACE-ID, for RUN."
  (let ((url (harness-demo--string (plist-get item :url))))
    (when url
      (let ((promise
             (cond ((harness-method-exists-p 'workspace/browser/open)
                    (harness-call-async 'workspace/browser/open workspace-id url))
                   ((harness-method-exists-p 'workspace/box/launch)
                    (harness-call-async 'workspace/box/launch workspace-id url))
                   (t nil))))
        (when promise
          (plist-put run :opened promise)
          (harness-then promise
                        (lambda (result) (plist-put run :open-result result) nil)
                        (lambda (err)
                          (plist-put run :open-error (format "%s" err))
                          nil)))))))

(defun harness-demo--start-workspace (task item run workspace status)
  "Start ITEM of TASK on WORKSPACE, whose box answered STATUS, for RUN."
  (let* ((id (car workspace))
         (cwd (or (harness-demo--string (plist-get item :cwd))
                  (plist-get task :worktree) (plist-get task :project)))
         (box-cwd (and cwd (harness-demo--mount status cwd))))
    (cond
     ((not (harness-demo--box-running-p status))
      (harness-demo--failed "box-not-running" "workspace computer not running"))
     ((not box-cwd)
      (harness-demo--failed "mount-missing"
                            "no workspace mount for the demo's directory"))
     (t
      (plist-put run :state "running")
      (plist-put run :box-cwd box-cwd)
      (when (and (listp (plist-get item :command)) (plist-get item :command))
        (harness-demo--exec-in-box id
                                   (harness-demo--command-string (plist-get item :command))
                                   box-cwd run))
      (harness-demo--open-in-box id item run)
      (when (and (not (plist-get item :command))
                 (not (harness-demo--string (plist-get item :url))))
        (harness-demo--failed "demo-not-runnable"
                              "demo without a command or a page"))
      (harness-demo--start-answer
       run (harness-demo--reason "started" "on the workspace computer"))))))

(defun harness-demo--brief (task item run)
  "Return the presenter's brief for ITEM of TASK, running as RUN.
The presenter is the reviewer's voice and hands: it drives the demo
with `present_demo' on the run's computer, one step at a time, and
answers what the reviewer asks without changing the work."
  (let* ((title (harness-demo--title item))
         (prompt (or (plist-get task :prompt) ""))
         (task-title (harness-first-line (if (harness-string-blank-p prompt) "the task" prompt) 80))
         (placement (plist-get run :placement))
         (workspace (plist-get run :workspace))
         (run-id (plist-get run :id))
         (commit (plist-get run :commit))
         (narration (harness-demo--string (plist-get item :narration)))
         (walkthrough (harness-demo--string (plist-get (harness-demo--report task) :walkthrough)))
         (where
          (if (equal placement "workspace")
              (format "The demo is already running on the workspace computer %s, and the reviewer is watching that computer's screen in the app."
                      (or (plist-get run :workspace-name) workspace))
            "The demo runs on the harness's machine; the reviewer cannot see that screen in the app."))
         (parts
          (delq nil
                (list
                 (format "You are presenting the demo \"%s\" of the task \"%s\" to its reviewer, by voice. The task is in review: do not change files, do not call hand_in, and do not send the task back." title task-title)
                 where
                 (if (equal placement "workspace")
                     (format "Drive that computer with the present_demo tool: run \"%s\", action \"click\" with x and y, \"type\" with text, \"key\" with a key name, \"scroll\", \"drag\", \"open\" with a url, \"launch\" with what, \"windows\" to list what is open, and \"screenshot\" to look at it. The reviewer can take control of the computer at any time; while they have it the tool refuses, so wait, and carry on when they hand it back." run-id)
                   (format "The run is \"%s\"." run-id))
                 (if commit (format "The reviewed commit is %s." commit) nil)
                 (format "Start with one sentence on what the demo shows, then do one step and wait for the reviewer before the next. Keep replies short: they are spoken. The reviewer may interrupt at any time: stop, answer, then carry on where you were.")
                 (if narration (format "How to show it:\n%s" narration) nil)
                 (if walkthrough (format "The report's own brief, for what the work is:\n%s"
                                         (harness-truncate-end walkthrough 6000))
                   nil)))))
    (harness-truncate-end (string-join parts "\n\n") 12000)))

(defun harness-demo--presenter (task item run)
  "Open the presenter of ITEM for RUN: a BTW of TASK's session, briefed.
Return the presenter's plist, or nil when no conversation can be
opened; the demo still runs, and the answer says there is no presenter."
  (let ((session (plist-get task :session)))
    (when (and (harness-demo--string session)
               (harness-method-exists-p 'session/btw)
               (harness-method-exists-p 'agent/prompt))
      (condition-case err
          (let* ((model (and (harness-method-exists-p 'session/get)
                             (ignore-errors (plist-get (harness-call 'session/get session) :model))))
                 (name (harness-truncate-end
                        (format "demo: %s" (harness-demo--title item)) 60))
                 (btw (harness-call 'session/btw session name model))
                 (id (plist-get btw :id)))
            (when (harness-demo--string id)
              (harness-call-async 'agent/prompt id
                                  (list (list :type "text"
                                              :text (harness-demo--brief task item run))))
              (list :session id :name name)))
        (error
         (harness-log 'warn "demo: no presenter: %s" (harness-error-message err))
         nil)))))

(defun harness-demo--begin (task item placement workspace run reviewed)
  "Start ITEM of TASK for RUN, as PLACEMENT and WORKSPACE say, at REVIEWED.
Return the answer for the start itself; a demo that is not ready
answers with the reason it is not."
  (cond
   ((plist-get reviewed :dirty)
    (harness-demo--failed "worktree-dirty"
                          "reviewed worktree with changes since the hand-in"))
   ((equal placement "host")
    (harness-demo--start-host task item run))
   ((not workspace)
    (harness-demo--failed "workspace-missing"
                          "no workspace bound to this demo"))
   ((not (car-safe workspace))
    (harness-demo--failed "workspace-unknown" "unknown workspace"))
   ((harness-demo--missing-box-methods)
    (harness-demo--failed
     "box-methods-missing"
     (format "workspace box methods missing: %s"
             (mapconcat (lambda (method) (format "%s" method))
                        (harness-demo--missing-box-methods) ", "))))
   (t
    (let ((status (harness-demo--box-status (car workspace))))
      (if (harness-demo--reason-p status)
          (harness-demo--failed (plist-get status :code) (plist-get status :text))
        (let ((box-commit (harness-demo--string (plist-get status :commit))))
          (cond
           ((and box-commit (plist-get reviewed :commit)
                 (not (string-prefix-p
                       (downcase box-commit)
                       (downcase (plist-get reviewed :commit)))))
            (harness-demo--failed
             "commit-mismatch"
             (format "workspace on %s, not %s"
                     (substring box-commit 0 (min 10 (length box-commit)))
                     (substring (plist-get reviewed :commit) 0 10))))
           (t
            (plist-put run :commit-verified (if box-commit t :false))
            (harness-demo--start-workspace task item run workspace status)))))))))

(defun harness-demo--began (task item placement run)
  "Return RUN as it is once a start on PLACEMENT began, presenter and all.
The presenter is opened here so that the conversation the reviewer
talks to is the one the demo's run was briefed for."
  (let ((presenter (harness-demo--presenter task item run))
        (vnc (when (equal placement "workspace")
               (harness-demo--vnc (plist-get run :workspace)))))
    (plist-put run :presenter presenter)
    (plist-put run :vnc vnc)
    (let ((answer (harness-demo--view run)))
      (when (and vnc (not (harness-json-true-p (plist-get vnc :available))))
        (plist-put answer :reason
                   (harness-demo--reason
                    "vnc-unavailable"
                    "no screen from the workspace computer")))
      answer)))

(defun harness-demo--start (task item placement workspace)
  "Start ITEM of TASK on PLACEMENT in WORKSPACE, and return the answer.
The run is the same run as the one a start of the same demo made while
that one still runs: a second tap is not a second demo."
  (let* ((session (plist-get task :session))
         (demo (plist-get item :id))
         (workspace-id (car-safe workspace))
         (key (harness-demo--key session demo placement workspace-id))
         (running (harness-demo--live-run key)))
    (cond
     (running
      (harness-demo--start-answer
       running (harness-demo--reason "already-running" "demo already running")))
     (t
      (let* ((reviewed (harness-demo--reviewed task))
             (run (list :id (harness-demo--new-run-id)
                        :session session :task (plist-get task :id)
                        :demo demo :title (harness-demo--title item)
                        :placement placement
                        :workspace workspace-id
                        :workspace-name (cdr-safe workspace)
                        :commit (plist-get reviewed :commit)
                        :commit-verified :false
                        :artifact (harness-demo--artifact item)
                        :launch (list :command (plist-get item :command)
                                      :cwd (or (harness-demo--string (plist-get item :cwd))
                                               (plist-get task :worktree)
                                               (plist-get task :project)))
                        :control "agent"
                        :at (float-time)
                        :state "starting")))
        (puthash (plist-get run :id) run harness-demo--runs)
        (puthash key run harness-demo--by-key)
        (let ((answer (harness-demo--begin task item placement workspace run reviewed)))
          (if (equal (plist-get answer :state) "running")
              (harness-demo--began task item placement run)
            (plist-put run :state "stopped")
            (plist-put run :reason (plist-get answer :reason))
            answer)))))))

;;;; What a run is now

(defun harness-demo--reason-p (value)
  "Return non-nil when VALUE is a reason, not a status."
  (and (listp value) (plist-member value :code) (plist-member value :text)))

(defun harness-demo--view (run)
  "Return RUN now, as the app reads it."
  (let* ((state (harness-demo--state run))
         (placement (plist-get run :placement))
         (vnc (when (and (equal placement "workspace")
                         (harness-demo--string (plist-get run :workspace)))
                (if (equal state "running")
                    (harness-demo--vnc (plist-get run :workspace))
                  (let ((last (plist-get run :vnc)))
                    (and last (plist-put (copy-sequence last) :available :false)))))))
    (list :state state
          :reason (plist-get run :reason)
          :run (plist-get run :id)
          :task (plist-get run :task)
          :demo (plist-get run :demo)
          :title (plist-get run :title)
          :placement placement
          :workspace (plist-get run :workspace)
          :workspace-name (plist-get run :workspace-name)
          :commit (plist-get run :commit)
          :commit-verified (plist-get run :commit-verified)
          :artifact (plist-get run :artifact)
          :launch (plist-get run :launch)
          :vnc vnc
          :control (if vnc (or (plist-get vnc :state) (plist-get run :control) "agent")
                     (plist-get run :control))
          :presenter (plist-get run :presenter)
          :at (plist-get run :at)
          :stopped (if (equal state "stopped") t :false))))

;;;; The methods

(harness-defmethod demo/start (session demo &optional placement workspace)
  "Start the demo DEMO of the hand-in SESSION is in review for.
DEMO is the demo's id in the report (`demo-1').  PLACEMENT is
\"workspace\" or \"host\"; the default is the workspace the demo is
bound to, else where the harness does.  WORKSPACE names the workspace
to use in place of the bound one.

Return the run: its state (`running', `lost', `stopped'), the task and
demo it bound, the reviewed commit, the workspace it used, its VNC
endpoint when it has a screen, who has control of the computer, and the
presenter conversation briefed to drive it.  A demo that cannot be
started answers `not-ready' with a reason: `no-task', `no-report',
`no-demo', `worktree-dirty', `workspace-missing', `workspace-unknown',
`box-methods-missing', `box-not-running`, `box-status-failed',
`mount-missing', `commit-mismatch', `demo-not-runnable' or
`spawn-failed'.  Nothing is started twice: a start of a demo that still
runs answers that run."
  (let* ((task (harness-demo--task session))
         (report (and task (harness-demo--report task)))
         (item (and report (harness-demo--demo report demo))))
    (cond
     ((not task)
      (harness-demo--failed "no-task" "no task for this session"))
     ((not report)
      (harness-demo--failed "no-report" "no hand-in report"))
     ((not item)
      (harness-demo--failed "no-demo" "no such demo in the report"))
     (t
      (let ((found (harness-demo--workspace task item workspace)))
        (if (eq found :unknown)
            (harness-demo--failed "workspace-unknown" "unknown workspace")
          (let ((place (harness-demo--placement placement found)))
            (if (and (equal place "workspace") (not found))
                (harness-demo--failed "workspace-missing"
                                      "no workspace bound to this demo")
              (harness-demo--start task item place found)))))))))

(harness-defmethod demo/status (run)
  "Return RUN as it is now.
An unknown run -- one this harness did not start, or started before it
was restarted -- is `lost': the app shows that rather than a screen
that no longer moves."
  (let ((record (harness-demo--run run)))
    (if (not record)
        (harness-demo--answer "lost"
                              (harness-demo--reason "unknown-run" "no such run")
                              :run run)
      (harness-demo--view record))))

(harness-defmethod demo/stop (run)
  "Stop RUN, and only what RUN started.
A demo on the harness's machine has its process killed; a demo on a
workspace computer has control returned to the presenter, and the
computer itself is left as it is -- it is not this run's to stop.  The
presenter's conversation stays.  Stopping a run twice is the same as
stopping it once."
  (let ((record (harness-demo--run run)))
    (cond
     ((not record)
      (harness-demo--answer "lost" (harness-demo--reason "unknown-run" "no such run")
                            :run run :stopped :false))
     ((equal (harness-demo--state record) "stopped")
      (harness-demo--view record))
     (t
      (let ((process (plist-get record :process))
            (vnc (plist-get record :vnc)))
        (when (and process (process-live-p process))
          (delete-process process))
        (when (and (equal (plist-get record :placement) "workspace")
                   (harness-method-exists-p 'workspace/box/return-control)
                   (harness-demo--string (plist-get record :workspace))
                   (equal (plist-get vnc :state) "user"))
          (ignore-errors
            (harness-call 'workspace/box/return-control (plist-get record :workspace))))
        (when (and (plist-get record :presenter)
                   (harness-method-exists-p 'session/hint)
                   (harness-demo--string (plist-get (plist-get record :presenter) :session)))
          (ignore-errors
            (harness-call 'session/hint
                          (plist-get (plist-get record :presenter) :session)
                          "Demo stopped")))
        (plist-put record :state "stopped")
        (plist-put record :control "agent")
        (ignore-errors (remhash (harness-demo--key (plist-get record :session)
                                                   (plist-get record :demo)
                                                   (plist-get record :placement)
                                                   (plist-get record :workspace))
                                harness-demo--by-key))
        (harness-demo--view record))))))

(harness-defmethod demo/control (run control)
  "Give CONTROL of RUN's computer to \"user\" or to \"agent\".
Return the run as it is then, with the control the computer reports.
A harness without the box's takeover methods answers the run unchanged,
with a reason saying so."
  (let ((record (harness-demo--run run)))
    (cond
     ((not record)
      (harness-demo--answer "lost" (harness-demo--reason "unknown-run" "no such run")
                            :run run))
     ((not (member control '("user" "agent")))
      (harness-demo--answer (harness-demo--state record)
                            (harness-demo--reason "control-unknown"
                                                  "unknown control")
                            :run run))
     ((not (equal (plist-get record :placement) "workspace"))
      (harness-demo--answer (harness-demo--state record)
                            (harness-demo--reason "no-computer"
                                                  "demo without a computer")
                            :run run))
     ((not (harness-method-exists-p (if (equal control "user")
                                        'workspace/box/take-over
                                      'workspace/box/return-control)))
      (harness-demo--answer (harness-demo--state record)
                            (harness-demo--reason "box-methods-missing"
                                                  "workspace box methods missing")
                            :run run))
     (t
      (condition-case err
          (progn
            (harness-call (if (equal control "user")
                              'workspace/box/take-over
                            'workspace/box/return-control)
                          (plist-get record :workspace))
            (plist-put record :control control)
            (let ((answer (harness-demo--view record)))
              (plist-put answer :control control)))
        (error
         (harness-demo--answer (harness-demo--state record)
                               (harness-demo--reason "control-failed"
                                                     (harness-error-message err))
                               :run run)))))))

;;;; The presenter's hands

(defun harness-demo--present-error (text)
  "Return a failed `present_demo' saying TEXT."
  (harness-tool-error text))

(defun harness-demo--screenshot (workspace-id)
  "Return the box of WORKSPACE-ID's screen as a tool result, or nil.
The screenshot is written to a temporary file so that the presenter can
see it, as `read_file' shows a picture."
  (let ((shot (harness-call 'workspace/box/screenshot workspace-id)))
    (let ((data (plist-get shot :data))
          (mime (or (harness-demo--string (plist-get shot :mime)) "image/png"))
          (width (plist-get shot :width))
          (height (plist-get shot :height)))
      (when (harness-demo--string data)
        (let* ((extension (if (string-match-p "jpe?g" mime) ".jpg" ".png"))
               (file (make-temp-file "harness-demo-screen-" nil extension))
               (bytes (base64-decode-string data)))
          (with-temp-file file (set-buffer-multibyte nil) (insert bytes))
          (harness-tool-ok
           (format "Screenshot of the workspace computer%s"
                   (if (and width height) (format " (%dx%d)" width height) ""))
           :attachments (list (list :path file :mime mime))
           :images (list (list :path file :mime mime))))))))

(defun harness-demo--present (input _ctx)
  "Handle the present_demo tool: drive the demo of run INPUT[:run].
The presenter may work the computer the run started and nothing else;
while the reviewer has its control the tool refuses, so that the two
are never typing at once."
  (let* ((run-id (harness-demo--string (plist-get input :run)))
         (action (harness-demo--string (plist-get input :action)))
         (record (harness-demo--run run-id))
         (workspace (and record (harness-demo--string (plist-get record :workspace)))))
    (cond
     ((not record)
      (harness-demo--present-error "No such demo run"))
     ((not (equal (harness-demo--state record) "running"))
      (harness-demo--present-error "The demo is not running"))
     ((not (equal (plist-get record :placement) "workspace"))
      (harness-demo--present-error "The demo has no workspace computer to drive"))
     ((equal (plist-get record :control) "user")
      (harness-demo--present-error
       "The reviewer has control of the computer; wait for them to hand it back"))
     (t
      (let* ((x (plist-get input :x))
             (y (plist-get input :y))
             (key (harness-demo--string (plist-get input :key)))
             (keysym (and key (or (cdr (assq (intern (downcase key)) harness-demo--key-names))
                                  (and (= 1 (length key)) key))))
             (method
              (pcase action
                ("click" (and (numberp x) (numberp y) 'workspace/box/click))
                ("type" (and (stringp (plist-get input :text)) 'workspace/box/type))
                ("key" (and keysym 'workspace/box/key))
                ("scroll" (and (numberp x) (numberp y) (numberp (plist-get input :amount))
                               'workspace/box/scroll))
                ("drag" (and (numberp x) (numberp y)
                             (numberp (plist-get input :to-x))
                             (numberp (plist-get input :to-y))
                             'workspace/box/drag))
                ("windows" 'workspace/box/windows)
                ("screenshot" (and (harness-method-exists-p 'workspace/box/screenshot)
                                   'workspace/box/screenshot))
                ("open" (and (harness-demo--string (plist-get input :url))
                             (cond ((harness-method-exists-p 'workspace/browser/open)
                                    'workspace/browser/open)
                                   ((harness-method-exists-p 'workspace/box/launch)
                                    'workspace/box/launch))))
                ("launch" (and (harness-demo--string (plist-get input :what))
                               'workspace/box/launch))
                (_ nil))))
        (cond
         ((not (harness-method-exists-p 'workspace/box/status))
          (harness-demo--present-error "The workspace box is not in this harness"))
         ((not method)
          (harness-demo--present-error
           (format "present_demo: action %s needs its arguments (x and y, text, key, amount, url or what)"
                   (or action "?"))))
         (t
          (condition-case err
              (let ((result
                     (pcase action
                       ("click" (harness-call method workspace x y))
                       ("type" (harness-call method workspace (plist-get input :text)))
                       ("key" (harness-call method workspace keysym))
                       ("scroll" (harness-call method workspace x y (plist-get input :amount)))
                       ("drag" (harness-call method workspace (list x y)
                                             (list (plist-get input :to-x)
                                                   (plist-get input :to-y))))
                       ("windows" (harness-call method workspace))
                       ("screenshot" (harness-demo--screenshot workspace))
                       ("open" (harness-call method workspace (plist-get input :url)))
                       ("launch" (harness-call method workspace (plist-get input :what))))))
                (cond
                 ((and (listp result) (plist-member result :is-error))
                  result)
                 ((stringp result) (harness-tool-ok result))
                 ((null result) (harness-tool-ok (format "%s done" action)))
                 (t (harness-tool-ok
                     (format "%s: %s" action
                             (if (listp result)
                                 (plist-get result :content)
                               result))))))
            (error
             (harness-demo--present-error
              (format "%s failed: %s" action (harness-error-message err))))))))))))

(harness-define-tool "present_demo"
  :label "Present the demo"
  :description "Drive the workspace computer a hand-in demo runs on, as its presenter. Use the run the demo's start gave you. Actions: click (x, y), type (text), key (a key name such as Return, Tab, Escape, Left, or one character), scroll (x, y, amount), drag (x, y to-x to-y), windows (what is open), screenshot (what the screen shows now), open (a url in the computer's browser), launch (an app). It refuses while the reviewer has control of the computer: wait for them to hand it back. Do not use it to change the work."
  :schema '(:type "object"
            :properties (:run (:type "string" :description "The demo run, as started.")
                         :action (:type "string"
                                  :enum ("click" "type" "key" "scroll" "drag" "windows" "screenshot" "open" "launch"))
                         :x (:type "number" :description "X in the screen's pixels.")
                         :y (:type "number" :description "Y in the screen's pixels.")
                         :text (:type "string" :description "What to type.")
                         :key (:type "string" :description "The key to press: Return, Tab, Escape, BackSpace, Delete, Up, Down, Left, Right, Home, End, PageUp, PageDown, or one character.")
                         :amount (:type "number" :description "Scroll wheel clicks; negative is up.")
                         :to-x (:type "number" :description "Where a drag ends, X.")
                         :to-y (:type "number" :description "Where a drag ends, Y.")
                         :url (:type "string" :description "What open opens, a URL.")
                         :what (:type "string" :description "What launch starts, an app."))
            :required ("run" "action"))
  :kind 'exec
  :subject (lambda (input) (format "%s %s" (or (plist-get input :action) "drive")
                                   (or (plist-get input :run) "")))
  :handler #'harness-demo--present)

(harness-define-module 'demo
  :doc "Start a hand-in's demo on its workspace computer: the VNC screen, the takeover, and the presenter that drives it."
  :requires '(tools tasks session agent))

(provide 'harness-demo)
;;; harness-demo.el ends here
