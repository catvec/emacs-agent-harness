;;; harness-tool-slots.el --- A few slots per machine for the tools that start processes  -*- lexical-binding: t; -*-

;;; Commentary:

;; Some tools start whole process trees.  bash runs a shell command --
;; a build, the test suite, or scripts/dev.sh, which starts another
;; Emacs with the harness in it.  elisp starts a batch Emacs for every
;; call, and ssh runs a command on another host; a module outside the
;; harness may have such a tool too, as this repository's plugin has
;; open_harness, which starts a checkout's development Emacs.  One such
;; call is meant to use the
;; machine; several at once -- a task board running a handful of
;; sessions, each with sub-agents of its own, a model that tries
;; commands in parallel -- take it over, and whatever else the user
;; runs, a game above all, stops answering.
;;
;; So this module holds a fixed number of slots per machine.  A call of
;; a governed tool (`harness-tool-slots-tools') starts while the machine
;; it runs on has a free slot, and otherwise waits until one is given
;; back.  The calls waiting for a slot go by the priority of the session
;; they serve (`harness-priority'): the highest priority call waiting
;; takes the slot, the oldest of those first, so the commands of a task
;; you marked high are served before the commands of a low one, and the
;; sub-agents of a task work at the task's priority.  A call waits only
;; for its own machine, so a command on another host (bash in a TRAMP
;; directory, the ssh tool) takes that host's slots, not this one's.
;; Waiting is not counted against the call's own timeout: that starts
;; when the call runs.
;;
;; Tools that only read or write files, ask the model something, or talk
;; to the bus are not governed, so a read_file never queues behind a
;; test run.  Neither is the harness's own work -- the merge queue,
;; worktrees, the grep tool: this is about what a model asks to run.
;;
;; The limit is `harness-tool-slots-count' slots on each machine, one
;; per processor by default, and `harness-tool-slots-burst' more may run
;; at once: a limit meant for the long commands should not make every
;; short one wait.  The slots belong to the harness process that loads
;; this module; a second harness on the same machine has its own.
;;
;; The slots of a machine are a pool of the harness-slots library
;; (lisp/harness-slots.el), which counts the calls holding a slot,
;; keeps the line of those waiting and hands the slots out.  This module
;; says how many slots a machine has (`harness-tool-slots--slots') and
;; how a waiting call ranks in the line: the priority of its session.
;;
;; Who is using the slots can be seen: a call asks its pool with the
;; session it serves and the tool it runs, so the pool knows what each
;; holder runs for whom, and since when, and each waiter too
;; (`harness-tool-slots-machines', machine by machine).  That changes
;; nothing about who is served: the session is what the call was ranked
;; by already, and the tool is only known along with it.  Whenever who
;; holds a slot, or waits for one, changes, the event
;; `tool-slots/holders-changed' says so; the tool-slots-load module turns
;; it into the `tool-slots/changed' a UI shows the slots by.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-slots)
(require 'harness-tools)
(require 'harness-priority)

(defcustom harness-tool-slots-count nil
  "How many calls of a governed tool may run at once on one machine.
Calls of the tools `harness-tool-slots-tools' names hold a slot of the
machine they run on; further calls wait for one, and the session's
priority decides which of those waiting goes first (`harness-priority').
nil, the default, is one slot per processor
\(`num-processors').  Set a smaller number to leave the machine more to
the user, such as 4 on a 16-core machine while they game; the calls
still run, they just wait their turn."
  :type '(choice (const :tag "One per processor" nil) integer)
  :group 'harness)

(defcustom harness-tool-slots-burst 2
  "Extra calls allowed on a machine over `harness-tool-slots-count'.
A limit sized for long commands would otherwise make every short one
wait behind them; the burst is the slack that keeps a trickle of quick
calls from queueing."
  :type 'integer
  :group 'harness)

(defcustom harness-tool-slots-tools '("bash" "elisp" "ssh")
  "Tools whose calls hold a slot of the machine they run on.
They are the tools that start processes: a shell command (which may be
a build, a test run, or a script that starts more Emacs), a batch
Emacs, and a command on another host.  A tool that is not listed never
waits.  Add a tool of your own that starts processes, or take one of
these out to let it run freely.  A module that defines such a tool --
a project's plugin, say, such as this repository's open_harness, which
starts an Emacs -- may add it here itself as it loads."
  :type '(repeat string)
  :group 'harness)

(defvar harness-tool-slots-machine-function #'harness-tool-slots-default-machine
  "Function returning the machine whose slots a tool call takes.
Called with the tool name, the call's input and its context, as
`harness-tool-slots-default-machine' is.  nil, or an error, means the
machine this harness runs on.  Set it to put every governed call on one
machine's slots, or bind it in a test.")

;;;; Slots

(defvar harness-tool-slots--machines (make-hash-table :test 'equal)
  "Machine key -> its slots, a pool of the harness-slots library.
The pool allows `harness-tool-slots--slots' calls at once.  Each call
asks with its data, `harness-tool-slots--data': the session it serves
and the tool it runs.  The priority of the session decides among the
calls waiting which is served next (`harness-tool-slots--rank-of').  A
machine keeps its pool once its last call is done.")

(harness-declare-event 'tool-slots/holders-changed
  "(MACHINE) once who holds a tool slot of MACHINE, or waits for one, changed.")

(defun harness-tool-slots--baseline ()
  "Return how many calls may run at once on one machine.
That is the limit the options alone set, before any other module
modulates it per machine (see `harness-tool-slots--slots')."
  (max 1 (+ (if (and (integerp harness-tool-slots-count)
                     (> harness-tool-slots-count 0))
                harness-tool-slots-count
              (max 1 (num-processors)))
            (if (and (integerp harness-tool-slots-burst)
                     (> harness-tool-slots-burst 0))
                harness-tool-slots-burst
              0))))

(defun harness-tool-slots--slots (&optional machine)
  "Return how many calls may run at once on MACHINE.
That is `harness-tool-slots--baseline' and, with MACHINE non-nil, what
another module makes of it for that machine: a module may lower the
limit of the machine this harness runs on while it is busy (see the
tool-slots-load plugin).  MACHINE nil, as a caller that does not say,
keeps the baseline."
  ;; MACHINE is the extension point: a module may lower the limit of the
  ;; machine this harness runs on by advising this function (see the
  ;; tool-slots-load plugin).
  (ignore machine)
  (harness-tool-slots--baseline))

(defun harness-tool-slots--priority (session)
  "Return the priority of SESSION, a session id or nil, as a level.
A call that has no session at all -- the harness itself asked -- waits
as `harness-priority-default' does."
  (if session (harness-priority-of session) harness-priority-default))

(defun harness-tool-slots--data (session tool)
  "Return what a call of TOOL for SESSION asks a pool for a slot with.
That is (:session SESSION :tool TOOL): SESSION a session id or nil, and
TOOL the tool's name."
  (list :session session :tool tool))

(defun harness-tool-slots--data-field (data key)
  "Return KEY, `:session' or `:tool', of DATA, what a call asked a pool with.
A call that asked before the tool was noted -- one a reload kept, or one
of the calls that waited in the slots from before pools -- asked with
the bare session id, or nil: that is its session and no tool is known."
  (if (and (consp data) (keywordp (car data)))
      (plist-get data key)
    (and (eq key :session) data)))

(defun harness-tool-slots--rank-of (data)
  "Return the rank of a call waiting for a slot, that asked with DATA.
That is the priority of the session DATA names as it is now, so raising
a session's priority moves the calls it already has waiting.  It is the
pool's rank function (`harness-slots-create'), and DATA what a call asks
with (`harness-tool-slots--data'); among calls of one rank the oldest
goes first."
  (harness-priority-rank
   (harness-tool-slots--priority (harness-tool-slots--data-field data :session))))

(defun harness-tool-slots--pool (machine)
  "Return the pool of slots of MACHINE, making it when it has none yet.
A reload keeps `harness-tool-slots--machines', so it may still hold a
machine's slots from before they were pools: a (RUNNING . WAITERS)
cons.  The pool that replaces it starts with no call running, and the
calls that waited ask it for their slots, in the order they came,
instead of waiting for slots whose holders no longer count.  Those
holders, the calls that held a slot before the reload, give theirs
back through `harness-tool-slots--give', which counts nothing down; so
for a while after such a reload a machine may run a few more calls than
its limit, the old ones and the new."
  (let ((pool (gethash machine harness-tool-slots--machines)))
    (if (and pool (not (consp pool)))
        pool
      (let ((fresh (harness-slots-create
                    :limit (lambda () (harness-tool-slots--slots machine))
                    :rank #'harness-tool-slots--rank-of)))
        (puthash machine fresh harness-tool-slots--machines)
        (dolist (waiter (cdr pool))
          (harness-resolve (plist-get waiter :promise)
                           (harness-slots-acquire
                            fresh (harness-tool-slots--data (plist-get waiter :session) nil))))
        fresh))))

(defun harness-tool-slots--changed (machine)
  "Say that who holds a slot of MACHINE, or waits for one, changed."
  (harness-emit 'tool-slots/holders-changed machine))

(defun harness-tool-slots--admit (machine)
  "Start the calls waiting for MACHINE while it has free slots.
The calls waiting go by priority, the oldest first among equals
\(`harness-slots-admit').  A module that raises a machine's limit while
calls wait calls this, so they start without waiting for another call
to finish.  A call that started is a change of who holds a slot
\(`tool-slots/holders-changed')."
  (let* ((pool (harness-tool-slots--pool machine))
         (before (harness-slots-running pool)))
    (harness-slots-admit pool)
    (unless (= before (harness-slots-running pool))
      (harness-tool-slots--changed machine))))

(defun harness-tool-slots--acquire (machine session &optional tool)
  "Return a promise of a ticket for a slot of MACHINE for a call of SESSION.
It resolves at once when MACHINE has a free slot, and otherwise when
one is given back to it, by SESSION's priority then, oldest first among
equals (`harness-slots-acquire').  TOOL is the name of the tool the call
runs, which the slot's holder is known by (`harness-tool-slots-machines').
The call is either holding a slot or waiting for one when this returns,
which is a change of who does (`tool-slots/holders-changed')."
  (prog1 (harness-slots-acquire (harness-tool-slots--pool machine)
                                (harness-tool-slots--data session tool))
    (harness-tool-slots--changed machine)))

(defun harness-tool-slots--give (machine)
  "Give back a slot of MACHINE that a call took before slots were pools.
Only a ticket made before the reload that brought the pools calls this.
A reload keeps the closures of the calls running through it, and those
were made when a machine's slots were a (RUNNING . WAITERS) cons: each
gives its slot back by this name.  The pool that took over counted no
such call -- it started at 0 running and counts the calls it admitted
itself -- so nothing is counted down here, or a call it did count would
lose its place.  The calls waiting that now fit start
\(`harness-tool-slots--admit').  So such a ticket neither signals nor
miscounts.  A ticket the pool made gives its slot back by itself
\(`harness-slots-acquire')."
  (harness-tool-slots--admit machine))

;;;; Which machine a call runs on

(defun harness-tool-slots-default-machine (name input ctx)
  "Return the machine a call of tool NAME with INPUT under CTX runs on.
An ssh call runs on the host its `:host' names.  Any other governed
tool runs where the directory it starts in is: on the machine of CTX's
working directory, or of the one INPUT's `:cwd' names, which is this
machine unless it is a TRAMP directory.  This machine's key is the
name the function `system-name' gives, after \"local:\", so a host named
like it elsewhere is not taken for it.  Two spellings of one host -- an
ssh alias and an address, say -- are two keys, which only means the
host gets the slots of both."
  (or (let ((host (and (equal name "ssh") (plist-get input :host))))
        (and (stringp host) (not (string-blank-p host))
             (concat "host:" (string-trim host))))
      (let ((dir (condition-case nil
                     (harness-tools-resolve-path (or (plist-get input :cwd) ".") ctx)
                   (error nil))))
        (if (and (stringp dir) (file-remote-p dir))
            (concat "host:" (or (file-remote-p dir 'host)
                                ;; A prefix whose host TRAMP cannot name.
                                dir))
          (concat "local:" (or (system-name) "machine"))))))

(defun harness-tool-slots--machine (tool input ctx)
  "Return the key of the machine a call of TOOL with INPUT under CTX runs on."
  (or (condition-case err
          (funcall harness-tool-slots-machine-function (harness-tool-name tool) input ctx)
        (error (harness-log 'debug "tool-slots: no machine for %s: %s"
                            (harness-tool-name tool) (harness-error-message err))
               nil))
      (concat "local:" (or (system-name) "machine"))))

(defun harness-tool-slots--machine-label (machine)
  "Return MACHINE as a person reads it."
  (if (string-prefix-p "local:" machine)
      "this machine"
    (string-remove-prefix "host:" machine)))

;;;; Holding a slot

(defun harness-tool-slots--governed-p (tool)
  "Non-nil when a call of TOOL holds a slot while it runs."
  (and (harness-tool-p tool)
       (member (harness-tool-name tool) harness-tool-slots-tools)
       t))

(defun harness-tool-slots--say (ctx text)
  "Tell the session of CTX that TEXT is happening, if it listens."
  (let ((report (plist-get ctx :report)))
    (when (functionp report)
      (ignore-errors (funcall report text)))))

(defun harness-tool-slots--waited (ctx name machine seconds)
  "Tell the session of CTX that a call of NAME waited SECONDS for MACHINE.
A call that started at once says nothing.  The session hears it as
progress, so a model whose call waits knows why it is slow, and the log
keeps it for the user."
  (when (> seconds 0.05)
    (let* ((session (plist-get ctx :session-id))
           (level (harness-tool-slots--priority session))
           (text (format "Waited %.1fs for a free slot on %s (tool: %s%s)"
                         seconds (harness-tool-slots--machine-label machine) name
                         (if (eq level harness-priority-default)
                             ""
                           (format ", priority: %s" level)))))
      (harness-log 'debug "tool-slots: %s" text)
      (harness-tool-slots--say ctx text))))

(defun harness-tool-slots--finish (ticket settle value &optional machine)
  "Give back the slot TICKET holds, then settle a call with VALUE.
SETTLE is the `resolve' or `reject' function of the call's promise.  The
slot goes first, so a call waiting for it starts while this one is
worded.  SETTLE is called whatever the ticket does: a ticket that
signals -- one made before a reload, say -- must not leave the promise
pending, for the turn that waits for the call would never go on.  The
error is not hidden: it goes on to the promise library, which logs it.
MACHINE, the machine the slot is of, is said to have changed holders
once the slot is back, however the ticket went
\(`tool-slots/holders-changed').  Return nil."
  (unwind-protect
      (unwind-protect (funcall ticket)
        (when machine (harness-tool-slots--changed machine)))
    (funcall settle value))
  nil)

(defun harness-tool-slots--hold (orig tool input ctx)
  "Run ORIG for TOOL with INPUT under CTX, holding a slot of its machine.
Return a promise of ORIG's result, settled once the slot is given back,
and settled even when giving it back fails (`harness-tool-slots--finish')."
  (harness-with-promise (resolve reject)
    (let* ((name (harness-tool-name tool))
           (machine (harness-tool-slots--machine tool input ctx))
           (asked (float-time)))
      (harness-then
       (harness-tool-slots--acquire machine (plist-get ctx :session-id) name)
       (lambda (ticket)
         (condition-case err
             (progn
               (harness-tool-slots--waited ctx name machine (- (float-time) asked))
               ;; The slot goes back before the result is handled, so a
               ;; call waiting for it starts while this one is worded.
               ;; The call settles even if giving the slot back signals.
               (harness-then (funcall orig tool input ctx)
                             (lambda (value)
                               (harness-tool-slots--finish ticket resolve value machine))
                             (lambda (err)
                               (harness-tool-slots--finish ticket reject err machine))))
           (error (harness-tool-slots--finish ticket reject err machine))))
       (lambda (err) (funcall reject err))))))

(defun harness-tool-slots--run-handler (orig tool input ctx)
  "Run the handler ORIG of TOOL with INPUT under CTX, holding a slot.
Around advice for `harness-tools--run-handler': a call of a governed
tool (see `harness-tool-slots-tools') waits for a free slot before its
handler starts; a call of any other tool runs as it always did."
  (if (harness-tool-slots--governed-p tool)
      (harness-tool-slots--hold orig tool input ctx)
    (funcall orig tool input ctx)))

;;;; Who is using the slots

;; What a UI shows of the slots: for each machine, the calls that hold a
;; slot -- whose session, which tool, since when -- and those waiting,
;; in the order they will be served.  It is read off the pools as they
;; are, plain data a method can hand over (tool-slots-load's
;; `tool-slots/status'); nothing here is kept apart from the pools.

(defun harness-tool-slots--local-machine ()
  "Return the key of the machine this harness runs on.
It is the key `harness-tool-slots-default-machine' gives a call that
runs here."
  (concat "local:" (or (system-name) "machine")))

(defun harness-tool-slots--session-facts (session facts)
  "Return (NAME . PRIORITY) of SESSION, a session id or nil.
NAME is the session's name, nil when it has none or the session module
does not know it -- a session it does not know is nameless, not an
error.  PRIORITY is the level it is served at, as the line of waiting
calls goes by it (`harness-tool-slots--priority').  FACTS is a hash
table of what was found already, which is where a session is looked up
once: one with a dozen calls at work asks the session module once."
  (or (gethash session facts)
      (puthash session
               (cons (and (stringp session)
                          (harness-method-exists-p 'session/get)
                          (condition-case nil
                              (let ((name (plist-get (harness-call 'session/get session) :name)))
                                (and (stringp name) (not (string-blank-p name)) name))
                            (error nil)))
                     (harness-tool-slots--priority session))
               facts)))

(defun harness-tool-slots--user (data facts)
  "Return what is known of the call that asked a pool with DATA, as a plist.
That is its :session, the :name of that session, the :tool and the
:priority the session is served at now, as a level's name; FACTS is as
for `harness-tool-slots--session-facts'."
  (let* ((session (harness-tool-slots--data-field data :session))
         (known (harness-tool-slots--session-facts session facts)))
    (list :session session
          :name (car known)
          :tool (harness-tool-slots--data-field data :tool)
          :priority (symbol-name (cdr known)))))

(defun harness-tool-slots--machine-state (machine pool facts)
  "Return who is using the slots of MACHINE, whose slots are POOL, as a plist.
POOL is nil for a machine that has used none yet.  FACTS is as for
`harness-tool-slots--session-facts'.  The plist is described by
`harness-tool-slots-machines'."
  (list :machine machine
        :label (harness-tool-slots--machine-label machine)
        :limit (if pool (harness-slots-limit pool) (harness-tool-slots--slots machine))
        :running (if pool (harness-slots-running pool) 0)
        :holders (and pool
                      (mapcar (lambda (holder)
                                (append (harness-tool-slots--user (plist-get holder :data) facts)
                                        (list :started (plist-get holder :started))))
                              (harness-slots-holders pool)))
        :waiters (and pool
                      (mapcar (lambda (waiter)
                                (append (harness-tool-slots--user (plist-get waiter :data) facts)
                                        (list :asked (plist-get waiter :asked))))
                              (harness-slots-line pool)))))

(defun harness-tool-slots-machines ()
  "Return who is using the tool slots, a plist for each machine in use.
The machines are this one, always, and then every other that has a call
holding a slot or waiting for one, by name.  Each plist has
  :machine  the machine's key, \"local:NAME\" or \"host:NAME\"
  :label    how a person reads it: \"this machine\", or the host
  :limit    how many calls may run at once on it now
  :running  how many calls hold a slot, as the machine's pool counts them
  :holders  the calls holding a slot, the one that has held it longest
            first, each a plist of :session (the id of the session it
            serves, nil for the harness's own call), :name (that
            session's name, nil without one), :tool (the tool's name),
            :priority (the session's, \"low\", \"medium\" or \"high\") and
            :started (when it took the slot, a float time)
  :waiters  the calls waiting, in the order they will be served, each
            such a plist with :asked, when it began to wait, in place of
            :started
Calls that took their slot before a reload may not be listed: the pool
did not note them then, though it counts them.  Asking changes nothing."
  (let* ((facts (make-hash-table :test 'equal))
         (local (harness-tool-slots--local-machine))
         (others (cl-loop for machine being the hash-keys of harness-tool-slots--machines
                          using (hash-values pool)
                          when (and (not (consp pool))
                                    (not (equal machine local))
                                    (or (> (harness-slots-running pool) 0)
                                        (> (harness-slots-waiting pool) 0)))
                          collect machine)))
    (mapcar (lambda (machine)
              (let ((pool (gethash machine harness-tool-slots--machines)))
                (harness-tool-slots--machine-state
                 machine (and pool (not (consp pool)) pool) facts)))
            (cons local (sort others #'string<)))))

;;;; The module

(defun harness-tool-slots--init ()
  "Hold slots for the calls of the governed tools."
  (unless (advice-member-p #'harness-tool-slots--run-handler 'harness-tools--run-handler)
    (advice-add 'harness-tools--run-handler :around #'harness-tool-slots--run-handler)))

(defun harness-tool-slots--shutdown ()
  "Stop holding slots, letting every call that waits run at once."
  (advice-remove 'harness-tools--run-handler #'harness-tool-slots--run-handler)
  (dolist (machine (hash-table-keys harness-tool-slots--machines))
    (harness-slots-flush (harness-tool-slots--pool machine))
    (harness-tool-slots--changed machine)))

(harness-define-module 'tool-slots
  :doc "A few slots per machine for the tools that start processes."
  :requires '(tools)
  :init #'harness-tool-slots--init
  :shutdown #'harness-tool-slots--shutdown)

(provide 'harness-tool-slots)
;;; harness-tool-slots.el ends here
