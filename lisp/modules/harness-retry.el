;;; harness-retry.el --- Try a failed step again when the network hiccuped  -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; A model call that fails because a connection was reset, a gateway
;; answered 502, or the provider asked the caller to slow down (HTTP 429
;; with a Retry-After) is worth trying again: the next try often answers.
;; The HTTP layer already retries a request whose failure nothing reached
;; the caller from (`harness-http-request'), so what arrives here is a
;; failure that got further: a stream cut in the middle of the answer, or
;; a transport failure that outlived those tries.
;;
;; A step is a safe unit to repeat, because the agent drops the partial
;; answer a failed step had already streamed before it runs the step
;; again (`harness-agent--rewind-step'): neither the transcript nor the
;; model is sent the same tokens twice.  What a step's tools already did
;; stays, and the model goes on from there.
;;
;; Quota and billing failures belong to the fallback module, which moves
;; the session to another provider; this module never answers for them
;; and never overrides an answer the filters before it gave.  A retry is
;; bounded per turn (`harness-retry-max-attempts') and waits longer each
;; time, so a provider that is really down ends the turn rather than
;; keeping it busy.
;;
;; A provider that knows names its failure's kind in `:error-kind'
;; (`transport' or `rate-limit', see `harness-provider-openai'); a
;; transport failure that arrives as text alone (a CLI provider's, say)
;; is read the same way by `harness-retry--kind'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)

(defcustom harness-retry-max-attempts 3
  "Most times one turn tries a transiently failed step again.
Counted per turn, so a turn that keeps failing ends however many steps
it ran.  Nil or 0 never tries again."
  :type 'integer :group 'harness)

(defcustom harness-retry-delay 1.0
  "Seconds to wait before trying a failed step again.
Each further retry waits twice as long, up to
`harness-retry-max-delay'."
  :type 'number :group 'harness)

(defcustom harness-retry-max-delay 30.0
  "Longest a step is waited for before it is tried again, in seconds.
It caps both the growing backoff and a provider's Retry-After: waiting
longer than this inside a turn is worse than ending it and leaving the
next message to try."
  :type 'number :group 'harness)

(defcustom harness-retry-jitter 0.2
  "Fraction of the backoff a retry may be spread by, for randomness.
Several sessions failing together (a provider that went down, say) then
do not all try again in the same instant.  Nil or 0 waits the backoff
exactly."
  :type 'number :group 'harness)

(defconst harness-retry--transport-patterns
  (concat "connection reset\\|recv failure\\|send failure\\|empty reply\\|broken pipe"
          "\\|connection refused\\|could not connect\\|connection timed out\\|timed out"
          "\\|could not resolve\\|name or service not known\\|temporary failure in name resolution"
          "\\|ssl connect error\\|tls\\|eof occurred\\|network is unreachable\\|transport"
          "\\|no response headers")
  "Regexps that say a failure was the transport's, not the request's.")

(defconst harness-retry--rate-limit-patterns
  "rate[ _-]limit\\|too many requests\\|slow down\\|retry after"
  "Regexps that say a provider asked the caller to slow down.")

(defvar harness-retry--attempts (make-hash-table :test 'equal)
  "Session id -> how many times its running turn tried a step again.
Reset when a turn starts and when it ends.")

(defun harness-retry--transient-text-p (text)
  "Non-nil when TEXT says the failure was a transient one.
TEXT is read in lower case; a failure a provider named with
`:error-kind' never needs this."
  (and (stringp text)
       (let ((text (downcase text)))
         (or (string-match-p harness-retry--transport-patterns text)
             (string-match-p harness-retry--rate-limit-patterns text)))))

(defun harness-retry--kind (failure)
  "Return the kind of FAILURE worth trying again, or nil.
FAILURE is what `agent/step-error' passes.  A kind a provider named is
used as it is: `transport' and `rate-limit' are this module's, anything
else (a quota, a refused login) is another module's.  Without a kind,
the error's text is read for a connection that failed or a limit that
was hit."
  (let ((kind (let ((k (plist-get failure :error-kind)))
                (and k (intern (format "%s" k)))))
        (text (plist-get failure :error)))
    (cond ((memq kind '(transport rate-limit)) kind)
          (kind nil)
          ((and (stringp text) (string-match-p harness-retry--rate-limit-patterns (downcase text)))
           'rate-limit)
          ((harness-retry--transient-text-p text) 'transport))))

(defun harness-retry--delay (attempt failure)
  "Seconds to wait before the ATTEMPT-th try of FAILURE's step.
A provider that asked to slow down (Retry-After, in the failure's
`:retry-after') is waited for first, capped at `harness-retry-max-delay';
otherwise the wait doubles per try, spread by `harness-retry-jitter'."
  (let* ((base (* harness-retry-delay (expt 2 (1- (max 1 attempt)))))
         (jitter (* base (or harness-retry-jitter 0) (/ (random 1000) 1000.0)))
         (asked (plist-get failure :retry-after)))
    (min harness-retry-max-delay
         (max (if (numberp asked) (max 0.0 asked) 0.0)
              (+ base jitter)))))

(defun harness-retry--wait (seconds)
  "Return a promise that settles after SECONDS."
  (harness-with-promise (resolve reject)
    (run-at-time seconds nil (lambda () (funcall resolve t)))))

(defun harness-retry--say (kind failure)
  "Return what a hint says about FAILURE of KIND."
  (format "%s: %s"
          (if (eq kind 'rate-limit) "rate limited" "network error")
          (harness-error-short-message (or (plist-get failure :error) "unknown"))))

(defun harness-retry--step-error (value next session failure)
  "`agent/step-error' handler: try a transiently failed step again.
VALUE and NEXT are the filter's, SESSION the session as it failed.
When no filter before this answered, a failure of KIND `transport' or
`rate-limit' has the step run again after a wait, at most
`harness-retry-max-attempts' times a turn.  Each wait is announced as a
hint, and so is giving up, so a turn that ends says what it tried.  A
failure another handler already answered (the fallback, having moved
the session on) is left alone."
  (let ((decision value))
    (unless (plist-get value :retry)
      (condition-case err
          (when-let* ((kind (harness-retry--kind failure)))
            (let* ((sid (plist-get session :id))
                   (attempt (1+ (gethash sid harness-retry--attempts 0)))
                   (most (or harness-retry-max-attempts 0)))
              (if (> attempt most)
                  (harness-call 'session/hint
                                sid (format "%s; giving up after %d %s"
                                            (harness-retry--say kind failure) most
                                            (if (= most 1) "try" "tries")))
                (let ((delay (harness-retry--delay attempt failure)))
                  (puthash sid attempt harness-retry--attempts)
                  (harness-call 'session/hint
                                sid (format "%s; trying again in %s (%d of %d)"
                                            (harness-retry--say kind failure)
                                            (harness-retry--duration delay) attempt most))
                  (setq decision (list :retry t :reason "a transient failure"
                                       :delay delay))))))
        (error (harness-log 'warn "retry: after the failure of %s: %S"
                            (plist-get session :id) err))))
    (if-let* ((delay (plist-get decision :delay)))
        (harness-then (harness-retry--wait delay) (lambda (_) (funcall next decision)))
      (funcall next decision)))
  nil)

(defun harness-retry--duration (seconds)
  "Return SECONDS as a short span, for a hint."
  (if (< seconds 1)
      (format "%.1f s" seconds)
    (format "%d s" (round seconds))))

(defun harness-retry--forget (session-id &rest _)
  "Forget how many times SESSION-ID's turn tried a step again."
  (remhash session-id harness-retry--attempts))

;;;; Module

(defun harness-retry--init ()
  "Count retries per turn and hook into the turn's failures."
  (harness-on 'agent/turn-started #'harness-retry--forget)
  (harness-on 'agent/turn-ended #'harness-retry--forget)
  (harness-add-filter 'agent/step-error #'harness-retry--step-error 60))

(defun harness-retry--shutdown ()
  "Forget what the retries counted."
  (harness-off (cons 'agent/turn-started #'harness-retry--forget))
  (harness-off (cons 'agent/turn-ended #'harness-retry--forget))
  (harness-remove-filter 'agent/step-error #'harness-retry--step-error)
  (clrhash harness-retry--attempts))

(harness-define-module 'retry
  :doc "Try a step again after a transient network or rate-limit failure."
  :requires '(session agent)
  :init #'harness-retry--init
  :shutdown #'harness-retry--shutdown)

(provide 'harness-retry)
;;; harness-retry.el ends here
