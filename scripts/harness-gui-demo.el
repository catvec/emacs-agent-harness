;;; harness-gui-demo.el --- Scripted provider for live UI verification -*- lexical-binding: t; -*-

;; Loaded into the dev daemon by the agent.  It registers a provider that
;; replays small conversations: a README read, a jailed read that needs
;; approval, a markdown answer, or a plan-mode session that calls the real
;; plan tool.  This exercises streaming, thinking, tool rendering, the
;; approval panel and markdown styling without a real model.

;;; Code:

(defvar harness-gui-demo--turn 0)

(defvar harness-gui-demo--script 'summary
  "Which conversation `harness-gui-demo-complete' replays.")

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

(defun harness-gui-demo--thought (request text)
  "Stream TEXT as the thinking of REQUEST."
  (when-let* ((thought (plist-get request :on-thought)))
    (funcall thought text)))

(defun harness-gui-demo--resolve-later (deferred delay result)
  "Resolve DEFERRED with RESULT after DELAY seconds."
  (run-at-time delay nil
               (lambda () (harness-deferred-resolve deferred result))))

(defun harness-gui-demo--summary-complete (request deferred)
  "Replay the summary conversation for REQUEST into DEFERRED."
  (pcase (cl-incf harness-gui-demo--turn)
    (1
     (harness-gui-demo--thought request "The user wants an overview. Check the README first.")
     (harness-gui-demo--stream request "Let me read the project README first.\n\n")
     (harness-gui-demo--resolve-later
      deferred 0.6
      (list :text "Let me read the project README first.\n"
            :thinking "The user wants an overview. Check the README first."
            :tool-calls (vector (list :id "call-readme"
                                      :name "read"
                                      :arguments '(:path "README.md")))
            :stop-reason "tool_use"
            :usage '(:input-tokens 120 :output-tokens 34))))
    (2
     (harness-gui-demo--thought request "The README is short. I still need the license header.")
     (harness-gui-demo--stream request "Now let me check how the project starts.\n\n")
     (harness-gui-demo--resolve-later
      deferred 0.4
      (list :text "Now let me check how the project starts.\n"
            :thinking "The README is short. I still need the license header."
            :tool-calls (vector (list :id "call-license"
                                      :name "read"
                                      :arguments '(:path "/etc/passwd")))
            :stop-reason "tool_use"
            :usage '(:input-tokens 300 :output-tokens 28))))
    (_
     (harness-gui-demo--stream request
                               "## Summary\n\nThe README calls the harness "
                               (cons 0.15 "**the Magit of agentic harnesses**.\n\n")
                               (cons 0.15 "- `read` keeps file access inside the session\n- shell commands run in a sandbox\n- approvals appear as a focused panel\n\n")
                               (cons 0.2 "```elisp\n(harness-start)\n```\n\n")
                               (cons 0.15 "Try _M-x harness-ui-chat-new_ to begin.\n"))
     (harness-gui-demo--resolve-later
      deferred 1.0
      (list :text "## Summary\n\nThe README calls the harness **the Magit of agentic harnesses**.\n"
            :stop-reason "end_turn"
            :usage '(:input-tokens 480 :output-tokens 96))))))

(defun harness-gui-demo--plan-complete (request deferred)
  "Replay the plan-mode conversation for REQUEST into DEFERRED."
  (pcase (cl-incf harness-gui-demo--turn)
    (1
     (harness-gui-demo--thought request "The user wants a plan; look around first.")
     (harness-gui-demo--stream request "Let me look at how the UI renders before planning.\n")
     (harness-gui-demo--resolve-later
      deferred 0.4
      (list :text "Let me look at how the UI renders before planning.\n"
            :stop-reason "tool_use"
            :tool-calls (vector (list :id "call-read"
                                      :name "read"
                                      :arguments '(:path "README.md"))))))
    (2
     (harness-gui-demo--stream request "I have enough context.  Writing the plan.\n")
     (harness-gui-demo--resolve-later
      deferred 0.4
      (list :text "I have enough context.  Writing the plan.\n"
            :stop-reason "tool_use"
            :tool-calls
            (vector (list :id "call-plan"
                          :name "plan"
                          :arguments
                          '(:title "Add a spinner"
                            :plan "# Goal\n\nShow a spinner while the model streams.\n\n## Approach\n\n- add a `harness-ui-chat-spinner` timer in the header line\n- stop it in `harness-ui-chat--send-blocks` callbacks\n- cover it with a UI test\n\n## Verification\n\n1. run `scripts/test.sh test/harness-ui-chat-test.el`\n2. watch a live turn in the dev daemon"))))))
    (_
     (harness-gui-demo--stream request
                               "The plan is in the transcript. "
                               (cons 0.2 "Approve it or tell me what to change."))
     (harness-gui-demo--resolve-later
      deferred 0.8
      (list :text "The plan is in the transcript. Approve it or tell me what to change.\n"
            :stop-reason "end_turn")))))

(defun harness-gui-demo-complete (request)
  "Scripted completion for the demo conversation."
  (let ((deferred (harness-deferred-new)))
    (cond
     ;; Answer the automatic session-naming call with a short title.
     ((string-match-p "short title" (or (plist-get request :system) ""))
      (harness-gui-demo--resolve-later
       deferred 0.05
       (list :text "Spinner plan" :stop-reason "end_turn")))
     ((eq harness-gui-demo--script 'plan)
      (harness-gui-demo--plan-complete request deferred))
     (t
      (harness-gui-demo--summary-complete request deferred)))
    deferred))

(defun harness-gui-demo--install-provider ()
  "Register the scripted provider."
  (harness-service-register
   "provider"
   :module 'harness-gui-demo
   :methods (list (cons 'complete #'harness-gui-demo-complete)
                  (cons 'models (lambda (&rest _args)
                                  (vector (list :id "mock/smart" :name "Mock Smart"
                                                :provider "mock" :context-window 200000))))
                  (cons 'price (lambda (&rest _args)
                                 (list :amount 0.0123 :currency "USD"))))))

(defun harness-gui-demo--new-session (mode prompt)
  "Create a session in MODE, open it and send PROMPT.
With PROMPT nil, open the chat but leave the composer empty for the
caller (used by demos that type the prompt for real)."
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
          (when mode
            (harness-service-call "agent" 'set-mode :session-id session-id :mode-id mode))
          (harness-ui-chat-open session-id 'full)
          (when prompt
            (with-current-buffer (gethash session-id harness-ui-chat--buffers)
              (goto-char (harness-ui-chat--compose-point))
              (insert prompt)
              (harness-ui-chat-send)))))))))

(defun harness-gui-demo-prepare ()
  "Install the scripted provider and open an empty demo chat.
The caller types the prompt; used by demos and screen recordings."
  (interactive)
  (setq harness-gui-demo--turn 0
        harness-gui-demo--script 'summary)
  (harness-gui-demo--install-provider)
  (harness-gui-demo--new-session nil nil))

(defun harness-gui-demo-install ()
  "Install the scripted provider and create a demo session."
  (interactive)
  (setq harness-gui-demo--turn 0
        harness-gui-demo--script 'summary)
  (harness-gui-demo--install-provider)
  (harness-gui-demo--new-session nil "What is this project?"))

(defun harness-gui-demo-plan ()
  "Create a plan-mode session and ask for a plan."
  (interactive)
  (setq harness-gui-demo--turn 0
        harness-gui-demo--script 'plan)
  (harness-gui-demo--install-provider)
  (harness-gui-demo--new-session "plan" "Plan how to add a spinner to the chat header."))

(defun harness-gui-demo-send ()
  "Put a prompt in the composer of the newest chat buffer and send it."
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
