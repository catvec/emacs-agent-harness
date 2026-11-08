;;; harness-tool-slots-test.el --- Tests for the tool slots plugin  -*- lexical-binding: t; -*-

;;; Commentary:

;; The plugin (lisp/modules/harness-tool-slots.el) holds a few slots per
;; machine for the calls of the tools that start processes.  Its calls
;; are driven through `harness-tools--run-handler', the point the plugin
;; advises, with probes whose handlers hold a promise until the test
;; settles it: a probe whose handler ran is one the plugin let start.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-slots)

;;;; The probes

(defvar harness-tool-slots-test--started nil
  "Names of the probe calls whose handler ran, in the order they ran.")

(defvar harness-tool-slots-test--waiting nil
  "The probes that started and are held, newest first, as (NAME . RESOLVE).")

(defun harness-tool-slots-test--probe (name)
  "Define tool NAME: a probe whose handler holds until the test settles it.
A call appends NAME to `harness-tool-slots-test--started' when its
handler runs, which is when the plugin has given it a slot.  Return NAME."
  (harness-define-tool name
    :label name :description "A probe that holds until settled" :kind 'exec
    :handler (lambda (_input _ctx)
               (harness-with-promise (resolve reject)
                 (ignore reject)
                 (setq harness-tool-slots-test--started
                       (append harness-tool-slots-test--started (list name)))
                 (push (cons name resolve) harness-tool-slots-test--waiting))))
  name)

(defun harness-tool-slots-test--settle-oldest ()
  "Settle the probe that has been running longest; return its name."
  (let ((entry (car (last harness-tool-slots-test--waiting))))
    (setq harness-tool-slots-test--waiting (butlast harness-tool-slots-test--waiting))
    (funcall (cdr entry) (harness-tool-ok (car entry)))
    (car entry)))

(defun harness-tool-slots-test--settle-all ()
  "Settle every probe that is held."
  (while harness-tool-slots-test--waiting
    (harness-tool-slots-test--settle-oldest)))

