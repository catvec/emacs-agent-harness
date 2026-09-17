;;; harness-test-runner.el --- Load every test suite -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Noah Huppert

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Loaded by scripts/test.sh before `ert-run-tests-batch-and-exit'.  Suites are
;; discovered by name so adding a file never means editing a list here.

;;; Code:

(require 'harness-test-util)

(let ((directory (file-name-directory (or load-file-name buffer-file-name))))
  (dolist (file (directory-files directory t "\\`harness-.*-test\\.el\\'"))
    (load file nil t)))

(provide 'harness-test-runner)
;;; harness-test-runner.el ends here
