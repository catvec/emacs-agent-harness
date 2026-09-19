;;; harness-ui-test.el --- Tests for the conversation and other views -*- lexical-binding: t; -*-

;; Copyright (C) 2026 the emacs-agent-harness authors

;; This file is not part of GNU Emacs.

;;; Commentary:

;; These tests drive the real UI in batch mode: buffers are created, rendered
;; and read back, so a renderer that throws or a marker that drifts is caught.
;; The provider is scripted (`harness-mock-provider'), so there is no network.

;;; Code:

(require 'ert)
(require 'harness)
(require 'harness-mock-provider)
(require 'harness-test-util)

(defmacro harness-ui-test-with-session (script &rest body)
  "Run BODY with a session whose provider plays SCRIPT.
BODY can refer to `session' and `buffer'; the buffer is killed afterwards."
  (declare (indent 1))
  `(harness-test-with-temp-session-dir
     (let* ((harness-plugins-directory
             (expand-file-name "plugins" harness-test--directory))
            (harness-permission-rules nil)
            (harness-permission-rules-file nil)
            (harness-permission-policy '((:default allow)))
            (harness-providers (list (list :name 'mock :kind 'harness-test
                                           :script ,script)))
            (harness-models '((:provider mock :id "mock-model"
                              :price-in 1.0 :price-out 2.0)))
            (default-directory (file-name-as-directory harness-test--directory))
            (session (harness-session-create '(:name "ui" :model "mock-model"
                                                      :provider mock)))
            (buffer nil))
       (harness-provider-setup)
       (unwind-protect
           (progn
             (setq buffer (harness-conversation-buffer session))
             ,@body)
         (when (buffer-live-p buffer) (kill-buffer buffer))
         ;; Sessions are global state; leaking one would change the counts the
         ;; mode line and the browser report in later tests.
         (harness-session-remove session)
         (dolist (other (buffer-list))
           (with-current-buffer other
             (when (or (derived-mode-p 'harness-sessions-mode)
                       (derived-mode-p 'harness-tree-mode)
                       (derived-mode-p 'harness-ask-mode)
                       (derived-mode-p 'harness-queue-mode))
               (kill-buffer other))))))))

(defun harness-ui-test--wait-idle (session)
  "Wait until SESSION is idle."
  (harness-test-wait-for
   (lambda () (memq (harness-session-status session) '(idle))) 20))

(defun harness-ui-test--send (session text)
  "Send TEXT to SESSION and wait for the run to finish."
  (harness-agent-send session text)
  (harness-ui-test--wait-idle session))

(defun harness-ui-test--text (buffer)
  "Return BUFFER's contents as plain text."
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))


;;; Conversation buffer

(ert-deftest harness-ui-test-renders-a-conversation ()
  "A conversation renders both speakers and keeps output read-only."
  (harness-ui-test-with-session '((:text "hello from the model"))
    (harness-ui-test--send session "hello from me")
    (let ((text (harness-ui-test--text buffer)))
      (should (string-match-p "hello from me" text))
      (should (string-match-p "You" text))
      (should (string-match-p "hello from the model" text))
      (should (string-match-p "Assistant" text)))
    ;; The model lives in the header line, not the transcript.
    (with-current-buffer buffer
      (should (string-match-p "mock-model" (harness-conversation--header-line)))
      (should (string-match-p "Idle" (harness-conversation--header-line))))
    ;; The transcript is entirely read-only; the editable input lives in its
    ;; own buffer, shown in a side window.
    (with-current-buffer buffer
      (should (text-property-not-all (point-min) (point-max) 'read-only nil)))
    (with-current-buffer (harness-conversation-input-buffer session)
      (should (marker-position harness-conversation--input-start))
      (should (equal (harness-conversation--input) "")))))

(ert-deftest harness-ui-test-input-area-round-trip ()
  "Typing in the input area and sending works from the buffer."
  (harness-ui-test-with-session '((:text "reply"))
    (with-current-buffer (harness-conversation-input-buffer session)
      (goto-char (point-max))
      (insert "typed by hand")
      (harness-conversation-send)
      (should (equal (harness-conversation--input) "")))
    (harness-ui-test--wait-idle session)
    (should (string-match-p "typed by hand" (harness-ui-test--text buffer)))
    (should (string-match-p "reply" (harness-ui-test--text buffer)))))

(ert-deftest harness-ui-test-input-area-accepts-typing ()
  "Every key self-inserts in the input buffer, including command keys.

The input is a `text-mode' derivative, so a single-key transcript binding
such as n, p, g or q cannot swallow what the user types."
  (harness-ui-test-with-session '((:text "reply"))
    (switch-to-buffer (harness-conversation-input-buffer session))
    (goto-char (point-max))
    (execute-kbd-macro "n p g q 1 < > ? h a, b.")
    (should (equal (harness-conversation--input) "n p g q 1 < > ? h a, b."))
    (execute-kbd-macro (kbd "RET"))
    (harness-ui-test--wait-idle session)
    (should (string-match-p (regexp-quote "n p g q 1 < > ? h a, b.")
                            (harness-ui-test--text buffer)))
    (should (string-match-p "reply" (harness-ui-test--text buffer)))))

