;;; harness-tools-dev.el --- Open a checkout's harness in an Emacs  -*- lexical-binding: t; -*-

;;; Commentary:

;; Verifying work on the harness itself means trying it in a running
;; Emacs.  The project's live development loop (scripts/dev.sh) starts
;; a dedicated `emacs -Q' daemon from a checkout -- a task's worktree,
;; say -- under a socket and state directory of its own, and drives it
;; with emacsclient; harness-dev.el in that checkout provides the
;; eval / keys / shot / errors commands.
;;
;; This module makes that instance one call away:
;;
;; - the agent's `open_harness' tool (with `path' defaulting to the
;;   session's worktree), and
;; - the `harness-dev/open' method, which the task board calls from
;;   Open harness, in the menu of a card waiting for review.
;;
;; The tool is for this project only: sessions whose working directory
;; or worktree is a checkout of the harness (`harness.el' and
;; scripts/dev.sh side by side) are offered it, and any other directory
;; is refused.  Starting the instance is repeatable and touches nothing
;; of the session's own; the tool is in
;; `harness-perms-auto-allow-tools', so it needs no approval.
;;
;; Lifetimes.  An instance is a whole Emacs with a harness of its own
;; inside, and nothing in it ever stops it.  So this module records the
;; instances it opens, and who opened each one, in dev-instances.json in
;; the state directory.  It stops each instance once nothing needs it:
;;
;; - An instance an agent opened for itself is needed while that agent
;;   works.  For a task's session, that is until the task stops working:
;;   it goes to review or is done, or stops on an error or a cancel.  For
;;   a sub-agent, it is until its turn ends.  For a session the user
;;   talks to, it is until the session is closed, or has been idle for
;;   `harness-tools-dev--idle-timeout'.
;; - An instance opened for the user to look at -- the board's Open
;;   harness, or the tool with `focus' -- is needed until the task it
;;   shows is done, archived or deleted.  Without a task, it is needed
;;   while the session that opened it is open.
;; - An instance in the worktree of a task or session is also needed
;;   while that task or session is at work.  They share it: the instance
;;   belongs to the worktree, whichever agent opened it.
;; - An instance whose checkout is gone is never needed.
;;
;; The check runs a moment after anything that can end a need: a turn
;; ending, a task moving on, a session closed or deleted, a worktree
;; removed.  The instance of a worktree also stops before the worktree
;; is removed, through the `worktree/before-remove' filter.
;;
;; A sweep of the process table runs a minute after the harness starts
;; and every ten minutes after that.  It finds the instances nobody
;; recorded: those started before this module kept records, or by a
;; harness that has since restarted.  It takes on the ones whose
;; checkout is the worktree of one of this harness's tasks or sessions,
;; or is gone, and checks them like the rest.  Any other instance
;; belongs to somebody else and is left alone, as is the instance this
;; harness runs in.
;;
;; Stopping asks the daemon to exit over emacsclient.  A daemon still
;; alive after that has its process tree killed.  As a last resort, an
;; instance exits by itself once the Emacs the user runs the harness in
;; is gone: HARNESS_DEV_OWNER names that Emacs, and harness-dev.el
;; watches it.  So an Emacs that quits or crashes leaves no instance
;; behind.  A restart of the harness process alone leaves them running:
;; the harness started again reads the record and looks after them.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-tools)

(defvar harness-state-directory)

(defconst harness-tools-dev-tool "open_harness"
  "Name of the tool that opens a checkout's harness in an Emacs.")

(defconst harness-tools-dev--script "scripts/dev.sh"
  "A checkout's live development loop, run to open its harness.")

(defconst harness-tools-dev--marker "harness.el"
  "File that, with `harness-tools-dev--script', marks a harness checkout.")

(defcustom harness-tools-dev-timeout 180
  "Seconds `scripts/dev.sh start' may take before the tool gives up.
The first start of a checkout byte-compiles every module, so it takes
longer than later ones."
  :type 'number :group 'harness)

(defconst harness-tools-dev--registry-name "dev-instances.json"
  "File in `harness-state-directory' recording the instances opened.")

