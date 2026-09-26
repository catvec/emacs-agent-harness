;;; harness-fixture-beta.el --- Test module depending on alpha -*- lexical-binding: t; -*-

;;; Commentary:

;; Fixture for `harness-core-test': declares a dependency on
;; `harness-fixture-alpha' and requires a version that a fixture gamma
;; cannot satisfy, to test version checking.

;;; Code:

(require 'harness-core)
(require 'harness-fixture-alpha)

(harness-module-define 'harness-fixture-beta
  :version "2.0.0"
  :description "Beta test fixture."
  :requires '((harness-core "0.1.0")
              (harness-fixture-alpha "1.0.0"))
  :provides '(harness-fixture-beta)
  :setup #'harness-fixture-beta-setup)

(defun harness-fixture-beta-setup ()
  "Set the fixture up."
  (push 'beta-setup harness-fixture-test-log)
  (harness-service-register
   "beta"
   :module 'harness-fixture-beta
   :doc "Beta fixture service."
   :methods '((hello . (lambda () "hello")))))

(provide 'harness-fixture-beta)
;;; harness-fixture-beta.el ends here
