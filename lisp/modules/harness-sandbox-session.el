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
;;   V WAY                 how it finds a run's processes: `proc', `ps'
;;                         or `group'
;;   S TOKEN               a command started
;;   O TOKEN BASE64        bytes of its standard output
;;   E TOKEN BASE64        bytes of its standard error
;;   X TOKEN STATUS LIVE   it ended; LIVE processes of it are still there
;;   P LIVE SEQ            processes of the instance no run owns; SEQ is
;;                         the number of the question it answers
;;   D                     the instance is going
;;
;; A count is a snapshot taken while the supervisor scans, and every
;; process of a run still in flight is passed over -- that run owns them.
;; So a `status' asked while a command runs is answered with a zero that
;; says nothing about what the command leaves behind, and that zero
;; arriving after the run ended would say the runtime holds nothing.  Each
;; question is therefore numbered with the runtime's epoch, which every
;; command that starts or ends bumps, and an answer whose number is no
;; longer the runtime's own is dropped rather than believed: a runtime is
;; not idle because nobody has counted what it holds.
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
;; the instance's id, so the supervisor finds every one of them by what
;; they inherited -- a `setsid' child and a double-forked daemon included
;; -- reading it from `/proc' on Linux and from the process table
;; (`ps -E', `ps e') where there is none; where neither is available it
;; asks the kernel about the process group the run was started in, which
;; is what a Mac under MXC has (see
;; `harness-sandbox-session--supervisor-program').  Cancel sends TERM to
;; each, waits, then KILLs what ignored it, and says how many are still
;; alive when it replies.  A run is cancelled only when that count is
;; zero; a run that cannot be emptied ends its whole runtime instead.
;; Destroy ends the instance: the supervisor ends every process of the
;; instance before it says it is going -- the kernel does that with the
;; namespace where there is one, and the supervisor does it itself where
;; there is not -- and the harness waits for its own process to be gone
;; before it says so.  An ordinary call that leaves a process running is
;; neither: the process survives, it is counted (`P'), and it keeps the
;; runtime alive.
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

(defconst harness-sandbox-session--heartbeat 10
  "Seconds between the supervisor's `H' frames.
A command that prints nothing sends no frame, and a transport that has
gone sends none either; the heartbeat is what tells them apart.  It must
stay well below `harness-sandbox-session--lease-seconds', which is what
reads it: a run is ended when no frame of any kind has arrived for the
lease, so a heartbeat at the lease would be no heartbeat at all.")

(defconst harness-sandbox-session--supervisor-program
  (mapconcat
   #'identity
   '("set +e"
     "version=$1 instance=$2 scratch=$3 beat=${4:-10}"
     "missing="
     "for p in base64 grep sed mkfifo dd tr sleep; do"
     "  command -v \"$p\" >/dev/null 2>&1 || missing=\"$missing $p\""
     "done"
     "if [ -n \"$missing\" ]; then printf 'R %s %s\\n' \"$version\" \"$missing\"; exit 3; fi"
     "printf 'R %s\\n' \"$version\""
     "export HARNESS_INSTANCE=$instance"
     ;; A nested runtime inherits its caller's run tag.  Only commands,
     ;; not the new supervisor's helpers, belong to a run.
     "unset HARNESS_RUN"
     ;; The supervisor's own helpers carry this; a command is started
     ;; with it empty, so what the instance runs can be told from what
     ;; runs it (`alive_of_instance').
     "export HARNESS_SUPERVISOR=$$"
     "live="
     "say() { printf '%s\\n' \"$*\"; }"
     ;; Where a run's processes are found.  Three ways, best first, and
     ;; the one that is chosen is said in the `V' frame:
     ;;
     ;;   proc   each process's environment, read from
     ;;          /proc/PID/environ.  Exact, and GNU/Linux has it.
     ;;   ps     the process table, asked for each process's environment
     ;;          (`ps -E' on BSD, `ps e' elsewhere), matching the
     ;;          HARNESS_INSTANCE it inherited.  Exact too, and what a
     ;;          BSD has where it can run `ps' at all.
     ;;   group  the process group each run is started in, and nothing
     ;;          else.  A run's shell is its group's leader (`set -m'),
     ;;          so its pid is the group's, `kill -0 -- -PGID' says
     ;;          whether anything of the run is left, and
     ;;          `kill -TERM/-KILL -- -PGID' ends it.  The kernel answers
     ;;          both, so this needs no program and no `/proc'.
     ;;
     ;; The last one is what macOS under MXC has.  Seatbelt refuses to
     ;; exec a setuid binary, and /bin/ps is setuid root, so `ps' cannot
     ;; run there at all -- and on macOS 27 the kernel withholds the
     ;; environment of Apple platform binaries (which /bin/bash, /bin/sh
     ;; and /bin/sleep are) from KERN_PROCARGS2, which is the call `ps -E'
     ;; makes.  Demanding either one made the supervisor say it lacked
     ;; ps-with-environment and exit, so every command in the sandbox
     ;; failed before it ran.
     ;;
     ;; What `group' gives up is what leaves the group: a `setsid' child
     ;; or a daemon that called setpgid.  Seatbelt confines a process
     ;; tree rather than a namespace, so such a process is still confined
     ;; by the profile it inherited, and MXC ends the run's whole tree
     ;; when the run's shell exits; the supervisor's own count of the
     ;; group is then a lower bound, which is what it says it is.
     ;;
     ;; HARNESS_SUPERVISOR_PROCS forces one way, so the way a Mac uses is
     ;; measured on a Linux host by its own tests.
     "procs=${HARNESS_SUPERVISOR_PROCS:-}"
     ;; Where `/proc' would be, so that a test can say there is none -- a
     ;; Mac has no /proc -- without a Mac to run it on.
     "procdir=${HARNESS_SUPERVISOR_PROC:-/proc}"
     "ps_style="
     ;; `ps' may not be there, or may be there and unable to run (a
     ;; setuid binary under Seatbelt): asking is the only way to know.
     "ps_works() {"
     "  ps -A -E -ww -o pid=,command= 2>/dev/null | grep -Fq \"HARNESS_INSTANCE=$instance\" && { ps_style=bsd; return 0; }"
     "  ps -A -ww -o pid=,command= e 2>/dev/null | grep -Fq \"HARNESS_INSTANCE=$instance\" && { ps_style=gnu; return 0; }"
     "  return 1"
     "}"
     "if [ \"$procs\" = group ]; then"
     "  :"
     "elif [ \"$procs\" = ps ]; then"
     "  if command -v ps >/dev/null 2>&1 && ps_works; then procs=ps; else procs=group; fi"
     "elif [ \"$procs\" = proc ]; then"
     "  :"
     "elif [ -r \"$procdir/self/environ\" ]; then"
     "  procs=proc"
     "elif command -v ps >/dev/null 2>&1 && ps_works; then"
     "  procs=ps"
     "else"
     "  procs=group"
     "fi"
     "if [ \"$procs\" = ps ]; then :; else ps_style=; fi"
     ;; Said before anything runs, so the harness -- and a user reading
     ;; the access view -- knows which answer a count is.
     "say V \"$procs\""
     "ps_lines() {"
     "  case \"$ps_style\" in"
     "    bsd) ps -A -E -ww -o pid=,command= 2>/dev/null ;;"
     "    gnu) ps -A -ww -o pid=,command= e 2>/dev/null ;;"
     "  esac"
     "}"
     ;; Every process of the instance, one per line, as the backend lets
     ;; it be seen: a path to its environment under /proc, or its whole
     ;; line of the process table.  `group' has no such list -- it knows
     ;; the runs it started, and asks the kernel about each group -- so
     ;; this answers nothing and its callers take their own `group' arm.
     "instance_environs() {"
     "  case \"$procs\" in"
     "    proc) grep -Flzx \"HARNESS_INSTANCE=$instance\" \"$procdir\"/[0-9]*/environ 2>/dev/null ;;"
     "    ps) ps_lines | while IFS= read -r line; do"
     "          case \" $line \" in *\" HARNESS_INSTANCE=$instance \"*) printf '%s\\n' \"$line\" ;; esac"
     "        done ;;"
     "    *) : ;;"
     "  esac"
     "}"
     ;; The process group a run was started in, which is its shell's pid
     ;; (see `run_one'), kept in its scratch until the group is empty.
     "pgid_of() { cat \"$scratch/$1/pgid\" 2>/dev/null; }"
     "group_alive() {"
     "  local g"
     "  g=$(pgid_of \"$1\")"
     "  [ -n \"$g\" ] || return 1"
     "  kill -0 -- \"-$g\" 2>/dev/null"
     "}"
     ;; The pids carrying RUN's token.  A tag matches whole, so one
     ;; instance's `-foreign' namesake and one run's `r1' beside `r12'
     ;; are not taken for each other.  Under `group' the group is the
     ;; answer, and a run whose group is empty has no process left.
     "pids_of() {"
     "  case \"$procs\" in"
     "    proc)"
     "      local f"
     "      for f in $(instance_environs); do"
     "        grep -Fqzx \"HARNESS_RUN=$1\" \"$f\" 2>/dev/null || continue"
     "        f=${f#\"$procdir\"/}"
     "        printf '%s\\n' \"${f%/environ}\""
     "      done ;;"
     "    ps)"
     "      instance_environs | while IFS= read -r line; do"
     "        case \" $line \" in *\" HARNESS_RUN=$1 \"*) ;; *) continue ;; esac"
     "        read -r pid rest <<< \"$line\""
     "        printf '%s\\n' \"$pid\""
     "      done ;;"
     "    group) pgid_of \"$1\" ;;"
     "  esac"
     "}"
     ;; The state of every process, from the process table: a zombie is
     ;; no process of the run, whatever it is still listed as.  `group'
     ;; asks the kernel whether the group has a member at all, so there
     ;; is nothing to filter.
     "states() { case \"$procs\" in group) : ;; *) ps -A -o pid=,stat= 2>/dev/null ;; esac; }"
     "alive_of() {"
     "  local p st table"
     "  if [ \"$procs\" = group ]; then"
     "    group_alive \"$1\" && pgid_of \"$1\""
     "    return 0"
     "  fi"
     "  table=$(states)"
     "  for p in $(pids_of \"$1\"); do"
     "    st=$(printf '%s\\n' \"$table\" | sed -n \"s/^ *$p  *//p\" | head -1)"
     "    case \"$st\" in Z*) ;; '') ;; *) printf '%s ' \"$p\" ;; esac"
     "  done"
     "}"
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
     "  while chunk=$(dd bs=384 count=1 <&9 2>/dev/null | base64 | tr -d '\\n'); do"
     "    [ -n \"$chunk\" ] || break"
     "    say \"$1\" \"$2\" \"$chunk\""
     "  done"
     "  exec 9<&-"
     "}"
     ;; The run token of every process of the instance, one line each, so
     ;; `status' can tell a process of a run in flight from one left over.
     "run_tokens() {"
     "  case \"$procs\" in"
     "    proc)"
     "      local f"
     "      for f in $(instance_environs); do"
     "        tr '\\0' '\\n' < \"$f\" 2>/dev/null | sed -n 's/^HARNESS_RUN=//p' | head -1"
     "      done ;;"
     "    ps)"
     "      instance_environs | while IFS= read -r line; do"
     "        case \" $line \" in *\" HARNESS_RUN=\"*) ;; *) continue ;; esac"
     "        printf '%s\\n' \"$line\" | sed -n 's/.* HARNESS_RUN=\\([^ ]*\\).*/\\1/p' | head -1"
     "      done ;;"
     ;; The token a run's group still holds is the token of a run in
     ;; flight: `run_one' writes the pgid before the command starts and
     ;; removes it when the group is empty, so a file left behind by a
     ;; run whose group went is no run at all.
     "    group)"
     "      local d g"
     "      for d in \"$scratch\"/*; do"
     "        [ -f \"$d/pgid\" ] || continue"
     "        [ -f \"$d/cmd\" ] && continue"
     "        g=$(cat \"$d/pgid\" 2>/dev/null)"
     "        [ -n \"$g\" ] || continue"
     "        kill -0 -- \"-$g\" 2>/dev/null || continue"
     "        printf '%s\\n' \"${d##*/}\""
     "      done ;;"
     "  esac"
     "}"
     ;; Every process of the instance, whatever run it belongs to.  The
     ;; supervisor and the helpers it starts carry HARNESS_SUPERVISOR with
     ;; its pid; a command is started with that name empty, so what is
     ;; left is exactly what the instance runs.  Under `group' that is the
     ;; runs whose group still has a member -- which is what the instance
     ;; is, since the supervisor and its helpers are in the supervisor's
     ;; own group and no run's.
     "alive_of_instance() {"
     "  local p st table g"
     "  if [ \"$procs\" = group ]; then"
     ;; The tokens the instance still runs, as the groups they are: a
     ;; caller kills what this answers, so it is pids here, not tokens.
     "    for p in $(pids_of_instance); do"
     "      g=$(pgid_of \"$p\")"
     "      [ -n \"$g\" ] && printf '%s ' \"$g\""
     "    done"
     "    return 0"
     "  fi"
     "  table=$(states)"
     "  for p in $(pids_of_instance); do"
     "    st=$(printf '%s\\n' \"$table\" | sed -n \"s/^ *$p  *//p\" | head -1)"
     "    case \"$st\" in Z*) ;; '') ;; *) printf '%s ' \"$p\" ;; esac"
     "  done"
     "}"
     "pids_of_instance() {"
     "  case \"$procs\" in"
     "    proc)"
     "      local f"
     "      for f in $(instance_environs); do"
     "        if grep -Fqzx \"HARNESS_SUPERVISOR=$$\" \"$f\" 2>/dev/null; then continue; fi"
     "        f=${f#\"$procdir\"/}"
     "        printf '%s\\n' \"${f%/environ}\""
     "      done ;;"
     "    ps)"
     "      instance_environs | while IFS= read -r line; do"
     "        case \" $line \" in *\" HARNESS_SUPERVISOR=$$ \"*) continue ;; esac"
     "        read -r pid rest <<< \"$line\""
     "        printf '%s\\n' \"$pid\""
     "      done ;;"
     "    group) run_tokens ;;"
     "  esac"
     "}"
     "count_of() { printf '%s' \"$1\" | tr -s ' ' '\\n' | grep -c .; }"
     "untag() {"
     "  local out= t"
     "  for t in $2; do [ \"$t\" = \"$1\" ] || out=\"$out $t\"; done"
     "  printf '%s' \"$out\""
     "}"
     "start_one() {"
     "  local token=$1 secs=$2 dir=$scratch/$1"
     "  mkdir -p \"$dir\" && rm -f \"$dir/o\" \"$dir/e\" \"$dir/timed-out\" && mkfifo \"$dir/o\" \"$dir/e\" \\"
     "    || { say X \"$token\" 126 0; return 1; }"
     "  say S \"$token\""
     "  live=\"$live $token\""
     "  return 0"
     "}"
     ;; A command runs in a process group of its own (`set -m'), so the
     ;; run's own watchdog can end every process of it -- a `setsid' child
     ;; that left the group is found by its tag instead (`alive_of').  The
     ;; watchdog is the shell's own, not coreutils `timeout', which macOS
     ;; does not ship; it says it fired with a file, because a finished
     ;; child is a zombie until it is waited for and would still answer
     ;; `kill -0'.  A run ended at its time says 124, as `timeout' said.
     "run_one() {"
     "  local token=$1 secs=$2 dir=$scratch/$1 op ep rp wp st left"
     "  draw O \"$token\" \"$dir/o\" & op=$!"
     "  draw E \"$token\" \"$dir/e\" & ep=$!"
     "  printf '%s' \"$3\" | base64 -d > \"$dir/cmd\" 2>/dev/null"
     "  set -m"
     "  HARNESS_SUPERVISOR= HARNESS_RUN=$token bash \"$dir/cmd\" </dev/null >\"$dir/o\" 2>\"$dir/e\" & rp=$!"
     ;; The run's group is the run's shell's pid (`set -m' makes it the
     ;; leader), and it is written where `pgid_of' reads it before the
     ;; command can start: a `kill' that arrives at once names a group
     ;; this instance already knows.  `cmd' is what says a run is in
     ;; flight; `pgid' is what says one is still there.
     "  printf '%s\\n' \"$rp\" > \"$dir/pgid\""
     "  ( sleep \"$secs\"; : > \"$dir/timed-out\"; kill -TERM -- \"-$rp\" 2>/dev/null"
     "    sleep 3; kill -KILL -- \"-$rp\" 2>/dev/null ) >/dev/null 2>&1 & wp=$!"
     "  set +m"
     "  wait $rp; st=$?"
     "  kill -TERM -- \"-$wp\" 2>/dev/null; kill -TERM \"$wp\" 2>/dev/null"
     "  wait $wp 2>/dev/null"
     "  if [ -f \"$dir/timed-out\" ]; then st=124; fi"
     "  rm -f \"$dir/timed-out\""
     "  wait $op $ep"
     "  rm -f \"$dir/cmd\""
     "  live=$(untag \"$token\" \"$live\")"
     "  left=$(alive_of \"$token\")"
     ;; The group is gone when nothing is left of it, and the record of it
     ;; goes with it: a pgid kept after its group is empty is a pid the
     ;; kernel may hand to something else, which would be counted here.
     "  [ -z \"$left\" ] && rm -f \"$dir/pgid\""
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
     ;; Ending the instance ends what it runs, and says how many would not
     ;; go: under bwrap the kernel ends them with the namespace, and a
     ;; backend that only confines the process tree (MXC) has this to end
     ;; them with instead.
     "kill_all() {"
     "  local pids p i"
     "  pids=$(alive_of_instance)"
     "  for p in $pids; do kill -TERM -- \"-$p\" 2>/dev/null; kill -TERM \"$p\" 2>/dev/null; done"
     "  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do"
     "    sleep 0.25"
     "    pids=$(alive_of_instance)"
     "    [ -z \"$pids\" ] && break"
     "    for p in $pids; do kill -KILL -- \"-$p\" 2>/dev/null; kill -KILL \"$p\" 2>/dev/null; done"
     "  done"
     "  printf '%s' \"$(count_of \"$(alive_of_instance)\")\""
     "}"
     "status_all() {"
     "  local n=0 tok seq=$1"
     "  for tok in $(run_tokens); do"
     "    [ -n \"$tok\" ] || continue"
     ;; A run in flight is the one whose command file is still there:
     ;; `run_one' writes it before the command starts and removes it
     ;; when the command ends.  `live' cannot answer this -- `run_one'
     ;; runs in the background, so the `untag' it does never reaches
     ;; this shell and the list only ever grows -- and counting by it
     ;; skipped every process of the instance, a leftover included.
     "    if [ -f \"$scratch/$tok/cmd\" ]; then continue; fi"
     "    n=$((n+1))"
     "  done"
     "  say P \"$n\" \"$seq\""
     "}"
     ;; A command that prints nothing -- a sleep, a build that is quiet, a
     ;; clone on a slow link -- writes no frame, and a transport that has
     ;; gone writes none either: without a heartbeat the harness cannot
     ;; tell the two apart, and its lease ends the run as if the
     ;; transport had.  So the loop reads with a timeout and says `H'
     ;; when it times out.  `H' is a frame of the same pipe, and that is
     ;; the point: it says the pipe still carries a frame from here to
     ;; there.  If the harness has stopped reading, this write blocks, no
     ;; `H' gets through, and the lease still sees a transport that is
     ;; gone.
     ;;
     ;; The read is by line, accumulated across timeouts: a `run' line
     ;; carries the command's script in base64 and can be longer than
     ;; PIPE_BUF, so it may arrive in pieces, and a timeout in the middle
     ;; of one must not throw the pieces away.
     "line="
     "while :; do"
     "  IFS= read -r -t \"$beat\" chunk"
     "  st=$?"
     "  line=\"$line$chunk\""
     "  if [ \"$st\" -gt 128 ]; then say H; continue; fi"
     "  if [ \"$st\" -ne 0 ]; then break; fi"
     "  op= a= b= c="
     ;; A control line is split into words without expanding anything in
     ;; it.  Globbing is not turned off for the program: `alive_of' reads
     ;; /proc/[0-9]*/environ and needs it.
     "  IFS=' ' read -r op a b c <<< \"$line\""
     "  line="
     "  case \"$op\" in"
     ;; A run's directories and its `S' frame are made here, before
     ;; the next control line is read, so a `kill' that follows a `run'
     ;; names a token the instance already knows; what runs afterwards
     ;; is in the background.
     "    run) if start_one \"$a\" \"$b\"; then run_one \"$a\" \"$b\" \"$c\" & fi ;;"
     "    kill) kill_one \"$a\" & ;;"
     "    status) status_all \"$a\" & ;;"
     ;; Ending the instance ends what it runs.  Under bwrap the kernel
     ;; does that when the namespace's init goes, and MXC -- whose
     ;; confinement is a process tree, not a namespace -- is asked to:
     ;; the `D' frame comes after every process of the instance has been
     ;; sent TERM and then KILL, so a caller that sees it knows the
     ;; instance is empty, not only that the supervisor is leaving.
     "    quit) kill_all >/dev/null; say D; exit 0 ;;"
     "  esac"
     "done"
     "exit 0")
   "\n")
  "The program the init of a session's runtime runs.

  bash supervisor.sh VERSION INSTANCE SCRATCH BEAT

It writes the frames the module's commentary lists on standard output and
reads `run TOKEN SECONDS BASE64', `kill TOKEN', `status N' and `quit' on
standard input.  Its output is a pipe the sandbox cannot reach, and it
writes no file the harness reads: what a command prints is drawn into a
frame as it arrives, one `write()' each, below `PIPE_BUF', so a frame is
whole in the pipe and cannot be forged from a command's bytes.

It needs `base64', `grep', `sed', `mkfifo', `dd', `tr' and `sleep' -- the
programs a Mac and a Linux both have -- and names in its `R' frame
whichever is missing, so a backend that gives fewer tools says so rather
than hang.  Coreutils' `timeout' and `setsid' are not among them: macOS
has neither, so a run's own time is kept by a shell watchdog.

How it finds a run's processes is negotiated, not demanded, and said in
its `V' frame: `proc' (each process's environment from
`/proc/PID/environ', exact, GNU/Linux), `ps' (the process table with each
process's environment, `ps -E' or `ps e', exact, where `ps' can run at
all) or `group' (the process group the run was started in, asked of the
kernel, which needs no program).  It falls to `group' when neither
`/proc' nor a `ps' that answers is there, which is what a Mac under MXC
is: Seatbelt refuses to exec a setuid binary and /bin/ps is setuid root,
and macOS 27 withholds an Apple platform binary's environment -- which
/bin/bash and /bin/sleep are -- from the call `ps -E' makes.
HARNESS_SUPERVISOR_PROCS forces one way, which is how the tests measure
each of them on a Linux host.  HARNESS_SUPERVISOR_PROC names where
`/proc' would be, so a test can say there is none -- a Mac has none --
without a Mac to run it on.")

(defconst harness-sandbox-session--runtime-keys
  '(:session :instance :dir :scratch :process :buffer :partial :state
    :reason :since :started :checked :idle-since :owned :asked
    :epoch :profile :procs
    :cwd :generation :backend :capabilities :runs :going)
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
     (t (let ((held (harness-sandbox-session--hold ctx cwd)))
          (or (plist-get held :why)
              (when-let* ((missing (harness-sandbox-session--missing-capabilities held)))
                (format "%s cannot promise %s, which a runtime's cancel and end need"
                        (or (plist-get held :backend) "the backend")
                        (string-join (mapcar (lambda (fact) (substring (symbol-name fact) 1))
                                             missing)
                                     ", ")))))))))

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
        (plist-get runtime :scratch)
        (number-to-string
         (max 1 (min harness-sandbox-session--heartbeat
                     (floor (/ harness-sandbox-session--lease-seconds 3)))))))

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
                     (process-exit-status proc)))
      ;; What a runtime held outlives the decision to end it, and this is
      ;; where it goes: the poll ends a runtime without waiting for its
      ;; process (`harness-sandbox-session--stop-later'), leaving its
      ;; buffer and its scratch for the moment the process is gone.
      (harness-sandbox-session--discard runtime))))

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
answers only when the instance is, which is what makes \"stopped\" true.

A caller that must not wait on the event loop -- the poll that looks at
every runtime ten times a second -- uses
`harness-sandbox-session--stop-later' instead: the same end, asked for
and finished from the sentinel."
  (harness-sandbox-session--end runtime reason failure t))

