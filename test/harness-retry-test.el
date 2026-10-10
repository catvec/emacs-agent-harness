;;; harness-retry-test.el --- Tests for retrying transiently failed steps  -*- lexical-binding: t; -*-

;;; Commentary:

;; The module answers `agent/step-error' for a failure a connection or a
;; rate limit caused, so the step runs again on the same provider after a
;; wait, and the agent drops the partial answer the failed step streamed
;; (`harness-agent--rewind-step').  One test runs the real OpenAI provider
;; against a server in this Emacs that resets a stream in the middle and
;; then answers, the way a proxy dropped the connection in the field.

;;; Code:

(require 'harness-test-helpers)

(defvar harness-retry-test-requests nil
  "The requests the scripted provider was sent, oldest first.")

(defmacro harness-retry-test-with (&rest body)
  "Load the state layer with a scripted provider, the retry module, and run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider tools session agent retry))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-retry--attempts)
     (let ((default-directory dir)
           (harness-retry-delay 0.01)
           (harness-retry-jitter 0))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       ,@body)))

(defun harness-retry-test-define-provider (script)
  "Define provider `scripted-retry' whose completion SCRIPT answers each step.
SCRIPT is called with the number of the step (1 the first) and returns
the events to send, as a list of plists, the last of them a `done'."
  (setq harness-retry-test-requests nil)
  (harness-define-provider 'scripted-retry
    :label "Scripted retry"
    :complete
    (lambda (request)
      (let ((on-event (or (plist-get request :on-event) #'ignore))
            (step (1+ (length harness-retry-test-requests)))
            (cancelled nil))
        (push request harness-retry-test-requests)
        (harness-run-soon
         (lambda ()
           (unless cancelled
             (funcall on-event '(:type start))
             (dolist (ev (funcall script step))
               (funcall on-event ev)))))
        (list :cancel (lambda ()
                        (setq cancelled t)
                        (funcall on-event '(:type done :stop-reason cancelled))))))))

(defun harness-retry-test-session ()
  "Make a session on the scripted provider."
  (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "scripted-retry:m") :id))

(defun harness-retry-test-nodes (id &optional kind)
  "Return the transcript nodes of session ID, of KIND when given."
  (let ((nodes (harness-call 'session/nodes id)))
    (if kind (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) kind)) nodes) nodes)))

(defun harness-retry-test-hints (id)
  "Return the hint texts of session ID, oldest first."
  (mapcar (lambda (n) (plist-get n :content)) (harness-retry-test-nodes id 'hint)))

(ert-deftest harness-retry-tries-a-transport-failure-again ()
  "A step whose stream was cut is run again, and its partial answer dropped.
The retry must not leave the half answer the failed step streamed in
the transcript, where the model would read it as its own words twice."
  (harness-retry-test-with
    (harness-retry-test-define-provider
     (lambda (step)
       (if (= step 1)
           '((:type thinking :delta "thinking out loud")
             (:type text :delta "half an answer")
             (:type done :stop-reason error
                    :error "the connection was reset by the peer" :error-kind transport))
         '((:type text :delta "the whole answer")
           (:type done :stop-reason end-turn)))))
    (let ((id (harness-retry-test-session)))
      (should (eq 'end-turn (plist-get (harness-await (harness-call 'agent/prompt id "go")) :stop-reason)))
      (should (= 2 (length harness-retry-test-requests)))
      ;; Only the retried answer remains: no partial text, no partial thinking.
      (should (equal '("the whole answer")
                     (mapcar (lambda (n) (plist-get n :content))
                             (harness-retry-test-nodes id 'assistant))))
      (should-not (harness-retry-test-nodes id 'thinking))
      (should (cl-some (lambda (h) (string-match-p "trying again" h)) (harness-retry-test-hints id))))))

(ert-deftest harness-retry-gives-up-after-its-cap ()
  "A provider that stays down ends the turn, with the tries bounded and said."
  (harness-retry-test-with
    (let ((harness-retry-max-attempts 2))
      (harness-retry-test-define-provider
       (lambda (_step)
         '((:type text :delta "a last attempt")
           (:type done :stop-reason error
                  :error "the connection was reset by the peer" :error-kind transport))))
      (let ((id (harness-retry-test-session)))
        (should (eq 'error (plist-get (harness-await (harness-call 'agent/prompt id "go")) :stop-reason)))
        ;; The first attempt and two retries, and no more.
        (should (= 3 (length harness-retry-test-requests)))
        (should (cl-some (lambda (h) (string-match-p "giving up after 2 tries" h))
                         (harness-retry-test-hints id)))
        ;; Nothing was tried after that: the turn is over.
        (should (equal '("a last attempt")
                       (mapcar (lambda (n) (plist-get n :content))
                               (harness-retry-test-nodes id 'assistant))))))))

(ert-deftest harness-retry-leaves-quota-and-billing-to-the-fallback ()
  "A failure another handler's business ends the turn here, not another step."
  (harness-retry-test-with
    (harness-retry-test-define-provider
     (lambda (_step)
       '((:type done :stop-reason error
              :error "You've hit your limit · resets 3pm" :error-kind quota))))
    (let ((id (harness-retry-test-session)))
      (should (eq 'error (plist-get (harness-await (harness-call 'agent/prompt id "go")) :stop-reason)))
      (should (= 1 (length harness-retry-test-requests))))))

(ert-deftest harness-retry-reads-a-transport-failure-from-its-text ()
  "A provider that names no kind still gets a retry when the words say so."
  (harness-retry-test-with
    (harness-retry-test-define-provider
     (lambda (step)
       (if (= step 1)
           '((:type done :stop-reason error
                  :error "curl exited 56 (exited abnormally with code 56): Recv failure: Connection reset by peer"))
         '((:type text :delta "back") (:type done :stop-reason end-turn)))))
    (let ((id (harness-retry-test-session)))
      (should (eq 'end-turn (plist-get (harness-await (harness-call 'agent/prompt id "go")) :stop-reason)))
      (should (= 2 (length harness-retry-test-requests))))))

(ert-deftest harness-retry-honours-retry-after ()
  "A rate limit that asked for a wait is waited for, its delay capped."
  (should (= 3 (let ((harness-retry-delay 0.5) (harness-retry-jitter 0))
                 (harness-retry--delay 1 '(:retry-after 3)))))
  (should (= 30.0 (let ((harness-retry-delay 1) (harness-retry-jitter 0)
                        (harness-retry-max-delay 30.0))
                    (harness-retry--delay 1 '(:retry-after 600)))))
  ;; Never sooner than the backoff: a server's wait is a minimum.
  (should (= 10.0 (let ((harness-retry-delay 10) (harness-retry-jitter 0))
                    (harness-retry--delay 1 '(:retry-after 3)))))
  (should (= 4.0 (let ((harness-retry-delay 1) (harness-retry-jitter 0))
                   (harness-retry--delay 3 '(:retry-after nil))))) ; 1, 2, 4
  (harness-retry-test-with
    (let ((harness-retry-delay 0.05))
      (harness-retry-test-define-provider
       (lambda (step)
         (if (= step 1)
             '((:type done :stop-reason error :error "Rate limit exceeded"
                    :error-kind rate-limit :retry-after 0.01))
           '((:type text :delta "after the wait") (:type done :stop-reason end-turn)))))
      (let ((id (harness-retry-test-session)))
        (should (eq 'end-turn (plist-get (harness-await (harness-call 'agent/prompt id "go")) :stop-reason)))
        (should (= 2 (length harness-retry-test-requests)))
        (should (cl-some (lambda (h) (string-match-p "rate limited" h)) (harness-retry-test-hints id)))))))

(ert-deftest harness-retry-does-not-retry-a-cancelled-turn ()
  "A turn cancelled while it waits to try again tries nothing."
  (harness-retry-test-with
    (let ((harness-retry-delay 0.3))
      (harness-retry-test-define-provider
       (lambda (_step)
         '((:type text :delta "cut off")
           (:type done :stop-reason error
                  :error "the connection was reset by the peer" :error-kind transport))))
      (let* ((id (harness-retry-test-session))
             (turn (harness-call 'agent/prompt id "go")))
        (harness-test-wait (lambda () (= 1 (length harness-retry-test-requests))) 5 "the first step")
        (harness-call 'agent/cancel id)
        (should (eq 'cancelled (plist-get (harness-await turn) :stop-reason)))
        (accept-process-output nil 0.5)      ; well past the retry delay
        (should (= 1 (length harness-retry-test-requests)))))))

;;;; A real provider against a server that drops the stream

(ert-deftest harness-retry-drops-a-stream-cut-in-the-middle ()
  "The OpenAI provider's stream reset mid-answer is retried, without the partial text.
This is the failure the field reported: a session on a DeepSeek model,
a connection reset, and a turn that ended with curl's exit code."
  (skip-unless (executable-find "curl"))
  (harness-retry-test-with
    (let* ((partial (concat "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hel\"}}]}\n\n"
                            "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"lo the\"}}]}\n\n"))
           (full (concat "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hello there\"}}]}\n\n"
                         "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
                         "data: [DONE]\n\n"))
           (server (harness-test-http-serve
                    `(("/chat/completions" .
                       ,(lambda (attempt)
                          (if (= attempt 1)
                              (list 200 '(("Content-Type" . "text/event-stream"))
                                    partial :chunks 4 :reset-after 1)
                            (list 200 '(("Content-Type" . "text/event-stream")) full)))))))
           (endpoint (list :id 'testlocal :label "Local test server"
                           :base-url (harness-test-http-url server "") :api-key "sk-test")))
      (unwind-protect
          (progn
            (harness-test-load-module 'provider-openai)
            (harness-openai-register-endpoint endpoint)
            (let* ((session (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                                     :model "testlocal:local-model")
                                       :id)))
              (harness-await (harness-call 'agent/prompt session "hi"))
              (should (equal '("Hello there")
                             (mapcar (lambda (n) (plist-get n :content))
                                     (harness-retry-test-nodes session 'assistant))))
              (should (cl-some (lambda (h) (string-match-p "trying again" h))
                               (harness-retry-test-hints session)))))
        (delete-process server)))))

(provide 'harness-retry-test)
;;; harness-retry-test.el ends here
