;;; harness-provider-chaos-test.el --- Adversarial turns and recovery -*- lexical-binding: t; -*-

(require 'harness-test-helpers)
(require 'harness-provider-openai)

(defmacro harness-provider-chaos-test-with (&rest body)
  "Run BODY with an isolated session and a real registered faulty provider."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (module '(store project config provider tools session agent))
       (harness-test-load-module module))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (let ((default-directory dir)
           (script nil) (wire nil) (hold-done nil) (cancel-fails-once nil)
           (requests 0) (executions 0) (ended 0) (cancels 0) callbacks)
       (harness-define-provider 'chaos
         :models (lambda () (harness-resolved '((:name "events" :context-window 8000))))
         :complete
         (lambda (request)
           (cl-incf requests)
           ;; An accepting fake is not a recovery oracle.  Native APIs
           ;; require string tool identifiers and names on later requests.
           (dolist (message (plist-get request :messages))
             (dolist (block (plist-get message :content))
               (pcase (plist-get block :type)
                 ("tool_use"
                  (should (stringp (plist-get block :id)))
                  (should (stringp (plist-get block :name)))
                  (should (string-prefix-p "{" (harness-json-encode (plist-get block :input)))))
                 ("tool_result" (should (stringp (plist-get block :tool_use_id)))))))
           (let ((emit (plist-get request :on-event))
                 (events script))
             (push emit callbacks)
             (setq script nil)
             (if wire
                 (let* ((payload wire)
                        (stream (make-harness-openai--stream
                                 :on-event emit :endpoint '(:id chaos :base-url "https://invalid.example")))
                        (parser (harness-http-sse-parser
                                 (lambda (_name data) (harness-openai--stream-chunk stream data)))))
                   (setq wire nil)
                   ;; The real HTTP callback runs after complete returns.
                   ;; A synchronous fake would let provider/complete catch
                   ;; errors which actually escape through a timer/filter.
                   (harness-run-soon
                    (lambda () (funcall parser payload) (harness-openai--stream-complete stream))))
               (dolist (event events) (funcall emit event))
               (unless hold-done
                 (funcall emit '(:type text :delta "healthy answer"))
                 (funcall emit '(:type done :stop-reason end-turn))))
             (list :cancel (lambda ()
                             (cl-incf cancels)
                             (when cancel-fails-once
                               (setq cancel-fails-once nil)
                               (error "cancellation failed before stopping")))))))
       (harness-add-filter 'permission/decide
                           (lambda (_ next &rest _) (funcall next '(:behavior allow))))
       (harness-define-tool "chaos_echo" :label "Echo" :description "Pure fixture" :kind 'read
                            :handler (lambda (_input _ctx) (cl-incf executions) "echo"))
       (let ((sid (plist-get (harness-call 'session/create :cwd dir :model "chaos:events") :id)))
         (harness-on 'agent/turn-ended (lambda (&rest _) (cl-incf ended)))
         ,@body))))

(defconst harness-provider-chaos-test-events
  '(nil 42 "not an event" [] (:type . text) (:type text :delta)
    (:type text :delta 42) (:type text :delta [1 2]) (:type thinking :delta (:bad t))
    (:type usage :input "many") (:type usage :output -1) (:type usage :cost [])
    (:type hint :text 42) (:type hint :text (:bad t))
    (:type activity :phase [bad] :chars "many")
    (:type quota :windows 42) (:type provider-state :state 42)
    (:type provider-state :state "opaque") (:type checkpoint :checkpoint 42)
    (:type tool-call :id "bad-input" :name "chaos_echo" :input 42)
    (:type tool-call :id "missing" :name "missing_tool" :input nil)
    (:type tool-call :id 42 :name "chaos_echo" :input nil)
    (:type tool-call :id [] :name "chaos_echo" :input nil)
    (:type tool-call :id "bad-name" :name 42 :input nil)
    (:type tool-call :id "bad-respond" :name "chaos_echo" :input nil :respond 42)
    (:type tool-result :id "unasked" :output 42)
    (:type done :stop-reason "end-turn") (:type done :stop-reason "not-a-reason")
    (:type done :stop-reason [bad]) (:type "done" :stop-reason "end-turn")
    (:type done :stop-reason error :error (:bad t))
    (:type done :stop-reason tool-use) (:type done)
    (:type unknown :payload (:bad t))
    (:type text :delta "valid text") (:type thinking :delta "valid thinking")
    (:type usage :input 3 :output 1 :cost 0.0)
    (:type tool-call :id "echo" :name "chaos_echo" :input (:text "hi")))
  "A bounded corpus of valid events and mutations of their shapes and fields.")

(defun harness-provider-chaos-test-check (events &optional wire-data)
  "Drive EVENTS through the provider registry, turn, persistence and next prompt."
  (harness-provider-chaos-test-with
    (setq script events wire wire-data)
    (let ((result (harness-test-await (harness-call 'agent/prompt sid "adversarial turn") 2)))
      (should (memq (plist-get result :stop-reason) '(end-turn error max-tokens cancelled blocked)))
      (when wire-data (should (eq 'error (plist-get result :stop-reason))))
      (should (= 1 ended))
      (should-not (harness-agent-running-p sid))
      (should-not (plist-get (harness-call 'session/get sid) :pending))
      (should-not (plist-get (harness-call 'agent/activity sid) :calls)))
    ;; Probe recovery, not just the absence of an exception.  Keep the same
    ;; session, and then cold-load its actual saved record and node journal.
    (should (eq 'end-turn (plist-get (harness-test-await
                                    (harness-call 'agent/prompt sid "continue") 2) :stop-reason)))
    (harness-session-flush)
    (clrhash harness-sessions)
    (harness-session--load-all)
    (should-not (harness-call 'session/hydration-faults))
    (should (eq 'end-turn (plist-get (harness-test-await
                                    (harness-call 'agent/prompt sid "after reload") 2) :stop-reason)))
    (should (= 3 ended))
    (let ((before (copy-tree (harness-call 'session/nodes sid))))
      ;; Every old request must have lost authority over the session.
      (dolist (callback callbacks)
        (funcall callback '(:type text :delta "late corruption"))
        (funcall callback '(:type done :stop-reason error :error "late failure")))
      (should (equal before (harness-call 'session/nodes sid))))))

(ert-deftest harness-provider-chaos-corpus-survives-turn-and-reload ()
  (let ((index 0) (print-circle t) (print-level 4) (print-length 12))
    (dolist (event harness-provider-chaos-test-events)
      (ert-info ((format "corpus case %d: %S" index event))
        (harness-provider-chaos-test-check (list event)))
      (cl-incf index))))

(ert-deftest harness-provider-chaos-seeded-sequences-survive-turn-and-reload ()
  "Reproduce any campaign failure with the start seed and a count of one."
  (let ((start (string-to-number (or (getenv "HARNESS_PROVIDER_CHAOS_START_SEED") "0")))
        (count (string-to-number (or (getenv "HARNESS_PROVIDER_CHAOS_SEEDS") "32")))
        (print-circle t) (print-level 4) (print-length 12))
    (should (> count 0))
    (dotimes (offset count)
      (let* ((seed (+ start offset)) (state seed) events)
        (dotimes (_ 8)
          (setq state (logand #x7fffffff (+ (* state 1103515245) 12345)))
          (push (nth (% state (length harness-provider-chaos-test-events))
                     harness-provider-chaos-test-events) events))
        (setq events (nreverse events))
        (ert-info ((format "seed=%d events=%S" seed events))
          (harness-provider-chaos-test-check events))))))

(ert-deftest harness-provider-chaos-duplicate-call-cannot-repeat-effect ()
  (harness-provider-chaos-test-with
    (setq script '((:type tool-call :id "same" :name "chaos_echo" :input nil)
                   (:type tool-call :id "same" :name "chaos_echo" :input nil)))
    (harness-test-await (harness-call 'agent/prompt sid "duplicate delivery") 2)
    (should (= 1 executions))
    (should-not (harness-agent-running-p sid))
    ;; A separate user request is not a duplicate of the old request.
    (setq script '((:type tool-call :id "same" :name "chaos_echo" :input nil)))
    (harness-test-await (harness-call 'agent/prompt sid "independent request") 2)
    (should (= 2 executions))))

(ert-deftest harness-provider-chaos-completed-hosted-call-cannot-repeat-effect ()
  (harness-provider-chaos-test-with
    (let ((replies 0))
      (setq hold-done t
            script (list
                    (list :type 'tool-call :id "same" :name "chaos_echo" :input nil
                          :respond
                          (lambda (_result)
                            (cl-incf replies)
                            ;; The original result was already recorded and
                            ;; removed from the active call list before respond.
                            (funcall (car callbacks)
                                     (list :type 'tool-call :id "same" :name "chaos_echo" :input nil
                                           :respond (lambda (_duplicate) (cl-incf replies))))
                            (funcall (car callbacks) '(:type done :stop-reason end-turn))))))
      (harness-test-await (harness-call 'agent/prompt sid "late duplicate") 2)
      (should (= 1 executions))
      (should (= 2 replies))
      (should (= 1 ended)))))

(ert-deftest harness-provider-chaos-late-events-cannot-end-replacement-turn ()
  (harness-provider-chaos-test-with
    (let ((harness-agent--cancel-grace 0.001))
      (setq hold-done t)
      (let ((old (harness-call 'agent/prompt sid "never ends")))
        (harness-test-wait (lambda () (= 1 requests)))
        (harness-call 'agent/cancel sid)
        (should (eq 'cancelled (plist-get (harness-test-await old 2) :stop-reason))))
      (let ((replacement (harness-call 'agent/prompt sid "replacement")))
        (harness-test-wait (lambda () (= 2 requests)))
        (let ((before (copy-tree (harness-call 'session/nodes sid)))
              (old (cadr callbacks)))
          (funcall old '(:type tool-call :id "late" :name "chaos_echo" :input nil))
          (funcall old '(:type provider-state :state (:corrupt "late")))
          (funcall old '(:type done :stop-reason error :error "late failure"))
          (should-not (harness-promise-settled-p replacement))
          (should (zerop executions))
          (should (equal before (harness-call 'session/nodes sid))))
        (funcall (car callbacks) '(:type done :stop-reason end-turn))
        (should (eq 'end-turn (plist-get (harness-test-await replacement 2) :stop-reason)))
        (should (= 2 ended))))))

(ert-deftest harness-provider-chaos-guard-tolerates-circular-and-improper-envelopes ()
  (harness-provider-chaos-test-with
    (let* ((cycle (list :unrecognised t))
           (seen nil)
           (guard (harness-provider--guard-events (lambda (event) (push event seen)))))
      (setcdr (last cycle) cycle)
      (dolist (event (list cycle '(:type . done) 42 [] "noise"))
        (funcall guard event))
      (funcall guard '(:type done :stop-reason [bad]))
      (funcall guard '(:type done :stop-reason end-turn))
      (should (= 1 (length seen)))
      (should (eq 'error (plist-get (car seen) :stop-reason)))
      (should (eq 'protocol (plist-get (car seen) :error-kind))))))

(ert-deftest harness-provider-chaos-malformed-terminal-stops-the-live-provider ()
  "Converting a bad terminal event to an error must also stop its producer."
  (harness-provider-chaos-test-with
    (setq hold-done t)
    (let ((promise (harness-call 'agent/prompt sid "asynchronous bad terminal")))
      (harness-test-wait (lambda () (= 1 requests)))
      (funcall (car callbacks) '(:type done :stop-reason [bad]))
      (should (eq 'error (plist-get (harness-test-await promise 2) :stop-reason)))
      (should (= 1 cancels))
      (should-not (harness-agent-running-p sid)))))

(ert-deftest harness-provider-chaos-terminal-shapes-always-deliver-a-usable-ending ()
  (harness-provider-chaos-test-with
    (dolist (terminal '((:type done :stop-reason) (:type done . broken)
                        (:type "done" :stop-reason "end-turn")
                        (:type done :stop-reason [bad]) (:type done :error 42)))
      (let* ((seen nil)
             (callback (harness-provider--guard-events (lambda (event) (push event seen)))))
        (funcall callback terminal)
        (should (= 1 (length seen)))
        (should (memq (plist-get (car seen) :stop-reason) '(end-turn error)))
        (funcall callback '(:type done :stop-reason end-turn))
        (should (= 1 (length seen)))))))

(ert-deftest harness-provider-chaos-non-object-arguments-never-execute-or-poison-history ()
  (dolist (input '(42 [] "not an object" (:broken)))
    (harness-provider-chaos-test-with
      (setq script (list (list :type 'tool-call :id "bad-args" :name "chaos_echo" :input input)))
      (harness-test-await (harness-call 'agent/prompt sid "bad tool arguments") 2)
      (should (zerop executions))
      (should (cl-find-if (lambda (node) (and (eq (plist-get node :kind) 'tool-result)
                                             (plist-get node :is-error)))
                          (harness-call 'session/nodes sid)))
      (should (eq 'end-turn (plist-get (harness-test-await
                                      (harness-call 'agent/prompt sid "try again") 2) :stop-reason))))))

(ert-deftest harness-provider-chaos-cancellation-can-be-retried-after-it-signals ()
  (harness-provider-chaos-test-with
    (setq hold-done t cancel-fails-once t)
    (let ((promise (harness-call 'agent/prompt sid "cancellation exception")))
      (harness-test-wait (lambda () (= 1 requests)))
      (let ((cancel (plist-get (harness-agent-turn-handle (harness-agent-turn-for sid)) :cancel)))
        (should-error (funcall cancel))
        (funcall cancel)
        (should (= 2 cancels))
        (funcall cancel)
        (should (= 2 cancels)))
      (funcall (car callbacks) '(:type done :stop-reason cancelled))
      (should (eq 'cancelled (plist-get (harness-test-await promise 2) :stop-reason))))))

(ert-deftest harness-provider-chaos-malformed-sse-recovers-through-next-prompt-and-cold-load ()
  (dolist (wire-data '("data: {\"error\":{\"message\":42}}\n\n"
                       "data: {\"choices\":42}\n\n"
                       "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":42}]}}]}\n\n"
                       "data: {bad json}\n\n"
                       "data: {\"id\":1,\"id\":2}\n\n"))
    (ert-info ((format "wire: %S" wire-data))
      (harness-provider-chaos-test-check nil wire-data))))

(provide 'harness-provider-chaos-test)
;;; harness-provider-chaos-test.el ends here