(defun harness-sandbox-session--stop-later (runtime &optional reason failure)
  "End RUNTIME for REASON without waiting for it to go.  Return RUNTIME.
What `harness-sandbox-session--stop' does, except that the harness does
not wait for the supervisor's process: the state is marked, the
supervisor is asked to quit, and the sentinel -- which runs when the
process is gone -- finishes the end.  A supervisor that will not go is
ended by a timer, not by a wait.

This is what the poll uses.  Waiting there blocked the whole event loop,
every session's work with it, for as long as the supervisor took to
close: the harness's own latency records show 2-7.5 s stalls, one of 38 s
and one of 341 s, all inside `harness-sandbox-session--poll-runtime'."
  (harness-sandbox-session--end runtime reason failure nil))

(defun harness-sandbox-session--end (runtime reason failure settle)
  "End RUNTIME for REASON, as `harness-sandbox-session--stop' does.
With SETTLE, wait for the supervisor's process to be gone first."
  (let ((proc (plist-get runtime :process))
        (sid (plist-get runtime :session)))
    ;; The runtime reads as ended before its process is asked to go: the
    ;; sentinel runs while this waits for it, and a runtime still marked
    ;; running would have its commands called broken rather than stopped.
    ;; `:going' says the same to everything that runs in between -- a
    ;; `R' frame that arrives while the supervisor is closing must not put
    ;; it back to running, and a run's last report is the teardown's.
    (setf (plist-get runtime :state) (if failure 'failed 'stopped)
          (plist-get runtime :going) (if failure 'failed 'stopped)
          (plist-get runtime :reason) (or reason (plist-get runtime :reason)))
    (when (and proc (process-live-p proc))
      (harness-log 'debug "sandbox: stopping %s (%s)" (plist-get runtime :instance)
                   (or reason "no reason"))
      (ignore-errors (harness-process-send proc "quit\n"))
      (if (not settle)
          ;; The sentinel finishes the end when the process goes; this is
          ;; only the bound on a supervisor that does not.
          (run-at-time harness-sandbox-session--settle nil
                       (lambda ()
                         (when (process-live-p proc)
                           (harness-log 'warn
                                        "sandbox: %s did not close, ending it"
                                        (plist-get runtime :instance))
                           (ignore-errors (delete-process proc)))))
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
              (accept-process-output nil 0.02))))))
    (harness-sandbox-session--fail-runs runtime (or reason "its runtime stopped")
                                        (if failure 'failed 'stopped))
    ;; The runtime stays the session's until its process is gone.  It reads
    ;; as `stopped', so `harness-sandbox-session-ensure' builds another one
    ;; rather than using it -- and waits for this one, which is what keeps
    ;; two supervisors for one session from existing at once.  The sentinel
    ;; forgets it, and drops what it held, when the process goes.
    (when settle
      (when (eq runtime (gethash sid harness-sandbox-session--runtimes))
        (remhash sid harness-sandbox-session--runtimes))
      (harness-sandbox-session--discard runtime))
    runtime))

