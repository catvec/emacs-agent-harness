;;; -*- lexical-binding: t; -*-
(load (expand-file-name "lisp/modules/harness-tasks-test.el" harness-test-root) nil t)
(let* ((parent (make-temp-file "harness-pause-parent-" t))
       (temporary-file-directory (file-name-as-directory parent)))
  (add-hook 'kill-emacs-hook (lambda () (ignore-errors (delete-directory parent t))))
  (harness-test-mark-project parent)
  (ert-run-tests-batch-and-exit "harness-tasks-pause-all-and-resume-all"))
