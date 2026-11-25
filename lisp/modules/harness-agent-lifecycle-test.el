;;; harness-agent-lifecycle-test.el --- Faults at turn boundaries -*- lexical-binding: t; -*-

(require 'harness-test-helpers)

(defmacro harness-agent-lifecycle-test-with (&rest body)
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo tools session agent))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-agent--turns)
     (let* ((default-directory dir)
            (harness-provider-demo--delay 0.001)
            (harness-provider-demo-script-override '((:type done :stop-reason end-turn)))
            (sid (plist-get (harness-call 'session/create :cwd dir :model "demo:scripted") :id)))
       ,@body)))

(defun harness-agent-lifecycle-test-turn (sid &optional handle)
  (let ((turn (make-harness-agent-turn :session-id sid :started (float-time)
                                       :promise (harness-make-promise) :handle handle)))
    (puthash sid turn harness-agent--turns)
    (harness-call 'session/set-status sid 'running)
    turn))

(ert-deftest harness-agent-lifecycle-request-build-failure-settles-turn ()
  (harness-agent-lifecycle-test-with
    (let (attempted promise)
      (cl-letf (((symbol-function 'harness-agent-step-request)
                 (lambda (&rest _) (setq attempted t) (error "request construction failed"))))
        (setq promise (harness-call 'agent/prompt sid "start"))
        (harness-test-wait (lambda () attempted))
        (should (harness-promise-settled-p promise))
        (should (eq 'error (plist-get (harness-test-await promise) :stop-reason)))
        (should-not (harness-agent-running-p sid)))
      ;; No manual repair is needed to send the next message.
      (should (eq 'end-turn (plist-get (harness-test-await
                                      (harness-call 'agent/prompt sid "try again")) :stop-reason))))))

(ert-deftest harness-agent-lifecycle-rejected-opening-gate-settles-turn ()
  (harness-agent-lifecycle-test-with
    (cl-letf (((symbol-function 'harness-run-filter-async)
               (lambda (&rest _) (harness-rejected '(error "gate failed")))))
      (let ((promise (harness-call 'agent/prompt sid "start")))
        (should (eq 'error (plist-get (harness-test-await promise 1) :stop-reason)))
        (should-not (harness-agent-running-p sid))))))

(ert-deftest harness-agent-lifecycle-rejected-step-gate-settles-turn ()
  (harness-agent-lifecycle-test-with
    (let ((turn (harness-agent-lifecycle-test-turn sid)))
      (cl-letf (((symbol-function 'harness-run-filter-async)
                 (lambda (&rest _) (harness-rejected '(error "step gate failed")))))
        (harness-agent--next-step turn)
        (should (eq 'error (plist-get (harness-test-await (harness-agent-turn-promise turn) 1)
                                     :stop-reason)))
        (should-not (harness-agent-running-p sid))))))

(ert-deftest harness-agent-lifecycle-bookkeeping-failure-still-announces-end ()
  (harness-agent-lifecycle-test-with
    (let ((turn (harness-agent-lifecycle-test-turn sid))
          (call (symbol-function 'harness-call)) ended)
      (harness-on 'agent/turn-ended (lambda (id reason) (push (list id reason) ended)))
      (cl-letf (((symbol-function 'harness-call)
                 (lambda (method &rest args)
                   (if (eq method 'session/usage-add)
                       (error "usage store unavailable")
                     (apply call method args)))))
        (harness-agent--end turn 'end-turn))
      (should (harness-promise-settled-p (harness-agent-turn-promise turn)))
      (should (equal (list (list sid 'end-turn)) ended))
      (should (eq 'idle (plist-get (harness-call 'session/get sid) :status)))
      (should-not (harness-agent-running-p sid)))))

(ert-deftest harness-agent-lifecycle-done-handler-failure-settles-turn ()
  (harness-agent-lifecycle-test-with
    (let* ((turn (harness-agent-lifecycle-test-turn sid))
           (callback (harness-provider--guard-events
                      (lambda (event) (harness-agent--on-event turn event)))))
      (cl-letf (((symbol-function 'harness-agent--receipt-answer)
                 (lambda (&rest _) (error "receipt unavailable"))))
        (funcall callback '(:type done :stop-reason end-turn)))
      (should (harness-promise-settled-p (harness-agent-turn-promise turn)))
      (should-not (harness-agent-running-p sid)))))

(ert-deftest harness-agent-lifecycle-old-step-gate-cannot-start-request ()
  (harness-agent-lifecycle-test-with
    (let ((old (harness-agent-lifecycle-test-turn sid))
          (gate (harness-make-promise)) (requests 0))
      (cl-letf (((symbol-function 'harness-run-filter-async) (lambda (&rest _) gate)))
        (harness-agent--next-step old))
      (harness-agent--end old 'cancelled)
      (let ((replacement (harness-agent-lifecycle-test-turn sid)))
        (cl-letf (((symbol-function 'harness-agent--step)
                   (lambda (_turn) (cl-incf requests))))
          (harness-resolve gate '(:proceed t))
          ;; This callback runs after the gate's existing continuation.
          (harness-test-await (harness-then gate (lambda (_) t))))
        (should (zerop requests))
        (should (eq replacement (harness-agent-turn-for sid)))
        (harness-agent--end replacement 'cancelled)))))

(ert-deftest harness-agent-lifecycle-terminal-fault-matrix ()
  "Every terminal bookkeeping boundary leaves an observable completed turn."
  (dolist (method '(session/exists-p session/usage-add session/runtime
                   session/pending-dismiss session/set-provider-node session/set-status))
    (ert-info ((format "terminal fault at %s" method))
      (harness-agent-lifecycle-test-with
        (let ((turn (harness-agent-lifecycle-test-turn sid))
              (call (symbol-function 'harness-call)) (ended 0))
          (harness-on 'agent/turn-ended (lambda (&rest _) (cl-incf ended)))
          (cl-letf (((symbol-function 'harness-call)
                     (lambda (name &rest args)
                       (if (eq name method) (error "injected terminal fault")
                         (apply call name args)))))
            (harness-agent--end turn 'cancelled))
          (should-not (harness-agent-running-p sid))
          (should (harness-promise-settled-p (harness-agent-turn-promise turn)))
          (should (= 1 ended)))))))

(ert-deftest harness-agent-lifecycle-terminal-event-reentry-is-idempotent ()
  (harness-agent-lifecycle-test-with
    (let ((turn (harness-agent-lifecycle-test-turn sid)) (ended 0))
      (puthash sid t harness-agent--step-open)
      (harness-on 'agent/step-ended (lambda (&rest _) (harness-agent--end turn 'cancelled)))
      (harness-on 'agent/turn-ended (lambda (&rest _) (cl-incf ended)))
      (harness-agent--end turn 'end-turn)
      (should (= 1 ended))
      (should (eq 'end-turn (plist-get (harness-test-await (harness-agent-turn-promise turn))
                                     :stop-reason))))))

(ert-deftest harness-agent-lifecycle-late-opening-gate-cannot-edit-new-transcript ()
  (harness-agent-lifecycle-test-with
    (let ((gate (harness-make-promise)) entered old-promise old-turn)
      (cl-letf (((symbol-function 'harness-run-filter-async)
                 (lambda (&rest _) (setq entered t) gate)))
        (setq old-promise (harness-call 'agent/prompt sid "older")
              old-turn (harness-agent-turn-for sid))
        (harness-test-wait (lambda () entered)))
      (harness-agent--end old-turn 'cancelled)
      (harness-test-await old-promise)
      (harness-test-await (harness-call 'agent/prompt sid "newer"))
      (let ((before (harness-call 'session/nodes sid)))
        (harness-resolve gate '(:proceed t))
        (harness-test-await (harness-then gate (lambda (_) t)))
        (should (equal before (harness-call 'session/nodes sid))))
      (should (equal '("older" "newer")
                     (mapcar (lambda (node) (plist-get node :content))
                             (cl-remove-if-not (lambda (node) (eq 'user (plist-get node :kind)))
                                               (harness-call 'session/nodes sid))))))))

(ert-deftest harness-agent-lifecycle-obsolete-head-follow-cannot-enter-gate ()
  (harness-agent-lifecycle-test-with
    (let ((follow (harness-make-promise)) (gates 0) old)
      (harness-add-filter 'agent/before-turn
                          (lambda (value next &rest _) (cl-incf gates) (funcall next value)))
      (cl-letf (((symbol-function 'harness-agent--follow-head) (lambda (_) follow)))
        (harness-call 'agent/prompt sid "older")
        (setq old (harness-agent-turn-for sid)))
      (harness-agent--end old 'cancelled)
      (harness-test-await (harness-call 'agent/prompt sid "newer"))
      (should (= 1 gates))
      (harness-resolve follow nil)
      (harness-test-await (harness-then follow (lambda (_) t)))
      (should (= 1 gates)))))

(ert-deftest harness-agent-lifecycle-synchronous-failure-cancels-returned-handle ()
  (harness-agent-lifecycle-test-with
    (let ((call (symbol-function 'harness-call)) (cancelled 0))
      (cl-letf (((symbol-function 'harness-call)
                 (lambda (name &rest args)
                   (pcase name
                     ('provider/complete
                      (funcall (plist-get (car args) :on-event) '(:type hint :text "trigger"))
                      (list :cancel (lambda () (cl-incf cancelled))))
                     ('session/hint (error "synchronous callback failed"))
                     (_ (apply call name args))))))
        (let ((promise (harness-call 'agent/prompt sid "start")))
          (should (eq 'error (plist-get (harness-test-await promise) :stop-reason)))
          (should (= 1 cancelled))
          (should-not (harness-agent-running-p sid)))))))

(ert-deftest harness-agent-lifecycle-log-observer-failure-cannot-strand-internal-error ()
  (harness-agent-lifecycle-test-with
    (let ((turn (harness-agent-lifecycle-test-turn sid))
          (call (symbol-function 'harness-call)) (ended 0))
      (harness-on 'agent/turn-ended (lambda (&rest _) (cl-incf ended)))
      (let ((harness-log-hook (list (lambda (&rest _) (error "log forwarding disconnected")))))
        (cl-letf (((symbol-function 'harness-call)
                   (lambda (method &rest args)
                     (if (eq method 'session/hint) (error "transcript write failed")
                       (apply call method args)))))
          (harness-agent--on-event turn '(:type hint :text "a valid event"))))
      (should (harness-promise-settled-p (harness-agent-turn-promise turn)))
      (should (eq 'error (plist-get (harness-test-await (harness-agent-turn-promise turn)) :stop-reason)))
      (should (= 1 ended))
      (should-not (harness-agent-running-p sid))
      (should (eq 'end-turn (plist-get (harness-test-await (harness-call 'agent/prompt sid "recover"))
                                      :stop-reason))))))

(ert-deftest harness-agent-lifecycle-log-observer-failure-cannot-disable-cancellation ()
  (harness-agent-lifecycle-test-with
    (let ((turn (harness-agent-lifecycle-test-turn sid (list :cancel #'ignore))) (ended 0))
      (harness-on 'agent/cancelling (lambda (&rest _) (error "cancellation observer failed")))
      (harness-on 'agent/turn-ended (lambda (&rest _) (cl-incf ended)))
      (let* ((harness-log-hook (list (lambda (&rest _) (error "log forwarding disconnected"))))
             (timer (harness-test-capture-timer harness-agent--cancel-grace
                                               (lambda () (harness-call 'agent/cancel sid)))))
        (unwind-protect (timer-event-handler timer)
          (cancel-timer timer)))
      (should (harness-promise-settled-p (harness-agent-turn-promise turn)))
      (should (eq 'cancelled (plist-get (harness-test-await (harness-agent-turn-promise turn)) :stop-reason)))
      (should (= 1 ended))
      (should-not (harness-agent-running-p sid))
      (should (eq 'end-turn (plist-get (harness-test-await (harness-call 'agent/prompt sid "recover"))
                                      :stop-reason))))))

(provide 'harness-agent-lifecycle-test)
;;; harness-agent-lifecycle-test.el ends here
