;;; harness-tools-emacs-timeout-test.el --- A user's Emacs that never answers  -*- lexical-binding: t -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; In its own file so the Emacs the suite starts for it has no other
;; client connected: `emacs/request' asks the most recently active Emacs
;; lent to the harness, and a leftover client from another test could be
;; that one and answer before the deadline.

;;; Code:

(require 'harness-test-helpers)

(defun harness-tools-emacs-timeout-test--allow (_decision next &rest _)
  "Permissive permission filter for the test."
  (funcall next (list :behavior 'allow)))

(ert-deftest harness-tools-emacs-timeout-fails-an-unresponsive-emacs ()
  "A tool about the user's Emacs fails when that Emacs does not answer.
An Emacs blocked in a subprocess call used to leave the call, and the
turn it belongs to, pending forever."
  (harness-test-load-module 'tools)
  (harness-test-load-module 'tools-emacs)
  ;; The module starts the ACP server when this is t; set it before the
  ;; load, not in a `let': the module's own `defvar' is evaluated while
  ;; byte-compiling, where a lexical binding would be an error.
  (setq harness-acp--server-enabled nil)
  (harness-test-load-module 'acp)
  (require 'harness-emacs-endpoint)
  (harness-add-filter 'permission/decide #'harness-tools-emacs-timeout-test--allow 10)
  (let ((conn (harness-acp-connect nil)))
    (harness-test-await (harness-acp-initialize conn (harness-emacs-endpoint-client-capabilities)))
    ;; An Emacs that lent itself, receives the request and never answers.
    (harness-acp-set-handler conn (lambda (&rest _) nil))
    (unwind-protect
        (let ((harness-tools--emacs-timeout 0.3)
              ;; Keep the desktop notice out of the test.
              (harness-tools--ui-notice-at (float-time)))
          (let ((r (harness-await (harness-call 'tools/execute nil
                                                (list :id "c1" :name "emacs_buffers" :input nil))
                                  5)))
            (should (plist-get r :is-error))
            (should (string-search "The user's Emacs did not answer within 0.3s" (plist-get r :content)))))
      (harness-acp-close conn))))

(provide 'harness-tools-emacs-timeout-test)
;;; harness-tools-emacs-timeout-test.el ends here
