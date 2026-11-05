;;; harness-gremlin-test.el --- The harness survives gremlins  -*- lexical-binding: t; -*-

;;; Commentary:

;; A controlled chaos suite.  Each test runs in a throwaway state
;; directory and a fresh bus, with a small `harness-gremlin-budget', a
;; fixed seed, no network, and timers and processes cleaned up even when
;; an assertion fails.  Permission decisions are automatic: either a
;; test `permission/decide' filter allows every call, or a non-interactive
;; session's own mode and jail decide, so no test waits for a person.
;;
;; The suites are:
;;
;; - the framework: budgets, seeded choice, cleanup, incident report;
;; - the provider: every scenario ends with exactly one done event, a
;;   hang cancels once, malformed events cannot break a turn, tool storms
;;   run every call, ghost tools get error results, the jail refuses the
;;   shortcut, secrets are masked before the model echoes them, and quota
;;   and rate limits keep their classification;
;; - the tools: a hang hits the timeout, huge output is truncated and
;;   saved, errors are normalised, out-of-jail probes are refused, leaks
;;   are masked, CPU and memory are capped, a leftover process is killed,
;;   and disarmed tools refuse to run;
;; - the plugin: trust and scope, a frozen list, a hanging tool, a plugin
;;   that crashes while loading, and a planted checkout that must not load.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-test-helpers)

(defvar harness--modules)
(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-tools-max-output-chars)
(defvar harness-plugin-modules)
(defvar harness-plugins--applied)
(defvar harness-session--tmp-root)
(defvar harness-gremlin--timers)
(defvar harness-gremlin--processes)
(defvar harness-gremlin-plugin--observations)
(defvar harness-gremlin-plugin--attempts)
(defvar harness-provider-gremlin--continuations)
(defvar timer-list)

(declare-function harness-gremlin-cleanup "harness-gremlin" ())
(declare-function harness-gremlin-incident "harness-gremlin" (gremlin event &rest properties))
(declare-function harness-gremlin-attempt "harness-gremlin" (gremlin action target function))
(declare-function harness-gremlin-attempts "harness-gremlin" ())
(declare-function harness-gremlin-report "harness-gremlin" ())
(declare-function harness-gremlin-reset "harness-gremlin" (&optional seed run))
(declare-function harness-gremlin-run-at "harness-gremlin" (seconds function))
(declare-function harness-gremlin-spend "harness-gremlin" (resource amount))
(declare-function harness-gremlin-bytes "harness-gremlin" (size &optional character))
(declare-function harness-gremlin-incidents "harness-gremlin" ())
(declare-function harness-provider-gremlin--scenario "harness-provider-gremlin" (request))
(declare-function harness-provider-gremlin--scenario-names "harness-provider-gremlin" ())
(declare-function harness-plugins--planted-p "harness-plugins" (dir))

(defconst harness-gremlin-test--budget
  '(:seconds 5 :bytes 200000 :calls 300 :memory-mb 8 :processes 2)
  "The budget every chaos test starts with: enough to finish, little enough to stay safe.")

