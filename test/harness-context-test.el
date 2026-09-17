;;; harness-context-test.el --- Tests for long context handling -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Noah Huppert

;; This file is not part of GNU Emacs.

;;; Code:

(require 'ert)
(require 'harness-context)
(require 'harness-mock-provider)
(require 'harness-test-util)

(defmacro harness-context-test-with-session (script &rest body)
  "Run BODY with a session whose provider plays SCRIPT."
  (declare (indent 1))
  `(harness-test-with-temp-session-dir
     (let* ((harness-permission-policy '((:default allow)))
            (harness-providers (list (list :name 'mock :kind 'harness-test
                                           :script ,script)))
            (harness-models '((:provider mock :id "mock-model"
                              :context-window 1000)))
            (default-directory (file-name-as-directory harness-test--directory))
            (session (harness-session-create '(:name "context" :model "mock-model"
                                                        :provider mock))))
       (harness-provider-setup)
       ,@body)))

(defun harness-context-test--add (session text &optional role)
  "Append a message with TEXT to SESSION."
  (let ((message (harness-message-create session (or role 'user) text)))
    (harness-message-finalize message)
    (harness-session-add-message session message)
    message))

(ert-deftest harness-context-test-sizing ()
  "Token estimation is proportional to size and cached per message."
  (harness-context-test-with-session '((:nothing))
    (let ((message (harness-context-test--add session (make-string 400 ?x))))
      (should (>= (harness-context-message-chars message) 400))
      (should (equal (plist-get (harness-message-meta message) :chars)
                     (harness-context-message-chars message)))
      ;; The cache is used, not recomputed.
      (setf (harness-message-content message) "short")
      (should (>= (harness-context-message-chars message) 400))
      (should (> (harness-context-tokens session) 0)))))

(ert-deftest harness-context-test-budget-and-ratio ()
  "The budget comes from the model's window minus the reserve."
  (harness-context-test-with-session '((:nothing))
    (let ((harness-context-reserve-tokens 200))
      (should (= (harness-context-budget session) 800)))
    (harness-context-test--add session (make-string 3200 ?x))
    (should (> (harness-context-ratio session) 0.9))
    (should (string-match-p "%" (harness-context-stats-string session)))))

(ert-deftest harness-context-test-build-messages-keeps-recent ()
  "Building the request drops the oldest messages when they do not fit."
  (harness-context-test-with-session '((:nothing))
    (let ((harness-context-reserve-tokens 100)
          (harness-context-keep-recent 2))
      ;; Each message is about 250 tokens with a 900 token budget.
      (dotimes (i 10)
        (harness-context-test--add session (make-string 1000 (+ ?a i))))
      (let ((built (harness-context-build-messages session)))
        (should (< (length built) 10))
        (should (<= (length built) 5))
        ;; A note says the transcript is windowed, and the note is a message.
        (should (eq (harness-message-role (car built)) 'system))
        (should (string-match-p "omitted" (harness-message-content (car built))))))))

(ert-deftest harness-context-test-compaction ()
  "Compacting stores a summary and stops sending what it covers."
  (harness-context-test-with-session '((:text "The user asked for a fix; the file was changed.") (:text "reply"))
    (let ((harness-context-keep-recent 1))
      (dotimes (i 6)
        (harness-context-test--add session (format "message %d" i)))
      (let ((done nil))
        (harness-context-compact session (lambda (summary) (setq done summary)))
        (should (harness-test-wait-for (lambda () done) 10)))
      (should (harness-context-summary session))
      (should (> (harness-context-summarised-upto session) 0))
      ;; The request no longer contains the summarised messages.
      (let ((built (harness-context-build-messages session)))
        (should (< (length built) 6))
        (should (equal (harness-message-content (car built)) "message 5")))
      ;; And the summary reaches the model through the system prompt.
      (should (string-match-p "Summary of the conversation"
                              (harness-provider-system-prompt session))))))

(ert-deftest harness-context-test-compaction-failure-is-remembered ()
  "A failed compaction is not retried on the very next turn."
  (harness-context-test-with-session '((:error "summariser is down"))
    (let ((harness-context-keep-recent 1))
      (dotimes (_ 6)
        (harness-context-test--add session (make-string 500 ?x)))
      (let ((done nil))
        (harness-context-compact session (lambda (_summary) (setq done t)))
        (should (harness-test-wait-for (lambda () done) 10)))
      (should-not (harness-context-summary session))
      (should (plist-get (harness-session-meta session) :summary-error-at))
      (should-not (harness-context-needs-compaction-p session)))))

(ert-deftest harness-context-test-needs-compaction ()
  "Compaction is only wanted when the context is actually full."
  (harness-context-test-with-session '((:nothing))
    (let ((harness-context-auto-compact t)
          (harness-context-reserve-tokens 100)
          (harness-context-keep-recent 1))
      (harness-context-test--add session "small")
      (should-not (harness-context-needs-compaction-p session))
      (dotimes (_ 8)
        (harness-context-test--add session (make-string 1000 ?x)))
      (should (harness-context-needs-compaction-p session))
      (let ((harness-context-auto-compact nil))
        (should-not (harness-context-needs-compaction-p session))))))

(ert-deftest harness-context-test-auto-compaction-runs-first ()
  "A run that is over budget compacts before it asks the model."
  (harness-context-test-with-session
      '((:text "summary of the old messages") (:text "the answer"))
    (let ((harness-context-reserve-tokens 100)
          (harness-context-keep-recent 1)
          (harness-context-compact-at 0.5))
      (dotimes (_ 8)
        (harness-context-test--add session (make-string 1000 ?x)))
      (harness-agent-send session "carry on")
      (should (harness-test-wait-for
               (lambda () (memq (harness-session-status session) '(idle))) 20))
      ;; Two requests: the compaction, then the real one.
      (should (= (length (harness-test-provider-requests (harness-provider-default)))
                 2))
      (should (harness-context-summary session))
      (should (equal (harness-message-content (harness-session-last-message session))
                     "the answer")))))

(ert-deftest harness-context-test-search ()
  "Search finds matches in content, thinking and tool output."
  (harness-context-test-with-session '((:nothing))
    (harness-context-test--add session "nothing to see")
    (let ((with-thinking (harness-context-test--add session "visible text")))
      (setf (harness-message-thinking with-thinking) "a hidden needle here"))
    (let ((with-tool (harness-message-create session 'assistant "")))
      (setf (harness-message-tool-calls with-tool)
            (list (harness-tool-call-create :name "bash" :args-string "{}"
                                            :status 'ok :result "tool needle")))
      (harness-message-finalize with-tool)
      (harness-session-add-message session with-tool))
    (let ((results nil))
      (harness-context-search session "needle" (lambda (found) (setq results found)))
      (should (harness-test-wait-for (lambda () results) 10))
      (should (= (length results) 2))
      (should (seq-some (lambda (result) (eq (plist-get result :field) 'thinking)) results))
      (should (seq-some (lambda (result) (eq (plist-get result :field) 'tool)) results))
      (should (string-match-p "needle" (plist-get (car results) :text))))))

(ert-deftest harness-context-test-search-chunks ()
  "A long transcript is searched without examining everything at once."
  (harness-context-test-with-session '((:nothing))
    (let ((harness-context-search-chunk 5)
          (ticks 0))
      (dotimes (i 40)
        (harness-context-test--add session (format "line %d" i)))
      (let ((results nil))
        (harness-context-search session "line 39" (lambda (found) (setq results found)))
        ;; The first chunk cannot have finished the search.
        (should (= (length results) 0))
        (should (harness-test-wait-for (lambda () results) 10))
        (should (= (length results) 1))
        (ignore ticks)))))

(provide 'harness-context-test)
;;; harness-context-test.el ends here
