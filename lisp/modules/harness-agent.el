;;; harness-agent.el --- The agent turn loop -*- lexical-binding: t; -*-

;; This file is part of Emacs Agent Harness.

;;; Commentary:

;; One prompt turn:
;;
;;   user message -> provider stream -> text/thinking/tool calls
;;     -> permissions -> tool execution -> tool results -> provider again
;;     -> ... until the model stops asking for tools
;;
;; The loop lives in the state layer and speaks only to kernel services:
;; the session service stores the transcript, the provider service streams
;; completions, the tool service executes, the permission service decides.
;; The ACP layer projects everything that happens here onto
;; `session/update' notifications; this module never talks to a UI.
;;
;; Prompts that arrive mid-turn are queued and sent together at the next
;; turn boundary.  Steering messages (used by non-interactive denials, and
;; available to the UI) are injected before the next provider call, which is
;; how an agent gets corrected without aborting its work.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'harness-core)
(require 'harness-tools)

(defgroup harness-agent nil
  "Agent turn loop."
  :group 'harness)

(defcustom harness-agent-system-prompt
  (concat "You are a coding agent running inside Emacs. You work in the session "
          "directory shown below; file tools are confined to it and shell commands "
          "run in a sandbox where the real home directory does not exist.\n"
          "\n"
          "Use the tools to inspect and change code. Prefer `read' over guessing, "
          "`edit' over rewriting files, and `search`/`glob` to find things. "
          "Keep answers short; the user can read the tool output. "
          "Use the todo tool for multi-step work.")
  "System prompt prepended to every completion."
  :type 'string)

