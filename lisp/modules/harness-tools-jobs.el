;;; harness-tools-jobs.el --- Long-lived confined jobs of a session  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; A `bash' call is a sandbox session of its own: the command runs in a
;; PID namespace that ends with it (see `harness-tools-shell'), so a
;; server it leaves running is gone by the time the next call starts.
;; That boundary is what keeps a session's processes from outliving its
;; permission decisions, its timeouts and its transcript, and it stays
;; (docs/design/tool-call-persistent-jobs.md).  What it does not give is
;; a process that several calls share, which a dev server, a display, an
;; emulator or a playtest needs; the only workflow was one self-contained
;; command, and every call paid for the startup again.
;;
;; This module is that process, made explicit and bounded.  `bash_job'
;; starts a *job*: a command in a sandbox of the session's own that the
;; harness starts, holds and stops, and whose sandbox lives as long as
;; the job rather than as long as one call.  It is the same sandbox a
;; bash command gets, built by the same
;; `harness-tools-shell-sandbox-profile' and wrapped by the same
;; `harness-tools-shell-wrap-profile': the session's working directory,
;; worktree and own temporary directory, the configured and granted
;; directories writable, the skills and read-only directories readable,
;; the `tools/sandbox-options' filter's options (a read-only session's
;; job is read-only, an offline one's is offline) and its Linux
;; capabilities where the backend can give them.  Nothing is unshared
;; differently: a job keeps `--unshare-pid', so it is a PID namespace of
;; its own, and a script inside it may start as many processes as it
;; likes, all of which end with the job.
;;
;; A job is the harness's process, not the call's: the harness spawns it
;; (`make-process', as it spawns an MCP server), so it outlives the call
;; that started it and the next call reaches it.  Four bounds end it, and
;; each holds even when the others do not:
;;
;; - the harness stops it -- at its deadline, on `bash_job' stop or
;;   restart, when its session is deleted, closed or moved, when its task
;;   is done or cancelled or its work is stopped (`agent/stop-outstanding',
;;   which task mode calls to pause or return a task), when the module
;;   shuts down, and at Emacs's own exit (`kill-emacs-hook');
;; - the sandbox's own `timeout' runs the command, so the job's deadline
;;   ends it inside the sandbox whatever the harness is doing;
;; - bwrap runs with `--die-with-parent', so a harness that dies without
;;   running a handler takes the sandbox with it, and the kernel ends
;;   every process of the namespace with the sandbox's init;
;; - what a job costs is bounded: its output in memory and in its log
;;   (`harness-tools-jobs-output-limit'), its time (a restart does not
;;   extend its deadline), how many one session may run, and how many
;;   times its sandbox may be built again.
;;
;; Every spawn is checked, not only the first.  A job outlives the call
;; that was decided, so `harness-tools-jobs--prepare' runs before a start,
;; a restart and an automatic rebuild alike: the session is read again,
;; the job's directory is authorised against `permission/dirs' as it is
;; now, the *effective* policy of that directory is asked for (a
;; project's .dir-locals.el can say `off' where the global setting does
;; not), the backend must be one that can hold a job, and the command that
;; will be spawned must be the one bwrap runs.  Anything else stops the
;; job with the reason rather than letting it run unconfined.
;;
;; Ownership.  A job belongs to the session whose call started it: only
;; that session lists, reads or stops it, and an id of another session's
;; is not found rather than refused, so nothing of it is shown.  The jobs
;; of a session end with it, as above.  Ownership is not network
;; isolation: the network is the machine's, as it is for bash, so a job's
;; listener is reachable from anywhere on the machine that may reach the
;; port, and two jobs cannot bind the same one.
;;
;; What a command may reach can change while a job runs.  The mounts of a
;; sandbox are fixed when it starts, as they are for an MCP server, so a
;; directory granted later is not in a job already running.  A change
;; that matters -- `access/changed', `permission/dir-revoked',
;; `config/changed' for the policy, the backend, the allowed directories
;; or the read-only ones -- is therefore compared against the profile the
;; job was built with.  The profile is the fingerprint as well as the
;; build plan, so every effective access input has to be in it:
;; `harness-sandbox-extra-read-only-dirs' is one the sandbox reads itself,
;; and the job's profile carries it as `:extra-read-only'.  A different
;; profile restarts the job with the new mounts; one that cannot be built,
;; or that the session may no longer run, stops the job with the reason.
;; A job never keeps authority its session no longer has, and a restart is
;; counted on it and logged.  A session that moves to another directory
;; stops its jobs: the directory they run in is not what it works in any
;; more.
;;
;; Backends.  A job needs a backend whose sandbox the harness can hold and
;; end itself: bwrap, which the tests measure.  systemd-run can hold a
;; process for a while but not be stopped: the harness would have the
;; systemd-run *client*, and ending the client does not stop the transient
;; unit it started -- stopping that needs a named unit and
;; `systemctl --user stop`, a second authority the harness does not have
;; here.  A job under systemd-run would therefore outlive every stop the
;; harness makes, so it is refused rather than offered with a bound that
;; does not hold.  MXC has no PID namespace, so nothing would end a job's
;; processes with it; OpenShell makes a sandbox per command.  All of them
;; refuse a job with the reason, as do the `off' policy (globally or for
;; the directory), no backend, a remote directory and a read-only session
;; -- there a job would be a process outside the jail that outlives its
;; call, which is what the jail exists to prevent.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-tools)
(require 'harness-tools-shell)

;; The sandbox a session's calls share (the sandbox-session module).  A
;; job runs in it -- as a run marked detached -- where the harness can
;; hold one, and in a sandbox of its own where it cannot.
(declare-function harness-sandbox-session-start-run "harness-sandbox-session"
                  (ctx cwd command &rest args))
(declare-function harness-sandbox-session-kill-run "harness-sandbox-session"
                  (run &optional reason))
(declare-function harness-sandbox-session-run-state "harness-sandbox-session" (run))
(declare-function harness-sandbox-session-run-entry "harness-sandbox-session" (run))
(declare-function harness-sandbox-session-run-result "harness-sandbox-session" (run))
(declare-function harness-sandbox-session-problem "harness-sandbox-session" (ctx cwd))
(declare-function harness-sandbox-session-sandbox "harness-sandbox-session" (session-id))
(declare-function harness-sandbox-session-live-runs "harness-sandbox-session" (sandbox))
(declare-function harness-sandbox-session-state "harness-sandbox-session" (sandbox))

(defcustom harness-tools-jobs-ttl 3600
  "Longest a `bash_job' may run, in seconds.
A call may ask for less; never for more.  A job is stopped when its
time is up, and the `timeout' inside its sandbox ends it at the same
moment whatever the harness is doing."
  :type 'integer :group 'harness)

(defcustom harness-tools-jobs-max-per-session 4
  "Most jobs one session may have running at once."
  :type 'integer :group 'harness)

(defcustom harness-tools-jobs-output-limit 262144
  "Most output, in bytes, a job keeps in memory and in its log.
A job's output arrives through a process filter in the harness process,
so it is bounded there: what this many bytes cannot hold is dropped from
the front, and the first line says how much, so a caller reads that the
log was cut rather than a log that starts in the middle.  A job that
writes faster than a caller reads therefore costs the harness a bounded
amount of memory and a bounded file, whatever it prints."
  :type 'integer :group 'harness)

(defcustom harness-tools-jobs-max-restarts 5
  "Most times one job is started again after its sandbox changed.
A restart is free of the session's own decision -- `access/changed' can
come from any part of the harness, again and again -- so a job whose
sandbox keeps changing is stopped rather than restarted for ever, with
that as its reason.  The job's deadline is fixed when it first starts, so
restarts do not give it more time either."
  :type 'integer :group 'harness)

(defconst harness-tools-jobs--default-seconds 600
  "Seconds a job runs when its call asks for no time.")

(defconst harness-tools-jobs--kill-after 5
  "Seconds between the TERM and the KILL the sandbox's `timeout' sends a job.")

(defconst harness-tools-jobs--tick 5
  "Seconds between two looks at the deadlines of the jobs.")

(defcustom harness-tools-jobs-evidence-limit 262144
  "Most bytes of job lifecycle evidence kept, across every session.
A job's lifecycle is recorded as one line per event in a file of the
harness's state directory (see `harness-tools-jobs-evidence`), and the
file is cut from the front when it grows past this, so a harness that
runs for months keeps a bounded record of how its jobs ended rather
than all of them.  A line is small -- ids, times, a state and a reason,
never the command or its output -- so this holds thousands of ends."
  :type 'integer :group 'harness)

