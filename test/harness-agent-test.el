;;; harness-agent-test.el --- Tests for the turn loop -*- lexical-binding: t; -*-

;;; Commentary:

;; The agent is tested against a scripted provider service and real session
;; storage.  No network, no model.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'harness-core)
(require 'harness-session)
(require 'harness-tools)
(require 'harness-agent)
(require 'harness-test-helpers)

(harness-module-load 'harness-tools)
(harness-module-load 'harness-session)
(harness-module-load 'harness-agent)

(defvar harness-agent-test--responses nil
  "Queue of response plists for the scripted provider.")

(defvar harness-agent-test--requests nil
  "Requests the scripted provider received, newest first.")

(defvar harness-agent-test--held nil
  "Deferred of the last held response.")

(defvar harness-agent-test--cancelled nil
  "Set when a held provider deferred was cancelled.")

(defvar harness-agent-test--models
  (vector (list :id "mock/mock-model" :name "Mock Model" :provider "mock"
                :context-window 100000)))

(defvar harness-agent-test--price nil
  "Cost plist returned by the fake provider's price method.")

(defun harness-agent-test--install-provider ()
  "Install the scripted provider service."
  (setq harness-agent-test--responses nil
        harness-agent-test--requests nil
        harness-agent-test--held nil
        harness-agent-test--cancelled nil)
  (harness-service-register
   "provider"
   :module 'harness-agent-test
   :methods
   (list
    (cons 'complete
          (lambda (request)
            (push request harness-agent-test--requests)
            (let* ((response (or (pop harness-agent-test--responses)
                                 (list :text "default" :stop-reason "end_turn")))
                   (deferred (harness-deferred-new)))
              (harness-deferred-on-cancel
               deferred (lambda () (setq harness-agent-test--cancelled t)))
              (dolist (delta (append (plist-get response :thought-deltas) nil))
                (when-let* ((callback (plist-get request :on-thought)))
                  (funcall callback delta)))
              (dolist (delta (append (plist-get response :text-deltas) nil))
                (when-let* ((callback (plist-get request :on-text)))
                  (funcall callback delta)))
              (cond
               ((plist-get response :hold)
                (setq harness-agent-test--held deferred))
               ((plist-get response :error)
                (run-at-time 0.001 nil
                             (lambda ()
                               (harness-deferred-reject
                                deferred (cons 'harness-provider-error
                                               (plist-get response :error))))))
               (t
                (run-at-time 0.001 nil
                             (lambda ()
                               (harness-deferred-resolve
                                deferred
                                (harness-plist-omit-nil
                                 (list :text (plist-get response :text)
                                       :thinking (plist-get response :thinking)
                                       :tool-calls (plist-get response :tool-calls)
                                       :stop-reason (or (plist-get response :stop-reason)
                                                        "end_turn")
                                       :usage (plist-get response :usage))))))))
              deferred)))
    (cons 'models (lambda (&rest _args) harness-agent-test--models))
    (cons 'price (lambda (&rest _args) harness-agent-test--price)))))

(defun harness-agent-test--install-tools ()
  "Register the tools the tests call."
  (harness-tool-register
   "echo"
   :description "Echo text."
   :schema '(:type "object" :properties (:text (:type "string")) :required ["text"])
   :kind 'read
   :read-only t
   :module 'harness-agent-test
   :handler (lambda (arguments _context) (format "echo:%s" (plist-get arguments :text)))))

(defvar harness-agent-test--storage nil)

(defmacro harness-agent-test--with-session (&rest body)
  "Run BODY with `test-session-id' in a fresh session and storage."
  (declare (indent 0))
  `(let* ((harness-agent-test--storage (make-temp-file "harness-agent-" t))
          (harness-session-storage-directory harness-agent-test--storage)
          (harness-agent-max-turn-requests 10)
          (harness-agent--model-cache harness-agent-test--models)
          (harness-agent-test--price nil)
          (directory (make-temp-file "harness-agent-project-" t))
          (harness-agent-test--responses nil)
          (harness-agent-test--requests nil))
     (unwind-protect
         (progn
           (clrhash harness-session--active)
           (clrhash harness-session--project-ids)
           (clrhash harness-agent--sessions)
           (harness-service-unregister "permission")
           (harness-agent-test--install-provider)
           (harness-agent-test--install-tools)
           (setq harness-agent--model-cache harness-agent-test--models)
           (let* ((info (harness-service-call "session" 'create
                                              :cwd directory
                                              :title "agent test"
                                              :model "mock/mock-model"))
                  (test-session-id (plist-get info :sessionId)))
             ,@body))
       (ignore-errors (delete-directory directory t)))))

(defun harness-agent-test--entries (session-id)
  "Return the transcript entries of SESSION-ID as a list."
  (let ((entries (harness-service-call "session" 'entries :session-id session-id)))
    (append (if (harness-deferred-p entries)
                (harness-deferred-value entries)
              entries)
            nil)))

(defun harness-agent-test--entry-text (entry)
  "Return the displayable text of one ENTRY."
  (let ((content (plist-get entry :content)))
    (cond
     ((vectorp content)
      (mapconcat (lambda (block)
                   (or (plist-get (plist-get block :content) :text)
                       (plist-get block :text)
                       ""))
                 (append content nil) ""))
     ((and (listp content) (plist-get content :type))
      (or (plist-get content :text) ""))
     (t (or (plist-get entry :title) "")))))

(defun harness-agent-test--texts (session-id)
  "Return the text of every transcript entry of SESSION-ID."
  (mapcar #'harness-agent-test--entry-text (harness-agent-test--entries session-id)))

(defun harness-agent-test--kinds (session-id)
  "Return the sessionUpdate kinds of SESSION-ID."
  (mapcar (lambda (entry) (plist-get entry :sessionUpdate))
          (harness-agent-test--entries session-id)))

(defun harness-agent-test--prompt (session-id text)
  "Send TEXT as a prompt to SESSION-ID.  Returns the deferred."
  (harness-service-call "agent" 'prompt
                        :session-id session-id
                        :prompt (vector (list :type "text" :text text))))

(ert-deftest harness-agent-plain-turn ()
  (harness-agent-test--with-session
    (setq harness-agent-test--responses
          (list (list :text "Hello there"
                      :text-deltas '("Hello " "there")
                      :thought-deltas '("hm")
                      :stop-reason "end_turn"
                      :usage '(:input-tokens 10 :output-tokens 4))))
    (let* ((deferred (harness-agent-test--prompt test-session-id "hi"))
           (reason (progn (harness-test-settle deferred 10)
                          (harness-deferred-value deferred))))
      (should (equal reason "end_turn"))
      (should (equal (harness-agent-test--kinds test-session-id)
                     '("user_message_chunk"
                       "agent_thought_chunk"
                       "agent_message_chunk"
                       ;; The per-call usage delta is kept as a timestamped
                       ;; transcript entry for budgets and the overview.
                       "usage_update")))
      (should (member "Hello there" (harness-agent-test--texts test-session-id)))
      (should (equal (plist-get (harness-service-call "session" 'info :session-id test-session-id)
                                :status)
                     "idle"))
      (should (equal (plist-get (harness-service-call "session" 'info :session-id test-session-id)
                                :usage)
                     '(:input 10 :output 4 :cache-read 0 :cache-write 0))))))

(ert-deftest harness-agent-non-streaming-response ()
  (harness-agent-test--with-session
    (setq harness-agent-test--responses (list (list :text "whole message")))
    (let ((deferred (harness-agent-test--prompt test-session-id "hi")))
      (harness-test-settle deferred 10)
      (should (member "whole message" (harness-agent-test--texts test-session-id))))))

(ert-deftest harness-agent-tool-call-loop ()
  (harness-agent-test--with-session
    (setq harness-agent-test--responses
          (list (list :tool-calls (vector (list :id "call-1" :name "echo"
                                                :arguments '(:text "hi")))
                      :stop-reason "tool_use")
                (list :text "finished" :stop-reason "end_turn")))
    (let ((deferred (harness-agent-test--prompt test-session-id "use the tool")))
      (harness-test-settle deferred 10)
      (should (equal (harness-deferred-value deferred) "end_turn"))
      (should (= (length harness-agent-test--requests) 2))
      (should (equal (harness-agent-test--kinds test-session-id)
                     '("user_message_chunk"
                       "tool_call"
                       "tool_call_update"
                       "tool_call_update"
                       "agent_message_chunk")))
      (let* ((entries (harness-agent-test--entries test-session-id))
             (completed (seq-find (lambda (entry)
                                    (equal (plist-get entry :status) "completed"))
                                  entries)))
        (should completed)
        (should (equal (plist-get completed :toolCallId) "call-1"))
        (should (string-match-p "echo:hi"
                                (harness-agent--result-text
                                 (list :content (plist-get completed :content))))))
      (should (member "finished" (harness-agent-test--texts test-session-id))))))

(ert-deftest harness-agent-permission-denial-becomes-tool-error ()
  (harness-agent-test--with-session
    (setq harness-agent-test--responses
          (list (list :tool-calls (vector (list :id "call-1" :name "echo"
                                                :arguments '(:text "hi"))))
                (list :text "ok")))
    (harness-service-register
     "permission"
     :module 'harness-agent-test
     :methods '((check . (lambda (&rest _args)
                           (let ((deferred (harness-deferred-new)))
                             (harness-deferred-resolve
                              deferred (list :decision 'deny :reason "not on my watch"))
                             deferred)))))
    (let ((deferred (harness-agent-test--prompt test-session-id "use the tool")))
      (harness-test-settle deferred 10)
      (let* ((entries (harness-agent-test--entries test-session-id))
             (tool-update (nth 2 entries)))
        (should (equal (plist-get tool-update :status) "failed"))
        (should (string-match-p "not on my watch"
                                (harness-agent--result-text
                                 (list :content (plist-get tool-update :content)))))))))

(ert-deftest harness-agent-permission-always-grants-directory ()
  (harness-agent-test--with-session
    (setq harness-agent-test--responses
          (list (list :tool-calls (vector (list :id "call-1" :name "echo"
                                                :arguments '(:text "hi"))))
                (list :text "ok")))
    (harness-service-register
     "permission"
     :module 'harness-agent-test
     :methods '((check . (lambda (&rest _args)
                           (let ((deferred (harness-deferred-new)))
                             (harness-deferred-resolve
                              deferred (list :decision 'allow :always t
                                             :paths (vector "/outside/dir/file.txt")))
                             deferred)))))
    (let ((deferred (harness-agent-test--prompt test-session-id "use the tool")))
      (harness-test-settle deferred 10)
      (should (member "/outside/dir/"
                      (plist-get (harness-service-call "session" 'info
                                                       :session-id test-session-id)
                                 :additionalDirectories))))))

(ert-deftest harness-agent-queues-prompts-until-turn-end ()
  (harness-agent-test--with-session
    (setq harness-agent-test--responses
          (list (list :hold t)
                (list :text "second turn")))
    (let* ((first (harness-agent-test--prompt test-session-id "first"))
           (second (harness-agent-test--prompt test-session-id "second")))
      ;; The second prompt is queued while the first provider call is held.
      (should (harness-test-wait-for (lambda () harness-agent-test--held)))
      (should (harness-deferred-pending-p second))
      (harness-deferred-resolve harness-agent-test--held
                                (list :text "first turn" :stop-reason "end_turn"))
      (harness-test-settle first 10)
      (harness-test-settle second 10)
      (should (equal (harness-deferred-value first) "end_turn"))
      (should (equal (harness-deferred-value second) "end_turn"))
      ;; Both user messages are in the transcript, in order.
      (let ((user-texts (cl-remove-if-not
                         (lambda (text) (member text '("first" "second")))
                         (harness-agent-test--texts test-session-id))))
        (should (equal user-texts '("first" "second")))))))

(ert-deftest harness-agent-cancel-stops-the-turn ()
  (harness-agent-test--with-session
    (setq harness-agent-test--responses (list (list :hold t)))
    (let ((deferred (harness-agent-test--prompt test-session-id "long task")))
      (should (harness-test-wait-for (lambda () harness-agent-test--held)))
      (harness-agent-cancel :session-id test-session-id)
      (should (equal (harness-deferred-value deferred) "cancelled"))
      (should harness-agent-test--cancelled)
      (should (equal (plist-get (harness-service-call "session" 'info
                                                      :session-id test-session-id)
                                :status)
                     "idle")))))

(ert-deftest harness-agent-max-turn-requests ()
  (harness-agent-test--with-session
    (let ((harness-agent-max-turn-requests 2))
      (setq harness-agent-test--responses
            (list (list :tool-calls (vector (list :id "c1" :name "echo"
                                                  :arguments '(:text "a"))))
                  (list :tool-calls (vector (list :id "c2" :name "echo"
                                                  :arguments '(:text "b"))))
                  (list :tool-calls (vector (list :id "c3" :name "echo"
                                                  :arguments '(:text "c"))))))
      (let ((deferred (harness-agent-test--prompt test-session-id "loop")))
        (harness-test-settle deferred 10)
        (should (equal (harness-deferred-value deferred) "max_turn_requests"))
        (should (= (length harness-agent-test--requests) 3))))))

(ert-deftest harness-agent-no-model-refuses ()
  (harness-agent-test--with-session
    (harness-service-call "session" 'set-config :session-id test-session-id
                          :config-id "model" :value "")
    (setq harness-agent-test--models [])
    (harness-agent-refresh-models)
    (let ((deferred (harness-agent-test--prompt test-session-id "hi")))
      (harness-test-settle deferred 10)
      (should (equal (harness-deferred-value deferred) "refusal"))
      (should (cl-some (lambda (text) (and text (string-match-p "No model" text)))
                       (harness-agent-test--texts test-session-id))))))

(ert-deftest harness-agent-provider-error-is-reported ()
  (harness-agent-test--with-session
    (setq harness-agent-test--responses (list (list :error "upstream is down")))
    (let ((deferred (harness-agent-test--prompt test-session-id "hi")))
      (harness-test-settle deferred 10)
      (should (equal (harness-deferred-value deferred) "end_turn"))
      (should (cl-some (lambda (text) (and text (string-match-p "upstream is down" text)))
                       (harness-agent-test--texts test-session-id))))))

(ert-deftest harness-agent-non-interactive-steers-instead-of-asking ()
  (harness-agent-test--with-session
    (setq harness-agent-test--responses
          (list (list :tool-calls (vector (list :id "c1" :name "echo"
                                                :arguments '(:text "a"))))
                (list :text "understood")))
    (harness-service-register
     "permission"
     :module 'harness-agent-test
     :methods '((check . (lambda (&rest _args)
                           (let ((deferred (harness-deferred-new)))
                             (harness-deferred-resolve
                              deferred (list :decision 'deny :reason "outside the jail"))
                             deferred)))))
    (harness-service-call "session" 'set-config :session-id test-session-id
                          :config-id "permission" :value "non-interactive")
    (let ((deferred (harness-agent-test--prompt test-session-id "use the tool")))
      (harness-test-settle deferred 10)
      (should (cl-some (lambda (text) (and text (string-match-p "Permission was denied" text)))
                       (harness-agent-test--texts test-session-id))))))

(ert-deftest harness-agent-records-cost ()
  (harness-agent-test--with-session
    (setq harness-agent-test--price '(:amount 0.25 :currency "USD"))
    (setq harness-agent-test--responses
          (list (list :text "hi" :usage '(:input-tokens 100 :output-tokens 50))))
    (let ((deferred (harness-agent-test--prompt test-session-id "hi")))
      (harness-test-settle deferred 10)
      (let ((info (harness-service-call "session" 'info :session-id test-session-id)))
        (should (= (plist-get (plist-get info :cost) :amount) 0.25))
        (should (= (plist-get (plist-get info :usage) :input) 100))))))

(ert-deftest harness-agent-configuration-lists-models ()
  (harness-agent-test--with-session
    (harness-agent-refresh-models)
    (let* ((configuration (harness-service-call "agent" 'configuration
                                                :session-id test-session-id))
           (options (plist-get configuration :configOptions))
           (model-option (seq-find (lambda (option)
                                     (equal (plist-get option :id) "model"))
                                   (append options nil))))
      (should model-option)
      (should (equal (plist-get model-option :currentValue) "mock/mock-model"))
      (should (equal (plist-get (aref (plist-get model-option :options) 0) :value)
                     "mock/mock-model")))
    (harness-service-call "agent" 'set-config :session-id test-session-id
                          :config-id "model" :value "mock/other")
    (should (equal (plist-get (harness-service-call "session" 'info
                                                    :session-id test-session-id)
                              :model)
                   "mock/other"))))


(ert-deftest harness-agent-thinking-option ()
  "Models that support a thinking level expose a config option."
  (harness-agent-test--with-session
    (setq harness-agent--model-cache
          (vector (list :id "mock/mock-model" :name "Mock" :provider "mock"
                        :context-window 100000 :thinking t)))
    (let* ((configuration (harness-service-call "agent" 'configuration
                                                :session-id test-session-id))
           (options (append (plist-get configuration :configOptions) nil))
           (thinking (seq-find (lambda (option)
                                 (equal (plist-get option :id) "thinking"))
                               options)))
      (should thinking)
      (should (equal (plist-get thinking :category) "thought_level"))
      (should (= (length (plist-get thinking :options)) 3)))
    (harness-service-call "agent" 'set-config
                          :session-id test-session-id
                          :config-id "thinking" :value "high")
    (should (equal (plist-get (harness-service-call "session" 'info
                                                    :session-id test-session-id)
                              :thinking)
                   "high"))))

(ert-deftest harness-agent-auto-names-the-session ()
  "After the first turn a titleless session gets a model-generated name."
  (harness-agent-test--with-session
    (harness-service-call "session" 'rename :session-id test-session-id :title nil)
    (setq harness-agent-test--responses
          (list (list :text "The answer is 42." :stop-reason "end_turn")
                (list :text "Answering Life\n" :stop-reason "end_turn")))
    (let ((deferred (harness-agent-test--prompt test-session-id "what is the answer?")))
      (harness-test-settle deferred 10)
      (should (harness-test-wait-for
               (lambda ()
                 (equal (plist-get (harness-service-call "session" 'info
                                                         :session-id test-session-id)
                                   :title)
                        "Answering Life"))
               10))
      ;; The naming request reused the conversation as its prefix.
      (should (= (length harness-agent-test--requests) 2))
      (let ((naming (car harness-agent-test--requests)))
        (should (string-match-p "short title" (plist-get naming :system))))
      ;; The harness marked the session as being named; the UI shows the
      ;; resulting title in its header rather than another transcript line.
      (should (cl-some (lambda (text) (and text (string-match-p "Naming this conversation" text)))
                       (harness-agent-test--texts test-session-id))))))

(ert-deftest harness-agent-notices-cache-expiry ()
  "A long gap before a big-context turn produces a cache hint."
  (harness-agent-test--with-session
    (harness-service-call "session" 'add-usage :session-id test-session-id
                          :input 5000 :output 500)
    (harness-service-call "session" 'state-set :session-id test-session-id
                          :key 'last-turn-at
                          :value (- (float-time) (* 3 harness-agent-cache-ttl)))
    (harness-agent--note-cache-expiry test-session-id)
    (should (cl-some (lambda (text) (and text (string-match-p "Prompt cache likely expired" text)))
                     (harness-agent-test--texts test-session-id)))))

(ert-deftest harness-agent-keeps-quiet-when-the-cache-is-warm ()
  (harness-agent-test--with-session
    (harness-service-call "session" 'add-usage :session-id test-session-id
                          :input 5000 :output 500)
    (harness-service-call "session" 'state-set :session-id test-session-id
                          :key 'last-turn-at
                          :value (float-time))
    (harness-agent--note-cache-expiry test-session-id)
    (should-not (cl-some (lambda (text) (and text (string-match-p "Prompt cache" text)))
                         (harness-agent-test--texts test-session-id)))))

(provide 'harness-agent-test)
;;; harness-agent-test.el ends here
