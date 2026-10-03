;;; harness-tools-client-timeout-test.el --- A UI that never answers  -*- lexical-binding: t -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; In its own file so the Emacs the suite starts for it has no other
;; client connected: `client/request' takes the first answer, and a
;; leftover client from another test would answer before the deadline.

;;; Code:

(require 'harness-test-helpers)

(defun harness-tools-client-timeout-test--allow (_decision next &rest _)
  "Permissive permission filter for the test."
  (funcall next (list :behavior 'allow)))

(ert-deftest harness-tools-client-timeout-fails-an-unresponsive-ui ()
  "A client tool call fails when the UI does not answer.
A UI blocked in a subprocess call used to leave the call, and the turn
it belongs to, pending forever."
  (harness-test-load-module 'tools)
  (harness-test-load-module 'tools-emacs)
  ;; The module starts the ACP server when this is t; set it before the
  ;; load, not in a `let': the module's own `defvar' is evaluated while
  ;; byte-compiling, where a lexical binding would be an error.
  (setq harness-acp--server-enabled nil)
  (harness-test-load-module 'acp)
  (harness-add-filter 'permission/decide #'harness-tools-client-timeout-test--allow 10)
  (let ((conn (harness-acp-connect nil)))
    ;; A UI that receives the request and never answers.
    (harness-acp-set-handler conn (lambda (&rest _) nil))
    (unwind-protect
        (let ((harness-tools--client-timeout 0.3)
              ;; Keep the desktop notice out of the test.
              (harness-tools--ui-notice-at (float-time)))
          (let ((r (harness-await (harness-call 'tools/execute nil
                                                (list :id "c1" :name "emacs_buffers" :input nil))
                                  5)))
            (should (plist-get r :is-error))
            (should (string-search "did not answer" (plist-get r :content)))))
      (harness-acp-close conn))))

(provide 'harness-tools-client-timeout-test)
;;; harness-tools-client-timeout-test.el ends here