(defconst harness-tools-jobs--evidence-file-name "jobs-lifecycle.jsonl"
  "The file the lifecycle of every job is appended to, under the state
directory.  One JSON object per line; see `harness-tools-jobs-evidence'.")

(defvar harness-tools-jobs--evidence-unavailable nil
  "Non-nil when the lifecycle file could not be written, once said so.")

;;;; The lifecycle evidence
;;
;; A job's record is in memory and goes with the session (`--forget'),
;; so what ended a job was only ever in the harness's debug log -- which
;; is not kept -- and a job whose process was killed by a signal nothing
;; in the harness sent read as failed with no reason at all.  That is
;; what the two jobs of 2026-11-16 looked like: exit 143, reason nil,
;; and nothing anywhere saying who asked for the teardown.
;;
;; So every job writes a small durable record of its own lifecycle: when
;; it started and in which sandbox run, every time the harness asked it
;; to stop and by which path, and how it ended.  A record says whether a
;; Harness stop request had been made when the job ended, so a job that
;; ends without one -- an external signal, say -- reads as unexplained
;; rather than being blamed on a path that never ran.  Nothing of the
;; command, its output or its transcript is in it: ids, times, a state,
;; a reason and the path of its log, and no more.

(defun harness-tools-jobs--evidence-path ()
  "Return the file the lifecycle of every job is recorded in, or nil.
It is under `harness-state-directory', which a harness that has none --
one built only for a test of something else -- does not get."
  (let ((dir (and (boundp 'harness-state-directory) (symbol-value 'harness-state-directory))))
    (and (stringp dir) (not (string-empty-p dir))
         (expand-file-name harness-tools-jobs--evidence-file-name dir))))

(defun harness-tools-jobs--evidence-signal-name (number)
  "Return the name of signal NUMBER, or nil when it is none.
Only the numbers a job can plausibly be killed by are named; anything
else up to 31 is `SIG<N>', and a number that is no signal at all is nil."
  (pcase number
    (1 "HUP") (2 "INT") (3 "QUIT") (6 "ABRT") (9 "KILL")
    (11 "SEGV") (13 "PIPE") (14 "ALRM") (15 "TERM")
    ((and (pred integerp) (pred natnump))
     (and (<= number 31) (format "SIG%d" number)))
    (_ nil)))

(defun harness-tools-jobs--evidence-signal (exit)
  "Return the signal name EXIT, a wait status, was killed by, or nil.
A command ended by a signal has the shell's 128+N as its status when a
shell or `timeout' reported it.  Only a status above 128 is read that
way here: 15 is an exit of 15 as often as it is SIGTERM, and guessing
between them would put a signal in the record that nothing observed.
A process the harness itself read the status of is asked instead
\(`process-status'), so its signal is named from the number it saw."
  (and (integerp exit) (> exit 128)
       (harness-tools-jobs--evidence-signal-name (- exit 128))))

(defun harness-tools-jobs--evidence-trim (file)
  "Cut FILE from the front to `harness-tools-jobs-evidence-limit' bytes.
The cut is made at a line boundary, so the file stays whole lines of
JSON, and the oldest events are the ones that go."
  (let ((size (and (file-readable-p file) (file-attribute-size (file-attributes file)))))
    (when (and size (> size harness-tools-jobs-evidence-limit))
      (let ((text (harness-read-file file)))
        (when (and text (> (length text) harness-tools-jobs-evidence-limit))
          (let* ((cut (- (length text) harness-tools-jobs-evidence-limit))
                 (start (or (string-match "\n" text cut) cut)))
            (harness-write-file-atomically file (substring text (1+ start)))))))))

(defun harness-tools-jobs--evidence-write (job event &rest fields)
  "Append EVENT, of JOB's lifecycle, with FIELDS, to the evidence file.
The record names the job, its session and the sandbox run it was in,
and the time; FIELDS add what this event says -- a state, an exit, the
path a stop came by -- and never the job's command or its output.  A
file that cannot be written is said once in the log, and never stops
the job: evidence is what is read after the fact, not what running it
depends on."
  (when-let* ((file (harness-tools-jobs--evidence-path)))
    (let ((record (append (list :at (float-time)
                                :event event
                                :job (plist-get job :id)
                                :session (plist-get job :session)
                                :run (plist-get job :run-id)
                                :sandbox (plist-get job :sandbox)
                                :generation (plist-get job :generation)
                                :log (plist-get job :log))
                          fields)))
      (condition-case err
          (progn
            (harness-ensure-directory (file-name-directory file))
            (let ((coding-system-for-write 'utf-8-unix)
                  (inhibit-message t))
              (write-region (concat (harness-json-encode-text record) "\n")
                            nil file 'append 'silent))
            (harness-tools-jobs--evidence-trim file)
            (setq harness-tools-jobs--evidence-unavailable nil))
        (error
         (unless harness-tools-jobs--evidence-unavailable
           (setq harness-tools-jobs--evidence-unavailable t)
           (harness-log 'warn "jobs: cannot record the lifecycle in %s: %s"
                        file (harness-error-message err))))))))

(defun harness-tools-jobs--evidence-running (job)
  "Record that JOB started running, naming the sandbox run it is in.
The run is the shared sandbox's token, or the job's own process, and
the sandbox is the instance of the runtime it was started in: the two
ids a later reading needs to put a job, its session and its sandbox
together."
  (let* ((run (plist-get job :run))
         (sandbox (and run (harness-sandbox-session-sandbox (plist-get job :session))))
         (proc (plist-get job :process)))
    (setf (plist-get job :run-id)
          (or (and run (plist-get run :token))
              (and proc (process-live-p proc) (format "pid-%s" (process-id proc))))
          (plist-get job :sandbox) (plist-get sandbox :instance)
          (plist-get job :generation) (plist-get sandbox :generation)
          (plist-get job :stop-path) nil
          (plist-get job :stop-reason) nil
          (plist-get job :end-recorded) nil)
    (harness-tools-jobs--evidence-write
     job "start"
     :state "running"
     :timeout (plist-get job :seconds)
     :deadline (plist-get job :deadline)
     :shared (and (plist-get job :shared) t))))

(defun harness-tools-jobs--evidence-stop (job path reason)
  "Record that the harness asked JOB to stop, by PATH, for REASON.
PATH names the handler that asked -- the tool's stop, the deadline, a
session or task ending, the shutdown -- and is what tells a later
reading whether the Harness ended a job itself.  The job keeps it, so
its end says which stop it ended from."
  (setf (plist-get job :stop-path) path
        (plist-get job :stop-reason) reason)
  (harness-tools-jobs--evidence-write job "stop" :path path :reason reason))

(defun harness-tools-jobs--evidence-end (job state exit)
  "Record how JOB ended: STATE, and EXIT as the harness saw it.
The record says whether a Harness stop request had been made -- and by
which path -- and names the signal when the status says one ended it.
A job that ended with no stop request behind it is marked unexplained
rather than attributed to a path that never ran: what killed it is not
something the harness saw, and it does not invent a sender."
  (unless (plist-get job :end-recorded)
    (setf (plist-get job :end-recorded) t)
    (let ((path (plist-get job :stop-path)))
      (harness-tools-jobs--evidence-write
       job "end"
       :state (and state (symbol-name state))
       :exit exit
       :signal (harness-tools-jobs--evidence-signal exit)
       :path path
       :reason (or (plist-get job :stop-reason) (harness-tools-jobs--reason job))
       :teardown (cond (path "harness-stop")
                       ((eq state 'exited) "exit")
                       (t "unexplained"))))))

(defun harness-tools-jobs-evidence (session-id &optional id)
  "Return the recorded lifecycle of SESSION-ID's jobs, oldest first.
Each record is a plist of one event of a job's life: `:event' is
\"start\", \"stop\" or \"end\", `:job' and `:session' name the job and
its session, `:run' and `:sandbox' the run and the runtime it was in,
and `:at' when it happened.  A \"stop\" names the `:path' the harness
was asked to stop the job by, and why; an \"end\" gives its `:state',
`:exit', `:signal' when a signal ended it, and `:teardown' -- whether
the harness asked for it, the command exited, or nothing recorded
explains it.  With ID, only that job's.  The file is bounded, so a very
old job's records are gone: it keeps the most recent
`harness-tools-jobs-evidence-limit' bytes of every job's life."
  (let ((text (and (harness-tools-jobs--evidence-path)
                   (harness-read-file (harness-tools-jobs--evidence-path))))
        (out nil))
    (when text
      (dolist (line (split-string text "\n" t))
        (unless (string-blank-p line)
          (let ((record (condition-case nil (harness-json-parse line) (error nil))))
            (when (and record
                       (equal session-id (plist-get record :session))
                       (or (null id) (equal id (plist-get record :job))))
              (push record out))))))
    (nreverse out)))

(harness-defmethod sandbox/job-evidence (session-id &optional id)
  "Return how the jobs of SESSION-ID started, were stopped and ended.
It is what `harness-tools-jobs-evidence' reads, oldest first: the
durable record of each job's lifecycle, which outlives the job's entry
in memory and the session that ran it.  A client sees its own session's
jobs and no other's."
  (harness-tools-jobs-evidence session-id id))

(defconst harness-tools-jobs--log-interval 1
  "Seconds between two writes of a running job's log.
A job's output arrives in chunks, and its buffer is bounded; the file it
is kept in is written this often while it runs, so a reader of the file
sees what the job has said without paying a write per chunk.")

(defvar harness-tools-jobs--jobs (make-hash-table :test 'equal)
  "Job id -> its state plist.
It is (:id :session :ctx :command :cwd :seconds :deadline :profile
:process :buffer :log :state :exit :reason :restarts :started :ran
:history); `:seconds' is the job's timeout, `:started' and `:ran' a
float time and a count of seconds.")

(defvar harness-tools-jobs--by-session (make-hash-table :test 'equal)
  "Session id -> the ids of its jobs, oldest first.")

(defvar harness-tools-jobs--timer nil
  "Timer that stops the jobs whose time is up.")

;;;; The record

(defconst harness-tools-jobs--job-keys
  '(:id :session :ctx :command :cwd :seconds :deadline :profile
    :process :buffer :log :state :exit :reason :restarts :started :ran
    :history :dropped :log-written :run :shared :pid :was-running
    :run-id :sandbox :generation :stop-path :stop-reason :end-recorded)
  "Every key a job's plist is given when it is made.
It is not documentation only: `harness-tools-jobs--new-job' builds the
record from it, and a test holds every key the module sets to it.  The
`setf' of a `plist-get' key a plist does not have binds the variable it
was given rather than the stored plist, so a key set later but missing
here would quietly be set on a local, never reach the job, and leave a
branch that looks taken and is never taken -- which is what `:was-running'
did (see `harness-tools-jobs--rebuild-shared').  The last six are what
the lifecycle evidence is written from: the run of the job's current
life, the sandbox it ran in, why the harness stopped it and whether its
end was recorded.")

(defun harness-tools-jobs--new-job (&rest fields)
  "Return a new job record with FIELDS, a plist, set in it.
Every key of `harness-tools-jobs--job-keys' is in the result, nil where
FIELDS does not name it, so every later `setf' of the record has a place
to write."
  (let (job)
    (dolist (key harness-tools-jobs--job-keys)
      (setq job (plist-put job key nil)))
    (while fields
      (setq job (plist-put job (pop fields) (pop fields))))
    job))

;;;; Reading a job

(defun harness-tools-jobs--running-p (job)
  "Non-nil while JOB runs.
A job of the session's shared runtime runs in that runtime's supervisor,
not in a process of its own (see `harness-sandbox-session'): it is running
while its run is, and a run whose cancel the harness has asked for is not,
even before the runtime has said it is gone."
  (if-let* ((run (plist-get job :run)))
      (and (eq (harness-sandbox-session-run-state run) 'running)
           (not (plist-get run :cancelled)))
    (let ((proc (plist-get job :process)))
      (and proc (process-live-p proc)))))

(defun harness-tools-jobs--state (job)
  "Return JOB's state: `running', `exited', `stopped' or `failed'.
A job whose process is gone reads as the sentinel left it, or `failed'
when nothing recorded how it ended."
  (if-let* ((run (plist-get job :run)))
      (cond ((and (eq (harness-sandbox-session-run-state run) 'running)
                  (plist-get run :cancelled))
             'stopped)
            (t (pcase (harness-sandbox-session-run-state run)
                 ('running 'running)
                 ('exited 'exited)
                 ('stopped 'stopped)
                 (_ (if (plist-get run :exit) 'exited 'failed)))))
    (let ((proc (plist-get job :process)))
      (cond ((and proc (process-live-p proc)
                  (not (eq (plist-get job :state) 'stopped)))
             'running)
            ((eq (plist-get job :state) 'stopped) 'stopped)
            ((eq (plist-get job :state) 'failed) 'failed)
            ((null (plist-get job :exit)) 'failed)
            (t 'exited)))))

(defun harness-tools-jobs--reason (job)
  "Return why JOB ended, or why it is ending, as its caller reads it.
A job of the session's shared sandbox ends when its run does, and the
run's poll may record why a moment after the state says it stopped; the
run's own reason is read then, so a job stopped at its time says it was
stopped at its time rather than saying nothing."
  (or (plist-get job :reason)
      (and-let* ((run (plist-get job :run)))
        (plist-get run :reason))))

(defun harness-tools-jobs--entry (job)
  "Return JOB's public state, as the tool and the access view show it.
It is (:id :state :command :cwd :started :deadline :timeout :elapsed :exit
:pid :log :reason :restarts :shared): `:timeout' is how long the job may run,
`:elapsed' how long it has run, so that a caller need not guess which one a
count is, and `:shared' says that it runs in the session's one sandbox
rather than a sandbox of its own."
  (let* ((now (float-time))
         (started (plist-get job :started))
         (state (harness-tools-jobs--state job))
         (proc (plist-get job :process)))
    (list :id (plist-get job :id)
          :state state
          :command (plist-get job :command)
          :cwd (plist-get job :cwd)
          :started started
          :deadline (plist-get job :deadline)
          :timeout (plist-get job :seconds)
          :elapsed (and started
                        (if (eq state 'running)
                            (max 0 (- now started))
                          (or (plist-get job :ran) (max 0 (- now started)))))
          :exit (plist-get job :exit)
          :pid (or (and proc (process-live-p proc) (process-id proc))
                   (plist-get job :pid))
          :log (plist-get job :log)
          :reason (harness-tools-jobs--reason job)
          :restarts (or (plist-get job :restarts) 0)
          :shared (and (plist-get job :shared) t))))

(defun harness-tools-jobs-session-entries (session-id)
  "Return the jobs of SESSION-ID, oldest first, as its entries.
Each is what `harness-tools-jobs--entry' gives."
  (when (stringp session-id)
    (delq nil (mapcar (lambda (id) (when-let* ((job (gethash id harness-tools-jobs--jobs)))
                                     (harness-tools-jobs--entry job)))
                      (gethash session-id harness-tools-jobs--by-session)))))

(defun harness-tools-jobs--job (id)
  "Return the job ID names, or nil."
  (and (stringp id) (gethash id harness-tools-jobs--jobs)))

;;;; The backend a job needs
;;
;; What confines a job is not `sandbox/status': that reports the backend
;; the harness found and the *global* policy, while `sandbox/wrap' decides
;; per directory -- a project's .dir-locals.el can set
;; `harness-sandbox-policy' to `off' for the project alone, and a remote
;; directory runs unwrapped whatever the policy is.  A job that asked
;; `sandbox/status' whether it may run would then be started unconfined in
;; a project that says `off', which is the one thing a persistent process
;; must never do.  So the checks below ask the jail about the directory
;; the job runs in -- `sandbox/profiles' -- and then hold the *built*
;; command to them: it must be what bwrap runs, not the command itself.

(declare-function harness-sandbox-session--missing-capabilities "harness-sandbox-session" (held))

(defun harness-tools-jobs--missing-backend-problem (backend)
  "Return why BACKEND cannot hold a job, or nil.
A job runs in its session's runtime, so the question is what the generic
sandbox layer says of the backend, not what this module knows of one:
`sandbox/hold' answers with the lifecycle facts a backend can promise,
and a job needs an instance whose commands can be started, whose output
is the harness's own pipe, and whose processes can be ended and verified
(`harness-sandbox-session--missing-capabilities').  The adapter's own
reason for the fact it lacks goes with it, since that is what a person
reads.  Asking here keeps the refusal before a job is started, where its
reason is shown, rather than letting it fail on its first spawn."
  (cond
   ((null backend)
    "No sandbox backend can hold a job here: no sandbox is available")
   (t
    (let* ((held (ignore-errors (harness-call 'sandbox/hold default-directory
                                              '("bash" "-c" "true"))))
           (missing (and held (harness-sandbox-session--missing-capabilities held)))
           (why (plist-get held :why)))
      (cond
       ;; The backend could not hold an instance at all: that is the whole
       ;; answer, and it is the backend's own.
       ((and why (null (plist-get held :command))) why)
       (missing
        (concat (format "The sandbox backend %s cannot hold a job: no %s, which a job's output and its stop need"
                        backend (mapconcat #'symbol-name missing ", "))
                (and why (format " · %s" why))))
       (t nil))))))

(defun harness-tools-jobs--policy (cwd)
  "Return the sandbox policy in effect for CWD.
It is `config/get' for that directory, which reads a project's
.dir-locals.el, so a project that sets the policy to `off' for itself is
seen as `off' here even when the global setting is `required'.  Without
the config module the option's own value is the answer."
  (let ((policy (and cwd (harness-method-exists-p 'config/get)
                     (ignore-errors (harness-call 'config/get 'harness-sandbox-policy cwd)))))
    (or policy
        (and (boundp 'harness-sandbox-policy) (symbol-value 'harness-sandbox-policy))
        'preferred)))

(defun harness-tools-jobs--backend-problem (&optional cwd)
  "Return why no job can run here, or nil when one can.
CWD is the directory the job would run in: the policy and the backend are
the ones in effect *there*, which a project's own settings can change
\(`harness-tools-jobs--policy', `sandbox/profiles'), and a directory on
another host runs unwrapped however the policy reads.  Both the global
view (`sandbox/status') and the per-directory one (`sandbox/profiles') are
asked, and either saying that no job can be held is enough to refuse: one
answer standing in for the other would be a way past the check.  Without
CWD the global view is all there is, which is what the access view asks
before a job is requested."
  (let* ((policy (harness-tools-jobs--policy cwd))
         (profiles (and cwd (not (file-remote-p cwd))
                        (harness-method-exists-p 'sandbox/profiles)
                        (ignore-errors (harness-call 'sandbox/profiles cwd))))
         (status (and (harness-method-exists-p 'sandbox/status)
                      (ignore-errors (harness-call 'sandbox/status))))
         (backends (delete-dups (delq nil (list (plist-get profiles :backend)
                                                (plist-get status :backend)))))
         (backend-problems (or (delq nil (mapcar #'harness-tools-jobs--missing-backend-problem
                                                backends))
                              ;; Neither view names a backend at all.
                              (unless backends
                                (list (harness-tools-jobs--missing-backend-problem nil)))))
         (off (or (eq policy 'off) (eq (plist-get status :policy) 'off))))
    (cond
     ((and (stringp cwd) (file-remote-p cwd))
      (format "%s is on another host, where a job would run outside the sandbox"
              (harness-abbreviate-file-name cwd)))
     (off
      (if cwd
          (format "harness-sandbox-policy is `off' for %s: a job would be a process outside the jail that outlives its call, which is what the jail prevents"
                  (harness-abbreviate-file-name cwd))
        "harness-sandbox-policy is `off': a job would be a process outside the jail that outlives its call, which is what the jail prevents"))
     (backend-problems (car backend-problems))
     ;; A backend that can hold a job but has no profile to give for CWD
     ;; says why there: `off' for that directory, a remote one, no backend.
     ((plist-get profiles :why) (plist-get profiles :why))
     (t nil))))

(defun harness-tools-jobs--confined-p (command cwd)
  "Non-nil when COMMAND, a built command line, is one the sandbox confines.
This is the check that makes the others mean something: the profile was
asked about a directory, and what comes back is what will be spawned.  A
command built from the same profile that comes back unchanged is one
`sandbox/wrap' would run unconfined -- the `off' policy, a remote
directory, no backend -- so it is compared with that.  A backend is one a
job can run under when `sandbox/hold' gives the lifecycle facts the
harness's runtime manager needs (see
`harness-sandbox-session--missing-capabilities'): a backend that cannot
end a process and verify it is refused here, before a job runs, and not
by a program name this module happens to know."
  (let* ((unwrapped '("true"))
         (profile (ignore-errors
                    (harness-tools-shell-sandbox-profile (list :cwd cwd) cwd)))
         (plain (and profile
                     (ignore-errors (harness-tools-shell-wrap-profile profile unwrapped))))
         (held (and (harness-method-exists-p 'sandbox/hold)
                    (ignore-errors (harness-call 'sandbox/hold cwd unwrapped)))))
    (and (consp command)
         (stringp (car command))
         plain
         (not (equal (harness-tools-shell-wrap-profile profile command) command))
         held
         (null (harness-sandbox-session--missing-capabilities held))
         t)))

(defun harness-tools-jobs--confinement-problem (cwd)
  "Return why a job in CWD would not be confined as a bash command is, or nil.
Both halves of the answer are needed: the backend CWD's policy selects
can hold a job (see `harness-tools-jobs--backend-problem'), and the
command built for CWD is one that backend confines and can hold (see
`harness-tools-jobs--confined-p').  The second is asked because the first
is a module's description of itself, and the second is what will run: a
command that comes back unchanged would run unconfined, and one whose
backend promises no verifiable stop would run in a sandbox that cannot
hold a job."
  (or (harness-tools-jobs--backend-problem cwd)
      (let* ((unwrapped '("true"))
             (ctx (list :cwd cwd :session-id nil))
             (profile (ignore-errors (harness-tools-shell-sandbox-profile ctx cwd)))
             (wrapped (and profile
                           (ignore-errors (harness-tools-shell-wrap-profile profile unwrapped)))))
        (cond
         ((null profile)
          (format "No sandbox profile can be built for %s, so a job there would run unconfined"
                  (harness-abbreviate-file-name cwd)))
         ((null wrapped)
          (format "A command in %s cannot be wrapped for the sandbox, so a job there would not be confined"
                  (harness-abbreviate-file-name cwd)))
         ((equal wrapped unwrapped)
          (format "A command in %s runs unconfined, so a job there would outlive its call outside the jail"
                  (harness-abbreviate-file-name cwd)))
         ((harness-tools-jobs--confined-p wrapped cwd) nil)
         (t
          (format "A command in %s would run under a sandbox backend that cannot hold a job"
                  (harness-abbreviate-file-name cwd)))))))

;;;; The directory a job may still run in
;;
;; A job's directory is fixed when it starts and bwrap mounts it writable
;; at its own path (`harness-sandbox--mounts', `--bind CWD CWD'), whatever
;; else the profile lists.  A directory granted for one task and then
;; revoked must therefore not come back with a restart: the grant is
;; checked again, against what the session may reach *now*, before every
;; spawn, and a directory that is no longer the session's stops the job
;; instead of being mounted again.

(defun harness-tools-jobs--authorized-dirs (ctx)
  "Return the directories CTX's session may touch now, with their modes.
Each is (:dir DIR :writable BOOL), symbolic links resolved as the sandbox
resolves them: the session's working directory and worktree, its own
temporary directory, the configured ones, those granted to it and the
read-only ones -- the last with `:writable' nil.  The mode is kept rather
than dropped: a directory the session may still read but no longer write
is one a job must not be started in with a writable mount, and one whose
mode changed is a reason to restart what ran there.  Nil without the
permissions module, which is no narrower answer than a bash command gets
-- such a harness has no directory jail for any call -- and nil for a
session whose commands run on another host."
  (when (and (plist-get ctx :session-id)
             (not (plist-get ctx :host))
             (harness-method-exists-p 'permission/dirs))
    (ignore-errors
      (delq nil (mapcar (lambda (entry)
                          (let ((dir (plist-get entry :dir)))
                            (and (stringp dir) (not (file-remote-p dir))
                                 (list :dir (file-name-as-directory (expand-file-name dir))
                                       :writable (not (harness-json-true-p
                                                       (plist-get entry :read-only)))))))
                        (harness-call 'permission/dirs (plist-get ctx :session-id)))))))

(defun harness-tools-jobs--cwd-authorized-p (cwd ctx)
  "Non-nil when CWD is a directory CTX's session may still run a job in.
A cwd that lies inside one of the session's writable directories is,
symbolic links resolved: the session reaches it the way a bash call there
would, and writes there.  A cwd the session no longer has is not, and a
job there would be a mount of what its session gave up.  A cwd the session
may now only *read* is not one either: a job outlives its call, and a
directory kept for reading is kept from writing, not from a process that
was started before the change."
  (let ((cwd (file-name-as-directory (expand-file-name cwd)))
        (dirs (harness-tools-jobs--authorized-dirs ctx)))
    (and dirs
         (cl-some (lambda (entry)
                    (and (plist-get entry :writable)
                         (let ((dir (plist-get entry :dir)))
                           (or (harness-path-within-p dir cwd)
                               (harness-path-within-p (file-truename dir)
                                                      (file-truename cwd))))))
                  dirs))))

(defun harness-tools-jobs--session-record (session-id)
  "Return what the session SESSION-ID is now, or nil when it is gone.
A job's context was written when it started; a session that moved or whose
access changed since then is not the one the job was built for, so every
spawn reads it again rather than trusting the copy in the job."
  (when (and session-id (harness-method-exists-p 'session/get)
             (harness-method-exists-p 'session/exists-p))
    (when (harness-call 'session/exists-p session-id)
      (ignore-errors (harness-call 'session/get session-id)))))

;;;; Starting one

(defun harness-tools-jobs--session (ctx)
  "Return CTX's session id, or signal that a job runs in no session."
  (or (plist-get ctx :session-id)
      (signal 'harness-error (list "bash_job runs in no session"))))

(defun harness-tools-jobs--cwd (input ctx)
  "Return the directory a job with INPUT under CTX runs in."
  (let* ((given (plist-get input :cwd))
         (cwd (if (and (stringp given) (not (string-blank-p given)))
                  (harness-tools-resolve-path given ctx)
                (or (plist-get ctx :cwd) default-directory))))
    (when (file-remote-p cwd)
      (signal 'harness-error
              (list (format "%s is on another host, where a job would run outside the sandbox"
                            (harness-abbreviate-file-name cwd)))))
    (unless (file-directory-p cwd)
      (signal 'harness-error (list (format "Working directory does not exist: %s"
                                           (harness-abbreviate-file-name cwd)))))
    (file-name-as-directory (expand-file-name cwd))))

(defun harness-tools-jobs--seconds (input)
  "Return how many seconds a job with INPUT may run, within the TTL."
  (let* ((asked (plist-get input :timeout))
         (asked (cond ((numberp asked) asked)
                      ((and (stringp asked) (string-match-p "\\`[0-9.]+\\'" asked))
                       (string-to-number asked))
                      (t harness-tools-jobs--default-seconds))))
    (max 1 (min harness-tools-jobs-ttl (truncate asked)))))

(defun harness-tools-jobs--extra-read-only ()
  "Return the global read-only directories a job's sandbox must mount now.
`harness-sandbox-extra-read-only-dirs' is consumed by `sandbox/wrap'
itself, not by the profile `harness-tools-shell-sandbox-profile' builds,
so two profiles compare equal when it changes and a job would keep a
mount the setting took away.  Every access input has to be in what is
compared, so the value is carried in the profile (see
`harness-tools-jobs--profile') and a change of it rebuilds the job."
  (when (boundp 'harness-sandbox-extra-read-only-dirs)
    (delete-dups (delq nil (mapcar #'expand-file-name
                                   (ignore-errors (symbol-value 'harness-sandbox-extra-read-only-dirs)))))))

(defun harness-tools-jobs--profile (ctx cwd)
  "Return the sandbox profile a job of CTX's session runs in at CWD.
It is the profile a bash command gets, so a job sees what bash sees, with
`:extra-read-only' added: the global read-only directories the sandbox
mounts without the profile naming them (see
`harness-tools-jobs--extra-read-only').  The profile is the job's
fingerprint as well as its build plan: whatever is in it that changes
rebuilds the job, so a mount that is taken away is taken away.  A
directory made for one call (`:scratch') is refused: a job outlives the
call that would have deleted it."
  (let ((profile (harness-tools-shell-sandbox-profile ctx cwd)))
    (when (plist-get profile :scratch)
      (signal 'harness-error
              (list "A job cannot use a directory made for one call: ask for the directory for the session")))
    (plist-put profile :extra-read-only (harness-tools-jobs--extra-read-only))))

(defun harness-tools-jobs--prepare (job _call-ctx)
  "Return JOB ready to spawn now, or signal why it may not run.
Every spawn goes through here -- a start, a restart and an automatic
rebuild -- so no path can be the one that skips a check:

- the session is read again, and a session that is gone stops rather than
  runs for nobody;
- the directory is authorised again against `permission/dirs', so a
  directory the session was granted and then lost is not mounted again,
  and that is also what a session that moved and gave its old directory
  up is caught by;
- the effective confinement of that directory is asked for, and the
  command that will be spawned must be confined by a backend that can
  hold it;
- the profile is built again, so what the job runs with is what the
  session may reach now.

The job's `:ctx' is refreshed from the session, so the skills directories,
the temporary directory and the log path are the session's current ones
rather than the ones of the call that started it."
  (let* ((sid (plist-get job :session))
         (cwd (plist-get job :cwd))
         (old-ctx (plist-get job :ctx))
         (record (harness-tools-jobs--session-record sid))
         (moved (and record (plist-get record :cwd)))
         (ctx (if record
                  (list :session-id sid
                        :cwd (or moved (plist-get old-ctx :cwd))
                        :host (plist-get record :host))
                old-ctx)))
    (cond
     ((null record)
      (signal 'harness-error (list "its session no longer exists")))
     ((not (file-directory-p cwd))
      (signal 'harness-error
              (list (format "its directory %s does not exist any more"
                            (harness-abbreviate-file-name cwd)))))
     ((and (harness-method-exists-p 'permission/dirs)
           (not (harness-tools-jobs--cwd-authorized-p cwd ctx)))
      (signal 'harness-error
              (list (format "its session may no longer reach %s"
                            (harness-abbreviate-file-name cwd)))))
     (t
      (let ((problem (harness-tools-jobs--confinement-problem cwd)))
        (if problem
            (signal 'harness-error (list problem))
          (setf (plist-get job :ctx) ctx)
          job))))))

(defun harness-tools-jobs--spawn-confinement (job)
  "Return why JOB's built command is not confined, or nil.
The last check before `make-process': what the profile produces for the
job's own command must be confined, by a backend that promises the
lifecycle a held run needs, so a profile that names a directory
`sandbox/wrap' will not confine -- or one whose adapter cannot promise a
verified stop -- fails closed rather than spawn the command as it is."
  (let ((command (plist-get job :command)))
    (let ((wrapped (ignore-errors (harness-tools-jobs--wrap job))))
      (cond
       ((null wrapped)
        "its sandbox command could not be built")
       ((equal wrapped command)
        "its command would run unconfined")
       ((harness-tools-jobs--confined-p wrapped (plist-get job :cwd)) nil)
       (t "its command would run under a sandbox backend that cannot hold a job")))))

(defun harness-tools-jobs--command (job)
  "Return the command line that runs JOB's command inside its sandbox.
The sandbox's own `timeout' bounds it, whatever becomes of the harness."
  (list "timeout"
        "--signal=TERM"
        (format "--kill-after=%ds" harness-tools-jobs--kill-after)
        (format "%ds" (plist-get job :seconds))
        "bash" "-c" (plist-get job :command)))

(defun harness-tools-jobs--wrap (job)
  "Return JOB's command line wrapped in the sandbox its profile names."
  (harness-tools-shell-wrap-profile (plist-get job :profile)
                                    (harness-tools-jobs--command job)))

(defun harness-tools-jobs--note-line (buffer)
  "Return the last visible line of the output in BUFFER, or nil."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (save-excursion
        (goto-char (point-max))
        (forward-line -1)
        (let ((line (string-trim (buffer-substring-no-properties (line-beginning-position)
                                                                 (line-end-position)))))
          (unless (string-empty-p line) (truncate-string-to-width line 120)))))))

(defun harness-tools-jobs--clamp (text)
  "Return TEXT cut to the job output limit, with a line saying how much went.
The cut takes the front, because the end of a log is what a caller reads:
what a job said last is worth more than what it said first, and the line
it starts with says what is missing so nobody mistakes the tail for the
whole."
  (if (<= (length text) harness-tools-jobs-output-limit)
      text
    (let ((kept (substring text (- (length text) harness-tools-jobs-output-limit))))
      (concat (format "[... %s of output dropped]\n"
                      (harness-format-bytes (- (length text) (length kept))))
              kept))))

(defun harness-tools-jobs--append-output (job chunk)
  "Append CHUNK to JOB's output buffer, keeping it bounded.
The buffer is looked up at each chunk, not captured: it is made just
before the process -- or the run in the session's sandbox -- and stored
on the job just after it, so this must read it when the first output
arrives.  It is bounded (see `harness-tools-jobs-output-limit'): a job
that prints without end costs the harness a bounded amount of memory
rather than growing a buffer until Emacs cannot.  The front is what goes
-- the end is what a caller reads -- and one line at the top says how
much, so the tail is never mistaken for the whole."
  (let ((buffer (plist-get job :buffer)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((inhibit-read-only t)
              (limit harness-tools-jobs-output-limit))
          (goto-char (point-max))
          (insert chunk)
          (when (> (buffer-size) limit)
            (let ((drop (- (buffer-size) limit)))
              (setf (plist-get job :dropped)
                    (+ (or (plist-get job :dropped) 0) drop))
              (goto-char (point-min))
              (delete-region (point-min) (+ (point-min) drop))
              (goto-char (point-min))
              (insert (format "[... %s of earlier output dropped]\n"
                              (harness-format-bytes (plist-get job :dropped)))))))))))

(defun harness-tools-jobs--filter (job)
  "Return the output filter of JOB, whose output goes to its own buffer."
  (lambda (_proc chunk)
    (harness-tools-jobs--append-output job chunk)))

(defun harness-tools-jobs--sentinel (job)
  "Return the sentinel of JOB."
  (lambda (proc _event)
    (unless (process-live-p proc)
      (let ((status (process-exit-status proc)))
        (setf (plist-get job :ran) (max 0 (- (float-time) (plist-get job :started))))
        ;; A job the harness stopped says so.  One that ended by itself
        ;; keeps its exit status, but the sandbox's own `timeout' is not
        ;; a crash: 124 is its TERM and 137 its KILL, so a job that ran
        ;; past its deadline reads as stopped, with the reason the
        ;; harness would have given it.
        (cond
         ((eq (plist-get job :state) 'stopped) nil)
         ((memq status '(124 137))
          (setf (plist-get job :state) 'stopped
                (plist-get job :reason)
                (format "it reached its timeout of %s"
                        (harness-format-duration (plist-get job :seconds)))))
         (t (setf (plist-get job :exit) status
                  (plist-get job :state) (if (eql status 0) 'exited 'failed))))
        ;; How it ended is written down before the log, so a job that
        ;; died with no stop request behind it -- a signal nothing in the
        ;; harness sent -- is in the record as unexplained rather than
        ;; remembered only as a debug line nothing keeps.
        (harness-tools-jobs--evidence-end job (plist-get job :state) status)
        (harness-log 'debug "jobs: %s ended (%s)" (plist-get job :id) status)
        (ignore-errors (harness-tools-jobs--write-log job))))))

(defun harness-tools-jobs--produced-text (job)
  "Return what the current run of JOB has printed, or nil.
A job of its own writes into the buffer the harness keeps for it; a job
of the session's shared runtime keeps what its run printed, which the
harness decoded from the run's frames rather than read from a file (see
`harness-sandbox-session').  Either way the text is what this run has
said, without the history of earlier runs."
  (let ((buffer (plist-get job :buffer))
        (run (plist-get job :run)))
    (cond
     ((and buffer (buffer-live-p buffer))
      (with-current-buffer buffer (buffer-string)))
     (run
      (concat (or (plist-get run :stdout) "")
              (or (plist-get run :stderr) ""))))))

(defun harness-tools-jobs--write-log (job)
  "Write the output of JOB to the log file the harness keeps for it.
The log is a file of the session's temporary directory, outside the
sandbox's own writing, so a job cannot make the harness read what it did
not write.  What earlier runs of the same job said stays above what this
one says, so a restart neither hides nor loses it, and the whole is cut to
the job output limit from the front: a job that restarts for ever leaves
one bounded file, not one per restart.  A write is cheap and bounded, so
it happens while the job runs as well as when it ends, which is what a
reader of the file sees.

A job of the session's shared sandbox has its run's own output file,
which the sandbox writes; this keeps the job's log beside it, so what a
caller reads back is the same bounded log whichever sandbox the job ran
in."
  (let ((log (plist-get job :log))
        (history (or (plist-get job :history) ""))
        (text (harness-tools-jobs--produced-text job)))
    (when (and (stringp log) text)
      (harness-write-file-atomically
       log (harness-tools-jobs--clamp
            (concat (format "# %s  %s  in %s\n\n"
                            (plist-get job :id)
                            (if (eq (harness-tools-jobs--state job) 'running)
                                (format-time-string "started %Y-%m-%d %H:%M:%S")
                              (format "%s  %s"
                                      (symbol-name (harness-tools-jobs--state job))
                                      (format-time-string "%Y-%m-%d %H:%M:%S")))
                            (harness-abbreviate-file-name (plist-get job :cwd)))
                    history text)))
      (setf (plist-get job :log-written) (float-time)))))

(defun harness-tools-jobs--flush-logs ()
  "Write the log of every running job that has written since it was last written.
At most once every `harness-tools-jobs--log-interval', so a job that prints
a great deal does not pay for a file write per chunk; the buffer is
already bounded, so each write is."
  (let ((now (float-time)))
    (maphash (lambda (_id job)
               (when (and (harness-tools-jobs--running-p job)
                          (or (null (plist-get job :log-written))
                              (>= (- now (plist-get job :log-written))
                                  harness-tools-jobs--log-interval)))
                 (ignore-errors (harness-tools-jobs--write-log job))))
             harness-tools-jobs--jobs)))

(defun harness-tools-jobs--keep-output (job)
  "Move what JOB's current run printed into its history.
Called when the job stops or is restarted: the next run's output is kept
under this one in the log.  The history is bounded like the output, so a
job restarted many times does not grow it without end."
  (let ((buffer (plist-get job :buffer))
        (text (harness-tools-jobs--produced-text job)))
    (when (and text (not (string-empty-p text)))
      (setf (plist-get job :history)
            (harness-tools-jobs--clamp
             (concat (or (plist-get job :history) "") text "\n"))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((inhibit-read-only t)) (erase-buffer))))))

(defun harness-tools-jobs--spawn (job)
  "Start JOB's process and return JOB, or signal what stands in the way.
Nothing of a job whose process cannot start is kept: its entry goes, so
a failed start leaves no job behind.  The deadline is the one the job
already has: a restart -- by a call or by a change of access -- runs the
rest of the job's time, not another `:seconds' of it, so restarting is
never a way to a longer life than the one granted."
  (let* ((command (harness-tools-jobs--wrap job))
         (cwd (plist-get job :cwd))
         (buffer (generate-new-buffer (format " *job %s*" (plist-get job :id)) t))
         (default-directory (file-name-as-directory cwd))
         (proc nil))
    (unwind-protect
        (progn
          (setq proc (make-process
                      :name (format "harness-job-%s" (plist-get job :id))
                      :command command
                      :connection-type 'pipe
                      :coding 'utf-8-unix
                      :noquery t
                      :buffer buffer
                      :filter (harness-tools-jobs--filter job)
                      :sentinel (harness-tools-jobs--sentinel job)))
          (setf (plist-get job :process) proc
                (plist-get job :buffer) buffer
                (plist-get job :state) 'running
                (plist-get job :exit) nil
                (plist-get job :reason) nil
                (plist-get job :started) (float-time)
                (plist-get job :deadline)
                (or (plist-get job :deadline)
                    (+ (float-time) (plist-get job :seconds))))
          (harness-tools-jobs--evidence-running job)
          (harness-tools-jobs--write-log job)
          job)
      (unless proc
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(defun harness-tools-jobs--forget (job)
  "Drop JOB from the tables, so nothing lists it again."
  (let ((id (plist-get job :id))
        (sid (plist-get job :session)))
    (remhash id harness-tools-jobs--jobs)
    (when sid
      (puthash sid (delq id (gethash sid harness-tools-jobs--by-session))
               harness-tools-jobs--by-session))
    (when (buffer-live-p (plist-get job :buffer))
      (kill-buffer (plist-get job :buffer)))))

;;;; Stopping one

(defun harness-tools-jobs--stop (job &optional reason path)
  "Stop JOB for REASON, asked for by PATH, and return it.
PATH names the handler that stopped it -- the tool's stop, the deadline,
its session or task ending, the shutdown -- and is recorded with the
reason in the job's lifecycle (see `harness-tools-jobs-evidence'), so a
later reading can tell a teardown the Harness asked for from one nothing
here explains.

A job of the session's shared sandbox is one run in it, so stopping the
job ends that run -- its own process group -- and leaves the sandbox,
and whatever else the session runs, going.  A job that runs in a sandbox
of its own, where the session cannot hold a runtime, has that sandbox's
init get END-OF-FILE, and its `--die-with-parent' means the kernel ends
every process of the job's namespace when it goes, so what a script left
running goes with it.  A job that already ended is left as it is, with
the reason recorded."
  (let ((proc (plist-get job :process))
        (run (plist-get job :run)))
    ;; A job its session stopped is not one to carry into a sandbox a
    ;; later change builds.
    (setf (plist-get job :was-running) nil)
    (when (or run (and proc (process-live-p proc)))
      (harness-tools-jobs--evidence-stop job (or path "harness") reason))
    (when run
      (if (eq (harness-sandbox-session-run-state run) 'running)
          (progn
            (setf (plist-get job :reason) reason)
            (harness-log 'debug "jobs: stopping %s (%s)" (plist-get job :id) (or reason "no reason"))
            (harness-sandbox-session-kill-run run reason)
            ;; The run's own poll marks it stopped and calls the job's
            ;; `:done', which records its exit; this keeps the job's state
            ;; true at once.  What it said is kept as history, so the log
            ;; has both runs after the job is started again.
            (harness-tools-jobs--keep-output job)
            (setf (plist-get job :state) 'stopped
                  (plist-get job :reason) reason
                  (plist-get job :ran) (max 0 (- (float-time) (or (plist-get job :started)
                                                                  (float-time)))))
            (ignore-errors (harness-tools-jobs--write-log job)))
        ;; The run has already ended -- the sandbox it was in went, and
        ;; took it with it -- so what this says is why, not that it ends.
        ;; Its output is history either way, and its own reason -- the
        ;; directory the session lost, the policy that no longer confines
        ;; it -- wins over what the sandbox's ending said.
        (harness-tools-jobs--keep-output job)
        (when reason
          (setf (plist-get job :reason) reason))))
    (when (and proc (process-live-p proc) (not (plist-get job :shared)))
      (setf (plist-get job :reason) reason)
      (harness-log 'debug "jobs: stopping %s (%s)" (plist-get job :id) (or reason "no reason"))
      (ignore-errors (delete-process proc))
      (let ((deadline (+ (float-time) 5)))
        (while (and (process-live-p proc) (< (float-time) deadline))
          (accept-process-output nil 0.02)))
      (when (process-live-p proc)
        (ignore-errors (signal-process (process-id proc) 'kill)))
      (setf (plist-get job :state) 'stopped
            (plist-get job :ran) (max 0 (- (float-time) (plist-get job :started))))
      ;; Its own process is the end of a job of its own: the sentinel
      ;; recorded what it exited with, and this says how the harness read
      ;; the end it asked for.
      (harness-tools-jobs--evidence-end job 'stopped (plist-get job :exit))
      (ignore-errors (harness-tools-jobs--keep-output job))
      (ignore-errors (harness-tools-jobs--write-log job)))
    job))

(defun harness-tools-jobs-stop-job (id &optional reason)
  "Stop the job ID for REASON; return its entry, or nil when there is none."
  (when-let* ((job (harness-tools-jobs--job id)))
    (harness-tools-jobs--stop job reason "stop-job")
    (harness-tools-jobs--entry job)))

(defun harness-tools-jobs--stop-all (session-id reason &optional path)
  "Stop every job of SESSION-ID for REASON, asked for by PATH."
  (dolist (id (copy-sequence (gethash session-id harness-tools-jobs--by-session)))
    (when-let* ((job (harness-tools-jobs--job id)))
      (harness-tools-jobs--stop job reason (or path "stop-all")))))

(defun harness-tools-jobs--end-all (session-id reason &optional path)
  "Stop every job of SESSION-ID for REASON, asked for by PATH, and forget it.
For a session that is deleted or closed: nothing of it is left to list, so
nothing of it is left in the tables either."
  (dolist (id (copy-sequence (gethash session-id harness-tools-jobs--by-session)))
    (when-let* ((job (harness-tools-jobs--job id)))
      (harness-tools-jobs--stop job reason (or path "end-all"))
      (harness-tools-jobs--forget job))))

;;;; The ones that are over

(defun harness-tools-jobs--expired-p (job)
  "Non-nil when JOB has run past its deadline."
  (let ((deadline (plist-get job :deadline)))
    (and deadline (>= (float-time) deadline))))

(defun harness-tools-jobs--tick-all ()
  "Stop every job whose time is up, and write the logs of the others."
  (maphash (lambda (_id job)
             (when (and (harness-tools-jobs--running-p job)
                        (harness-tools-jobs--expired-p job))
               (harness-tools-jobs--stop
                job (format "it reached its timeout of %s"
                            (harness-format-duration (plist-get job :seconds)))
                "timeout")))
           harness-tools-jobs--jobs)
  (harness-tools-jobs--flush-logs))

(defun harness-tools-jobs--rebuild (job)
  "Bring JOB's sandbox in line with what its session may reach now.
Return JOB when its profile is unchanged or it was restarted, nil when it
was stopped.  A changed profile restarts the command in the new sandbox --
it is the same command in a different set of mounts -- and anything that
makes it impossible to run -- a directory the session lost, a policy that
no longer confines it, a backend that cannot hold it, a profile that
cannot be built -- stops it with the reason, so a job never keeps
authority its session no longer has.  The check is the same one a start
makes (see `harness-tools-jobs--prepare'): a rebuild is a spawn, and no
spawn skips it.

A job of the session's shared sandbox runs in the sandbox itself, which
the change rebuilds: the run in it ends with the sandbox, and the job is
given a new run in the new one (see `harness-tools-jobs--rebuild-shared').
This function settles whether the job may run at all, and it is run
again after the sandbox exists."
  (let* ((old (plist-get job :profile))
         ;; A profile is itself a plist, so a failed build is marked by a
         ;; keyword of its own rather than by being a cons.
         (current (condition-case err
                      (progn
                        (harness-tools-jobs--prepare job nil)
                        (list :profile (harness-tools-jobs--profile
                                        (plist-get job :ctx) (plist-get job :cwd))))
                    (error (list :error (harness-error-message err)))))
         (why (and (eq (car current) :error) (cadr current)))
         (current (and (eq (car current) :profile) (cadr current))))
    (cond
     (why
      (harness-tools-jobs--stop job (format "its session may no longer run it: %s" why)
                                "rebuild")
      nil)
     ((plist-get job :shared)
      ;; Its sandbox is the session's one, which the change rebuilds: the
      ;; run in it ends with the sandbox, and the job is given a new run
      ;; there afterwards (see `harness-tools-jobs--on-sandbox-rebuilt').
      ;; All this pass settles is whether it may run at all -- and a
      ;; session that may no longer have a shared sandbox (read-only, the
      ;; `off' policy, another backend) may not: what the job runs in is
      ;; not there to rebuild, so it stops rather than being carried into
      ;; nothing.
      (let ((problem (and (fboundp 'harness-sandbox-session-problem)
                          (harness-sandbox-session-problem
                           (plist-get job :ctx) (plist-get job :cwd)))))
        (if problem
            (progn (harness-tools-jobs--stop
                    job (format "its session may no longer run it: %s" problem)
                    "rebuild")
                   nil)
          job)))
     ((equal current old) job)
     ((harness-tools-jobs--expired-p job)
      (harness-tools-jobs--stop job "its time is up, and its sandbox changed, so it was not restarted"
                                 "rebuild")
      nil)
     ((not (harness-tools-jobs--running-p job))
      ;; Nothing left to rebuild: a job that ended is not restarted.
      job)
     ((>= (or (plist-get job :restarts) 0) harness-tools-jobs-max-restarts)
      (harness-tools-jobs--stop
       job (format "its sandbox changed again after %s, so it was not restarted again"
                   (harness-tools-count-phrase harness-tools-jobs-max-restarts "restart"))
       "rebuild")
      nil)
     (t
      (harness-log 'warn "jobs: %s restarted, what its session may reach changed" (plist-get job :id))
      (harness-tools-jobs--stop job "its sandbox changed, so it is restarted in the new one"
                                 "restart")
      (setf (plist-get job :profile) current
            (plist-get job :restarts) (1+ (or (plist-get job :restarts) 0)))
      (condition-case err
          (harness-tools-jobs--spawn job)
        (error (harness-tools-jobs--stop
                job (format "its sandbox could not be built again: %s"
                            (harness-error-message err))
                "restart")
               nil))))))

(defun harness-tools-jobs--rebuild-shared (job current)
  "Give JOB, of the session's shared runtime, a run in the runtime it has now.
CURRENT is the profile the job would be built with now.  A job still
running in the runtime is left alone; one whose run ended because the
runtime was ended is started again, in the runtime the next call builds,
and one whose session may no longer hold a runtime at all is stopped with
that reason.  A job that has run its restarts, or its time, is not
started again.

A runtime is not kept between calls (see
`harness-sandbox-session-idle-seconds'): the one a job ran in is ended
when what the session may reach changes, and the run started here is what
builds the next one.  So the question is what the session may hold, not
what it holds this moment."
  (ignore current)
  (cond
   ((harness-tools-jobs--running-p job) job)
   ((not (harness-tools-jobs--shared-p (plist-get job :ctx) (plist-get job :cwd)))
    (harness-tools-jobs--stop
     job (or (plist-get job :reason) "its session may no longer hold a runtime")
     "rebuild")
    nil)
   ((not (plist-get job :was-running))
    ;; Its run ended before the change -- it had finished, or its session
    ;; stopped it -- so there is nothing to carry into the next runtime.
    job)
   ((harness-tools-jobs--expired-p job)
    (harness-tools-jobs--stop job "its time is up, and its sandbox changed, so it was not restarted"
                              "rebuild")
    nil)
   ((>= (or (plist-get job :restarts) 0) harness-tools-jobs-max-restarts)
    (harness-tools-jobs--stop
     job (format "its sandbox changed again after %s, so it was not restarted again"
                 (harness-tools-count-phrase harness-tools-jobs-max-restarts "restart"))
     "rebuild")
    nil)
   (t
    (harness-log 'warn "jobs: %s restarted, its session's sandbox was rebuilt" (plist-get job :id))
    (setf (plist-get job :restarts) (1+ (or (plist-get job :restarts) 0))
          ;; Carried once: the run started here is the one a later change
          ;; has to note again to have it carried in its turn.
          (plist-get job :was-running) nil)
    (condition-case err
        (harness-tools-jobs--start-shared job)
      (error (harness-tools-jobs--stop
              job (format "its sandbox could not be built again: %s"
                          (harness-error-message err))
              "restart")
             nil)))))

(defun harness-tools-jobs-rebuild-session (session-id &optional note-running)
  "Rebuild or stop the jobs of SESSION-ID after what it may reach changed.
With NOTE-RUNNING, each job still running is marked as one to carry into
the sandbox the change builds: the sandbox a shared job runs in is
rebuilt after this, and what it ran ended with it."
  (dolist (id (copy-sequence (gethash session-id harness-tools-jobs--by-session)))
    (when-let* ((job (harness-tools-jobs--job id)))
      (when note-running
        ;; Sticky, and read before anything stops it: the jobs pass comes
        ;; first, so the job still runs when it is noted, and the sandbox
        ;; module's rebuild then ends the run.
        (setf (plist-get job :was-running)
              (or (plist-get job :was-running)
                  (and (harness-tools-jobs--running-p job) t))))
      (condition-case err
          (harness-tools-jobs--rebuild job)
        (error (harness-log 'error "jobs: %s could not be rebuilt: %s"
                            id (harness-error-message err))
               (harness-tools-jobs--stop
                job (format "its sandbox could not be rebuilt: %s" (harness-error-message err))
                "rebuild"))))))

(defun harness-tools-jobs--on-access-changed (session-id &rest _)
  "Rebuild the jobs of SESSION-ID after what it may reach changed.
It runs before the sandbox the session shares is rebuilt (see the
priority in `harness-tools-jobs--init'), so the jobs that were running
are known when their runs end with the sandbox."
  (harness-tools-jobs-rebuild-session session-id t))

(defun harness-tools-jobs--on-sandbox-rebuilt (session-id _rebuilt &rest _)
  "Give SESSION-ID's shared jobs a run in its new sandbox.
The sandbox was rebuilt, or ended for want of one; either way what ran
in it ended, and a job that was running when the change came is started
again there."
  (dolist (id (copy-sequence (gethash session-id harness-tools-jobs--by-session)))
    (when-let* ((job (harness-tools-jobs--job id)))
      (when (plist-get job :shared)
        ;; The reason the jobs pass found -- a directory the session lost,
        ;; a policy that no longer confines it -- is the one the caller
        ;; reads: a stop keeps a reason the job already has, and the
        ;; sandbox's own ending is only recorded where there was none
        ;; (see `harness-tools-jobs--shared-done').  Nothing is restored
        ;; over it here: what the pass below decides -- a cap reached, a
        ;; time spent -- is the later word on why the job is not running.
        (condition-case err
            (harness-tools-jobs--rebuild-shared job (plist-get job :profile))
          (error (harness-log 'error "jobs: %s could not be rebuilt: %s"
                              id (harness-error-message err))
                 (harness-tools-jobs--stop
                  job (format "its sandbox could not be rebuilt: %s"
                              (harness-error-message err))
                  "rebuild")))))))

(defun harness-tools-jobs--on-session-ended (session-id &rest _)
  "Stop the jobs of SESSION-ID, which was deleted or closed, and forget them."
  (harness-tools-jobs--end-all session-id "its session ended" "session-ended"))

(defun harness-tools-jobs--on-session-moved (session-id _old new)
  "Stop the jobs of SESSION-ID, which moved to NEW."
  (harness-tools-jobs--stop-all
   session-id (format "its session moved to %s" (harness-abbreviate-file-name new))))

(defun harness-tools-jobs--on-task-done (task &rest _)
  "Stop the jobs of TASK's session, whose work is done."
  (when-let* ((sid (plist-get task :session)))
    (harness-tools-jobs--stop-all sid "its task is done" "task-done")))

(defun harness-tools-jobs--on-task-cancelled (task &rest _)
  "Stop the jobs of TASK's session, whose work the user cancelled.
A cancel is the user ending the work, and a cancel is not a turn ending:
`agent/cancel' tells whatever holds a turn up to let it go, and the task
carries on being a task.  So the module that owns the jobs listens to
`task/cancelled' (which `task/cancel' emits for a task at work) as well
as to the pause and return path (`agent/stop-outstanding'), and nothing
of a cancelled task keeps running.  A cancel of a task that never
started takes its session with it, which `session/deleted' covers."
  (when-let* ((sid (plist-get task :session)))
    (harness-tools-jobs--stop-all sid "its task was cancelled" "task-cancelled")))

(defun harness-tools-jobs--stop-outstanding (value session-id &optional reason)
  "Stop SESSION-ID's jobs and say what stopped, for `agent/stop-outstanding'.
Task mode calls that filter when a task is pre-empted, returned to the
queue, paused, or has its turn cancelled: the work its session left
running outside its turn has to stop with it, and a job is exactly that
kind of work.  Only the session's own jobs stop, so another session's
task is untouched.  VALUE is what the handlers before this one returned;
the answer is VALUE with a line naming the jobs this one stopped, which
is what the task's session is told, or VALUE unchanged when there was
nothing running."
  (let ((running (cl-remove-if-not (lambda (id) (harness-tools-jobs--running-p (harness-tools-jobs--job id)))
                                   (copy-sequence
                                    (gethash session-id harness-tools-jobs--by-session)))))
    (if (null running)
        value
      (harness-tools-jobs--stop-all
       session-id (or reason "its session stopped the work it left running, so the job stopped")
       "stop-outstanding")
      (let ((note (format "Bash %s stopped"
                          (harness-tools-count-phrase (length running) "job"))))
        (if (and (stringp value) (not (string-blank-p value)))
            (concat value "; " note)
          note)))))

(defun harness-tools-jobs--on-config-changed (key &rest _)
  "Rebuild the jobs when KEY changes what a sandbox shows or gives."
  (when (memq key '(harness-sandbox-policy harness-sandbox-backend
                    harness-allowed-directories harness-sandbox-extra-read-only-dirs))
    (let (sessions)
      (maphash (lambda (_id job) (cl-pushnew (plist-get job :session) sessions :test #'equal))
               harness-tools-jobs--jobs)
      ;; Noting the running ones is what the access path does, and for
      ;; the same reason: the sandbox these jobs run in is rebuilt after
      ;; this pass, and a job that was running then is carried into the
      ;; new one rather than read as one that had ended.
      (dolist (sid sessions) (harness-tools-jobs-rebuild-session sid t)))))

;;;; Reading one back

(defun harness-tools-jobs-log-text (entry &optional lines)
  "Return the last LINES of ENTRY's output, or all of it.
A job that runs is read from what its run has said so far -- the buffer
its own command writes into, or the output file of its run in the
session's shared sandbox -- under what its earlier runs said; one that
ended from the log the harness kept for it, which is the same text."
  (let* ((log (plist-get entry :log))
         (job (harness-tools-jobs--job (plist-get entry :id)))
         (current (and job (harness-tools-jobs--produced-text job)))
         (text (cond
                ((and job (or current (plist-get job :history)))
                 (concat (or (plist-get job :history) "") (or current "")))
                ((and (stringp log) (file-readable-p log))
                 (with-temp-buffer
                   (insert-file-contents log)
                   (buffer-string))))))
    (if (not text)
        (if (eq (plist-get entry :state) 'running) "No output yet" "No output")
      (if (and lines (> lines 0))
          (let* ((all (split-string text "\n" nil))
                 (tail (last all (min lines (length all)))))
            (string-join tail "\n"))
        text))))

(defun harness-tools-jobs--status-line (entry)
  "Return one line saying what ENTRY, a job, is and how it goes.
A running one says how long it has run of the time it may run, so a
caller reads both numbers and neither is guessed."
  (format "%s  %s  %s"
          (plist-get entry :id)
          (let* ((state (plist-get entry :state))
                 (elapsed (harness-format-duration (or (plist-get entry :elapsed) 0)))
                 (timeout (plist-get entry :timeout))
                 (span (if timeout (format "%s of %s" elapsed (harness-format-duration timeout))
                         elapsed)))
            (cond ((eq state 'running)
                   (format "running · %s · pid %s" span (or (plist-get entry :pid) "?")))
                  ((eq state 'exited) (format "exited 0 · %s" span))
                  ((eq state 'stopped) (format "stopped · %s" span))
                  (t (format "failed · exit %s · %s" (plist-get entry :exit) span))))
          (harness-first-line (plist-get entry :command) 70)))

(defun harness-tools-jobs--describe (entry)
  "Return what ENTRY, a job, says of itself, over several lines."
  (string-join
   (delq nil
         (list (harness-tools-jobs--status-line entry)
               (format "  in %s" (harness-abbreviate-file-name (plist-get entry :cwd)))
               (and (memq (plist-get entry :state) '(exited stopped failed))
                    (plist-get entry :reason)
                    (format "  %s" (plist-get entry :reason)))
               (and (memq (plist-get entry :state) '(exited stopped failed))
                    (let ((last (car (last (harness-tools-jobs-evidence
                                            (plist-get entry :session) (plist-get entry :id))))))
                      (and (equal "end" (plist-get last :event))
                           (format "  ended: %s"
                                   (pcase (plist-get last :teardown)
                                     ("harness-stop" (format "stopped by the harness · %s"
                                                             (or (plist-get last :path) "-")))
                                     ("exit" "the command exited")
                                     (_ "no recorded stop request: unexplained"))))))
               (and (> (or (plist-get entry :restarts) 0) 0)
                    (format "  restarted %s" (harness-tools-count-phrase
                                              (plist-get entry :restarts) "time")))
               (format "  output: %s" (harness-abbreviate-file-name (plist-get entry :log)))
               (let ((last (and (eq (plist-get entry :state) 'running)
                                (harness-tools-jobs--note-line
                                 (plist-get (harness-tools-jobs--job (plist-get entry :id)) :buffer)))))
                 (and last (format "  last: %s" last)))))
   "\n"))

;;;; The tool

(defun harness-tools-jobs--resolve (ref session-id)
  "Return the job REF names among SESSION-ID's, or signal that it names none.
A job of another session is not found: nothing of it is the caller's."
  (let* ((ref (and (stringp ref) (string-trim ref)))
         (own (and ref (gethash session-id harness-tools-jobs--by-session)))
         (exact (and ref (memq (harness-tools-jobs--job ref) (mapcar #'harness-tools-jobs--job own))
                     (harness-tools-jobs--job ref))))
    (cond
     (exact exact)
     ((or (null ref) (string-empty-p ref))
      (signal 'harness-error (list "bash_job needs id for that action, as start and list name it")))
     (t
      (let ((found (delq nil (mapcar (lambda (id) (and (string-prefix-p ref id) (harness-tools-jobs--job id)))
                                     own))))
        (pcase (length found)
          (0 (signal 'harness-error (list (format "No job %s in this session" ref))))
          (1 (car found))
          (_ (signal 'harness-error
                     (list (format "%s names %s; use the whole id" ref
                                   (harness-tools-count-phrase (length found) "job")))))))))))

(defun harness-tools-jobs--shared-p (ctx cwd)
  "Non-nil when a job of CTX's session in CWD runs in its shared sandbox.
That is when the sandbox-session module is loaded and running, and the
session can hold one there (see `harness-sandbox-session-problem')."
  (and (fboundp 'harness-sandbox-session-start-run)
       (harness-method-exists-p 'sandbox/session)
       (null (harness-sandbox-session-problem ctx cwd))))

(defun harness-tools-jobs--start-shared (job)
  "Start JOB as a detached run of its session's shared sandbox.
The job outlives the call that started it, as it always did -- the
sandbox is the session's -- and it is stopped, listed and read back with
the same actions as a job in a sandbox of its own.  It costs the
session's sandbox one process; the sandbox ends it with everything else
when it is rebuilt or the session ends, and the job's own deadline ends
it as it always did.

The job's `:process' is the process of the sandbox it runs in, not a
process of its own: that is what holds the job, so it is what says the
job lives, what its pid is, and what ends it when the sandbox goes.  Its
output goes into a bounded buffer of its own, as a job in a sandbox of
its own does, so `logs', the overflow line and the harness's log read the
same whichever sandbox the job runs in."
  ;; What the run before this one said is history under this one: the
  ;; buffer is replaced here, and a restart -- by a call, or by the
  ;; sandbox being rebuilt -- keeps both runs in the log.
  (harness-tools-jobs--keep-output job)
  (let* ((buffer (generate-new-buffer (format " *job %s*" (plist-get job :id)) t))
         ;; The run may last only what is left of the job's own time: a
         ;; restart runs the rest of it, not another span.
         (seconds (max 1 (if (plist-get job :deadline)
                             (ceiling (- (plist-get job :deadline) (float-time)))
                           (plist-get job :seconds))))
         (run (harness-sandbox-session-start-run
               (plist-get job :ctx) (plist-get job :cwd) (plist-get job :command)
               :seconds seconds
               :id (plist-get job :id)
               :detach t
               :on-output (lambda (chunk) (harness-tools-jobs--append-output job chunk))
               :on-err (lambda (chunk) (harness-tools-jobs--append-output job chunk))
               :done (harness-tools-jobs--shared-done job)))
         (sandbox (harness-sandbox-session-sandbox (plist-get job :session))))
    (setf (plist-get job :run) run
          (plist-get job :shared) t
          (plist-get job :process) (plist-get sandbox :process)
          (plist-get job :buffer) buffer
          (plist-get job :pid) nil
          (plist-get job :state) 'running
          (plist-get job :exit) nil
          (plist-get job :reason) nil
          (plist-get job :dropped) nil
          ;; The job's log stays the one the harness keeps for it in the
          ;; session's temporary directory: the sandbox's own output file
          ;; is what the run says, and the log is what a caller reads,
          ;; bounded the same way whichever sandbox the job ran in.
          (plist-get job :started) (plist-get run :started)
          ;; A restart runs the rest of the job's own time, not another
          ;; span: the deadline it already has is the one it keeps.
          (plist-get job :deadline) (or (plist-get job :deadline)
                                        (plist-get run :deadline)))
    (harness-tools-jobs--evidence-running job)
    (harness-tools-jobs--write-log job)
    job))

(defun harness-tools-jobs--shared-done (job)
  "Return the function that records JOB's end when its shared run ends.
The reason the job was stopped for is the reason its session reads: a
run ended because the sandbox was rebuilt says that, while the job was
stopped because its directory went, so the job's own reason wins and the
run's is kept only where the job had none.

How it ended is written to the job's lifecycle record here, with the
exit the supervisor reported and whether a Harness stop request was
behind it (see `harness-tools-jobs--evidence-end').  A run whose status
says a signal ended it, and which no stop request of the harness
explains, is recorded as unexplained: what sent it is not something the
harness saw."
  (lambda (run)
    (let ((entry (ignore-errors (harness-sandbox-session-run-entry run))))
      (setf (plist-get job :state) (if (eq (harness-sandbox-session-run-state run) 'stopped)
                                       'stopped
                                     (if (eql (plist-get run :exit) 0) 'exited 'failed))
            (plist-get job :exit) (plist-get run :exit)
            (plist-get job :reason) (or (plist-get job :reason) (plist-get run :reason))
            (plist-get job :ran) (and entry (- (or (plist-get entry :elapsed) 0) 0))
            (plist-get job :log) (plist-get entry :log))
      (harness-tools-jobs--evidence-end job (plist-get job :state) (plist-get run :exit))
      (ignore-errors (harness-tools-jobs--write-log job)))))

(defun harness-tools-jobs--start (input ctx)
  "Handle the start action of `bash_job' with INPUT under CTX.
The job is built, checked and spawned here: the directory is authorised
against what the session may reach now, the confinement of that directory
is asked for, and the profile and the built command are the ones the job
runs with (see `harness-tools-jobs--prepare')."
  (let* ((sid (harness-tools-jobs--session ctx))
         (command (plist-get input :command))
         (running (length (delq nil (mapcar (lambda (e) (and (eq (plist-get e :state) 'running) t))
                                            (harness-tools-jobs-session-entries sid))))))
    (cond
     ((or (not (stringp command)) (string-blank-p command))
      (harness-tool-error "Missing command: start needs command, the shell command the job runs"))
     ((>= running harness-tools-jobs-max-per-session)
      (harness-tool-error
       (format "This session runs %s, its most: stop one with bash_job and action stop, or wait for one to end"
               (harness-tools-count-phrase running "job"))))
     (t
      (condition-case err
          (let* ((cwd (harness-tools-jobs--cwd input ctx))
                 (seconds (harness-tools-jobs--seconds input))
                 (id (format "job-%s" (harness-short-id 6)))
                 (tmp (harness-tools-shell--tmp-dir ctx))
                 (log (and tmp (expand-file-name (format "%s.log" id) tmp)))
                 (job (harness-tools-jobs--new-job
                       :id id :session sid :ctx ctx :command command :cwd cwd
                       :seconds seconds :log log)))
            (harness-tools-jobs--prepare job ctx)
            (if (harness-tools-jobs--shared-p (plist-get job :ctx) cwd)
                ;; The session's one sandbox: the job is a run in it, not a
                ;; process of its own.
                (setf (plist-get job :shared) t)
              (setf (plist-get job :profile)
                    (harness-tools-jobs--profile (plist-get job :ctx) cwd))
              (let ((confinement (harness-tools-jobs--spawn-confinement job)))
                (when confinement
                  (signal 'harness-error (list confinement)))))
            (puthash id job harness-tools-jobs--jobs)
            (puthash sid (append (gethash sid harness-tools-jobs--by-session) (list id))
                     harness-tools-jobs--by-session)
            (condition-case err
                (if (plist-get job :shared)
                    (harness-tools-jobs--start-shared job)
                  (harness-tools-jobs--spawn job))
              (error (harness-tools-jobs--forget job)
                     (signal (car err) (cdr err))))
            (let ((entry (harness-tools-jobs--entry job)))
              (harness-tool-ok
               (format "%s started · runs until %s, or until stop\n  %s\n  in %s\n  output: %s"
                       id
                       (if (> seconds 3600)
                           (format "in %s" (harness-format-duration seconds))
                         (format-time-string "%H:%M" (plist-get entry :deadline)))
                       (harness-first-line command 90)
                       (harness-abbreviate-file-name cwd)
                       (if log (harness-abbreviate-file-name log) "not kept"))
               :meta (list :job id :pid (plist-get entry :pid)))))
        ((error quit)
         (harness-tool-error (format "Cannot start the job: %s" (harness-error-message err)))))))))

(defun harness-tools-jobs--stop-action (input ctx restart)
  "Handle the stop or, with RESTART, the restart action of `bash_job'.
INPUT is the call's, CTX its context.  A restart is a spawn like a start:
the job's directory is authorised again and its confinement asked for, so
a restart after a permission change runs in the sandbox the session has
now, and a restart after a change that leaves no confined sandbox is
refused and stops the job instead of reviving it unconfined."
  (let* ((sid (harness-tools-jobs--session ctx))
         (job (harness-tools-jobs--resolve (plist-get input :id) sid))
         (id (plist-get job :id)))
    (if (not restart)
        (progn
          (harness-tools-jobs--stop job "stopped by its session" "stop")
          (harness-tool-ok
           (format "%s stopped%s; its files stay where it wrote them"
                   id
                   (if (equal (harness-tools-jobs--state job) 'stopped) "" " (it had ended)"))))
      (condition-case err
          (progn
            (harness-tools-jobs--prepare job ctx)
            (when (harness-tools-jobs--expired-p job)
              (signal 'harness-error
                      (list (format "its time is up: it may run %s in all, and that is spent"
                                    (harness-format-duration (plist-get job :seconds))))))
            (unless (plist-get job :shared)
              (setf (plist-get job :profile)
                    (harness-tools-jobs--profile (plist-get job :ctx) (plist-get job :cwd)))
              (let ((confinement (harness-tools-jobs--spawn-confinement job)))
                (when confinement
                  (signal 'harness-error (list confinement)))))
            (harness-tools-jobs--stop job "restarted by its session" "restart")
            (setf (plist-get job :restarts) (1+ (or (plist-get job :restarts) 0)))
            ;; A restart is the same command again, in the sandbox the
            ;; session has now: its own, or the one the session shares.
            (if (harness-tools-jobs--shared-p (plist-get job :ctx) (plist-get job :cwd))
                (progn (setf (plist-get job :shared) t)
                       (harness-tools-jobs--start-shared job))
              (harness-tools-jobs--spawn job))
            (harness-tool-ok (format "%s restarted with the sandbox it has now, for the rest of its %s"
                                     id (harness-format-duration (plist-get job :seconds)))
                             :meta (list :job id)))
        ((error quit)
         (harness-tools-jobs--stop job (format "its restart failed: %s" (harness-error-message err))
                                  "restart")
         (harness-tool-error (format "%s could not restart: %s" id (harness-error-message err))))))))

(defun harness-tools-jobs--bash-job (input ctx)
  "Handler of `bash_job' with INPUT under CTX."
  (let* ((value (plist-get input :action))
         (action (and (stringp value) (downcase (string-trim value))))
         (sid (harness-tools-jobs--session ctx)))
    (cond
     ((equal action "start") (harness-tools-jobs--start input ctx))
     ((equal action "stop") (harness-tools-jobs--stop-action input ctx nil))
     ((equal action "restart") (harness-tools-jobs--stop-action input ctx t))
     ((equal action "list")
      (let ((entries (harness-tools-jobs-session-entries sid)))
        (harness-tool-ok
         (if entries
             (string-join (mapcar #'harness-tools-jobs--status-line entries) "\n")
           "No jobs in this session"))))
     ((member action '("status" "logs"))
      (let* ((entries (if (plist-get input :id)
                          (list (harness-tools-jobs--entry
                                 (harness-tools-jobs--resolve (plist-get input :id) sid)))
                        (harness-tools-jobs-session-entries sid))))
        (cond
         ((null entries)
          (if (plist-get input :id)
              (harness-tool-error (format "No job %s in this session" (plist-get input :id)))
            (harness-tool-error "No jobs in this session")))
         ((equal action "status")
          (harness-tool-ok (string-join (mapcar #'harness-tools-jobs--describe entries) "\n\n")))
         (t
          (harness-tool-ok (or (harness-tools-jobs-log-text (car entries) (harness-tools-jobs--lines input))
                               "No output"))))))
     ((equal action "evidence")
      (let* ((id (and (stringp (plist-get input :id)) (string-trim (plist-get input :id))))
             (id (and id (not (string-empty-p id)) id))
             ;; A job that has ended may be gone from the session's list
             ;; and still have its lifecycle recorded, which is the point
             ;; of the record: the id is read as it is, and the session it
             ;; is read under is what decides whose it was.
             (records (harness-tools-jobs-evidence sid id)))
        (cond
         (records
          (harness-tool-ok
           (string-join (mapcar #'harness-tools-jobs--evidence-line records) "\n")
           :meta (list :job id :records (length records))))
         (id
          (let ((job (ignore-errors (harness-tools-jobs--resolve id sid))))
            (harness-tool-ok (if job
                                 (format "No lifecycle recorded for %s yet" (plist-get job :id))
                               (format "No job %s in this session" id)))))
         (t (harness-tool-ok "No job lifecycle recorded in this session")))))
     (t (harness-tool-error
         (format "bash_job needs action: start, list, status, logs, evidence, stop or restart%s"
                 (if value (format " (not %S)" value) "")))))))

(defun harness-tools-jobs--evidence-line (record)
  "Return one line saying what RECORD, an event of a job's life, was.
The line is the tool's, so it reads as what happened: when, which job,
and what the event says -- a start's run, a stop's path and reason, an
end's state, exit, signal and whether the harness asked for it."
  (let ((event (plist-get record :event))
        (at (plist-get record :at)))
    (format "%s  %s  %s%s"
            (if (numberp at) (format-time-string "%Y-%m-%d %H:%M:%S" at) "-")
            (or (plist-get record :job) "-")
            (pcase event
              ("start" (format "start · run %s · %s"
                               (or (plist-get record :run) "-")
                               (if (harness-json-true-p (plist-get record :shared))
                                   "in the session's sandbox" "in a sandbox of its own")))
              ("stop" (format "stop · %s · %s"
                              (or (plist-get record :path) "-")
                              (or (plist-get record :reason) "no reason")))
              ("end" (format "end · %s · exit %s%s · %s"
                             (or (plist-get record :state) "-")
                             (let ((exit (plist-get record :exit)))
                               (if (integerp exit) exit "?"))
                             (if-let* ((signal (plist-get record :signal)))
                                 (format " (%s)" signal) "")
                             (pcase (plist-get record :teardown)
                               ("harness-stop" (format "stopped by the harness · %s"
                                                       (or (plist-get record :path) "-")))
                               ("exit" "the command exited")
                               (_ "no recorded stop request: unexplained"))))
              (_ (format "%s" event)))
            (let ((log (plist-get record :log)))
              (if (and (equal event "end") (stringp log))
                  (format " · log %s" (harness-abbreviate-file-name log))
                "")))))

(defun harness-tools-jobs--lines (input)
  "Return how many lines of output a `bash_job' call with INPUT asks for."
  (let ((lines (plist-get input :lines)))
    (cond ((numberp lines) (truncate lines))
          ((and (stringp lines) (string-match-p "\\`[0-9]+\\'" lines)) (string-to-number lines))
          (t 100))))

;;;; Methods for the access view

(harness-defmethod sandbox/jobs (session-id)
  "Return the jobs of SESSION-ID, oldest first, as the access view draws them.
Each is (:id :state :command :cwd :started :deadline :timeout :elapsed :exit
:pid :log :reason :restarts); `:state' is running, exited, stopped or failed.
A client sees the jobs of the session its view shows, and no other's."
  (harness-tools-jobs-session-entries session-id))

(harness-defmethod sandbox/job-stop (session-id id)
  "Stop job ID of SESSION-ID, for the user; return its entry.
Signals when ID is no job of SESSION-ID's, so another session's job
cannot be stopped through it."
  (let ((job (harness-tools-jobs--resolve id session-id)))
    (harness-tools-jobs--stop job "stopped from the access view" "access-view")
    (harness-tools-jobs--entry job)))

(harness-define-tool "bash_job"
  :label "Bash job"
  :description
  (concat
   "Run a shell command as a long-lived, confined job of this session: it starts in this call, keeps running after it, and later calls reach it -- a dev server, a display, an emulator, or a game a playtest drives -- while what it writes stays in the working directory. "
   "A job runs in a sandbox of this session's own, built as a bash command's is: the directories the session may use, its temporary directory as /tmp, the network, its Linux capabilities, and a read-only or offline session's job is read-only or offline. The harness holds the process, so it is the same sandbox for every call that reaches it, and it is still a namespace of its own: a script inside it may start several processes, and all of them end with the job. "
   "Actions: start (command, and optionally cwd and timeout in seconds, at most 3600), list, status (id, or all of the session's), logs (id, lines), evidence (id, or all of the session's: how each job started, every stop the harness asked it for, and how it ended), stop (id) and restart (id, after a permission change or a crash). "
   "A job ends when its time is up, when stop names it, when its session is closed or deleted, when its task is done or cancelled or paused, and when the harness shuts down; the sandbox's own timeout ends it even when the harness does not, and nothing it left running survives it. A restart runs the rest of the job's own time, not a new span, and it is refused when the session may no longer run a job in its directory. Its output is kept in the session's temporary directory, bounded: a job that prints more than the limit loses its oldest output, and the log says so. Its lifecycle -- its run, the path each stop came by, its exit and signal -- is kept in the harness's state directory, bounded, so how a job ended outlives the job: an end with no stop request behind it reads as unexplained, since what sent a signal is not something the harness sees. "
   "A job belongs to the session that started it: no other session lists, reads or stops it. A job runs in this session's shared runtime, which the sandbox layer holds on demand, and it needs a backend that can promise a verifiable cancel and teardown; where none can -- no backend, the `off' policy, a project whose own settings say `off', a remote directory, or a backend that cannot -- a job is refused with that reason, because its processes there would not be confined or would not end with it. "
   "The network is the machine's, as it is for bash: a job that listens on a port is reachable from this machine and from any other session's commands, so two jobs cannot bind the same address and port, and an offline session's job is offline. Confinement is what a job's own processes may touch, not a private network. "
   "For one command that starts, uses and stops a second process, bash is enough: its sandbox ends with the call.")
  :schema '(:type "object"
            :properties (:action (:type "string" :enum ["start" "list" "status" "logs" "evidence" "stop" "restart"]
                                  :description "What to do: start a job, list the session's jobs, show one, read its output, read how one ended, stop it, or restart it.")
                         :command (:type "string" :description "For start: the shell command the job runs, as bash runs one.")
                         :id (:type "string" :description "The job to act on, as start and list name it.")
                         :cwd (:type "string" :description "For start: the directory to run in, relative to the working directory. Default: the working directory.")
                         :timeout (:type "integer" :description "For start: seconds the job may run, at most 3600. Default 600.")
                         :lines (:type "integer" :description "For logs: how many lines of its output to return. Default 100."))
            :required ("action"))
  :kind 'exec
  :timeout 60
  :paths (lambda (input) (list (or (plist-get input :cwd) ".")))
  :subject (lambda (input)
             (or (plist-get input :id)
                 (harness-first-line (plist-get input :command) 60)
                 (plist-get input :action)))
  :handler #'harness-tools-jobs--bash-job)

;;;; Module

(defun harness-tools-jobs--shutdown ()
  "Stop every job: the harness is shutting down, or Emacs exits."
  (when harness-tools-jobs--timer
    (cancel-timer harness-tools-jobs--timer)
    (setq harness-tools-jobs--timer nil))
  ;; The filter goes with the module, as a supervisor's does: a harness
  ;; that no longer has jobs must not claim to have stopped any.
  (harness-remove-filter 'agent/stop-outstanding #'harness-tools-jobs--stop-outstanding)
  (maphash (lambda (_id job)
             (when (harness-tools-jobs--running-p job)
               (harness-tools-jobs--stop job "the harness is shutting down" "shutdown")))
           harness-tools-jobs--jobs))

(defun harness-tools-jobs--init ()
  "Wire the jobs to the events that end or change them.  Idempotent."
  (harness-on 'session/deleted #'harness-tools-jobs--on-session-ended 80)
  (harness-on 'session/deactivated #'harness-tools-jobs--on-session-ended 80)
  (harness-on 'session/moved #'harness-tools-jobs--on-session-moved 80)
  ;; Before the sandbox module rebuilds a session's sandbox, which runs at
  ;; 80: a shared job is running then, and is known to be one to carry into
  ;; the new sandbox.  `sandbox/rebuilt' says it exists, and the job is
  ;; started again there.
  (harness-on 'access/changed #'harness-tools-jobs--on-access-changed 70)
  (harness-on 'sandbox/rebuilt #'harness-tools-jobs--on-sandbox-rebuilt 80)
  (harness-on 'permission/dir-revoked #'harness-tools-jobs--on-access-changed 80)
  (harness-on 'config/changed #'harness-tools-jobs--on-config-changed 70)
  (harness-on 'task/done #'harness-tools-jobs--on-task-done 80)
  (harness-on 'task/cancelled #'harness-tools-jobs--on-task-cancelled 80)
  ;; Pause, return to pending and pre-emption stop a session's work through
  ;; `agent/stop-outstanding', which is where a job has to stop too: a task
  ;; the user paused must not keep a server, a display or an emulator.
  (harness-add-filter 'agent/stop-outstanding #'harness-tools-jobs--stop-outstanding 60)
  (unless (timerp harness-tools-jobs--timer)
    (setq harness-tools-jobs--timer
          (run-at-time harness-tools-jobs--tick harness-tools-jobs--tick
                       #'harness-tools-jobs--tick-all)))
  (add-hook 'kill-emacs-hook #'harness-tools-jobs--shutdown))

(harness-define-module 'tools-jobs
  :doc "Long-lived confined jobs of a session (bash_job): a server, a display or a playtest that later calls reach, bounded by its timeout and stopped with its session.  A job is a run of the session's shared runtime, so it needs a backend whose adapter can promise a verifiable cancel and teardown."
  :requires '(tools-shell sandbox)
  :init #'harness-tools-jobs--init
  :shutdown #'harness-tools-jobs--shutdown)

(provide 'harness-tools-jobs)
;;; harness-tools-jobs.el ends here
