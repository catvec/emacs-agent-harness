;;; demo.el --- What an unreadable OpenRouter catalogue is reported as  -*- lexical-binding: t; -*-

;;; Commentary:

;; The reported failure:
;;
;;   OpenRouter routing paused: the endpoint catalogue could not be read:
;;   Invalid error symbol: http-error
;;
;; A transient failure of OpenRouter's endpoint catalogue -- a 503, a
;; rate limit, a connection reset -- was reported as a bug in the
;; harness, and the status and the provider's own message were lost.
;;
;; The cause is a shape mismatch.  `harness-http-request-json' rejects
;; with a tagged tuple, (http-error STATUS BODY), which is *not* a
;; defined error type: it is a data list.  Passing such a rejection on
;; by signalling its car -- (signal (car err) (cdr err)) -- asks Emacs to
;; signal `http-error', which no `define-error' declared, so Emacs raises
;; (error "Invalid error symbol" http-error) instead and the real failure
;; is gone.
;;
;; This demo runs both: what the old pass-on reported, and what the fix
;; reports.  It needs no network, no credential and no harness: the
;; catalogue fetch is a canned rejection and nothing is dispatched.
;;
;;   demo/openrouter-catalogue-failure/demo.sh
;;
;; The same output is in demo/openrouter-catalogue-failure/expected.txt,
;; and repro-before.log holds the failing run of the regression test
;; against the old behaviour.

;;; Code:

(require 'harness-util)
(require 'harness-http)
(require 'harness-core)

(defconst demo--cases
  '((503 . "{\"error\":{\"message\":\"upstream unavailable\"}}")
    (429 . "{\"error\":{\"message\":\"rate limited, retry in 20s\"}}")
    (502 . "Bad Gateway"))
  "The catalogue failures the demo reports, as (STATUS . BODY).")

(defun demo--old (err)
  "Return what the pre-fix code reported for ERR, the fetch's rejection.
It signalled the rejection's car, which is no defined error symbol."
  (condition-case old-err
      (progn (signal (car err) (cdr err)) "nothing signalled")
    (error (format "OpenRouter routing paused: the endpoint catalogue could not be read: %s"
                   (harness-error-message old-err)))))

(defun demo--new (err)
  "Return what the fix reports for ERR, the fetch's rejection."
  (format "OpenRouter routing paused: the endpoint catalogue could not be read: %s"
          (harness-error-message err)))

(defun demo--case (status body)
  "Print what one catalogue failure, STATUS and BODY, was and is reported as."
  (let ((err (list 'http-error status body)))
    (princ (format "  HTTP %s %s\n" status body))
    (princ (format "    before: %s\n" (demo--old err)))
    (princ (format "    after:  %s\n\n" (demo--new err)))))

(defun demo--transport ()
  "Print the two ways a request fails before any response arrives."
  (dolist (err (list (list 'http-error nil (list 'curl "Connection reset by peer" :code 56))
                     (list 'http-error nil (list 'curl "Operation timed out" :code 28))))
    (princ (format "  %s\n" (nth 2 err)))
    (princ (format "    before: %s\n" (demo--old err)))
    (princ (format "    after:  %s\n\n" (demo--new err)))))

(defun demo--resignal ()
  "Print what passing a rejection on does, before and after."
  (princ "Passing the fetch's rejection on\n")
  (dolist (err (list (list 'http-error 503 "unavailable")
                     (list 'harness-no-such-method "x")))
    (let ((old (condition-case e (progn (signal (car err) (cdr err)) "nothing")
                 (error (format "%S" e))))
          (new (condition-case e (progn (harness-resignal err) "nothing")
                 (error (format "%S" e)))))
      (princ (format "  %S\n    before: %s\n    after:  %s\n" err old new))))
  (princ "\n"))

(defun demo-run ()
  "Print the reported failure before the fix and what is reported now."
  (princ "\nA catalogue the server refused\n\n")
  (dolist (case demo--cases)
    (demo--case (car case) (cdr case)))
  (princ "A request that never reached the server\n\n")
  (demo--transport)
  (demo--resignal)
  (princ "Neither message names an error symbol, and both keep the reason the session stopped.\n\n"))

(provide 'demo)
;;; demo.el ends here
