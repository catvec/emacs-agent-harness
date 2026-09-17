;;; harness-agent-test.el --- Tests for the run loop -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Noah Huppert

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Everything here runs against `harness-mock-provider', so a full
;; request/tool/request cycle is exercised without a network.

;;; Code:

(require 'ert)
(require 'harness-agent)
(require 'harness-mock-provider)
(require 'harness-test-util)

(defmacro harness-agent-test-with-session (script &rest body)
  "Run BODY with a session whose provider plays SCRIPT.
BODY can refer to `session'."
  (declare (indent 1))
  `(harness-test-with-temp-session-dir
     (let* ((harness-providers (list (list :name 'mock :kind 'harness-test
                                           :script ,script)))
            (harness-models '((:provider mock :id "mock-model"
                              :price-in 1.0 :price-out 2.0)))
            (harness-permission-policy '((:default allow)))
            (default-directory (file-name-as-directory harness-test--directory))
            (session (harness-session-create '(:name "test" :model "mock-model"
                                                     :provider mock))))
       (harness-provider-setup)
       (unwind-protect
           (progn ,@body)
         (harness-session-remove session)))))

(defun harness-agent-test--wait (session)
  "Wait until SESSION is idle again."
  (harness-test-wait-for
   (lambda () (memq (harness-session-status session) '(idle))) 20))

(defun harness-agent-test--messages (session)
  "Return (ROLE . CONTENT) pairs for SESSION."
  (mapcar (lambda (message)
            (cons (harness-message-role message) (harness-message-content message)))
          (harness-session-messages session)))

(ert-deftest harness-agent-test-simple-run ()
  "A plain reply lands in the transcript and the session goes idle."
  (harness-agent-test-with-session '((:text "hello there"))
    (harness-agent-send session "hi")
    (should (memq (harness-session-status session) '(working streaming)))
    (should (harness-agent-test--wait session))
    (should (equal (harness-agent-test--messages session)
                   '((user . "hi") (assistant . "hello there"))))
    (should (eq (harness-message-status (harness-session-last-message session)) 'complete))
    ;; Usage is recorded with a cost derived from the model's prices.
    (should (equal (plist-get (harness-session-usage session) :in) 10))
    (should (> (plist-get (harness-session-usage session) :cost) 0))))

(ert-deftest harness-agent-test-thinking ()
  "Reasoning deltas go to the message's thinking slot, not its content."
  (harness-agent-test-with-session '((:thinking "hmm " "done"))
    (harness-agent-send session "hi")
    (should (harness-agent-test--wait session))
    (let ((message (harness-session-last-message session)))
      (should (equal (harness-message-content message) "done"))
      (should (equal (harness-message-thinking message) "hmm ")))))

(ert-deftest harness-agent-test-tool-call-round-trip ()
  "A tool call runs, its output returns to the model, and the run continues."
  (harness-agent-test-with-session
      '((:tool-call ("bash" (:command "echo from-tool")))
        (:text "all done"))
    (harness-agent-send session "please run it")
    (should (harness-agent-test--wait session))
    (let ((roles (mapcar #'harness-message-role (harness-session-messages session))))
      (should (equal roles '(user assistant tool assistant))))
    (let* ((assistant (nth 1 (harness-session-messages session)))
           (call (car (harness-message-tool-calls assistant)))
           (tool-message (nth 2 (harness-session-messages session))))
      (should (eq (harness-tool-call-status call) 'ok))
      (should (string-match-p "from-tool" (harness-tool-call-result call)))
      (should (equal (harness-message-tool-call-id tool-message) (harness-tool-call-id call)))
      (should (string-match-p "from-tool" (harness-message-content tool-message))))
    ;; Two requests were made: one that asked for the tool, one that used it.
    (should (= (length (harness-test-provider-requests (harness-provider-default))) 2))))

(ert-deftest harness-agent-test-denied-tool ()
  "A denied tool call becomes an error result and the model is told."
  (harness-test-with-temp-session-dir
    (let* ((harness-providers '((:name mock :kind harness-test
                                 :script ((:tool-call ("bash" (:command "rm -rf /")))
                                          (:text "understood")))))
           (harness-models '((:provider mock :id "mock-model")))
           (harness-permission-policy '((:default deny)))
           (session (harness-session-create '(:name "deny" :model "mock-model"
                                                     :provider mock))))
      (harness-provider-setup)
      (harness-agent-send session "do it")
      (harness-test-wait-for (lambda () (memq (harness-session-status session) '(idle))) 20)
      (let* ((assistant (nth 1 (harness-session-messages session)))
             (call (car (harness-message-tool-calls assistant)))
             (tool-message (nth 2 (harness-session-messages session))))
        (should (eq (harness-tool-call-status call) 'denied))
        (should (string-match-p "denied" (harness-message-content tool-message))))
      (should (equal (harness-message-content (harness-session-last-message session))
                     "understood")))))

(ert-deftest harness-agent-test-approval-resumes ()
  "With a rule of `ask' the run suspends until the approval is answered."
  (harness-test-with-temp-session-dir
    (let* ((harness-providers '((:name mock :kind harness-test
                                 :script ((:tool-call ("bash" (:command "echo approved")))
                                          (:text "thanks")))))
           (harness-models '((:provider mock :id "mock-model")))
           (harness-permission-policy '((:default ask)))
           (session (harness-session-create '(:name "ask" :model "mock-model"
                                                     :provider mock))))
      (harness-provider-setup)
      (harness-agent-send session "run it")
      (should (harness-test-wait-for
               (lambda () (eq (harness-session-status session) 'awaiting-approval)) 10))
      (let ((approval (car (harness-approval-pending session))))
        (should approval)
        (should (equal (harness-approval-kind approval) 'tool))
        (should (string-match-p "bash" (harness-approval-prompt approval)))
        (harness-perms-resolve approval 'allow))
      (should (harness-test-wait-for
               (lambda () (memq (harness-session-status session) '(idle))) 20))
      (should (equal (harness-message-content (harness-session-last-message session))
                     "thanks"))
      (let* ((assistant (nth 1 (harness-session-messages session)))
             (call (car (harness-message-tool-calls assistant))))
        (should (eq (harness-tool-call-status call) 'ok))))))

(ert-deftest harness-agent-test-approval-always-remembers ()
  "Answering `allow-always' adds a pinned rule for that exact command."
  (harness-test-with-temp-session-dir
    (let* ((harness-providers '((:name mock :kind harness-test
                                 :script ((:tool-call ("bash" (:command "echo once")))))))
           (harness-models '((:provider mock :id "mock-model")))
           (harness-permission-policy '((:default ask)))
           (harness-permission-rules nil)
           (harness-permission-rules-file nil)
           (session (harness-session-create '(:name "always" :model "mock-model"
                                                     :provider mock))))
      (harness-provider-setup)
      (harness-agent-send session "run it")
      (should (harness-test-wait-for
               (lambda () (eq (harness-session-status session) 'awaiting-approval)) 10))
      (harness-perms-resolve (car (harness-approval-pending session)) 'allow-always)
      (harness-test-wait-for (lambda () (memq (harness-session-status session) '(idle))) 20)
      (should (= (length harness-permission-rules) 1))
      (let ((rule (car harness-permission-rules)))
        (should (equal (harness-plist-or-alist-get :tool rule) "bash"))
        (should (equal (harness-plist-or-alist-get :action rule) 'allow))
        (should (equal (harness-permission-check
                        (harness-tool-call-create
                         :name "bash" :args-string "{\"command\":\"echo once\"}")
                        session)
                       'allow))
        ;; A different command is still asked about.
        (should (equal (harness-permission-check
                        (harness-tool-call-create
                         :name "bash" :args-string "{\"command\":\"echo twice\"}")
                        session)
                       'ask))))))

(ert-deftest harness-agent-test-queue-drains ()
  "A message sent while the session is busy runs when the run finishes."
  (harness-agent-test-with-session '((:text "first") (:text "second"))
    (harness-agent-send session "one")
    (harness-agent-send session "two")
    (should (= (harness-queue-length session) 1))
    (should (harness-test-wait-for
             (lambda () (and (memq (harness-session-status session) '(idle))
                             (= (length (harness-session-messages session)) 4)))
             20))
    (should (= (harness-queue-length session) 0))
    (should (equal (harness-agent-test--messages session)
                   '((user . "one") (assistant . "first")
                     (user . "two") (assistant . "second"))))))

(ert-deftest harness-agent-test-error-is-recorded ()
  "A failed request is recorded on the message and the session goes idle."
  (harness-agent-test-with-session '((:error "the gateway exploded"))
    (harness-agent-send session "hi")
    (should (harness-agent-test--wait session))
    (let ((message (harness-session-last-message session)))
      (should (eq (harness-message-status message) 'error))
      (should (string-match-p "exploded" (harness-message-error message)))
      (should (string-match-p "the gateway exploded"
                              (or (plist-get (harness-session-status-detail session) :label)
                                  ""))))))

(ert-deftest harness-agent-test-abort ()
  "Aborting a run stops it and marks the open message."
  (harness-agent-test-with-session '((:text "never delivered"))
    (harness-agent-send session "hi")
    (harness-agent-abort session)
    (should (memq (harness-session-status session) '(idle)))
    (should (harness-test-provider-cancelled (harness-provider-default)))))

(ert-deftest harness-agent-test-max-iterations ()
  "A model that always asks for a tool stops at the iteration cap."
  (harness-test-with-temp-session-dir
    (let* ((harness-providers (list (list :name 'mock :kind 'harness-test
                                          :script (cl-loop for i below 6
                                                           collect (list :tool-call
                                                                         (list "bash"
                                                                               (list :command
                                                                                     "true")))))))
           (harness-models '((:provider mock :id "mock-model")))
           (harness-permission-policy '((:default allow)))
           (harness-agent-max-iterations 3)
           (session (harness-session-create '(:name "loop" :model "mock-model"
                                                     :provider mock))))
      (harness-provider-setup)
      (harness-agent-send session "go")
      (should (harness-test-wait-for
               (lambda () (memq (harness-session-status session) '(idle))) 30))
      (should (string-match-p "Stopped after 3 iterations"
                              (harness-message-content
                               (harness-session-last-message session)))))))

(ert-deftest harness-agent-test-text-tool-protocol ()
  "A provider without native tools can request one with a fenced block."
  (harness-test-with-temp-session-dir
    (let* ((harness-providers
            '((:name mock :kind harness-test
               :capabilities (:tools nil)
               :script ((:text "sure:\n\n```tool\n{\"name\": \"bash\", \"arguments\": {\"command\": \"echo via-text\"}}\n```\n")
                        (:text "finished")))))
           (harness-models '((:provider mock :id "mock-model")))
           (harness-permission-policy '((:default allow)))
           (session (harness-session-create '(:name "text-tools" :model "mock-model"
                                                        :provider mock))))
      (harness-provider-setup)
      (harness-agent-send session "run something")
      (should (harness-test-wait-for
               (lambda () (memq (harness-session-status session) '(idle))) 20))
      (let ((call (car (harness-message-tool-calls
                        (nth 1 (harness-session-messages session))))))
        (should call)
        (should (equal (harness-tool-call-name call) "bash"))
        (should (equal (harness-tool-call-arg call :command) "echo via-text")))
      ;; The fenced block is removed from the visible transcript.
      (should-not (string-match-p "```tool"
                                  (harness-message-content
                                   (nth 1 (harness-session-messages session)))))
      (should (equal (harness-message-content (harness-session-last-message session))
                     "finished")))))

(ert-deftest harness-agent-test-system-prompt-includes-context ()
  "The system prompt carries the project and, when needed, the tool list."
  (harness-agent-test-with-session '((:text "ok"))
    (harness-agent-send session "hi")
    (should (harness-agent-test--wait session))
    (let* ((request (car (harness-test-provider-requests (harness-provider-default))))
           (prompt (harness-provider-request-system request)))
      (should (string-match-p "Working directory" prompt))
      ;; The mock advertises native tools, so no text protocol is appended.
      (should-not (string-match-p "fenced block" prompt)))))

(provide 'harness-agent-test)
;;; harness-agent-test.el ends here
