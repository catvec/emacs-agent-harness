;;; harness-request-lifecycle.el --- Request completion and cancellation -*- lexical-binding: t; -*-

;;; Commentary:
;; Small, synchronous lifecycle mechanics shared by request boundaries.
;; No scheduler, retry policy, transport, session state or global registry.
;; Each owner has its own control.  Claiming finish fences reentry; delivery
;; is separate unconditional cleanup.  Cancellation remembers a late handle
;; and fences reentry without making a failed cancellation unrepeatable.

;;; Code:
(require 'cl-lib)

(cl-defstruct (harness-request-lifecycle
               (:constructor harness-request-lifecycle-create) (:copier nil))
  "Control belonging to one request, never reused for its replacement."
  phase cancel-function cancel-requested cancelling cancelled)

(defun harness-request-lifecycle-open-p (control)
  "Non-nil while CONTROL has not claimed terminal processing."
  (null (harness-request-lifecycle-phase control)))

(defun harness-request-lifecycle-finish (control deliver prepare fallback &optional on-error)
  "Finish CONTROL once, passing the prepared result to DELIVER.
PREPARE computes the terminal result after finish has been claimed.
FALLBACK is an already constructed result for interrupted preparation.
ON-ERROR, when supplied, converts a preparation error to a result.
Without it, the error propagates after FALLBACK is delivered.
Delivery is attempted once even when preparation or ON-ERROR signals.
A failure inside DELIVER propagates; it cannot reopen this request."
  (when (harness-request-lifecycle-open-p control)
    (setf (harness-request-lifecycle-phase control) 'finishing)
    (let ((result fallback))
      (unwind-protect
          (setq result
                (if on-error
                    (condition-case err (funcall prepare)
                      (error (funcall on-error err)))
                  (funcall prepare)))
        (setf (harness-request-lifecycle-phase control) 'finished)
        (funcall deliver result)))))

(defun harness-request-lifecycle-cancel (control)
  "Request cancellation of CONTROL's exact producer, including a late handle.
A successful cancellation is called once.  A function that signals may
be retried; synchronous recursive cancellation cannot call it twice.
This does not infer a terminal outcome or replay potentially executed work."
  (setf (harness-request-lifecycle-cancel-requested control) t)
  (when (and (harness-request-lifecycle-cancel-function control)
             (not (harness-request-lifecycle-cancelled control))
             (not (harness-request-lifecycle-cancelling control)))
    (setf (harness-request-lifecycle-cancelling control) t)
    (unwind-protect
        (prog1 (funcall (harness-request-lifecycle-cancel-function control))
          (setf (harness-request-lifecycle-cancelled control) t))
      (setf (harness-request-lifecycle-cancelling control) nil))))

(defun harness-request-lifecycle-set-cancel (control function)
  "Attach FUNCTION to CONTROL and honor an earlier cancellation request.
FUNCTION must cancel this request, not look up its session's current
producer.  A control cannot be reassigned to another producer."
  (unless (functionp function) (signal 'wrong-type-argument (list 'functionp function)))
  (when (and (harness-request-lifecycle-cancel-function control)
             (not (eq function (harness-request-lifecycle-cancel-function control))))
    (error "Request cancellation already belongs to another producer"))
  (setf (harness-request-lifecycle-cancel-function control) function)
  (when (harness-request-lifecycle-cancel-requested control)
    (harness-request-lifecycle-cancel control)))

(provide 'harness-request-lifecycle)
;;; harness-request-lifecycle.el ends here