(defun harness-tool-slots-test--setup ()
  "Load the plugin and start from fresh slots and records."
  (harness-test-load-module 'tools)
  (harness-test-load-module 'tool-slots)
  (harness-tool-slots-test--reset))

(defun harness-tool-slots-test--reset ()
  "Forget the slots and the probes of an earlier test."
  (clrhash harness-tool-slots--machines)
  (setq harness-tool-slots-test--started nil
        harness-tool-slots-test--waiting nil))

(defun harness-tool-slots-test--pool (machine)
  "Return the pool of slots MACHINE has, nil while it has none."
  (gethash machine harness-tool-slots--machines))

(defun harness-tool-slots-test--running (machine)
  "Return how many calls hold a slot of MACHINE, 0 while it has no pool."
  (let ((pool (harness-tool-slots-test--pool machine)))
    (if pool (harness-slots-running pool) 0)))

(defun harness-tool-slots-test--waiting (machine)
  "Return how many calls wait for a slot of MACHINE, 0 while it has no pool."
  (let ((pool (harness-tool-slots-test--pool machine)))
    (if pool (harness-slots-waiting pool) 0)))

(defun harness-tool-slots-test--idle-p (machine)
  "Non-nil when MACHINE has a pool of slots and no call holds one or waits.
A machine keeps its pool once its last call is done."
  (and (harness-tool-slots-test--pool machine)
       (= 0 (harness-tool-slots-test--running machine))
       (= 0 (harness-tool-slots-test--waiting machine))))

(defun harness-tool-slots-test--call (name &optional input ctx)
  "Run probe NAME with INPUT under CTX as `tools/execute' would; return a promise.
The tool is looked up as the model's call would look it up.  A CTX
with :report records what the call says as it waits."
  (harness-tools--run-handler (harness-tool-get name) input
                              (or ctx (list :cwd (file-name-as-directory default-directory)))))

(defun harness-tool-slots-test--machine (&rest _)
  "Return the one machine the tests' probes run on."
  "test-machine")

(defun harness-tool-slots-test--content (promise)
  "Return what PROMISE's result says, waiting for it."
  (plist-get (harness-await promise 5) :content))

;;;; The slots

(ert-deftest harness-tool-slots-a-call-under-the-limit-runs-at-once ()
  "Calls run while the machine has free slots, and none waits."
  (harness-tool-slots-test--setup)
  (let ((harness-tool-slots-tools '("slots-probe"))
        (harness-tool-slots-count 2)
        (harness-tool-slots-burst 0)
        (harness-tool-slots-machine-function #'harness-tool-slots-test--machine))
    (harness-tool-slots-test--probe "slots-probe")
    (let ((one (harness-tool-slots-test--call "slots-probe"))
          (two (harness-tool-slots-test--call "slots-probe")))
      (should (equal '("slots-probe" "slots-probe") harness-tool-slots-test--started))
      ;; Both are held until the test settles them: neither waited, and
      ;; neither result is ready.
      (should-not (harness-promise-settled-p one))
      (should-not (harness-promise-settled-p two))
      (let ((names (list (harness-tool-slots-test--settle-oldest)
                         (harness-tool-slots-test--settle-oldest))))
        (should (equal '("slots-probe" "slots-probe") names)))
      (should (equal "slots-probe" (harness-tool-slots-test--content one)))
      (should (equal "slots-probe" (harness-tool-slots-test--content two))))))

(ert-deftest harness-tool-slots-a-call-over-the-limit-waits-its-turn ()
  "A call over the limit holds until one finishes, and calls start in order."
  (harness-tool-slots-test--setup)
  (let ((harness-tool-slots-tools '("slots-probe"))
        (harness-tool-slots-count 1)
        (harness-tool-slots-burst 0)
        (harness-tool-slots-machine-function #'harness-tool-slots-test--machine))
    (harness-tool-slots-test--probe "slots-probe")
    (let ((first (harness-tool-slots-test--call "slots-probe"))
          (second (harness-tool-slots-test--call "slots-probe"))
          (third (harness-tool-slots-test--call "slots-probe")))
      (should (equal '("slots-probe") harness-tool-slots-test--started))
      (harness-tool-slots-test--settle-oldest)
      (should (equal '("slots-probe" "slots-probe") harness-tool-slots-test--started))
      (harness-tool-slots-test--settle-oldest)
      (should (equal '("slots-probe" "slots-probe" "slots-probe") harness-tool-slots-test--started))
      (harness-tool-slots-test--settle-oldest)
      (should (equal "slots-probe" (harness-tool-slots-test--content first)))
      (should (equal "slots-probe" (harness-tool-slots-test--content second)))
      (should (equal "slots-probe" (harness-tool-slots-test--content third)))
      ;; Nothing is left running or waiting.
      (should (harness-tool-slots-test--idle-p "test-machine")))))

(ert-deftest harness-tool-slots-the-burst-lets-a-few-calls-more-run ()
  "A call over the count starts while the burst is left, the next waits."
  (harness-tool-slots-test--setup)
  (let ((harness-tool-slots-tools '("slots-probe"))
        (harness-tool-slots-count 1)
        (harness-tool-slots-burst 1)
        (harness-tool-slots-machine-function #'harness-tool-slots-test--machine))
    (harness-tool-slots-test--probe "slots-probe")
    (let ((first (harness-tool-slots-test--call "slots-probe"))
          (burst (harness-tool-slots-test--call "slots-probe"))
          (waiting (harness-tool-slots-test--call "slots-probe")))
      (should (equal '("slots-probe" "slots-probe") harness-tool-slots-test--started))
      (harness-tool-slots-test--settle-oldest)
      (should (equal '("slots-probe" "slots-probe" "slots-probe") harness-tool-slots-test--started))
      (harness-tool-slots-test--settle-all)
      (should (equal "slots-probe" (harness-tool-slots-test--content first)))
      (should (equal "slots-probe" (harness-tool-slots-test--content burst)))
      (should (equal "slots-probe" (harness-tool-slots-test--content waiting))))))

(ert-deftest harness-tool-slots-slots-are-held-per-machine ()
  "A call waits only for the slots of the machine it runs on."
  (harness-tool-slots-test--setup)
  (let ((harness-tool-slots-tools '("slots-probe"))
        (harness-tool-slots-count 1)
        (harness-tool-slots-burst 0)
        (harness-tool-slots-machine-function
         (lambda (_name input _ctx) (or (plist-get input :machine) "one"))))
    (harness-tool-slots-test--probe "slots-probe")
    (let ((one (harness-tool-slots-test--call "slots-probe" '(:machine "one")))
          (other (harness-tool-slots-test--call "slots-probe" '(:machine "two"))))
      ;; The second machine's slot is free: both run at once.
      (should (equal '("slots-probe" "slots-probe") harness-tool-slots-test--started))
      (harness-tool-slots-test--settle-all)
      (should (equal "slots-probe" (harness-tool-slots-test--content one)))
      (should (equal "slots-probe" (harness-tool-slots-test--content other)))
      (should (harness-tool-slots-test--idle-p "one"))
      (should (harness-tool-slots-test--idle-p "two")))))

(ert-deftest harness-tool-slots-a-call-of-another-tool-never-waits ()
  "Only the tools `harness-tool-slots-tools' names hold slots."
  (harness-tool-slots-test--setup)
  (let ((harness-tool-slots-tools '("slots-probe"))
        (harness-tool-slots-count 1)
        (harness-tool-slots-burst 0)
        (harness-tool-slots-machine-function #'harness-tool-slots-test--machine))
    (harness-tool-slots-test--probe "slots-probe")
    (harness-define-tool "slots-quick"
      :label "Quick" :description "A tool that answers at once" :kind 'read
      :handler (lambda (_input _ctx) "quick answer"))
    (let ((held (harness-tool-slots-test--call "slots-probe"))
          (quick (harness-tool-slots-test--call "slots-quick")))
      ;; The quick tool's handler ran and answered while the governed
      ;; probe still holds the machine's only slot.
      (should (equal "quick answer" (plist-get (harness-await quick 5) :content)))
      (should (equal '("slots-probe") harness-tool-slots-test--started))
      (harness-tool-slots-test--settle-all)
      (should (equal "slots-probe" (harness-tool-slots-test--content held))))))

(ert-deftest harness-tool-slots-a-failed-call-gives-its-slot-back ()
  "A handler that rejects, and one that signals, free their slot."
  (harness-tool-slots-test--setup)
  (let ((harness-tool-slots-tools '("slots-probe"))
        (harness-tool-slots-count 1)
        (harness-tool-slots-burst 0)
        (harness-tool-slots-machine-function #'harness-tool-slots-test--machine))
    (harness-tool-slots-test--probe "slots-probe")
    (harness-define-tool "slots-boom"
      :label "Boom" :description "A probe whose handler signals" :kind 'exec
      :handler (lambda (_input _ctx) (error "Boom")))
    (let ((harness-tool-slots-tools '("slots-probe" "slots-boom")))
      (let ((boom (harness-tools--run-handler
                   (harness-tool-get "slots-boom") nil (list :cwd default-directory))))
        ;; The failure is the call's result, and the slot is free again.
        (should (plist-get (harness-await boom 5) :is-error))
        (should (harness-tool-slots-test--idle-p "test-machine"))
        (let ((next (harness-tool-slots-test--call "slots-probe")))
          (should (equal '("slots-probe") harness-tool-slots-test--started))
          (harness-tool-slots-test--settle-all)
          (should (equal "slots-probe" (harness-tool-slots-test--content next)))))
      ;; A rejected promise from the handler frees it too.
      (harness-define-tool "slots-reject"
        :label "Reject" :description "A probe that rejects" :kind 'exec
        :handler (lambda (_input _ctx) (harness-rejected "nope")))
      (let ((harness-tool-slots-tools '("slots-probe" "slots-reject")))
        (let ((rejected (harness-tools--run-handler
                         (harness-tool-get "slots-reject") nil (list :cwd default-directory))))
          (should (plist-get (harness-await rejected 5) :is-error))
          (should (harness-tool-slots-test--idle-p "test-machine"))
          (let ((next (harness-tool-slots-test--call "slots-probe")))
            (harness-tool-slots-test--settle-all)
            (should (equal "slots-probe" (harness-tool-slots-test--content next)))))))))

(ert-deftest harness-tool-slots-a-waiting-call-tells-the-session ()
  "A call that had to wait says so as progress, and is logged."
  (harness-tool-slots-test--setup)
  (let ((harness-tool-slots-tools '("slots-probe"))
        (harness-tool-slots-count 1)
        (harness-tool-slots-burst 0)
        (harness-tool-slots-machine-function #'harness-tool-slots-test--machine)
        (said nil))
    (harness-tool-slots-test--probe "slots-probe")
    (let* ((ctx (list :cwd (file-name-as-directory default-directory)
                      :report (lambda (text) (push text said))))
           (first (harness-tool-slots-test--call "slots-probe" nil ctx))
           (second (harness-tool-slots-test--call "slots-probe" nil ctx)))
      (should-not said)
      (sleep-for 0.08)
      (harness-tool-slots-test--settle-oldest)
      (should (equal '("slots-probe" "slots-probe") harness-tool-slots-test--started))
      (should (string-match-p "\\`Waited [0-9.]+s for a free slot" (car said)))
      (harness-tool-slots-test--settle-all)
      (should (equal "slots-probe" (harness-tool-slots-test--content first)))
      (should (equal "slots-probe" (harness-tool-slots-test--content second))))))

(ert-deftest harness-tool-slots-the-advice-is-added-once ()
  "Loading, starting or reloading the plugin never holds a slot twice.
A second advice would make a call take two of the machine's slots, so a
call under a one-slot limit would wait for itself and never run."
  (harness-tool-slots-test--setup)
  (let ((harness-tool-slots-tools '("slots-probe"))
        (harness-tool-slots-count 1)
        (harness-tool-slots-burst 0)
        (harness-tool-slots-machine-function #'harness-tool-slots-test--machine))
    (harness-tool-slots-test--probe "slots-probe")
    (harness-tool-slots--init)
    (harness-tool-slots--init)
    (let ((call (harness-tool-slots-test--call "slots-probe")))
      (should (equal '("slots-probe") harness-tool-slots-test--started))
      (harness-tool-slots-test--settle-all)
      (should (equal "slots-probe" (harness-tool-slots-test--content call))))
    ;; And giving the slots up at shutdown lets a waiting call run.
    (let* ((before (length harness-tool-slots-test--started))
           (held (harness-tool-slots-test--call "slots-probe"))
           (waited (harness-tool-slots-test--call "slots-probe")))
      (should (= (1+ before) (length harness-tool-slots-test--started)))
      (harness-tool-slots--shutdown)
      (harness-tool-slots--init)
      (should (= (+ 2 before) (length harness-tool-slots-test--started)))
      (harness-tool-slots-test--settle-all)
      (should (equal "slots-probe" (harness-tool-slots-test--content held)))
      (should (equal "slots-probe" (harness-tool-slots-test--content waited))))))

(ert-deftest harness-tool-slots-shutdown-lets-the-waiting-calls-of-every-machine-run ()
  "Giving the slots up at shutdown starts the calls waiting on each machine."
  (harness-tool-slots-test--setup)
  (let ((harness-tool-slots-tools '("slots-probe"))
        (harness-tool-slots-count 1)
        (harness-tool-slots-burst 0)
        (harness-tool-slots-machine-function
         (lambda (_name input _ctx) (or (plist-get input :machine) "one"))))
    (harness-tool-slots-test--probe "slots-probe")
    (let ((calls (list (harness-tool-slots-test--call "slots-probe" '(:machine "one"))
                       (harness-tool-slots-test--call "slots-probe" '(:machine "two"))
                       (harness-tool-slots-test--call "slots-probe" '(:machine "one"))
                       (harness-tool-slots-test--call "slots-probe" '(:machine "two")))))
      ;; One call runs on each machine, the other two wait.
      (should (= 2 (length harness-tool-slots-test--started)))
      (should (= 1 (harness-tool-slots-test--waiting "one")))
      (should (= 1 (harness-tool-slots-test--waiting "two")))
      (harness-tool-slots--shutdown)
      (should (= 4 (length harness-tool-slots-test--started)))
      (should (= 0 (harness-tool-slots-test--waiting "one")))
      (should (= 0 (harness-tool-slots-test--waiting "two")))
      (harness-tool-slots--init)
      (harness-tool-slots-test--settle-all)
      (dolist (call calls)
        (should (equal "slots-probe" (harness-tool-slots-test--content call))))
      (should (harness-tool-slots-test--idle-p "one"))
      (should (harness-tool-slots-test--idle-p "two")))))

(ert-deftest harness-tool-slots-slots-from-before-pools-are-taken-over ()
  "A reload may leave a machine's slots in the shape they had before pools.
A call asking then is served, not failed, and the calls that waited in
the old slots start in the new pool, in the order they came."
  (harness-tool-slots-test--setup)
  (let ((harness-tool-slots-tools '("slots-probe"))
        (harness-tool-slots-count 1)
        (harness-tool-slots-burst 0)
        (harness-tool-slots-machine-function #'harness-tool-slots-test--machine)
        (old-first (harness-make-promise))
        (old-second (harness-make-promise)))
    (harness-tool-slots-test--probe "slots-probe")
    ;; (RUNNING . WAITERS): one call held a slot, two waited for one.
    (puthash "test-machine"
             (cons 1 (list (list :promise old-first :session nil)
                           (list :promise old-second :session nil)))
             harness-tool-slots--machines)
    (let ((call (harness-tool-slots-test--call "slots-probe")))
      ;; The machine has a pool now, and its one slot went to the oldest
      ;; waiter; the other waiter and the new call wait behind it.
      (should (harness-slots-limit (harness-tool-slots-test--pool "test-machine")))
      (should (functionp (harness-promise-value old-first)))
      (should-not (harness-promise-settled-p old-second))
      (should-not harness-tool-slots-test--started)
      (should (= 1 (harness-tool-slots-test--running "test-machine")))
      (should (= 2 (harness-tool-slots-test--waiting "test-machine")))
      ;; Each gives its slot back in turn, and the call runs last.
      (funcall (harness-promise-value old-first))
      (should (functionp (harness-promise-value old-second)))
      (should-not harness-tool-slots-test--started)
      (funcall (harness-promise-value old-second))
      (should (equal '("slots-probe") harness-tool-slots-test--started))
      (harness-tool-slots-test--settle-all)
      (should (equal "slots-probe" (harness-tool-slots-test--content call)))
      (should (harness-tool-slots-test--idle-p "test-machine")))))

;;;; Tickets from before pools
;;
;; A reload keeps the calls that run through it, and with them the
;; tickets they made when a machine's slots were a (RUNNING . WAITERS)
;; cons.  Such a ticket gives its slot back by the name
;; `harness-tool-slots--give', which a pool no longer answers to by
;; counting: the pool that took over counted none of those calls.

(ert-deftest harness-tool-slots-a-give-from-before-pools-counts-nothing-down ()
  "A slot given back by a call from before pools takes no count from the pool.
The pool that took over counted the calls it admitted itself, so a call
that held a slot before it was never counted there: giving that slot
back must neither signal nor let a call start into a slot a call of the
pool still holds."
  (harness-tool-slots-test--setup)
  (let ((harness-tool-slots-tools '("slots-probe"))
        (harness-tool-slots-count 1)
        (harness-tool-slots-burst 0)
        (harness-tool-slots-machine-function #'harness-tool-slots-test--machine))
    (harness-tool-slots-test--probe "slots-probe")
    ;; (RUNNING . WAITERS): one call held the only slot, none waited.
    (puthash "test-machine" (cons 1 nil) harness-tool-slots--machines)
    (let ((first (harness-tool-slots-test--call "slots-probe"))
          (second (harness-tool-slots-test--call "slots-probe")))
      ;; The pool counts the calls it admitted: the first holds the
      ;; only slot, and the second waits for it.
      (should (equal '("slots-probe") harness-tool-slots-test--started))
      (should (= 1 (harness-tool-slots-test--running "test-machine")))
      (should (= 1 (harness-tool-slots-test--waiting "test-machine")))
      ;; The call from before ends, and its ticket gives its slot back
      ;; by name, as it was made to.  That signals nothing and counts
      ;; nothing down: the second still waits for the first's slot.
      (harness-tool-slots--give "test-machine")
      (should (= 1 (harness-tool-slots-test--running "test-machine")))
      (should (= 1 (harness-tool-slots-test--waiting "test-machine")))
      (should (equal '("slots-probe") harness-tool-slots-test--started))
      ;; The first call's own ticket does, and the second starts.
      (harness-tool-slots-test--settle-oldest)
      (should (equal '("slots-probe" "slots-probe") harness-tool-slots-test--started))
      (should (= 1 (harness-tool-slots-test--running "test-machine")))
      (should (= 0 (harness-tool-slots-test--waiting "test-machine")))
      (harness-tool-slots-test--settle-all)
      (should (equal "slots-probe" (harness-tool-slots-test--content first)))
      (should (equal "slots-probe" (harness-tool-slots-test--content second)))
      (should (harness-tool-slots-test--idle-p "test-machine")))))

(ert-deftest harness-tool-slots-a-give-from-before-pools-takes-the-old-slots-over ()
  "A slot given back from before pools may be the first to ask the machine.
No new call has made a pool then: the machine's slots are still a
\(RUNNING . WAITERS) cons.  The give signals nothing, the machine has a
pool afterwards, and the call that waited is served by it."
  (harness-tool-slots-test--setup)
  (let ((harness-tool-slots-count 1)
        (harness-tool-slots-burst 0)
        (harness-tool-slots-machine-function #'harness-tool-slots-test--machine)
        (waiter (harness-make-promise)))
    ;; One call held the only slot, and one waited for it.
    (puthash "test-machine"
             (cons 1 (list (list :promise waiter :session nil)))
             harness-tool-slots--machines)
    (harness-tool-slots--give "test-machine")
    (should (harness-slots--pool-p (harness-tool-slots-test--pool "test-machine")))
    ;; The waiter has a slot of the pool, and the ticket that gives it back.
    (should (functionp (harness-promise-value waiter)))
    (should (= 1 (harness-tool-slots-test--running "test-machine")))
    (should (= 0 (harness-tool-slots-test--waiting "test-machine")))
    (funcall (harness-promise-value waiter))
    (should (harness-tool-slots-test--idle-p "test-machine"))))

;;;; A call settles whatever happens to its slot
;;
;; `harness-tools--run-handler' turns every failure of a handler into a
;; result, so the ways the plugin itself rejects a call -- the promise
;; of a handler that rejects, a handler that signals before it has a
;; promise to give -- are driven here through `harness-tool-slots--hold'
;; with a handler of their own.

(ert-deftest harness-tool-slots-a-hold-that-fails-gives-its-slot-back ()
  "A hold whose handler fails rejects its call and frees the slot.
That is a handler whose promise rejects, and one that signals before it
has a promise to give."
  (harness-tool-slots-test--setup)
  (let ((harness-tool-slots-tools '("slots-probe"))
        (harness-tool-slots-count 1)
        (harness-tool-slots-burst 0)
        (harness-tool-slots-machine-function #'harness-tool-slots-test--machine))
    (harness-tool-slots-test--probe "slots-probe")
    (let ((tool (harness-tool-get "slots-probe")))
      ;; The handler's promise rejects.
      (let ((call (harness-tool-slots--hold
                   (lambda (&rest _) (harness-rejected "Handler failed"))
                   tool nil nil)))
        (should (eq 'rejected (harness-promise-state call)))
        (should (equal "Handler failed" (harness-promise-value call)))
        (should (harness-tool-slots-test--idle-p "test-machine")))
      ;; The handler signals before it has a promise to give.
      (let ((call (harness-tool-slots--hold
                   (lambda (&rest _) (error "Handler signalled"))
                   tool nil nil)))
        (should (eq 'rejected (harness-promise-state call)))
        (should (equal '(error "Handler signalled") (harness-promise-value call)))
        (should (harness-tool-slots-test--idle-p "test-machine")))
      ;; The machine's only slot is free for the next call.
      (let ((next (harness-tool-slots-test--call "slots-probe")))
        (should (equal '("slots-probe") harness-tool-slots-test--started))
        (harness-tool-slots-test--settle-all)
        (should (equal "slots-probe" (harness-tool-slots-test--content next)))
        (should (harness-tool-slots-test--idle-p "test-machine"))))))

(ert-deftest harness-tool-slots-a-ticket-that-signals-leaves-no-call-hanging ()
  "A call settles even when giving its slot back signals.
Such a ticket would otherwise stop the settling that follows it, and
the turn waiting for the call would wait for ever.  The error is not
hidden: it is logged, and a call that failed is failed with its own
error, not the ticket's."
  (harness-tool-slots-test--setup)
  (let ((harness-tool-slots-tools '("slots-probe"))
        (harness-tool-slots-count 1)
        (harness-tool-slots-burst 0)
        (harness-tool-slots-machine-function #'harness-tool-slots-test--machine)
        (logged nil))
    (harness-tool-slots-test--probe "slots-probe")
    (cl-letf (((symbol-function 'harness-tool-slots--acquire)
               (lambda (_machine _session &optional _tool)
                 (harness-resolved (lambda () (error "Ticket boom")))))
              (harness-log-hook
               (list (lambda (level msg) (when (eq level 'error) (push msg logged))))))
      (let ((tool (harness-tool-get "slots-probe")))
        ;; The handler answers: the call has its result.
        (let ((call (harness-tool-slots-test--call "slots-probe")))
          (should (equal '("slots-probe") harness-tool-slots-test--started))
          (harness-tool-slots-test--settle-all)
          (should (equal "slots-probe" (harness-tool-slots-test--content call))))
        (should (cl-some (lambda (msg) (string-match-p "Ticket boom" msg)) logged))
        ;; The handler fails: the call is rejected with that failure.
        (let ((call (harness-tool-slots--hold
                     (lambda (&rest _) (harness-rejected "Handler failed"))
                     tool nil nil)))
          (should (eq 'rejected (harness-promise-state call)))
          (should (equal "Handler failed" (harness-promise-value call))))
        ;; The handler signals before it has a promise to give.
        (let ((call (harness-tool-slots--hold
                     (lambda (&rest _) (error "Handler signalled"))
                     tool nil nil)))
          (should (eq 'rejected (harness-promise-state call)))
          (should (equal '(error "Handler signalled") (harness-promise-value call))))))))

(ert-deftest harness-tool-slots-tools-execute-holds-a-slot ()
  "A call through `tools/execute' takes a slot like any other."
  (harness-tool-slots-test--setup)
  (harness-add-filter 'permission/decide
                      (lambda (_decision next &rest _) (funcall next (list :behavior 'allow)))
                      10)
  (let ((harness-tool-slots-tools '("slots-probe"))
        (harness-tool-slots-count 1)
        (harness-tool-slots-burst 0)
        (harness-tool-slots-machine-function #'harness-tool-slots-test--machine))
    (harness-tool-slots-test--probe "slots-probe")
    (let ((first (harness-call 'tools/execute nil (list :id "c1" :name "slots-probe" :input nil)))
          (second (harness-call 'tools/execute nil (list :id "c2" :name "slots-probe" :input nil))))
      (should (equal '("slots-probe") harness-tool-slots-test--started))
      (harness-tool-slots-test--settle-oldest)
      (should (equal '("slots-probe" "slots-probe") harness-tool-slots-test--started))
      (harness-tool-slots-test--settle-all)
      (should (equal "slots-probe" (plist-get (harness-await first 5) :content)))
      (should (equal "slots-probe" (plist-get (harness-await second 5) :content))))))

;;;; Judges decide before the wait
;;
;; The auto-mode judge is a model call of the harness's own.  It is a
;; `permission/decide' stage, and `tools/execute' runs that chain to its
;; end before it runs the handler, which is where a governed tool waits
;; for its slot.  So a judge never holds a slot nor queues for one, and
;; a call that waits for a slot has been judged.

(defvar harness-tool-slots-test--judged nil
  "What the stand-in judge decided, newest first, as (CALL-ID HELD WAITING).
HELD is how many calls held a slot of the test machine, and WAITING how
many waited for one, when the verdict came.")

(defun harness-tool-slots-test--judge (decision next request)
  "Stand in for the auto-mode judge, a `permission/decide' stage.
It takes a moment, as a model call does, and then allows the call,
noting the state of the test machine's slots (`harness-tool-slots-test--judged')."
  (if (not (eq 'ask (plist-get decision :behavior)))
      (funcall next decision)
    (run-at-time 0.02 nil
                 (lambda ()
                   (push (list (plist-get request :call-id)
                               (harness-tool-slots-test--running "test-machine")
                               (harness-tool-slots-test--waiting "test-machine"))
                         harness-tool-slots-test--judged)
                   (funcall next (list :behavior 'allow :reason "ordinary work"))))
    nil))

(ert-deftest harness-tool-slots-a-judge-decides-before-the-slot-wait ()
  "A call is judged before it asks for a slot, so a full machine does not hold a judge up.
The first call is judged and takes the only slot.  The second is judged
while that slot is held, and nobody waits for one at that moment; its
verdict is in, and only then does it wait.  A slot freed, it runs."
  (harness-test-reset-bus)
  (harness-tool-slots-test--setup)
  (setq harness-tool-slots-test--judged nil)
  (harness-add-filter 'permission/decide #'harness-tool-slots-test--judge 30)
  (unwind-protect
      (let ((harness-tool-slots-tools '("slots-probe"))
            (harness-tool-slots-count 1)
            (harness-tool-slots-burst 0)
            (harness-tool-slots-machine-function #'harness-tool-slots-test--machine))
        (harness-tool-slots-test--probe "slots-probe")
        (let ((first (harness-call 'tools/execute nil (list :id "c1" :name "slots-probe" :input nil))))
          ;; Judged with the machine idle, then it takes the only slot.
          (harness-test-wait (lambda () (equal '("slots-probe") harness-tool-slots-test--started)) 5
                             "the first call to run")
          (should (equal '(("c1" 0 0)) harness-tool-slots-test--judged))
          (let ((second (harness-call 'tools/execute nil (list :id "c2" :name "slots-probe" :input nil))))
            ;; The slot is held, and the second call is judged all the same:
            ;; at that moment it was not waiting for one.
            (harness-test-wait (lambda () (assoc "c2" harness-tool-slots-test--judged)) 5
                               "the second call to be judged")
            (should (equal '("c2" 1 0) (assoc "c2" harness-tool-slots-test--judged)))
            ;; Its verdict is in, and it waits for the slot now.
            (harness-test-wait (lambda () (> (harness-tool-slots-test--waiting "test-machine") 0)) 5
                               "the second call to wait for a slot")
            (should (equal '("slots-probe") harness-tool-slots-test--started))
            (should-not (harness-promise-settled-p second))
            ;; A slot frees: it runs.
            (harness-tool-slots-test--settle-oldest)
            (harness-test-wait (lambda () (= 2 (length harness-tool-slots-test--started))) 5
                               "the second call to run")
            (should (equal '("c2" "c1") (mapcar #'car harness-tool-slots-test--judged)))
            (harness-tool-slots-test--settle-all)
            (should (equal "slots-probe" (plist-get (harness-await first 5) :content)))
            (should (equal "slots-probe" (plist-get (harness-await second 5) :content)))
            (should (harness-tool-slots-test--idle-p "test-machine")))))
    (harness-remove-filter 'permission/decide #'harness-tool-slots-test--judge)))

;;;; The limit, and which machine it is for

(ert-deftest harness-tool-slots-the-limits-come-from-the-options ()
  "The slots are the count plus the burst, whatever the options hold."
  (let ((harness-tool-slots-count 3) (harness-tool-slots-burst 1))
    (should (= 4 (harness-tool-slots--slots))))
  (let ((harness-tool-slots-count 3) (harness-tool-slots-burst 0))
    (should (= 3 (harness-tool-slots--slots))))
  ;; Nonsense, or nothing at all, means one slot per processor.
  (let ((harness-tool-slots-count nil) (harness-tool-slots-burst 2))
    (should (= (+ 2 (max 1 (num-processors))) (harness-tool-slots--slots))))
  (let ((harness-tool-slots-count 0) (harness-tool-slots-burst -1))
    (should (= (max 1 (num-processors)) (harness-tool-slots--slots))))
  (let ((harness-tool-slots-count "many") (harness-tool-slots-burst nil))
    (should (= (max 1 (num-processors)) (harness-tool-slots--slots)))))

(ert-deftest harness-tool-slots-the-default-machine-is-local-or-a-host ()
  "A local call is this machine's; a remote directory and ssh name their host."
  (harness-tool-slots-test--setup)
  (harness-tool-slots-test--probe "slots-probe")
  (let ((local (harness-tool-slots-default-machine "bash" nil (list :cwd default-directory))))
    (should (equal (concat "local:" (system-name)) local))
    (should (equal "this machine" (harness-tool-slots--machine-label local))))
  ;; A session on another host, and a remote cwd given to the call.
  (should (equal "host:example.invalid"
                 (harness-tool-slots-default-machine
                  "bash" nil (list :cwd "/ssh:example.invalid:/srv/" :host nil))))
  (should (equal "host:example.invalid"
                 (harness-tool-slots-default-machine
                  "elisp" nil (list :cwd "/x/" :host "/ssh:example.invalid:"))))
  ;; The ssh tool is keyed by the host it names, whatever the cwd.
  (should (equal "host:box" (harness-tool-slots-default-machine "ssh" '(:host "box") nil)))
  (should (equal "host:box" (harness-tool-slots-default-machine "ssh" '(:host "  box  ") nil)))
  (should (equal (concat "local:" (system-name))
                 (harness-tool-slots-default-machine "ssh" '(:host "  ") nil)))
  ;; A machine function that says nothing, or fails, is this machine.
  (let* ((tool (harness-tool-get "slots-probe"))
         (harness-tool-slots-machine-function (lambda (&rest _) nil)))
    (should (equal (concat "local:" (system-name))
                   (harness-tool-slots--machine tool nil nil))))
  (let* ((tool (harness-tool-get "slots-probe"))
         (harness-tool-slots-machine-function (lambda (&rest _) (error "No"))))
    (should (equal (concat "local:" (system-name))
                   (harness-tool-slots--machine tool nil nil)))))


;;;; Priority
;;
;; A call waiting for a slot is served by its session's priority: the
;; calls of a task the user marked high go before a low one's, and the
;; sub-agents of a task work at the task's priority (see the priority
;; plugin).  The tests above use no session, so every call is medium and
;; they queue in the order they arrived.

(defvar harness-sessions)

(defmacro harness-tool-slots-test-with-sessions (&rest body)
  "Load the state modules and both plugins into a fresh bus and state dir, then BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider session)) (harness-test-load-module m))
     (harness-test-load-module 'priority)
     (harness-test-load-module 'tools)
     (harness-test-load-module 'tool-slots)
     (clrhash harness-sessions)
     (harness-tool-slots-test--reset)
     (let ((default-directory dir))
       ,@body)))

(ert-deftest harness-tool-slots-the-highest-priority-call-goes-first ()
  "The calls of the highest priority session waiting take the free slot first."
  (harness-tool-slots-test--setup)
  (let ((harness-tool-slots-tools '("slots-plain" "slots-other" "slots-urgent"))
        (harness-tool-slots-count 1)
        (harness-tool-slots-burst 0)
        (harness-tool-slots-machine-function #'harness-tool-slots-test--machine)
        (levels '(("plain" . medium) ("other" . medium) ("urgent" . high))))
    (harness-tool-slots-test--probe "slots-plain")
    (harness-tool-slots-test--probe "slots-other")
    (harness-tool-slots-test--probe "slots-urgent")
    (cl-letf (((symbol-function 'harness-priority-of)
               (lambda (sid) (or (cdr (assoc sid levels)) 'medium))))
      ;; Arrival order: plain holds the only slot, then other, then urgent.
      (let ((plain (harness-tool-slots-test--call "slots-plain" nil (list :session-id "plain")))
            (other (harness-tool-slots-test--call "slots-other" nil (list :session-id "other")))
            (urgent (harness-tool-slots-test--call "slots-urgent" nil (list :session-id "urgent"))))
        (should (equal '("slots-plain") harness-tool-slots-test--started))
        ;; The slot frees: urgent goes before other, though it arrived last.
        (harness-tool-slots-test--settle-oldest)
        (should (equal '("slots-plain" "slots-urgent") harness-tool-slots-test--started))
        (harness-tool-slots-test--settle-oldest)
        (should (equal '("slots-plain" "slots-urgent" "slots-other")
                       harness-tool-slots-test--started))
        (harness-tool-slots-test--settle-all)
        (should (equal "slots-plain" (harness-tool-slots-test--content plain)))
        (should (equal "slots-other" (harness-tool-slots-test--content other)))
        (should (equal "slots-urgent" (harness-tool-slots-test--content urgent)))))))

(ert-deftest harness-tool-slots-a-priority-raised-while-waiting-moves-a-call ()
  "A call waits with its session's priority as it is when a slot frees."
  (harness-tool-slots-test--setup)
  (let* ((harness-tool-slots-tools '("slots-hold" "slots-older" "slots-newer"))
         (harness-tool-slots-count 1)
         (harness-tool-slots-burst 0)
         (harness-tool-slots-machine-function #'harness-tool-slots-test--machine)
         (levels (list (cons "hold" 'medium) (cons "older" 'low) (cons "newer" 'low))))
    (harness-tool-slots-test--probe "slots-hold")
    (harness-tool-slots-test--probe "slots-older")
    (harness-tool-slots-test--probe "slots-newer")
    (cl-letf (((symbol-function 'harness-priority-of)
               (lambda (sid) (or (cdr (assoc sid levels)) 'medium))))
      (let ((hold (harness-tool-slots-test--call "slots-hold" nil (list :session-id "hold")))
            (older (harness-tool-slots-test--call "slots-older" nil (list :session-id "older")))
            (newer (harness-tool-slots-test--call "slots-newer" nil (list :session-id "newer"))))
        (should (equal '("slots-hold") harness-tool-slots-test--started))
        ;; The newer call's session is raised while both wait: it goes first.
        (setq levels (list (cons "hold" 'medium) (cons "older" 'low) (cons "newer" 'high)))
        (harness-tool-slots-test--settle-oldest)
        (should (equal '("slots-hold" "slots-newer") harness-tool-slots-test--started))
        (harness-tool-slots-test--settle-all)
        (should (equal "slots-hold" (harness-tool-slots-test--content hold)))
        (should (equal "slots-older" (harness-tool-slots-test--content older)))
        (should (equal "slots-newer" (harness-tool-slots-test--content newer)))))))

(ert-deftest harness-tool-slots-a-sub-agent-works-at-its-parents-priority ()
  "A call of a session with none of its own takes its parent's priority."
  (harness-tool-slots-test-with-sessions
    (let* ((cwd (harness-test-temp-dir))
           (parent (plist-get (harness-call 'session/create :cwd cwd) :id))
           (task (plist-get (harness-call 'session/create :cwd cwd :parent-id parent) :id))
           (other (plist-get (harness-call 'session/create :cwd cwd) :id))
           (worker (plist-get (harness-call 'session/create :cwd cwd :parent-id task) :id)))
      (harness-call 'priority/set parent "high")
      (let ((harness-tool-slots-tools '("slots-parent" "slots-other" "slots-worker"))
            (harness-tool-slots-count 1)
            (harness-tool-slots-burst 0)
            (harness-tool-slots-machine-function #'harness-tool-slots-test--machine))
        (harness-tool-slots-test--probe "slots-parent")
        (harness-tool-slots-test--probe "slots-other")
        (harness-tool-slots-test--probe "slots-worker")
        ;; The parent's session holds the slot; its sub-agent's session and
        ;; a plain session wait, the sub-agent arriving last.
        (let ((holder (harness-tool-slots-test--call "slots-parent" nil (list :session-id parent)))
              (plain (harness-tool-slots-test--call "slots-other" nil (list :session-id other)))
              (worker (harness-tool-slots-test--call "slots-worker" nil (list :session-id worker))))
          (should (equal '("slots-parent") harness-tool-slots-test--started))
          (harness-tool-slots-test--settle-oldest)
          ;; The worker inherits the task's high priority and goes first.
          (should (equal '("slots-parent" "slots-worker") harness-tool-slots-test--started))
          (harness-tool-slots-test--settle-all)
          (should (equal "slots-parent" (harness-tool-slots-test--content holder)))
          (should (equal "slots-other" (harness-tool-slots-test--content plain)))
          (should (equal "slots-worker" (harness-tool-slots-test--content worker))))))))

;;;; Who is using the slots
;;
;; The plugin knows, for each machine, which session's call of which
;; tool holds each slot and since when, and who waits for one in what
;; order, and says when that changes.  It is a record kept beside the
;; slots: the tests above are the proof that the calls are served as
;; they were.

(defun harness-tool-slots-test--state (machine)
  "Return the entry of `harness-tool-slots-machines' for MACHINE, nil if it has none."
  (cl-find machine (harness-tool-slots-machines)
           :key (lambda (entry) (plist-get entry :machine)) :test #'equal))

(defun harness-tool-slots-test--who (users)
  "Return USERS, holders or waiters, as (SESSION TOOL) pairs."
  (mapcar (lambda (user) (list (plist-get user :session) (plist-get user :tool))) users))

(ert-deftest harness-tool-slots-this-machine-is-always-listed ()
  "An idle machine is listed with its limit and nobody on it, and others are not.
A machine keeps its pool when its last call is done, but is listed only
while a call holds a slot of it or waits for one."
  (harness-tool-slots-test--setup)
  (let ((harness-tool-slots-tools '("slots-probe"))
        (harness-tool-slots-count 3)
        (harness-tool-slots-burst 1)
        (harness-tool-slots-machine-function
         (lambda (_name input _ctx) (or (plist-get input :machine) "one"))))
    (harness-tool-slots-test--probe "slots-probe")
    (let ((local (harness-tool-slots--local-machine)))
      (let ((machines (harness-tool-slots-machines)))
        (should (equal (list local) (mapcar (lambda (m) (plist-get m :machine)) machines)))
        (should (equal (list :machine local :label "this machine" :limit 4 :running 0
                             :holders nil :waiters nil)
                       (car machines))))
      ;; Calls on two other machines list them, after this one, by name.
      (let ((two (harness-tool-slots-test--call "slots-probe" '(:machine "two")))
            (one (harness-tool-slots-test--call "slots-probe" '(:machine "one"))))
        (should (equal (list local "one" "two")
                       (mapcar (lambda (m) (plist-get m :machine)) (harness-tool-slots-machines))))
        (should (equal "one" (plist-get (harness-tool-slots-test--state "one") :label)))
        ;; The pools stay when the calls are done; the listing does not.
        (harness-tool-slots-test--settle-all)
        (should (equal "slots-probe" (harness-tool-slots-test--content one)))
        (should (equal "slots-probe" (harness-tool-slots-test--content two)))
        (should (harness-tool-slots-test--idle-p "one"))
        (should (equal (list local)
                       (mapcar (lambda (m) (plist-get m :machine)) (harness-tool-slots-machines))))))))

(ert-deftest harness-tool-slots-holders-are-listed-with-session-tool-and-start ()
  "A call that holds a slot is listed under its machine until it is done.
Its session, its tool and when it took the slot, the longest holder
first; the tool is the call's own, not the name of what the probe runs."
  (harness-tool-slots-test--setup)
  (let ((harness-tool-slots-tools '("slots-probe" "slots-other"))
        (harness-tool-slots-count 2)
        (harness-tool-slots-burst 0)
        (harness-tool-slots-machine-function #'harness-tool-slots-test--machine))
    (harness-tool-slots-test--probe "slots-probe")
    (harness-tool-slots-test--probe "slots-other")
    (let* ((before (float-time))
           (one (harness-tool-slots-test--call "slots-probe" nil (list :session-id "s1")))
           (two (harness-tool-slots-test--call "slots-other" nil (list :session-id "s2")))
           (after (float-time))
           (state (harness-tool-slots-test--state "test-machine")))
      (should (equal "test-machine" (plist-get state :label)))
      (should (= 2 (plist-get state :limit)))
      (should (= 2 (plist-get state :running)))
      (should (equal '(("s1" "slots-probe") ("s2" "slots-other"))
                     (harness-tool-slots-test--who (plist-get state :holders))))
      (dolist (holder (plist-get state :holders))
        (should (<= before (plist-get holder :started) after))
        (should (equal "medium" (plist-get holder :priority)))
        ;; Without a session module no session has a name.
        (should-not (plist-get holder :name)))
      (should-not (plist-get state :waiters))
      ;; The first call ends: only the second is left.
      (harness-tool-slots-test--settle-oldest)
      (should (equal "slots-probe" (harness-tool-slots-test--content one)))
      (should (equal '(("s2" "slots-other"))
                     (harness-tool-slots-test--who
                      (plist-get (harness-tool-slots-test--state "test-machine") :holders))))
      (harness-tool-slots-test--settle-all)
      (should (equal "slots-other" (harness-tool-slots-test--content two)))
      ;; Nobody holds a slot of it any more: it is not listed, though it
      ;; keeps its pool.
      (should-not (harness-tool-slots-test--state "test-machine"))
      (should (harness-tool-slots-test--idle-p "test-machine")))))

(ert-deftest harness-tool-slots-waiters-are-listed-in-the-order-they-will-be-served ()
  "The calls waiting are listed by priority, the oldest first among equals.
Each has its session, its tool, its session's priority as it is now and
when it began to wait; a priority raised while it waits moves it up, as
it moves it up the line, and the slot goes to whom the list says."
  (harness-tool-slots-test--setup)
  (let ((harness-tool-slots-tools '("slots-hold" "slots-low" "slots-plain" "slots-urgent"))
        (harness-tool-slots-count 1)
        (harness-tool-slots-burst 0)
        (harness-tool-slots-machine-function #'harness-tool-slots-test--machine)
        (levels (list (cons "hold" 'medium) (cons "low" 'low)
                      (cons "plain" 'medium) (cons "urgent" 'high))))
    (dolist (name harness-tool-slots-tools)
      (harness-tool-slots-test--probe name))
    (cl-letf (((symbol-function 'harness-priority-of)
               (lambda (sid) (or (cdr (assoc sid levels)) 'medium))))
      (let* ((before (float-time))
             (calls (mapcar (lambda (who)
                              (harness-tool-slots-test--call (concat "slots-" who) nil
                                                             (list :session-id who)))
                            '("hold" "low" "plain" "urgent")))
             (after (float-time))
             (state (harness-tool-slots-test--state "test-machine")))
        (should (equal '(("hold" "slots-hold")) (harness-tool-slots-test--who (plist-get state :holders))))
        (should (= 1 (plist-get state :running)))
        (should (equal '(("urgent" "slots-urgent" "high")
                         ("plain" "slots-plain" "medium")
                         ("low" "slots-low" "low"))
                       (mapcar (lambda (w) (list (plist-get w :session) (plist-get w :tool)
                                                 (plist-get w :priority)))
                               (plist-get state :waiters))))
        (dolist (waiter (plist-get state :waiters))
          (should (<= before (plist-get waiter :asked) after))
          (should-not (plist-member waiter :started)))
        ;; The oldest waiter's priority rises above the others'.
        (setcdr (assoc "low" levels) 'high)
        (should (equal '("low" "urgent" "plain")
                       (mapcar (lambda (w) (plist-get w :session))
                               (plist-get (harness-tool-slots-test--state "test-machine") :waiters))))
        ;; The slot that frees goes to the first in the list.
        (harness-tool-slots-test--settle-oldest)
        (should (equal '("slots-hold" "slots-low") harness-tool-slots-test--started))
        (should (equal '(("low" "slots-low"))
                       (harness-tool-slots-test--who
                        (plist-get (harness-tool-slots-test--state "test-machine") :holders))))
        (harness-tool-slots-test--settle-all)
        (dolist (call calls) (harness-await call 5))
        (should (harness-tool-slots-test--idle-p "test-machine"))))))

(ert-deftest harness-tool-slots-a-session-is-listed-by-its-name-and-priority ()
  "The session of a call is listed by its name, and its own priority.
A session the harness does not know has no name and the default
priority; so does a call of the harness's own, with no session."
  (harness-tool-slots-test-with-sessions
    (let* ((cwd (harness-test-temp-dir))
           (named (plist-get (harness-call 'session/create :cwd cwd :name "Fix the build") :id))
           (blank (plist-get (harness-call 'session/create :cwd cwd) :id)))
      (harness-call 'priority/set named "high")
      (let ((harness-tool-slots-tools '("slots-probe"))
            (harness-tool-slots-count 4)
            (harness-tool-slots-burst 0)
            (harness-tool-slots-machine-function #'harness-tool-slots-test--machine))
        (harness-tool-slots-test--probe "slots-probe")
        (dolist (id (list named blank "nobody" nil))
          (harness-tool-slots-test--call "slots-probe" nil (list :session-id id)))
        (let ((holders (plist-get (harness-tool-slots-test--state "test-machine") :holders)))
          (should (equal (list named blank "nobody" nil)
                         (mapcar (lambda (h) (plist-get h :session)) holders)))
          (should (equal (list "Fix the build" nil nil nil)
                         (mapcar (lambda (h) (plist-get h :name)) holders)))
          (should (equal '("high" "medium" "medium" "medium")
                         (mapcar (lambda (h) (plist-get h :priority)) holders))))
        (harness-tool-slots-test--settle-all)))))

(ert-deftest harness-tool-slots-the-rank-reads-the-session-from-any-form-of-data ()
  "A call asks with its session and tool, and one from before asked with the session alone.
A reload keeps the calls waiting, whatever they asked with, and the pool
ranks them all by the priority of their session."
  (cl-letf (((symbol-function 'harness-priority-of)
             (lambda (sid) (if (equal sid "urgent") 'high 'medium))))
    (should (= 2 (harness-tool-slots--rank-of (harness-tool-slots--data "urgent" "bash"))))
    (should (= 2 (harness-tool-slots--rank-of "urgent")))
    (should (= 1 (harness-tool-slots--rank-of "plain")))
    (should (= 1 (harness-tool-slots--rank-of nil)))
    (should (= 1 (harness-tool-slots--rank-of (harness-tool-slots--data nil "bash"))))))

(ert-deftest harness-tool-slots-calls-from-before-pools-are-listed-without-a-tool ()
  "The calls that waited in the slots from before pools are listed, with no tool.
They ask the pool that takes over with the session they came with, and
the tool is not known of them."
  (harness-tool-slots-test--setup)
  (let ((harness-tool-slots-tools '("slots-probe"))
        (harness-tool-slots-count 1)
        (harness-tool-slots-burst 0)
        (harness-tool-slots-machine-function #'harness-tool-slots-test--machine)
        (old (harness-make-promise)))
    (harness-tool-slots-test--probe "slots-probe")
    (puthash "test-machine" (cons 1 (list (list :promise old :session "old-session")))
             harness-tool-slots--machines)
    (let ((call (harness-tool-slots-test--call "slots-probe" nil (list :session-id "new-session")))
          (state nil))
      (setq state (harness-tool-slots-test--state "test-machine"))
      (should (equal '(("old-session" nil)) (harness-tool-slots-test--who (plist-get state :holders))))
      (should (equal '(("new-session" "slots-probe")) (harness-tool-slots-test--who (plist-get state :waiters))))
      (funcall (harness-promise-value old))
      (harness-tool-slots-test--settle-all)
      (should (equal "slots-probe" (harness-tool-slots-test--content call)))
      (should (harness-tool-slots-test--idle-p "test-machine")))))

;;;; Saying that who holds a slot changed

(defmacro harness-tool-slots-test-with-changes (var &rest body)
  "Run BODY with VAR collecting what `tool-slots/holders-changed' says, newest first.
Each is (MACHINE HOLDERS WAITERS): the machine, and how many sessions hold a
slot of it and wait for one when the event came."
  (declare (indent 1))
  `(let* ((,var nil)
          (handle (harness-on 'tool-slots/holders-changed
                              (lambda (machine)
                                (let ((state (harness-tool-slots-test--state machine)))
                                  (push (list machine
                                              (length (plist-get state :holders))
                                              (length (plist-get state :waiters)))
                                        ,var))))))
     (unwind-protect (progn ,@body)
       (harness-off handle))))

(ert-deftest harness-tool-slots-every-change-of-who-holds-a-slot-is-announced ()
  "A call taking a slot, one waiting, one done and the next starting are each announced.
The announcement comes as the pool changes, so what it finds there is
the pool after the change."
  (harness-tool-slots-test--setup)
  (let ((harness-tool-slots-tools '("slots-probe"))
        (harness-tool-slots-count 1)
        (harness-tool-slots-burst 0)
        (harness-tool-slots-machine-function #'harness-tool-slots-test--machine))
    (harness-tool-slots-test--probe "slots-probe")
    (harness-tool-slots-test-with-changes changes
      (let ((first (harness-tool-slots-test--call "slots-probe" nil (list :session-id "s1"))))
        ;; It took the only slot.
        (should (equal '(("test-machine" 1 0)) (reverse changes)))
        (let ((second (harness-tool-slots-test--call "slots-probe" nil (list :session-id "s2"))))
          ;; The second one waits.
          (should (equal '(("test-machine" 1 0) ("test-machine" 1 1)) (reverse changes)))
          (harness-tool-slots-test--settle-oldest)
          ;; The first is done and the second has its slot.
          (should (equal '(("test-machine" 1 0) ("test-machine" 1 1) ("test-machine" 1 0))
                         (reverse changes)))
          (harness-tool-slots-test--settle-all)
          (should (equal '("test-machine" 0 0) (car changes)))
          (should (= 4 (length changes)))
          (should (equal "slots-probe" (harness-tool-slots-test--content first)))
          (should (equal "slots-probe" (harness-tool-slots-test--content second))))))))

(ert-deftest harness-tool-slots-a-call-that-fails-announces-its-slot-back ()
  "A call whose handler fails or signals gives its slot back, and says so."
  (harness-tool-slots-test--setup)
  (let ((harness-tool-slots-tools '("slots-probe"))
        (harness-tool-slots-count 1)
        (harness-tool-slots-burst 0)
        (harness-tool-slots-machine-function #'harness-tool-slots-test--machine))
    (harness-tool-slots-test--probe "slots-probe")
    (let ((tool (harness-tool-get "slots-probe")))
      (harness-tool-slots-test-with-changes changes
        (dolist (handler (list (lambda (&rest _) (harness-rejected "Handler failed"))
                               (lambda (&rest _) (error "Handler signalled"))))
          (setq changes nil)
          (let ((call (harness-tool-slots--hold handler tool nil (list :session-id "s1"))))
            (should (eq 'rejected (harness-promise-state call)))
            ;; Took the slot, then gave it back.
            (should (equal '(("test-machine" 1 0) ("test-machine" 0 0)) (reverse changes)))
            (should-not (plist-get (harness-tool-slots-test--state "test-machine") :holders))))))))

(ert-deftest harness-tool-slots-admitting-announces-only-when-a-call-started ()
  "Starting the calls a raised limit has room for is announced, and nothing else is.
Nothing started, nothing changed."
  (harness-tool-slots-test--setup)
  (let ((harness-tool-slots-tools '("slots-probe"))
        (harness-tool-slots-count 1)
        (harness-tool-slots-burst 0)
        (harness-tool-slots-machine-function #'harness-tool-slots-test--machine))
    (harness-tool-slots-test--probe "slots-probe")
    (let ((first (harness-tool-slots-test--call "slots-probe"))
          (second (harness-tool-slots-test--call "slots-probe")))
      (harness-tool-slots-test-with-changes changes
        ;; Room for none: nobody starts, and nothing is said.
        (harness-tool-slots--admit "test-machine")
        (should-not changes)
        ;; One more slot, and the second starts.
        (setq harness-tool-slots-count 2)
        (harness-tool-slots--admit "test-machine")
        (should (equal '(("test-machine" 2 0)) changes))
        (harness-tool-slots--admit "test-machine")
        (should (= 1 (length changes))))
      (harness-tool-slots-test--settle-all)
      (should (equal "slots-probe" (harness-tool-slots-test--content first)))
      (should (equal "slots-probe" (harness-tool-slots-test--content second))))))

(ert-deftest harness-tool-slots-shutdown-announces-that-nobody-holds-a-slot ()
  "Giving the slots up lets the waiting calls run, counts nobody as holding one, and says so."
  (harness-tool-slots-test--setup)
  (let ((harness-tool-slots-tools '("slots-probe"))
        (harness-tool-slots-count 1)
        (harness-tool-slots-burst 0)
        (harness-tool-slots-machine-function
         (lambda (_name input _ctx) (or (plist-get input :machine) "one"))))
    (harness-tool-slots-test--probe "slots-probe")
    (let ((calls (list (harness-tool-slots-test--call "slots-probe" '(:machine "one"))
                       (harness-tool-slots-test--call "slots-probe" '(:machine "one"))
                       (harness-tool-slots-test--call "slots-probe" '(:machine "two")))))
      ;; One call runs on each machine, and one waits on the first.
      (should (= 2 (length harness-tool-slots-test--started)))
      (harness-tool-slots-test-with-changes changes
        (harness-tool-slots--shutdown)
        (should (= 3 (length harness-tool-slots-test--started)))
        (should (equal '("one" "two") (sort (mapcar #'car changes) #'string<)))
        ;; Nobody holds a slot or waits: the calls run, but are not counted.
        (dolist (change changes)
          (should (equal 0 (nth 1 change)))
          (should (equal 0 (nth 2 change)))))
      (harness-tool-slots--init)
      (harness-tool-slots-test--settle-all)
      (dolist (call calls) (harness-await call 5)))))

(provide 'harness-tool-slots-test)
;;; harness-tool-slots-test.el ends here
