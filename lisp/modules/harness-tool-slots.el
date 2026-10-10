;;; harness-tool-slots.el --- A few slots per machine for the tools that start processes  -*- lexical-binding: t; -*-

;;; Commentary:

;; Some tools start whole process trees.  bash runs a shell command --
;; a build, the test suite, or scripts/dev.sh, which starts another
;; Emacs with the harness in it.  elisp starts a batch Emacs for every
;; call, ssh runs a command on another host, and open_harness starts a
;; checkout's development Emacs.  One such call is meant to use the
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

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
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

(defcustom harness-tool-slots-tools '("bash" "elisp" "ssh" "open_harness")
  "Tools whose calls hold a slot of the machine they run on.
They are the tools that start processes: a shell command (which may be
a build, a test run, or a script that starts more Emacs), a batch
Emacs, a command on another host, and a checkout's development Emacs.
A tool that is not listed never waits.  Add a tool of your own that
starts processes, or take one of these out to let it run freely."
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
  "Machine key -> its slots, as (RUNNING . WAITERS).
WAITERS holds the plist of each call waiting for a slot (`:promise' and
the `:session' it serves), oldest first; the priority decides among
them which is served next (`harness-tool-slots--next').  A machine
keeps its key once its last call is done: it holds a count and a
list.")

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

(defun harness-tool-slots--state (machine)
  "Return the slots of MACHINE, making them when it has none yet."
  (or (gethash machine harness-tool-slots--machines)
      (puthash machine (cons 0 nil) harness-tool-slots--machines)))

(defun harness-tool-slots--ticket (machine)
  "Return the function that gives one slot of MACHINE back, once."
  (let ((given nil))
    (lambda ()
      (unless given
        (setq given t)
        (harness-tool-slots--give machine)))))

(defun harness-tool-slots--priority (session)
  "Return the priority of SESSION, a session id or nil, as a level.
A call that has no session at all -- the harness itself asked -- waits
as `harness-priority-default' does."
  (if session (harness-priority-of session) harness-priority-default))

(defun harness-tool-slots--rank-of (waiter)
  "Return the rank of WAITER, a call waiting for a slot.
That is its session's priority as it is now, so raising a session's
priority moves the calls it already has waiting."
  (harness-priority-rank (harness-tool-slots--priority (plist-get waiter :session))))

(defun harness-tool-slots--next (waiters)
  "Return the call of WAITERS that takes the next free slot.
That is the highest priority session's call, the oldest of those first
\(`harness-priority-above-p'): WAITERS is in the order the calls
arrived, so the first of the highest rank is the oldest."
  (let ((best (car waiters))
        (best-rank (harness-tool-slots--rank-of (car waiters))))
    (dolist (waiter (cdr waiters))
      (let ((rank (harness-tool-slots--rank-of waiter)))
        (when (> rank best-rank)
          (setq best waiter best-rank rank))))
    best))

(defun harness-tool-slots--admit (machine)
  "Start the calls waiting for MACHINE while it has free slots.
The calls waiting go by priority, the oldest first among equals
\(`harness-tool-slots--next').  A module that raises a machine's limit
while calls wait calls this, so they start without waiting for another
call to finish."
  (let* ((state (harness-tool-slots--state machine))
         (slots (harness-tool-slots--slots machine)))
    (while (and (cdr state) (< (car state) slots))
      (let ((waiter (harness-tool-slots--next (cdr state))))
        (setcdr state (delq waiter (cdr state)))
        (setcar state (1+ (car state)))
        (harness-resolve (plist-get waiter :promise)
                         (harness-tool-slots--ticket machine))))))

(defun harness-tool-slots--give (machine)
  "Give one slot of MACHINE back and start its next waiting call, if one waits.
The calls waiting go by priority, the oldest first among equals
\(`harness-tool-slots--next')."
  (let* ((state (harness-tool-slots--state machine)))
    (setcar state (max 0 (1- (car state))))
    (harness-tool-slots--admit machine)))

(defun harness-tool-slots--acquire (machine session)
  "Return a promise of a ticket for a slot of MACHINE for a call of SESSION.
It resolves at once when MACHINE has a free slot, and otherwise when
one is given back to it, by SESSION's priority then, oldest first among
equals (`harness-tool-slots--give')."
  (let ((state (harness-tool-slots--state machine)))
    (if (< (car state) (harness-tool-slots--slots machine))
        (progn
          (setcar state (1+ (car state)))
          (harness-resolved (harness-tool-slots--ticket machine)))
      (let ((promise (harness-make-promise)))
        (setcdr state (nconc (cdr state)
                             (list (list :promise promise :session session))))
        promise))))

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

(defun harness-tool-slots--hold (orig tool input ctx)
  "Run ORIG for TOOL with INPUT under CTX, holding a slot of its machine.
Return a promise of ORIG's result, settled once the slot is given back."
  (harness-with-promise (resolve reject)
    (let* ((name (harness-tool-name tool))
           (machine (harness-tool-slots--machine tool input ctx))
           (asked (float-time)))
      (harness-then
       (harness-tool-slots--acquire machine (plist-get ctx :session-id))
       (lambda (ticket)
         (condition-case err
             (progn
               (harness-tool-slots--waited ctx name machine (- (float-time) asked))
               ;; The slot goes back before the result is handled, so a
               ;; call waiting for it starts while this one is worded.
               (harness-then (funcall orig tool input ctx)
                             (lambda (value) (funcall ticket) (funcall resolve value))
                             (lambda (err) (funcall ticket) (funcall reject err))))
           (error (funcall ticket) (funcall reject err))))
       (lambda (err) (funcall reject err))))))

(defun harness-tool-slots--run-handler (orig tool input ctx)
  "Run the handler ORIG of TOOL with INPUT under CTX, holding a slot.
Around advice for `harness-tools--run-handler': a call of a governed
tool (see `harness-tool-slots-tools') waits for a free slot before its
handler starts; a call of any other tool runs as it always did."
  (if (harness-tool-slots--governed-p tool)
      (harness-tool-slots--hold orig tool input ctx)
    (funcall orig tool input ctx)))

;;;; The module

(defun harness-tool-slots--init ()
  "Hold slots for the calls of the governed tools."
  (unless (advice-member-p #'harness-tool-slots--run-handler 'harness-tools--run-handler)
    (advice-add 'harness-tools--run-handler :around #'harness-tool-slots--run-handler)))

(defun harness-tool-slots--shutdown ()
  "Stop holding slots, letting every call that waits run at once."
  (advice-remove 'harness-tools--run-handler #'harness-tool-slots--run-handler)
  (dolist (machine (hash-table-keys harness-tool-slots--machines))
    (let* ((state (gethash machine harness-tool-slots--machines))
           (waiters (prog1 (cdr state) (setcdr state nil))))
      (setcar state 0)
      (dolist (waiter waiters)
        (harness-resolve (plist-get waiter :promise)
                         (harness-tool-slots--ticket machine))))))

(harness-define-module 'tool-slots
  :doc "A few slots per machine for the tools that start processes."
  :requires '(tools)
  :init #'harness-tool-slots--init
  :shutdown #'harness-tool-slots--shutdown)

(provide 'harness-tool-slots)
;;; harness-tool-slots.el ends here
