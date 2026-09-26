;;; harness-fixture-old-alpha.el --- Impossible version requirement -*- lexical-binding: t; -*-

;;; Commentary:

;; Fixture for `harness-core-test': requires a version of alpha that does
;; not exist, so loading it must fail with `harness-module-error'.

;;; Code:

(require 'harness-core)
(require 'harness-fixture-alpha)

(harness-module-define 'harness-fixture-old-alpha
  :version "0.0.1"
  :description "Requires a future alpha."
  :requires '((harness-fixture-alpha "99.0.0"))
  :provides '(harness-fixture-old-alpha)
  :setup #'ignore)

(provide 'harness-fixture-old-alpha)
;;; harness-fixture-old-alpha.el ends here
