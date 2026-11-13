;;; harness-sandbox-session.el --- The confined runtime a session's calls share  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; A session's tool calls can share one confined runtime.  A file a
;; command writes is there for the next call, and so is a process it
;; leaves running: a dev server, a display, an emulator, a playtest.  That
;; is what makes consecutive calls cheap instead of one self-contained
;; script each (docs/design/tool-call-persistent-jobs.md).
;;
;; **Identity is not compute.**  A session always has a *workspace*: the
;; directories it may reach, its temporary directory, its own working
;; directory.  That identity, and the permission generation it was
;; authorised under, exists whether or not anything runs.  The *runtime* --
;; one sandbox holding one supervisor, with the session's shells and
;; servers in it -- is created by the first call that needs it and
;; destroyed when nothing of the session is left in it.  A session that is
;; idle keeps no process: what persists between its calls is its files and
;; its permission generation, and a process it left running is what keeps
;; the runtime alive, because that process *is* work.
;;
;; **Above the generic sandbox, not inside bwrap.**  This module names no
;; backend.  It asks `sandbox/hold' (`harness-sandbox.el') for a command
;; line that makes its supervisor a held instance -- one whose standard
;; input and output the harness owns -- and for what the backend that made
;; it can and cannot promise.  Each adapter answers for itself.  Every
;; call, every job and the UI use this one manager, this one
;; command/result protocol and these one lifecycle rules: start, exec,
;; status, cancel, destroy, idle.  A backend that cannot give what the
;; rules need says so in its capability facts; this module refuses to hold
;; there with that reason in its answer, and the caller falls back to a
;; sandbox per call -- the same confinement, a process that ends with its
;; call -- rather than to something unconfined, and never to a persistent
;; process outside a jail.  Nothing outside this module interprets a
;; backend's command line.
;;
;; **What is shared is the runtime, not the authority.**  The instance is
;; built from the session's effective profile and no more: its directories
;; and only those, its own temporary directory as /tmp, the skills
;; read-only, the `tools/sandbox-options' filter's options, the Linux
;; capabilities the user gave it, the network unless the session is
;; offline.  The mounts are fixed when the instance starts, so the profile
;; is its permission *generation*: every change to what the session may
;; reach -- `access/changed', `permission/dir-revoked', `config/changed'
;; for the policy, the backend, the allowed or the extra read-only
;; directories, `session/moved' -- rebuilds it, and nothing a command left
;; running keeps a directory the session gave up.  The generation is
;; computed from the session's *current* directories
;; (`harness-sandbox-session--profile-now'): they are read again and the
;; session's own working directory is authorised again each time, so a
;; session whose working directory it may now only read, or no longer has,
;; cannot keep an instance mounted writable from the older answer.  A
;; rebuild stops admitting commands, ends the old generation with
;; everything in it, verifies that it is gone, and only then builds the
;; next one; the session is told in its transcript, and the access view
;; says the same before it happens.
;;
;; **The transport cannot be steered by the sandbox.**  A command runs in
;; the sandbox and may write anything it can reach, so the harness never
;; reads a file the sandbox can name to learn what a command printed.  The
;; supervisor's standard output is the one channel, and every record on it
;; is a line the supervisor writes in one `write()' call:
;;
;;   R VERSION [MISSING…]  the instance is up, one supervisor in it
;;   S TOKEN               a command started
;;   O TOKEN BASE64        bytes of its standard output
;;   E TOKEN BASE64        bytes of its standard error
;;   X TOKEN STATUS LIVE   it ended; LIVE processes of it are still there
;;   P LIVE                processes of the instance no run owns
;;   D                     the instance is going
;;
;; The harness decodes those frames in the process buffer Emacs fills from
;; the pipe itself, so no pathname a command can change is ever followed on
;; the host: there is no out, err or status file, and no script file read
;; back.  A command's own bytes are base64, so a line cannot be forged out
;; of its output, and a frame is one `write()' below `PIPE_BUF', so it
;; stays whole in the pipe.  Control goes the other way on the
;; supervisor's standard input, which the sandbox cannot reach.
;;
;; **Cancel is not destroy.**  A run's processes inherit `HARNESS_RUN' and
;; the instance's id, so the supervisor finds every one of them by the
;; `/proc' entry it inherits -- a `setsid' child and a double-forked daemon
;; included -- and cancel sends TERM to each, waits, then KILLs what
;; ignored it, and says how many are still alive when it replies.  A run
;; is cancelled only when that count is zero; a run that cannot be
;; emptied ends its whole runtime instead, which the kernel does terminate.
;; Destroy ends the instance: the supervisor goes, the namespace with it,
;; and the harness waits for its own process to be gone before it says so.
;; An ordinary call that leaves a process running is neither: the process
;; survives, it is counted (`P'), and it keeps the runtime alive.
;;
;; **Bounds.**  One instance per session, one supervisor in it, one
;; command per run: `harness-sandbox-session-max-commands' concurrent runs
;; (a further call is refused with that reason, not queued without end),
;; each run ended by its own `timeout' in the sandbox and by the harness at
;; the same moment, its output bounded in memory
;; (`harness-sandbox-session-output-limit') and in its log
;; (`harness-sandbox-session-log-limit'), and a run whose frames stop
;; arriving bounded by `harness-sandbox-session--lease-seconds'.
;;
;; **When it goes.**  The runtime is built on demand and destroyed when
;; nothing of the session is in it -- no run in flight and no process it
;; owns -- after `harness-sandbox-session-idle-seconds' (nil: never until
;; the session ends; 0: at once, which is the default and what the demo
;; measures).  It ends at once, with everything in it, when the session is
;; deleted, deactivated or moved, when its permission generation changes,
;; when its task is done or cancelled, when the module shuts down, and at
;; Emacs's own exit.  A supervisor that dies takes its runs with it, marks
;; them failed with what it printed, and leaves no runtime behind: the next
;; call builds another.  A call that arrives while a runtime is being
;; destroyed waits for it to be gone and then builds the next generation;
;; nothing is ever submitted into an instance that is going.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-tools-shell)

(defgroup harness-sandbox-session nil
  "The confined runtime a session's calls share."
  :group 'harness)

(defcustom harness-sandbox-session-output-limit 1048576
  "Most output, in bytes, one command keeps in the harness's memory.
A command's output arrives through the supervisor's frames; this is how
much of it the harness keeps for the result of a call and the note under
it.  A command that prints more loses the front of what it printed, and
its result says so and names the log it is in, so a chatty command costs
the harness a bounded amount of memory rather than all of it."
  :type 'integer
  :group 'harness-sandbox-session)

(defcustom harness-sandbox-session-log-limit 4194304
  "Most output, in bytes, the harness keeps of one command in its log.
The harness appends each command's output to its log in the session's
temporary directory as it arrives, up to this many bytes; what comes
after is dropped and the log says at its end that it was.  The log is
written by the harness alone: a command can neither name its path nor
change what the harness reads."
  :type 'integer
  :group 'harness-sandbox-session)

(defcustom harness-sandbox-session-max-commands 8
  "Most commands one session may run in its runtime at once.
A call and the jobs of a session share it; past this, a call is refused
with that reason rather than start another or wait without end."
  :type 'integer
  :group 'harness-sandbox-session)

(defcustom harness-sandbox-session-idle-seconds 0
  "Seconds a runtime with nothing of its session in it is kept.
Idle means no run in flight and no process the runtime owns: a command's
leftover daemon keeps it alive, because that daemon is work.  One that is
idle for this long goes -- its processes with it -- rather than sit on the
machine for a session that has stopped working.  Nil keeps it until the
session ends.  The default is to end it at once: a runtime with nothing in
it is a process a session does not need, and its next call pays its start
up again (`docs/evidence/tool-call-persistent-jobs/` measures what that
costs)."
  :type '(choice integer (const :tag "Until the session ends" nil))
  :group 'harness-sandbox-session)

(defconst harness-sandbox-session--ready-seconds 15
  "Seconds a new runtime has to say that it is up.")

(defconst harness-sandbox-session--poll 0.1
  "Seconds between two looks at the commands a runtime runs.")

(defconst harness-sandbox-session--poll-answer 2.0
  "Seconds the supervisor has to answer a question about what it owns.")

(defconst harness-sandbox-session--kill-after 3
  "Seconds a cancelled command has between its TERM and its KILL.")

(defconst harness-sandbox-session--settle 5
  "Seconds a runtime has to close before the harness ends it.")

(defconst harness-sandbox-session--lease-seconds 60
  "Seconds a run's frames may stop arriving before the harness ends it.
The supervisor writes a frame for every block of output it takes and one
when a command ends, so silence for this long means the transport has
gone -- a pipe nobody reads, a process the harness lost -- and the run is
ended and reported rather than left running unobserved.")

(defconst harness-sandbox-session--frame-limit 65536
  "Most bytes of one unterminated frame the harness buffers.
Longer than any frame the supervisor writes; a line that grows past it is
cut and dropped, so a broken supervisor cannot grow the harness's memory.")

(defconst harness-sandbox-session--protocol 1
  "The version of the supervisor's frame protocol this module speaks.")

(defconst harness-sandbox-session--supervisor-program
  (mapconcat
   #'identity
   '("set +e"
     "version=$1 instance=$2 scratch=$3"
     "missing="
     "for p in timeout setsid base64 grep sed mkfifo dd tr; do"
     "  command -v \"$p\" >/dev/null 2>&1 || missing=\"$missing $p\""
     "done"
     "if [ -n \"$missing\" ]; then printf 'R %s %s\\n' \"$version\" \"$missing\"; exit 3; fi"
     "printf 'R %s\\n' \"$version\""
     "export HARNESS_INSTANCE=$instance"
     "live="
     "say() { printf '%s\\n' \"$*\"; }"
     ;; One block, one frame, one write(): `dd' returns on the first short
     ;; read, so a block is in a frame as it arrives rather than when the
     ;; stream closes, and `base64' makes it ASCII, NUL and newline
     ;; included.  A frame below PIPE_BUF written by one printf stays
     ;; whole in the pipe, whatever else is writing.
     ;; The fifo is opened once, by the descriptor this subshell reads:
     ;; a second open of a fifo whose writer has closed waits for a new
     ;; one, and `dd' on a closed fifo would never return.  Reading a
     ;; descriptor that was opened when the writer was there is a short
     ;; read at the end, which is what ends the loop.
     "draw() {"
     "  local chunk"
     "  exec 9< \"$3\""
     "  while chunk=$(dd bs=384 count=1 <&9 2>/dev/null | base64 -w0); do"
     "    [ -n \"$chunk\" ] || break"
     "    say \"$1\" \"$2\" \"$chunk\""
     "  done"
     "  exec 9<&-"
     "}"
     "pids_of() { grep -lzx \"HARNESS_RUN=$1\" /proc/[0-9]*/environ 2>/dev/null | sed -e 's|^/proc/||' -e 's|/environ$||'; }"
     "alive_of() {"
     "  local p st"
     "  for p in $(pids_of \"$1\"); do"
     "    st=$(sed -n 's/^[0-9]* (.*) \\(.\\).*/\\1/p' \"/proc/$p/stat\" 2>/dev/null)"
     "    case \"$st\" in Z|'') ;; *) printf '%s ' \"$p\" ;; esac"
     "  done"
     "}"
     "count_of() { printf '%s' \"$1\" | tr -s ' ' '\\n' | grep -c .; }"
     "untag() {"
     "  local out= t"
     "  for t in $2; do [ \"$t\" = \"$1\" ] || out=\"$out $t\"; done"
     "  printf '%s' \"$out\""
     "}"
     "start_one() {"
     "  local token=$1 secs=$2 dir=$scratch/$1"
     "  mkdir -p \"$dir\" && rm -f \"$dir/o\" \"$dir/e\" && mkfifo \"$dir/o\" \"$dir/e\" \\"
     "    || { say X \"$token\" 126 0; return 1; }"
     "  say S \"$token\""
     "  live=\"$live $token\""
     "  return 0"
     "}"
     "run_one() {"
     "  local token=$1 secs=$2 dir=$scratch/$1 op ep rp st left"
     "  draw O \"$token\" \"$dir/o\" & op=$!"
     "  draw E \"$token\" \"$dir/e\" & ep=$!"
     "  printf '%s' \"$3\" | base64 -d > \"$dir/cmd\" 2>/dev/null"
     "  HARNESS_RUN=$token timeout --signal=TERM --kill-after=3s \"${secs}s\" \\"
     "    bash \"$dir/cmd\" </dev/null >\"$dir/o\" 2>\"$dir/e\" & rp=$!"
     "  wait $rp; st=$?"
     "  wait $op $ep"
     "  rm -f \"$dir/cmd\""
     "  live=$(untag \"$token\" \"$live\")"
     "  left=$(alive_of \"$token\")"
     "  say X \"$token\" \"$st\" \"$(count_of \"$left\")\""
     "}"
     "kill_one() {"
     "  local token=$1 pids p i"
     ;; A token this instance never ran, or one it has finished, has
     ;; nothing to end: it is answered once, not retried.
     "  case \" $live \" in"
     "    *\" $token \"*) ;;"
     "    *) say K \"$token\" 0; return ;;"
     "  esac"
     "  pids=$(alive_of \"$1\")"
     "  for p in $pids; do kill -TERM -- \"-$p\" 2>/dev/null; kill -TERM \"$p\" 2>/dev/null; done"
     "  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do"
     "    sleep 0.25"
     "    pids=$(alive_of \"$1\")"
     "    [ -z \"$pids\" ] && break"
     "    for p in $pids; do kill -KILL -- \"-$p\" 2>/dev/null; kill -KILL \"$p\" 2>/dev/null; done"
     "  done"
     "  pids=$(alive_of \"$1\")"
     "  say K \"$1\" \"$(count_of \"$pids\")\""
     "}"
     "status_all() {"
     "  local n=0 f tok"
     "  for f in /proc/[0-9]*/environ; do"
     "    tok=$(tr '\\0' '\\n' < \"$f\" 2>/dev/null | sed -n 's/^HARNESS_RUN=//p' | head -1)"
     "    [ -n \"$tok\" ] || continue"
     "    case \" $live \" in *\" $tok \"*) ;; *) n=$((n+1));; esac"
     "  done"
     "  say P \"$n\""
     "}"
     "while IFS=' ' read -r op a b c; do"
     "  case \"$op\" in"
     ;; A run's directories and its `S' frame are made here, before
     ;; the next control line is read, so a `kill' that follows a `run'
     ;; names a token the instance already knows; what runs afterwards
     ;; is in the background.
     "    run) if start_one \"$a\" \"$b\"; then run_one \"$a\" \"$b\" \"$c\" & fi ;;"
     "    kill) kill_one \"$a\" & ;;"
     "    status) status_all & ;;"
     "    quit) say D; exit 0 ;;"
     "  esac"
     "done"
     "exit 0")
   "\n")
  "The program the init of a session's runtime runs.

  bash supervisor.sh VERSION INSTANCE SCRATCH

It writes the frames the module's commentary lists on standard output and
reads `run TOKEN SECONDS BASE64', `kill TOKEN', `status' and `quit' on
standard input.  Its output is a pipe the sandbox cannot reach, and it
writes no file the harness reads: what a command prints is drawn into a
frame as it arrives, one `write()' each, below `PIPE_BUF', so a frame is
whole in the pipe and cannot be forged from a command's bytes.

It needs `timeout', `setsid', `base64', `grep', `sed', `mkfifo', `dd' and
`tr'; it names in its `R' frame whichever is missing and exits, so a backend
that gives fewer tools says so rather than hang.")

(defconst harness-sandbox-session--runtime-keys
  '(:session :instance :dir :scratch :process :buffer :partial :state
    :reason :since :started :checked :idle-since :owned :asked :profile
    :cwd :generation :backend :capabilities :runs)
  "Every key a runtime's plist is given when it is made.
It is not documentation only: `harness-sandbox-session--runtime' builds
the record from it, and a test reads this module's source and holds every
key it sets to it.  The `setf' of a `plist-get' key a plist does not have
binds the variable it was given rather than the stored plist, so a key set
later but missing here would quietly be set on a local and never reach the
runtime -- which is what `:asked' did: the supervisor's count was read and
thrown away, and an idle runtime was torn down as if it held nothing.")

(defconst harness-sandbox-session--run-keys
  '(:id :token :session :command :cwd :seconds :started :deadline :state
    :exit :reason :ended :cancelled :cancelled-reason :owned :survivors
    :detached :on-output :on-err :done :stdout :stderr :tail :out-dropped
    :err-dropped :out-carry :err-carry :log :logged :log-full :script
    :reported)
  "Every key a run's plist is given when it is made, for the same reason.")

(defun harness-sandbox-session--runtime (fields)
  "Return a runtime record with FIELDS, a plist, set in it.
Every key of `harness-sandbox-session--runtime-keys' is in the result, nil
where FIELDS does not name it, so every later `setf' of the record has a
place to write."
  (let (record)
    (dolist (key harness-sandbox-session--runtime-keys)
      (setq record (plist-put record key nil)))
    (while fields
      (setq record (plist-put record (pop fields) (pop fields))))
    record))

(defun harness-sandbox-session--new-run (fields)
  "Return a run record with FIELDS, a plist, set in it.
Every key of `harness-sandbox-session--run-keys' is in the result, nil
where FIELDS does not name it."
  (let (record)
    (dolist (key harness-sandbox-session--run-keys)
      (setq record (plist-put record key nil)))
    (while fields
      (setq record (plist-put record (pop fields) (pop fields))))
    record))

