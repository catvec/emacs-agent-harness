;;; admission-demo.el --- Show one account's pools apart  -*- lexical-binding: t; -*-

;;; Commentary:

;; A small demonstration of what `harness-admission' keeps apart: two
;; upstream endpoints of one provider account, each with its own pool,
;; and an account-wide limit that holds both.  It runs in batch, prints
;; what `admission/state' says, and exits; it is a demonstration, not a
;; test, so nothing here asserts anything.
;;
;;   emacs -Q --batch -L lisp -L lisp/modules -L lisp/ui -L test \
;;     -l scripts/admission-demo.el

;;; Code:

(let ((root (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name)))))
  (dolist (dir '("lisp" "lisp/modules" "lisp/ui" "test"))
    (add-to-list 'load-path (expand-file-name dir root)))
  (require 'harness-test-helpers)
  (load (expand-file-name "lisp/modules/harness-admission.el" root) nil t))

(harness-test-with-temp-state
  (harness-test-reset-bus)
  (dolist (m '(store project config provider retry admission))
    (harness-test-load-module m))
  (harness-admission-reset)
  (let ((harness-admission t) (harness-admission-jitter 0))
    (unwind-protect
        (let ((limit (lambda (endpoint scope wait)
                       (harness-admission--rest
                        (harness-admission--pool-of (format "openrouter/%s" endpoint)
                                                    "openrouter")
                        (list :stop-reason 'error :error-kind 'rate-limit
                              :retry-after wait :limit-scope scope)))))
          (princ "== A limit DeepInfra answered: only its pool rests ==\n")
          (funcall limit "deepinfra/fp8" 'pool 9)
          (dolist (pool (harness-call 'admission/state))
            (princ (format "  %-26s account=%-11s %s\n"
                           (plist-get pool :key) (plist-get pool :account)
                           (let ((left (- (plist-get pool :until) (float-time))))
                             (if (> left 0)
                                 (format "resting %.0f s" left)
                               "open: sends at once")))))
          (princ "\n== Then OpenRouter itself limits the key: both rest ==\n")
          (funcall limit "cohere/fp8" 'account 4)
          (dolist (pool (harness-call 'admission/state))
            (princ (format "  %-26s account=%-11s %s\n"
                           (plist-get pool :key) (plist-get pool :account)
                           (let ((left (- (plist-get pool :until) (float-time))))
                             (if (> left 0)
                                 (format "resting %.0f s" left)
                               "open: sends at once"))))))
      (harness-admission-reset))))

;;; admission-demo.el ends here
