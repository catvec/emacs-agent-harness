;;; harness-gui-demo.el --- Scripted provider for live UI verification -*- lexical-binding: t; -*-

;; Loaded into the dev daemon by the agent.  It registers a provider that
;; replays a small conversation: a README read, a jailed read that needs
;; approval, and a markdown answer.  This exercises streaming, thinking,
;; tool rendering, the approval panel and markdown styling without a real
;; model.

;;; Code:

(defvar harness-gui-demo--turn 0)

(defun harness-gui-demo--stream (request &rest pieces)
  "Send PIECES (strings, or (delay . string)) to REQUEST's on-text."
  (dolist (piece pieces)
    (if (consp piece)
        (let ((delay (car piece))
              (text (cdr piece)))
          (run-at-time delay nil
                       (lambda ()
                         (when-let* ((callback (plist-get request :on-text)))
                           (funcall callback text)))))
      (when-let* ((callback (plist-get request :on-text)))
        (funcall callback piece)))))

(defun harness-gui-demo-complete (request)
  "Scripted completion for the demo conversation."
  (cl-incf harness-gui-demo--turn)
  (let ((deferred (harness-deferred-new)))
    (pcase harness-gui-demo--turn
      (1
       (when-let* ((thought (plist-get request :on-thought)))
         (funcall thought "The user wants an overview. Check the README first."))
       (harness-gui-demo--stream request "Let me read the project README first.\n\n"
                                 (cons 0.3 "\n"))
       (run-at-time 0.6 nil
                    (lambda ()
                      (harness-deferred-resolve
                       deferred
                       (list :text "Let me read the project README first.\n"
                             :thinking "The user wants an overview. Check the README first."
                             :tool-calls (vector (list :id "call-readme"
                                                       :name "read"
                                                       :arguments '(:path "README.md")))
                             :stop-reason "tool_use"
                             :usage '(:input-tokens 120 :output-tokens 34))))))
      (2
       (when-let* ((thought (plist-get request :on-thought)))
         (funcall thought "The README is short. I still need the license header."))
       (harness-gui-demo--stream request "Now let me check how the project starts.\n\n")
       (run-at-time 0.4 nil
                    (lambda ()
                      (harness-deferred-resolve
                       deferred
                       (list :text "Now let me check how the project starts.\n"
                             :thinking "The README is short. I still need the license header."
                             :tool-calls (vector (list :id "call-license"
                                                       :name "read"
                                                       :arguments '(:path "/etc/passwd")))
                             :stop-reason "tool_use"
                             :usage '(:input-tokens 300 :output-tokens 28))))))
      (_
       (harness-gui-demo--stream request
                                 "## Summary\n\nThe README calls the harness "
                                 (cons 0.15 "**the Magit of agentic harnesses**.\n\n")
                                 (cons 0.15 "- `read` keeps file access inside the session\n- shell commands run in a sandbox\n- approvals appear as a focused panel\n\n")
                                 (cons 0.2 "```elisp\n(harness-start)\n```\n\n")
                                 (cons 0.15 "Try _M-x harness-ui-chat-new_ to begin.\n"))
       (run-at-time 1.0 nil
                    (lambda ()
                      (harness-deferred-resolve
                       deferred
                       (list :text "## Summary\n\nThe README calls the harness **the Magit of agentic harnesses**.\n"
                             :stop-reason "end_turn"
                             :usage '(:input-tokens 480 :output-tokens 96)))))))
    deferred))

(defun harness-gui-demo-install ()
  "Install the scripted provider and create a demo session."
  (interactive)
  (setq harness-gui-demo--turn 0)
  (harness-service-register
   "provider"
   :module 'harness-gui-demo
   :methods (list (cons 'complete #'harness-gui-demo-complete)
                  (cons 'models (lambda (&rest _args)
                                  (vector (list :id "mock/smart" :name "Mock Smart"
                                                :provider "mock" :context-window 200000))))
                  (cons 'price (lambda (&rest _args)
                                 (list :amount 0.0123 :currency "USD")))))
  (harness-agent-refresh-models)
  (harness-deferred-then
   (harness-ui-request "session/new" (list :cwd default-directory :mcpServers []))
   (lambda (result)
     (let ((session-id (plist-get result :sessionId)))
       (harness-deferred-then
        (harness-ui-request "session/set_config_option"
                            (list :sessionId session-id :configId "model"
                                  :value "mock/smart"))
        (lambda (_)
          (harness-ui-chat-open session-id 'full)
          (message "demo session: %s" session-id)))))))

(defun harness-gui-demo-send ()
  "Put a prompt in the composer and send it."
  (interactive)
  (let ((buffer (car (seq-filter (lambda (buffer)
                                   (string-prefix-p "*harness:" (buffer-name buffer)))
                                 (buffer-list)))))
    (with-current-buffer buffer
      (goto-char (harness-ui-chat--compose-point))
      (insert "What is this project?")
      (harness-ui-chat-send))))

(provide 'harness-gui-demo)
;;; harness-gui-demo.el ends here
