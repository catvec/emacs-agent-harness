;;; harness-mcp-fake-server.el --- An MCP server for the host's tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Started by test/harness-mcp-test.el as `emacs --batch -Q -L lisp -l
;; THIS-FILE -f harness-mcp-fake-main', in the sandbox or out of it.  Its
;; tools do what a test needs a server to do: say something back, say
;; where it runs, touch files, take its time, die, fill the pipe with a
;; lot of text, announce things.

;;; Code:

(require 'harness-mcp-protocol)

(defun harness-mcp-fake--tool (name handler)
  "Return the tool NAME, answered by HANDLER."
  (harness-mcp-make-tool :name name :description (format "The fake %s tool." name)
                         :schema '(:type "object" :properties :empty)
                         :handler handler))

(defun harness-mcp-fake--context (ctx)
  "Return the harness context the call CTX carried."
  (plist-get (plist-get ctx :meta) harness-mcp-context-key))

(defvar harness-mcp-fake--server
  (harness-mcp-make-server
   :name "fake" :title "Fake" :version "1"
   :tools
   (list
    (harness-mcp-fake--tool "echo" (lambda (args _ctx) (format "echo: %s" (plist-get args :text))))
    (harness-mcp-fake--tool "context" (lambda (_args ctx) (format "%S" (harness-mcp-fake--context ctx))))
    (harness-mcp-fake--tool "env" (lambda (_args _ctx)
                                    (format "sandbox=%s pid=%d" (getenv "HARNESS_SANDBOX") (emacs-pid))))
    (harness-mcp-fake--tool "read" (lambda (args _ctx)
                                     (with-temp-buffer
                                       (insert-file-contents (plist-get args :path))
                                       (buffer-string))))
    (harness-mcp-fake--tool "write" (lambda (args _ctx)
                                      (write-region (plist-get args :text) nil (plist-get args :path) nil 'silent)
                                      "written"))
    (harness-mcp-fake--tool "delete" (lambda (args _ctx)
                                       (delete-directory (plist-get args :path) t)
                                       "deleted"))
    (harness-mcp-fake--tool "sleep" (lambda (args _ctx)
                                      (sleep-for (or (plist-get args :seconds) 1))
                                      "slept"))
    (harness-mcp-fake--tool "crash" (lambda (_args _ctx) (kill-emacs 3)))
    (harness-mcp-fake--tool "big" (lambda (args _ctx) (make-string (plist-get args :n) ?x)))
    (harness-mcp-fake--tool "progress"
                            (lambda (_args ctx)
                              (funcall (plist-get ctx :progress) 1 2 "half way")
                              (funcall (plist-get ctx :progress) 2 2 "done")
                              "ok"))
    (harness-mcp-fake--tool "announce"
                            (lambda (args _ctx)
                              (harness-mcp-stdio-write
                               (harness-mcp-notification
                                "notifications/message"
                                (list :level "info" :logger "harness"
                                      :data (list :event (plist-get args :event) :args (list "an-argument")))))
                              "announced"))
    (harness-mcp-fake--tool "result" (lambda (_args _ctx)
                                       (list :content "with extras" :is-error nil
                                             :attachments (list (list :path "/a/path" :mime "text/plain"))
                                             :meta (list :exit 0))))
    (harness-mcp-fake--tool "fail" (lambda (_args _ctx) (error "Deliberate failure")))
    (harness-mcp-fake--tool "noise" (lambda (_args _ctx)
                                      (princ "garbage on standard output")
                                      (message "a message on standard error")
                                      "quiet"))
    (harness-mcp-fake--tool "later" (lambda (args _ctx)
                                      (let ((promise (harness-make-promise)))
                                        (run-at-time (or (plist-get args :seconds) 0.1) nil
                                                     (lambda () (harness-resolve promise "done later")))
                                        promise))))))

(defun harness-mcp-fake-main ()
  "Serve `harness-mcp-fake--server' on standard input and output."
  (harness-mcp-stdio-loop harness-mcp-fake--server)
  (kill-emacs 0))

(provide 'harness-mcp-fake-server)
;;; harness-mcp-fake-server.el ends here
