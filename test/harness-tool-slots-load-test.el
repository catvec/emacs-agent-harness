;;; harness-tool-slots-load-test.el --- Tests for the load-aware tool slots plugin  -*- lexical-binding: t; -*-

;;; Commentary:

;; The plugin (lisp/modules/harness-tool-slots-load.el) lowers this
;; machine's tool slots while its load average is high.  The load is
;; stubbed (`harness-tool-slots-load-function', or `load-average' itself
;; where a test checks which of its averages is read) so that a test
;; says exactly what kind of machine it is, and `--tick' takes one
;; reading, as the plugin's timer would; the plugin's own timer is
;; stopped by the tests' setup, which also loads the plugin before each
;; test.

;;; Code:

(require 'harness-test-helpers)

;;;; The probes
;;
;; The calls are driven through `harness-tools--run-handler', the point
;; the tool-slots plugin advises, with probes whose handlers hold a
;; promise until the test settles it: a probe whose handler ran is one
;; the plugins let start.

(defvar harness-tool-slots-load-test--started nil
  "Names of the probe calls whose handler ran, in the order they ran.")

(defvar harness-tool-slots-load-test--waiting nil
  "The probes that started and are held, newest first, as (NAME . RESOLVE).")

(defun harness-tool-slots-load-test--probe (name)
  "Define tool NAME: a probe whose handler holds until the test settles it.
A call appends NAME to `harness-tool-slots-load-test--started' when its
handler runs, which is when the plugins have given it a slot.  Return NAME."
  (harness-define-tool name
    :label name :description "A probe that holds until settled" :kind 'exec
    :handler (lambda (_input _ctx)
               (harness-with-promise (resolve reject)
                 (ignore reject)
                 (setq harness-tool-slots-load-test--started
                       (append harness-tool-slots-load-test--started (list name)))
                 (push (cons name resolve) harness-tool-slots-load-test--waiting))))
  name)

(defun harness-tool-slots-load-test--settle-oldest ()
  "Settle the probe that has been running longest; return its name."
  (let ((entry (car (last harness-tool-slots-load-test--waiting))))
    (setq harness-tool-slots-load-test--waiting (butlast harness-tool-slots-load-test--waiting))
    (funcall (cdr entry) (harness-tool-ok (car entry)))
    (car entry)))

(defun harness-tool-slots-load-test--settle-all ()
  "Settle every probe that is held."
  (while harness-tool-slots-load-test--waiting
    (harness-tool-slots-load-test--settle-oldest)))

(defun harness-tool-slots-load-test--call (name &optional ctx)
  "Run probe NAME under CTX as `tools/execute' would; return its promise."
  (harness-tools--run-handler
   (harness-tool-get name) nil
   (or ctx (list :cwd (file-name-as-directory default-directory)))))

(defun harness-tool-slots-load-test--content (promise)
  "Return what PROMISE's result says, waiting for it."
  (plist-get (harness-await promise 5) :content))

;;;; The machine, and the load the tests pretend it has

(defun harness-tool-slots-load-test--machine (&rest _)
  "Return the one local machine the tests' calls run on."
  "local:test-machine")

(defun harness-tool-slots-load-test--load (per-processor)
  "Return a load function reporting PER-PROCESSOR load per processor.
What it returns is what `load-average' would: the machine's load, not
its load per processor, so the plugin divides by the processor count."
  (lambda (&optional _window) (* per-processor (max 1 (num-processors)))))

(defun harness-tool-slots-load-test--averages (one five fifteen)
  "Return a `load-average' reporting ONE, FIVE and FIFTEEN per processor.
They are the 1-, 5- and 15-minute averages, in the order `load-average'
reports them, and as the machine's load: the plugin divides them by the
processor count.  Bind `load-average' to it, and the load function to
the default one, to test which of the three the plugin reads."
  (let ((processors (max 1 (num-processors))))
    (lambda (&optional _use-floats)
      (list (* one processors) (* five processors) (* fifteen processors)))))

(defun harness-tool-slots-load-test--quiet ()
  "Return a load that leaves every slot: the machine is idle."
  0.1)

(defun harness-tool-slots-load-test--busy ()
  "Return a load that leaves the floor: the machine is busy."
  4.0)

;;;; Setup

