;;; harness-util-test.el --- Tests for shared helpers  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defun harness-util-test--touch (root &rest paths)
  "Create each of PATHS (relative) under ROOT."
  (dolist (p paths)
    (let ((f (expand-file-name p root)))
      (make-directory (file-name-directory f) t)
      (with-temp-file f))))

(ert-deftest harness-util-list-files-walks-shallowest-first ()
  (let ((root (harness-test-temp-dir)))
    (harness-util-test--touch root "a/b/deep.el" "top.el" "a/mid.el"
                              ".git/HEAD" "node_modules/x/i.js" ".hidden/h.el" ".env")
    (should (equal (harness-list-files root) '(".env" "top.el" "a/mid.el" "a/b/deep.el")))))

(ert-deftest harness-util-list-files-stops-at-limit ()
  (let ((root (harness-test-temp-dir)))
    (harness-util-test--touch root "1" "2" "3" "d/4")
    (should (= (length (harness-list-files root 2)) 2))))

(ert-deftest harness-util-list-files-skips-unreadable-directories ()
  (let ((root (harness-test-temp-dir)))
    (harness-util-test--touch root "locked/secret" "ok/file")
    (set-file-modes (expand-file-name "locked" root) #o000)
    (unwind-protect
        (should (equal (harness-list-files root) '("ok/file")))
      (set-file-modes (expand-file-name "locked" root) #o755))))

(ert-deftest harness-util-list-files-respects-time-budget ()
  (let ((root (harness-test-temp-dir)))
    (harness-util-test--touch root "a/1" "b/2")
    (should (null (harness-list-files root nil 0)))))

(provide 'harness-util-test)
;;; harness-util-test.el ends here
