;;; harness-tool-slots-load.el --- Fewer tool slots while this machine is busy  -*- lexical-binding: t; -*-

;;; Commentary:

;; The tool-slots plugin caps how many calls of the tools that start
;; processes run at once on one machine: one slot per processor plus a
;; slight burst.  That number is sized for a machine with nothing else
;; to do.  While the machine is busy -- a build, a test run, a game --
;; every slot it hands out is one more process tree the user's own work
;; shares the processors with, and the commands only queue up anyway.
;;
;; So this plugin watches this machine's load average (`load-average',
;; the same numbers /proc/loadavg shows on GNU/Linux) and lowers the
;; slots it allows while the load is high, restoring the configured
;; limit as the load falls.  It reads two averages.  The longer one
;; (`harness-tool-slots-load-window', the 5-minute average by default)
;; follows the load that lasts, such as a build, and sets the limit as
;; it always did.  The shorter one (`harness-tool-slots-load-short-window',
;; the 1-minute average by default) moves with every test run or
;; compile, and may only lower the limit below what the longer one
;; allows: it never gives a slot back.  A burst of work therefore takes
;; slots away at once, even while the 5-minute average has hardly
;; moved.  The load is read per processor: 1.0 means one processor's
;; worth of runnable work on each processor, and at
;; `harness-tool-slots-load-high' -- 2.0 by default -- the limit is
;; down to `harness-tool-slots-load-floor', one slot, so the work still
;; goes on, slowly.
;;
;; It only ever lowers the limit.  The number in force is the smaller
;; of the baseline (`harness-tool-slots-count' plus the burst) and what
;; the load allows, so it is never more than the tool-slots plugin
;; would hand out on its own, and at low load it is the baseline
;; exactly.  The load is sampled often and the limit changed rarely: a
;; change is taken only once the load has moved away from the load that
;; took the last one by `harness-tool-slots-load-deadband', and then at
;; most once per `harness-tool-slots-load-cooldown', so a spike does
;; not make the slots flap.  Lowering stays that fast.  A limit the
;; shorter average has pulled down comes back slowly, though: it rises
;; by `harness-tool-slots-load-recovery-step' slots at a time, and only
;; once per `harness-tool-slots-load-recovery-cooldown', up to what the
;; longer average allows -- so the slots a short burst took are not
;; given back at once merely because the burst is over, and a machine
;; that stays quiet gets them all back after a few of those steps.  A
;; limit the longer average alone took still comes back as it did.  On
;; a rise the calls already waiting start at once, up to what now fits;
;; on a fall the calls running are left alone and no new one starts
;; until the machine is under the limit again.
;;
;; Only this machine is watched.  A call on another host -- over TRAMP
;; or through the ssh tool -- runs on a machine whose load this harness
;; cannot read, and keeps that host's baseline slots.
;;
;; Whenever the effective number changes, down or back up, every active
;; session is told as a system message, so the user sees why calls are
;; waiting: "Tool slots reduced from 18 to 5: system load 1.8x on this
;; machine".  A load that moves a lot would fill every transcript with
;; them, so the changes of one stretch share one message per session.
;; The first is a hint as above; a change that follows within ten
;; minutes of the last is added to that hint instead of a new one,
;; whatever else the session has done meanwhile, and the chat draws it
;; as one line, "Slots changed due to system load (3 changes)", that
;; opens to the changes with the time of each.  After a quieter spell
;; the next change starts a hint of its own, so the transcript still
;; shows where in the session's work the load moved.  The hint is a
;; folding one (`harness-node-fold').  A session's model is never sent
;; hints, so none of this changes what it reads.
;;
;; That note is the history, and it stands where the first change of its
;; stretch landed.  How the slots stand now is the machine's, not a
;; session's: the `tool-slots/status' method gives it, and the event
;; `tool-slots/changed' announces every change -- the watch ending too --
;; so that a UI can show it, as the chat does while the slots are held
;; back, pinned above its compose box (ui-tool-slots-load).
;;
;; The state also says who is using the slots: for each machine, which
;; session's call of which tool holds each slot and since when, and who
;; waits, in the order they will be served, at what priority
;; (`harness-tool-slots-machines').  That moves with every call that
;; starts, waits or ends, far more often than the limit, so the event
;; for it is held back a moment (`harness-tool-slots-load--notify-delay')
;; and is one for however many calls came and went meanwhile, with the
;; state as it is when it is sent: a UI that shows the users of the
;; slots, as the task slots page does, is brought up to date by it, and
;; the sessions are told nothing.
;;
;; The limit is modulated by around advice on
;; `harness-tool-slots--slots', which is where the tool-slots plugin
;; asks how many calls a machine may run; the extension point is the
;; machine that function now takes.  Disable the module
;; (`harness-disabled-modules'), or set
;; `harness-tool-slots-load-enabled' to nil, to stop watching the load:
;; the limit is the baseline again, as plain tool-slots leaves it.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-tool-slots)

(defcustom harness-tool-slots-load-enabled t
  "Whether this machine's load lowers the tool slots it is allowed.
On, the module samples the load average and holds back governed tool
calls while the machine is busy (see the tool-slots plugin); off, the
limit is what `harness-tool-slots-count' and `harness-tool-slots-burst'
say.  Disabling the module itself (`harness-disabled-modules') does the
same and stops the sampling."
  :type 'boolean
  :group 'harness)

(defcustom harness-tool-slots-load-window 5
  "Which load average the long-term watch reads: over 1, 5 or 15 minutes.
These are the three averages `load-average' reports.  The 5-minute
average, the default, follows the load that lasts.  A test run or a
compile of a minute or two moves it a little, so the limit is not
taken away by every burst of work, while a build that goes on lowers
it within a few minutes, and it comes back a few minutes after it is
over.  This average sets the limit, and only it can allow more slots
than the load does now; the short-term watch
\(`harness-tool-slots-load-short-window') may only lower that number.
The 1-minute average reacts to every burst at once; the 15-minute one
is steadier still, and slower to give the slots back."
  :type '(choice (const :tag "1 minute" 1)
                 (const :tag "5 minutes" 5)
                 (const :tag "15 minutes" 15))
  :group 'harness)

(defcustom harness-tool-slots-load-short-window 1
  "Which load average the short-term watch reads: over 1, 5 or 15 minutes.
These are the three averages `load-average' reports, and the default
is the 1-minute one, which reacts to a test run or a compile at once.
This average never raises the limit: it may only lower it below what
the long-term watch (`harness-tool-slots-load-window') allows.  A drop
of this average does not give the slots back at once either; a limit
it pulled down recovers a step at a time
\(`harness-tool-slots-load-recovery-step',
`harness-tool-slots-load-recovery-cooldown').  Set it to the same
average as `harness-tool-slots-load-window' to give neither watch the
edge over the other."
  :type '(choice (const :tag "1 minute" 1)
                 (const :tag "5 minutes" 5)
                 (const :tag "15 minutes" 15))
  :group 'harness)

(defcustom harness-tool-slots-load-low 1.0
  "Load per processor at or below which every slot is allowed.
The load is the average `harness-tool-slots-load-function' reports for
each watch -- `harness-tool-slots-load-window' and
`harness-tool-slots-load-short-window' -- divided by the processor
count, so 1.0 is one processor's worth of runnable work per processor.
At or below this the limit is the baseline; above it the slots go down
with the load."
  :type 'number
  :group 'harness)

(defcustom harness-tool-slots-load-high 2.0
  "Load per processor at or above which only the floor is allowed.
Between `harness-tool-slots-load-low' and this the slots fall with the
load, reaching `harness-tool-slots-load-floor' here.  At 2.0 the
machine has twice the runnable work its processors can run."
  :type 'number
  :group 'harness)

(defcustom harness-tool-slots-load-floor 1
  "How few slots this machine keeps under load.
Never below 1, and never above the baseline: the module only lowers the
limit and restores it, so a slot is always left for the work to go on,
slowly, however loaded the machine is."
  :type 'integer
  :group 'harness)

(defcustom harness-tool-slots-load-interval 5.0
  "Seconds between load samples.
The load is sampled this often (`harness-tool-slots-load-function'),
but the limit itself changes at most once per
`harness-tool-slots-load-cooldown'."
  :type 'number
  :group 'harness)

(defcustom harness-tool-slots-load-cooldown 30.0
  "Seconds the modulated limit stays put after it changes.
A sample within the cooldown is read, and the limit does not change, so
a short spike cannot make the slots flap.  A fall waits for the
cooldown as a rise does, which also keeps the sessions from being told
about a change that is over by the next sample.  A rise of a limit the
short-term watch lowered waits for
`harness-tool-slots-load-recovery-cooldown' instead."
  :type 'number
  :group 'harness)

(defcustom harness-tool-slots-load-recovery-step 1
  "How many slots a limit the short-term watch lowered gains at a time.
A limit the short-term load pulled below what the long-term load
allows comes back slowly: it rises by this many slots, and no more,
each time `harness-tool-slots-load-recovery-cooldown' is over, until
it reaches what the long-term load allows.  At least one slot is given
back at a time."
  :type 'integer
  :group 'harness)

(defcustom harness-tool-slots-load-recovery-cooldown 120.0
  "Seconds a limit the short-term watch lowered waits before it rises.
Each rise gives back `harness-tool-slots-load-recovery-step' slots,
and the next waits this long again, so a short burst of load does not
give all the slots back at once when it is over.  The ordinary
`harness-tool-slots-load-cooldown' holds too.  Lowering is not held
back by this: it waits only for `harness-tool-slots-load-cooldown'.
A limit the long-term load alone lowered comes back as it always did."
  :type 'number
  :group 'harness)

(defcustom harness-tool-slots-load-deadband 0.15
  "Least change in load per processor that takes a new limit.
A change is taken only when the load has moved this far from the load
that took the last one, in the direction of the change, so noise around
a threshold does not move the slots.  A rise back to the baseline is
taken as soon as the load is at or below
`harness-tool-slots-load-low', deadband or not, so a quiet machine
always gets its full limit back -- unless the short-term watch pulled
the limit down, which recovers in steps instead
\(`harness-tool-slots-load-recovery-cooldown')."
  :type 'number
  :group 'harness)

(defun harness-tool-slots-load-default-load (&optional window)
  "Return this machine's load average over WINDOW minutes, or nil.
WINDOW is 1, 5 or 15, and nil means `harness-tool-slots-load-window'.
Those are the only averages the system keeps: a window of a minute or
less reads the 1-minute one, a window of 15 minutes or more the
15-minute one, and any other window -- 10, say -- the 5-minute one, the
default.  The value is what `load-average' reports, the numbers
/proc/loadavg shows on GNU/Linux.  A system that does not keep the
longer averages reports fewer of them, and the longest one it has is
read instead.  A system that cannot report its load at all gives nil,
which leaves the limit alone."
  (condition-case err
      (let* ((loads (load-average t))
             (window (or window harness-tool-slots-load-window))
             (index (cond ((not (numberp window)) 1)
                          ((<= window 1) 0)
                          ((>= window 15) 2)
                          (t 1))))
        (or (nth index loads) (car (last loads))))
    (error (harness-log 'debug "tool-slots-load: no load average: %s"
                        (harness-error-message err))
           nil)))

(defvar harness-tool-slots-load-function #'harness-tool-slots-load-default-load
  "Function returning this machine's load average, or nil.
Called with one argument, the window in minutes
\(`harness-tool-slots-load-window'); it returns the load average as a
number, or nil when the machine cannot say.  Set it -- or bind it in a
test -- to watch something else than `load-average'.")

;;;; The load, and the limit it allows

(defvar harness-tool-slots-load--limit nil
  "This machine's slot limit as the load last set it, or nil.
nil means the baseline, `harness-tool-slots--baseline'; a number is
what the load allows, never above the baseline.")

(defvar harness-tool-slots-load--changed-at nil
  "Time the limit last changed, or nil while it has never changed.")

(defvar harness-tool-slots-load--changed-pressure nil
  "Load per processor when the limit last changed, or nil.
It is the reading of whichever watch -- long or short -- took the
limit there, so a deadband measured from it is that watch's own.")

(defvar harness-tool-slots-load--short-limited nil
  "Non-nil while the short-term load holds the limit below the long-term one.
It is set when the short-term watch takes slots away that the long-term
watch would not, and cleared once the limit has climbed back to what
the long-term watch allows.  While it is set, the limit rises only in
`harness-tool-slots-load-recovery-step' steps, one per
`harness-tool-slots-load-recovery-cooldown', and the quiet-machine
shortcut does not restore the baseline at once.")

(defvar harness-tool-slots-load--changed-text nil
  "What the sessions were told when the limit last changed, or nil.
The same line the sessions' note holds (`harness-tool-slots-load--notice'),
for a UI that shows the slots as they are now.")

(defvar harness-tool-slots-load--timer nil
  "The repeating timer that samples the load, or nil when it is off.")

(defun harness-tool-slots-load--pressure-at (window)
  "Return this machine's load per processor over WINDOW, or nil.
WINDOW is the average to read, in minutes, and nil means
`harness-tool-slots-load-window'.  An unreadable load -- `load-average'
signals, or the load function says nothing useful -- is nil, and a
limit is never lowered for it."
  (let ((load (condition-case err
                  (funcall harness-tool-slots-load-function
                           (or window harness-tool-slots-load-window))
                (error (harness-log 'debug "tool-slots-load: %s"
                                    (harness-error-message err))
                       nil))))
    (when (and (numberp load) (>= load 0))
      (/ (float load) (max 1 (num-processors))))))

(defun harness-tool-slots-load--pressure ()
  "Return this machine's load per processor over the long-term window.
That is `harness-tool-slots-load-window' minutes, the load that sets
the limit.  A load it cannot read is nil, and the limit is left alone."
  (harness-tool-slots-load--pressure-at harness-tool-slots-load-window))

(defun harness-tool-slots-load--short-pressure ()
  "Return this machine's load per processor over the short-term window.
That is `harness-tool-slots-load-short-window' minutes, the load that
may only lower the limit.  A load it cannot read is nil; it then has
nothing to say, and only the long-term load sets the limit."
  (harness-tool-slots-load--pressure-at harness-tool-slots-load-short-window))

(defun harness-tool-slots-load--cap (pressure baseline)
  "Return the slots PRESSURE allows on this machine, at most BASELINE.
That is BASELINE at or below `harness-tool-slots-load-low', the floor
\(`harness-tool-slots-load-floor', never below 1) at or above
`harness-tool-slots-load-high', and between them as many slots as the
load leaves of the room between the two, so more load never means more
slots.  BASELINE is never exceeded whatever the options say."
  (let* ((floor (max 1 (min baseline (or harness-tool-slots-load-floor 1))))
         (low (float (or harness-tool-slots-load-low 1.0)))
         (high (float (or harness-tool-slots-load-high 2.0)))
         (room (- baseline floor)))
    (cond ((<= room 0) baseline)
          ((<= pressure low) baseline)
          ((>= pressure high) floor)
          (t (max floor
                  (- baseline
                     (ceiling (* room (/ (- pressure low)
                                         (max 1e-9 (- high low)))))))))))

(defun harness-tool-slots-load--local-p (machine)
  "Non-nil when MACHINE is the machine this harness runs on.
The tool-slots plugin keys this machine \"local:NAME\"; a host reached
over TRAMP or ssh is \"host:HOST\", and its load is not ours to read."
  (and (stringp machine) (string-prefix-p "local:" machine)))

(defun harness-tool-slots-load--slots-advice (orig &optional machine)
  "Return the slots MACHINE may run, lowered while this machine is busy.
Around advice for `harness-tool-slots--slots': a \"local:\" machine --
the one this harness runs on -- is held to what the load allows, while
any other keeps ORIG's number, the baseline, as its load is not this
machine's to read."
  (let ((baseline (funcall orig machine)))
    (if (and harness-tool-slots-load-enabled
             harness-tool-slots-load--limit
             (harness-tool-slots-load--local-p machine))
        (min baseline harness-tool-slots-load--limit)
      baseline)))

;;;; Taking a change

(defun harness-tool-slots-load--cooled-p ()
  "Non-nil when the limit may change again after a change."
  (or (null harness-tool-slots-load--changed-at)
      (>= (- (float-time) harness-tool-slots-load--changed-at)
          (max 0 (float harness-tool-slots-load-cooldown)))))

(defun harness-tool-slots-load--recovered-p ()
  "Non-nil when a short-term-lowered limit may rise another step.
That waits `harness-tool-slots-load-recovery-cooldown' after the last
change, longer than `harness-tool-slots-load-cooldown' keeps a fall
from flapping."
  (or (null harness-tool-slots-load--changed-at)
      (>= (- (float-time) harness-tool-slots-load--changed-at)
          (max 0 (float (or harness-tool-slots-load-recovery-cooldown 0))))))

(defun harness-tool-slots-load--moved-p (pressure cap current baseline)
  "Non-nil when PRESSURE has moved enough for CAP to replace CURRENT.
That is `harness-tool-slots-load-deadband' away from the load the last
change was taken at, in the direction of this one; a CAP that restores
BASELINE is taken as soon as the load is at or below
`harness-tool-slots-load-low', so a quiet machine is not held short.
The first change is taken at once."
  (let ((last harness-tool-slots-load--changed-pressure)
        (band (max 0 (float harness-tool-slots-load-deadband))))
    (or (null last)
        (if (< cap current)
            (>= pressure (+ last band))
          (or (and (= cap baseline)
                   (<= pressure (float (or harness-tool-slots-load-low 1.0))))
              (<= pressure (- last band)))))))

(defun harness-tool-slots-load--admit ()
  "Start the calls waiting on this machine, up to the limit it has now.
The calls run by session priority, as the tool-slots plugin serves
them; when the limit fell, none fits and none starts."
  (dolist (machine (hash-table-keys harness-tool-slots--machines))
    (when (harness-tool-slots-load--local-p machine)
      (harness-tool-slots--admit machine))))

(defun harness-tool-slots-load--notice (old new pressure)
  "Return one line saying this machine's slots went from OLD to NEW.
PRESSURE is the load per processor that decided it, nil when the load
watch was turned off."
  (cond ((< new old)
         (format "Tool slots reduced from %d to %d: system load %.1fx on this machine"
                 old new pressure))
        ((null pressure)
         (format "Tool slots restored to %d: the load watch is off" new))
        ((= new (harness-tool-slots--baseline))
         (format "Tool slots restored to %d: system load back to normal" new))
        (t (format "Tool slots raised from %d to %d: system load %.1fx on this machine"
                   old new pressure))))

;;;; One note per stretch of changes
;;
;; A session is told of a change in a hint, and a load that moves a lot
;; moves the slots a lot: a hint to each change would fill the
;; transcript, and split the runs of tool calls the chat folds into one
;; summary.  So the changes of one stretch share a hint, the session's
;; note of slot changes: a folding hint (`harness-node-fold') holding a
;; line to a change, which the chat draws as one line that opens to
;; them.  A change is added to the note the session has when that
;; note's last change is recent, wherever in the transcript the note
;; is -- tool calls and messages may have come since -- and a change
;; that comes later than that starts a note of its own.

(defconst harness-tool-slots-load--note-key "tool-slots-load"
  "The `:key' of the fold of a session's note of slot changes.
It tells this module's notes from other hints that fold.")

(defconst harness-tool-slots-load--note-title "Slots changed due to system load"
  "What a note of slot changes says while it is folded, before the count.")

(defvar harness-tool-slots-load--note-window 600.0
  "Seconds a note of slot changes stays open to the next change.
A change that comes this soon after the note's last is added to the
note; a later one starts another.  A load that moves back and forth
within minutes therefore makes one note, and a build an hour on, with
the machine quiet between, a note of its own.")

(defvar harness-tool-slots-load--note-limit 20
  "Most changes one note of slot changes holds.
A note this full is closed, and the next change starts another: a load
that moves for hours would otherwise write one ever longer note anew
at every change.  With the default options the load of a build, from
idle to full and back, changes the slots fewer times than that, each
`harness-tool-slots-load-deadband' of load being one change at most,
and the stepwise recovery of a short-term cut one change per step, so
a build is one note.")

(defun harness-tool-slots-load--note-count-title (items)
  "Return the title of a note holding ITEMS: the title, and how many changes.
A note of one change is that change's own line in the chat, so its
title is only the title."
  (if (cdr items)
      (format "%s (%d changes)" harness-tool-slots-load--note-title (length items))
    harness-tool-slots-load--note-title))

(defun harness-tool-slots-load--note-text (items)
  "Return the plain text of a note holding ITEMS, for what does not fold.
One change reads as its own line, as the hint of a single change always
did; several read as the title and a line to a change, with its time."
  (if (null (cdr items))
      (plist-get (car items) :text)
    (concat (harness-tool-slots-load--note-count-title items) "\n"
            (mapconcat (lambda (item)
                         (let ((ts (plist-get item :ts)))
                           (concat (if ts (format-time-string "%H:%M:%S  " ts) "")
                                   (plist-get item :text))))
                       items "\n"))))

(defun harness-tool-slots-load--note-meta (meta items)
  "Return META, a node's `:meta', with the fold of a note holding ITEMS."
  (plist-put (copy-sequence meta) :fold
             (list :key harness-tool-slots-load--note-key
                   :title (harness-tool-slots-load--note-count-title items)
                   :items items)))

(defun harness-tool-slots-load--open-note (id now)
  "Return session ID's note that a change at NOW is added to, or nil.
That is the session's newest note of slot changes on the branch its
transcript is on, when its last change is less than
`harness-tool-slots-load--note-window' old and it holds fewer than
`harness-tool-slots-load--note-limit' changes.  A newer note that is
closed is the last word: an older one is older still."
  (cl-loop for node in (reverse (harness-call 'session/nodes id))
           for fold = (and (eq (plist-get node :kind) 'hint) (harness-node-fold node))
           when (and fold (equal (plist-get fold :key) harness-tool-slots-load--note-key))
           return (let* ((items (plist-get fold :items))
                         (last (plist-get (car (last items)) :ts)))
                    (and (< (length items) harness-tool-slots-load--note-limit)
                         (numberp last)
                         (< (- now last) harness-tool-slots-load--note-window)
                         node))))

(defun harness-tool-slots-load--note-add (id node text now)
  "Add the change TEXT, at NOW, to NODE, the note of session ID."
  (let ((items (append (plist-get (harness-node-fold node) :items)
                       (list (list :ts now :text text)))))
    (harness-call 'session/update-node id (plist-get node :id)
                  :content (harness-tool-slots-load--note-text items)
                  :meta (harness-tool-slots-load--note-meta (plist-get node :meta) items))))

(defun harness-tool-slots-load--note-start (id text now)
  "Start a note of slot changes in session ID, with the change TEXT at NOW."
  (let ((items (list (list :ts now :text text))))
    (harness-call 'session/append id
                  (list :kind 'hint
                        :content (harness-tool-slots-load--note-text items)
                        :meta (harness-tool-slots-load--note-meta nil items)))))

(defun harness-tool-slots-load--note (id text now)
  "Tell session ID of the change TEXT, at NOW, in its note of slot changes.
The change joins the session's open note (see
`harness-tool-slots-load--open-note'), or starts a note when there is
none.  A note that cannot be added to -- it went while this was on its
way -- is no reason to leave the session untold: the change starts a
new one."
  (let ((open (harness-tool-slots-load--open-note id now)))
    (or (and open
             (condition-case err
                 (progn (harness-tool-slots-load--note-add id open text now) t)
               (error (harness-log 'debug "tool-slots-load: no adding to the note of %s: %s"
                                   id (harness-error-message err))
                      nil)))
        (harness-tool-slots-load--note-start id text now))))

(defun harness-tool-slots-load--announce (text)
  "Tell every active session of the change TEXT, in its note of slot changes.
A session that is closed, or inactive, is left alone; a session that
goes while the message is on its way is skipped."
  (when (and (harness-method-exists-p 'session/list)
             (harness-method-exists-p 'session/nodes)
             (harness-method-exists-p 'session/append)
             (harness-method-exists-p 'session/update-node))
    (let ((now (float-time)))
      (dolist (session (harness-call 'session/list (list :active t)))
        (let ((id (plist-get session :id)))
          (when (and (stringp id) (not (eq (plist-get session :status) 'inactive)))
            (condition-case err
                (harness-tool-slots-load--note id text now)
              (error (harness-log 'debug "tool-slots-load: %s not told: %s"
                                  id (harness-error-message err))))))))))

;;;; The slots as they are now

;; The notes in the sessions' transcripts are the history of the slots
;; changing.  What a person watching a chat wants to know is how many
;; there are now, so a UI shows that pinned above the compose box while
;; they are held back (harness-ui-tool-slots-load.el).  It gets the
;; state from `tool-slots/status' when it connects and hears of every
;; change as `tool-slots/changed'.

(defun harness-tool-slots-load--state ()
  "Return the tool slots as a UI shows them.
That is (:limit N :baseline B :pressure P :text TEXT :at TIME :machines
MACHINES): N the slots in force on this machine, B the most there are
-- the machine is held back while N is under B -- and, of the change
that took N, P the load per processor that decided it, TEXT what the
sessions were told and TIME when.  The three are nil before the first
change, and P when the watch was turned off.  MACHINES is who is using
the slots, machine by machine (`harness-tool-slots-machines')."
  (let ((baseline (harness-tool-slots--baseline)))
    (list :limit (min baseline (or harness-tool-slots-load--limit baseline))
          :baseline baseline
          :pressure harness-tool-slots-load--changed-pressure
          :text harness-tool-slots-load--changed-text
          :at harness-tool-slots-load--changed-at
          :machines (harness-tool-slots-machines))))

(harness-defmethod tool-slots/status ()
  "Return the tool slots: (:limit :baseline :pressure :text :at :machines).
:limit is how many calls of the governed tools may run at once on this
machine now and :baseline how many would without the load watch, so the
machine is held back while :limit is the smaller.  :pressure is the load
per processor that took the limit, :text what the sessions were told of
it and :at when, as `tool-slots/changed' announces them.  :machines
says who is using the slots, a plist for this machine and for every
other that has a call holding a slot or waiting for one: :machine (its
key), :label, :limit, :running (how many calls hold a slot) and the
calls themselves, :holders, the longest at work first, each a plist of
:session (its id), :name (the session's), :tool, :priority and :started
\(a float time), and :waiters, in the order they will be served, the
same with :asked, when the call began to wait, in place of :started."
  (harness-tool-slots-load--state))

(harness-declare-event 'tool-slots/changed
  "(STATE) once the slots changed -- this machine's limit, the watch ending, who holds a slot or waits for one: STATE as `tool-slots/status' gives it.")

(defvar harness-tool-slots-load--notify-delay 0.2
  "Seconds a change of who holds a slot waits before `tool-slots/changed' says so.
Calls come and go in bursts -- a dozen sessions starting a test run each
-- and one announcement carries them all.  The state is read when it is
sent, not when the first call came, so nothing is left out; and a
steady stream of calls still gets one every this many seconds, since the
delay runs from the first change, not the last.")

(defvar harness-tool-slots-load--notify-timer nil
  "The timer that will announce who holds the slots, or nil when none is due.")

(defun harness-tool-slots-load--notify-now ()
  "Announce the tool slots as they are now, for a change of who holds them."
  (setq harness-tool-slots-load--notify-timer nil)
  (harness-emit 'tool-slots/changed (harness-tool-slots-load--state)))

(defun harness-tool-slots-load--notify-soon (&rest _)
  "Have `tool-slots/changed' say soon that who holds a slot, or waits, changed.
On `tool-slots/holders-changed', with the machine, which it needs not.
Once for the changes of the next `harness-tool-slots-load--notify-delay'
seconds: while a timer is due, a change is already on its way."
  (unless (timerp harness-tool-slots-load--notify-timer)
    (setq harness-tool-slots-load--notify-timer
          (run-at-time (max 0 harness-tool-slots-load--notify-delay) nil
                       #'harness-tool-slots-load--notify-now))))

(defun harness-tool-slots-load--notify-cancel ()
  "Drop an announcement that is due, as the module stops."
  (when (timerp harness-tool-slots-load--notify-timer)
    (cancel-timer harness-tool-slots-load--notify-timer))
  (setq harness-tool-slots-load--notify-timer nil))

(defun harness-tool-slots-load--set (slots pressure)
  "Make SLOTS this machine's limit, nil for the baseline, and say so.
PRESSURE is the load per processor that decided it, nil when the load
watch was turned off.  Every UI hears the new state, the calls waiting
start when the limit rose, and every active session hears the new number."
  (let* ((baseline (harness-tool-slots--baseline))
         (old (min baseline (or harness-tool-slots-load--limit baseline)))
         (new (or slots baseline))
         (text (harness-tool-slots-load--notice old new pressure)))
    (setq harness-tool-slots-load--limit slots
          harness-tool-slots-load--changed-at (float-time)
          harness-tool-slots-load--changed-pressure pressure
          harness-tool-slots-load--changed-text text)
    (harness-log 'info "tool-slots-load: %s" text)
    (harness-emit 'tool-slots/changed (harness-tool-slots-load--state))
    (harness-tool-slots-load--admit)
    (harness-tool-slots-load--announce text)))

(defun harness-tool-slots-load--tick ()
  "Sample this machine's load and set its slots to what the load allows.
Called on a timer, once at startup, and by a test.  The long-term
average (`harness-tool-slots-load-window') sets the limit; the
short-term one (`harness-tool-slots-load-short-window') may only lower
it.  A falling limit is taken when the load has moved by
`harness-tool-slots-load-deadband' since the last change, and then at
most once per `harness-tool-slots-load-cooldown'.  A limit the
short-term load lowered rises slowly, by
`harness-tool-slots-load-recovery-step' slots and one step per
`harness-tool-slots-load-recovery-cooldown', until it reaches what the
long-term load allows; other rises are taken as they always were.  A
load the machine cannot report leaves the limit as it is."
  (let* ((baseline (harness-tool-slots--baseline))
         (current (min baseline (or harness-tool-slots-load--limit baseline))))
    (cond
     ((not harness-tool-slots-load-enabled)
      ;; The watch is off: the baseline, whatever the load says.
      (when harness-tool-slots-load--limit
        (harness-tool-slots-load--set nil nil)))
     (t
      (when-let* ((long (harness-tool-slots-load--pressure)))
        (let* ((short (harness-tool-slots-load--short-pressure))
               (long-cap (min baseline
                              (harness-tool-slots-load--cap long baseline)))
               (short-cap (and short
                               (min baseline
                                    (harness-tool-slots-load--cap
                                     short baseline))))
               (cap (if short-cap (min long-cap short-cap) long-cap))
               (short-binds-p (and short-cap (< short-cap long-cap)))
               ;; The reading that asks for CAP: the short-term one when it
               ;; holds the limit below what the long-term one allows.
               (pressure (if short-binds-p short long)))
          ;; The long-term load alone now allows CURRENt: no short-term
          ;; cut is left to recover.
          (when (and harness-tool-slots-load--short-limited
                     (>= current long-cap))
            (setq harness-tool-slots-load--short-limited nil))
          (cond
           ((< cap current)
            (when (and (harness-tool-slots-load--cooled-p)
                       (harness-tool-slots-load--moved-p
                        pressure cap current baseline))
              (setq harness-tool-slots-load--short-limited short-binds-p)
              (harness-tool-slots-load--set (if (= cap baseline) nil cap)
                                            pressure)))
           ((> cap current)
            (if harness-tool-slots-load--short-limited
                ;; A step back up, not the whole way at once.
                (when (and (harness-tool-slots-load--cooled-p)
                           (harness-tool-slots-load--recovered-p))
                  (let* ((step (max 1 (or harness-tool-slots-load-recovery-step 1)))
                         (new (min cap (+ current step))))
                    ;; Once the long-term load allows NEW there is nothing
                    ;; of the short-term cut left, and its rules take over.
                    (setq harness-tool-slots-load--short-limited
                          (< new long-cap))
                    (harness-tool-slots-load--set (if (= new baseline) nil new)
                                                  pressure)))
              (when (and (harness-tool-slots-load--cooled-p)
                         (harness-tool-slots-load--moved-p
                          pressure cap current baseline))
                (harness-tool-slots-load--set (if (= cap baseline) nil cap)
                                              pressure)))))))))))

;;;; The module

(defun harness-tool-slots-load--init ()
  "Watch this machine's load and lower its tool slots while it is busy."
  (unless (advice-member-p #'harness-tool-slots-load--slots-advice
                           'harness-tool-slots--slots)
    (advice-add 'harness-tool-slots--slots :around
                #'harness-tool-slots-load--slots-advice))
  (setq harness-tool-slots-load--changed-at nil
        harness-tool-slots-load--changed-pressure nil
        harness-tool-slots-load--changed-text nil
        harness-tool-slots-load--short-limited nil)
  ;; Who holds a slot is told to the UIs along with the limit.
  (harness-on 'tool-slots/holders-changed #'harness-tool-slots-load--notify-soon)
  ;; The machine may already be busy: take the first reading now.
  (harness-tool-slots-load--tick)
  (when (timerp harness-tool-slots-load--timer)
    (cancel-timer harness-tool-slots-load--timer))
  (let ((interval (max 1 (float harness-tool-slots-load-interval))))
    (setq harness-tool-slots-load--timer
          (run-with-timer interval interval #'harness-tool-slots-load--tick))))

(defun harness-tool-slots-load--shutdown ()
  "Stop watching the load and give this machine its baseline slots back.
The sessions are not told: the watch going away is not the machine's
load changing, and a harness shutting down has no business saying so.
A UI is, if the slots were held back, so that what it shows of them
goes with the limit."
  (when (timerp harness-tool-slots-load--timer)
    (cancel-timer harness-tool-slots-load--timer))
  (setq harness-tool-slots-load--timer nil)
  (harness-off (cons 'tool-slots/holders-changed #'harness-tool-slots-load--notify-soon))
  (harness-tool-slots-load--notify-cancel)
  (advice-remove 'harness-tool-slots--slots
                 #'harness-tool-slots-load--slots-advice)
  (let ((held (and harness-tool-slots-load--limit t)))
    (setq harness-tool-slots-load--limit nil
          harness-tool-slots-load--changed-at nil
          harness-tool-slots-load--changed-pressure nil
          harness-tool-slots-load--changed-text nil
          harness-tool-slots-load--short-limited nil)
    (when held
      (harness-tool-slots-load--admit)
      (harness-emit 'tool-slots/changed (harness-tool-slots-load--state)))))

(harness-define-module 'tool-slots-load
  :doc "Fewer tool slots while this machine is loaded."
  :requires '(tool-slots)
  :init #'harness-tool-slots-load--init
  :shutdown #'harness-tool-slots-load--shutdown)

(provide 'harness-tool-slots-load)
;;; harness-tool-slots-load.el ends here