(defcustom harness-agent-max-turn-requests 50
  "Maximum provider calls in one turn before it is cut short."
  :type 'natnum)

(defcustom harness-agent-default-model nil
  "Model used when a session has none, as \"provider/model\"."
  :type '(choice (const nil) string))

(defcustom harness-agent-max-output-tokens 8192
  "Maximum tokens the model may generate in one call."
  :type 'natnum)

(defcustom harness-agent-compact-threshold 0.8
  "Compact the conversation when this fraction of the context is used."
  :type 'number)

(defcustom harness-agent-compact-keep-entries 12
  "Entries kept verbatim when compacting; older ones become a summary."
  :type 'natnum)

(defvar harness-agent--sessions (make-hash-table :test #'equal)
  "Session id -> `harness-agent-state'.")

(defvar harness-agent--model-cache nil
  "Cached vector of model plists, or nil when never fetched.")

(defvar harness-agent-question-function nil
  "Function that asks the user a question and returns a deferred.
The UI layer installs this; the request plist carries :session-id,
:question, :options and :freeform, and the deferred resolves to the
answer string or nil.")

;;; State

(cl-defstruct (harness-agent-state (:constructor harness-agent-state-create))
  session-id
  turn
  (queue nil)                   ; list of (blocks . deferred), oldest first
  (steers nil)                  ; list of content blocks, oldest first
  (compacting nil))

(cl-defstruct (harness-agent-turn (:constructor harness-agent-turn-create))
  deferred
  abort
  (message-id nil)
  (thinking-id nil)
  (streamed nil)
  (iterations 0)
  (waited-for-models nil)
  (running t)
  (cancelled nil))

(defun harness-agent--state (session-id)
  "Return (creating it if needed) the agent state for SESSION-ID."
  (or (gethash session-id harness-agent--sessions)
      (puthash session-id (harness-agent-state-create :session-id session-id)
               harness-agent--sessions)))

(defun harness-agent--turn (session-id)
  "Return the running turn of SESSION-ID, or nil."
  (let ((state (gethash session-id harness-agent--sessions)))
    (and state (harness-agent-state-turn state))))

;;; Session plumbing

(defun harness-agent--info (session-id)
  "Return session info for SESSION-ID or signal."
  (harness-service-call "session" 'info :session-id session-id))

(defun harness-agent--error-message (error)
  "Render an error value from a deferred rejection as a string."
  (let ((data (cdr error)))
    (cond
     ((stringp data) data)
     ((and (consp data) (stringp (car data))) (car data))
     ((null data) (format "%S" (car error)))
     (t (format "%S" error)))))

(defun harness-agent--system-hint (session-id text &optional level)
  "Append a harness hint to SESSION-ID."
  (harness-service-call "session" 'system-hint
                        :session-id session-id :text text :level level))

(defun harness-agent--allowed-p (decision)
  "Return non-nil when DECISION allows a call."
  (eq (plist-get decision :decision) 'allow))

(defun harness-agent--entries (session-id)
  "Return the transcript entries of SESSION-ID as a list.
Signals when the transcript is still being read from disk."
  (let ((entries (harness-service-call "session" 'entries :session-id session-id)))
    (cond
     ((not (harness-deferred-p entries))
      (append entries nil))
     ((harness-deferred-resolved-p entries)
      (append (harness-deferred-value entries) nil))
     (t (signal 'harness-error (list "Session transcript is still loading"))))))

(defun harness-agent--permission-mode (info)
  "Return INFO's permission mode as a symbol."
  (let ((mode (plist-get info :permissionMode)))
    (cond ((symbolp mode) (or mode 'ask))
          ((stringp mode) (intern mode))
          (t 'ask))))

;;; Prompting

(defun harness-agent-prompt (&rest args)
  "Handle a session/prompt.  Returns a deferred of the stop reason."
  (let* ((session-id (plist-get args :session-id))
         (blocks (harness-agent--block-vector (plist-get args :prompt)))
         (state (harness-agent--state session-id)))
    (if (harness-agent-state-turn state)
        ;; Mid-turn: queue the message for the next turn boundary.
        (let ((deferred (harness-deferred-new)))
          (setf (harness-agent-state-queue state)
                (append (harness-agent-state-queue state)
                        (list (cons blocks deferred))))
          deferred)
      (harness-deferred-then
       (harness-service-call "session" 'entries :session-id session-id)
       (lambda (_entries) (harness-agent--start-turn session-id blocks))))))

(defun harness-agent--block-vector (blocks)
  "Normalize BLOCKS into a vector of content blocks."
  (vconcat (append blocks nil)))

(defun harness-agent--start-turn (session-id blocks)
  "Start a turn for SESSION-ID with BLOCKS.  Returns a deferred."
  (let* ((state (harness-agent--state session-id))
         (turn (harness-agent-turn-create :deferred (harness-deferred-new)
                                          :abort (harness-deferred-new))))
    (setf (harness-agent-state-turn state) turn)
    (harness-service-call "session" 'set-status :session-id session-id :status "running")
    (harness-agent--append-user-message session-id blocks)
    (harness-deferred-on-cancel (harness-agent-turn-deferred turn)
                                (lambda () (harness-agent-cancel :session-id session-id)))
    (run-at-time 0 nil (lambda () (harness-agent--loop session-id turn)))
    (harness-agent-turn-deferred turn)))

(defun harness-agent--append-user-message (session-id blocks)
  "Append BLOCKS as one user message to SESSION-ID."
  (let ((key (list "user" (harness-uuid)))
        (message-id (harness-uuid)))
    (harness-service-call
     "session" 'stream-begin
     :session-id session-id
     :key key
     :entry (list :sessionUpdate "user_message_chunk"
                  :messageId message-id
                  :content (harness-agent--block-vector blocks)))
    (harness-service-call "session" 'stream-end :session-id session-id :key key)))

;;; The loop

(defun harness-agent--session-model (info)
  "Return INFO's model, or nil when unset/empty."
  (let ((model (plist-get info :model)))
    (and (stringp model) (not (string-empty-p model)) model)))

(defun harness-agent--loop (session-id turn)
  "Run one provider call for SESSION-ID and continue as needed."
  (when (harness-agent-turn-running turn)
    (if (harness-deferred-rejected-p (harness-agent-turn-abort turn))
        (harness-agent--finish-turn session-id turn "cancelled")
      (progn
        (harness-agent--flush-steers session-id)
        (harness-agent--maybe-compact session-id)
        (let* ((info (harness-agent--info session-id))
               (model (or (harness-agent--session-model info)
                          harness-agent-default-model
                          (harness-agent--first-model))))
          (cond
           (model
            (harness-agent--call-provider
             session-id turn model (harness-agent--provider-request session-id turn info model)))
           ((harness-agent-turn-waited-for-models turn)
            (harness-agent--system-hint
             session-id
             "No model is configured. Choose one with the model switcher, or set harness-agent-default-model."
             "error")
            (harness-agent--finish-turn session-id turn "refusal"))
           (t
            (setf (harness-agent-turn-waited-for-models turn) t)
            (harness-deferred-then
             (harness-agent--ensure-models)
             (lambda (_) (harness-agent--loop session-id turn))))))))))

(defun harness-agent--flush-steers (session-id)
  "Inject pending steering messages into the transcript."
  (let* ((state (harness-agent--state session-id))
         (steers (harness-agent-state-steers state)))
    (when steers
      (setf (harness-agent-state-steers state) nil)
      (harness-agent--append-user-message
       session-id
       (vconcat (vector (list :type "text"
                              :text "Additional instruction from the user:"))
                (vconcat steers))))))

(defun harness-agent--ensure-models ()
  "Return a deferred resolving once the model cache is populated."
  (if harness-agent--model-cache
      (let ((deferred (harness-deferred-new)))
        (harness-deferred-resolve deferred harness-agent--model-cache)
        deferred)
    (let ((models (if (harness-service-available-p "provider" 'models)
                      (harness-service-call "provider" 'models)
                    nil)))
      (if (harness-deferred-p models)
          (harness-deferred-then models
                                 (lambda (value)
                                   (setq harness-agent--model-cache value)
                                   value))
        (setq harness-agent--model-cache (or models []))
        (let ((deferred (harness-deferred-new)))
          (harness-deferred-resolve deferred harness-agent--model-cache)
          deferred)))))

(defun harness-agent--first-model ()
  "Return the first available model id, or nil."
  (when (and harness-agent--model-cache
             (> (length harness-agent--model-cache) 0))
    (plist-get (aref harness-agent--model-cache 0) :id)))

(defun harness-agent--provider-request (session-id _turn info model)
  "Build the completion request for SESSION-ID."
  (list :model model
        :system (harness-agent--system-prompt info)
        :messages (harness-agent--messages session-id)
        :tools (harness-agent--tools info)
        :max-output-tokens harness-agent-max-output-tokens
        :thinking (plist-get info :thinking)
        :on-text (lambda (delta)
                   (harness-agent--stream-delta session-id
                                                (harness-agent--turn session-id)
                                                'text delta))
        :on-thought (lambda (delta)
                      (harness-agent--stream-delta session-id
                                                   (harness-agent--turn session-id)
                                                   'thinking delta))
        :on-tool-call #'ignore))

(defun harness-agent--messages (session-id)
  "Build the provider messages for SESSION-ID, honouring compaction."
  (let* ((entries (harness-agent--entries session-id))
         (compaction (harness-agent--compaction session-id)))
    (if (and compaction (plist-get compaction :up-to))
        (let* ((upto (plist-get compaction :up-to))
               (summary (plist-get compaction :text))
               (after (cl-loop for entry in entries
                               for index from 0
                               when (> index upto) collect entry)))
          (vconcat
           (vector (list :role "user"
                         :content (vector (list :type "text"
                                                :text (format "Summary of the earlier conversation:\n%s"
                                                              summary)))))
           (harness-provider-messages-from-entries (vconcat after))))
      (harness-provider-messages-from-entries (vconcat entries)))))

(defun harness-agent--system-prompt (info)
  "Return the system prompt for session INFO."
  (concat harness-agent-system-prompt
          "\n\nSession directory: " (or (plist-get info :cwd) "(unknown)")
          (let ((additional (plist-get info :additionalDirectories)))
            (if (and additional (> (length additional) 0))
                (format "\nAdditional directories: %s"
                        (string-join (append additional nil) ", "))
              ""))
          (let* ((state (harness-service-call "session" 'state-all
                                              :session-id (plist-get info :sessionId)))
                 (todos (plist-get state :todos)))
            (if (and todos (> (length todos) 0))
                (format "\n\nCurrent todo list:\n%s"
                        (mapconcat (lambda (item)
                                     (format "- [%s] %s"
                                             (or (plist-get item :status) "pending")
                                             (or (plist-get item :content) "")))
                                   (append todos nil) "\n"))
              ""))))

(defun harness-agent--tools (info)
  "Return tool specs for session INFO.  Plan mode keeps read-only tools."
  (if (equal (plist-get info :mode) "plan")
      (harness-tools-specs
       (seq-keep (lambda (tool)
                   (when (harness-tool-read-only tool)
                     (harness-tool-name tool)))
                 (harness-tool-list)))
    (harness-tools-specs)))

;;; Streaming

(defun harness-agent--stream-delta (session-id turn kind delta)
  "Record a streamed DELTA of KIND for TURN."
  (when (and turn (harness-agent-turn-running turn))
    (setf (harness-agent-turn-streamed turn) t)
    (pcase kind
      ('text
       (unless (harness-agent-turn-message-id turn)
         (setf (harness-agent-turn-message-id turn) (harness-uuid))
         (harness-service-call
          "session" 'stream-begin
          :session-id session-id
          :key (list "agent" (harness-agent-turn-message-id turn))
          :entry (list :sessionUpdate "agent_message_chunk"
                       :messageId (harness-agent-turn-message-id turn)
                       :content (list :type "text" :text ""))))
       (harness-service-call
        "session" 'stream-chunk
        :session-id session-id
        :key (list "agent" (harness-agent-turn-message-id turn))
        :update (list :sessionUpdate "agent_message_chunk"
                      :messageId (harness-agent-turn-message-id turn)
                      :content (list :type "text" :text delta))))
      ('thinking
       (unless (harness-agent-turn-thinking-id turn)
         (setf (harness-agent-turn-thinking-id turn) (harness-uuid))
         (harness-service-call
          "session" 'stream-begin
          :session-id session-id
          :key (list "thinking" (harness-agent-turn-thinking-id turn))
          :entry (list :sessionUpdate "agent_thought_chunk"
                       :messageId (harness-agent-turn-thinking-id turn)
                       :content (list :type "text" :text ""))))
       (harness-service-call
        "session" 'stream-chunk
        :session-id session-id
        :key (list "thinking" (harness-agent-turn-thinking-id turn))
        :update (list :sessionUpdate "agent_thought_chunk"
                      :messageId (harness-agent-turn-thinking-id turn)
                      :content (list :type "text" :text delta)))))))

(defun harness-agent--close-streams (session-id turn)
  "Materialize any open streams of TURN."
  ;; Thinking was produced before the message, so materialize it first.
  (when (harness-agent-turn-thinking-id turn)
    (harness-service-call "session" 'stream-end :session-id session-id
                          :key (list "thinking" (harness-agent-turn-thinking-id turn)))
    (setf (harness-agent-turn-thinking-id turn) nil))
  (when (harness-agent-turn-message-id turn)
    (harness-service-call "session" 'stream-end :session-id session-id
                          :key (list "agent" (harness-agent-turn-message-id turn)))
    (setf (harness-agent-turn-message-id turn) nil)))

;;; Provider call

(defun harness-agent--call-provider (session-id turn model request)
  "Call the provider with REQUEST and handle the result for TURN."
  (unless (harness-service-available-p "provider" 'complete)
    (harness-agent--system-hint
     session-id "No completion provider is loaded; cannot run the model." "error")
    (harness-agent--finish-turn session-id turn "refusal")
    (cl-return-from harness-agent--call-provider nil))
  (let* ((turn-abort (harness-agent-turn-abort turn))
         (deferred (harness-service-call "provider" 'complete request)))
    (harness-deferred-on-cancel turn-abort
                                (lambda ()
                                  (when (harness-deferred-pending-p deferred)
                                    (harness-deferred-cancel deferred))))
    (harness-deferred-then
     deferred
     (lambda (result)
       (harness-agent--close-streams session-id turn)
       (when (harness-agent-turn-running turn)
         (harness-agent--record-usage session-id model result)
         (harness-agent--handle-result session-id turn result)))
     (lambda (error)
       (harness-agent--close-streams session-id turn)
       (when (harness-agent-turn-running turn)
         (if (harness-agent-turn-cancelled turn)
             (harness-agent--finish-turn session-id turn "cancelled")
           (let ((message (format "The model call failed: %s"
                                  (harness-agent--error-message error))))
             (harness-agent--system-hint session-id message "error")
             (harness-emit 'agent-error :session-id session-id :message message)
             (harness-agent--finish-turn session-id turn "end_turn"))))))))

;;; Results, tools, continuation

(defun harness-agent--handle-result (session-id turn result)
  "Handle a completed provider RESULT for TURN."
  (let* ((text (or (plist-get result :text) ""))
         (tool-calls (append (plist-get result :tool-calls) nil)))
    ;; Providers that do not stream: append the whole message now.
    (when (and (not (harness-agent-turn-streamed turn))
               (not (string-empty-p text)))
      (let ((key (list "agent-final" (harness-uuid))))
        (harness-service-call
         "session" 'stream-begin
         :session-id session-id :key key
         :entry (list :sessionUpdate "agent_message_chunk"
                      :messageId (harness-uuid)
                      :content (list :type "text" :text text)))
        (harness-service-call "session" 'stream-end :session-id session-id :key key)))
    (cond
     ((null tool-calls)
      (harness-agent--finish-turn session-id turn
                                  (or (plist-get result :stop-reason) "end_turn")))
     ((>= (harness-agent-turn-iterations turn) harness-agent-max-turn-requests)
      (harness-agent--finish-turn session-id turn "max_turn_requests"))
     (t
      (harness-deferred-then
       (harness-agent--execute-tools session-id turn tool-calls)
       (lambda (_)
         (cl-incf (harness-agent-turn-iterations turn))
         (run-at-time 0 nil (lambda () (harness-agent--loop session-id turn)))))))))

(defun harness-agent--execute-tools (session-id turn tool-calls)
  "Execute every tool call of TOOL-CALLS sequentially.  Returns a deferred."
  (let ((deferred (harness-deferred-new))
        (remaining (copy-sequence tool-calls)))
    (cl-labels ((next ()
                  (if (null remaining)
                      (harness-deferred-resolve deferred nil)
                    (let ((call (pop remaining)))
                      (harness-deferred-then
                       (harness-agent--execute-tool session-id turn call)
                       (lambda (_) (next)))))))
      (next))
    deferred))

(defun harness-agent--execute-tool (session-id turn call)
  "Check permissions, run CALL, and append its transcript entries."
  (let* ((tool-name (or (plist-get call :name) ""))
         (arguments (plist-get call :arguments))
         (tool (harness-tool-get tool-name))
         (tool-call-id (or (plist-get call :id) (harness-uuid)))
         (key (list "tool" tool-call-id))
         (deferred (harness-deferred-new))
         (info (harness-agent--info session-id))
         (context (harness-tool-context-create
                   :session-id session-id
                   :cwd (plist-get info :cwd)
                   :abort (harness-agent-turn-abort turn)
                   :meta info)))
    (harness-agent--append-tool-entry
     session-id
     (list :sessionUpdate "tool_call"
           :toolCallId tool-call-id
           :name tool-name
           :title (or (and tool (harness-tool-description tool))
                      (format "Calling %s" tool-name))
           :kind (if tool (symbol-name (harness-tool-kind tool)) "other")
           :status "pending"
           :rawInput (if (stringp arguments)
                         arguments
                       (or arguments (make-hash-table)))))
    (cond
     ((null tool)
      (harness-deferred-resolve
       deferred
       (harness-agent--finish-tool session-id key tool-call-id
                                   (harness-tool-error-result
                                    (format "No such tool: %s" tool-name)))))
     ((and (stringp arguments) (not (string-empty-p arguments)))
      (harness-deferred-resolve
       deferred
       (harness-agent--finish-tool session-id key tool-call-id
                                   (harness-tool-error-result
                                    (format "Arguments were not valid JSON: %s" arguments)))))
     (t
      (harness-deferred-then
       (harness-agent--check-permission session-id tool-name arguments context info)
       (lambda (decision)
         (if (harness-agent--allowed-p decision)
             (progn
               (when (plist-get decision :always)
                 (harness-agent--grant-paths session-id decision))
               (harness-agent--append-tool-entry
                session-id
                (list :sessionUpdate "tool_call_update"
                      :toolCallId tool-call-id
                      :status "in_progress"))
               (harness-deferred-then
                (harness-service-call "tool" 'execute
                                      :name tool-name
                                      :arguments arguments
                                      :context context)
                (lambda (result)
                  (harness-deferred-resolve
                   deferred
                   (harness-agent--finish-tool session-id key tool-call-id result)))))
           (progn
             (harness-agent--maybe-steer-about-denial session-id info decision)
             (harness-deferred-resolve
              deferred
              (harness-agent--finish-tool
               session-id key tool-call-id
               (harness-tool-error-result
                (format "Permission denied: %s"
                        (or (plist-get decision :reason) "not allowed")))))))))))
    deferred))

(defun harness-agent--append-tool-entry (session-id entry)
  "Append a tool transcript ENTRY to SESSION-ID."
  (harness-service-call "session" 'append :session-id session-id :entry entry))

(defun harness-agent--finish-tool (session-id _key tool-call-id result)
  "Append the completed tool entry for RESULT on TOOL-CALL-ID."
  (harness-agent--append-tool-entry
   session-id
   (list :sessionUpdate "tool_call_update"
         :toolCallId tool-call-id
         :status (if (plist-get result :is-error) "failed" "completed")
         :content (vector (list :type "content"
                                :content (list :type "text"
                                               :text (harness-agent--result-text result))))))
  result)

(defun harness-agent--result-text (result)
  "Flatten tool RESULT content into text."
  (mapconcat (lambda (block)
               (let ((content (plist-get block :content)))
                 (cond
                  ((and (listp content) (plist-get content :type))
                   (or (plist-get content :text) (format "%S" content)))
                  ((vectorp content)
                   (mapconcat (lambda (inner) (or (plist-get inner :text) ""))
                              (append content nil) "\n"))
                  (t (format "%S" (plist-get block :text))))))
             (append (plist-get result :content) nil) "\n"))

(defun harness-agent--check-permission (session-id tool-name arguments context info)
  "Return a deferred permission decision for a tool call."
  (let ((mode (harness-agent--permission-mode info)))
    (if (not (harness-service-available-p "permission" 'check))
        (let ((deferred (harness-deferred-new)))
          (harness-deferred-resolve deferred (list :decision 'allow))
          deferred)
      (let ((deferred (harness-deferred-new)))
        (harness-deferred-then
         (harness-service-call
          "permission" 'check
          :tool-name tool-name
          :arguments arguments
          :context context
          :cwd (plist-get info :cwd)
          :additional-directories (plist-get info :additionalDirectories)
          :permission-mode mode)
         (lambda (decision)
           ;; Non-interactive mode never blocks: a denial becomes steering.
           (if (and (eq mode 'non-interactive)
                    (not (harness-agent--allowed-p decision)))
               (harness-deferred-resolve
                deferred
                (list :decision 'deny
                      :reason (concat (or (plist-get decision :reason) "not allowed")
                                      " The user is away; find a different approach that "
                                      "respects this restriction and continue the task.")))
             (harness-deferred-resolve deferred decision)))
         (lambda (error)
           (harness-deferred-resolve
            deferred (list :decision 'deny
                           :reason (format "Permission check failed: %s"
                                           (harness-agent--error-message error))))))
        deferred))))

(defun harness-agent--grant-paths (session-id decision)
  "Grant the directories of an always-allow DECISION to SESSION-ID."
  (dolist (path (append (plist-get decision :paths) nil))
    (harness-service-call "session" 'add-directory
                          :session-id session-id
                          :directory (file-name-directory path))))

(defun harness-agent--maybe-steer-about-denial (session-id info decision)
  "In non-interactive sessions, record DENIAL as a steering message."
  (when (eq (harness-agent--permission-mode info) 'non-interactive)
    (let ((state (harness-agent--state session-id)))
      (setf (harness-agent-state-steers state)
            (append (harness-agent-state-steers state)
                    (list (list :type "text"
                                :text (format "Permission was denied: %s"
                                              (or (plist-get decision :reason)
                                                  "not allowed")))))))))

;;; Usage and cost

(defun harness-agent--record-usage (session-id model result)
  "Record usage and cost of RESULT on MODEL for SESSION-ID."
  (let* ((usage (plist-get result :usage))
         (input (or (plist-get usage :input-tokens) 0))
         (output (or (plist-get usage :output-tokens) 0)))
    (when (or (> input 0) (> output 0))
      (harness-service-call "session" 'add-usage
                            :session-id session-id
                            :input input
                            :output output
                            :cache-read (or (plist-get usage :cache-read) 0)
                            :cache-write (or (plist-get usage :cache-write) 0)
                            :context-used (+ input output)
                            :context-size (harness-agent--context-size model))
      (when (harness-service-available-p "provider" 'price)
        (let ((cost (harness-service-call "provider" 'price :model model :usage usage)))
          (when (and (listp cost) (numberp (plist-get cost :amount)))
            (harness-service-call "session" 'add-cost
                                  :session-id session-id
                                  :amount (plist-get cost :amount)
                                  :currency (or (plist-get cost :currency) "USD"))))))))

(defun harness-agent--context-size (model)
  "Return the context window of MODEL from the provider model list."
  (let ((cached (seq-find (lambda (entry) (equal (plist-get entry :id) model))
                          (append harness-agent--model-cache nil))))
    (or (plist-get cached :context-window) 0)))

;;; Compaction

(defun harness-agent--compaction (session-id)
  "Return SESSION-ID's compaction state, or nil."
  (let ((state (harness-service-call "session" 'state-all :session-id session-id)))
    (plist-get state :compaction)))

(defun harness-agent--maybe-compact (session-id)
  "Start compacting SESSION-ID when it approaches the context window."
  (let* ((state (harness-agent--state session-id))
         (info (harness-agent--info session-id))
         (model (or (plist-get info :model) harness-agent-default-model))
         (size (harness-agent--context-size model))
         (used (or (plist-get info :contextUsed) 0)))
    (when (and (not (harness-agent-state-compacting state))
               (> size 0)
               (> used (* harness-agent-compact-threshold size))
               (harness-service-available-p "provider" 'complete))
      (setf (harness-agent-state-compacting state) t)
      (harness-deferred-finally
       (harness-agent--compact session-id model (harness-agent--entries session-id))
       (lambda () (setf (harness-agent-state-compacting state) nil))))))

(defun harness-agent--compact (session-id model entries)
  "Summarize the older part of ENTRIES for SESSION-ID."
  (let* ((keep harness-agent-compact-keep-entries)
         (cutoff (max 0 (- (length entries) keep)))
         (older (seq-subseq (vconcat entries) 0 cutoff)))
    (if (zerop cutoff)
        (let ((deferred (harness-deferred-new)))
          (harness-deferred-resolve deferred nil)
          deferred)
      (harness-service-call "session" 'system-hint
                            :session-id session-id
                            :text "Compacting the conversation to free context…")
      (harness-deferred-then
       (harness-service-call
        "provider" 'complete
        :model model
        :system "Summarize this conversation for continuation. Keep decisions, file paths, command results and open questions. Be concise."
        :messages (harness-provider-messages-from-entries older)
        :max-output-tokens 2000)
       (lambda (result)
         (let ((text (plist-get result :text)))
           (when (and text (not (string-empty-p text)))
             (harness-service-call "session" 'state-set
                                   :session-id session-id
                                   :key 'compaction
                                   :value (list :up-to (1- cutoff) :text text))
             (harness-service-call "session" 'system-hint
                                   :session-id session-id
                                   :text "Conversation compacted.")))
         nil)
       (lambda (error)
         (harness-log "compaction failed: %S" error)
         nil)))))

;;; Finishing and queueing

(defun harness-agent--finish-turn (session-id turn stop-reason)
  "Finish TURN with STOP-REASON, then start any queued turn."
  (when (harness-agent-turn-running turn)
    (setf (harness-agent-turn-running turn) nil)
    (let ((state (harness-agent--state session-id)))
      (setf (harness-agent-state-turn state) nil)
      (harness-service-call "session" 'set-status :session-id session-id :status "idle")
      (harness-emit 'agent-turn-finished :session-id session-id :stop-reason stop-reason)
      (harness-deferred-resolve (harness-agent-turn-deferred turn) stop-reason)
      (let ((queue (harness-agent-state-queue state)))
        (when queue
          (setf (harness-agent-state-queue state) nil)
          (let ((blocks (vconcat (seq-mapcat (lambda (entry) (append (car entry) nil))
                                             queue)))
                (deferreds (mapcar #'cdr queue)))
            (harness-deferred-then
             (harness-agent--start-turn session-id blocks)
             (lambda (reason)
               (dolist (deferred deferreds)
                 (harness-deferred-resolve deferred reason))))))))))

(defun harness-agent-cancel (&rest args)
  "Cancel the running turn of :session-id, if any."
  (let* ((session-id (plist-get args :session-id))
         (turn (harness-agent--turn session-id)))
    (when turn
      (setf (harness-agent-turn-cancelled turn) t)
      (harness-deferred-cancel (harness-agent-turn-abort turn) "cancelled")
      (harness-agent--close-streams session-id turn)
      (harness-agent--finish-turn session-id turn "cancelled"))
    nil))

(defun harness-agent-steer (&rest args)
  "Add steering text to the running turn, or start a turn with it."
  (let* ((session-id (plist-get args :session-id))
         (text (plist-get args :text)))
    (if (harness-agent--turn session-id)
        (let ((state (harness-agent--state session-id)))
          (setf (harness-agent-state-steers state)
                (append (harness-agent-state-steers state)
                        (list (list :type "text" :text text))))
          nil)
      (harness-agent-prompt :session-id session-id
                            :prompt (vector (list :type "text" :text text))))))

;;; Configuration

(defun harness-agent-configuration (&rest args)
  "Return the complete configuration state for :session-id."
  (let* ((session-id (plist-get args :session-id))
         (info (harness-service-call "session" 'info :session-id session-id))
         (session-configuration (harness-service-call "session" 'configuration
                                                      :session-id session-id))
         (options (append (plist-get session-configuration :configOptions) nil))
         (models (or harness-agent--model-cache [])))
    (when (> (length models) 0)
      (setq options (cons (harness-agent--model-option models (plist-get info :model))
                          (seq-remove (lambda (option) (equal (plist-get option :id) "model"))
                                      options))))
    (list :configOptions (vconcat options))))

(defun harness-agent--model-option (models current)
  "Build the model config option from MODELS with CURRENT selected."
  (list :id "model" :name "Model" :category "model" :type "select"
        :currentValue (or current "")
        :options
        (vconcat
         (mapcar (lambda (model)
                   (list :value (plist-get model :id)
                         :name (let ((name (or (plist-get model :name)
                                               (plist-get model :id)))
                                     (provider (plist-get model :provider)))
                                 (if (and provider
                                          (not (string-prefix-p (concat provider "/") name)))
                                     (format "%s (%s)" name provider)
                                   name))))
                 (append models nil)))))

(defun harness-agent-set-config (&rest args)
  "Set :config-id to :value for :session-id and return the configuration."
  (let ((session-id (plist-get args :session-id)))
    (harness-service-call "session" 'set-config
                          :session-id session-id
                          :config-id (plist-get args :config-id)
                          :value (plist-get args :value))
    (harness-agent-configuration :session-id session-id)))

(defun harness-agent-set-mode (&rest args)
  "Set the session mode."
  (let ((session-id (plist-get args :session-id)))
    (harness-service-call "session" 'set-mode
                          :session-id session-id
                          :mode-id (plist-get args :mode-id))
    (harness-agent-configuration :session-id session-id)))

(defun harness-agent-refresh-models ()
  "Refresh the cached model list."
  (interactive)
  (setq harness-agent--model-cache nil)
  (harness-agent--ensure-models)
  harness-agent--model-cache)

;;; Events and service

(defun harness-agent-ask-tool (arguments context)
  "Tool handler: ask the user a question through the UI."
  (let ((session-id (harness-tool-context-session-id context))
        (question (plist-get arguments :question)))
    (if (null harness-agent-question-function)
        (harness-tool-error-result
         "No user is available to answer questions; decide for yourself or continue.")
      (progn
        (harness-agent--set-status session-id "blocked")
        (harness-deferred-then
         (funcall harness-agent-question-function
                  (harness-plist-omit-nil
                   (list :session-id session-id
                         :question question
                         :options (let ((options (plist-get arguments :options)))
                                    (when (and options (> (length options) 0)) options))
                         :freeform (plist-get arguments :freeform))))
         (lambda (answer)
           (harness-agent--set-status session-id "running")
           (if (and answer (not (string-empty-p answer)))
               (format "The user answered: %s" answer)
             "The user dismissed the question without answering."))
         (lambda (error)
           (harness-agent--set-status session-id "running")
           (harness-tool-error-result
            (format "Asking the user failed: %s" (harness-agent--error-message error)))))))))

(defun harness-agent--set-status (session-id status)
  "Set SESSION-ID's status through the session service."
  (when (and session-id (harness-service-available-p "session" 'set-status))
    (ignore-errors
      (harness-service-call "session" 'set-status :session-id session-id :status status))))

(defun harness-agent-setup ()
  "Set up the agent module."
  (harness-event-define 'agent-error
    :module 'harness-agent
    :doc "A model call failed."
    :payload '((session-id . string) (message . string)))
  (harness-event-define 'agent-turn-finished
    :module 'harness-agent
    :doc "A prompt turn ended."
    :payload '((session-id . string) (stop-reason . string)))
  (harness-service-register
   "agent"
   :module 'harness-agent
   :doc "Prompt turns, tool execution and session configuration."
   :methods '((prompt . harness-agent-prompt)
              (cancel . harness-agent-cancel)
              (steer . harness-agent-steer)
              (configuration . harness-agent-configuration)
              (set-config . harness-agent-set-config)
              (set-mode . harness-agent-set-mode)
              (refresh-models . harness-agent-refresh-models)))
  (harness-tool-register
   "ask"
   :description "Ask the user a question and wait for their answer. Use sparingly, when the task truly needs human input."
   :schema '(:type "object"
             :properties (:question (:type "string")
                          :options (:type "array" :description "Suggested answers.")
                          :freeform (:type "boolean" :description "Allow a free-form answer."))
             :required ["question"])
   :kind 'think
   :handler #'harness-agent-ask-tool))

(defun harness-agent-teardown ()
  "Tear down the agent module."
  (maphash (lambda (_id state)
             (when-let* ((turn (harness-agent-state-turn state)))
               (harness-deferred-cancel (harness-agent-turn-abort turn) "teardown")))
           harness-agent--sessions)
  (clrhash harness-agent--sessions)
  (setq harness-agent--model-cache nil))

(harness-module-define 'harness-agent
  :version harness-version
  :description "Prompt turns, tool loop, queueing and compaction."
  :requires '((harness-core "0.1.0")
              (harness-tools "0.1.0")
              (harness-provider "0.1.0"))
  :provides '(harness-agent)
  :setup #'harness-agent-setup
  :teardown #'harness-agent-teardown)

(provide 'harness-agent)
;;; harness-agent.el ends here
