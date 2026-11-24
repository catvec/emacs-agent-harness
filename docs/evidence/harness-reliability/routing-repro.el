;;; routing-repro.el --- Historical completion failure reproduction -*- lexical-binding: t; -*-
(require 'harness-provider-openrouter-test-helpers)
(defun harness-openrouter-health-test--session (state &optional expires)
  "Session with proven STATE, full history and an expired cache by default."
  (let* ((model (concat "openrouter:" harness-openrouter-test-model))
         (session (harness-openrouter-test--session
                   "health-session"
                   (list :openrouter-route (harness-openrouter-test--route)
                         :openrouter-send (list :state state :at (- (float-time) 1000)
                                                :slug "deepinfra/fp8" :model model)))))
    (plist-put session :cache (list :expires (or expires (- (float-time) 100))
                                    :ttl 300 :model model))))


(ert-deftest harness-openrouter-health-terminal-write-failure-does-not-wedge-live-owner ()
  "A failed terminal save cannot hide done or strand this process's marker."
  (let* ((s (harness-openrouter-health-test--session "sent"))
         (req (plist-put (harness-openrouter-test--request s)
                         :openrouter-route (harness-openrouter--route-of s)))
         callback events token)
    (harness-openrouter-test-with-session s
      (cl-letf (((symbol-function 'harness-openai--complete)
                 (lambda (_endpoint request)
                   (setq callback (plist-get request :on-event))
                   (funcall (plist-get request :before-dispatch))
                   (list :cancel #'ignore))))
        (setq req (plist-put req :on-event (lambda (event) (push event events))))
        (harness-openrouter--tracked-complete req)
        (setq token (plist-get (harness-openrouter--send-evidence
                               harness-openrouter-test--session-value) :inflight))
        (let ((call (symbol-function 'harness-call)))
          (cl-letf (((symbol-function 'harness-call)
                     (lambda (method &rest args)
                       (if (and (eq method 'session/set-ext)
                                (eq (nth 1 args) harness-openrouter--send-key))
                           (error "terminal save failed")
                         (apply call method args)))))
            (funcall callback '(:type done :stop-reason end-turn))))
        (should (eq 'done (plist-get (car events) :type)))
        (should (equal token (plist-get (harness-openrouter--send-evidence
                                        harness-openrouter-test--session-value) :inflight)))
        ;; The owner is still alive.  The terminal callback proves that
        ;; this exact request ended, so a same-pin send can recover it.
        (harness-openrouter--tracked-complete req)
        (let ((e (harness-openrouter--send-evidence harness-openrouter-test--session-value)))
          (should-not (equal token (plist-get e :inflight)))
          (should (plist-get e :partial))
          (should (equal "request-ended" (plist-get (car (last (plist-get e :recoveries))) :reason))))
        (funcall callback '(:type done :stop-reason end-turn))))))

(ert-run-tests-batch-and-exit "terminal-write-failure")