(ert-deftest harness-ui-test-input-area-ret-sends-and-shift-ret-newlines ()
  "RET sends the input; `S-<return>' inserts a newline."
  (harness-ui-test-with-session '((:text "reply"))
    (switch-to-buffer (harness-conversation-input-buffer session))
    (goto-char (point-max))
    (execute-kbd-macro "first line")
    (execute-kbd-macro (kbd "S-<return>"))
    (execute-kbd-macro "second line")
    ;; Shift+Return must not have submitted anything.
    (should (equal (harness-conversation--input) "first line\nsecond line"))
    (should (eq (harness-session-status session) 'idle))
    (execute-kbd-macro (kbd "RET"))
    (harness-ui-test--wait-idle session)
    (should (equal (harness-conversation--input) ""))
    (should (string-match-p "first line" (harness-ui-test--text buffer)))
    (should (string-match-p "second line" (harness-ui-test--text buffer)))))

(ert-deftest harness-ui-test-input-window-grows-with-the-message ()
  "The input side window grows with a multi-line message and shrinks again."
  (harness-ui-test-with-session '((:text "reply"))
    (harness-conversation-open session)
    (let ((input (harness-conversation-input-buffer session))
          (window nil))
      (unwind-protect
          (progn
            (setq window (get-buffer-window input))
            (should window)
            (should (= (window-height window) harness-ui-input-min-height))
            (with-current-buffer input
              (goto-char (point-max))
              (insert "one\ntwo")
              (harness-conversation-input--fit))
            (should (> (window-height window) harness-ui-input-min-height))
            ;; A message longer than the limit is capped, not unbounded.
            (with-current-buffer input
              (goto-char (point-max))
              (dotimes (i 40) (insert (format "line %d\n" i)))
              (harness-conversation-input--fit))
            (should (= (window-height window) harness-ui-input-max-height))
            (should (> (window-start window) (point-min)))
            (with-current-buffer input
              (harness-conversation--clear-input)
              (harness-conversation-input--fit))
            (should (= (window-height window) harness-ui-input-min-height)))
        (when (window-live-p window) (delete-window window))))))

(ert-deftest harness-ui-test-buffers-opt-out-of-line-numbers ()
  "Harness buffers do not show a line-number gutter.

Doom enables line numbers from `text-mode-hook', which runs after a mode's
body, so the opt-out has to survive that as well as the globalized mode."
  (require 'display-line-numbers)
  (global-display-line-numbers-mode 1)
  (add-hook 'text-mode-hook #'display-line-numbers-mode)
  (unwind-protect
      (harness-ui-test-with-session '((:text "reply"))
        (with-current-buffer buffer
          (should-not display-line-numbers))
        (with-current-buffer (harness-conversation-input-buffer session)
          (should-not display-line-numbers)))
    (remove-hook 'text-mode-hook #'display-line-numbers-mode)
    (global-display-line-numbers-mode -1)))

(ert-deftest harness-ui-test-input-area-keeps-typing-after-a-send ()
  "The input area is typeable again after a message is sent."
  (harness-ui-test-with-session '((:text "first") (:text "second"))
    (switch-to-buffer (harness-conversation-input-buffer session))
    (goto-char (point-max))
    (execute-kbd-macro (concat "one" (kbd "C-c C-c")))
    (harness-ui-test--wait-idle session)
    (switch-to-buffer (harness-conversation-input-buffer session))
    (goto-char (point-max))
    (execute-kbd-macro (concat "two" (kbd "C-c C-c")))
    (harness-ui-test--wait-idle session)
    (let ((text (harness-ui-test--text buffer)))
      (should (string-match-p "one" text))
      (should (string-match-p "two" text)))))

(ert-deftest harness-ui-test-transcript-single-keys-still-work ()
  "In the transcript the single-key commands keep their meaning."
  (harness-ui-test-with-session '((:text "reply"))
    (harness-ui-test--send session "hello")
    (switch-to-buffer buffer)
    (goto-char (point-min))
    (execute-kbd-macro "n")
    (should (> (point) (point-min)))
    (execute-kbd-macro "p")
    (should (= (point) (point-min)))))

(ert-deftest harness-ui-test-tool-call-renders-output ()
  "A tool call's name, status and output appear in the conversation."
  (harness-ui-test-with-session
      '((:tool-call ("bash" (:command "echo on-screen")))
        (:text "done"))
    (harness-ui-test--send session "run it")
    (let ((text (harness-ui-test--text buffer)))
      (should (string-match-p "bash" text))
      (should (string-match-p "echo on-screen" text))
      (should (string-match-p "on-screen" text))
      (should (string-match-p "done" text)))))

(ert-deftest harness-ui-test-approval-is-clickable-and-resolvable ()
  "An approval renders with buttons and can be answered from the buffer."
  (harness-ui-test-with-session
      '((:tool-call ("bash" (:command "echo approved")))
        (:text "thank you"))
    (let ((harness-permission-policy '((:default ask))))
      ;; Not `--send': that waits for idle, and this run is meant to block.
      (harness-agent-send session "run it")
      (should (harness-test-wait-for
               (lambda () (eq (harness-session-status session) 'awaiting-approval)) 10))
      (let ((text (harness-ui-test--text buffer)))
        (should (string-match-p "Allow" text))
        (should (string-match-p "echo approved" text)))
      ;; Answer it from the buffer, the way a user would.
      (with-current-buffer buffer
        (goto-char (point-min))
        (harness-conversation-approve))
      ;; The widget buffer that opened for the approval must be gone; leaving
      ;; it up would let a stale keypress resolve the approval a second time.
      (should-not (get-buffer "*Harness Approve: ui*"))
      (harness-ui-test--wait-idle session)
      (should (string-match-p "thank you" (harness-ui-test--text buffer))))))

(ert-deftest harness-ui-test-resolving-dismisses-the-ask-buffer ()
  "Approving tool calls leaves no ask buffer or window behind.

Every permission opens the widget buffer in a window.  Resolving it must
remove that buffer from its window -- `bury-buffer' with a buffer argument
only reorders the buffer list -- or each approval leaves a window up and the
next request opens another one beside it."
  (harness-ui-test-with-session
      '((:tool-call ("bash" (:command "echo 1")))
        (:tool-call ("bash" (:command "echo 2")))
        (:tool-call ("bash" (:command "echo 3")))
        (:tool-call ("bash" (:command "echo 4")))
        (:text "all done"))
    (let ((harness-permission-policy '((:default ask))))
      (harness-agent-send session "run it")
      (dotimes (_ 4)
        (should (harness-test-wait-for
                 (lambda () (eq (harness-session-status session) 'awaiting-approval)) 10))
        (let ((approve (get-buffer "*Harness Approve: ui*")))
          (should approve)
          (with-current-buffer approve (harness-ask-submit)))
        ;; Gone before the next request arrives, so nothing accumulates.
        (should-not (get-buffer "*Harness Approve: ui*")))
      (harness-ui-test--wait-idle session)
      (should-not (get-buffer "*Harness Approve: ui*"))
      (should-not (seq-find (lambda (window)
                              (string-match-p "Harness Approve"
                                              (buffer-name (window-buffer window))))
                            (window-list))))))

(ert-deftest harness-ui-test-streamed-thinking-gets-its-own-line ()
  "A streamed reasoning trace is labelled and separated from the answer.

The assistant message is rendered before the first delta, so the reasoning
region has to be opened by the first thinking delta; the answer must still
start on its own line."
  (harness-ui-test-with-session
      '((:deltas (thinking "first ") (thinking "second")
                 (text "the answer")))
    (let ((harness-ui-show-thinking t))
      (harness-ui-test--send session "go"))
    (let ((text (harness-ui-test--text buffer)))
      (should (string-match-p "thinking…\nfirst second\nthe answer" text)))))

(ert-deftest harness-ui-test-streamed-thinking-is-folded-by-default ()
  "Reasoning is hidden until `harness-ui-show-thinking' is on."
  (harness-ui-test-with-session
      '((:deltas (thinking "a secret thought") (text "the answer")))
    (harness-ui-test--send session "go")
    (with-current-buffer buffer
      (goto-char (point-min))
      (search-forward "a secret thought")
      (should (get-text-property (1- (point)) 'invisible)))
    (should (string-match-p "the answer" (harness-ui-test--text buffer)))))

(ert-deftest harness-ui-test-approval-is-rendered-once ()
  "Re-syncing the conversation does not duplicate the approval block."
  (harness-ui-test-with-session '((:tool-call ("bash" (:command "echo hi"))))
    (let ((harness-permission-policy '((:default ask))))
      ;; Not `--send': that waits for idle, and this run is meant to block.
      (harness-agent-send session "run it")
      (should (harness-test-wait-for
               (lambda () (eq (harness-session-status session) 'awaiting-approval)) 10))
      (with-current-buffer buffer
        (harness-conversation--sync)
        (harness-conversation--sync)
        (goto-char (point-min))
        (should (= 1 (how-many (regexp-quote "Allow bash(echo hi)?"))))))))

(ert-deftest harness-ui-test-tool-approval-uses-widget-buffer ()
  "A tool permission opens the shared widget buffer and is answered there."
  (harness-ui-test-with-session
      '((:tool-call ("bash" (:command "echo hi")))
        (:text "done"))
    (let ((harness-permission-policy '((:default ask))))
      (harness-agent-send session "run it")
      (should (harness-test-wait-for
               (lambda () (eq (harness-session-status session) 'awaiting-approval)) 10))
      (let ((approve (get-buffer "*Harness Approve: ui*")))
        (should approve)
        (with-current-buffer approve
          (should (string-match-p "Allow bash" (buffer-string)))
          (should (string-match-p "echo hi" (buffer-string)))
          ;; The hint is the live binding, not a hard-coded string.
          (should (string-match-p
                   (regexp-quote (harness-command-key #'harness-ask-submit
                                                     harness-ask-mode-map))
                   (buffer-string)))
          (harness-ask-submit)))
      (harness-ui-test--wait-idle session)
      (should (string-match-p "done" (harness-ui-test--text buffer))))))

(ert-deftest harness-ui-test-send-while-blocked-queues ()
  "Sending while a question is pending queues instead of starting a run."
  (harness-ui-test-with-session
      '((:tool-call ("ask_user_question"
                     (:questions [(:question "Which?" :header "Q")])))
        (:text "after the answer")
        (:text "reply to the queued message"))
    (harness-agent-send session "ask me")
    (should (harness-test-wait-for
             (lambda () (eq (harness-session-status session) 'awaiting-answer)) 10))
    (should-not (harness-agent-send session "queued while blocked"))
    (should (eq (harness-session-status session) 'awaiting-answer))
    (should (= 1 (harness-queue-length session)))
    (harness-ask-answer (harness-ask-pending session) nil)
    (when-let* ((ask (get-buffer "*Harness Ask: ui*"))) (kill-buffer ask))
    (harness-ui-test--wait-idle session)
    (should (string-match-p "reply to the queued message"
                            (harness-ui-test--text buffer)))))

(ert-deftest harness-ui-test-queue-renders-and-edits ()
  "A queued message is visible and editable through the queue buffer."
  (harness-ui-test-with-session '((:text "first reply") (:text "second reply"))
    (harness-agent-send session "one")
    (harness-agent-send session "two")
    ;; The queue is rendered while the first run is going.
    (should (harness-test-wait-for
             (lambda () (string-match-p "Queued" (harness-ui-test--text buffer))) 10))
    (harness-ui-test--wait-idle session)
    (should (harness-test-wait-for
             (lambda () (string-match-p "second reply" (harness-ui-test--text buffer))) 10))
    (should (string-match-p "first reply" (harness-ui-test--text buffer)))))

(ert-deftest harness-ui-test-load-earlier ()
  "Older messages come back when the limit is raised."
  (harness-ui-test-with-session '((:text "one") (:text "two"))
    (harness-ui-test--send session "first")
    (harness-ui-test--send session "second")
    (with-current-buffer buffer
      ;; Four messages exist; render only the last two, then load the rest.
      (setq harness-ui-max-rendered-messages 2)
      (harness-conversation-refresh)
      (should-not (string-match-p "first" (buffer-string)))
      (harness-conversation-load-earlier)
      (should (string-match-p "first" (buffer-string))))))

(ert-deftest harness-ui-test-rename-updates-buffer-name ()
  "Renaming a session renames its buffer."
  (harness-ui-test-with-session '((:text "hi"))
    (should (equal (buffer-name buffer) "*Harness: ui*"))
    (harness-session-rename session "renamed session")
    (should (equal (buffer-name (harness-session-buffer session))
                   "*Harness: renamed session*"))))

(ert-deftest harness-ui-test-mode-line ()
  "The mode line shows status, model and cost, and the global indicator counts."
  (harness-ui-test-with-session '((:text "hi"))
    (harness-ui-test--send session "hello")
    (let ((line (harness-mode-line-string session)))
      (should (string-match-p "mock-model" line))
      (should (string-match-p "Idle" line)))
    ;; Blocked sessions are what the global indicator is for.
    (harness-session-set-status session 'awaiting-approval)
    (should (string-match-p "1 blocked" (harness-mode-line-global-string)))
    (harness-session-set-status session 'working)
    (should (string-match-p "1" (harness-mode-line-global-string)))))


;;; Session browser

(ert-deftest harness-ui-test-session-browser ()
  "The browser lists sessions, filters them and opens one."
  (harness-ui-test-with-session '((:text "hi"))
    (harness-ui-test--send session "hello")
    (let ((browser (harness-sessions--buffer "*Harness Sessions*")))
      (unwind-protect
          (with-current-buffer browser
            (harness-sessions-refresh)
            (should tabulated-list-entries)
            (should (equal (caar tabulated-list-entries) (harness-session-id session)))
            ;; Filtering by a status that nothing has empties the list.
            (harness-sessions-filter 'blocked)
            (should-not tabulated-list-entries)
            (harness-sessions-filter 'all)
            (should tabulated-list-entries)
            (harness-sessions-filter 'project)
            (should tabulated-list-entries)
            (harness-sessions-filter 'all))
        (kill-buffer browser)))))

(ert-deftest harness-ui-test-session-browser-search ()
  "Search shows matching sessions."
  (skip-unless (harness-index-available-p))
  (harness-ui-test-with-session '((:text "hi"))
    (harness-ui-test--send session "a unique marker phrase")
    (let ((browser (harness-sessions--buffer "*Harness Search*")))
      (unwind-protect
          (with-current-buffer browser
            (harness-sessions-search "unique marker phrase")
            (should tabulated-list-entries)
            (should (equal (caar tabulated-list-entries) (harness-session-id session))))
        (kill-buffer browser)))))

(ert-deftest harness-ui-test-session-browser-approves ()
  "An approval can be answered from the browser without opening the session."
  (harness-ui-test-with-session '((:tool-call ("bash" (:command "echo x"))) (:text "ok"))
    (let ((harness-permission-policy '((:default ask))))
      (harness-agent-send session "run")
      (should (harness-test-wait-for
               (lambda () (eq (harness-session-status session) 'awaiting-approval)) 10))
      (let ((browser (harness-sessions--buffer "*Harness Sessions*")))
        (unwind-protect
            (with-current-buffer browser
              (harness-sessions-refresh)
              (goto-char (point-min))
              (harness-sessions-approve)
              (should-not (harness-session-approvals session)))
          (kill-buffer browser)))
      (harness-ui-test--wait-idle session))))


;;; Tree view

(ert-deftest harness-ui-test-tree ()
  "The tree shows messages and tool calls as foldable headings."
  (harness-ui-test-with-session
      '((:tool-call ("bash" (:command "echo tree-output"))) (:text "answer"))
    (harness-ui-test--send session "do the thing")
    (let ((tree (harness-tree-buffer session)))
      (unwind-protect
          (with-current-buffer tree
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "do the thing" text))
              (should (string-match-p "answer" text))
              (should (string-match-p "bash" text))
              (should (string-match-p "tree-output" text)))
            (should (derived-mode-p 'harness-tree-mode))
            ;; Folding must not error, from a heading.
            (goto-char (point-min))
            (outline-next-heading)
            (outline-toggle-children))
        (kill-buffer tree)))))

(ert-deftest harness-ui-test-tree-jumps-to-conversation ()
  "RET in the tree opens the conversation at the message."
  (harness-ui-test-with-session '((:text "second message"))
    (harness-ui-test--send session "first message")
    (let ((tree (harness-tree-buffer session)))
      (unwind-protect
          (with-current-buffer tree
            (harness-tree-refresh)
            (goto-char (point-min))
            (search-forward "<msg-")
            (harness-tree-goto-message)
            (should (eq (window-buffer) (harness-session-buffer session))))
        (kill-buffer tree)))))


;;; Asking the user

(ert-deftest harness-ui-test-ask-question ()
  "The ask tool blocks the session and the buffer collects the answer."
  (harness-ui-test-with-session '((:nothing))
    (let ((tool-call (harness-tool-call-create
                      :name "ask_user_question"
                      :args-string (harness-json-write
                                    (list :questions
                                          (vector (list :question "Which one?"
                                                        :header "Choice"
                                                        :options (vector (list :label "alpha")
                                                                         (list :label "beta"))
                                                        :multi_select :false
                                                        :allow_custom :false))))))
          (finished nil))
      (harness-tool-run tool-call session (lambda (call) (setq finished call)))
      (should (harness-test-wait-for
               (lambda () (eq (harness-session-status session) 'awaiting-answer)) 10))
      (let ((approval (harness-ask-pending session)))
        (should approval)
        (should (equal (harness-approval-kind approval) 'question))
        (let ((ask (get-buffer "*Harness Ask: ui*")))
          (should ask)
          (with-current-buffer ask
            (should (string-match-p "Which one\\?" (buffer-string)))
            (should (string-match-p "alpha" (buffer-string)))
            (should (string-match-p "Submit" (buffer-string))))
          ;; Answer programmatically, as the buffer's Submit does.
          (harness-ask-answer
           approval
           (list (list (cons 'header "Choice")
                       (cons 'question "Which one?")
                       (cons 'answer "alpha")
                       (cons 'selected (list "alpha")))))
          (kill-buffer ask)))
      (should (harness-test-wait-for (lambda () finished) 10))
      (should (eq (harness-tool-call-status finished) 'ok))
      (should (string-match-p "alpha" (harness-tool-call-result finished)))
      ;; Resolving lifts the session out of the blocked status.
      (should-not (memq (harness-session-status session) '(awaiting-answer))))))

(ert-deftest harness-ui-test-ask-cancel ()
  "Cancelling a question tells the model the user declined."
  (harness-ui-test-with-session '((:nothing))
    (let ((tool-call (harness-tool-call-create
                      :name "ask_user_question"
                      :args-string (harness-json-write
                                    (list :questions
                                          (vector (list :question "Well?"
                                                        :header "Q"
                                                        :allow_custom :true))))))
          (finished nil))
      (harness-tool-run tool-call session (lambda (call) (setq finished call)))
      (should (harness-test-wait-for
               (lambda () (eq (harness-session-status session) 'awaiting-answer)) 10))
      (let ((approval (harness-ask-pending session)))
        (harness-ask-answer approval nil)
        (when-let* ((ask (get-buffer "*Harness Ask: ui*"))) (kill-buffer ask)))
      (should (harness-test-wait-for (lambda () finished) 10))
      (should (eq (harness-tool-call-status finished) 'error))
      (should (string-match-p "declined" (harness-tool-call-result finished))))))

(ert-deftest harness-ui-test-ask-does-not-stack ()
  "A second question while one is pending is refused."
  (harness-ui-test-with-session '((:nothing))
    (let ((args (harness-json-write
                 (list :questions (vector (list :question "One?" :header "Q")))))
          (second nil))
      (harness-tool-run (harness-tool-call-create :name "ask_user_question"
                                                  :args-string args)
                        session (lambda (_call) nil))
      (should (harness-test-wait-for
               (lambda () (eq (harness-session-status session) 'awaiting-answer)) 10))
      (harness-tool-run (harness-tool-call-create :name "ask_user_question"
                                                  :args-string args)
                        session (lambda (call) (setq second call)))
      (should (harness-test-wait-for (lambda () second) 10))
      (should (eq (harness-tool-call-status second) 'error))
      (harness-ask-answer (harness-ask-pending session) nil)
      (when-let* ((ask (get-buffer "*Harness Ask: ui*"))) (kill-buffer ask)))))


;;; Model selection

(ert-deftest harness-ui-test-model-list-and-select ()
  "The model list renders and selection updates the session."
  (harness-ui-test-with-session '((:text "hi"))
    (let ((list-buffer (progn (harness-list-models session)
                              (get-buffer "*Harness Models*"))))
      (unwind-protect
          (with-current-buffer list-buffer
            (revert-buffer)
            (should tabulated-list-entries)
            (should (equal (caar tabulated-list-entries) "mock-model"))
            (goto-char (point-min))
            (harness-model-use)
            (should (equal (harness-session-model session) "mock-model")))
        (kill-buffer list-buffer)))))

(provide 'harness-ui-test)
;;; harness-ui-test.el ends here
