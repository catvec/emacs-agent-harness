;;; harness-small.el --- One-off model calls the harness makes on its own  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness.

;;; Commentary:

;; The harness makes model calls of its own beside any conversation: a
;; session's name, the permission judge and the summary of a prompt, the
;; session judge, a recap, a compaction's summary, the Insights summary,
;; the companion pet, the task board's search, the todo sync's question.
;; Each is a request of its own -- `:ephemeral', without thinking or
;; tools, under an id that no turn and no session's conversation ever
;; sees -- and each goes through `harness-small-ask' here instead of
;; calling `provider/complete' itself, so that one place decides how such
;; a call is made and how it survives a provider that is having a bad
;; minute.
;;
;; Why.  A provider under load -- DeepSeek answering 429, say -- fails a
;; small call as readily as it fails a step of a turn, but nothing tried
;; such a call again.  A turn recovers on its own: its failure reaches
;; `agent/step-error', where `harness-retry' runs the step again and
;; `harness-fallback' moves a session off a provider that ran out.  The
;; name of a session, the verdict of the permission judge, a recap or a
;; summary had no such layer, so a 429 left a session "unnamed" or put a
;; prompt nobody could judge to the user.  `harness-small-ask' gives
;; those calls the treatment a step gets, from the same code: what kind
;; of failure it was and how long to wait before trying again are
;; `harness-retry''s (`harness-retry-kind', `harness-retry-backoff' and
;; the options behind them, `harness-retry-max-attempts' among them), so
;; a rate limit waits the Retry-After it asked for and a connection cut
;; is tried again after a growing, jittered backoff.
;;
;; A small call holds no provider state of its own and no conversation,
;; so a try that failed left nothing behind that a second try could send
;; twice.  What the caller gathered from the failed try -- the
;; half-written title, verdict or summary -- is forgotten when the call
;; is tried again: the caller is sent `harness-small-restart-event' and
;; clears what it kept, so a partial answer is never read as the whole
;; one.  A failure no retry would get past (a refused login, an account
;; out of quota, a request the harness malformed) reaches the caller as
;; the call's end, as it always did, and a caller that has waited long
;; enough cancels through the handle `harness-small-ask' returns.
;;
;; This module keeps no state and starts nothing.  Its callers `require'
;; it and do not list `small' among their modules' requirements, so that
;; each of them loads on its own, as they do with `judge'
;; (lisp/modules/harness-judge.el).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
;; The failure kinds and the wait behind them are the step retry's, so
;; that a small call and a step of a turn are tried again alike.
(require 'harness-retry)

(defconst harness-small-restart-event '(:type restart)
  "The event a caller of `harness-small-ask' gets when a try is thrown away.
It says the half answer the try that failed had streamed is to be
forgotten: the request is being sent again.")

(defun harness-small-retryable-p (failure)
  "Non-nil when FAILURE, the `done' of a failed try, is worth trying again.
That is what `harness-retry-kind' says of it: a connection cut, a rate
limit or a provider process that died.  A failure another layer answers
for (a refusal, a login, an account out of quota) is not.  FAILURE is
the `done' event's keys."
  (and (eq (plist-get failure :type) 'done)
       (harness-retry-kind failure)))

(defun harness-small-ask (request &optional opts)
  "Send REQUEST as one of the harness's own small model calls; return a handle.
REQUEST is a `provider/complete' request without `:on-event': this
function adds its own and hands every event to OPTS' `:on-event', a
function of one event that defaults to ignoring them.  A caller keeps
the request's own keys -- `:ephemeral', `:job', `:system', `:messages',
`:max-tokens' and the rest; nothing here changes them.

A failure a retry may get past (see `harness-small-retryable-p') is not
the call's end: the caller is sent `harness-small-restart-event' to
forget what the failed try had gathered, the wait `harness-retry-backoff'
asks for is taken (a rate limit's Retry-After honoured, else a growing,
jittered backoff), and the request is sent again, at most
`harness-retry-max-attempts' times.  The `done' of the last try, whatever
it says, is the one the caller reads.  A request that raises instead of
failing is handed over as a `done' with `:stop-reason' error, so a caller
handles it the one way.

OPTS also take `:label', a few words naming the call in the log (\"small
call\" by default); `:retries', how many times the call may be tried again
after the first (`harness-retry-max-attempts' by default, 0 for a caller
that does its own trying); and `:on-event' as above.  Return a handle
plist with `:cancel', a function that stops the call and any wait for a
retry."
  (let* ((on-event (or (plist-get opts :on-event) #'ignore))
         (label (or (plist-get opts :label) "small call"))
         (most (if (plist-member opts :retries)
                   (max 0 (or (plist-get opts :retries) 0))
                 (max 0 (or harness-retry-max-attempts 0))))
         (body (harness-plist-remove request :on-event))
         (tries 0) (handle nil) (timer nil) (cancelled nil))
    (cl-labels
        ((start ()
           ;; Send the request, TRY counting the tries from 1.
           (let ((serial (cl-incf tries)))
             (condition-case err
                 (setq handle
                       (harness-call 'provider/complete
                                     (append body
                                             (list :on-event
                                                   (lambda (ev) (receive ev serial))))))
               (error (funcall on-event (list :type 'done :stop-reason 'error
                                              :error (harness-error-message err)))))))
         (receive (ev serial)
           ;; Only the try in flight speaks, and a `done' is its last word.
           (when (and (not cancelled) (= serial tries))
             (if (and (eq (plist-get ev :type) 'done) (< tries most) (harness-small-retryable-p ev))
                 ;; A failure worth another try: the half answer is
                 ;; forgotten, the wait the failure asks for is taken, and
                 ;; the request is sent again.
                 (let* ((kind (harness-retry-kind ev))
                        (delay (harness-retry-backoff tries ev)))
                   (funcall on-event harness-small-restart-event)
                   (harness-log 'info "small: %s: %s; trying again in %s (%d of %d)"
                                label (harness-retry-say kind ev)
                                (harness-retry-duration delay) tries most)
                   (setq timer (run-at-time delay nil (lambda () (setq timer nil) (start)))))
               (funcall on-event ev))))
         (cancel ()
           (setq cancelled t)
           (when timer (cancel-timer timer) (setq timer nil))
           (when (and handle (functionp (plist-get handle :cancel)))
             (ignore-errors (funcall (plist-get handle :cancel))))))
      (start)
      (list :cancel #'cancel))))

(harness-define-module 'small
  :doc "One-off model calls the harness makes on its own, tried again like a step of a turn when they fail transiently.")

(provide 'harness-small)
;;; harness-small.el ends here
