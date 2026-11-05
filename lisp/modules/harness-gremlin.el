;;; harness-gremlin.el --- Controlled chaos fixtures for testing the harness  -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; A gremlin is a deliberately bad actor that the harness has to survive.
;; It is not a claim that somebody wrote malicious code.  Most of what a
;; gremlin does is what the real world already does:
;;
;; - `unreliable': a provider is slow, drops a stream, rate limits, runs
;;   out of quota, or an upstream returns a malformed answer.  Nothing
;;   here is anyone's fault; the world is just not a function that always
;;   returns a value.
;; - `bug': a component of the harness itself has a defect -- a bad
;;   event shape, a value of the wrong type, a promise that never settles,
;;   a tool that leaks output.  The gremlin makes the defect happen on
;;   purpose, where a test can see it.
;; - `optimizer': a language model takes the path of least resistance to a
;;   reward.  It calls the same tool over and over, edits the test rather
;;   than the code, claims success without doing the work, reads a file it
;;   was not asked to read, or puts a secret in its answer.  It is not
;;   trying to break the harness; it is doing exactly what it was trained
;;   to do, and the harness must make the safe path the easy one.
;;
;; The provider and tool gremlins live in harness-provider-gremlin.el and
;; harness-tools-gremlin.el; a project's plugin can be a gremlin too (see
;; .harness/plugins/gremlin/).  This module is the shared, opt-in harness:
;; it registers the gremlins, gives each a seeded random source and a hard
;; budget, records what happened, and cleans up the timers and processes a
;; run started.
;;
;; Nothing is armed by default.  A gremlin provider or tool answers
;; politely, or refuses, until `harness-gremlin-enabled' is non-nil.  The
;; chaos test suite binds `harness-gremlin-with-run', which also gives the
;; run its budget and seed.  Never enable gremlins in a session that is
;; doing real work: they are test fixtures, not a fuzzing mode for the
;; user's editor.
;;
;; A run is a controlled environment, not an excuse for a resource fire:
;;
;;   (harness-gremlin-with-run "provider contract"
;;     (harness-gremlin-seed 424242)
;;     (harness-provider-gremlin--complete request))
;;
;; The budget in `harness-gremlin-budget' caps wall-clock seconds, bytes of
;; generated output, calls, memory and processes.  A gremlin asks
;; `harness-gremlin-spend' before it exceeds one; when the budget is gone
;; it stops and records why.  `harness-gremlin-run-at' and
;; `harness-gremlin-start-process' make what a run creates visible to
;; `harness-gremlin-cleanup', which cancels its timers and kills its
;; processes even when a test fails.
;;
;; The log, `harness-gremlin-incident', is for what a gremlin did; the
;; attempt log, `harness-gremlin-attempt', is for what it tried to reach
;; and whether the harness let it.  `harness-gremlin-report' summarizes
;; both, by origin and by gremlin, so a test can assert that every failure
;; mode was exercised and that the destructive ones were refused.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)

(defcustom harness-gremlin-enabled nil
  "Non-nil arms the gremlins, so tests can make them misbehave.
Nil, the default, keeps them harmless: the gremlin provider answers
politely and the gremlin tools refuse to run.  A test arms a run with
`harness-gremlin-with-run'; an installation never needs to set this."
  :type 'boolean :group 'harness)

