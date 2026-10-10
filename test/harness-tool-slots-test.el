;;; harness-tool-slots-test.el --- Tests for the tool slots plugin  -*- lexical-binding: t; -*-

;;; Commentary:

;; The plugin (lisp/modules/harness-tool-slots.el) holds a few slots per
;; machine for the calls of the tools that start processes.  Its calls
;; are driven through `harness-tools--run-handler', the point the plugin
;; advises, with probes whose handlers hold a promise until the test
;; settles it: a probe whose handler ran is one the plugin let start.

;;; Code:

(require 'harness-test-helpers)

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
      (should (equal (cons 0 nil) (gethash "test-machine" harness-tool-slots--machines))))))

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
      (should (equal (cons 0 nil) (gethash "one" harness-tool-slots--machines)))
      (should (equal (cons 0 nil) (gethash "two" harness-tool-slots--machines))))))

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
        (should (equal (cons 0 nil) (gethash "test-machine" harness-tool-slots--machines)))
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
          (should (equal (cons 0 nil) (gethash "test-machine" harness-tool-slots--machines)))
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

(provide 'harness-tool-slots-test)
;;; harness-tool-slots-test.el ends here
