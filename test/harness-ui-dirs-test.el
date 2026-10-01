;;; harness-ui-dirs-test.el --- Tests for the directory access buffer  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)

(defmacro harness-ui-dirs-test-with (&rest body)
  "Load the state layer, perms, ACP, the UI and the directory buffer, run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp-server-enabled nil))
       (dolist (m '(store project config provider tools perms session acp ui ui-dirs))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-perms--allowed-dirs)
     (clrhash harness-ui--sessions)
     (let* ((harness-acp-token nil)
            (default-directory dir)
            (sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id)))
       (unwind-protect
           (progn ,@body)
         (dolist (b (buffer-list))
           (when (with-current-buffer b (derived-mode-p 'harness-ui-dirs-mode)) (kill-buffer b)))
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))))))

(defun harness-ui-dirs-test--sources ()
  "Return the sources listed in the current directory buffer."
  (mapcar (lambda (e) (format "%s" (plist-get e :source))) harness-ui-dirs--entries))

(ert-deftest harness-ui-dirs-list-add-and-revoke ()
  (harness-ui-dirs-test-with
    (let ((extra (harness-test-temp-dir)))
      (harness-directories sid)
      (should (derived-mode-p 'harness-ui-dirs-mode))
      (harness-test-wait (lambda () harness-ui-dirs--entries) 5 "directory rows")
      (should (equal '("cwd" "outputs") (harness-ui-dirs-test--sources)))
      ;; Adding grants the directory to the session and the buffer follows.
      (harness-ui-dirs-add extra)
      (harness-test-wait (lambda () (member "session" (harness-ui-dirs-test--sources))) 5 "granted row")
      (should (member extra (harness-call 'permission/allowed-dirs sid)))
      (goto-char (point-min))
      (while (and (not (eobp)) (not (equal (tabulated-list-get-id) extra))) (forward-line 1))
      (should (equal extra (tabulated-list-get-id)))
      ;; Revoking asks, then removes it.
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
        (harness-ui-dirs-revoke))
      (harness-test-wait (lambda () (not (member "session" (harness-ui-dirs-test--sources)))) 5 "revoked row")
      (should-not (member extra (harness-call 'permission/allowed-dirs sid)))
      ;; The working directory cannot be revoked.
      (goto-char (point-min))
      (while (and (not (eobp)) (not (tabulated-list-get-id))) (forward-line 1))
      (should-error (harness-ui-dirs-revoke) :type 'user-error))))

(ert-deftest harness-ui-dirs-follows-grants-from-prompts ()
  (harness-ui-dirs-test-with
    (let ((extra (harness-test-temp-dir)))
      (harness-directories sid)
      (harness-test-wait (lambda () harness-ui-dirs--entries) 5 "directory rows")
      ;; A grant made elsewhere (a permission prompt) refreshes the buffer.
      (harness-call 'permission/allow-dir sid extra)
      (harness-test-wait (lambda () (member "session" (harness-ui-dirs-test--sources))) 5 "granted row"))))

(provide 'harness-ui-dirs-test)
;;; harness-ui-dirs-test.el ends here