(defcustom harness-gremlin-seed nil
  "Seed of the random choices gremlins make, or nil for a new one each run.
The same seed makes the same sequence of choices, so a chaos test can
reproduce the failure it found.  `harness-gremlin-report' returns the
seed the run used."
  :type '(choice (const :tag "Different each run" nil) integer)
  :group 'harness)

(defcustom harness-gremlin-budget
  '(:seconds 30 :bytes 2000000 :calls 1000 :memory-mb 64 :processes 4)
  "Caps on what one gremlin run may use.
`:seconds' is wall-clock time, `:bytes' output a gremlin may generate,
`:calls' actions it may take, `:memory-mb' memory it may allocate and
`:processes' processes it may start.  A gremlin checks the budget
before each step and stops when it is spent, recording an incident; it
never makes the machine slow for the sake of a test."
  :type '(plist :key-type keyword :value-type number) :group 'harness)

(defcustom harness-gremlin-max-incidents 500
  "Most incidents one run keeps.  The oldest are dropped first.
A gremlin that loops is exactly what the budget is for; this keeps its
log from becoming a second resource problem."
  :type 'integer :group 'harness)

(defcustom harness-gremlin-max-attempts 500
  "Most attempts one run keeps.  The oldest are dropped first."
  :type 'integer :group 'harness)

(defconst harness-gremlin-kinds '(provider tool plugin)
  "The kinds of gremlin a test can register.
A provider gremlin speaks the provider event protocol; a tool gremlin
is a `harness-define-tool' handler; a plugin gremlin is a project's
plugin module, loaded through the trust rules of harness-plugins.el.")

(defconst harness-gremlin-origins
  '((unreliable . "The world is unreliable: timeouts, rate limits, disconnects, partial data.")
    (bug . "A defect in the harness or a component: a wrong type, a missed event, a leak.")
    (optimizer . "A model takes the path of least resistance: loops, shortcuts, exfiltration."))
  "Why a gremlin exists, in the terms of the failure, not the fault.
Every gremlin names one of these, and the report counts them, so a run
shows whether it exercised the world, our code or the model's incentives.")

(defvar harness-gremlins (make-hash-table :test 'eq)
  "Gremlin name -> its metadata plist, as `harness-gremlin-define' stores it.")

(defvar harness-gremlin--run nil
  "Name of the current gremlin run, or nil before one starts.")

(defvar harness-gremlin--seed nil
  "Seed the current run actually used.")

(defvar harness-gremlin--started nil
  "`float-time' when the current run started, or nil before it does.")

(defvar harness-gremlin--spent nil
  "Resources the current run has spent, a plist of numbers.")

(defvar harness-gremlin--incidents nil
  "Incidents of the current run, newest first.")

(defvar harness-gremlin--attempts nil
  "Attempts of the current run, newest first.")

(defvar harness-gremlin--rng-state nil
  "State of the current run's deterministic random number generator.")

(defvar harness-gremlin--timers nil
  "Timers the current run started and has not cancelled.")

(defvar harness-gremlin--processes nil
  "Processes the current run started and has not cleaned up.")

(defvar harness-gremlin--budget-exhausted nil
  "Non-nil once a gremlin of the current run asked for more than its budget.")

(defvar harness-gremlin--budget-reported nil
  "Non-nil once the current run recorded its budget exhaustion.")

;;;; The registry

(cl-defun harness-gremlin-define (name &key kind origin doc)
  "Register gremlin NAME, a symbol, of KIND and ORIGIN.
KIND is `provider', `tool' or `plugin'; ORIGIN is `unreliable', `bug'
or `optimizer', and says what kind of failure NAME stands for.  DOC
describes the failure to a person reading the module page.  Defining
NAME again replaces it, as a reload does."
  (unless (and name (symbolp name) (not (keywordp name)))
    (error "A gremlin needs a symbol name, not %S" name))
  (unless (memq kind harness-gremlin-kinds)
    (error "Gremlin %s needs a kind, one of %s, not %S"
           name (mapconcat #'symbol-name harness-gremlin-kinds ", ") kind))
  (unless (assq origin harness-gremlin-origins)
    (error "Gremlin %s needs an origin, one of %s, not %S"
           name (mapconcat (lambda (o) (symbol-name (car o))) harness-gremlin-origins ", ") origin))
  (puthash name (list :name name :kind kind :origin origin :doc doc) harness-gremlins)
  name)

(defun harness-gremlin-get (name)
  "Return the metadata plist of gremlin NAME, or nil."
  (gethash name harness-gremlins))

(defun harness-gremlin-list (&optional kind)
  "Return the registered gremlins as metadata plists, sorted by name.
With KIND, only that kind of gremlin."
  (let (out)
    (maphash (lambda (_name plist)
               (when (or (null kind) (eq kind (plist-get plist :kind)))
                 (push plist out)))
             harness-gremlins)
    (sort out (lambda (a b)
                (string< (symbol-name (plist-get a :name))
                         (symbol-name (plist-get b :name)))))))

(defun harness-gremlin-armed-p ()
  "Non-nil when gremlins may misbehave in this process.
That is `harness-gremlin-enabled'; a test binds it with
`harness-gremlin-with-run'."
  (and harness-gremlin-enabled t))

;;;; A run and its budget

(defun harness-gremlin--ensure-started ()
  "Start an implicit run if something uses the gremlin helpers unarmed."
  (unless harness-gremlin--started
    (harness-gremlin-reset)))

(defun harness-gremlin-reset (&optional seed run)
  "Reset the gremlin run state, with SEED and RUN.
SEED defaults to `harness-gremlin-seed', or to a new random one.  A
timer or process the previous run left is not cleaned up here: call
`harness-gremlin-cleanup' first, as `harness-gremlin-with-run' does."
  (let* ((seed (or seed harness-gremlin-seed (random most-positive-fixnum)))
         (state (logand seed #x7fffffff)))
    (setq harness-gremlin--seed seed
          harness-gremlin--rng-state (if (zerop state) 1 state)
          harness-gremlin--run (or run harness-gremlin--run "ad-hoc")
          harness-gremlin--started (float-time)
          harness-gremlin--spent nil
          harness-gremlin--incidents nil
          harness-gremlin--attempts nil
          harness-gremlin--timers nil
          harness-gremlin--processes nil
          harness-gremlin--budget-exhausted nil
          harness-gremlin--budget-reported nil)
    seed))

(defun harness-gremlin-elapsed ()
  "Return seconds since the current run started."
  (if harness-gremlin--started (max 0 (- (float-time) harness-gremlin--started)) 0))

(defun harness-gremlin-time-left ()
  "Return seconds the current run may still use, or a large number when uncapped."
  (harness-gremlin--ensure-started)
  (if-let* ((limit (plist-get harness-gremlin-budget :seconds)))
      (max 0 (- limit (harness-gremlin-elapsed)))
    most-positive-fixnum))

(defun harness-gremlin-spent (resource)
  "Return how much of RESOURCE the current run has spent."
  (or (plist-get harness-gremlin--spent resource) 0))

(defun harness-gremlin-remaining (resource)
  "Return how much of RESOURCE the run may still spend, or nil.
Nil means the run has no budget for RESOURCE."
  (harness-gremlin--ensure-started)
  (when-let* ((limit (plist-get harness-gremlin-budget resource)))
    (max 0 (- limit (harness-gremlin-spent resource)))))

(defun harness-gremlin--refuse-budget (resource wanted available)
  "Record that RESOURCE is spent, and return nil.
WANTED is what was asked for and AVAILABLE what may still be spent."
  (setq harness-gremlin--budget-exhausted t)
  (unless harness-gremlin--budget-reported
    (setq harness-gremlin--budget-reported t)
    (harness-gremlin-incident
     'budget "budget-exhausted" :resource resource
     :wanted wanted :available (or available 0)))
  nil)

(defun harness-gremlin-spend (resource amount)
  "Spend AMOUNT of RESOURCE for the current run; nil when that is too much.
RESOURCE is one of the keys of `harness-gremlin-budget'.  A gremlin
calls this before it allocates, writes or starts anything, so the test
machine stays responsive.  The first refusal of a run records one
incident; later ones are silent."
  (harness-gremlin--ensure-started)
  (let* ((amount (max 0 (or amount 0)))
         (limit (plist-get harness-gremlin-budget resource))
         (spent (harness-gremlin-spent resource)))
    (cond
     ((null limit) t)
     ((<= (+ spent amount) limit)
      (setq harness-gremlin--spent
            (plist-put harness-gremlin--spent resource (+ spent amount)))
      t)
     (t (harness-gremlin--refuse-budget resource amount (- limit spent))))))

(defun harness-gremlin-fraction ()
  "Return a deterministic number from 0 up to, but not including, 1."
  (harness-gremlin--ensure-started)
  (setq harness-gremlin--rng-state
        (mod (+ (* harness-gremlin--rng-state 1103515245) 12345) 2147483648))
  (/ (float (ash harness-gremlin--rng-state -1)) 1073741824.0))

(defun harness-gremlin-random (&optional limit)
  "Return a deterministic random integer.
Without LIMIT it is from 0 to 2^30; with LIMIT, from 0 up to but not
including LIMIT.  The sequence is the same for the same seed."
  (if (and limit (> limit 0))
      (mod (floor (* (harness-gremlin-fraction) limit)) limit)
    (floor (* (harness-gremlin-fraction) 1073741824.0))))

(defun harness-gremlin-chance (probability)
  "Return non-nil with PROBABILITY, a number from 0 to 1, deterministically."
  (< (harness-gremlin-fraction) (max 0 (min 1 (float probability)))))

(defun harness-gremlin-pick (sequence)
  "Return a deterministic random element of SEQUENCE, or nil when it is empty."
  (when (and sequence (> (length sequence) 0))
    (nth (harness-gremlin-random (length sequence)) sequence)))

(defun harness-gremlin-shuffle (sequence)
  "Return a deterministic shuffled copy of SEQUENCE."
  (let ((items (append sequence nil)))
    (cl-loop for i from (1- (length items)) downto 1
             do (let ((j (harness-gremlin-random (1+ i))))
                  (cl-rotatef (nth i items) (nth j items))))
    items))

(defun harness-gremlin-latency (maximum)
  "Return a deterministic delay from 0 up to MAXIMUM seconds.
The delay is also capped by the time the run has left, and is a
quarter of that at most: a gremlin that waits does not spend the whole
budget on one pause."
  (let ((limit (min (max 0 (float maximum))
                    (max 0 (* (harness-gremlin-time-left) 0.25)))))
    (* limit (harness-gremlin-fraction))))

(defun harness-gremlin-bytes (size &optional character)
  "Return a string of SIZE CHARACTER bytes, within the run's byte budget.
When the budget cannot give SIZE, return what it can and record why.
CHARACTER defaults to `x'.  A gremlin uses this instead of `make-string'
so that a server-sized answer cannot become a test suite's memory."
  (let* ((size (max 0 (round size)))
         (remaining (harness-gremlin-remaining :bytes))
         (allowed (if remaining (min size remaining) size)))
    (when (< allowed size)
      (harness-gremlin-incident 'budget "bytes-clamped" :wanted size :allowed allowed))
    (if (harness-gremlin-spend :bytes allowed)
        (make-string allowed (or character ?x))
      "")))

(defun harness-gremlin-allocate (megabytes)
  "Return a string of MEGABYTES megabytes of payload, within the memory budget.
Return an empty string when the run cannot allocate any more, and
record the request.  The caller can tell what it got from the length."
  (let* ((megabytes (max 0 (round megabytes)))
         (remaining (harness-gremlin-remaining :memory-mb))
         (allowed (if remaining (min megabytes remaining) megabytes)))
    (when (< allowed megabytes)
      (harness-gremlin-incident 'budget "memory-clamped"
                                :wanted megabytes :allowed allowed))
    (if (and (> allowed 0) (harness-gremlin-spend :memory-mb allowed))
        (make-string (* allowed 1024 1024) ?m)
      "")))

(defun harness-gremlin-spin (milliseconds)
  "Busily spin for MILLISECONDS, within the run's time budget.
Return the seconds actually spent, a float.  This models a runaway
computation; tests use it with tiny values."
  (let* ((milliseconds (max 0 (min milliseconds (* 1000 (harness-gremlin-time-left)))))
         (deadline (+ (float-time) (/ milliseconds 1000.0))))
    (while (< (float-time) deadline))
    (/ milliseconds 1000.0)))

;;;; Timers and processes

(defun harness-gremlin-run-at (seconds function)
  "Run FUNCTION after SECONDS, as a timer the run will clean up.
Errors are logged, never left to Emacs's timer machinery.  Return the
timer."
  (harness-gremlin--ensure-started)
  (let ((timer nil))
    (setq timer (run-at-time seconds nil
                             (lambda ()
                               (setq harness-gremlin--timers
                                     (delq timer harness-gremlin--timers))
                               (condition-case err
                                   (funcall function)
                                 (error
                                  (harness-log 'warn "gremlin %s: timer failed: %s"
                                               harness-gremlin--run
                                               (error-message-string err)))))))
    (push timer harness-gremlin--timers)
    timer))

(defun harness-gremlin-cancel-timer (timer)
  "Cancel TIMER and forget it, if it is still one of the run's."
  (when (timerp timer)
    (ignore-errors (cancel-timer timer))
    (setq harness-gremlin--timers (delq timer harness-gremlin--timers))))

(defun harness-gremlin-start-process (name buffer command)
  "Start COMMAND as process NAME in BUFFER, within the process budget.
Return the process.  It is killed by `harness-gremlin-cleanup' when the
run ends.  Signals when the budget has no process left."
  (harness-gremlin--ensure-started)
  (unless (harness-gremlin-spend :processes 1)
    (error "Gremlin %s: process budget spent" harness-gremlin--run))
  (let ((process (make-process :name name :buffer buffer :command command :noquery t)))
    (push process harness-gremlin--processes)
    process))

(defvar harness-gremlin-cleanup-hook nil
  "Hook run after `harness-gremlin-cleanup' cancelled a run's work.
A gremlin implementation with a resource of its own adds a function
here to release it.")

(defun harness-gremlin-cleanup ()
  "Cancel the run's timers and kill its live processes.
This is what keeps a failed chaos test from leaving work behind.  It
does not clear the incident or attempt logs, so a report can still be
made after it."
  (dolist (timer harness-gremlin--timers)
    (ignore-errors (cancel-timer timer)))
  (setq harness-gremlin--timers nil)
  (dolist (process harness-gremlin--processes)
    (when (process-live-p process)
      (ignore-errors (delete-process process))))
  (setq harness-gremlin--processes nil)
  (run-hooks 'harness-gremlin-cleanup-hook))

;;;; Incidents and attempts

(defun harness-gremlin--remember (entry place maximum)
  "Push ENTRY onto PLACE, a variable naming a list, keeping MAXIMUM newest.
PLACE is a symbol; this sets it.  Return ENTRY."
  (let ((items (cons entry (symbol-value place))))
    (when (and maximum (> (length items) maximum))
      (setcdr (nthcdr (1- maximum) items) nil))
    (set place items)
    entry))

(defun harness-gremlin-incident (gremlin event &rest properties)
  "Record that GREMLIN did EVENT, with PROPERTIES.
EVENT is a symbol or a string naming what happened; PROPERTIES are
extra keys of the incident plist.  Return the incident, or nil when
gremlins are not armed.  The log is newest first and bounded by
`harness-gremlin-max-incidents'."
  (when (harness-gremlin-armed-p)
    (harness-gremlin--ensure-started)
    (harness-gremlin--remember
     (append (list :gremlin gremlin :event event :at (float-time)) properties)
     'harness-gremlin--incidents harness-gremlin-max-incidents)))

(defun harness-gremlin-incidents ()
  "Return the incidents of the current run, newest first."
  (copy-sequence harness-gremlin--incidents))

(defun harness-gremlin-incidents-of (gremlin)
  "Return the incidents of GREMLIN in the current run, newest first."
  (cl-remove-if-not (lambda (entry) (eq (plist-get entry :gremlin) gremlin))
                    harness-gremlin--incidents))

(defun harness-gremlin-attempt (gremlin action target function)
  "Try FUNCTION as GREMLIN's attempt at ACTION on TARGET.
Record whether it was allowed to run its course.  Return (SUCCEEDED
. VALUE): SUCCEEDED is t when FUNCTION returned and nil when it
signalled; VALUE is what it returned, or the error message.  The log
keeps no returned value, only whether the attempt was allowed, so an
attempt to read a secret never makes the test's own log a leak."
  (harness-gremlin--ensure-started)
  (let* ((outcome (condition-case err
                      (cons t (funcall function))
                    (error (cons nil (error-message-string err)))))
         (entry (list :gremlin gremlin :action action :target target
                      :allowed (car outcome) :at (float-time)
                      :error (unless (car outcome) (cdr outcome)))))
    (when (harness-gremlin-armed-p)
      (harness-gremlin--remember entry 'harness-gremlin--attempts
                                 harness-gremlin-max-attempts))
    outcome))

(defun harness-gremlin-attempts ()
  "Return the attempts of the current run, newest first."
  (copy-sequence harness-gremlin--attempts))

(defun harness-gremlin-attempts-of (gremlin)
  "Return the attempts of GREMLIN in the current run, newest first."
  (cl-remove-if-not (lambda (entry) (eq (plist-get entry :gremlin) gremlin))
                    harness-gremlin--attempts))

;;;; The report

(defun harness-gremlin-report ()
  "Return a plist summarizing the current run.
It holds the run's name and seed, the budget and what was spent, the
incident and attempt counts, attempts allowed and refused, and counts
by origin and by gremlin.  The counts are built from the registry, so
a gremlin that never fired shows as zero."
  (harness-gremlin--ensure-started)
  (let ((incidents harness-gremlin--incidents)
        (attempts harness-gremlin--attempts)
        (by-origin nil) (by-gremlin nil) (allowed 0) (refused 0))
    (dolist (entry incidents)
      (let* ((gremlin (plist-get entry :gremlin))
             (origin (or (plist-get (harness-gremlin-get gremlin) :origin) 'unknown)))
        (setf (alist-get origin by-origin 0) (1+ (alist-get origin by-origin 0)))
        (setf (alist-get gremlin by-gremlin 0) (1+ (alist-get gremlin by-gremlin 0)))))
    (dolist (entry attempts)
      (if (plist-get entry :allowed) (cl-incf allowed) (cl-incf refused)))
    (list :run harness-gremlin--run
          :seed harness-gremlin--seed
          :armed (harness-gremlin-armed-p)
          :elapsed (harness-gremlin-elapsed)
          :budget (copy-sequence harness-gremlin-budget)
          :spent (copy-sequence harness-gremlin--spent)
          :time-left (harness-gremlin-time-left)
          :budget-exhausted (and harness-gremlin--budget-exhausted t)
          :incidents (length incidents)
          :attempts (length attempts)
          :attempts-allowed allowed
          :attempts-refused refused
          :by-origin (sort by-origin (lambda (a b) (string< (symbol-name (car a)) (symbol-name (car b)))))
          :by-gremlin (sort by-gremlin (lambda (a b) (string< (symbol-name (car a)) (symbol-name (car b))))))))

(defun harness-gremlin-describe-report (&optional report)
  "Return REPORT, or the current report, as a short human-readable string."
  (let ((report (or report (harness-gremlin-report))))
    (format "Gremlin run %s (seed %s): %d incident%s, %d attempt%s (%d refused), %.4fs, %d bytes; origins: %s%s"
            (or (plist-get report :run) "ad-hoc")
            (plist-get report :seed)
            (plist-get report :incidents) (if (= 1 (plist-get report :incidents)) "" "s")
            (plist-get report :attempts) (if (= 1 (plist-get report :attempts)) "" "s")
            (plist-get report :attempts-refused)
            (float (or (plist-get report :elapsed) 0))
            (or (plist-get (plist-get report :spent) :bytes) 0)
            (mapconcat (lambda (cell) (format "%s=%d" (car cell) (cdr cell)))
                       (plist-get report :by-origin) " ")
            (if (plist-get report :budget-exhausted) " [budget spent]" ""))))

(defmacro harness-gremlin-with-run (name &rest body)
  "Run BODY as gremlin run NAME with a fresh budget, seed and logs.
The run is armed for BODY, and its timers and processes are cleaned up
afterwards, even when BODY signals.  Bind `harness-gremlin-seed' and
`harness-gremlin-budget' around the call to choose them."
  (declare (indent 1) (debug t))
  `(let ((harness-gremlin-enabled t)
         (harness-gremlin--run ,name)
         (harness-gremlin-budget (copy-sequence harness-gremlin-budget))
         (harness-gremlin--started nil)
         (harness-gremlin--spent nil)
         (harness-gremlin--incidents nil)
         (harness-gremlin--attempts nil)
         (harness-gremlin--rng-state nil)
         (harness-gremlin--timers nil)
         (harness-gremlin--processes nil)
         (harness-gremlin--budget-exhausted nil)
         (harness-gremlin--budget-reported nil))
     (harness-gremlin-reset)
     (unwind-protect (progn ,@body)
       (harness-gremlin-cleanup))))

(defun harness-gremlin-run (name function &optional budget)
  "Run FUNCTION as gremlin run NAME with BUDGET; return (RESULT . REPORT).
This is the function form of `harness-gremlin-with-run', for a caller
that has a function at hand.  The run is cleaned up before REPORT is
built."
  (let ((harness-gremlin-enabled t)
        (harness-gremlin--run name)
        (harness-gremlin-budget (copy-sequence (or budget harness-gremlin-budget)))
        (harness-gremlin--started nil)
        (harness-gremlin--spent nil)
        (harness-gremlin--incidents nil)
        (harness-gremlin--attempts nil)
        (harness-gremlin--rng-state nil)
        (harness-gremlin--timers nil)
        (harness-gremlin--processes nil)
        (harness-gremlin--budget-exhausted nil)
        (harness-gremlin--budget-reported nil))
    (harness-gremlin-reset)
    (let (result)
      (unwind-protect (setq result (funcall function))
        (harness-gremlin-cleanup))
      (cons result (harness-gremlin-report)))))

(harness-define-module 'gremlin
  :doc "Opt-in chaos fixtures and the budgeted run that contains them.")

(provide 'harness-gremlin)
;;; harness-gremlin.el ends here
