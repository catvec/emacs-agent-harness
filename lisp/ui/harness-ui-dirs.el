;;; harness-ui-dirs.el --- Obsolete: a session's directories are in its access view  -*- lexical-binding: t; -*-

;;; Commentary:

;; The list of the directories a session may touch was a buffer of its
;; own here.  It is a section of the session's access view now
;; (harness-ui-access.el), with the session's sandbox, mode, tools,
;; rules and the judgements of its calls, and `harness-directories'
;; (C-c h d) opens the view at its directories.  The access view loads
;; with the access module, one of the core modules.
;;
;; This module stays so that a configuration naming ui-dirs in
;; `harness-enabled-modules' still loads: it loads the access view.

;;; Code:

(require 'harness-core)
(require 'harness-ui-access)

(harness-define-module 'ui-dirs
  :doc "Obsolete: the directories of a session are a section of its access view (ui-access), which this loads."
  :requires '(ui-access))

(provide 'harness-ui-dirs)
;;; harness-ui-dirs.el ends here