(defun harness-sandbox-session--discard (runtime)
  "Drop what RUNTIME holds that outlives it: its buffer and its scratch.
Safe to call twice: the sentinel and the caller both do."
  (when (buffer-live-p (plist-get runtime :buffer))
    (kill-buffer (plist-get runtime :buffer)))
  (let ((scratch (plist-get runtime :scratch)))
    (when (and (stringp scratch) (file-exists-p scratch))
      ;; A run's scratch is its own files: a script and two fifos.  A
      ;; command that wrote a great deal there makes this slow, so it is
      ;; never done twice for one runtime.
      (setf (plist-get runtime :scratch) nil)
      (ignore-errors (delete-directory scratch t)))))

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
      ;; A runtime that is going -- one the poll ended without waiting --
      ;; is waited for here, the one admission point, so nothing is
      ;; submitted into an instance that is being destroyed and no second
      ;; supervisor is started for the same session.
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
      ("V" (harness-sandbox-session--visibility runtime token))
      ("S" (when-let* ((run (harness-sandbox-session--run runtime token)))
             (setf (plist-get run :started) (or (plist-get run :started) (float-time))
                   (plist-get runtime :state) 'running)))
      ("O" (harness-sandbox-session--output runtime token (nth 2 parts) :stdout))
      ("E" (harness-sandbox-session--output runtime token (nth 2 parts) :stderr))
      ("X" (harness-sandbox-session--ended runtime token (nth 2 parts) (nth 3 parts)))
      ("P" (harness-sandbox-session--counted runtime token (nth 2 parts)))
      ;; The supervisor's heartbeat: no output to carry, only the word
      ;; that the transport still carries frames.  `:checked' is what the
      ;; lease reads, and the filter has already moved it; this frame
      ;; exists so that a quiet command's silence is not taken for a
      ;; transport that has gone.
      ("H" nil)
      ("D" (setf (plist-get runtime :state) 'stopped))
      ((or "S" "") nil)
      (_
       ;; A line that is no frame is the supervisor's own diagnostics, or
       ;; a command's raw bytes that escaped its pipes.  It is logged,
       ;; never shown as output.
       (harness-log 'debug "sandbox: %s said %S" (plist-get runtime :instance)
                    (truncate-string-to-width line 200))))))

(defun harness-sandbox-session--visibility (runtime way)
  "Record that RUNTIME finds its processes WAY, from its `V' frame.
WAY is `proc', `ps' or `group' (see
`harness-sandbox-session--supervisor-program').  It is what a count of the
runtime's processes is worth: `proc' and `ps' find a process that left its
group, and `group' does not -- a group cannot be left and then found, only
asked after -- so a `group' runtime's count is a lower bound and its
answer says so."
  (when (member way '("proc" "ps" "group"))
    (setf (plist-get runtime :procs) (intern way))))

(defun harness-sandbox-session--ready (runtime parts)
  "Record that RUNTIME's supervisor said it is up, from PARTS.
When it names programs it lacks, the runtime is not one this module can
use: its runs are failed with that reason and it is ended.  A runtime
that is going stays going: its `R' frame may arrive while it is being
closed, and saying it is up would read the end of its runs as a failure."
  (let ((missing (cdr (cdr parts))))
    (unless (plist-get runtime :going)
      (setf (plist-get runtime :state) 'running))
    (if missing
        (let ((why (format "the sandbox lacks %s" (string-join missing ", "))))
          (harness-sandbox-session--fail-runs runtime why 'failed)
          (setf (plist-get runtime :reason) why))
      (harness-log 'debug "sandbox: %s ready (%s)" (plist-get runtime :instance)
                   (plist-get runtime :backend)))
  ;; The supervisor said it is up; the harness may ask what it holds.
  (harness-sandbox-session--ask runtime)))

(defun harness-sandbox-session--counted (runtime count epoch)
  "Record COUNT, processes RUNTIME holds, from the answer numbered EPOCH.
A count is a snapshot taken while the supervisor scans, so it can be
older than what the harness already knows: the `status' sent when the
runtime became ready is answered while a command is still in flight, and
every process of that command is passed over as one the run owns, so the
answer is a zero.  Arriving after the run has ended, it would say the
runtime holds nothing and the poll would destroy it with the process the
run left behind still in it.  An answer to a question asked before the
last command started or ended is therefore dropped rather than believed:
the epoch it carries is no longer the runtime's own."
  (when (and (stringp epoch)
             (equal epoch (number-to-string (or (plist-get runtime :epoch) 0))))
    (setf (plist-get runtime :owned) (string-to-number (or count "0"))
          (plist-get runtime :asked) (float-time))
    (unless (plist-get runtime :going)
      (setf (plist-get runtime :state) 'running))))

(defun harness-sandbox-session--ask (runtime)
  "Ask RUNTIME how many processes it holds, and number the question.
The number is the runtime's `:epoch', which every command that starts or
ends bumps, so an answer to a question asked before that change carries
an epoch the runtime no longer has and is dropped."
  (setf (plist-get runtime :asked) (float-time)
        (plist-get runtime :owned) nil)
  (ignore-errors
    (harness-sandbox-session--send
     runtime (format "status %s" (or (plist-get runtime :epoch) 0)))))

(defun harness-sandbox-session--bump-epoch (runtime)
  "Say that what RUNTIME holds changed, so an answer already asked for is stale."
  (setf (plist-get runtime :epoch) (1+ (or (plist-get runtime :epoch) 0))))

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
           ;; A runtime that is going takes its runs with it, and the
           ;; supervisor ends their processes before it says `D' -- which
           ;; is what a backend without a namespace to end them with needs
           ;; (MXC).  So a run's report that arrives after the harness
           ;; ended the runtime is the teardown's doing, not the
           ;; command's: 143 is not a command that failed, and the run is
           ;; `stopped' with the runtime's reason.  `:going' is read
           ;; rather than the state: a `R' or `P' frame can arrive while
           ;; the supervisor is closing, and a run's own end is the last
           ;; thing it says.
           (ended-with (plist-get runtime :going))
           (state (or ended-with
                      (cond ((or wanted (memq code '(124 137))) 'stopped)
                            ((eql code 0) 'exited)
                            (t 'failed)))))
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
              ;; A run the harness asked to stop is a cancellation, whatever
              ;; code the kill left: the supervisor's kill loop sends TERM and
              ;; then KILL, and a run's own watchdog turns the same pair into
              ;; 124 and then 137.  Reading the code first called an explicit
              ;; cancellation a timeout whenever a process ignored TERM, which
              ;; is exactly when a stop takes the longer road.  A run its
              ;; runtime's end took says that, not its exit code.
              (cond (wanted (plist-get run :cancelled-reason))
                    (ended-with (or (plist-get runtime :reason)
                                    "its runtime stopped"))
                    ((memq code '(124 137))
                     (format "it reached its timeout of %s"
                             (harness-format-duration (plist-get run :seconds)))))))
      ;; What the instance held before this run ended is no answer to what
      ;; it holds now: the run may have left processes behind, and only a
      ;; new count can say.  The run's own survivors are a lower bound, and
      ;; a zero is what says the instance may be idle.
      (harness-sandbox-session--bump-epoch runtime)
      (setf (plist-get runtime :owned) (and (> survivors 0) survivors)
            (plist-get runtime :asked) (and (> survivors 0) (float-time)))
      (harness-sandbox-session--end-run
       run state code
       (cond (wanted (plist-get run :cancelled-reason))
             (ended-with (or (plist-get runtime :reason) "its runtime stopped"))
             ((memq code '(124 137))
              (format "it reached its timeout of %s"
                      (harness-format-duration (plist-get run :seconds))))))
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
              (harness-sandbox-session--stop-later runtime "its runtime did not start" t))
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
      (harness-sandbox-session--stop-later runtime "its output stopped reaching the harness" t)
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
         ;; Ask again once the last question has had its
         ;; `harness-sandbox-session--poll-answer' to be answered.  The
         ;; wait is on the question, not on the answer: asking while an
         ;; answer is still owed used to send a `status' on every poll
         ;; tick, and the supervisor answers each one by scanning every
         ;; process's environment, so the questions starved the answer
         ;; they were waiting for.
         ((not (and asked (<= (- now asked) harness-sandbox-session--poll-answer)))
          (harness-sandbox-session--ask runtime)
          (setq keep t))
         ;; Asked, and no answer has come back yet: decide nothing.  A
         ;; runtime is not idle because nobody has counted what it holds,
         ;; so an unanswered question is never read as owning nothing.
         ((not (integerp owned))
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
              (harness-sandbox-session--stop-later runtime "nothing of the session was left in it")
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
    (setf (plist-get runtime :idle-since) nil
          ;; The lease measures silence since the last frame, and a run
          ;; that has just started has sent none yet: without this, a run
          ;; started into a runtime that has been quiet for a while would
          ;; be ended at its first look for silence that came before it.
          (plist-get runtime :checked) (float-time))
    ;; A command is starting: a count asked for before it is no answer to
    ;; what the runtime holds now.
    (harness-sandbox-session--bump-epoch runtime)
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
demand and a session that is not working holds none.

`:procs' says how the runtime finds the processes it counts -- `proc',
`ps' or `group' (see `harness-sandbox-session--supervisor-program') --
or nil before its supervisor has said.  `:owned' is exact under `proc'
and `ps', and a lower bound under `group'."
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
              :procs (plist-get runtime :procs)
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
