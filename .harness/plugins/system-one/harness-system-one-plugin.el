;;; harness-system-one-plugin.el --- The system-one plugin  -*- lexical-binding: t; -*-

;; Version: 0.1.0

;;; Commentary:

;; What a project's .dir-locals.el requires to use the local reflex: the
;; module `system-one', which reads a tool call with a small fine-tuned
;; encoder and decides it when the model is sure (see
;; lisp/modules/harness-system-one.el).
;;
;; The module is the harness's own, so it loads with the harness and its
;; stage is in the permission chain whether or not a project names it.
;; What a project decides by naming it here is that its sessions get the
;; tool `system_one_classify', which reads a call without running it.
;; The reflex itself is a stage, not a tool, and a stage is not what a
;; plugin adds: `harness-plugin-modules' names modules whose tools a
;; project's sessions are offered.
;;
;;   ((nil . ((eval . (require 'harness-system-one-plugin
;;                             (expand-file-name ".harness/plugins/system-one/"
;;                                               top)))
;;            (harness-plugin-modules . (system-one)))))

;;; Code:

(require 'harness-system-one)

;; The tool is defined in the module, so naming the module in
;; `harness-plugin-modules' is what offers it.  A plugin file whose name
;; is harness-NAME.el defines module NAME, which is how the harness
;; knows which module's tools a project asked for.
(provide 'harness-system-one-plugin)
;;; harness-system-one-plugin.el ends here
