;;; harness-fuzz-plugin.el --- A project plugin that fuzzes the harness  -*- lexical-binding: t; -*-

;; Version: 0.2.0

;;; Commentary:

;; The project plugin of the fuzz target suite.  It is not loaded by
;; this repository's .dir-locals.el and is not part of a working
;; harness: a test, or a project that wants to fuzz the harness, makes
;; .dir-locals.el require this file and name module tools-fuzz, then
;; trusts those entries as the user would with `!'.  See
;; harness-fuzz.el for what a target is and harness-plugins.el for the
;; loading, trust, freezing and scope rules.
;;
;; Loading and defining happen in two files, as a plugin's halves do in
;; both Emacsen: this file is the entry point the project requires, and
;; harness-tools-fuzz.el is loaded once the tool registry is there.
;; The engine, harness-fuzz.el, is the adapter AFL++ starts for each
;; input.  Both wait for harness-tools, so the user's Emacs, which
;; loads no tool registry, does not pull the fuzz engine and its
;; protocol libraries in when a file of the project is visited.

;;; Code:

(let ((directory (file-name-directory (or load-file-name buffer-file-name))))
  (with-eval-after-load 'harness-tools
    (require 'harness-fuzz (expand-file-name "harness-fuzz" directory))
    (require 'harness-tools-fuzz
             (expand-file-name "harness-tools-fuzz" directory))))

(provide 'harness-fuzz-plugin)
;;; harness-fuzz-plugin.el ends here