(defvar harness-sandbox-session--runtimes (make-hash-table :test 'equal)
  "Session id -> its runtime, a record of `harness-sandbox-session--runtime-keys'.")

(defvar harness-sandbox-session--generation 0
  "How many runtimes this harness has built, for naming one.")

(defvar harness-sandbox-session--timer nil
  "The timer that looks at the runtimes, or nil.")

;;;; Reading a runtime

(defun harness-sandbox-session-sandbox (session-id)
  "Return the runtime of SESSION-ID, or nil."
  (and (stringp session-id) (gethash session-id harness-sandbox-session--runtimes)))

(defun harness-sandbox-session-sandboxes ()
  "Return every runtime, oldest first."
  (let (all)
    (maphash (lambda (_sid runtime) (push runtime all)) harness-sandbox-session--runtimes)
    (sort all (lambda (a b) (< (or (plist-get a :generation) 0)
                               (or (plist-get b :generation) 0))))))

(defun harness-sandbox-session-state (runtime)
  "Return RUNTIME's state: `starting', `running', `failed' or `stopped'."
  (let ((proc (plist-get runtime :process)))
    (cond ((and proc (process-live-p proc))
           (if (eq (plist-get runtime :state) 'starting) 'starting 'running))
          ((eq (plist-get runtime :state) 'stopped) 'stopped)
          ((eq (plist-get runtime :state) 'failed) 'failed)
          (t 'started))))

(defun harness-sandbox-session-live-runs (runtime)
  "Return the runs of RUNTIME that are still going."
  (let (live)
    (maphash (lambda (_token run)
               (when (eq (harness-sandbox-session-run-state run) 'running)
                 (push run live)))
             (or (plist-get runtime :runs) (make-hash-table :test 'equal)))
    (nreverse live)))

(defun harness-sandbox-session-run-state (run)
  "Return RUN's state: `running', `exited', `failed' or `stopped'."
  (or (plist-get run :state) 'running))

(defun harness-sandbox-session-run-entry (run)
  "Return what RUN shows of itself, for a caller or the access view.
It is (:id :state :command :cwd :started :deadline :timeout :elapsed
:exit :owned :reason :log): the id its caller named it by, how long it has
run and how long it may, and how many processes it left that outlive it."
  (let* ((now (float-time))
         (started (plist-get run :started))
         (state (harness-sandbox-session-run-state run)))
    (list :id (plist-get run :id)
          :state state
          :command (plist-get run :command)
          :cwd (plist-get run :cwd)
          :started started
          :deadline (plist-get run :deadline)
          :timeout (plist-get run :seconds)
          :elapsed (and started
                        (if (eq state 'running)
                            (max 0 (- now started))
                          (max 0 (- (or (plist-get run :ended) now) started))))
          :exit (plist-get run :exit)
          :owned (plist-get run :owned)
          :reason (plist-get run :reason)
          :log (plist-get run :log))))

;;;; What a runtime needs, and the permission generation it is built under

(defun harness-sandbox-session--command-limit-problem (ctx)
  "Return why CTX's session cannot run another command now, or nil."
  (let* ((runtime (harness-sandbox-session-sandbox (plist-get ctx :session-id)))
         (live (and runtime (length (harness-sandbox-session-live-runs runtime)))))
    (and live (>= live harness-sandbox-session-max-commands)
         (format "This session runs %s in its runtime, its most: wait for one to end"
                 (harness-tools-count-phrase live "command")))))

(defun harness-sandbox-session--extra-read-only ()
  "Return the global read-only directories a runtime must mount now."
  (when (boundp 'harness-sandbox-extra-read-only-dirs)
    (delete-dups (delq nil (mapcar #'expand-file-name
                                   (ignore-errors
                                     (symbol-value 'harness-sandbox-extra-read-only-dirs)))))))

(defun harness-sandbox-session--dir-entry (session-id dir)
  "Return the `permission/dirs' entry of SESSION-ID that holds DIR, or nil.
The first entry naming a directory wins, as it does for the sandbox: a
directory both granted and read-only is writable."
  (when (and (stringp session-id) (stringp dir)
             (harness-method-exists-p 'permission/dirs))
    (let ((dir (file-name-as-directory (expand-file-name dir))))
      (condition-case err
          (cl-find-if (lambda (entry)
                        (let ((root (plist-get entry :dir)))
                          (and (stringp root) (not (file-remote-p root))
                               (or (harness-path-within-p root dir)
                                   (harness-path-within-p (file-truename root)
                                                          (file-truename dir))))))
                      (harness-call 'permission/dirs session-id))
        (error (harness-log 'warn "sandbox: could not read the directories of %s: %s"
                            session-id (harness-error-message err))
               nil)))))

(defun harness-sandbox-session--writable-p (session-id dir)
  "Non-nil when SESSION-ID may write DIR now.
A harness with no permission module lets it write, as every call there
does; a directory of the session that is an `:read-only' entry is readable
only; and one that is no directory of the session at all is not writable
either -- there is nothing to mount."
  (cond
   ((not (harness-method-exists-p 'permission/dirs)) t)
   ((null (harness-sandbox-session--dir-entry session-id dir)) nil)
   (t (not (harness-json-true-p
            (plist-get (harness-sandbox-session--dir-entry session-id dir) :read-only))))))

(defun harness-sandbox-session--reachable-p (session-id dir)
  "Non-nil when SESSION-ID may reach DIR at all now."
  (or (not (harness-method-exists-p 'permission/dirs))
      (and (harness-sandbox-session--dir-entry session-id dir) t)))

(defun harness-sandbox-session--profile (ctx cwd)
  "Return the profile a runtime of CTX's session at CWD would be built from.
The global read-only directories are carried in it as `:extra-read-only':
`sandbox/wrap' mounts them itself, without the profile naming them, so a
change of that setting would leave two profiles equal and keep a mount it
took away.  Whether CWD may be written is carried too, because the sandbox
binds the working directory whether or not it is among the session's
writable ones: a directory the session may only read must not come back
writable when the profile is built again.  Every input that decides what
the runtime shows is in what is compared, so a change of any of them
rebuilds it."
  (let ((profile (harness-tools-shell-sandbox-profile ctx cwd)))
    (plist-put (plist-put profile :extra-read-only (harness-sandbox-session--extra-read-only))
               :cwd-writable (and (harness-sandbox-session--writable-p
                                   (plist-get ctx :session-id) cwd)
                                  t))))

(defun harness-sandbox-session-problem (ctx cwd)
  "Return why CTX's session cannot hold a runtime at CWD, or nil.
These are the reasons a runtime that outlives a call cannot be given at
all.  They are asked of the generic layer, not of a backend by name: no
`sandbox/hold', a directory on another host, no session or no writable
temporary directory for its log, a session that may only read, a
directory made for the one call, and a backend whose adapter says it
cannot hold an instance, or cannot hold one with the lifecycle these rules
need.  The value is a noun phrase, not a sentence: the access view shows it
beside \"Not held\", and a job's reason shows it in the transcript."
  (let* ((sid (plist-get ctx :session-id))
         (tmp (and sid (harness-tools-shell--tmp-dir ctx)))
         (profile (and sid tmp (ignore-errors (harness-tools-shell-sandbox-profile ctx cwd))))
         (options (and profile (plist-get profile :options)))
         (scratch (and profile (append (plist-get profile :scratch) (plist-get options :scratch)))))
    (cond
     ((null sid) "no session")
     ((and (stringp cwd) (file-remote-p cwd))
      (format "%s · another host" (harness-abbreviate-file-name cwd)))
     ((null (harness-method-exists-p 'sandbox/hold)) "no sandbox module")
     ((null tmp) "no session temporary directory")
     ((not (file-directory-p tmp)) "session temporary directory missing")
     ((harness-json-true-p (plist-get options :read-only)) "read-only session")
     (scratch "directory for one call")
     ((null profile)
      (format "no sandbox profile for %s" (harness-abbreviate-file-name cwd)))
     (t (plist-get (harness-sandbox-session--hold ctx cwd) :why)))))

(defun harness-sandbox-session-available-p (ctx cwd)
  "Non-nil when CTX's session can share one runtime for CWD."
  (null (harness-sandbox-session-problem ctx cwd)))

(defun harness-sandbox-session--hold-options (profile &optional dir)
  "Return the `sandbox/hold' options building a runtime from PROFILE.
They are the ones a one-shot command of the session gets from the same
profile, so what confines the runtime is what confined the call, and
whether the working directory may be written is one of them.  DIR, the
runtime's own directory, is mounted writable at its own path: it holds
the supervisor and the files of the runs, and the sandbox's `/tmp' is not
always the session's temporary directory -- a session whose temporary
directory lies in the machine's /tmp keeps the sandbox's own -- so the
runtime must be shown where it is, not where /tmp would have led."
  (let ((options (plist-get profile :options)))
    (append (harness-tools-shell--wrap-options
             (delete-dups (delq nil (cons dir (plist-get profile :writable))))
             (plist-get profile :readable)
             options nil (plist-get profile :env) (plist-get profile :tmp))
            (list :cwd-writable (and (plist-get profile :cwd-writable) t)))))

(defun harness-sandbox-session--hold (ctx cwd &optional command dir)
  "Return `sandbox/hold'\='s answer for a runtime of CTX's session at CWD.
COMMAND is what is to be held: the supervisor, when a runtime is being
built, and a stand-in when the question is only whether one could be.
It is the plist the adapter gave; when it gave no command, its `:why' says
what the backend cannot do."
  (let ((profile (harness-sandbox-session--profile ctx cwd)))
    (condition-case err
        (apply #'harness-call 'sandbox/hold
               (or (plist-get profile :cwd) cwd)
               (or command (list "bash" "-c" "true"))
               (harness-sandbox-session--hold-options profile dir))
      (error (list :why (harness-error-message err))))))

(defun harness-sandbox-session--missing-capabilities (held)
  "Return the lifecycle capabilities HELD lacks, as symbols.
The rules need an adapter that runs one command at a time and reports its
output and its end (`:exec' and `:stream'), cancels one and finds every
process of it to verify the result (`:cancel' with `:enumerate'), and ends
the whole instance and can say when it is gone (`:destroy').  A backend
without them is not promised: its reason is shown instead."
  (let ((caps (plist-get held :capabilities)))
    (cl-remove-if
     (lambda (want)
       (harness-json-true-p (plist-get caps want)))
     '(:exec :stream :cancel :enumerate :destroy))))

;;;; The files a runtime runs from

(defun harness-sandbox-session--dir (tmp)
  "Return the directory a session's runtime of TMP keeps its files in, made.
It is inside the session's temporary directory, which the sandbox shows as
its `/tmp': the directory is named there as such, because a path under the
machine's /tmp is not one the sandbox can reach -- its /tmp is the
session's directory itself."
  (let ((dir (expand-file-name "sandbox/" tmp)))
    (make-directory dir t)
    dir))

(defun harness-sandbox-session--write-supervisor (dir)
  "Write the supervisor program into DIR, and return its path.
It is written from `harness-sandbox-session--supervisor-program' every
time a runtime starts, so the program a runtime runs is the one this
module holds."
  (let ((file (expand-file-name "supervisor.sh" dir)))
    (harness-write-file-atomically file harness-sandbox-session--supervisor-program)
    (set-file-modes file #o755)
    file))

(defun harness-sandbox-session--scratch (dir)
  "Return the directory the runtime in DIR makes its runs' files in, made."
  (let ((scratch (expand-file-name "runs/" dir)))
    (make-directory scratch t)
    scratch))

(defun harness-sandbox-session--log (dir token)
  "Return the log file of the run TOKEN of the runtime in DIR."
  (let ((logs (expand-file-name "logs/" dir)))
    (make-directory logs t)
    (expand-file-name (concat token ".log") logs)))

;;;; Starting and ending

(defun harness-sandbox-session--buffer-text (runtime)
  "Return what RUNTIME's own process wrote that was no frame, its diagnostics."
  (let ((buffer (plist-get runtime :buffer)))
    (if (buffer-live-p buffer)
        (with-temp-buffer
          (insert-buffer-substring buffer)
          (string-trim (buffer-string)))
      "")))

(defun harness-sandbox-session--send (runtime line)
  "Send LINE to RUNTIME's supervisor.
A line sent while the runtime is still starting waits in the pipe until
the supervisor reads it, so a caller starts a runtime and its first
command in one step rather than waiting for a ready line."
  (let ((proc (plist-get runtime :process)))
    (unless (and proc (process-live-p proc))
      (signal 'harness-error (list "the session's runtime is not running")))
    (condition-case err
        (harness-process-send proc (concat line "\n"))
      (error (harness-log 'warn "sandbox: could not send a control line: %s"
                          (harness-error-message err))))))

(defun harness-sandbox-session--hold-command (runtime)
  "Return the command line that makes RUNTIME a held instance.
It is the supervisor, whose standard input and output are the one channel
this module speaks on; the adapter for the backend only says how it is
reached and what confines it, and it is built from the same profile a
one-shot command of the session gets."
  (list "bash" (expand-file-name "supervisor.sh" (plist-get runtime :dir))
        (number-to-string harness-sandbox-session--protocol)
        (plist-get runtime :instance)
        (plist-get runtime :scratch)))

(defun harness-sandbox-session--spawn (session-id cwd profile)
  "Start a runtime for SESSION-ID in CWD, built from PROFILE.
Return it, or signal why it cannot start, leaving nothing behind."
  (let* ((tmp (plist-get profile :tmp))
         (dir (harness-sandbox-session--dir tmp))
         (instance (format "%s-%s" (substring session-id 0 8) (harness-short-id 6)))
         (runtime (harness-sandbox-session--runtime
                   (list :session session-id :instance instance :dir dir
                         :scratch (harness-sandbox-session--scratch dir)
                         :partial "" :state 'starting
                         :since (float-time) :started (float-time)
                         :checked (float-time)
                         :profile profile :cwd (plist-get profile :cwd)
                         :generation (cl-incf harness-sandbox-session--generation)
                         :runs (make-hash-table :test 'equal))))
         (default-directory (file-name-as-directory (or (plist-get profile :cwd) cwd)))
         (ctx (list :session-id session-id :cwd (or (plist-get profile :cwd) cwd)))
         proc held)
    (harness-sandbox-session--write-supervisor dir)
    (setq held (harness-sandbox-session--hold
                ctx (or (plist-get profile :cwd) cwd)
                (harness-sandbox-session--hold-command runtime) dir))
    (unless (plist-get held :command)
      (signal 'harness-error
              (list (or (plist-get held :why) "no held instance for this backend"))))
    (setf (plist-get runtime :backend) (plist-get held :backend)
          (plist-get runtime :capabilities) (plist-get held :capabilities)
          (plist-get runtime :buffer)
          (generate-new-buffer (format " *sandbox %s*" instance) t))
    (condition-case err
        (setq proc (make-process
                    :name (format "harness-sandbox-%s" instance)
                    :command (plist-get held :command)
                    :connection-type 'pipe
                    :coding 'binary
                    :noquery t
                    :buffer (plist-get runtime :buffer)
                    :filter (harness-sandbox-session--filter runtime)
                    :sentinel (harness-sandbox-session--sentinel runtime)))
      (error (kill-buffer (plist-get runtime :buffer))
             (signal (car err) (cdr err))))
    (setf (plist-get runtime :process) proc)
    (puthash session-id runtime harness-sandbox-session--runtimes)
    (harness-sandbox-session--ensure-timer)
    runtime))

(defun harness-sandbox-session--sentinel (runtime)
  "Return the sentinel of RUNTIME.
A runtime that ends takes its runs with it -- the backend's confinement
sees to that, and for bwrap the kernel does when the namespace's init
exits -- so every run of it is marked ended, and the session gets a new
runtime at its next call."
  (lambda (proc _event)
    (unless (process-live-p proc)
      (when (eq runtime (gethash (plist-get runtime :session)
                                 harness-sandbox-session--runtimes))
        (let ((state (harness-sandbox-session-state runtime))
              (why (harness-sandbox-session--buffer-text runtime)))
          (if (eq state 'stopped)
              ;; The harness ended it, and the runs in it with it: they
              ;; stopped, they did not break.
              (harness-sandbox-session--fail-runs
               runtime (or (plist-get runtime :reason) "its runtime stopped") 'stopped)
            (setf (plist-get runtime :state) 'failed
                  (plist-get runtime :reason)
                  (format "its runtime ended: %s" (if (string-empty-p why) "no reason" why)))
            (harness-sandbox-session--fail-runs
             runtime (or (plist-get runtime :reason) "its runtime ended") 'failed)))
        (remhash (plist-get runtime :session) harness-sandbox-session--runtimes)
        (harness-log 'debug "sandbox: %s ended (%s)" (plist-get runtime :instance)
                     (process-exit-status proc))))))

(defun harness-sandbox-session--fail-runs (runtime reason &optional state)
  "Mark every running command of RUNTIME as ended, for REASON, as STATE.
STATE is `failed' -- the runtime went without being asked to -- or
`stopped', which is what the harness ending the runtime makes of the
commands in it: the job that ran is not a job that broke."
  (dolist (run (harness-sandbox-session-live-runs runtime))
    ;; The state is left to `harness-sandbox-session--end-run', which only
    ;; ends a run that still reads as running: setting it here first would
    ;; make that a no-op, and the run's own `:done' -- the job that ran in
    ;; it -- would never be told it ended.
    (setf (plist-get run :reason) reason)
    (harness-sandbox-session--end-run run (or state 'failed) (plist-get run :exit)
                                      reason)))

(defun harness-sandbox-session--stop (runtime &optional reason failure)
  "End RUNTIME, and every command in it, for REASON.  Return RUNTIME.
The runs in it are marked `stopped' -- the harness ended them -- or
`failed' when FAILURE says the runtime went of its own accord, which is
what a job reads to say whether it was ended or it broke.  The supervisor
is asked to quit, and the harness waits for its process to be gone: this
answers only when the instance is, which is what makes \"stopped\" true."
  (let ((proc (plist-get runtime :process))
        (sid (plist-get runtime :session)))
    ;; The runtime reads as ended before its process is asked to go: the
    ;; sentinel runs while this waits for it, and a runtime still marked
    ;; running would have its commands called broken rather than stopped.
    (setf (plist-get runtime :state) (if failure 'failed 'stopped)
          (plist-get runtime :reason) (or reason (plist-get runtime :reason)))
    (when (and proc (process-live-p proc))
      (harness-log 'debug "sandbox: stopping %s (%s)" (plist-get runtime :instance)
                   (or reason "no reason"))
      (ignore-errors (harness-process-send proc "quit\n"))
      (let ((deadline (+ (float-time) harness-sandbox-session--settle)))
        (while (and (process-live-p proc) (< (float-time) deadline))
          (accept-process-output nil 0.02)))
      (when (process-live-p proc)
        ;; The supervisor would not go: its own process is what the
        ;; backend's confinement hangs on, so ending it is what ends the
        ;; instance and everything in it.
        (harness-log 'warn "sandbox: %s did not close, ending it" (plist-get runtime :instance))
        (ignore-errors (delete-process proc))
        (let ((deadline (+ (float-time) harness-sandbox-session--settle)))
          (while (and (process-live-p proc) (< (float-time) deadline))
            (accept-process-output nil 0.02)))))
    (harness-sandbox-session--fail-runs runtime (or reason "its runtime stopped")
                                        (if failure 'failed 'stopped))
    (when (eq runtime (gethash sid harness-sandbox-session--runtimes))
      (remhash sid harness-sandbox-session--runtimes))
    (when (buffer-live-p (plist-get runtime :buffer))
      (kill-buffer (plist-get runtime :buffer)))
    (ignore-errors (delete-directory (plist-get runtime :scratch) t))
    runtime))

(defun harness-sandbox-session-stop-session (session-id &optional reason)
  "End the runtime of SESSION-ID, and everything in it, for REASON."
  (when-let* ((runtime (harness-sandbox-session-sandbox session-id)))
    (harness-sandbox-session--stop runtime reason)))

(defun harness-sandbox-session-ensure (ctx cwd)
  "Return CTX's session's runtime for CWD, starting it if there is none.
Signal why the session can have none (see
`harness-sandbox-session-problem'), so a caller can fall back rather than
guess.  A runtime that is being destroyed is waited for, so nothing is
submitted into an instance that is going: this is the one admission point,
and it is serial with teardown."
  (let* ((sid (plist-get ctx :session-id))
         (session-cwd (or (plist-get ctx :cwd) cwd))
         (runtime (harness-sandbox-session-sandbox sid)))
    (cond
     ((and runtime (memq (harness-sandbox-session-state runtime) '(running starting)))
      runtime)
     (t
      (when runtime (harness-sandbox-session--stop runtime "it had ended"))
      (let ((problem (harness-sandbox-session-problem ctx session-cwd)))
        (when problem (signal 'harness-error (list problem)))
        (harness-sandbox-session--spawn
         sid session-cwd (harness-sandbox-session--profile ctx session-cwd)))))))

;;;; The frames

(defun harness-sandbox-session--filter (runtime)
  "Return the process filter of RUNTIME.
It cuts the process output into frames and hands each to
`harness-sandbox-session--frame'; nothing of what a command prints is
believed until it is a frame of this protocol."
  (lambda (_proc chunk)
    (when (and (stringp chunk) (not (string-empty-p chunk)))
      (let ((text (concat (or (plist-get runtime :partial) "") chunk)))
        (setf (plist-get runtime :checked) (float-time))
        (while (let ((newline (string-search "\n" text)))
                 (when newline
                   (let ((line (substring text 0 newline)))
                     (setq text (substring text (1+ newline)))
                     (unless (string-empty-p (string-trim-right line "\r"))
                       (harness-sandbox-session--frame runtime (string-trim-right line "\r"))))
                   t)))
        (when (> (length text) harness-sandbox-session--frame-limit)
          (setq text ""))
        (setf (plist-get runtime :partial) text)))))

(defun harness-sandbox-session--frame (runtime line)
  "Take LINE, one frame of RUNTIME's supervisor, and act on it."
  (let* ((parts (split-string line " " t))
         (kind (car parts))
         (token (nth 1 parts)))
    (pcase kind
      ("R" (harness-sandbox-session--ready runtime parts))
      ("S" (when-let* ((run (harness-sandbox-session--run runtime token)))
             (setf (plist-get run :started) (or (plist-get run :started) (float-time))
                   (plist-get runtime :state) 'running)))
      ("O" (harness-sandbox-session--output runtime token (nth 2 parts) :stdout))
      ("E" (harness-sandbox-session--output runtime token (nth 2 parts) :stderr))
      ("X" (harness-sandbox-session--ended runtime token (nth 2 parts) (nth 3 parts)))
      ("P" (setf (plist-get runtime :owned) (string-to-number (or token "0"))
                 (plist-get runtime :asked) (float-time)
                 (plist-get runtime :state) 'running))
      ("D" (setf (plist-get runtime :state) 'stopped))
      ((or "S" "") nil)
      (_
       ;; A line that is no frame is the supervisor's own diagnostics, or
       ;; a command's raw bytes that escaped its pipes.  It is logged,
       ;; never shown as output.
       (harness-log 'debug "sandbox: %s said %S" (plist-get runtime :instance)
                    (truncate-string-to-width line 200))))))

(defun harness-sandbox-session--ready (runtime parts)
  "Record that RUNTIME's supervisor said it is up, from PARTS.
When it names programs it lacks, the runtime is not one this module can
use: its runs are failed with that reason and it is ended."
  (let ((missing (cdr (cdr parts))))
    (setf (plist-get runtime :state) 'running)
    (if missing
        (let ((why (format "the sandbox lacks %s" (string-join missing ", "))))
          (harness-sandbox-session--fail-runs runtime why 'failed)
          (setf (plist-get runtime :reason) why))
      (harness-log 'debug "sandbox: %s ready (%s)" (plist-get runtime :instance)
                   (plist-get runtime :backend)))
  ;; The supervisor said it is up; the harness may ask what it holds.
  (ignore-errors (harness-sandbox-session--send runtime "status"))))

(defun harness-sandbox-session--run (runtime token)
  "Return the run of RUNTIME named TOKEN, or nil."
  (and token (gethash token (plist-get runtime :runs))))

(defun harness-sandbox-session--utf8 (bytes carry)
  "Decode BYTES, unibyte, after CARRY; return (TEXT . NEW-CARRY).
A multi-byte sequence cut between two frames is held back whole, so a
caller reads text and never half a character."
  (let* ((data (concat (or carry "") bytes))
         (length (length data))
         (cut length)
         (back 0)
         lead need)
    (while (and (< back 3) (>= (- length back) 1)
                (let ((byte (aref data (- length back 1))))
                  (setq lead byte)
                  (and (>= byte #x80) (or (< byte #xC0) (>= byte #xF8)))))
      (setq back (1+ back)))
    (when (and (>= back 1) (< back 4))
      (setq lead (aref data (- length back)))
      (setq need (cond ((< lead #xE0) 2) ((< lead #xF0) 3) ((< lead #xF8) 4) (t 1)))
      (when (and need (> need back))
        (setq cut (- length back))))
    (cons (decode-coding-string (substring data 0 cut) 'utf-8)
          (substring data cut))))

(defun harness-sandbox-session--output (runtime token base64 stream)
  "Take the bytes BASE64 of STREAM, of the run TOKEN in RUNTIME.
They are kept in memory within the output limit, put in the run's log
within the log limit, and given to the caller's function as text."
  (when-let* ((run (harness-sandbox-session--run runtime token)))
    (let* ((bytes (condition-case nil
                      (base64-decode-string (or base64 ""))
                    (error nil)))
           (key (if (eq stream :stdout) :out-carry :err-carry))
           (decoded (harness-sandbox-session--utf8 bytes (plist-get run key)))
           (text (car decoded)))
      (setf (plist-get run key) (cdr decoded)
            (plist-get run :chunks) (plist-get run :chunks))
      (when (not (string-empty-p text))
        (harness-sandbox-session--keep run stream text)
        (harness-sandbox-session--append-log run text)
        (if (eq stream :stdout)
            (when (plist-get run :on-output)
              (ignore-errors (funcall (plist-get run :on-output) text)))
          (when (plist-get run :on-err)
            (ignore-errors (funcall (plist-get run :on-err) text))))))))

(defun harness-sandbox-session--keep (run stream text)
  "Keep TEXT of STREAM in RUN, bounded by the output limit."
  (let* ((key (if (eq stream :stdout) :stdout :stderr))
         (limit harness-sandbox-session-output-limit)
         (kept (concat (or (plist-get run key) "") text)))
    (when (> (length kept) limit)
      (let ((drop (- (length kept) limit)))
        (plist-put run (if (eq stream :stdout) :out-dropped :err-dropped)
                   (+ (or (plist-get run (if (eq stream :stdout) :out-dropped :err-dropped)) 0)
                      drop))
        (setq kept (substring kept drop))))
    (setf (plist-get run key) kept)
    (let ((tail (concat (or (plist-get run :tail) "") text)))
      (setf (plist-get run :tail)
            (if (> (length tail) 4000) (substring tail (- (length tail) 4000)) tail)))))

(defun harness-sandbox-session--append-log (run text)
  "Append TEXT to RUN's log, up to the log limit, and say when it is full."
  (when-let* ((log (plist-get run :log)))
    (let* ((limit harness-sandbox-session-log-limit)
           (written (or (plist-get run :logged) 0))
           (room (and log (- limit written))))
      (when (and room (> room 0) (not (string-empty-p text)))
        (let* ((bytes (encode-coding-string text 'utf-8-unix))
               (part (if (> (length bytes) room) (substring bytes 0 room) bytes))
               (whole (< (length bytes) (length part))))
          (ignore whole)
          (condition-case nil
              (write-region part nil log t 'no-message)
            (error nil))
          (setf (plist-get run :logged) (+ written (length part)))
          (when (and (>= (plist-get run :logged) limit)
                     (not (plist-get run :log-full)))
            (setf (plist-get run :log-full) t)
            (condition-case nil
                (write-region (format "\n[... log stopped after %s ]\n"
                                      (harness-format-bytes limit))
                              nil log t 'no-message)
              (error nil))))))))

(defun harness-sandbox-session--ended (runtime token status live)
  "Record that run TOKEN of RUNTIME ended with STATUS, LIVE processes left."
  (when-let* ((run (harness-sandbox-session--run runtime token)))
    (let* ((code (string-to-number (or status "0")))
           (survivors (string-to-number (or live "0")))
           (wanted (plist-get run :cancelled))
           (state (cond ((or wanted (memq code '(124 137))) 'stopped)
                        ((eql code 0) 'exited)
                        (t 'failed))))
      ;; What the supervisor reports is recorded even when the harness
      ;; has already ended the run itself: the deadline kill and the
      ;; report race, and the report is the only thing that says how the
      ;; command really exited and how many processes it left.  The state
      ;; is not overridden -- `--end-run' has said why the run ended, and
      ;; its `:done' has already run -- but the rest of the answer is the
      ;; supervisor's to give.
      (setf (plist-get run :owned) survivors
            (plist-get run :survivors) survivors
            (plist-get run :exit) code
            (plist-get run :reported) (float-time))
      (unless (plist-get run :reason)
        (setf (plist-get run :reason)
              (cond ((memq code '(124 137))
                     (format "it reached its timeout of %s"
                             (harness-format-duration (plist-get run :seconds))))
                    (wanted (plist-get run :cancelled-reason)))))
      ;; What the instance held before this run ended is no answer to what
      ;; it holds now: the run may have left processes behind, and only a
      ;; new count can say.  The run's own survivors are a lower bound, and
      ;; a zero is what says the instance may be idle.
      (setf (plist-get runtime :owned) (and (> survivors 0) survivors)
            (plist-get runtime :asked) (and (> survivors 0) (float-time)))
      (harness-sandbox-session--end-run
       run state code
       (cond ((memq code '(124 137))
              (format "it reached its timeout of %s"
                      (harness-format-duration (plist-get run :seconds))))
             (wanted (plist-get run :cancelled-reason))))
      ;; A run the session ended must be gone: a process of it that would
      ;; not stop is a process nothing can stop in this instance, so the
      ;; instance is ended -- which the backend's confinement does
      ;; terminate -- rather than left holding it.
      (when (and (memq state '(stopped)) (> survivors 0) wanted)
        (harness-sandbox-session--stop
         runtime (format "%s processes of an ended command would not stop" survivors)
         t)))))

(defun harness-sandbox-session--end-run (run state exit &optional reason)
  "End RUN as STATE with EXIT, for REASON, and tell whoever waits."
  (when (eq (harness-sandbox-session-run-state run) 'running)
    (setf (plist-get run :state) state
          (plist-get run :exit) exit
          (plist-get run :reason) (or reason (plist-get run :reason))
          (plist-get run :ended) (float-time))
    (when-let* ((done (prog1 (plist-get run :done) (setf (plist-get run :done) nil))))
      (ignore-errors (funcall done run))))
  run)

(defun harness-sandbox-session--poll-run (run)
  "Look at RUN once: end it when it has run past its deadline.
The supervisor's own `timeout' ends the command at the same moment and
reports it; this is what ends a run whose supervisor stopped answering."
  (when (and (eq (harness-sandbox-session-run-state run) 'running)
             (plist-get run :deadline)
             (>= (float-time) (plist-get run :deadline)))
    (harness-sandbox-session-kill-run run "it reached its timeout")))

(defun harness-sandbox-session--poll ()
  "Look at every runtime: its runs' deadlines, and whether it is idle.
A runtime's supervisor is asked how many processes it owns once no run is
in flight, and one that owns nothing and has nothing running is destroyed
once `harness-sandbox-session-idle-seconds' is up."
  (let ((any nil))
    (dolist (runtime (harness-sandbox-session-sandboxes))
      (when (harness-sandbox-session--poll-runtime runtime)
        (setq any t)))
    (unless any
      (when harness-sandbox-session--timer
        (cancel-timer harness-sandbox-session--timer)
        (setq harness-sandbox-session--timer nil)))))

(defun harness-sandbox-session--poll-runtime (runtime)
  "Look at RUNTIME once; return non-nil when it must be looked at again."
  (let* ((live (harness-sandbox-session-live-runs runtime))
         (state (harness-sandbox-session-state runtime))
         (now (float-time))
         (keep nil))
    (cond
     ((not (eq state 'running))
      (when (eq state 'starting)
        (if (> (- now (or (plist-get runtime :started) now))
               harness-sandbox-session--ready-seconds)
            (progn
              (harness-log 'warn "sandbox: %s never said it was up" (plist-get runtime :instance))
              (harness-sandbox-session--stop runtime "its runtime did not start" t))
          (setq keep t))))
     ((and live (> (- now (or (plist-get runtime :checked) now))
                   harness-sandbox-session--lease-seconds))
      ;; The transport has gone: the run's frames stopped arriving and
      ;; nothing reads its pipe.  It is ended and reported rather than
      ;; left running unobserved.
      (harness-log 'warn "sandbox: %s stopped reporting; ending its %s"
                   (plist-get runtime :instance)
                   (harness-tools-count-phrase (length live) "command"))
      (harness-sandbox-session--fail-runs
       runtime "its output stopped reaching the harness" 'failed)
      (harness-sandbox-session--stop runtime "its output stopped reaching the harness" t)
      (setq keep nil))
     (live
      (dolist (run live)
        (condition-case err
            (harness-sandbox-session--poll-run run)
          (error (harness-log 'warn "sandbox: looking at a command: %s"
                              (harness-error-message err)))))
      (setq keep t))
     (t
      ;; No run in flight: ask how much of the session is still in there.  The
      ;; answer comes back as a `P' frame, so the decision waits for one: a
      ;; runtime is not idle because nobody asked yet.
      (let ((owned (plist-get runtime :owned))
            (asked (plist-get runtime :asked)))
        (cond
         ;; The answer is older than the question, or there is none yet:
         ;; ask again, and decide nothing until the supervisor says.  A
         ;; runtime is not idle because nobody has counted what it holds.
         ((not (and (integerp owned) asked (<= (- now asked) harness-sandbox-session--poll-answer)))
          (setf (plist-get runtime :asked) now
                (plist-get runtime :owned) nil)
          (ignore-errors (harness-sandbox-session--send runtime "status"))
          (setq keep t))
         ;; A process the session left running is work: the runtime stays,
         ;; and its idle clock starts again when that process goes.
         ((> owned 0)
          (setf (plist-get runtime :idle-since) nil)
          (setq keep t))
         (t
          (setf (plist-get runtime :idle-since) (or (plist-get runtime :idle-since) now))
          (let ((idle harness-sandbox-session-idle-seconds))
            (cond
             ((null idle) (setq keep t))
             ((>= (- now (plist-get runtime :idle-since)) idle)
              (harness-log 'debug "sandbox: %s has nothing in it; ending it"
                           (plist-get runtime :instance))
              (harness-sandbox-session--stop runtime "nothing of the session was left in it")
              (setq keep nil))
             (t (setq keep t)))))))))
    keep))

(defun harness-sandbox-session--ensure-timer ()
  "Start looking at the runtimes, unless that is under way."
  (unless (timerp harness-sandbox-session--timer)
    (setq harness-sandbox-session--timer
          (run-at-time harness-sandbox-session--poll harness-sandbox-session--poll
                       #'harness-sandbox-session--poll))))

(defun harness-sandbox-session-kill-run (run &optional reason)
  "Cancel RUN's command, and every process of it, for REASON.
The supervisor is asked to end it: TERM to each process carrying the run's
token, then KILL to what ignored it, and it reports what is still alive.
The run is `stopped' only when nothing of it is left; a process that
would not stop ends the whole runtime instead, which the backend's
confinement does terminate."
  (when (eq (harness-sandbox-session-run-state run) 'running)
    (let ((runtime (harness-sandbox-session-sandbox (plist-get run :session))))
      (setf (plist-get run :cancelled) t
            (plist-get run :cancelled-reason)
            (or reason
                (format "it reached its timeout of %s"
                        (harness-format-duration (plist-get run :seconds)))))
      (when runtime
        (when (eq (harness-sandbox-session-state runtime) 'running)
          (ignore-errors
            (harness-sandbox-session--send runtime (format "kill %s" (plist-get run :token)))))
        ;; The supervisor's kill loop is bounded; if its report never
        ;; comes, the run is ended here and its runtime goes with it.
        (run-at-time (+ harness-sandbox-session--kill-after 4) nil
                     (lambda ()
                       (when (eq (harness-sandbox-session-run-state run) 'running)
                         (harness-sandbox-session--end-run
                          run 'stopped nil (plist-get run :cancelled-reason))
                         (when-let* ((runtime (harness-sandbox-session-sandbox
                                               (plist-get run :session))))
                           (harness-sandbox-session--stop
                            runtime "an ended command did not report" t)))))))
    run))

(cl-defun harness-sandbox-session-start-run (ctx cwd command &key seconds on-output on-err id done (detach nil))
  "Start COMMAND in CTX's session's runtime, running in CWD.
SECONDS is how long it may run.  ON-OUTPUT, when given, is called with
each chunk of its standard output as it arrives, and ON-ERR with each
chunk of its standard error.  ID is the name its caller knows it by, and
DONE is called with the run when it ends.  With DETACH the run keeps going
after the call that started it, as a job does; without it, its caller
waits for it (see `harness-sandbox-session-wait').  Return the run; signal
why it cannot start."
  (when-let* ((problem (harness-sandbox-session--command-limit-problem ctx)))
    (signal 'harness-error (list problem)))
  (let* ((runtime (harness-sandbox-session-ensure ctx cwd))
         (token (format "r%s" (harness-short-id 10)))
         (run (harness-sandbox-session--new-run
               (list :id (or id token) :token token
                     :session (plist-get ctx :session-id)
                     :command command :cwd cwd :seconds seconds
                     :started (float-time) :deadline (+ (float-time) seconds)
                     :state 'running :detached detach :on-output on-output
                     :on-err on-err :done done :stdout "" :stderr "" :tail ""
                     :out-dropped 0 :err-dropped 0
                     :log (harness-sandbox-session--log (plist-get runtime :dir) token)
                     :logged 0
                     :script (harness-sandbox-session--script cwd command)))))
    (setf (plist-get runtime :idle-since) nil)
    (puthash token run (plist-get runtime :runs))
    ;; The runs of a session that has ended are not kept for ever.
    (when (> (hash-table-count (plist-get runtime :runs)) 200)
      (let (oldest)
        (maphash (lambda (_token candidate)
                   (when (and (not (eq (harness-sandbox-session-run-state candidate) 'running))
                              (or (null oldest)
                                  (< (or (plist-get candidate :ended) 0)
                                     (or (plist-get oldest :ended) 0))))
                     (setq oldest candidate)))
                 (plist-get runtime :runs))
        (when oldest
          (remhash (plist-get oldest :token) (plist-get runtime :runs))
          (ignore-errors (delete-file (plist-get oldest :log))))))
    (harness-sandbox-session--send
     runtime (format "run %s %d %s" token (max 1 seconds)
                     (base64-encode-string
                      (encode-coding-string (plist-get run :script) 'utf-8-unix) t)))
    (harness-sandbox-session--ensure-timer)
    run))

(defun harness-sandbox-session--script (cwd command)
  "Return the script that runs COMMAND in CWD inside the sandbox.
A directory the sandbox does not show fails with that, rather than the
command running somewhere else."
  (concat (format "cd -- %s 2>/dev/null || { printf '%%s\\n' %s >&2; exit 1; }\n"
                  (harness-sandbox-session--quote cwd)
                  (harness-sandbox-session--quote
                   (format "No such directory in the sandbox: %s" cwd)))
          command
          (unless (string-suffix-p "\n" command) "\n")))

(defun harness-sandbox-session--quote (text)
  "Return TEXT quoted for the shell, in single quotes."
  (concat "'" (replace-regexp-in-string "'" "'\\\\''" text t t) "'"))

(defun harness-sandbox-session-wait (run &optional deadline)
  "Return a promise of RUN's result, or reject when it cannot be had.
The promise settles when the run ends, and a caller's own timeout bounds
it (see `harness-tools-shell--bash'): at DEADLINE the run is cancelled,
which ends its processes and answers only when they are gone."
  (harness-with-promise (resolve reject)
    (ignore reject)
    (if (not (eq (harness-sandbox-session-run-state run) 'running))
        (funcall resolve (harness-sandbox-session-run-result run))
      (setf (plist-get run :done)
            (lambda (done)
              (funcall resolve (harness-sandbox-session-run-result done))))
      (when deadline
        (run-at-time (max 0 (- deadline (float-time))) nil
                     (lambda ()
                       (when (eq (harness-sandbox-session-run-state run) 'running)
                         (harness-sandbox-session-kill-run run "it reached its timeout"))))))))

(defun harness-sandbox-session--with-drop-marker (text dropped)
  "Return TEXT with a line saying DROPPED bytes of its front went."
  (if (or (null dropped) (<= dropped 0))
      text
    (concat (format "[... %s of earlier output dropped]\n" (harness-format-bytes dropped))
            text)))

(defun harness-sandbox-session-run-result (run)
  "Return what RUN gave, shaped as `harness-run-command' gives its result.
That is (:exit :stdout :stderr), with `timeout' for the exit of a command
the harness ended at its time, `:dropped' for the bytes of the front of
its output memory could not keep, `:state', `:reason', `:owned' and the
`:log' file its whole output is in."
  (let* ((state (harness-sandbox-session-run-state run))
         (out-dropped (plist-get run :out-dropped))
         (err-dropped (plist-get run :err-dropped)))
    (list :exit (if (eq state 'stopped) 'timeout (plist-get run :exit))
          :stdout (harness-sandbox-session--with-drop-marker
                   (or (plist-get run :stdout) "") out-dropped)
          :stderr (harness-sandbox-session--with-drop-marker
                   (or (plist-get run :stderr) "") err-dropped)
          :state state
          :reason (plist-get run :reason)
          :owned (plist-get run :owned)
          :dropped (+ (or out-dropped 0) (or err-dropped 0))
          :log (plist-get run :log))))

(defun harness-sandbox-session-run-tail (run)
  "Return the last of what RUN has printed, for the note under a call."
  (plist-get run :tail))

;;;; The permission generation the runtime was built under

(defun harness-sandbox-session--hint (session-id stopped reason)
  "Tell SESSION-ID that its runtime restarted, and STOPPED processes stopped.
REASON says why.  Nothing is said where the harness keeps no transcript:
a harness without one says nothing rather than fail."
  (when (and (stringp session-id) (harness-method-exists-p 'session/hint))
    (let ((text (concat "Sandbox restarted · " reason
                        (and (> (or stopped 0) 0)
                             (format " · %s stopped"
                                     (harness-tools-count-phrase stopped "process"))))))
      (condition-case err
          (harness-call 'session/hint session-id text)
        (error (harness-log 'warn "sandbox: could not note the restart in %s: %s"
                            session-id (harness-error-message err)))))))

(defun harness-sandbox-session--profile-now (runtime)
  "Return (:profile PROFILE) for RUNTIME as it would be built now, or (:error WHY).
WHY is that its session is gone, that the session's working directory is
no longer one it may reach at all, or that the session may no longer have
a runtime there.  The directories are read again, and the working
directory is authorised again, so a revoked or downgraded directory cannot
keep the mounts the runtime was built with."
  (let* ((sid (plist-get runtime :session))
         (record (and (harness-method-exists-p 'session/get)
                      (harness-method-exists-p 'session/exists-p)
                      (ignore-errors (harness-call 'session/exists-p sid))
                      (ignore-errors (harness-call 'session/get sid))))
         (cwd (or (and record (plist-get record :cwd)) (plist-get runtime :cwd)))
         (ctx (list :session-id sid :cwd cwd :host (and record (plist-get record :host)))))
    (cond
     ((null record) (list :error "its session is gone"))
     ((not (harness-sandbox-session--reachable-p sid cwd))
      (list :error (format "it may no longer reach %s" (harness-abbreviate-file-name cwd))))
     (t
      (let ((problem (harness-sandbox-session-problem ctx cwd)))
        (if problem
            (list :error problem)
          (list :profile (harness-sandbox-session--profile ctx cwd))))))))

(defun harness-sandbox-session-rebuild (session-id &optional why)
  "Rebuild SESSION-ID's runtime if what it may reach changed; return it.
A profile that differs from the one the runtime was built with ends it --
with every process in it -- and builds a new one, and the session is told
so in its transcript.  A change that leaves no possible runtime ends it
too, with the reason.  Nothing happens when the profile is the same, so a
runtime with nothing running is not built again for no reason: the next
call builds it.  WHY names the change, for the note and the log.

Once it has been rebuilt, or ended for want of one, `sandbox/rebuilt' is
emitted for the session: what the runtime holds -- the jobs that ran in
it -- restarts there, after it exists rather than while it does not."
  (when-let* ((runtime (harness-sandbox-session-sandbox session-id)))
    (let* ((now (harness-sandbox-session--profile-now runtime))
           (problem (plist-get now :error))
           (profile (plist-get now :profile))
           (running (length (harness-sandbox-session-live-runs runtime)))
           (changed nil))
      (cond
       (problem
        (setq changed t)
        (harness-log 'warn "sandbox: %s cannot be rebuilt: %s" session-id problem)
        (harness-sandbox-session--stop runtime (format "its runtime ended: %s" problem))
        (harness-sandbox-session--hint session-id running
                                        (format "%s · its runtime cannot be rebuilt"
                                                (or why "what it may reach changed"))))
       ((equal (plist-get runtime :profile) profile) nil)
       (t
        (setq changed t)
        (harness-log 'warn "sandbox: %s restarted, what its session may reach changed (%s)"
                     session-id (or why "a permission change"))
        (harness-sandbox-session--stop runtime "its runtime was rebuilt")
        (harness-sandbox-session--hint
         session-id running (or why "what the session may reach changed"))))
      (when changed
        (harness-emit 'sandbox/rebuilt session-id nil why))
      nil)))

(harness-declare-event 'sandbox/rebuilt
                       "(SESSION-ID RUNTIME WHY) after the runtime of SESSION-ID was ended because what the session may reach changed.  RUNTIME is nil: the next call of the session builds the next generation, with nothing of the old one in it.  WHY names what changed.  What ran in the old one ended with it, and a job that ran there is started again in the new one.")

(defun harness-sandbox-session-rebuild-all (&optional why)
  "Rebuild every runtime, for WHY."
  (dolist (runtime (harness-sandbox-session-sandboxes))
    (ignore-errors (harness-sandbox-session-rebuild (plist-get runtime :session) why))))

;;;; Events

(defun harness-sandbox-session--on-access-changed (session-id &rest _)
  "Rebuild SESSION-ID's runtime after what it may reach changed."
  (harness-sandbox-session-rebuild session-id "what the session may reach changed"))

(defun harness-sandbox-session--on-session-ended (session-id &rest _)
  "End SESSION-ID's runtime, which is deleted or closed."
  (harness-sandbox-session-stop-session session-id "its session ended"))

(defun harness-sandbox-session--on-session-moved (session-id _old new)
  "End SESSION-ID's runtime, which moved to NEW.
Its mounts are the old directory's, and a runtime is not what a session
works in any more."
  (harness-sandbox-session-stop-session
   session-id (format "its session moved to %s" (harness-abbreviate-file-name new))))

(defun harness-sandbox-session--on-task-done (task &rest _)
  "End the runtime of TASK's session, whose work is done."
  (when-let* ((sid (plist-get task :session)))
    (harness-sandbox-session-stop-session sid "its task is done")))

(defun harness-sandbox-session--on-task-cancelled (task &rest _)
  "End the runtime of TASK's session, whose work the user cancelled."
  (when-let* ((sid (plist-get task :session)))
    (harness-sandbox-session-stop-session sid "its task was cancelled")))

(defun harness-sandbox-session--on-config-changed (key &rest _)
  "Rebuild every runtime when KEY changes what a runtime shows or gives."
  (when (memq key '(harness-sandbox-policy harness-sandbox-backend
                    harness-allowed-directories harness-sandbox-extra-read-only-dirs
                    harness-sandbox-session-log-limit))
    (harness-sandbox-session-rebuild-all (format "%s changed" key))))

;;;; The method the rest of the harness asks

(harness-defmethod sandbox/session (session-id)
  "Return the shared runtime of SESSION-ID, as the access view and tools see it.
It is (:available BOOL :problem TEXT :state STATE :generation N :backend B
:since TIME :processes N :owned N :cwd PATH), or (:available nil
:problem TEXT) where the session can have none: `:state' is `starting',
`running', `failed' or `stopped', `:processes' how many commands run in it
now, `:owned' how many processes of the session it holds that no command
of this harness started, and `:since' when it started.  Nil without a
session id.  A session with no runtime is still one that *can* hold one:
`:available' says so and `:state' is nil, because a runtime is built on
demand and a session that is not working holds none."
  (when (stringp session-id)
    (let ((runtime (harness-sandbox-session-sandbox session-id))
          (record (and (harness-method-exists-p 'session/get)
                       (ignore-errors (harness-call 'session/get session-id)))))
      (cond
       (runtime
        (list :available t
              :state (harness-sandbox-session-state runtime)
              :generation (plist-get runtime :generation)
              :backend (plist-get runtime :backend)
              :capabilities (plist-get runtime :capabilities)
              :since (plist-get runtime :started)
              :processes (length (harness-sandbox-session-live-runs runtime))
              :owned (plist-get runtime :owned)
              :cwd (plist-get runtime :cwd)
              :idle-seconds harness-sandbox-session-idle-seconds
              :log-limit harness-sandbox-session-log-limit
              :output-limit harness-sandbox-session-output-limit))
       (t
        (let ((problem (and record
                            (harness-sandbox-session-problem
                             (list :session-id session-id :cwd (plist-get record :cwd))
                             (plist-get record :cwd)))))
          (list :available (and problem nil)
                :problem (or problem "no runtime until a command needs one")
                :state nil
                :idle-seconds harness-sandbox-session-idle-seconds)))))))

;;;; Module

(defun harness-sandbox-session--shutdown ()
  "End every runtime: the harness is shutting down, or Emacs exits."
  (when harness-sandbox-session--timer
    (cancel-timer harness-sandbox-session--timer)
    (setq harness-sandbox-session--timer nil))
  (dolist (runtime (harness-sandbox-session-sandboxes))
    (harness-sandbox-session--stop runtime "the harness is shutting down")))

(defun harness-sandbox-session--init ()
  "Wire the runtimes to the events that end or change them.  Idempotent."
  (harness-on 'session/deleted #'harness-sandbox-session--on-session-ended 80)
  (harness-on 'session/deactivated #'harness-sandbox-session--on-session-ended 80)
  (harness-on 'session/moved #'harness-sandbox-session--on-session-moved 80)
  (harness-on 'access/changed #'harness-sandbox-session--on-access-changed 80)
  (harness-on 'permission/dir-revoked #'harness-sandbox-session--on-access-changed 80)
  (harness-on 'config/changed #'harness-sandbox-session--on-config-changed 80)
  (harness-on 'task/done #'harness-sandbox-session--on-task-done 80)
  (harness-on 'task/cancelled #'harness-sandbox-session--on-task-cancelled 80)
  (add-hook 'kill-emacs-hook #'harness-sandbox-session--shutdown))

(harness-define-module 'sandbox-session
  :doc "The confined runtime a session's calls share, held on demand: a bash call and a bash_job run in the same mounts, so files and processes persist across calls while the runtime lasts; nothing of the session in it and it goes, and a permission change ends it and stops what it ran."
  :requires '(sandbox tools-shell)
  :init #'harness-sandbox-session--init
  :shutdown #'harness-sandbox-session--shutdown)

(provide 'harness-sandbox-session)
;;; harness-sandbox-session.el ends here