(defun harness-gremlin-test--forget-plugin ()
  "Unload the gremlin plugin's features, module and tools."
  (dolist (feature '(harness-gremlin-plugin harness-tools-gremlin-plugin))
    (setq features (delq feature features)))
  (when (boundp 'harness--modules)
    (remhash 'tools-gremlin-plugin harness--modules))
  (when (boundp 'harness-tools)
    (dolist (name '("gremlin_plugin_echo" "gremlin_plugin_hang"
                    "gremlin_plugin_snoop" "gremlin_plugin_leak"))
      (remhash name harness-tools)))
  (when (boundp 'harness-gremlin-plugin--observations)
    (setq harness-gremlin-plugin--observations nil))
  (when (boundp 'harness-gremlin-plugin--attempts)
    (setq harness-gremlin-plugin--attempts nil)))

(defun harness-gremlin-test--reset ()
  "Reset the state a chaos test may inherit from the one before it."
  (harness-gremlin-cleanup)
  (setq harness-gremlin-enabled nil
        harness-plugin-modules nil
        dir-locals-directory-cache nil
        dir-locals-class-alist nil)
  (when (boundp 'harness-provider-gremlin--continuations)
    (clrhash harness-provider-gremlin--continuations))
  (when (boundp 'harness-plugins--applied)
    (clrhash harness-plugins--applied))
  (harness-gremlin-test--forget-plugin))

(defun harness-gremlin-test--cleanup ()
  "Clean up after a chaos test: timers, processes and the plugin."
  (harness-gremlin-cleanup)
  (harness-gremlin-test--forget-plugin))

(defmacro harness-gremlin-test-with (modules &rest body)
  "Run BODY with the core modules and MODULES on a fresh bus and state.
The tool registry is emptied before MODULES load, so a plugin's tools
from an earlier test cannot leak in."
  (declare (indent 1))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (module '(store project config provider provider-gremlin gremlin tools session))
       (harness-test-load-module module))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (dolist (module ,modules)
       (harness-test-load-module module))
     (harness-gremlin-test--reset)
     (unwind-protect (progn ,@body)
       (harness-gremlin-test--cleanup))))

;;;; Shared fixtures

(defun harness-gremlin-test--allow (_decision next &rest _)
  "A `permission/decide' stage that allows every call."
  (funcall next (list :behavior 'allow)))

(defun harness-gremlin-test--session (root &optional extra)
  "Create a session in ROOT for the gremlin provider; return its id.
It is non-interactive and in yolo mode, so the tests never wait for a
person; the jail still refuses paths outside its directories."
  (plist-get (apply #'harness-call 'session/create
                    :cwd (file-name-as-directory (expand-file-name root))
                    :model "gremlin:chaos" :permission-mode 'yolo
                    :non-interactive t extra)
             :id))

(defun harness-gremlin-test--request (text &optional id)
  "Return a provider request whose last user message is TEXT."
  (list :model "gremlin:chaos"
        :session (list :id (or id "gremlin-provider-test")
                       :cwd (file-name-as-directory (harness-test-temp-dir)))
        :system ""
        :messages (list (list :role "user"
                              :content (list (list :type "text" :text text))))
        :tools nil :thinking nil))

(defun harness-gremlin-test--collect (text scenario &optional timeout)
  "Complete TEXT with SCENARIO and return (EVENTS . HANDLE).
Call `provider/complete', collect events until the first done, and
wait for it.  The caller runs this inside `harness-gremlin-with-run'."
  (let ((events nil) (done nil) (handle nil)
        (harness-provider-gremlin-scenario scenario)
        (harness-provider-gremlin-delay 0.001))
    (setq handle
          (harness-call
           'provider/complete
           (plist-put (harness-gremlin-test--request text)
                      :on-event
                      (lambda (event)
                        (push event events)
                        (when (eq (plist-get event :type) 'done)
                          (setq done t))))))
    (harness-test-wait (lambda () done) (or timeout 5)
                       (format "done for %s" scenario))
    (cons (nreverse events) handle)))

(defun harness-gremlin-test--done-events (events)
  "Return the done events in EVENTS."
  (cl-remove-if-not (lambda (event) (eq (plist-get event :type) 'done)) events))

(defun harness-gremlin-test--nodes (session-id &optional kind)
  "Return SESSION-ID's nodes, or those of KIND."
  (let ((nodes (harness-call 'session/nodes session-id)))
    (if kind (cl-remove-if-not (lambda (node) (eq (plist-get node :kind) kind)) nodes)
      nodes)))

(defun harness-gremlin-test--session-text (session-id)
  "Return all the text SESSION-ID recorded, for a leak assertion."
  (mapconcat (lambda (node)
               (format "%s" (or (plist-get node :output)
                                (plist-get node :content)
                                (plist-get node :input)
                                "")))
             (harness-gremlin-test--nodes session-id) "\n"))

(defun harness-gremlin-test--call (session-id name &optional input)
  "Execute tool NAME with INPUT for SESSION-ID and wait for its result."
  (harness-test-await
   (harness-call 'tools/execute session-id
                 (list :id (format "call-%s" name) :name name :input input))
   10))

(defun harness-gremlin-test--tool-names (session-id)
  "Return the names of the tools SESSION-ID gets."
  (mapcar (lambda (spec) (plist-get spec :name))
          (harness-call 'tools/list session-id)))

(defun harness-gremlin-test--frozen (session-id)
  "Return the plugin list SESSION-ID froze, as its `:ext' keeps it."
  (plist-get (plist-get (harness-call 'session/get session-id) :ext) :plugins))

(defun harness-gremlin-test--plugin-eval ()
  "Return the form that requires the gremlin plugin by its absolute path."
  `(require 'harness-gremlin-plugin
            ,(file-name-sans-extension
              (expand-file-name ".harness/plugins/gremlin/harness-gremlin-plugin"
                                harness-test-root))))

(defun harness-gremlin-test--entries (&optional modules)
  "Return trusted .dir-locals entries for the gremlin plugin and MODULES."
  (list (cons 'eval (harness-gremlin-test--plugin-eval))
        (cons 'harness-plugin-modules (or modules '(tools-gremlin-plugin)))))

(defun harness-gremlin-test--write-locals (dir &optional modules)
  "Write DIR's .dir-locals.el as a trusted project would have it."
  (let ((entries (harness-gremlin-test--entries modules)))
    (with-temp-file (expand-file-name ".dir-locals.el" dir)
      (let ((print-length nil) (print-level nil))
        (prin1 (list (cons nil entries)) (current-buffer))))
    (setq dir-locals-directory-cache nil
          dir-locals-class-alist nil)
    entries))

(defun harness-gremlin-test--project (&optional modules)
  "Make a temporary project whose plugin names MODULES, and return its directory."
  (let ((dir (file-name-as-directory (harness-test-temp-dir))))
    (harness-gremlin-test--write-locals dir modules)
    dir))

(defun harness-gremlin-test--plugin-session (dir &optional modules)
  "Create a session in DIR with the gremlin plugin trusted; return its id.
DIR must have the .dir-locals.el of `harness-gremlin-test--project'."
  (let ((safe-local-variable-values (harness-gremlin-test--entries modules))
        (enable-local-variables t)
        (enable-local-eval 'maybe))
    (clrhash harness-plugins--applied)
    (setq dir-locals-directory-cache nil)
    (harness-gremlin-test--session dir)))

;;;; The framework

(ert-deftest harness-gremlin-budget-refuses-what-is-over ()
  "A run stops at its budget, records that once, and returns less instead of more."
  (harness-gremlin-test-with nil
    (let ((harness-gremlin-budget
           '(:seconds 5 :bytes 10 :calls 2 :memory-mb 1 :processes 0)))
      (harness-gremlin-with-run "budget"
        (should (harness-gremlin-spend :bytes 8))
        (should-not (harness-gremlin-spend :bytes 5))
        (should (harness-gremlin-spend :calls 1))
        (should (harness-gremlin-spend :calls 1))
        (should-not (harness-gremlin-spend :calls 1))
        (let ((report (harness-gremlin-report)))
          (should (plist-get report :budget-exhausted))
          (should (= 1 (plist-get report :incidents)))
          (should (eq 'budget (plist-get (car (harness-gremlin-incidents)) :gremlin))))
        ;; The byte budget has 2 bytes left; the request gets exactly 2.
        (should (= 2 (length (harness-gremlin-bytes 100))))))))

(ert-deftest harness-gremlin-seeded-choice-is-reproducible ()
  "The same seed makes the same choices, so a chaos failure can be replayed."
  (harness-gremlin-test-with nil
    (let* ((harness-gremlin-seed 12345)
           (first (harness-gremlin-with-run
                    "seed a"
                    (cl-loop repeat 32 collect (harness-gremlin-random 1000))))
           (again (harness-gremlin-with-run
                   "seed b"
                   (cl-loop repeat 32 collect (harness-gremlin-random 1000)))))
      (should (equal first again))
      (should (= 32 (length first)))
      (should (cl-every (lambda (n) (and (integerp n) (<= 0 n) (< n 1000))) first))
      (let ((harness-gremlin-seed 54321))
        (should-not (equal first (harness-gremlin-with-run
                                 "seed c"
                                 (cl-loop repeat 32 collect (harness-gremlin-random 1000)))))))))

(ert-deftest harness-gremlin-cleanup-cancels-timers ()
  "A run's timer goes when the run does, even if the test failed first."
  (harness-gremlin-test-with nil
    (let (timer)
      (harness-gremlin-with-run "timers"
        (setq timer (harness-gremlin-run-at 60 #'ignore))
        (should (memq timer timer-list)))
      (should-not (memq timer timer-list)))))

(ert-deftest harness-gremlin-report-counts-origins-and-attempts ()
  "The report names what happened, how it was caused, and what was refused."
  (harness-gremlin-test-with nil
    (harness-gremlin-with-run "report"
      (harness-gremlin-incident 'slow "made the test wait" :seconds 2)
      (harness-gremlin-attempt 'slow "read" "/outside" (lambda () (error "refused")))
      (harness-gremlin-attempt 'slow "read" "/inside" (lambda () t))
      (let ((report (harness-gremlin-report)))
        (should (equal "report" (plist-get report :run)))
        (should (= 1 (plist-get report :incidents)))
        (should (= 2 (plist-get report :attempts)))
        (should (= 1 (plist-get report :attempts-allowed)))
        (should (= 1 (plist-get report :attempts-refused)))
        (should (equal 1 (alist-get 'unreliable (plist-get report :by-origin))))
        (should (equal 1 (alist-get 'slow (plist-get report :by-gremlin))))
        (should (string-match-p "1 incident" (harness-gremlin-describe-report report)))))))

(ert-deftest harness-gremlin-disarmed-records-nothing ()
  "Without `harness-gremlin-enabled', a gremlin may not act or write a log."
  (harness-gremlin-test-with nil
    (setq harness-gremlin-enabled nil)
    (harness-gremlin-reset)
    (should-not (harness-gremlin-armed-p))
    (should-not (harness-gremlin-incident 'slow "should not be recorded"))
    (should (equal '(t . 1)
                   (harness-gremlin-attempt 'slow "read" "/inside" (lambda () 1))))
    (should-not (harness-gremlin-attempts))
    (should-not (harness-gremlin-incidents))))

;;;; The provider

(ert-deftest harness-gremlin-provider-every-scenario-ends-with-one-done ()
  "Every scenario except hang ends a request with exactly one done event.
The provider may emit malformed events or a second done; the provider
wrapper must still give the agent one ending and no more."
  (harness-gremlin-test-with nil
    (dolist (scenario (harness-provider-gremlin--scenario-names))
      (unless (eq scenario 'hang)
        (let ((harness-gremlin-budget harness-gremlin-test--budget))
          (harness-gremlin-with-run (format "scenario-%s" scenario)
            (let* ((result (harness-gremlin-test--collect "gremlin scenario" scenario))
                   (dones (harness-gremlin-test--done-events (car result))))
              (should (= 1 (length dones)))
              (should (memq (plist-get (car dones) :stop-reason)
                            '(end-turn tool-use max-tokens error cancelled))))))))))

(ert-deftest harness-gremlin-provider-hang-cancels-once ()
  "A stream that never ends is ended by cancellation, exactly once."
  (harness-gremlin-test-with nil
    (let ((harness-gremlin-budget harness-gremlin-test--budget))
      (harness-gremlin-with-run "hang"
        (let* ((events nil) (done nil)
               (harness-provider-gremlin-scenario 'hang)
               (harness-provider-gremlin-delay 0.001)
               (request (harness-gremlin-test--request "gremlin hang"))
               (request (plist-put request :on-event
                                   (lambda (event)
                                     (push event events)
                                     (when (eq (plist-get event :type) 'done)
                                       (setq done t)))))
               (handle (harness-call 'provider/complete request)))
          (harness-test-wait (lambda () (>= (length events) 3)) 2 "hang events")
          (should-not done)
          (funcall (plist-get handle :cancel))
          (funcall (plist-get handle :cancel))
          (harness-test-wait (lambda () done) 1 "cancelled done")
          (let ((dones (harness-gremlin-test--done-events (nreverse events))))
            (should (= 1 (length dones)))
            (should (eq 'cancelled (plist-get (car dones) :stop-reason)))))))))

(ert-deftest harness-gremlin-provider-double-done-keeps-the-first ()
  "A second done is dropped by the provider wrapper; the turn ends once."
  (harness-gremlin-test-with nil
    (let ((harness-gremlin-budget harness-gremlin-test--budget))
      (harness-gremlin-with-run "double-done"
        (let* ((result (harness-gremlin-test--collect "gremlin double-done" 'double-done))
               (dones (harness-gremlin-test--done-events (car result))))
          (should (= 1 (length dones)))
          (should (eq 'end-turn (plist-get (car dones) :stop-reason)))
          (should-not (plist-get (car dones) :error)))))))

(ert-deftest harness-gremlin-provider-malformed-cannot-break-the-turn ()
  "Wrong types, missing fields and an unknown event end with a normal turn.
The agent may log or skip what it cannot use; it must not leave the
session running or lose the ending."
  (harness-gremlin-test-with '(agent)
    (harness-add-filter 'permission/decide #'harness-gremlin-test--allow 0)
    (let* ((root (harness-test-temp-dir))
           (session (harness-gremlin-test--session root)))
      (let ((harness-gremlin-budget harness-gremlin-test--budget))
        (harness-gremlin-with-run "malformed-agent"
          (let ((harness-provider-gremlin-scenario 'malformed)
                (harness-provider-gremlin-delay 0.001))
            (let ((turn (harness-test-await
                         (harness-call 'agent/prompt session "gremlin malformed") 10)))
              (should (eq 'end-turn (plist-get turn :stop-reason)))
              (should (harness-call 'session/exists-p session))
              (should (eq 'idle (plist-get (harness-call 'session/get session) :status)))
              (let ((results (harness-gremlin-test--nodes session 'tool-result)))
                (should (= 1 (length results)))
                (should (plist-get (car results) :is-error))))))))))

(ert-deftest harness-gremlin-provider-tool-storm-runs-every-call ()
  "A model that calls the same tool many times in one step gets every result."
  (harness-gremlin-test-with '(agent tools-gremlin)
    (harness-add-filter 'permission/decide #'harness-gremlin-test--allow 0)
    (let* ((root (harness-test-temp-dir))
           (session (harness-gremlin-test--session root))
           (count harness-provider-gremlin-max-tool-calls))
      (let ((harness-gremlin-budget harness-gremlin-test--budget))
        (harness-gremlin-with-run "tool-storm"
          (let ((harness-provider-gremlin-scenario 'tool-storm)
                (harness-provider-gremlin-delay 0.001))
            (let ((turn (harness-test-await
                         (harness-call 'agent/prompt session "gremlin tool-storm") 10)))
              (should (eq 'end-turn (plist-get turn :stop-reason)))
              (should (= count (length (harness-gremlin-test--nodes session 'tool-call))))
              (let ((results (harness-gremlin-test--nodes session 'tool-result)))
                (should (= count (length results)))
                (should (cl-every (lambda (node)
                                    (and (not (plist-get node :is-error))
                                         (string-prefix-p "pong" (or (plist-get node :output) ""))))
                                  results)))
              (should-not (gethash session harness-provider-gremlin--continuations)))))))))

(ert-deftest harness-gremlin-provider-ghost-tools-get-error-results ()
  "Calls to tools that do not exist end as error results, not as a stalled turn."
  (harness-gremlin-test-with '(agent)
    (harness-add-filter 'permission/decide #'harness-gremlin-test--allow 0)
    (let* ((root (harness-test-temp-dir))
           (session (harness-gremlin-test--session root)))
      (let ((harness-gremlin-budget harness-gremlin-test--budget))
        (harness-gremlin-with-run "ghost-tools"
          (let ((harness-provider-gremlin-scenario 'ghost-tools)
                (harness-provider-gremlin-delay 0.001))
            (let ((turn (harness-test-await
                         (harness-call 'agent/prompt session "gremlin ghost-tools") 10)))
              (should (eq 'end-turn (plist-get turn :stop-reason)))
              (let ((results (harness-gremlin-test--nodes session 'tool-result)))
                (should (= 3 (length results)))
                (should (cl-every (lambda (node) (plist-get node :is-error)) results))
                (should (cl-every (lambda (node)
                                    (string-match-p "Unknown tool" (or (plist-get node :output) "")))
                                  results))))))))))

(ert-deftest harness-gremlin-provider-shortcut-is-refused-by-the-jail ()
  "The shortcut scenario cannot read a file outside the session.
The jail refuses the call before the tool's handler runs, and the
secret never reaches a transcript node."
  (harness-gremlin-test-with '(agent tools-gremlin perms)
    (let* ((root (harness-test-temp-dir))
           (outside (harness-test-temp-dir))
           (secret (expand-file-name "secret.txt" outside))
           (marker "gremlin-shortcut-secret-marker")
           (session (harness-gremlin-test--session root)))
      (with-temp-file secret (insert marker "\n"))
      (let ((harness-gremlin-budget harness-gremlin-test--budget))
        (harness-gremlin-with-run "shortcut"
          (let ((harness-provider-gremlin-scenario 'shortcut)
                (harness-provider-gremlin-target secret)
                (harness-provider-gremlin-delay 0.001))
            (let ((turn (harness-test-await
                         (harness-call 'agent/prompt session "gremlin shortcut") 10)))
              (should (eq 'end-turn (plist-get turn :stop-reason)))
              (let ((results (harness-gremlin-test--nodes session 'tool-result)))
                (should (= 1 (length results)))
                (should (plist-get (car results) :is-error))
                (should (string-match-p "outside the allowed directories"
                                        (or (plist-get (car results) :output) ""))))
              (should-not (string-search marker (harness-gremlin-test--session-text session)))
              ;; The handler never ran, so the attempt log is empty.
              (should-not (harness-gremlin-attempts)))))))))

(ert-deftest harness-gremlin-provider-secret-is-masked-before-it-echoes ()
  "A tool result full of secrets is masked before the model can repeat it."
  (harness-gremlin-test-with '(agent tools-gremlin secrets)
    (harness-add-filter 'permission/decide #'harness-gremlin-test--allow 0)
    (let* ((root (harness-test-temp-dir))
           (session (harness-gremlin-test--session root)))
      (let ((harness-gremlin-budget harness-gremlin-test--budget))
        (harness-gremlin-with-run "secret-leak"
          (let ((harness-provider-gremlin-scenario 'secret-leak)
                (harness-provider-gremlin-delay 0.001))
            (let ((turn (harness-test-await
                         (harness-call 'agent/prompt session "gremlin secret-leak") 10))
                  (text nil))
              (should (eq 'end-turn (plist-get turn :stop-reason)))
              (setq text (harness-gremlin-test--session-text session))
              (should (string-search "[redacted:" text))
              (should-not (string-search "gremlin000000000000000000000000000000" text))
              (should-not (string-search "plugin-password" text)))))))))

(ert-deftest harness-gremlin-provider-quota-and-rate-limit-keep-their-kind ()
  "Quota and rate-limit failures reach the agent classified, with a reset time."
  (harness-gremlin-test-with nil
    (dolist (case '(("gremlin quota" quota) ("gremlin rate-limit" rate-limit)))
      (let ((harness-gremlin-budget harness-gremlin-test--budget))
        (harness-gremlin-with-run (format "failure-%s" (cadr case))
          (let* ((result (harness-gremlin-test--collect
                          (car case) (cadr case)))
                 (done (car (harness-gremlin-test--done-events (car result)))))
            (should (eq 'error (plist-get done :stop-reason)))
            (should (eq (cadr case) (plist-get done :error-kind)))
            (should (numberp (plist-get done :resets)))))))))

(ert-deftest harness-gremlin-provider-flood-respects-the-byte-budget ()
  "A flood stops at the run's byte budget; what it cut is recorded."
  (harness-gremlin-test-with nil
    (let ((harness-gremlin-budget
           '(:seconds 5 :bytes 20000 :calls 300 :memory-mb 8 :processes 2)))
      (harness-gremlin-with-run "flood"
        (let* ((result (harness-gremlin-test--collect "gremlin flood" 'flood))
               (text-bytes (cl-loop for event in (car result)
                                    when (memq (plist-get event :type) '(text thinking))
                                    sum (length (or (plist-get event :delta) "")))))
          (should (> text-bytes 0))
          (should (<= text-bytes 20000))
          (should (cl-some (lambda (incident)
                             (equal "text-clamped" (plist-get incident :event)))
                           (harness-gremlin-incidents))))))))

(ert-deftest harness-gremlin-provider-choice-is-seeded ()
  "Without a named scenario, the seed decides which gremlin a request meets."
  (harness-gremlin-test-with nil
    (let* ((harness-gremlin-seed 20261104)
           (request (harness-gremlin-test--request "hello, no scenario here"))
           (choices (lambda ()
                      (let ((harness-provider-gremlin-scenario nil))
                        (cl-loop repeat 25 collect
                                 (harness-provider-gremlin--scenario request)))))
           (first (harness-gremlin-with-run "choice a" (funcall choices)))
           (again (harness-gremlin-with-run "choice b" (funcall choices))))
      (should (equal first again))
      (should (= 25 (length first)))
      (should (cl-every (lambda (scenario)
                          (memq scenario (harness-provider-gremlin--scenario-names)))
                        first)))))

(ert-deftest harness-gremlin-provider-liar-is-recorded-not-believed ()
  "A model may claim success; the harness records the claim, not evidence of it.
This is the `optimizer' gremlin: there is no tool call to point at, and
the transcript must show exactly that."
  (harness-gremlin-test-with '(agent)
    (harness-add-filter 'permission/decide #'harness-gremlin-test--allow 0)
    (let* ((root (harness-test-temp-dir))
           (session (harness-gremlin-test--session root)))
      (let ((harness-gremlin-budget harness-gremlin-test--budget))
        (harness-gremlin-with-run "liar"
          (let ((harness-provider-gremlin-scenario 'liar)
                (harness-provider-gremlin-delay 0.001))
            (let ((turn (harness-test-await
                         (harness-call 'agent/prompt session "gremlin liar") 10)))
              (should (eq 'end-turn (plist-get turn :stop-reason)))
              (should-not (harness-gremlin-test--nodes session 'tool-call))
              (let ((assistant (mapconcat (lambda (node) (or (plist-get node :content) ""))
                                          (harness-gremlin-test--nodes session 'assistant) "\n")))
                (should (string-match-p "all tests pass" assistant))))))))))

;;;; The tools

(ert-deftest harness-gremlin-tools-hang-hits-the-timeout ()
  "A tool whose promise never settles fails as a timeout, not as a stall."
  (harness-gremlin-test-with '(tools-gremlin)
    (harness-add-filter 'permission/decide #'harness-gremlin-test--allow 0)
    (let ((harness-gremlin-budget harness-gremlin-test--budget)
          (start (float-time)))
      (harness-gremlin-with-run "tool-hang"
        (let ((result (harness-gremlin-test--call nil "gremlin_hang")))
          (should (plist-get result :is-error))
          (should (string-match-p "timed out" (plist-get result :content)))
          (should (>= (- (float-time) start) 0.35))
          (should (< (- (float-time) start) 2.0)))))))

(ert-deftest harness-gremlin-tools-big-output-is-truncated-and-saved ()
  "A result larger than the guard is cut, and its whole text is saved."
  (harness-gremlin-test-with '(tools-gremlin)
    (harness-add-filter 'permission/decide #'harness-gremlin-test--allow 0)
    (let ((harness-gremlin-budget harness-gremlin-test--budget)
          (harness-tools-max-output-chars 1000))
      (harness-gremlin-with-run "tool-big"
        (let* ((result (harness-gremlin-test--call nil "gremlin_big" '(:bytes 5000)))
               (truncated (plist-get result :truncated))
               (path (plist-get truncated :path)))
          (should-not (plist-get result :is-error))
          (should path)
          (should (file-exists-p path))
          (should (= 5000 (with-temp-buffer
                            (insert-file-contents path)
                            (buffer-size))))
          (should (< (length (plist-get result :content)) 1200))
          (should (= 5000 (plist-get truncated :chars))))))))

(ert-deftest harness-gremlin-tools-errors-are-normalised ()
  "A handler that signals, rejects or returns nonsense becomes a result.
Nothing escapes `tools/execute', and a strange value is a string."
  (harness-gremlin-test-with '(tools-gremlin)
    (harness-add-filter 'permission/decide #'harness-gremlin-test--allow 0)
    (let ((harness-gremlin-budget harness-gremlin-test--budget))
      (harness-gremlin-with-run "tool-errors"
        (dolist (mode '("signal" "reject" "report-then-signal"))
          (let ((result (harness-gremlin-test--call nil "gremlin_error" (list :mode mode))))
            (should (plist-get result :is-error))
            (should (stringp (plist-get result :content)))))
        (dolist (case '(("bad-result" . nil) ("no-content" . nil)
                        ("nil" . nil) ("number" . nil)))
          (let ((result (harness-gremlin-test--call nil "gremlin_error"
                                                    (list :mode (car case)))))
            (should-not (plist-get result :is-error))
            (should (stringp (plist-get result :content)))))
        (should (equal "42" (plist-get (harness-gremlin-test--call
                                        nil "gremlin_error" '(:mode "number"))
                                       :content)))))))

(ert-deftest harness-gremlin-tools-outside-path-is-refused ()
  "A probe of a path outside the session never reaches the handler.
Inside the session it runs and records an allowed attempt, without
printing the file's contents."
  (harness-gremlin-test-with '(tools-gremlin perms)
    (let* ((root (harness-test-temp-dir))
           (outside (harness-test-temp-dir))
           (secret (expand-file-name "secret.txt" outside))
           (inside (expand-file-name "inside.txt" root))
           (marker "gremlin-probe-secret-marker")
           (session (harness-gremlin-test--session root)))
      (with-temp-file secret (insert marker "\n"))
      (with-temp-file inside (insert "inside only\n"))
      (let ((harness-gremlin-budget harness-gremlin-test--budget))
        (harness-gremlin-with-run "tool-probe"
          (let ((outside-result (harness-gremlin-test--call
                                 session "gremlin_probe"
                                 (list :targets (list secret)))))
            (should (plist-get outside-result :is-error))
            (should (string-match-p "outside the allowed directories"
                                    (plist-get outside-result :content)))
            (should-not (string-search marker (plist-get outside-result :content)))
            (should-not (harness-gremlin-attempts)))
          (let ((inside-result (harness-gremlin-test--call
                                session "gremlin_probe"
                                (list :targets (list inside)))))
            (should-not (plist-get inside-result :is-error))
            (should (string-match-p "readable" (plist-get inside-result :content)))
            (should-not (string-search "inside only" (plist-get inside-result :content))))
          (let ((attempts (harness-gremlin-attempts)))
            (should (= 1 (length attempts)))
            (should (plist-get (car attempts) :allowed))))))))

(ert-deftest harness-gremlin-tools-leak-is-masked ()
  "The leak tool's fake credentials are masked before they reach a caller."
  (harness-gremlin-test-with '(tools-gremlin secrets)
    (harness-add-filter 'permission/decide #'harness-gremlin-test--allow 0)
    (let ((harness-gremlin-budget harness-gremlin-test--budget))
      (harness-gremlin-with-run "tool-leak"
        (let ((result (harness-gremlin-test--call nil "gremlin_leak")))
          (should-not (plist-get result :is-error))
          (should (string-search "[redacted:" (plist-get result :content)))
          (should-not (string-search "gremlin000000000000000000000000000000"
                                     (plist-get result :content)))
          (should-not (string-search "plugin-password" (plist-get result :content))))))))

(ert-deftest harness-gremlin-tools-resource-hog-is-bounded ()
  "A CPU and memory request is clamped by the run's budget, not obeyed."
  (harness-gremlin-test-with '(tools-gremlin)
    (harness-add-filter 'permission/decide #'harness-gremlin-test--allow 0)
    (let ((harness-gremlin-budget
           '(:seconds 2 :bytes 200000 :calls 300 :memory-mb 2 :processes 2))
          (start (float-time)))
      (harness-gremlin-with-run "tool-hog"
        (let ((result (harness-gremlin-test--call
                       nil "gremlin_hog" '(:milliseconds 20 :megabytes 8))))
          (should-not (plist-get result :is-error))
          (should (string-match-p "allocated 2097152" (plist-get result :content)))
          (should (string-match-p "8 MB" (plist-get result :content)))
          (should (< (- (float-time) start) 1.5))
          (should (cl-some (lambda (incident)
                             (equal "memory-clamped" (plist-get incident :event)))
                           (harness-gremlin-incidents))))))))

(ert-deftest harness-gremlin-tools-slow-reports-progress ()
  "A slow tool reports progress and then answers, without a manual wait."
  (harness-gremlin-test-with '(tools-gremlin)
    (harness-add-filter 'permission/decide #'harness-gremlin-test--allow 0)
    (let ((harness-gremlin-budget harness-gremlin-test--budget)
          (progress nil))
      (harness-on 'tools/progress
                  (lambda (_session-id _call-id text) (push text progress)))
      (harness-gremlin-with-run "tool-slow"
        (let ((result (harness-gremlin-test--call
                       nil "gremlin_slow" '(:seconds 0.05 :chunks 3))))
          (should-not (plist-get result :is-error))
          (should (string-match-p "Waited" (plist-get result :content)))
          (should (= 3 (length progress)))
          (should (cl-every (lambda (text) (string-match-p "gremlin slow" text)) progress)))))))

(ert-deftest harness-gremlin-tools-run-cleanup-kills-a-leftover-process ()
  "A tool that leaves a process behind does not outlive its gremlin run."
  (skip-unless (executable-find "sleep"))
  (harness-gremlin-test-with '(tools-gremlin)
    (harness-add-filter 'permission/decide #'harness-gremlin-test--allow 0)
    (let ((harness-gremlin-budget harness-gremlin-test--budget)
          process)
      (harness-gremlin-with-run "tool-process"
        (let ((result (harness-gremlin-test--call
                       nil "gremlin_stay" '(:seconds 30))))
          (should-not (plist-get result :is-error))
          (setq process (car harness-gremlin--processes))
          (should (process-live-p process)))
        (harness-gremlin-cleanup)
        (should-not (process-live-p process))
        (should-not harness-gremlin--processes)))))

(ert-deftest harness-gremlin-tools-disarmed-refuse-to-run ()
  "Without an armed run, a gremlin tool returns an error and does nothing."
  (harness-gremlin-test-with '(tools-gremlin)
    (harness-add-filter 'permission/decide #'harness-gremlin-test--allow 0)
    (let ((result (harness-gremlin-test--call nil "gremlin_ping" nil)))
      (should (plist-get result :is-error))
      (should (string-match-p "disarmed" (plist-get result :content))))))

(ert-deftest harness-gremlin-tools-malformed-path-is-refused ()
  "A probe whose target is not a string is refused before the handler.
A call with no usable paths is not a call with nothing to judge."
  (harness-gremlin-test-with '(tools-gremlin)
    (harness-add-filter 'permission/decide #'harness-gremlin-test--allow 0)
    (let ((harness-gremlin-budget harness-gremlin-test--budget))
      (harness-gremlin-with-run "tool-malformed-path"
        (let ((result (harness-gremlin-test--call
                       nil "gremlin_probe" '(:targets (42)))))
          (should (plist-get result :is-error))
          (should (string-match-p "could not be worked out" (plist-get result :content)))
          (should-not (harness-gremlin-attempts)))))))

;;;; The plugin

(ert-deftest harness-gremlin-plugin-trust-scope-and-freeze ()
  "A gremlin plugin is only loaded when trusted, and its tools only reach
the sessions that name its module.  A session keeps the list it started
with when the project's file changes."
  (harness-gremlin-test-with '(plugins)
    (let* ((dir (harness-gremlin-test--project))
           (other-dir (harness-gremlin-test--project '(other))))
      ;; Untrusted: the plugin's eval and variable do not apply.
      (let ((safe-local-variable-values nil)
            (enable-local-variables t)
            (enable-local-eval 'maybe))
        (let ((session (harness-gremlin-test--session dir)))
          (should (eq :false (harness-gremlin-test--frozen session)))
          (should-not (featurep 'harness-gremlin-plugin))
          (should-not (harness-tool-get "gremlin_plugin_echo"))))
      ;; Trusted: the plugin loads, its module starts, and its tool is in scope.
      (let ((harness-gremlin-enabled t)
            (harness-gremlin-seed 42)
            (harness-gremlin-budget harness-gremlin-test--budget))
        (harness-gremlin-reset)
        (let ((session (harness-gremlin-test--plugin-session dir)))
          (should (equal '("tools-gremlin-plugin")
                         (harness-gremlin-test--frozen session)))
          (should (featurep 'harness-gremlin-plugin))
          (should (harness-module-plugin-p 'tools-gremlin-plugin))
          (should (harness-module-ready-p 'tools-gremlin-plugin))
          (should (member "gremlin_plugin_echo"
                          (harness-gremlin-test--tool-names session)))
          (should (cl-some (lambda (entry)
                             (equal "loaded" (plist-get entry :event)))
                           harness-gremlin-plugin--observations))
          (harness-add-filter 'permission/decide #'harness-gremlin-test--allow 0)
          (let ((result (harness-gremlin-test--call
                         session "gremlin_plugin_echo" nil)))
            (should-not (plist-get result :is-error))
            (should (equal "the gremlin plugin tool ran" (plist-get result :content))))
        ;; Another project names another module: no plugin tool.
        (let ((other (harness-gremlin-test--plugin-session other-dir '(other))))
          (should (equal '("other") (harness-gremlin-test--frozen other)))
          (should-not (member "gremlin_plugin_echo"
                              (harness-gremlin-test--tool-names other)))
          (harness-add-filter 'permission/decide #'harness-gremlin-test--allow 0)
          (let ((result (harness-gremlin-test--call other "gremlin_plugin_echo" nil)))
            (should (plist-get result :is-error))
            (should (string-prefix-p "Unknown tool" (plist-get result :content)))))
        ;; Freezing: a rewritten file changes the next session, not this one.
        (should (equal '("tools-gremlin-plugin")
                       (harness-gremlin-test--frozen session)))
        (harness-gremlin-test--write-locals dir '(other))
        (let ((new (harness-gremlin-test--plugin-session dir '(other))))
          (should (equal '("other") (harness-gremlin-test--frozen new))))
        (should (equal '("tools-gremlin-plugin")
                       (harness-gremlin-test--frozen session))))))))

(ert-deftest harness-gremlin-plugin-hanging-tool-times-out ()
  "A plugin tool goes through the same timeout as any other tool."
  (harness-gremlin-test-with '(plugins)
    (let* ((dir (harness-gremlin-test--project))
           (harness-gremlin-enabled t)
           (harness-gremlin-seed 42)
           (harness-gremlin-budget harness-gremlin-test--budget)
           (start (float-time)))
      (harness-gremlin-reset)
      (let ((session (harness-gremlin-test--plugin-session dir)))
        (harness-add-filter 'permission/decide #'harness-gremlin-test--allow 0)
        (let ((result (harness-gremlin-test--call
                       session "gremlin_plugin_hang" nil)))
          (should (plist-get result :is-error))
          (should (string-match-p "timed out" (plist-get result :content)))
          (should (>= (- (float-time) start) 0.3))
          (should (< (- (float-time) start) 2.0)))))))

(ert-deftest harness-gremlin-plugin-load-failure-is-contained ()
  "A plugin that signals while loading leaves the harness and session alive.
Its eval fails, its module never exists, and the session starts with no
plugin tools."
  (harness-gremlin-test-with '(plugins)
    (let* ((dir (file-name-as-directory (harness-test-temp-dir)))
           (plugin-file (expand-file-name "harness-crashplug.el" dir)))
      (with-temp-file plugin-file
        (insert ";;; -*- lexical-binding: t; -*-\n"
                "(require 'harness-tools)\n"
                "(error \"the gremlin plugin crashed while loading\")\n"
                "(provide 'harness-crashplug)\n"))
      (let ((entries (list (cons 'eval
                                 `(require 'harness-crashplug
                                           ,(file-name-sans-extension plugin-file)))
                           (cons 'harness-plugin-modules '(crashplug)))))
        (with-temp-file (expand-file-name ".dir-locals.el" dir)
          (let ((print-length nil) (print-level nil))
            (prin1 (list (cons nil entries)) (current-buffer))))
        (setq dir-locals-directory-cache nil)
        (clrhash harness-plugins--applied)
        (let ((safe-local-variable-values entries)
              (enable-local-variables t)
              (enable-local-eval 'maybe))
          (let ((session (harness-gremlin-test--session dir)))
            (should (harness-call 'session/exists-p session))
            (should (eq 'idle (plist-get (harness-call 'session/get session) :status)))
            (should (eq :false (harness-gremlin-test--frozen session)))
            (should-not (featurep 'harness-crashplug))
            (should-not (harness-module-get 'crashplug))))))))

(ert-deftest harness-gremlin-plugin-tools-are-jailed-and-masked ()
  "A plugin's tools meet the same jail and the same masking as any other.
The snoop tool's path outside the session is refused before its handler
runs, so nothing is read and nothing is recorded; the leak tool's
credentials are masked before the caller sees them."
  (harness-gremlin-test-with '(plugins perms secrets)
    (let* ((dir (harness-gremlin-test--project))
           (outside (harness-test-temp-dir))
           (secret (expand-file-name "secret.txt" outside))
           (marker "gremlin-plugin-snoop-marker")
           (harness-gremlin-enabled t)
           (harness-gremlin-seed 42)
           (harness-gremlin-budget harness-gremlin-test--budget))
      (with-temp-file secret (insert marker "\n"))
      (harness-gremlin-reset)
      (let ((session (harness-gremlin-test--plugin-session dir)))
        (let ((result (harness-gremlin-test--call
                       session "gremlin_plugin_snoop"
                       (list :targets (list secret)))))
          (should (plist-get result :is-error))
          (should (string-match-p "outside the allowed directories"
                                  (plist-get result :content)))
          (should-not (string-search marker (plist-get result :content)))
          (should-not (string-search marker
                                     (harness-gremlin-test--session-text session)))
          (should-not harness-gremlin-plugin--attempts))
        (let ((result (harness-gremlin-test--call session "gremlin_plugin_leak" nil)))
          (should-not (plist-get result :is-error))
          (should (string-search "[redacted:" (plist-get result :content)))
          (should-not (string-search "sk-ant-" (plist-get result :content)))
          (should-not (string-search "plugin-password" (plist-get result :content)))
          (should-not (string-search "sk-ant-" (harness-gremlin-test--session-text session))))))))

(ert-deftest harness-gremlin-plugin-planted-checkout-is-refused ()
  "A trusted-looking plugin in a checkout an agent could have made is not applied."
  (harness-gremlin-test-with '(plugins)
    (let* ((dir (file-name-as-directory
                 (expand-file-name "planted" harness-session--tmp-root)))
           (entries (harness-gremlin-test--entries)))
      (make-directory dir t)
      (harness-gremlin-test--write-locals dir '(tools-gremlin-plugin))
      (setq dir-locals-directory-cache nil)
      (clrhash harness-plugins--applied)
      (should (harness-plugins--planted-p dir))
      (let ((safe-local-variable-values entries)
            (enable-local-variables t)
            (enable-local-eval 'maybe))
        (let ((session (harness-gremlin-test--session dir)))
          (should (eq :false (harness-gremlin-test--frozen session)))
          (should-not (featurep 'harness-gremlin-plugin))
          (should-not (harness-tool-get "gremlin_plugin_echo")))))))

(provide 'harness-gremlin-test)
;;; harness-gremlin-test.el ends here