(defun harness-tool-slots-load-test--setup ()
  "Load the plugins and start from fresh slots, load and probes."
  (harness-test-load-module 'tools)
  (harness-test-load-module 'tool-slots)
  (harness-test-load-module 'tool-slots-load)
  (harness-tool-slots-load-test--reset))

(defun harness-tool-slots-load-test--reset ()
  "Forget an earlier test's slots, load reading and probes.
The plugin's timer is stopped: the tests take readings themselves, by
calling `harness-tool-slots-load--tick'.  The advice is left in place,
and put back when a test took it off."
  (unless (advice-member-p #'harness-tool-slots-load--slots-advice 'harness-tool-slots--slots)
    (advice-add 'harness-tool-slots--slots :around
                #'harness-tool-slots-load--slots-advice))
  (when (timerp harness-tool-slots-load--timer)
    (cancel-timer harness-tool-slots-load--timer))
  ;; Nor does an announcement of who holds a slot, which an earlier
  ;; test's calls left due, come in the middle of this one.
  (harness-tool-slots-load--notify-cancel)
  (setq harness-tool-slots-load--timer nil
        harness-tool-slots-load--limit nil
        harness-tool-slots-load--changed-at nil
        harness-tool-slots-load--changed-pressure nil
        harness-tool-slots-load-function #'harness-tool-slots-load-test--quiet
        harness-tool-slots-load-test--started nil
        harness-tool-slots-load-test--waiting nil)
  (clrhash harness-tool-slots--machines))

(defun harness-tool-slots-load-test--tick ()
  "Take one load reading, as the plugin's timer would."
  (harness-tool-slots-load--tick))

(defmacro harness-tool-slots-load-test-with-sessions (&rest body)
  "Load the state modules and the plugins into fresh state, then BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider session)) (harness-test-load-module m))
     (harness-test-load-module 'priority)
     (harness-tool-slots-load-test--setup)
     (let ((default-directory (harness-test-temp-dir)))
       ,@body)))

(defun harness-tool-slots-load-test--hints (id)
  "Return the system hints session ID holds, oldest first."
  (delq nil (mapcar (lambda (node) (and (eq (plist-get node :kind) 'hint)
                                       (plist-get node :content)))
                    (harness-call 'session/nodes id))))

(defun harness-tool-slots-load-test--hint (id)
  "Return the newest system hint session ID holds, or nil."
  (car (last (harness-tool-slots-load-test--hints id))))

(defun harness-tool-slots-load-test--notes (id)
  "Return the notes of slot changes session ID holds, oldest first.
They are the hints that fold (`harness-node-fold'), as nodes."
  (cl-remove-if-not (lambda (node) (and (eq (plist-get node :kind) 'hint)
                                       (harness-node-fold node)))
                    (harness-call 'session/nodes id)))

(defun harness-tool-slots-load-test--lines (note)
  "Return the changes NOTE holds, oldest first, as the texts they say."
  (mapcar (lambda (item) (plist-get item :text))
          (plist-get (harness-node-fold note) :items)))

(defun harness-tool-slots-load-test--move (per-processor)
  "Move the machine's load to PER-PROCESSOR and take a reading.
The reading is let through the cooldown and the deadband, so it changes
the slots whenever the load asks for another number."
  (setq harness-tool-slots-load-function (harness-tool-slots-load-test--load per-processor)
        harness-tool-slots-load--changed-at nil
        harness-tool-slots-load--changed-pressure nil)
  (harness-tool-slots-load-test--tick))

(defconst harness-tool-slots-load-test--reduced
  "Tool slots reduced from 8 to 4: system load 1.5x on this machine"
  "What a machine of eight slots going to load 1.5 per processor tells.")

(defconst harness-tool-slots-load-test--restored
  "Tool slots restored to 8: system load back to normal"
  "What a machine of eight slots getting its slots back tells.")

(defconst harness-tool-slots-load-test--floor
  "Tool slots reduced from 8 to 1: system load 2.0x on this machine"
  "What a machine of eight slots going to load 2.0 per processor tells.")

;;;; The limit the load allows

(ert-deftest harness-tool-slots-load-a-quiet-machine-keeps-the-baseline ()
  "At or below the low threshold the slots are the baseline, exactly."
  (harness-tool-slots-load-test--setup)
  (let ((harness-tool-slots-count 6)
        (harness-tool-slots-burst 2)
        (harness-tool-slots-load-function (harness-tool-slots-load-test--load 0.3)))
    (harness-tool-slots-load-test--tick)
    (should (= 8 (harness-tool-slots--baseline)))
    (should (= 8 (harness-tool-slots--slots "local:test-machine")))
    (should-not harness-tool-slots-load--limit))
  ;; The load of a machine that is exactly as busy as its processors is
  ;; still quiet: the limit is the one per processor the count means.
  (let ((harness-tool-slots-count 6)
        (harness-tool-slots-burst 2)
        (harness-tool-slots-load-function (harness-tool-slots-load-test--load 1.0)))
    (harness-tool-slots-load-test--tick)
    (should (= 8 (harness-tool-slots--slots "local:test-machine")))
    (should-not harness-tool-slots-load--limit)))

(ert-deftest harness-tool-slots-load-a-busy-machine-loses-slots ()
  "A load over the low threshold takes slots away, down to the floor."
  (harness-tool-slots-load-test--setup)
  (let ((harness-tool-slots-count 8)
        (harness-tool-slots-burst 0)
        (harness-tool-slots-load-function (harness-tool-slots-load-test--load 1.5)))
    ;; Halfway up the range: half of the seven slots over the floor go.
    (harness-tool-slots-load-test--tick)
    (should (= 4 (harness-tool-slots--slots "local:test-machine")))
    (should (= 4 harness-tool-slots-load--limit))
    ;; A load at the high threshold leaves the floor, never nothing.
    (setq harness-tool-slots-load-function (harness-tool-slots-load-test--load 2.0)
          harness-tool-slots-load--changed-at nil)
    (harness-tool-slots-load-test--tick)
    (should (= 1 (harness-tool-slots--slots "local:test-machine")))
    ;; And more load than that is still the floor.
    (setq harness-tool-slots-load-function (harness-tool-slots-load-test--load 9.0)
          harness-tool-slots-load--changed-at nil)
    (harness-tool-slots-load-test--tick)
    (should (= 1 (harness-tool-slots--slots "local:test-machine")))))

(ert-deftest harness-tool-slots-load-more-load-never-means-more-slots ()
  "The limit falls with the load, or stays, but never rises with it."
  (harness-tool-slots-load-test--setup)
  (let ((harness-tool-slots-count 16)
        (harness-tool-slots-burst 0)
        (harness-tool-slots-load-low 1.0)
        (harness-tool-slots-load-high 2.0)
        (last most-positive-fixnum))
    ;; Every load from quiet to four times the machine's processors: the
    ;; number of slots never goes up, and never leaves floor..baseline.
    (dolist (pressure '(0.2 0.9 1.0 1.1 1.4 1.9 2.0 3.0))
      (setq harness-tool-slots-load-function
            (harness-tool-slots-load-test--load pressure)
            harness-tool-slots-load--changed-at nil
            harness-tool-slots-load--changed-pressure nil)
      (harness-tool-slots-load-test--tick)
      (let ((slots (harness-tool-slots--slots "local:test-machine")))
        (should (>= slots 1))
        (should (<= slots 16))
        (should (<= slots last))
        (setq last slots)))))

(ert-deftest harness-tool-slots-load-the-limit-never-goes-above-the-baseline ()
  "Whatever the options and the load say, the baseline is the ceiling."
  (harness-tool-slots-load-test--setup)
  ;; A floor above the baseline does not raise it, and neither does a
  ;; quiet machine: the plugin only ever takes slots away.
  (let ((harness-tool-slots-count 3)
        (harness-tool-slots-burst 0)
        (harness-tool-slots-load-floor 9)
        (harness-tool-slots-load-function (harness-tool-slots-load-test--load 0.1)))
    (harness-tool-slots-load-test--tick)
    (should (= 3 (harness-tool-slots--slots "local:test-machine")))
    (should-not harness-tool-slots-load--limit)
    (setq harness-tool-slots-load-function (harness-tool-slots-load-test--load 3.0)
          harness-tool-slots-load--changed-at nil)
    (harness-tool-slots-load-test--tick)
    (should (= 3 (harness-tool-slots--slots "local:test-machine"))))
  ;; Even a limit from elsewhere that is above the baseline is held down
  ;; to it: the number in force is the smaller of the two.
  (let ((harness-tool-slots-count 4)
        (harness-tool-slots-burst 1))
    (setq harness-tool-slots-load--limit 100)
    (should (= 5 (harness-tool-slots--slots "local:test-machine")))
    (setq harness-tool-slots-load--limit 3)
    (should (= 3 (harness-tool-slots--slots "local:test-machine")))))

(ert-deftest harness-tool-slots-load-only-this-machine-is-modulated ()
  "A local call is held back; a call on another host keeps the baseline."
  (harness-tool-slots-load-test--setup)
  (let ((harness-tool-slots-count 8)
        (harness-tool-slots-burst 0)
        (harness-tool-slots-load-function (harness-tool-slots-load-test--load 1.5)))
    (harness-tool-slots-load-test--tick)
    (should (= 4 (harness-tool-slots--slots "local:test-machine")))
    ;; The load of another host is not this machine's to read.
    (should (= 8 (harness-tool-slots--slots "host:example.invalid")))
    (should (= 8 (harness-tool-slots--slots "host:box")))
    ;; And a caller that does not say which machine means the baseline.
    (should (= 8 (harness-tool-slots--slots)))))

(ert-deftest harness-tool-slots-load-a-quiet-machine-gets-the-baseline-back ()
  "A load that falls restores the baseline exactly."
  (harness-tool-slots-load-test--setup)
  (let ((harness-tool-slots-count 8)
        (harness-tool-slots-burst 0)
        (harness-tool-slots-load-function (harness-tool-slots-load-test--load 2.0)))
    (harness-tool-slots-load-test--tick)
    (should (= 1 (harness-tool-slots--slots "local:test-machine")))
    (setq harness-tool-slots-load-function (harness-tool-slots-load-test--load 0.2)
          harness-tool-slots-load--changed-at nil)
    (harness-tool-slots-load-test--tick)
    (should (= 8 (harness-tool-slots--slots "local:test-machine")))
    (should-not harness-tool-slots-load--limit)
    ;; The reading that restored it is remembered: a nudge back up does
    ;; not take the slots away again at once (`harness-tool-slots-load-deadband').
    (should (= 0.2 harness-tool-slots-load--changed-pressure))))

(ert-deftest harness-tool-slots-load-a-load-it-cannot-read-changes-nothing ()
  "A machine that cannot report its load keeps the limit it has."
  (harness-tool-slots-load-test--setup)
  (let ((harness-tool-slots-count 8)
        (harness-tool-slots-burst 0)
        (harness-tool-slots-load-function (lambda (&optional _window) nil)))
    (harness-tool-slots-load-test--tick)
    (should (= 8 (harness-tool-slots--slots "local:test-machine")))
    (should-not harness-tool-slots-load--limit))
  ;; `load-average' signalling is the same: the limit is left alone, not
  ;; the whole reading thrown away.
  (let ((harness-tool-slots-count 8)
        (harness-tool-slots-burst 0)
        (harness-tool-slots-load-function (lambda (&optional _window) (error "No load here"))))
    (harness-tool-slots-load-test--tick)
    (should (= 8 (harness-tool-slots--slots "local:test-machine")))
    (should-not harness-tool-slots-load--limit)))

(ert-deftest harness-tool-slots-load-the-cooldown-holds-the-limit-still ()
  "A change waits for the cooldown, however the load moves within it."
  (harness-tool-slots-load-test--setup)
  (let ((harness-tool-slots-count 8)
        (harness-tool-slots-burst 0)
        (harness-tool-slots-load-cooldown 30.0)
        (harness-tool-slots-load-function (harness-tool-slots-load-test--load 1.5)))
    (harness-tool-slots-load-test--tick)
    (should (= 4 (harness-tool-slots--slots "local:test-machine")))
    ;; A spike right after is read, and the limit does not move.
    (setq harness-tool-slots-load-function (harness-tool-slots-load-test--load 4.0))
    (harness-tool-slots-load-test--tick)
    (should (= 4 (harness-tool-slots--slots "local:test-machine")))
    ;; Nor does a load that fell back within the cooldown.
    (setq harness-tool-slots-load-function (harness-tool-slots-load-test--load 0.1))
    (harness-tool-slots-load-test--tick)
    (should (= 4 (harness-tool-slots--slots "local:test-machine")))
    ;; Once the cooldown is over, the reading in force is taken.
    (setq harness-tool-slots-load--changed-at (- (float-time) 1000))
    (harness-tool-slots-load-test--tick)
    (should (= 8 (harness-tool-slots--slots "local:test-machine")))
    (should-not harness-tool-slots-load--limit)))

(ert-deftest harness-tool-slots-load-a-deadband-ignores-a-load-that-nudges ()
  "A load that moved only a nudge does not change the limit."
  (harness-tool-slots-load-test--setup)
  (let ((harness-tool-slots-count 8)
        (harness-tool-slots-burst 0)
        (harness-tool-slots-load-deadband 0.15)
        (harness-tool-slots-load-function (harness-tool-slots-load-test--load 1.5)))
    (harness-tool-slots-load-test--tick)
    (should (= 4 (harness-tool-slots--slots "local:test-machine")))
    ;; 1.6 would take a slot away, but it is only a nudge over the 1.5 the
    ;; last change was taken at.
    (setq harness-tool-slots-load-function (harness-tool-slots-load-test--load 1.6)
          harness-tool-slots-load--changed-at nil)
    (harness-tool-slots-load-test--tick)
    (should (= 4 (harness-tool-slots--slots "local:test-machine")))
    ;; A load that really moved does take it.
    (setq harness-tool-slots-load-function (harness-tool-slots-load-test--load 1.7)
          harness-tool-slots-load--changed-at nil)
    (harness-tool-slots-load-test--tick)
    (should (= 3 (harness-tool-slots--slots "local:test-machine")))))

(ert-deftest harness-tool-slots-load-waiting-calls-start-when-the-slots-rise ()
  "A limit that rises admits the calls waiting, at once and by priority."
  (harness-tool-slots-load-test--setup)
  (let ((harness-tool-slots-tools '("load-probe"))
        (harness-tool-slots-count 2)
        (harness-tool-slots-burst 0)
        (harness-tool-slots-machine-function #'harness-tool-slots-load-test--machine)
        (harness-tool-slots-load-function (harness-tool-slots-load-test--load 1.5)))
    (harness-tool-slots-load-test--probe "load-probe")
    (harness-tool-slots-load-test--tick)
    (should (= 1 (harness-tool-slots--slots "local:test-machine")))
    (let ((first (harness-tool-slots-load-test--call "load-probe"))
          (second (harness-tool-slots-load-test--call "load-probe"))
          (third (harness-tool-slots-load-test--call "load-probe")))
      ;; The machine's one slot is held; the other two calls wait.
      (should (equal '("load-probe") harness-tool-slots-load-test--started))
      (setq harness-tool-slots-load-function (harness-tool-slots-load-test--load 0.2)
            harness-tool-slots-load--changed-at nil)
      (harness-tool-slots-load-test--tick)
      ;; Back to the baseline of two: one waiting call starts there and
      ;; then, without another call having finished.
      (should (= 2 (harness-tool-slots--slots "local:test-machine")))
      (should (equal '("load-probe" "load-probe") harness-tool-slots-load-test--started))
      (harness-tool-slots-load-test--settle-all)
      (should (equal "load-probe" (harness-tool-slots-load-test--content first)))
      (should (equal "load-probe" (harness-tool-slots-load-test--content second)))
      (should (equal "load-probe" (harness-tool-slots-load-test--content third))))))

(ert-deftest harness-tool-slots-load-a-fall-leaves-the-running-calls-alone ()
  "A lower limit starts no new call, and the running ones finish."
  (harness-tool-slots-load-test--setup)
  (let ((harness-tool-slots-tools '("load-probe"))
        (harness-tool-slots-count 8)
        (harness-tool-slots-burst 0)
        (harness-tool-slots-machine-function #'harness-tool-slots-load-test--machine)
        (harness-tool-slots-load-function (harness-tool-slots-load-test--load 0.2)))
    (harness-tool-slots-load-test--probe "load-probe")
    (harness-tool-slots-load-test--tick)
    (let ((one (harness-tool-slots-load-test--call "load-probe"))
          (two (harness-tool-slots-load-test--call "load-probe"))
          (three (harness-tool-slots-load-test--call "load-probe")))
      ;; Three calls run at the baseline; the machine gets busy.
      (should (equal '("load-probe" "load-probe" "load-probe")
                     harness-tool-slots-load-test--started))
      (setq harness-tool-slots-load-function (harness-tool-slots-load-test--load 4.0)
            harness-tool-slots-load--changed-at nil)
      (harness-tool-slots-load-test--tick)
      (should (= 1 (harness-tool-slots--slots "local:test-machine")))
      ;; The calls running are left alone, and no fourth call starts.
      (should (equal '("load-probe" "load-probe" "load-probe")
                     harness-tool-slots-load-test--started))
      (let ((fourth (harness-tool-slots-load-test--call "load-probe")))
        (should (equal '("load-probe" "load-probe" "load-probe")
                       harness-tool-slots-load-test--started))
        (harness-tool-slots-load-test--settle-all)
        ;; Only once the machine is back under its limit does the next
        ;; call start, as each slot is given back (`harness-slots-admit').
        (should (equal "load-probe" (harness-tool-slots-load-test--content one)))
        (should (equal "load-probe" (harness-tool-slots-load-test--content two)))
        (should (equal "load-probe" (harness-tool-slots-load-test--content three)))
        ;; The settle of the three frees slots one by one, so the fourth
        ;; runs by the time they are done.
        (harness-tool-slots-load-test--settle-all)
        (should (equal "load-probe" (harness-tool-slots-load-test--content fourth)))))))

(ert-deftest harness-tool-slots-load-the-module-can-be-turned-off ()
  "Shutting the plugin down gives this machine its baseline slots at once."
  (harness-tool-slots-load-test--setup)
  (let ((harness-tool-slots-count 4)
        (harness-tool-slots-burst 0)
        (harness-tool-slots-load-function (harness-tool-slots-load-test--load 3.0)))
    (harness-tool-slots-load-test--tick)
    (should (= 1 (harness-tool-slots--slots "local:test-machine")))
    (harness-tool-slots-load--shutdown)
    (should-not (advice-member-p #'harness-tool-slots-load--slots-advice
                                 'harness-tool-slots--slots))
    (should-not harness-tool-slots-load--timer)
    (should-not harness-tool-slots-load--limit)
    (should (= 4 (harness-tool-slots--slots "local:test-machine")))
    ;; Starting it again watches the load as before.
    (harness-tool-slots-load--init)
    (should (= 1 (harness-tool-slots--slots "local:test-machine")))))

;;;; Which load average is read

(ert-deftest harness-tool-slots-load-the-five-minute-average-by-default ()
  "The plugin reads the 5-minute load average unless told otherwise."
  (harness-tool-slots-load-test--setup)
  (should (eql 5 (eval (car (get 'harness-tool-slots-load-window 'standard-value)) t)))
  ;; The window is what the load function is asked for.
  (let ((asked nil))
    (let ((harness-tool-slots-load-function
           (lambda (&optional window) (push window asked) 0.1)))
      (harness-tool-slots-load-test--tick)
      (let ((harness-tool-slots-load-window 15))
        (harness-tool-slots-load-test--tick)))
    (should (equal '(5 15) (reverse asked))))
  ;; And the default load function answers it from `load-average''s
  ;; three averages: the 1-, 5- and 15-minute ones, in that order.
  (cl-letf (((symbol-function 'load-average)
             (lambda (&optional _use-floats) (list 1.5 5.5 15.5))))
    (should (= 5.5 (harness-tool-slots-load-default-load 5)))
    (should (= 1.5 (harness-tool-slots-load-default-load 1)))
    (should (= 15.5 (harness-tool-slots-load-default-load 15)))
    ;; No window is the window configured.
    (let ((harness-tool-slots-load-window 15))
      (should (= 15.5 (harness-tool-slots-load-default-load))))
    (let ((harness-tool-slots-load-window 5))
      (should (= 5.5 (harness-tool-slots-load-default-load))))
    ;; There is no 10-minute average: a window between the ends reads the
    ;; 5-minute one, as does a window that is not a number, and one past
    ;; an end reads that end.
    (should (= 5.5 (harness-tool-slots-load-default-load 10)))
    (should (= 5.5 (harness-tool-slots-load-default-load 'fortnight)))
    (should (= 1.5 (harness-tool-slots-load-default-load 0.5)))
    (should (= 15.5 (harness-tool-slots-load-default-load 60))))
  ;; A system that keeps only the shorter averages gives the longest of
  ;; them, rather than no load at all.
  (cl-letf (((symbol-function 'load-average)
             (lambda (&optional _use-floats) (list 1.5))))
    (should (= 1.5 (harness-tool-slots-load-default-load 5)))
    (should (= 1.5 (harness-tool-slots-load-default-load 15))))
  (cl-letf (((symbol-function 'load-average)
             (lambda (&optional _use-floats) (list 1.5 5.5))))
    (should (= 5.5 (harness-tool-slots-load-default-load 15))))
  ;; One that keeps none gives nil, which leaves the limit alone.
  (cl-letf (((symbol-function 'load-average)
             (lambda (&optional _use-floats) nil)))
    (should-not (harness-tool-slots-load-default-load 5))))

(ert-deftest harness-tool-slots-load-a-burst-of-work-keeps-the-slots ()
  "A minute of heavy load leaves the slots; the 1-minute window would not."
  (harness-tool-slots-load-test--setup)
  (let ((harness-tool-slots-count 8)
        (harness-tool-slots-burst 0)
        (harness-tool-slots-load-function #'harness-tool-slots-load-default-load))
    ;; A test run of a minute: the 1-minute average is three times what
    ;; the processors can run, the 5-minute one -- the window read by
    ;; default -- has hardly moved.
    (cl-letf (((symbol-function 'load-average)
               (harness-tool-slots-load-test--averages 3.0 0.8 0.3)))
      (harness-tool-slots-load-test--tick)
      (should (= 8 (harness-tool-slots--slots "local:test-machine")))
      (should-not harness-tool-slots-load--limit)
      ;; Read over one minute, the same burst takes every slot but one.
      (let ((harness-tool-slots-load-window 1))
        (harness-tool-slots-load-test--tick)
        (should (= 1 (harness-tool-slots--slots "local:test-machine")))))))

(ert-deftest harness-tool-slots-load-a-load-that-lasts-takes-the-slots ()
  "A load that lasts reaches the 5-minute average, and the slots follow it."
  (harness-tool-slots-load-test--setup)
  (let ((harness-tool-slots-count 8)
        (harness-tool-slots-burst 0)
        (harness-tool-slots-load-function #'harness-tool-slots-load-default-load))
    ;; A build that goes on: the 5-minute average is up too, halfway up
    ;; the range, and half of the seven slots over the floor go.
    (cl-letf (((symbol-function 'load-average)
               (harness-tool-slots-load-test--averages 3.0 1.5 0.9)))
      (harness-tool-slots-load-test--tick)
      (should (= 4 (harness-tool-slots--slots "local:test-machine"))))
    ;; The build is over: the 1-minute average is quiet at once, but the
    ;; 5-minute one has not come down yet, and neither have the slots.
    (setq harness-tool-slots-load--changed-at nil)
    (cl-letf (((symbol-function 'load-average)
               (harness-tool-slots-load-test--averages 0.2 1.5 1.0)))
      (harness-tool-slots-load-test--tick)
      (should (= 4 (harness-tool-slots--slots "local:test-machine"))))
    ;; Once it has, the baseline is back.
    (cl-letf (((symbol-function 'load-average)
               (harness-tool-slots-load-test--averages 0.1 0.9 0.9)))
      (harness-tool-slots-load-test--tick)
      (should (= 8 (harness-tool-slots--slots "local:test-machine")))
      (should-not harness-tool-slots-load--limit))))

;;;; Telling the sessions

(ert-deftest harness-tool-slots-load-a-change-tells-every-active-session ()
  "Both directions of a change reach every active session, once.
A first change is a hint saying what changed, as ever; the way back up
joins it (see the tests of the note below)."
  (harness-tool-slots-load-test-with-sessions
    (let* ((cwd (harness-test-temp-dir))
           (first (plist-get (harness-call 'session/create :cwd cwd) :id))
           (second (plist-get (harness-call 'session/create :cwd cwd) :id))
           (closed (plist-get (harness-call 'session/create :cwd cwd) :id)))
      (harness-call 'session/deactivate closed)
      (let ((harness-tool-slots-count 8)
            (harness-tool-slots-burst 0)
            (harness-tool-slots-load-function (harness-tool-slots-load-test--load 1.5)))
        (harness-tool-slots-load-test--tick)
        (should (= 4 (harness-tool-slots--slots "local:test-machine")))
        (should (equal "Tool slots reduced from 8 to 4: system load 1.5x on this machine"
                       (harness-tool-slots-load-test--hint first)))
        (should (equal "Tool slots reduced from 8 to 4: system load 1.5x on this machine"
                       (harness-tool-slots-load-test--hint second)))
        ;; A session that is closed is left alone.
        (should-not (harness-tool-slots-load-test--hint closed))
        ;; The number did not change: the sessions are not told again.
        (let ((told (list (harness-tool-slots-load-test--hints first)
                          (harness-tool-slots-load-test--hints second))))
          (harness-tool-slots-load-test--tick)
          (should (equal told (list (harness-tool-slots-load-test--hints first)
                                    (harness-tool-slots-load-test--hints second)))))
        ;; The way back up is told too, in the note the first change began
        ;; rather than in another hint: one note holds the two changes.
        (harness-tool-slots-load-test--move 0.2)
        (should (= 8 (harness-tool-slots--slots "local:test-machine")))
        (dolist (id (list first second))
          (should (= 1 (length (harness-tool-slots-load-test--hints id))))
          (should (equal (list harness-tool-slots-load-test--reduced
                               harness-tool-slots-load-test--restored)
                         (harness-tool-slots-load-test--lines
                          (car (harness-tool-slots-load-test--notes id))))))
        (should-not (harness-tool-slots-load-test--notes closed))))))

;;;; One note per stretch of changes

(ert-deftest harness-tool-slots-load-the-first-change-reads-as-it-always-did ()
  "A change on its own is a hint with the one line, whatever else it holds.
Its fold, which the chat does not draw for one change, is there for the
next change to add to."
  (harness-tool-slots-load-test-with-sessions
    (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
          (harness-tool-slots-count 8)
          (harness-tool-slots-burst 0))
      (harness-tool-slots-load-test--move 1.5)
      (let* ((note (car (harness-tool-slots-load-test--notes id)))
             (fold (harness-node-fold note)))
        (should (equal harness-tool-slots-load-test--reduced (plist-get note :content)))
        (should (equal "tool-slots-load" (plist-get fold :key)))
        (should (equal "Slots changed due to system load" (plist-get fold :title)))
        (should (equal (list harness-tool-slots-load-test--reduced)
                       (harness-tool-slots-load-test--lines note)))
        (should (numberp (plist-get (car (plist-get fold :items)) :ts)))
        (should (= 1 (length (harness-call 'session/nodes id))))))))

(ert-deftest harness-tool-slots-load-the-changes-of-a-stretch-share-one-note ()
  "A change within the window joins the session's note, in place.
Whatever the session did since the note was written -- messages, tool
calls -- the note stays where it is and gains a line, and no hint is
added where the session now is."
  (harness-tool-slots-load-test-with-sessions
    (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
          (harness-tool-slots-count 8)
          (harness-tool-slots-burst 0))
      (harness-call 'session/append id '(:kind user :content "go"))
      (harness-tool-slots-load-test--move 1.5)
      (let ((note-id (plist-get (car (harness-tool-slots-load-test--notes id)) :id)))
        (harness-call 'session/append id '(:kind assistant :content "on it"))
        (harness-call 'session/append id '(:kind tool-call :tool "bash" :call-id "c1" :input (:command "ls")))
        (harness-call 'session/append id '(:kind tool-result :call-id "c1" :output "a b"))
        (harness-tool-slots-load-test--move 0.2)
        (harness-call 'session/append id '(:kind assistant :content "still on it"))
        (harness-tool-slots-load-test--move 2.0)
        ;; One hint, the one the first change wrote, and it is not the
        ;; session's newest node: it was updated where it stands.
        (should (= 1 (length (harness-tool-slots-load-test--hints id))))
        (should (= 1 (length (harness-tool-slots-load-test--notes id))))
        (let ((note (car (harness-tool-slots-load-test--notes id))))
          (should (equal note-id (plist-get note :id)))
          (should-not (equal note-id (plist-get (harness-call 'session/get id) :head)))
          (should (equal (list harness-tool-slots-load-test--reduced
                               harness-tool-slots-load-test--restored
                               harness-tool-slots-load-test--floor)
                         (harness-tool-slots-load-test--lines note)))
          (should (equal "Slots changed due to system load (3 changes)"
                         (plist-get (harness-node-fold note) :title)))
          ;; Its plain text, for what does not fold: the title, then a line
          ;; to a change, each with the time it came.
          (let ((lines (split-string (plist-get note :content) "\n")))
            (should (equal "Slots changed due to system load (3 changes)" (car lines)))
            (should (= 4 (length lines)))
            (cl-loop for line in (cdr lines)
                     for text in (harness-tool-slots-load-test--lines note)
                     do (should (string-match (concat "\\`[0-9][0-9]:[0-9][0-9]:[0-9][0-9]  "
                                                      (regexp-quote text) "\\'")
                                              line))))
          ;; The changes came one after another.
          (let ((times (mapcar (lambda (item) (plist-get item :ts))
                               (plist-get (harness-node-fold note) :items))))
            (should (equal times (sort (copy-sequence times) #'<)))))))))

(ert-deftest harness-tool-slots-load-each-session-keeps-a-note-of-its-own ()
  "A session that was told later joins no one else's note, and has its own."
  (harness-tool-slots-load-test-with-sessions
    (let* ((cwd (harness-test-temp-dir))
           (first (plist-get (harness-call 'session/create :cwd cwd) :id))
           (harness-tool-slots-count 8)
           (harness-tool-slots-burst 0))
      (harness-tool-slots-load-test--move 1.5)
      (let ((second (plist-get (harness-call 'session/create :cwd cwd) :id)))
        (harness-tool-slots-load-test--move 0.2)
        (should (equal (list harness-tool-slots-load-test--reduced
                             harness-tool-slots-load-test--restored)
                       (harness-tool-slots-load-test--lines
                        (car (harness-tool-slots-load-test--notes first)))))
        ;; The second session heard only of the change it was there for.
        (should (equal (list harness-tool-slots-load-test--restored)
                       (harness-tool-slots-load-test--lines
                        (car (harness-tool-slots-load-test--notes second)))))
        (should (equal harness-tool-slots-load-test--restored
                       (plist-get (car (harness-tool-slots-load-test--notes second)) :content)))))))

(ert-deftest harness-tool-slots-load-a-change-after-a-quiet-spell-starts-a-note ()
  "A change later than the window after the note's last starts a note of its own.
The transcript then shows where in the session's work the load moved."
  (harness-tool-slots-load-test-with-sessions
    (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
          (harness-tool-slots-count 8)
          (harness-tool-slots-burst 0))
      (should (> harness-tool-slots-load--note-window 0))
      (harness-tool-slots-load-test--move 1.5)
      (let ((harness-tool-slots-load--note-window 0.0))
        (harness-call 'session/append id '(:kind assistant :content "much later"))
        (harness-tool-slots-load-test--move 0.2))
      (let ((notes (harness-tool-slots-load-test--notes id)))
        (should (= 2 (length notes)))
        (should (equal harness-tool-slots-load-test--reduced (plist-get (car notes) :content)))
        (should (equal harness-tool-slots-load-test--restored (plist-get (cadr notes) :content)))
        (should (equal (list harness-tool-slots-load-test--restored)
                       (harness-tool-slots-load-test--lines (cadr notes)))))
      ;; The newest note is the one the next change joins, not the first.
      (harness-tool-slots-load-test--move 2.0)
      (let ((notes (harness-tool-slots-load-test--notes id)))
        (should (= 2 (length notes)))
        (should (= 1 (length (harness-tool-slots-load-test--lines (car notes)))))
        (should (equal (list harness-tool-slots-load-test--restored
                             harness-tool-slots-load-test--floor)
                       (harness-tool-slots-load-test--lines (cadr notes))))))))

(ert-deftest harness-tool-slots-load-the-window-is-counted-from-the-last-change ()
  "A note stays open while the changes keep coming, however long it has been.
Its window is that of its last change, not of its first."
  (harness-tool-slots-load-test-with-sessions
    (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
          (harness-tool-slots-count 8)
          (harness-tool-slots-burst 0)
          (harness-tool-slots-load-test--clock 1000.0))
      (cl-letf (((symbol-function 'float-time)
                 (lambda (&optional _) harness-tool-slots-load-test--clock)))
        ;; Four changes, 400 seconds apart: 1200 seconds from the first
        ;; to the last, which is twice the window of 600.
        (dolist (load '(1.5 0.2 1.5 0.2))
          (harness-tool-slots-load-test--move load)
          (cl-incf harness-tool-slots-load-test--clock 400.0))
        (should (= 1 (length (harness-tool-slots-load-test--notes id))))
        (should (= 4 (length (harness-tool-slots-load-test--lines
                              (car (harness-tool-slots-load-test--notes id))))))
        ;; The clock is 400 seconds past the last change: inside the window.
        ;; At 700 it is outside.
        (cl-incf harness-tool-slots-load-test--clock 300.0)
        (harness-tool-slots-load-test--move 1.5)
        (should (= 2 (length (harness-tool-slots-load-test--notes id))))
        (should (equal (list harness-tool-slots-load-test--reduced)
                       (harness-tool-slots-load-test--lines
                        (cadr (harness-tool-slots-load-test--notes id)))))))))

(ert-deftest harness-tool-slots-load-a-full-note-is-closed ()
  "A note that holds as many changes as it may is closed, and the next starts another."
  (harness-tool-slots-load-test-with-sessions
    (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
          (harness-tool-slots-count 8)
          (harness-tool-slots-burst 0)
          (harness-tool-slots-load--note-limit 2))
      (harness-tool-slots-load-test--move 1.5)
      (harness-tool-slots-load-test--move 0.2)
      (should (= 1 (length (harness-tool-slots-load-test--notes id))))
      (harness-tool-slots-load-test--move 2.0)
      (let ((notes (harness-tool-slots-load-test--notes id)))
        (should (= 2 (length notes)))
        (should (= 2 (length (harness-tool-slots-load-test--lines (car notes)))))
        (should (equal (list harness-tool-slots-load-test--floor)
                       (harness-tool-slots-load-test--lines (cadr notes))))))))

(ert-deftest harness-tool-slots-load-a-note-off-the-branch-is-left-alone ()
  "A session that went back before its note does not add to the note.
The note is on a branch the session left; the change is told where the
session is, in a note of its own."
  (harness-tool-slots-load-test-with-sessions
    (let* ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
           (start (plist-get (harness-call 'session/append id '(:kind user :content "go")) :id))
           (harness-tool-slots-count 8)
           (harness-tool-slots-burst 0))
      (harness-tool-slots-load-test--move 1.5)
      (let ((old (car (harness-tool-slots-load-test--notes id))))
        (harness-call 'session/set-head id start)
        (should-not (harness-tool-slots-load-test--notes id))
        (harness-tool-slots-load-test--move 0.2)
        (let ((now (car (harness-tool-slots-load-test--notes id))))
          (should-not (equal (plist-get old :id) (plist-get now :id)))
          (should (equal (list harness-tool-slots-load-test--restored)
                         (harness-tool-slots-load-test--lines now))))
        ;; The note on the branch left is as it was.
        (should (equal (list harness-tool-slots-load-test--reduced)
                       (harness-tool-slots-load-test--lines
                        (harness-call 'session/node id (plist-get old :id)))))))))

(ert-deftest harness-tool-slots-load-another-modules-fold-is-not-ours ()
  "A hint that folds for another module is left as it is."
  (harness-tool-slots-load-test-with-sessions
    (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
          (harness-tool-slots-count 8)
          (harness-tool-slots-burst 0))
      (let ((other (harness-call 'session/append id
                                 (list :kind 'hint :content "Other things\nthing"
                                       :meta (list :fold (list :key "other" :title "Other things"
                                                               :items (list (list :ts (float-time) :text "thing"))))))))
        (harness-tool-slots-load-test--move 1.5)
        (should (equal '("thing") (harness-tool-slots-load-test--lines
                                   (harness-call 'session/node id (plist-get other :id)))))
        (should (= 2 (length (harness-tool-slots-load-test--notes id))))
        (should (equal (list harness-tool-slots-load-test--reduced)
                       (harness-tool-slots-load-test--lines
                        (cadr (harness-tool-slots-load-test--notes id)))))))))

(ert-deftest harness-tool-slots-load-a-note-that-cannot-be-added-to-is-replaced ()
  "A session is told even when its note went while the change was on its way."
  (harness-tool-slots-load-test-with-sessions
    (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
          (harness-tool-slots-count 8)
          (harness-tool-slots-burst 0))
      (harness-tool-slots-load-test--move 1.5)
      (cl-letf (((symbol-function 'harness-tool-slots-load--note-add)
                 (lambda (&rest _) (error "The note is gone"))))
        (harness-tool-slots-load-test--move 0.2))
      (let ((notes (harness-tool-slots-load-test--notes id)))
        (should (= 2 (length notes)))
        (should (equal (list harness-tool-slots-load-test--restored)
                       (harness-tool-slots-load-test--lines (cadr notes))))))))

(ert-deftest harness-tool-slots-load-a-session-that-cannot-be-told-leaves-the-others-told ()
  "A session that goes while the message is on its way is skipped."
  (harness-tool-slots-load-test-with-sessions
    (let* ((cwd (harness-test-temp-dir))
           (gone (plist-get (harness-call 'session/create :cwd cwd) :id))
           (kept (plist-get (harness-call 'session/create :cwd cwd) :id))
           (note (symbol-function 'harness-tool-slots-load--note))
           (harness-tool-slots-count 8)
           (harness-tool-slots-burst 0))
      (cl-letf (((symbol-function 'harness-tool-slots-load--note)
                 (lambda (id &rest args)
                   (if (equal id gone) (error "No session %s" id) (apply note id args)))))
        (harness-tool-slots-load-test--move 1.5))
      (should (= 4 (harness-tool-slots--slots "local:test-machine")))
      (should-not (harness-tool-slots-load-test--notes gone))
      (should (equal (list harness-tool-slots-load-test--reduced)
                     (harness-tool-slots-load-test--lines
                      (car (harness-tool-slots-load-test--notes kept))))))))

(ert-deftest harness-tool-slots-load-the-note-outlives-a-restart ()
  "A note read back from the node log is the one the next change joins."
  (harness-tool-slots-load-test-with-sessions
    (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
          (harness-tool-slots-count 8)
          (harness-tool-slots-burst 0))
      (harness-tool-slots-load-test--move 1.5)
      (harness-tool-slots-load-test--move 0.2)
      (let ((before (car (harness-tool-slots-load-test--notes id))))
        (harness-session-flush)
        (clrhash harness-sessions)
        (harness-session--load-all)
        (harness-call 'session/resume id)
        (let ((after (car (harness-tool-slots-load-test--notes id))))
          (should (equal (plist-get before :id) (plist-get after :id)))
          (should (equal (plist-get before :content) (plist-get after :content)))
          (should (equal (harness-node-fold before) (harness-node-fold after))))
        (harness-tool-slots-load-test--move 2.0)
        (should (= 1 (length (harness-tool-slots-load-test--notes id))))
        (should (equal (list harness-tool-slots-load-test--reduced
                             harness-tool-slots-load-test--restored
                             harness-tool-slots-load-test--floor)
                       (harness-tool-slots-load-test--lines
                        (car (harness-tool-slots-load-test--notes id)))))
        ;; And the update was written too: the next restart reads it.
        (harness-session-flush)
        (clrhash harness-sessions)
        (harness-session--load-all)
        (should (= 3 (length (harness-tool-slots-load-test--lines
                              (car (harness-tool-slots-load-test--notes id))))))))))

;;;; The slots as they stand
;;
;; The notes are the history; a UI shows how the slots stand now, from
;; `tool-slots/status' and each `tool-slots/changed'.

(defvar harness-tool-slots-load-test--changes nil
  "The states `tool-slots/changed' announced, newest first.")

(defun harness-tool-slots-load-test--listen ()
  "Collect what `tool-slots/changed' announces in `harness-tool-slots-load-test--changes'."
  (setq harness-tool-slots-load-test--changes nil)
  (harness-on 'tool-slots/changed
              (lambda (state) (push state harness-tool-slots-load-test--changes))))

(ert-deftest harness-tool-slots-load-the-state-says-how-the-slots-stand ()
  "The state is the limit in force, the most there are, and what took it.
A machine with all its slots has the limit and the baseline alike and
nothing to say of a change; one held back has the load that took the
limit, what the sessions were told and when; `tool-slots/status' gives
the same."
  (harness-tool-slots-load-test-with-sessions
    (let ((harness-tool-slots-count 8)
          (harness-tool-slots-burst 0))
      (let ((state (harness-tool-slots-load--state)))
        (should (= 8 (plist-get state :limit)))
        (should (= 8 (plist-get state :baseline)))
        (should-not (plist-get state :pressure))
        (should-not (plist-get state :text))
        (should-not (plist-get state :at)))
      (harness-tool-slots-load-test--move 1.5)
      (let ((state (harness-tool-slots-load--state)))
        (should (= 4 (plist-get state :limit)))
        (should (= 8 (plist-get state :baseline)))
        (should (= 1.5 (plist-get state :pressure)))
        (should (equal harness-tool-slots-load-test--reduced (plist-get state :text)))
        (should (numberp (plist-get state :at)))
        ;; Clients ask for it by name.
        (should (equal state (harness-call 'tool-slots/status))))
      ;; The way back up: all the slots, and what said so.
      (harness-tool-slots-load-test--move 0.2)
      (let ((state (harness-call 'tool-slots/status)))
        (should (= 8 (plist-get state :limit)))
        (should (= 8 (plist-get state :baseline)))
        (should (equal harness-tool-slots-load-test--restored (plist-get state :text)))))))

(ert-deftest harness-tool-slots-load-every-change-is-announced-to-the-uis ()
  "Each change of the limit is announced once, with the state it leaves.
The number staying where it was announces nothing; the watch turned off
while the slots are held back does, as the baseline comes back."
  (harness-tool-slots-load-test-with-sessions
    (let ((harness-tool-slots-count 8)
          (harness-tool-slots-burst 0))
      (harness-tool-slots-load-test--listen)
      (harness-tool-slots-load-test--move 1.5)
      (should (= 1 (length harness-tool-slots-load-test--changes)))
      (let ((state (car harness-tool-slots-load-test--changes)))
        (should (= 4 (plist-get state :limit)))
        (should (= 8 (plist-get state :baseline)))
        (should (= 1.5 (plist-get state :pressure)))
        (should (equal harness-tool-slots-load-test--reduced (plist-get state :text))))
      ;; The same number again: no news.
      (harness-tool-slots-load-test--tick)
      (should (= 1 (length harness-tool-slots-load-test--changes)))
      ;; Further down, and back up.
      (harness-tool-slots-load-test--move 2.0)
      (should (= 1 (plist-get (car harness-tool-slots-load-test--changes) :limit)))
      (harness-tool-slots-load-test--move 0.2)
      (should (= 8 (plist-get (car harness-tool-slots-load-test--changes) :limit)))
      (should (= 3 (length harness-tool-slots-load-test--changes)))
      ;; Held back again, then the watch is turned off.
      (harness-tool-slots-load-test--move 1.5)
      (let ((harness-tool-slots-load-enabled nil))
        (harness-tool-slots-load-test--tick))
      (let ((state (car harness-tool-slots-load-test--changes)))
        (should (= 5 (length harness-tool-slots-load-test--changes)))
        (should (= 8 (plist-get state :limit)))
        (should (equal "Tool slots restored to 8: the load watch is off" (plist-get state :text)))
        (should-not (plist-get state :pressure))))))

(ert-deftest harness-tool-slots-load-shutting-down-tells-the-uis-the-slots-are-back ()
  "A UI showing the slots held back is told they are not once the module stops.
The sessions are not told, nor is a UI of slots that were not held back."
  (harness-tool-slots-load-test-with-sessions
    (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
          (harness-tool-slots-count 8)
          (harness-tool-slots-burst 0))
      ;; Nothing held back: nothing to take away.
      (harness-tool-slots-load-test--listen)
      (harness-tool-slots-load--shutdown)
      (should-not harness-tool-slots-load-test--changes)
      (harness-tool-slots-load--init)
      (harness-tool-slots-load-test--move 1.5)
      (should (= 1 (length harness-tool-slots-load-test--changes)))
      (harness-tool-slots-load--shutdown)
      (should (= 2 (length harness-tool-slots-load-test--changes)))
      (let ((state (car harness-tool-slots-load-test--changes)))
        (should (= 8 (plist-get state :limit)))
        (should (= 8 (plist-get state :baseline)))
        (should-not (plist-get state :text))
        (should-not (plist-get state :at)))
      ;; The session heard of the one change, not of this.
      (should (equal (list harness-tool-slots-load-test--reduced)
                     (harness-tool-slots-load-test--lines
                      (car (harness-tool-slots-load-test--notes id))))))))

(ert-deftest harness-tool-slots-load-the-slots-reach-clients ()
  "Clients ask how the slots stand and hear when they change."
  (harness-test-load-module 'acp)
  (should (harness-acp--extension-allowed-p "tool-slots/status"))
  (should (memq 'tool-slots/changed harness-acp--forwarded-events)))

;;;; Who is using the slots
;;
;; Beside the limit, the state says which session's call of which tool
;; holds each slot and who waits, machine by machine, and the event
;; announces it when that changes -- once for a burst of calls.

(defun harness-tool-slots-load-test--machines (&optional state)
  "Return the :machines of STATE, by default the state as it is now, keyed by machine."
  (mapcar (lambda (machine) (cons (plist-get machine :machine) machine))
          (plist-get (or state (harness-tool-slots-load--state)) :machines)))

(ert-deftest harness-tool-slots-load-the-state-says-who-is-using-the-slots ()
  "The state lists the calls using the slots, and `tool-slots/status' says the same.
A call holding a slot is listed with its session, name, tool and since
when; one waiting is, after it, with its priority.  This machine is
there with no call too."
  (harness-tool-slots-load-test-with-sessions
    (let* ((cwd (harness-test-temp-dir))
           (build (plist-get (harness-call 'session/create :cwd cwd :name "Fix the build") :id))
           (docs (plist-get (harness-call 'session/create :cwd cwd :name "Write the docs") :id))
           (harness-tool-slots-tools '("load-probe"))
           (harness-tool-slots-count 1)
           (harness-tool-slots-burst 0)
           (harness-tool-slots-machine-function #'harness-tool-slots-load-test--machine))
      (harness-tool-slots-load-test--probe "load-probe")
      ;; Idle: this machine, listed, with nobody on it.
      (let ((machines (plist-get (harness-tool-slots-load--state) :machines)))
        (should (= 1 (length machines)))
        (should (equal "this machine" (plist-get (car machines) :label)))
        (should (= 0 (plist-get (car machines) :running)))
        (should-not (plist-get (car machines) :holders)))
      (harness-call 'priority/set docs "high")
      (let* ((before (float-time))
             (first (harness-tool-slots-load-test--call
                     "load-probe" (list :cwd (file-name-as-directory cwd) :session-id build)))
             (second (harness-tool-slots-load-test--call
                      "load-probe" (list :cwd (file-name-as-directory cwd) :session-id docs)))
             (after (float-time))
             (state (harness-tool-slots-load--state))
             (machine (cdr (assoc "local:test-machine" (harness-tool-slots-load-test--machines state)))))
        (should (= 1 (plist-get machine :limit)))
        (should (= 1 (plist-get machine :running)))
        (let ((holder (car (plist-get machine :holders))))
          (should (equal (list build "Fix the build" "load-probe" "medium")
                         (list (plist-get holder :session) (plist-get holder :name)
                               (plist-get holder :tool) (plist-get holder :priority))))
          (should (<= before (plist-get holder :started) after)))
        (let ((waiter (car (plist-get machine :waiters))))
          (should (equal (list docs "Write the docs" "load-probe" "high")
                         (list (plist-get waiter :session) (plist-get waiter :name)
                               (plist-get waiter :tool) (plist-get waiter :priority))))
          (should (<= before (plist-get waiter :asked) after)))
        ;; The limit and the rest of the state are still there, and clients ask by name.
        (should (= 1 (plist-get state :limit)))
        (should (equal state (harness-call 'tool-slots/status)))
        (harness-tool-slots-load-test--settle-all)
        (should (equal "load-probe" (harness-tool-slots-load-test--content first)))
        (should (equal "load-probe" (harness-tool-slots-load-test--content second)))))))

(ert-deftest harness-tool-slots-load-the-limit-of-a-machine-is-the-one-in-force ()
  "A machine held back lists the limit it is held to, and one that is not the baseline."
  (harness-tool-slots-load-test-with-sessions
    (let ((harness-tool-slots-count 8)
          (harness-tool-slots-burst 0)
          (local (harness-tool-slots--local-machine)))
      (should (= 8 (plist-get (cdr (assoc local (harness-tool-slots-load-test--machines))) :limit)))
      (harness-tool-slots-load-test--move 1.5)
      (should (= 4 (plist-get (cdr (assoc local (harness-tool-slots-load-test--machines))) :limit)))
      (should (= 4 (plist-get (harness-tool-slots-load--state) :limit)))
      ;; Another host is not held back by this machine's load.
      (let ((harness-tool-slots-tools '("load-probe"))
            (harness-tool-slots-machine-function (lambda (&rest _) "host:build")))
        (harness-tool-slots-load-test--probe "load-probe")
        (let ((call (harness-tool-slots-load-test--call "load-probe")))
          (should (= 8 (plist-get (cdr (assoc "host:build" (harness-tool-slots-load-test--machines)))
                                  :limit)))
          (should (equal "build" (plist-get (cdr (assoc "host:build" (harness-tool-slots-load-test--machines)))
                                            :label)))
          (harness-tool-slots-load-test--settle-all)
          (should (equal "load-probe" (harness-tool-slots-load-test--content call))))))))

(ert-deftest harness-tool-slots-load-a-burst-of-calls-is-announced-once ()
  "Calls starting, waiting and ending are announced after a moment, once.
The announcement is the state as it is when it is sent, so it has all
the calls of the burst; the next change is announced the same way.  No
announcement comes at the moment of the change."
  (harness-tool-slots-load-test-with-sessions
    (let ((harness-tool-slots-tools '("load-probe"))
          (harness-tool-slots-count 2)
          (harness-tool-slots-burst 0)
          (harness-tool-slots-machine-function #'harness-tool-slots-load-test--machine)
          (harness-tool-slots-load--notify-delay 0.05))
      (harness-tool-slots-load-test--probe "load-probe")
      (harness-tool-slots-load-test--listen)
      (let ((calls (mapcar (lambda (id)
                             (harness-tool-slots-load-test--call
                              "load-probe" (list :cwd (file-name-as-directory default-directory)
                                                 :session-id id)))
                           '("s1" "s2" "s3" "s4"))))
        (should-not harness-tool-slots-load-test--changes)
        (harness-test-wait (lambda () harness-tool-slots-load-test--changes) 5 "the announcement")
        ;; Let anything else that is due come too: there is nothing.
        (accept-process-output nil 0.15)
        (should (= 1 (length harness-tool-slots-load-test--changes)))
        (let ((machine (cdr (assoc "local:test-machine"
                                   (harness-tool-slots-load-test--machines
                                    (car harness-tool-slots-load-test--changes))))))
          (should (equal '("s1" "s2") (mapcar (lambda (h) (plist-get h :session))
                                              (plist-get machine :holders))))
          (should (equal '("s3" "s4") (mapcar (lambda (w) (plist-get w :session))
                                              (plist-get machine :waiters)))))
        ;; Two calls end and the waiters start: announced once again.
        (setq harness-tool-slots-load-test--changes nil)
        (harness-tool-slots-load-test--settle-oldest)
        (harness-tool-slots-load-test--settle-oldest)
        (should-not harness-tool-slots-load-test--changes)
        (harness-test-wait (lambda () harness-tool-slots-load-test--changes) 5 "the next announcement")
        (accept-process-output nil 0.15)
        (should (= 1 (length harness-tool-slots-load-test--changes)))
        (let ((machine (cdr (assoc "local:test-machine"
                                   (harness-tool-slots-load-test--machines
                                    (car harness-tool-slots-load-test--changes))))))
          (should (equal '("s3" "s4") (mapcar (lambda (h) (plist-get h :session))
                                              (plist-get machine :holders))))
          (should-not (plist-get machine :waiters)))
        (harness-tool-slots-load-test--settle-all)
        (dolist (call calls) (harness-await call 5))))))

(ert-deftest harness-tool-slots-load-a-steady-stream-is-still-announced ()
  "The delay runs from the first change of a stretch, so a stream of calls never starves it.
A change while an announcement is due adds none and moves none."
  (harness-tool-slots-load-test-with-sessions
    (let ((harness-tool-slots-load--notify-delay 30))
      (should-not harness-tool-slots-load--notify-timer)
      (harness-tool-slots-load--notify-soon "one")
      (let ((timer harness-tool-slots-load--notify-timer))
        (should (timerp timer))
        (harness-tool-slots-load--notify-soon "two")
        (harness-tool-slots-load--notify-soon "three")
        (should (eq timer harness-tool-slots-load--notify-timer)))
      ;; It fires as it is due, and the next change starts the next.
      (harness-tool-slots-load-test--listen)
      (harness-tool-slots-load--notify-now)
      (should (= 1 (length harness-tool-slots-load-test--changes)))
      (should-not harness-tool-slots-load--notify-timer)
      (harness-tool-slots-load--notify-soon "four")
      (should (timerp harness-tool-slots-load--notify-timer))
      (harness-tool-slots-load--notify-cancel)
      (should-not harness-tool-slots-load--notify-timer))))

(ert-deftest harness-tool-slots-load-the-announcement-follows-the-module ()
  "The announcement is subscribed while the module runs, and a due one goes with it."
  (harness-tool-slots-load-test-with-sessions
    (let ((harness-tool-slots-tools '("load-probe"))
          (harness-tool-slots-count 2)
          (harness-tool-slots-burst 0)
          (harness-tool-slots-machine-function #'harness-tool-slots-load-test--machine)
          (harness-tool-slots-load--notify-delay 30))
      (harness-tool-slots-load-test--probe "load-probe")
      ;; A call is a change that is announced soon.
      (let ((call (harness-tool-slots-load-test--call "load-probe")))
        (should (timerp harness-tool-slots-load--notify-timer))
        (harness-tool-slots-load--shutdown)
        ;; Stopped: the due announcement is gone, and a change brings none.
        (should-not harness-tool-slots-load--notify-timer)
        (harness-tool-slots-load-test--settle-all)
        (harness-await call 5)
        (let ((other (harness-tool-slots-load-test--call "load-probe")))
          (should-not harness-tool-slots-load--notify-timer)
          (harness-tool-slots-load-test--settle-all)
          (harness-await other 5)))
      ;; Started again, it is subscribed again, once.
      (harness-tool-slots-load--init)
      (harness-tool-slots-load--init)
      (let ((call (harness-tool-slots-load-test--call "load-probe")))
        (should (timerp harness-tool-slots-load--notify-timer))
        (harness-tool-slots-load--notify-cancel)
        (harness-tool-slots-load-test--settle-all)
        (harness-await call 5)))))

(ert-deftest harness-tool-slots-load-the-load-watch-going-off-is-told-in-the-note ()
  "Turning the watch off tells the sessions the baseline is back, in the note."
  (harness-tool-slots-load-test-with-sessions
    (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
          (harness-tool-slots-count 8)
          (harness-tool-slots-burst 0))
      (harness-tool-slots-load-test--move 1.5)
      (let ((harness-tool-slots-load-enabled nil))
        (harness-tool-slots-load-test--tick))
      (should (= 1 (length (harness-tool-slots-load-test--notes id))))
      (should (equal (list harness-tool-slots-load-test--reduced
                           "Tool slots restored to 8: the load watch is off")
                     (harness-tool-slots-load-test--lines
                      (car (harness-tool-slots-load-test--notes id))))))))

(provide 'harness-tool-slots-load-test)
;;; harness-tool-slots-load-test.el ends here
