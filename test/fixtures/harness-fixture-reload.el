;;; harness-fixture-reload.el --- Test module for safe reloading -*- lexical-binding: t; -*-

;;; Commentary:

;; Copied into a temporary directory by `harness-reload-test' so the copy
;; can be rewritten with new values or deliberate errors.

;;; Code:

(require 'harness-core)

(defvar harness-fixture-reload-value "one"
  "Value reported by the fixture service.")

(defun harness-fixture-reload-report ()
  "Return the fixture's current report."
  "one")

(harness-module-define 'harness-fixture-reload
  :version "1.0.0"
  :description "Reload fixture."
  :requires '((harness-core "0.1.0"))
  :provides '(harness-fixture-reload)
  :setup #'harness-fixture-reload-setup
  :teardown #'harness-fixture-reload-teardown)

(defvar harness-fixture-reload-setup-count 0
  "How many times setup ran.")

(defun harness-fixture-reload-setup ()
  "Register the fixture service."
  (cl-incf harness-fixture-reload-setup-count)
  (harness-service-register
   "fixture-reload"
   :module 'harness-fixture-reload
   :methods '((value . (lambda () (harness-fixture-reload-report)))
              (variable . (lambda () harness-fixture-reload-value)))))

(defun harness-fixture-reload-teardown ()
  "Nothing to undo."
  nil)

(provide 'harness-fixture-reload)
;;; harness-fixture-reload.el ends here
