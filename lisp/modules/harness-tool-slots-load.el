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
;; limit as the load falls.  The load is read per processor: 1.0 means
;; one processor's worth of runnable work on each processor, and at
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
;; not make the slots flap.  On a rise the calls already waiting start
;; at once, up to what now fits; on a fall the calls running are left
;; alone and no new one starts until the machine is under the limit
;; again.
;;
;; Only this machine is watched.  A call on another host -- over TRAMP
;; or through the ssh tool -- runs on a machine whose load this harness
;; cannot read, and keeps that host's baseline slots.
;;
;; Whenever the effective number changes, down or back up, every active
;; session is told as a system message, so the user and the models see
;; why calls are waiting: "Tool slots reduced from 18 to 5: system load
;; 1.8x on this machine".
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

(defcustom harness-tool-slots-load-window 1
  "Which load average the module reads: over 1, 5 or 15 minutes.
The 1-minute average feels a build or a test run at once; a longer
window is steadier, and so slower to give the slots back."
  :type '(choice (const :tag "1 minute" 1)
                 (const :tag "5 minutes" 5)
                 (const :tag "15 minutes" 15))
  :group 'harness)

(defcustom harness-tool-slots-load-low 1.0
  "Load per processor at or below which every slot is allowed.
The load is the average `harness-tool-slots-load-function' reports for
`harness-tool-slots-load-window', divided by the processor count, so
1.0 is one processor's worth of runnable work per processor.  At or
below this the limit is the baseline; above it the slots go down with
the load."
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
about a change that is over by the next sample."
  :type 'number
  :group 'harness)

(defcustom harness-tool-slots-load-deadband 0.15
  "Least change in load per processor that takes a new limit.
A change is taken only when the load has moved this far from the load
that took the last one, in the direction of the change, so noise around
a threshold does not move the slots.  A rise back to the baseline is
taken as soon as the load is at or below
`harness-tool-slots-load-low', deadband or not, so a quiet machine
always gets its full limit back."
  :type 'number
  :group 'harness)

(defun harness-tool-slots-load-default-load (&optional window)
  "Return this machine's load average over WINDOW minutes, or nil.
WINDOW is 1, 5 or 15 (`harness-tool-slots-load-window'), and the value
is what `load-average' reports -- the numbers /proc/loadavg shows on
GNU/Linux.  A system that cannot report its load gives nil, which
leaves the limit alone."
  (condition-case err
      (nth (pcase (or window 1) (5 1) (15 2) (_ 0)) (load-average t))
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
  "Load per processor when the limit last changed, or nil.")

(defvar harness-tool-slots-load--timer nil
  "The repeating timer that samples the load, or nil when it is off.")

(defun harness-tool-slots-load--pressure ()
  "Return this machine's load per processor, or nil when unknown.
An unreadable load -- `load-average' signals, or the load function
says nothing useful -- is nil, and a limit is never lowered for it."
  (let ((load (condition-case err
                  (funcall harness-tool-slots-load-function
                           harness-tool-slots-load-window)
                (error (harness-log 'debug "tool-slots-load: %s"
                                    (harness-error-message err))
                       nil))))
    (when (and (numberp load) (>= load 0))
      (/ (float load) (max 1 (num-processors))))))

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

(defun harness-tool-slots-load--announce (text)
  "Append TEXT to every active session, as a system hint.
A session that is closed, or inactive, is left alone; a session that
goes while the message is on its way is skipped."
  (when (and (harness-method-exists-p 'session/list)
             (harness-method-exists-p 'session/hint))
    (dolist (session (harness-call 'session/list (list :active t)))
      (let ((id (plist-get session :id)))
        (when (and (stringp id) (not (eq (plist-get session :status) 'inactive)))
          (ignore-errors (harness-call 'session/hint id text)))))))

(defun harness-tool-slots-load--set (slots pressure)
  "Make SLOTS this machine's limit, nil for the baseline, and say so.
PRESSURE is the load per processor that decided it, nil when the load
watch was turned off.  The calls waiting start when the limit rose, and
every active session hears the new number."
  (let* ((baseline (harness-tool-slots--baseline))
         (old (min baseline (or harness-tool-slots-load--limit baseline)))
         (new (or slots baseline))
         (text (harness-tool-slots-load--notice old new pressure)))
    (setq harness-tool-slots-load--limit slots
          harness-tool-slots-load--changed-at (float-time)
          harness-tool-slots-load--changed-pressure pressure)
    (harness-log 'info "tool-slots-load: %s" text)
    (harness-tool-slots-load--admit)
    (harness-tool-slots-load--announce text)))

(defun harness-tool-slots-load--tick ()
  "Sample this machine's load and set its slots to what the load allows.
Called on a timer, once at startup, and by a test.  A limit only
changes when the load has moved by
`harness-tool-slots-load-deadband' since the last change, and then at
most once per `harness-tool-slots-load-cooldown'; a load the machine
cannot report leaves the limit as it is."
  (let* ((baseline (harness-tool-slots--baseline))
         (current (min baseline (or harness-tool-slots-load--limit baseline))))
    (cond
     ((not harness-tool-slots-load-enabled)
      ;; The watch is off: the baseline, whatever the load says.
      (when harness-tool-slots-load--limit
        (harness-tool-slots-load--set nil nil)))
     (t
      (when-let* ((pressure (harness-tool-slots-load--pressure)))
        (let ((cap (min baseline
                        (harness-tool-slots-load--cap pressure baseline))))
          (when (and (/= cap current)
                     (harness-tool-slots-load--cooled-p)
                     (harness-tool-slots-load--moved-p
                      pressure cap current baseline))
            (harness-tool-slots-load--set (if (= cap baseline) nil cap)
                                          pressure))))))))

;;;; The module

(defun harness-tool-slots-load--init ()
  "Watch this machine's load and lower its tool slots while it is busy."
  (unless (advice-member-p #'harness-tool-slots-load--slots-advice
                           'harness-tool-slots--slots)
    (advice-add 'harness-tool-slots--slots :around
                #'harness-tool-slots-load--slots-advice))
  (setq harness-tool-slots-load--changed-at nil
        harness-tool-slots-load--changed-pressure nil)
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
load changing, and a harness shutting down has no business saying so."
  (when (timerp harness-tool-slots-load--timer)
    (cancel-timer harness-tool-slots-load--timer))
  (setq harness-tool-slots-load--timer nil)
  (advice-remove 'harness-tool-slots--slots
                 #'harness-tool-slots-load--slots-advice)
  (when harness-tool-slots-load--limit
    (setq harness-tool-slots-load--limit nil)
    (harness-tool-slots-load--admit))
  (setq harness-tool-slots-load--changed-at nil
        harness-tool-slots-load--changed-pressure nil))

(harness-define-module 'tool-slots-load
  :doc "Fewer tool slots while this machine is loaded."
  :requires '(tool-slots)
  :init #'harness-tool-slots-load--init
  :shutdown #'harness-tool-slots-load--shutdown)

(provide 'harness-tool-slots-load)
;;; harness-tool-slots-load.el ends here
