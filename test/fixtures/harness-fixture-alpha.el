;;; harness-fixture-alpha.el --- Test module -*- lexical-binding: t; -*-

;;; Commentary:

;; Fixture for `harness-core-test': a module with no dependencies that
;; registers a service, an event and an event handler, and records its
;; lifecycle in `harness-fixture-test-log'.

;;; Code:

(require 'harness-core)

(defvar harness-fixture-test-log nil
  "Set by fixture modules to record lifecycle events.")

(harness-module-define 'harness-fixture-alpha
  :version "1.0.0"
  :description "Alpha test fixture."
  :requires '((harness-core "0.1.0"))
  :provides '(harness-fixture-alpha)
  :setup #'harness-fixture-alpha-setup
  :teardown #'harness-fixture-alpha-teardown)

(harness-event-define 'harness-fixture-ping
  :module 'harness-fixture-alpha
  :doc "A ping happened."
  :payload '((value . integer)))

(defun harness-fixture-alpha-handle-ping (payload)
  "Record PAYLOAD in the fixture log."
  (push (list 'alpha-handled (plist-get payload :value)) harness-fixture-test-log))

(defun harness-fixture-alpha-setup ()
  "Set the fixture up."
  (push 'alpha-setup harness-fixture-test-log)
  (harness-service-register
   "alpha"
   :module 'harness-fixture-alpha
   :doc "Fixture service."
   :methods '((echo . (lambda (value) value))
              (double . (lambda (value) (* 2 value)))))
  (harness-on 'harness-fixture-ping #'harness-fixture-alpha-handle-ping
              :module 'harness-fixture-alpha))

(defun harness-fixture-alpha-teardown ()
  "Tear the fixture down."
  (push 'alpha-teardown harness-fixture-test-log))

(provide 'harness-fixture-alpha)
;;; harness-fixture-alpha.el ends here
