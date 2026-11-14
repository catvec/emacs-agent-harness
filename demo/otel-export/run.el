;;; run.el --- Run one demo turn with otel exporting to a local collector  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness.

;;; Commentary:

;; A demo a reviewer can run: a real harness session on the scripted demo
;; provider, with the otel module on and exporting to a collector on this
;; machine.  Nothing is faked but the model.  Start the collector first
;; (demo/otel-export/collector.py), then:
;;
;;   emacs -Q --batch -L lisp -L lisp/modules -L lisp/ui -L . \
;;     -l harness -l demo/otel-export/run.el "tools"
;;
;; The argument picks the demo provider's script ("tools" by default: three
;; tool calls, then a summary).  It prints what each export carried, then
;; flushes and shuts the module down.  The collector prints the spans and
;; metric points it received.

;;; Code:

(require 'harness)
(require 'harness-store)
(require 'harness-project)
(require 'harness-config)
(require 'harness-provider)
(require 'harness-provider-demo)
(require 'harness-tools)
(require 'harness-session)
(require 'harness-agent)
(require 'harness-otel)

(defvar harness-demo-otel--port
  (string-to-number (or (getenv "HARNESS_OTEL_DEMO_PORT") "4318"))
  "The port the demo's collector listens on.
`HARNESS_OTEL_DEMO_PORT' picks another, for a machine where 4318 is taken.")

(defun harness-demo-otel--say (format-string &rest args)
  "Print FORMAT-STRING and ARGS as one line."
  (princ (concat (apply #'format format-string args) "\n")))

(defun harness-demo-otel--exported (what)
  "Wait a moment, then say what the last export carried."
  (sleep-for 0.6)
  (let ((status (harness-call 'otel/status)))
    (harness-demo-otel--say "  %s: queued %s, sent %s, failed %s"
                            what
                            (plist-get status :queued)
                            (plist-get status :sent)
                            (plist-get status :failed))))

(defun harness-demo-otel--run ()
  "Run the demo turn and report what the exporter did."
  (setq harness-otel-enabled t
        harness-otel-endpoint (format "http://127.0.0.1:%d" harness-demo-otel--port)
        harness-otel-export-interval 1
        harness-otel-service-name "emacs-agent-harness-demo")
  (harness-otel--init)
  (harness-demo-otel--say "collector %s" harness-otel-endpoint)
  ;; The tools the demo's "tools" script asks for: two searches and a bash.
  (harness-define-tool "glob" :label "Search files" :description "glob" :kind 'read
                       :handler (lambda (_input _ctx) "a glob result"))
  (harness-define-tool "grep" :label "Search text" :description "grep" :kind 'read
                       :handler (lambda (_input _ctx) "a grep result"))
  (harness-define-tool "bash" :label "Run command" :description "bash" :kind 'exec
                       :handler (lambda (_input _ctx) "a bash result"))
  (harness-add-filter 'permission/decide
                      (lambda (_decision next &rest _)
                        (funcall next (list :behavior 'allow))) 10)
  (let* ((cwd (make-temp-file "harness-otel-demo-" t))
         (id (plist-get (harness-call 'session/create :cwd cwd :model "demo:scripted")
                        :id)))
    (harness-demo-otel--say "session %s" id)
    (harness-demo-otel--say "turn: \"tools\" (three tool calls, then a summary)")
    (harness-await (harness-call 'agent/prompt id "tools"))
    (harness-demo-otel--exported "after the turn")
    ;; The interval is a second, but a flush is what shows it now.
    (harness-call 'otel/flush)
    (harness-demo-otel--exported "after a flush")
    (harness-call 'otel/flush)
    (harness-demo-otel--exported "after a second flush (nothing owed)")
    (harness-otel--shutdown)
    (harness-demo-otel--say "shut down: collecting %s"
                            (plist-get (harness-call 'otel/status) :collecting))))

(harness-demo-otel--run)

;;; run.el ends here
