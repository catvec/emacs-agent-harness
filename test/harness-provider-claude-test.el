;;; harness-provider-claude-test.el --- Tests for the Claude CLI provider -*- lexical-binding: t; -*-

;;; Commentary:

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'harness-core)
(require 'harness-provider)
(require 'harness-provider-claude)
(require 'harness-test-helpers)

(harness-module-load 'harness-provider)
(harness-module-load 'harness-provider-claude)

(defun harness-provider-claude-test--script (lines &optional exit-code)
  "Write a fake claude CLI emitting LINES and exiting with EXIT-CODE."
  (let* ((directory (make-temp-file "harness-claude-cli-" t))
         (script (expand-file-name "claude" directory)))
    (with-temp-file script
      (insert "#!/usr/bin/env bash\n")
      (insert "# Consume the prompt, then replay the canned stream.\n")
      (insert "cat >/dev/null\n")
      (dolist (line lines)
        (insert (format "printf '%%s\\n' %s\n"
                        (shell-quote-argument line))))
      (insert (format "exit %d\n" (or exit-code 0))))
    (set-file-modes script #o755)
    script))

(defun harness-provider-claude-test--request (&optional on-text)
  "A provider request with a small conversation.
ON-TEXT receives streamed deltas."
  (list :model "claude-cli/claude-sonnet"
        :system "You are terse."
        :messages (vector (list :role "user"
                                :content (vector (list :type "text"
                                                       :text "Say hello"))))
        :on-text on-text))

(defun harness-provider-claude-test--run (request)
  "Run REQUEST through the provider and settle."
  (let ((deferred (harness-provider-complete request)))
    (harness-test-settle deferred 20)
    deferred))

(ert-deftest harness-provider-claude-registers-models ()
  (unless (executable-find harness-provider-claude-program)
    (ert-skip "the claude CLI is not installed"))
  (let ((provider (harness-provider-get "claude-cli")))
    (should provider)
    (should (equal (harness-provider-description provider)
                   "Claude Code CLI (subscription plans)."))
    (let ((deferred (harness-provider-models)))
      (harness-test-settle deferred 5)
      (let ((models (append (harness-deferred-value deferred) nil)))
        (should (cl-some (lambda (model)
                           (equal (plist-get model :id) "claude-cli/claude-sonnet"))
                         models))))))

(ert-deftest harness-provider-claude-streams-text-and-usage ()
  (let* ((harness-provider-claude-program
          (harness-provider-claude-test--script
           '("{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello \"}}}"
             "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"from Claude.\"}}}"
             "{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"Hello from Claude.\",\"usage\":{\"input_tokens\":12,\"output_tokens\":5}}"
             "{\"type\":\"done\"}")))
         (deltas nil)
         (deferred (harness-provider-claude-test--run
                    (harness-provider-claude-test--request
                     (lambda (text) (push text deltas))))))
    (should (harness-deferred-resolved-p deferred))
    (let ((result (harness-deferred-value deferred)))
      (should (equal (plist-get result :text) "Hello from Claude."))
      (should (equal (plist-get result :stop-reason) "end_turn"))
      (should (equal (plist-get (plist-get result :usage) :input-tokens) 12))
      (should (equal (plist-get (plist-get result :usage) :output-tokens) 5)))
    (should (equal (nreverse deltas) '("Hello " "from Claude.")))))

(ert-deftest harness-provider-claude-uses-the-final-message-without-streaming ()
  (let* ((harness-provider-claude-program
          (harness-provider-claude-test--script
           '("{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Complete answer\"}]}}"
             "{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"Complete answer\",\"usage\":{\"input_tokens\":3,\"output_tokens\":2}}")))
         (deferred (harness-provider-claude-test--run
                    (harness-provider-claude-test--request))))
    (should (harness-deferred-resolved-p deferred))
    (should (equal (plist-get (harness-deferred-value deferred) :text) "Complete answer"))))

(ert-deftest harness-provider-claude-reports-cli-failure ()
  (let* ((harness-provider-claude-program
          (harness-provider-claude-test--script
           '("not json at all") 1))
         (deferred (harness-provider-claude-test--run
                    (harness-provider-claude-test--request))))
    (should (harness-deferred-rejected-p deferred))
    (should (string-match-p "claude exited with status 1"
                            (format "%S" (harness-deferred-value deferred))))))

(ert-deftest harness-provider-claude-reports-a-missing-cli ()
  (let* ((harness-provider-claude-program "/nonexistent/claude")
         (deferred (harness-provider-claude-test--run
                    (harness-provider-claude-test--request))))
    (should (harness-deferred-rejected-p deferred))
    (should (string-match-p "not on PATH"
                            (format "%S" (harness-deferred-value deferred))))))

(ert-deftest harness-provider-claude-prompt-renders-the-conversation ()
  (let ((prompt (harness-provider-claude--prompt
                 (harness-provider-claude-test--request))))
    (should (string-match-p "You are terse\\." prompt))
    (should (string-match-p "User: Say hello" prompt))
    (should (string-match-p "Assistant:$" prompt))))

(provide 'harness-provider-claude-test)
;;; harness-provider-claude-test.el ends here