(defconst harness-tools-dev--socket-prefix "harness-dev-"
  "Start of the socket of every instance this module opens.
Only daemons under such a socket are ever stopped: the user's own dev
daemon (scripts/dev.sh's default socket) never is.")

(defvar harness-tools-dev--idle-timeout 3600
  "Seconds a session the user talks to may sit idle before its instance stops.
That is an instance its agent opened for itself.  Nil keeps it for as
long as the session is open.  The instances of tasks and sub-agents
have an end of their own and do not wait for this.")

(defvar harness-tools-dev--first-sweep 60
  "Seconds after the module starts before the first sweep; nil for none.
See `harness-tools-dev--sweep'.")

(defvar harness-tools-dev--sweep-interval 600
  "Seconds between sweeps of the process table for instances; nil for none.")

(defvar harness-tools-dev--processes-function #'harness-tools-dev-processes
  "Function returning the instances running on this machine.
See `harness-tools-dev-processes' for what it returns.  Tests replace
it, so that no test stops an Emacs it did not start.")

(defconst harness-tools-dev--check-delay 2
  "Seconds the check waits after an event that may end a need.
By then the task or session the event is about has settled.")

(defconst harness-tools-dev--exit-timeout 15
  "Seconds emacsclient may take to ask an instance to exit.")

(defconst harness-tools-dev--kill-grace 3
  "Seconds an instance gets to exit before it is killed, TERM before KILL.")

(defvar harness-tools-dev--starting (make-hash-table :test 'equal)
  "Socket -> how many starts of its instance are running.
Neither the check nor the sweep touches an instance being started.")

(defvar harness-tools-dev--stopping (make-hash-table :test 'equal)
  "Socket -> the promise of the stop of its instance under way.")

;;;; Checkouts

(defun harness-tools-dev-checkout-p (dir)
  "Non-nil when DIR is a checkout of the harness itself.
That is a directory holding harness.el and the live development loop
scripts/dev.sh side by side; the main checkout and every task worktree
of this project are."
  (and dir
       (let ((dir (file-name-as-directory (expand-file-name dir))))
         (and (file-exists-p (expand-file-name harness-tools-dev--marker dir))
              (file-exists-p (expand-file-name harness-tools-dev--script dir))))))

(defun harness-tools-dev--root (dir)
  "Return the project root of DIR, or DIR itself."
  (if (and dir (harness-method-exists-p 'project/root))
      (or (ignore-errors (harness-call 'project/root dir)) dir)
    dir))

(defun harness-tools-dev--session-p (session)
  "Non-nil when SESSION works in a checkout of the harness."
  (cl-some (lambda (dir) (and dir (harness-tools-dev-checkout-p (harness-tools-dev--root dir))))
           (list (plist-get session :worktree) (plist-get session :cwd))))

(defun harness-tools-dev--session (ctx)
  "Return the session plist of CTX, or a minimal stand-in."
  (or (and (plist-get ctx :session-id)
           (harness-method-exists-p 'session/get)
           (ignore-errors (harness-call 'session/get (plist-get ctx :session-id))))
      (list :cwd (plist-get ctx :cwd))))

(defun harness-tools-dev--default-dir (ctx)
  "Return the directory the tool of CTX opens the harness from by default."
  (let ((session (harness-tools-dev--session ctx)))
    (or (plist-get session :worktree)
        (plist-get session :cwd)
        (plist-get ctx :cwd)
        default-directory)))

;;;; The instance

(defun harness-tools-dev-socket (dir)
  "Return the emacsclient socket the harness of DIR is opened under.
It derives from DIR's true name, so opening the same checkout again
reaches the same instance and two worktrees never share one."
  (concat harness-tools-dev--socket-prefix
          (substring (secure-hash 'sha1 (file-truename (file-name-as-directory
                                                        (expand-file-name dir))))
                     0 12)))

(defun harness-tools-dev--socket-of (dir)
  "Return the socket of the instance of DIR, or nil for no DIR or a remote one."
  (and (stringp dir)
       (not (string-empty-p dir))
       (not (file-remote-p dir))
       (harness-tools-dev-socket dir)))

(defun harness-tools-dev-state (dir socket)
  "Return where the instance of DIR under SOCKET keeps its state.
That is the directory scripts/dev.sh defaults to, beside the checkout."
  (file-name-as-directory (expand-file-name (concat "scripts/.dev/state-" socket) dir)))

(defun harness-tools-dev--owner ()
  "Return the pid of the Emacs the instances this harness opens belong to.
That is the Emacs the user runs: the parent of this harness process
when the harness runs in a process of its own (HARNESS_SERVER_PARENT,
see harness-server.el), else this Emacs.  An instance exits once its
owner is gone.  A restart of the harness process alone leaves the
instances running, for the harness started again to look after."
  (let* ((default-directory "/")
         (parent (getenv "HARNESS_SERVER_PARENT"))
         (ppid (alist-get 'ppid (ignore-errors (process-attributes (emacs-pid))))))
    (if (and parent ppid
             (string-match-p "\\`[0-9]+\\'" parent)
             (= (string-to-number parent) ppid))
        ppid
      (emacs-pid))))

(defun harness-tools-dev--run (dir args &optional timeout)
  "Run DIR's scripts/dev.sh with ARGS; return a promise of the result.
TIMEOUT bounds the run, in seconds (default `harness-tools-dev-timeout').
HARNESS_DEV_SOCKET names the checkout's instance, so every call of a
checkout drives the same Emacs.  HARNESS_DEV_OWNER names the Emacs the
instance belongs to (`harness-tools-dev--owner'), which the instance
watches: it exits once that Emacs is gone."
  (harness-run-command (cons (expand-file-name harness-tools-dev--script dir) args)
                       :cwd dir
                       :timeout (or timeout harness-tools-dev-timeout)
                       :name "harness-dev"
                       :env `(("HARNESS_DEV_SOCKET" . ,(harness-tools-dev-socket dir))
                              ("HARNESS_DEV_OWNER" . ,(number-to-string (harness-tools-dev--owner))))))

(defun harness-tools-dev--describe (info &optional lifetime)
  "Return what the model is told about the instance INFO.
LIFETIME, a sentence, says when the instance stops."
  (let ((dir (abbreviate-file-name (plist-get info :path)))
        (socket (plist-get info :socket)))
    (format (concat "Harness from %s is running in an Emacs of its own (emacsclient socket %s), "
                    "with its state and compiled files in %s.%s\n"
                    "Drive it from %s with:\n"
                    "  HARNESS_DEV_SOCKET=%s scripts/dev.sh shot [PATH]   # screenshot its frame\n"
                    "  HARNESS_DEV_SOCKET=%s scripts/dev.sh keys \"C-c h a\"   # send real keys\n"
                    "  HARNESS_DEV_SOCKET=%s scripts/dev.sh eval \"(harness-call '(session/list))\"\n"
                    "  HARNESS_DEV_SOCKET=%s scripts/dev.sh errors   # recent *Messages* and warnings\n"
                    "  HARNESS_DEV_SOCKET=%s scripts/dev.sh reload   # load the source as it is now\n"
                    "  HARNESS_DEV_SOCKET=%s scripts/dev.sh stop\n"
                    "Opening it again reuses this instance.%s")
            dir socket (abbreviate-file-name (plist-get info :state))
            (if (plist-get info :focused)
                "  Its frame was raised and focused."
              "  Its frame stays lowered, so it does not steal focus.")
            dir socket socket socket socket socket socket
            (if (and lifetime (not (string-empty-p lifetime))) (concat " " lifetime) ""))))

(defun harness-tools-dev-start (dir &optional focus holder)
  "Start the Emacs instance running DIR's harness; return a promise.
DIR must be a local checkout of the harness.  With FOCUS non-nil its
frame is raised and focused once it is up; otherwise it stays lowered,
so unattended starts never steal the user's focus.  The promise
resolves to (:path DIR :socket SOCKET :state STATE :focused BOOL
:output STRING); opening a checkout that is already open just ensures
its frame exists.

HOLDER says who needs the instance, so that it can be stopped once
nothing does (see Lifetimes in the Commentary).  It is a plist:
`:session' is the session whose agent opened it, `:user' is non-nil
when the user is to look at it, and `:task' is the id of the task the
user looks at it for.  Without HOLDER the instance is not recorded.
An instance being stopped is started again only once it has stopped."
  (let ((dir (file-name-as-directory (expand-file-name dir))))
    (when (file-remote-p dir)
      (error "Cannot open the harness of a remote directory: %s" (abbreviate-file-name dir)))
    (unless (harness-tools-dev-checkout-p dir)
      (error "%s is not a checkout of the harness: no %s and %s"
             (abbreviate-file-name dir) harness-tools-dev--marker harness-tools-dev--script))
    (let* ((socket (harness-tools-dev-socket dir))
           (settle (lambda ()
                     (when (<= (cl-decf (gethash socket harness-tools-dev--starting 0)) 0)
                       (remhash socket harness-tools-dev--starting)))))
      (cl-incf (gethash socket harness-tools-dev--starting 0))
      (harness-then
       (harness-then
        (or (gethash socket harness-tools-dev--stopping) (harness-resolved nil))
        (lambda (_)
          (harness-then
           (harness-tools-dev--run dir '("start"))
           (lambda (r)
             (if (not (eql (plist-get r :exit) 0))
                 (error "Starting the harness in %s failed: %s"
                        (abbreviate-file-name dir)
                        (string-trim (concat (plist-get r :stdout) "\n" (plist-get r :stderr))))
               (let ((info (list :path dir :socket socket
                                 :state (harness-tools-dev-state dir socket)
                                 :focused (and focus t)
                                 :output (string-trim (plist-get r :stdout)))))
                 (when holder (harness-tools-dev--record info holder))
                 (if focus
                     (harness-then (harness-tools-dev--run dir '("eval" "(harness-dev-focus)"))
                                   (lambda (_) info))
                   (harness-resolved info))))))))
       (lambda (info) (funcall settle) info)
       (lambda (err) (funcall settle) (harness-rejected err))))))

;;;; The record of instances

(defvar harness-tools-dev--instances nil
  "The instances this harness looks after, as plists, oldest first.
Each is (:socket SOCKET :path CHECKOUT :sessions IDS :user BOOL :task ID
:opened TIME), with `:adopted' t on one the sweep found running
unrecorded.  IDS are the sessions whose agents opened it for
themselves; `:user' says it was opened for the user to look at, at the
task `:task'.  Read from `harness-tools-dev--registry-name' when first
needed, and written back on every change.")

(defvar harness-tools-dev--instances-dir nil
  "The state directory `harness-tools-dev--instances' was read from.")

(defun harness-tools-dev--registry-path ()
  "Return the file that records the instances."
  (expand-file-name harness-tools-dev--registry-name harness-state-directory))

(defun harness-tools-dev--instances ()
  "Return the recorded instances, reading the record first when needed."
  (let ((dir (expand-file-name harness-state-directory)))
    (unless (equal dir harness-tools-dev--instances-dir)
      (setq harness-tools-dev--instances-dir dir
            harness-tools-dev--instances
            (cl-remove-if-not (lambda (entry) (and (consp entry) (stringp (plist-get entry :socket))))
                              (condition-case err
                                  (harness-json-parse (harness-read-file (harness-tools-dev--registry-path)))
                                (error (harness-log 'warn "tools-dev: cannot read %s: %s"
                                                    (harness-tools-dev--registry-path)
                                                    (error-message-string err))
                                       nil)))))
    harness-tools-dev--instances))

(defun harness-tools-dev--save ()
  "Write the record of instances."
  (condition-case err
      (harness-write-file-atomically (harness-tools-dev--registry-path)
                                     (harness-json-encode (harness-json-array harness-tools-dev--instances)))
    (error (harness-log 'warn "tools-dev: cannot write %s: %s"
                        (harness-tools-dev--registry-path) (error-message-string err)))))

(defun harness-tools-dev--find (socket)
  "Return the recorded instance under SOCKET, or nil."
  (cl-find socket (harness-tools-dev--instances)
           :key (lambda (entry) (plist-get entry :socket)) :test #'equal))

(defun harness-tools-dev--put (entry)
  "Record ENTRY in place of whatever was recorded under its socket."
  (let ((socket (plist-get entry :socket)))
    (setq harness-tools-dev--instances
          (append (cl-remove socket (harness-tools-dev--instances)
                             :key (lambda (e) (plist-get e :socket)) :test #'equal)
                  (list entry)))
    (harness-tools-dev--save)
    entry))

(defun harness-tools-dev--forget (socket)
  "Forget the instance recorded under SOCKET."
  (when (harness-tools-dev--find socket)
    (setq harness-tools-dev--instances
          (cl-remove socket harness-tools-dev--instances
                     :key (lambda (e) (plist-get e :socket)) :test #'equal))
    (harness-tools-dev--save)))

(defun harness-tools-dev--record (info holder)
  "Record that the instance INFO was opened for HOLDER.
HOLDER is the plist `harness-tools-dev-start' takes.  It is added to
whatever holds the instance already."
  (let* ((socket (plist-get info :socket))
         (old (harness-tools-dev--find socket))
         (sid (plist-get holder :session))
         (sessions (plist-get old :sessions)))
    (when (and sid (not (member sid sessions)))
      (setq sessions (append sessions (list sid))))
    (harness-tools-dev--put
     (list :socket socket
           :path (plist-get info :path)
           :sessions sessions
           :user (and (or (plist-get holder :user) (harness-json-true-p (plist-get old :user))) t)
           :task (or (plist-get holder :task) (plist-get old :task))
           :opened (or (plist-get old :opened) (float-time))))))

;;;; What sessions and tasks need

(defun harness-tools-dev--get-session (sid)
  "Return the plist of session SID, or nil when there is no such session."
  (and (stringp sid)
       (harness-method-exists-p 'session/get)
       (or (not (harness-method-exists-p 'session/exists-p))
           (harness-call 'session/exists-p sid))
       (ignore-errors (harness-call 'session/get sid))))

(defun harness-tools-dev--sessions (&optional filter)
  "Return the sessions `session/list' returns for FILTER."
  (and (harness-method-exists-p 'session/list)
       (ignore-errors (harness-call 'session/list filter))))

(defun harness-tools-dev--tasks ()
  "Return every task, of every project."
  (and (harness-method-exists-p 'task/list)
       (ignore-errors (harness-call 'task/list))))

(defun harness-tools-dev--get-task (id)
  "Return task ID, or nil when there is no such task."
  (and id (harness-method-exists-p 'task/get)
       (ignore-errors (harness-call 'task/get id))))

(defun harness-tools-dev--task-of (sid)
  "Return the task session SID works on, or nil."
  (and (stringp sid) (harness-method-exists-p 'task/for-session)
       (ignore-errors (harness-call 'task/for-session sid))))

(defun harness-tools-dev--lineage (sid)
  "Return SID and the sessions it descends from, nearest first."
  (let (out)
    (while (and (stringp sid) (not (member sid out)))
      (push sid out)
      (setq sid (plist-get (harness-tools-dev--get-session sid) :parent-id)))
    (nreverse out)))

(defun harness-tools-dev--lineage-task (sid)
  "Return the id of the task SID works for: its own, else its ancestors'."
  (cl-some (lambda (id) (plist-get (harness-tools-dev--task-of id) :id))
           (harness-tools-dev--lineage sid)))

(defun harness-tools-dev--task-at (dir)
  "Return the id of the task whose worktree DIR is, or nil."
  (let ((socket (harness-tools-dev--socket-of dir)))
    (and socket
         (plist-get (cl-find-if (lambda (task)
                                  (equal socket (harness-tools-dev--socket-of (plist-get task :worktree))))
                                (harness-tools-dev--tasks))
                    :id))))

(defun harness-tools-dev--busy-p (sid &optional session)
  "Non-nil while session SID is at work.
That is while its turn runs or waits on the user, or while work it
started outside its turn is outstanding.  SESSION is its plist, when
the caller has it."
  (let ((session (or session (harness-tools-dev--get-session sid))))
    (and session
         (or (memq (plist-get session :status) '(running blocked))
             (and (harness-method-exists-p 'agent/running)
                  (ignore-errors (harness-call 'agent/running sid)))
             (and (harness-method-exists-p 'agent/outstanding)
                  (ignore-errors (harness-call 'agent/outstanding sid))))
         t)))

(defun harness-tools-dev--task-working-p (task)
  "Non-nil while TASK is at work.
That is while it is active and has stopped on nothing (no `:outcome'),
or while its session is at work, as in the merge queue."
  (and task
       (not (eq (plist-get task :state) 'done))
       (not (harness-json-true-p (plist-get task :archived)))
       (or (and (eq (plist-get task :state) 'active) (null (plist-get task :outcome)))
           (harness-tools-dev--busy-p (plist-get task :session)))))

(defun harness-tools-dev--open-p (session &optional recent)
  "Non-nil while SESSION is open, which is until it is closed.
With RECENT, it must also have been active within
`harness-tools-dev--idle-timeout'."
  (and session
       (not (eq (plist-get session :status) 'inactive))
       (or (not recent)
           (null harness-tools-dev--idle-timeout)
           (let ((updated (plist-get session :updated)))
             (or (not (numberp updated))
                 (< (- (float-time) updated) harness-tools-dev--idle-timeout))))))

(defun harness-tools-dev--session-needs-p (sid)
  "Non-nil while session SID still needs the instance its agent opened.
A task's session needs it while the task works, a sub-agent while it
works, and any other session while it is open and not long idle."
  (let ((session (harness-tools-dev--get-session sid)))
    (and session
         (or (harness-tools-dev--busy-p sid session)
             (let ((task (harness-tools-dev--task-of sid)))
               (cond (task (harness-tools-dev--task-working-p task))
                     ((eq (plist-get session :kind) 'subagent) nil)
                     (t (harness-tools-dev--open-p session t)))))
         t)))

(defun harness-tools-dev--user-needs-p (entry)
  "Non-nil while the user may still look at the instance ENTRY records.
With a task, that is until the task is done, archived or deleted.
Without one, it is while a session that opened it, or the session that
one descends from, is open.  With neither, nothing says the user is done."
  (let ((task-id (plist-get entry :task))
        (sessions (plist-get entry :sessions)))
    (cond
     (task-id
      (let ((task (harness-tools-dev--get-task task-id)))
        (and task
             (not (eq (plist-get task :state) 'done))
             (not (harness-json-true-p (plist-get task :archived))))))
     (sessions
      (cl-some (lambda (sid)
                 (cl-some (lambda (id) (harness-tools-dev--open-p (harness-tools-dev--get-session id)))
                          (harness-tools-dev--lineage sid)))
               sessions))
     (t t))))

(defun harness-tools-dev--context ()
  "Return what checking the instances needs, gathered once.
That is (:tasks TASKS :busy SESSIONS): every task, and the open
sessions at work."
  (list :tasks (harness-tools-dev--tasks)
        :busy (cl-remove-if-not (lambda (session)
                                  (harness-tools-dev--busy-p (plist-get session :id) session))
                                (harness-tools-dev--sessions (list :active t)))))

(defun harness-tools-dev--worked-in-p (socket ctx)
  "Non-nil while a task or session at work works in the checkout of SOCKET.
CTX is what `harness-tools-dev--context' gathered."
  (or (cl-some (lambda (task)
                 (and (plist-get task :worktree)
                      (harness-tools-dev--task-working-p task)
                      (equal socket (harness-tools-dev--socket-of (plist-get task :worktree)))))
               (plist-get ctx :tasks))
      (cl-some (lambda (session)
                 (equal socket (harness-tools-dev--socket-of
                                (or (plist-get session :worktree) (plist-get session :cwd)))))
               (plist-get ctx :busy))))

(defun harness-tools-dev--unneeded (entry ctx)
  "Return why nothing needs the instance ENTRY records any more.
Return nil while something does.  CTX is what
`harness-tools-dev--context' gathered."
  (let ((path (plist-get entry :path))
        (user (harness-json-true-p (plist-get entry :user)))
        (sessions (plist-get entry :sessions)))
    (cond
     ((not (and (stringp path) (file-directory-p path))) "its checkout is gone")
     ((cl-some #'harness-tools-dev--session-needs-p sessions) nil)
     ((and user (harness-tools-dev--user-needs-p entry)) nil)
     ((harness-tools-dev--worked-in-p (plist-get entry :socket) ctx) nil)
     (user (if (plist-get entry :task)
               "the task it was opened to look at is done"
             "the session that opened it is closed"))
     (sessions "the sessions that opened it are done with it")
     (t "no task or session works in its checkout"))))

(defun harness-tools-dev--lifetime (holder)
  "Return what the model is told about when the instance of HOLDER stops."
  (let* ((sid (plist-get holder :session))
         (session (harness-tools-dev--get-session sid)))
    (cond
     ((plist-get holder :user)
      (if (plist-get holder :task)
          "It is open for the user to look at, so it stays until the task is done."
        "It is open for the user to look at, so it stays while this session is open."))
     ((null session) "")
     ((harness-tools-dev--task-of sid)
      (concat "It stops by itself once this task stops working: when it goes to review or is done, "
              "or stops on an error or a cancel. Call open_harness again to start it again."))
     ((eq (plist-get session :kind) 'subagent)
      (concat "It stops by itself once your work is done, unless a task still works in the same "
              "checkout. Call open_harness again to start it again."))
     (t (format "It stops by itself once this session is closed%s."
                (if harness-tools-dev--idle-timeout
                    (format ", or has been idle for %s"
                            (harness-format-duration harness-tools-dev--idle-timeout))
                  ""))))))

;;;; Stopping

(defun harness-tools-dev--parse-command (args)
  "Return (:socket SOCKET :path CHECKOUT) of an instance's command line ARGS.
ARGS is the command line as one string.  `scripts/dev.sh start' runs
`emacs -Q --daemon=SOCKET -l CHECKOUT/scripts/harness-dev.el'.  Return
nil for any other command, including a daemon under another socket.
`:path' is nil when the command line names no checkout."
  (when (and (stringp args)
             (string-match (concat "\\(?:\\`\\| \\)--daemon=\\(" (regexp-quote harness-tools-dev--socket-prefix)
                                   "[0-9a-f]+\\)\\(?: \\|\\'\\)")
                           args))
    (let ((socket (match-string 1 args)))
      (list :socket socket
            :path (and (string-match " -l \\(.+?\\)/scripts/harness-dev\\.el\\(?: \\|\\'\\)" args)
                       (file-name-as-directory (match-string 1 args)))))))

(defun harness-tools-dev-processes ()
  "Return the instances of the harness running on this machine for this user.
Each is (:socket SOCKET :path CHECKOUT :pid PID), read from the command
line of an Emacs daemon (see `harness-tools-dev--parse-command').
Return `:unavailable' when the process table cannot be read."
  (let* ((default-directory "/")
         (uid (user-uid))
         (pids (and (fboundp 'list-system-processes) (ignore-errors (list-system-processes))))
         (out nil))
    (if (null pids)
        :unavailable
      (dolist (pid pids (nreverse out))
        (let ((attrs (ignore-errors (process-attributes pid))))
          ;; An Emacs: not a grep or a shell whose command line names a socket.
          (when (and (eql (alist-get 'euid attrs) uid)
                     (string-match-p "emacs" (or (alist-get 'comm attrs) "")))
            (let ((daemon (harness-tools-dev--parse-command (alist-get 'args attrs))))
              (when daemon
                (push (append daemon (list :pid pid)) out)))))))))

(defun harness-tools-dev--daemon-pids (socket)
  "Return the processes of the daemon under SOCKET, nil when none runs."
  (let ((running (funcall harness-tools-dev--processes-function)))
    (and (listp running)
         (delq nil (mapcar (lambda (daemon)
                             (and (equal socket (plist-get daemon :socket)) (plist-get daemon :pid)))
                           running)))))

(defvar harness-tools-dev--own-socket 'unknown
  "The socket of the instance this harness itself runs in, nil for none.
`unknown' until `harness-tools-dev--own-socket' finds out.")

(defun harness-tools-dev--own-socket ()
  "Return the socket of the instance this harness itself runs in, or nil.
That is this Emacs, when it is a daemon scripts/dev.sh started, or the
Emacs this harness process serves (see harness-server.el).  An agent
in an instance can open its own checkout, which is the same instance;
it never stops itself."
  (when (eq harness-tools-dev--own-socket 'unknown)
    (setq harness-tools-dev--own-socket
          (or (let ((name (daemonp)))
                (and (stringp name) (string-prefix-p harness-tools-dev--socket-prefix name) name))
              (let* ((default-directory "/")
                     (ppid (alist-get 'ppid (ignore-errors (process-attributes (emacs-pid))))))
                (and ppid
                     (plist-get (harness-tools-dev--parse-command
                                 (alist-get 'args (ignore-errors (process-attributes ppid))))
                                :socket))))))
  harness-tools-dev--own-socket)

(defun harness-tools-dev--after (seconds)
  "Return a promise resolved SECONDS from now."
  (harness-with-promise (resolve reject)
    (ignore reject)
    (run-at-time seconds nil resolve t)))

(defun harness-tools-dev--emacsclient ()
  "Return the emacsclient to reach instances with: this Emacs's own, if found."
  (let ((own (expand-file-name "emacsclient" invocation-directory)))
    (if (file-executable-p own) own "emacsclient")))

(defun harness-tools-dev--ask-to-exit (socket)
  "Ask the instance under SOCKET to exit, over emacsclient; return a promise.
Nothing of its checkout runs for that, so it works when the checkout is
gone too.  `-a false' keeps emacsclient from starting an Emacs when
none answers, as an empty ALTERNATE_EDITOR would have it do."
  (harness-run-command (list (harness-tools-dev--emacsclient) "-a" "false" "-s" socket
                             "--eval" "(kill-emacs)")
                       :cwd "/" :timeout harness-tools-dev--exit-timeout :name "harness-dev-stop"))

(defun harness-tools-dev--kill-leftovers (socket)
  "Kill the daemon under SOCKET should it still run in a moment; return a promise.
It gets `harness-tools-dev--kill-grace' seconds to exit, then its
process tree gets TERM, and as long again later KILL."
  (if (null (harness-tools-dev--daemon-pids socket))
      (harness-resolved nil)
    (harness-then
     (harness-tools-dev--after harness-tools-dev--kill-grace)
     (lambda (_)
       (let ((trees (mapcar (lambda (pid) (harness-process-tree pid nil))
                            (harness-tools-dev--daemon-pids socket))))
         (when trees
           (harness-log 'warn "tools-dev: the harness instance %s did not exit; killing it" socket)
           (dolist (tree trees) (harness-kill-process-tree tree 'term))
           (harness-then (harness-tools-dev--after harness-tools-dev--kill-grace)
                         (lambda (_)
                           (dolist (tree trees) (harness-kill-process-tree tree 'kill))
                           t))))))))

(defun harness-tools-dev--stop (entry reason)
  "Stop the instance ENTRY records, because of REASON; return a promise.
REASON is a phrase for the log and `harness-dev/stopped'.  The promise
resolves to non-nil once the instance is stopped, and ENTRY is
forgotten either way.  A second stop of the same instance while the
first runs returns the first's promise; the instance this harness runs
in is forgotten, never stopped."
  (let ((socket (plist-get entry :socket))
        (path (plist-get entry :path)))
    (cond
     ((gethash socket harness-tools-dev--stopping))
     ((equal socket (harness-tools-dev--own-socket))
      (harness-tools-dev--forget socket)
      (harness-resolved nil))
     (t
      (let* ((done (harness-make-promise))
             (finish (lambda (ok)
                       (remhash socket harness-tools-dev--stopping)
                       (harness-tools-dev--forget socket)
                       (when ok (harness-emit 'harness-dev/stopped socket path reason))
                       (harness-resolve done ok))))
        (puthash socket done harness-tools-dev--stopping)
        (harness-log 'info "tools-dev: stopping the harness instance of %s (%s): %s"
                     (if path (abbreviate-file-name path) "?") socket reason)
        (harness-then
         (harness-then (harness-catch (condition-case err
                                          (harness-tools-dev--ask-to-exit socket)
                                        (error (harness-rejected err)))
                                      #'ignore)
                       (lambda (_) (harness-tools-dev--kill-leftovers socket)))
         (lambda (_) (funcall finish t))
         (lambda (err)
           (harness-log 'warn "tools-dev: stopping %s failed: %s" socket (harness-error-message err))
           (funcall finish nil)))
        done)))))

(defun harness-tools-dev--stop-socket (socket path reason)
  "Stop the instance under SOCKET, of the checkout PATH, recorded or not.
REASON is as `harness-tools-dev--stop' takes it.  Return a promise of
non-nil when an instance was stopped, of nil when none ran."
  (let ((entry (harness-tools-dev--find socket)))
    (if (or entry
            (gethash socket harness-tools-dev--stopping)
            (harness-tools-dev--daemon-pids socket))
        (harness-tools-dev--stop (or entry (list :socket socket :path path)) reason)
      (harness-resolved nil))))

(defun harness-tools-dev--in-flight-p (socket)
  "Non-nil while the instance under SOCKET is being started or stopped."
  (or (gethash socket harness-tools-dev--starting)
      (gethash socket harness-tools-dev--stopping)))

(defun harness-tools-dev--check ()
  "Stop every recorded instance that nothing needs any more.
Return a promise of the sockets stopped."
  (let ((entries (cl-remove-if (lambda (entry) (harness-tools-dev--in-flight-p (plist-get entry :socket)))
                               (harness-tools-dev--instances))))
    (if (null entries)
        (harness-resolved nil)
      (let ((ctx (harness-tools-dev--context))
            (stops nil))
        (dolist (entry entries)
          (let ((why (harness-tools-dev--unneeded entry ctx)))
            (when why
              (let ((socket (plist-get entry :socket)))
                (push (harness-then (harness-tools-dev--stop entry why)
                                    (lambda (stopped) (and stopped socket)))
                      stops)))))
        (harness-then (harness-all (nreverse stops))
                      (lambda (sockets) (delq nil sockets)))))))

(defun harness-tools-dev--worktree-sockets ()
  "Return the sockets of the worktrees of this harness's tasks and sessions."
  (delete-dups
   (delq nil (append (mapcar (lambda (task) (harness-tools-dev--socket-of (plist-get task :worktree)))
                             (harness-tools-dev--tasks))
                     (mapcar (lambda (session) (harness-tools-dev--socket-of (plist-get session :worktree)))
                             (harness-tools-dev--sessions))))))

(defun harness-tools-dev--take-stock (running)
  "Bring the record up to date with RUNNING, the instances that run.
A recorded instance that no longer runs is forgotten.  An unrecorded
instance is recorded when it is this harness's to look after: when its
checkout is the worktree of one of this harness's tasks or sessions, or
is gone.  Any other instance belongs to somebody else and stays as it is."
  (let* ((sockets (mapcar (lambda (daemon) (plist-get daemon :socket)) running))
         (own (harness-tools-dev--own-socket))
         (ours 'unknown)
         (recorded (harness-tools-dev--instances))
         (kept (cl-remove-if-not (lambda (entry)
                                   (let ((socket (plist-get entry :socket)))
                                     (or (member socket sockets) (harness-tools-dev--in-flight-p socket))))
                                 recorded))
         (changed (/= (length kept) (length recorded))))
    (setq harness-tools-dev--instances kept)
    (dolist (daemon running)
      (let ((socket (plist-get daemon :socket))
            (path (plist-get daemon :path)))
        (unless (or (null path)
                    (equal socket own)
                    (harness-tools-dev--find socket)
                    (harness-tools-dev--in-flight-p socket))
          (when (or (not (file-directory-p path))
                    (member socket (if (eq ours 'unknown)
                                       (setq ours (harness-tools-dev--worktree-sockets))
                                     ours)))
            (setq harness-tools-dev--instances
                  (append harness-tools-dev--instances
                          (list (list :socket socket :path path :adopted t :opened (float-time))))
                  changed t)))))
    (when changed (harness-tools-dev--save))))

(defun harness-tools-dev--sweep ()
  "Find the instances that run, then stop those that nothing needs.
Return a promise of the sockets stopped.  See `harness-tools-dev--take-stock'
for what is found."
  (let ((running (funcall harness-tools-dev--processes-function)))
    (when (listp running)
      (harness-tools-dev--take-stock running))
    (harness-tools-dev--check)))

;;;; When to check

(defvar harness-tools-dev--check-timer nil
  "Timer of the check due, or nil.")

(defvar harness-tools-dev--sweep-timer nil
  "Timer of the sweeps, or nil.")

(defun harness-tools-dev--report (promise what)
  "Log a failure of PROMISE, the WHAT of the instances."
  (harness-catch promise
                 (lambda (err)
                   (harness-log 'warn "tools-dev: %s failed: %s" what (harness-error-message err))
                   nil)))

(defun harness-tools-dev--check-now ()
  "Run the check that was due."
  (setq harness-tools-dev--check-timer nil)
  (condition-case err
      (harness-tools-dev--report (harness-tools-dev--check) "checking the instances")
    (error (harness-log 'warn "tools-dev: checking the instances failed: %s" (error-message-string err)))))

(defun harness-tools-dev--schedule (&rest _)
  "Check the recorded instances in a moment.
An event handler, for every event that may end a need.  Nothing is
scheduled while nothing is recorded, nor again while a check is due:
the one due sees whatever happened meanwhile."
  (when (and (harness-tools-dev--instances)
             (not (timerp harness-tools-dev--check-timer)))
    (setq harness-tools-dev--check-timer
          (run-at-time harness-tools-dev--check-delay nil #'harness-tools-dev--check-now))))

(defun harness-tools-dev--sweep-now ()
  "Run a sweep, from its timer."
  (condition-case err
      (harness-tools-dev--report (harness-tools-dev--sweep) "sweeping for instances")
    (error (harness-log 'warn "tools-dev: sweeping for instances failed: %s" (error-message-string err)))))

(defun harness-tools-dev--before-remove (value _next _root path)
  "Stop the instance running from the worktree at PATH before it goes.
A `worktree/before-remove' filter: VALUE passes on unchanged once the
instance has stopped, so git never removes the directory under a
running Emacs."
  (let ((socket (harness-tools-dev--socket-of path)))
    (if (null socket)
        (harness-resolved value)
      (harness-then (harness-catch (harness-tools-dev--stop-socket socket path "its worktree is being removed")
                                   #'ignore)
                    (lambda (_) value)))))

;;;; The tool

(defun harness-tools-dev--open (input ctx)
  "Handler of the `open_harness' tool with INPUT under CTX."
  (let* ((given (plist-get input :path))
         (path (if (and (stringp given) (not (harness-string-blank-p given)))
                   (harness-tools-resolve-path given ctx)
                 (harness-tools-dev--default-dir ctx)))
         (focus (harness-json-true-p (plist-get input :focus)))
         (sid (plist-get ctx :session-id))
         (holder (and sid (list :session sid
                                :user focus
                                :task (and focus (or (harness-tools-dev--lineage-task sid)
                                                     (harness-tools-dev--task-at path)))))))
    (condition-case err
        (harness-then (harness-tools-dev-start path focus holder)
                      (lambda (info)
                        (harness-tool-ok (harness-tools-dev--describe
                                          info (and holder (harness-tools-dev--lifetime holder)))))
                      (lambda (e) (harness-tool-error (harness-error-message e))))
      (error (harness-tool-error (harness-error-message err))))))

(harness-define-tool harness-tools-dev-tool
  :label "Open harness in Emacs"
  :description "Start a separate Emacs instance running the harness (this program) from a checkout or task worktree of it, so harness changes can be tried and seen live. The instance gets a socket and state directory of its own, so it does not disturb the harness you run in; opening the same directory again reuses its instance. The result lists the commands that drive it through that checkout's scripts/dev.sh: screenshot its frame, send real keys, evaluate Lisp in it, read its messages, reload it, stop it. It stops by itself once nothing needs it: a task's when the task stops working (review, done, or stopped), a sub-agent's when its work is done, a conversation's when it is closed or long idle; with focus=true it is for the user to look at and stays until the task is done. Call the tool again to start it again. Only directories that are checkouts of the harness work (harness.el and scripts/dev.sh side by side); path defaults to the session's worktree, else its working directory."
  :schema '(:type "object"
            :properties (:path (:type "string"
                                :description "The harness checkout or task worktree to open, absolute or relative to the working directory. Default: the session's worktree, else its working directory.")
                         :focus (:type "boolean"
                                 :description "Raise and focus the instance's frame, for the user to look at: it then stays open until the task is done. Default false, so an unattended start does not steal the user's focus.")))
  :kind 'exec
  :timeout 300
  :paths (lambda (input) (list (or (plist-get input :path) ".")))
  :subject (lambda (input) (plist-get input :path))
  :handler #'harness-tools-dev--open)

;;;; Methods

(harness-defmethod harness-dev/open (path &optional focus)
  "Start an Emacs instance running the harness of PATH; return a promise.
The promise resolves to the instance's info plist (see
`harness-tools-dev-start').  FOCUS raises and focuses its frame.  This
is what the task board's Open harness calls, from the menu of a card
waiting for review; the agent uses the `open_harness' tool, which
shares the same start.  The instance is the user's to look at: it
stops once the task whose worktree PATH is is done, archived or
deleted."
  (let ((dir (file-name-as-directory (expand-file-name path))))
    (harness-tools-dev-start dir (harness-json-true-p focus)
                             (list :user t :task (harness-tools-dev--task-at dir)))))

(harness-defmethod harness-dev/instances ()
  "Return the instances of the harness this harness looks after.
Each is the plist recorded for it (see `harness-tools-dev--instances')
with `:needed', non-nil while something needs it, and `:reason', why
nothing does when nothing does."
  (let ((ctx nil))
    (mapcar (lambda (entry)
              (let ((why (harness-tools-dev--unneeded
                          entry (or ctx (setq ctx (harness-tools-dev--context))))))
                (append entry (list :needed (not why) :reason why))))
            (harness-tools-dev--instances))))

(harness-defmethod harness-dev/stop (path)
  "Stop the instance running the harness of PATH, if one runs; return a promise.
The promise resolves to non-nil when an instance was stopped."
  (let ((dir (file-name-as-directory (expand-file-name path))))
    (harness-tools-dev--stop-socket (harness-tools-dev-socket dir) dir "asked to stop")))

(harness-defmethod harness-dev/sweep ()
  "Stop every instance nothing needs any more, now; return a promise.
That is the sweep the module runs every `harness-tools-dev--sweep-interval'
seconds: it looks for instances in the process table first, so it finds
the unrecorded ones too.  The promise resolves to the sockets stopped."
  (harness-tools-dev--sweep))

(harness-declare-event 'harness-dev/stopped
                       "(SOCKET PATH REASON) after an instance of the harness `open_harness' or the board opened was stopped because nothing needed it any more.")

;;;; Project gating

(defun harness-tools-dev--tools (names session)
  "Keep `open_harness' in NAMES only for a session in a harness checkout.
The catalogue (SESSION nil) keeps every tool."
  (if (and session (not (harness-tools-dev--session-p session)))
      (remove harness-tools-dev-tool names)
    names))

;;;; Init and reload

(defconst harness-tools-dev--events
  '(agent/turn-ended session/deactivated session/deleted
    task/review task/done task/deleted worktree/removed)
  "Events after which an instance may no longer be needed.")

(defun harness-tools-dev--start-sweeping ()
  "Start the sweeps, the first `harness-tools-dev--first-sweep' seconds from now."
  (when (timerp harness-tools-dev--sweep-timer) (cancel-timer harness-tools-dev--sweep-timer))
  (setq harness-tools-dev--sweep-timer
        (and harness-tools-dev--first-sweep harness-tools-dev--sweep-interval
             (run-with-timer harness-tools-dev--first-sweep harness-tools-dev--sweep-interval
                             #'harness-tools-dev--sweep-now))))

(defun harness-tools-dev--init ()
  "Offer `open_harness' only to this project's sessions; look after the instances."
  (harness-add-filter 'agent/tools #'harness-tools-dev--tools 50)
  (harness-add-filter 'worktree/before-remove #'harness-tools-dev--before-remove)
  (dolist (event harness-tools-dev--events)
    (harness-on event #'harness-tools-dev--schedule))
  (harness-tools-dev--start-sweeping))

(defun harness-tools-dev--shutdown ()
  "Stop checking on the instances.
The instances themselves run on: each stops once the Emacs it belongs
to is gone (`harness-tools-dev--owner'), and a harness started again
looks after them."
  (dolist (timer (list harness-tools-dev--check-timer harness-tools-dev--sweep-timer))
    (when (timerp timer) (cancel-timer timer)))
  (setq harness-tools-dev--check-timer nil
        harness-tools-dev--sweep-timer nil))

(harness-define-module 'tools-dev
  :doc "The open_harness tool: run a checkout's harness in an Emacs of its own."
  :requires '(tools)
  :init #'harness-tools-dev--init
  :shutdown #'harness-tools-dev--shutdown)

;; A reload does not initialise a running module again: subscribe what
;; this version subscribes, and restart the sweeps.
(when (harness-module-ready-p 'tools-dev)
  (harness-tools-dev--init))

(provide 'harness-tools-dev)
;;; harness-tools-dev.el ends here
