;;; harness-fixture-tools.el --- Test module that registers a tool -*- lexical-binding: t; -*-

;;; Commentary:

;; Fixture for `harness-tools-test': unloading this module must remove the
;; tool it registered.

;;; Code:

(require 'harness-core)
(require 'harness-tools)

(harness-module-define 'harness-fixture-tools
  :version "1.0.0"
  :description "Tool fixture."
  :requires '((harness-core "0.1.0")
              (harness-tools "0.1.0"))
  :provides '(harness-fixture-tools)
  :setup #'harness-fixture-tools-setup)

(defun harness-fixture-tools-setup ()
  "Register the fixture tool."
  (harness-tool-register
   "fixture-echo"
   :description "Echo the input."
   :schema '(:type "object"
             :properties (:text (:type "string"))
             :required ["text"])
   :kind 'read
   :read-only t
   :handler (lambda (arguments _context) (plist-get arguments :text))))

(provide 'harness-fixture-tools)
;;; harness-fixture-tools.el ends here
