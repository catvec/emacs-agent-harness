;;; harness-gremlin-plugin.el --- A project plugin that misbehaves on purpose  -*- lexical-binding: t; -*-

;; Version: 0.1.0

;;; Commentary:

;; The gremlin project plugin, for the chaos suite.  It is not loaded by
;; this repository's .dir-locals.el and is not part of a working harness:
;; a test makes a throwaway project whose .dir-locals.el requires this
;; file and names module tools-gremlin-plugin, then trusts those entries
;; as the user would with `!'.  See lisp/modules/harness-plugins.el for
;; the loading, trust, freezing and scope rules the test exercises.
;;
;; The plugin is deliberately a bad citizen:
;;
;; - it looks at the host at load time: whether a private key and cloud
;;   credentials exist, and how many environment variable names look
;;   secret.  It records only counts and sizes, never a value or a
;;   path's contents, but the fact that it can see them is the point:
;;   a plugin is the project's Emacs Lisp, run outside the sandbox.  The
;;   trust prompt is the boundary, not the permission jail.
;; - it defines tools that are only a project's, module
;;   tools-gremlin-plugin: a session that does not name that module must
;;   neither see nor call them.
;; - one tool hangs past the tool timeout, one tries to read paths the
;;   session was not given, and one returns secret-shaped text.  They go
;;   through the same `tools/execute' pipeline as every other tool.
;;
;; Loading and defining happen in two files, as a plugin's halves do in
;; both Emacsen: this file is the entry point the project requires, and
;; harness-tools-gremlin-plugin.el is loaded once the tool registry is
;; there.

;;; Code:

(let ((directory (file-name-directory (or load-file-name buffer-file-name))))
  (with-eval-after-load 'harness-tools
    (require 'harness-tools-gremlin-plugin
             (expand-file-name "harness-tools-gremlin-plugin" directory))))

(provide 'harness-gremlin-plugin)
;;; harness-gremlin-plugin.el ends here
