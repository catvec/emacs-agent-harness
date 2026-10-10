;;; harness-tool-slots-load-test.el --- Tests for the load-aware tool slots plugin  -*- lexical-binding: t; -*-

;;; Commentary:

;; The plugin (lisp/modules/harness-tool-slots-load.el) lowers this
;; machine's tool slots while its load average is high.  The load is
;; stubbed (`harness-tool-slots-load-function') so that a test says
;; exactly what kind of machine it is, and `--tick' takes one reading,
;; as the plugin's timer would; the plugin's own timer is stopped by the
;; tests' setup, which also loads the plugin before each test.

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
        ;; call start, as each slot is given back (`harness-tool-slots--give').
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

;;;; Telling the sessions

(ert-deftest harness-tool-slots-load-a-change-tells-every-active-session ()
  "Both directions of a change reach every active session, once."
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
        ;; The way back up is told too.
        (setq harness-tool-slots-load-function (harness-tool-slots-load-test--load 0.2)
              harness-tool-slots-load--changed-at nil)
        (harness-tool-slots-load-test--tick)
        (should (= 8 (harness-tool-slots--slots "local:test-machine")))
        (should (equal "Tool slots restored to 8: system load back to normal"
                       (harness-tool-slots-load-test--hint first)))
        (should (equal 2 (length (harness-tool-slots-load-test--hints first))))))))

(provide 'harness-tool-slots-load-test)
;;; harness-tool-slots-load-test.el ends here
