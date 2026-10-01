;;; harness-provider-claude.el --- Claude Code CLI as a completion provider  -*- lexical-binding: t; -*-

;;; Commentary:

;; Drives the official `claude' command line (Claude Code) as a hosted
;; completion provider, so subscription users can use Claude models
;; from the harness.  Per harness session one long-lived CLI process is
;; kept alive across turns: the CLI keeps the conversation and the KV
;; cache, the harness only sends new user content and serves tool calls.
;;
;; Wire protocol (newline delimited JSON on stdin/stdout):
;;
;; - We spawn `claude -p --input-format stream-json --output-format
;;   stream-json ...' with every built-in tool disabled and one SDK MCP
;;   server called "harness".  The CLI asks us to serve that server over
;;   `control_request' messages of subtype `mcp_message'; we answer the
;;   JSON-RPC calls (initialize, tools/list, tools/call) inline.  A
;;   tools/call becomes a `tool-call' provider event whose `:respond'
;;   writes the result back, which is how the hosted loop continues.
;; - Streaming deltas arrive as `stream_event' messages carrying
;;   Anthropic streaming events; `assistant' messages are authoritative
;;   and are used to remember tool_use ids; `result' ends the turn.
;; - `--resume ID' recreates a session after a restart and `--resume ID
;;   --fork-session' implements `:fork': the new session starts from
;;   the parent's cached prefix.
;;
;; Nothing here blocks: output is handled in a process filter, death in
;; a sentinel, and cancellation by an interrupt request plus a timer.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-provider)

;;;; Customisation

(defcustom harness-provider-claude-program
  (or (executable-find "claude")
      (let ((local (expand-file-name "~/.local/bin/claude")))
        (and (file-executable-p local) local))
      "claude")
  "Path to the `claude' command line program."
  :type 'string :group 'harness)

(defcustom harness-provider-claude-interrupt-timeout 3
  "Seconds to wait after an interrupt before killing the CLI process."
  :type 'number :group 'harness)

(defcustom harness-provider-claude-extra-args nil
  "Extra command line arguments appended to every `claude' invocation."
  :type '(repeat string) :group 'harness)

;;;; Constants

(defconst harness-provider-claude-tool-prefix "mcp__harness__"
  "Prefix the CLI adds to the names of tools served by the harness.")

(defconst harness-provider-claude-models
  '((:name "claude-fable-5-1" :label "Claude Fable 5.1" :context-window 1000000
     :max-output 128000 :input-modalities ("text" "image")
     :thinking-levels ("low" "medium" "high" "xhigh" "max")
     :pricing (:input 10.0 :output 50.0 :cache-read 0.25 :cache-write 12.5))
    (:name "claude-opus-5-5" :label "Claude Opus 5.5" :context-window 1000000
     :max-output 128000 :input-modalities ("text" "image")
     :thinking-levels ("low" "medium" "high" "xhigh" "max")
     :pricing (:input 4.0 :output 20.0 :cache-read 0.2 :cache-write 5.0))
    (:name "claude-sonnet-5" :label "Claude Sonnet 5" :context-window 1000000
     :max-output 64000 :input-modalities ("text" "image")
     :thinking-levels ("low" "medium" "high" "xhigh" "max")
     :pricing (:input 2.0 :output 10.0 :cache-read 0.2 :cache-write 2.5))
    (:name "claude-haiku-4-5-20251001" :label "Claude Haiku 4.5" :context-window 200000
     :max-output 64000 :input-modalities ("text" "image")
     :thinking-levels ("low" "medium" "high")
     :pricing (:input 1.0 :output 5.0 :cache-read 0.1 :cache-write 1.25)))
  "Static model catalogue for the Claude Code provider (no network).")

(defconst harness-provider-claude-capabilities
  '(:hosted-loop t :fork t :resume t :vision t :thinking t :quota t
    :compaction hosted :cost-reported t :cache-status t)
  "Capabilities of every Claude Code model.")

;;;; State

(cl-defstruct (harness-provider-claude-session
               (:constructor harness-provider-claude--make-session)
               (:copier nil))
  "One CLI process serving one harness session."
  id                 ; harness session id
  process            ; the CLI process, or a dead one
  stderr             ; stderr buffer
  (buffer "")        ; unparsed tail of stdout
  cli-session-id     ; Claude Code session id, from system/init
  model              ; model name reported by the CLI
  spawn-key          ; (MODEL EFFORT SYSTEM) the process was started with
  ;; Per-turn state
  request            ; the current request plist, nil when idle
  on-event           ; the current :on-event callback
  active             ; non-nil while a turn is in flight
  cancelled          ; non-nil once cancel was requested for this turn
  cancel-timer       ; timer that kills the process after an interrupt
  pending-tools      ; list of (TOOL-USE-ID . NAME) awaiting a tools/call
  own-results        ; tool_use ids whose results the harness produced
  context)           ; input size of the last API call, from stream usage

(defvar harness-provider-claude--sessions (make-hash-table :test 'equal)
  "Harness session id -> `harness-provider-claude-session'.")

(defvar harness-provider-claude--quota nil
  "Last rate-limit windows seen, as (:name :used :resets) plists.")

;;;; Small helpers

(defun harness-provider-claude--strip-prefix (name)
  "Return tool NAME without the CLI's MCP server prefix."
  (if (and (stringp name) (string-prefix-p harness-provider-claude-tool-prefix name))
      (substring name (length harness-provider-claude-tool-prefix))
    name))

(defun harness-provider-claude--emit (entry event)
  "Deliver EVENT to the current turn's callback on ENTRY."
  (let ((fn (harness-provider-claude-session-on-event entry)))
    (when (and fn (harness-provider-claude-session-active entry))
      (funcall fn event))))

(defun harness-provider-claude--finish (entry event)
  "End the current turn on ENTRY by delivering the done EVENT once."
  (when (harness-provider-claude-session-active entry)
    (when-let* ((timer (harness-provider-claude-session-cancel-timer entry)))
      (cancel-timer timer))
    (let ((fn (harness-provider-claude-session-on-event entry)))
      (setf (harness-provider-claude-session-active entry) nil
            (harness-provider-claude-session-cancel-timer entry) nil
            (harness-provider-claude-session-on-event entry) nil
            (harness-provider-claude-session-request entry) nil)
      (when fn (funcall fn event)))))

(defun harness-provider-claude--send (entry object)
  "Write OBJECT as one JSON line to ENTRY's CLI process."
  (let ((proc (harness-provider-claude-session-process entry)))
    (if (process-live-p proc)
        (process-send-string proc (concat (harness-json-encode object) "\n"))
      (harness-log 'warn "provider-claude: cannot write to dead process for %s"
                   (harness-provider-claude-session-id entry)))))

(defun harness-provider-claude--stderr-tail (entry)
  "Return the last few lines of ENTRY's stderr, or an empty string."
  (let ((buf (harness-provider-claude-session-stderr entry)))
    (if (buffer-live-p buf)
        (with-current-buffer buf
          (string-trim (buffer-substring-no-properties
                        (max (point-min) (- (point-max) 2000)) (point-max))))
      "")))

(defun harness-provider-claude--environment ()
  "Return `process-environment' without the CLAUDECODE nesting marker."
  (cl-remove-if (lambda (e) (string-prefix-p "CLAUDECODE=" e)) process-environment))

;;;; Command line and spawning

(defun harness-provider-claude--command (model effort system resume fork)
  "Build the `claude' command line.
MODEL is the model name, EFFORT the thinking level or nil, SYSTEM the
system prompt or nil, RESUME a CLI session id to continue or nil, and
FORK non-nil to fork RESUME into a new session."
  (append
   (list harness-provider-claude-program
         "-p" "--input-format" "stream-json" "--output-format" "stream-json"
         "--verbose" "--include-partial-messages"
         "--tools" ""
         "--strict-mcp-config"
         "--mcp-config" (harness-json-encode
                         '(:mcpServers (:harness (:type "sdk" :name "harness"))))
         "--permission-mode" "bypassPermissions"
         "--model" model)
   (when effort (list "--effort" effort))
   (when (and system (not (harness-string-blank-p system)))
     (list "--system-prompt" system))
   (when resume (list "--resume" resume))
   (when (and resume fork) (list "--fork-session"))
   harness-provider-claude-extra-args))

(defun harness-provider-claude--spawn (entry request resume fork)
  "Start a CLI process for ENTRY serving REQUEST.
RESUME and FORK are passed to `harness-provider-claude--command'."
  (let* ((session (plist-get request :session))
         (cwd (or (plist-get session :cwd) default-directory))
         (host (plist-get session :host))
         (cwd (if (and host (not (file-remote-p cwd))) (concat host cwd) cwd))
         (default-directory (file-name-as-directory (expand-file-name cwd)))
         (process-environment (harness-provider-claude--environment))
         (model (cdr (harness-provider-parse-model (plist-get request :model))))
         (effort (plist-get request :thinking))
         (system (plist-get request :system))
         (command (harness-provider-claude--command model effort system resume fork))
         (stderr (generate-new-buffer " *harness-claude-stderr*" t))
         (proc (make-process :name (format "harness-claude-%s" (harness-provider-claude-session-id entry))
                             :command command
                             :coding '(utf-8 . utf-8)
                             :connection-type 'pipe
                             :noquery t
                             :file-handler t
                             :stderr stderr
                             :filter (lambda (_p chunk) (harness-provider-claude--filter entry chunk))
                             :sentinel (lambda (p e) (harness-provider-claude--sentinel entry p e)))))
    (when-let* ((ep (get-buffer-process stderr)))
      (set-process-query-on-exit-flag ep nil)
      (set-process-sentinel ep #'ignore))
    (harness-log 'info "provider-claude: spawned for %s%s%s"
                 (harness-provider-claude-session-id entry)
                 (if resume (format " (resume %s)" resume) "")
                 (if fork " forked" ""))
    (setf (harness-provider-claude-session-process entry) proc
          (harness-provider-claude-session-stderr entry) stderr
          (harness-provider-claude-session-buffer entry) ""
          (harness-provider-claude-session-spawn-key entry) (list model effort system))
    (harness-provider-claude--send
     entry '(:type "control_request" :request_id "init-1"
             :request (:subtype "initialize" :sdkMcpServers ("harness"))))
    proc))

(defun harness-provider-claude--kill (entry)
  "Kill ENTRY's process and its stderr buffer."
  (let ((proc (harness-provider-claude-session-process entry))
        (buf (harness-provider-claude-session-stderr entry)))
    (when (process-live-p proc)
      (set-process-sentinel proc #'ignore)
      (delete-process proc))
    (when (buffer-live-p buf) (kill-buffer buf))
    (setf (harness-provider-claude-session-process entry) nil
          (harness-provider-claude-session-stderr entry) nil)))

;;;; Messages out

(defun harness-provider-claude--read-base64 (path)
  "Return the contents of PATH base64 encoded, or nil."
  (when (and path (file-readable-p path))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally path)
      (base64-encode-string (buffer-string) t))))

(defun harness-provider-claude--convert-block (block)
  "Convert harness content BLOCK into an Anthropic content block, or nil."
  (pcase (plist-get block :type)
    ("text" (list :type "text" :text (or (plist-get block :text) "")))
    ("image"
     (when-let* ((data (or (plist-get block :data)
                           (harness-provider-claude--read-base64 (plist-get block :path)))))
       (list :type "image"
             :source (list :type "base64"
                           :media_type (or (plist-get block :mime) "image/png")
                           :data data))))
    ("file" (list :type "text"
                  :text (format "[attached file: %s]" (plist-get block :path))))
    (_ nil)))

(defun harness-provider-claude--user-blocks (request)
  "Return the content blocks of the trailing user messages in REQUEST."
  (let (blocks)
    (dolist (msg (plist-get request :messages))
      (let ((role (format "%s" (plist-get msg :role))))
        (cond ((equal role "assistant") (setq blocks nil))
              ((equal role "user")
               (dolist (b (plist-get msg :content))
                 (when-let* ((c (harness-provider-claude--convert-block b)))
                   (push c blocks)))))))
    (nreverse blocks)))

(defun harness-provider-claude--send-user (entry blocks)
  "Write a user message with content BLOCKS to ENTRY's process."
  (harness-provider-claude--send
   entry (list :type "user" :message (list :role "user" :content blocks))))

(defun harness-provider-claude--control-response (entry request-id reply)
  "Answer control request REQUEST-ID on ENTRY with the MCP message REPLY."
  (harness-provider-claude--send
   entry (list :type "control_response"
               :response (list :subtype "success" :request_id request-id
                               :response (list :mcp_response reply)))))

(defun harness-provider-claude--control-error (entry request-id message)
  "Fail control request REQUEST-ID on ENTRY with MESSAGE."
  (harness-provider-claude--send
   entry (list :type "control_response"
               :response (list :subtype "error" :request_id request-id :error message))))

;;;; MCP server

(defun harness-provider-claude--tool-list (entry)
  "Return the MCP tool descriptors for ENTRY's current request."
  (mapcar (lambda (spec)
            (list :name (plist-get spec :name)
                  :description (or (plist-get spec :description) "")
                  :inputSchema (or (plist-get spec :schema)
                                   '(:type "object" :properties :empty))))
          (plist-get (harness-provider-claude-session-request entry) :tools)))

(defun harness-provider-claude--take-tool-id (entry name)
  "Return the pending tool_use id for NAME on ENTRY, or a generated one."
  (let ((cell (cl-find name (harness-provider-claude-session-pending-tools entry)
                       :key #'cdr :test #'equal)))
    (if cell
        (progn (setf (harness-provider-claude-session-pending-tools entry)
                     (delq cell (harness-provider-claude-session-pending-tools entry)))
               (car cell))
      (concat "toolu_" (harness-short-id 12)))))

(defun harness-provider-claude--remember-tool-use (entry id name)
  "Remember that the assistant emitted tool_use ID for NAME on ENTRY."
  (when (and id name
             (not (assoc id (harness-provider-claude-session-pending-tools entry))))
    (setf (harness-provider-claude-session-pending-tools entry)
          (append (harness-provider-claude-session-pending-tools entry)
                  (list (cons id (harness-provider-claude--strip-prefix name)))))))

(defun harness-provider-claude--tools-call (entry request-id message)
  "Serve a tools/call MESSAGE under control request REQUEST-ID on ENTRY."
  (let* ((rpc-id (plist-get message :id))
         (params (plist-get message :params))
         (name (harness-provider-claude--strip-prefix (plist-get params :name)))
         (input (plist-get params :arguments))
         (tool-id (harness-provider-claude--take-tool-id entry name))
         (answered nil)
         (respond
          (lambda (result)
            (unless answered
              (setq answered t)
              (let ((content (plist-get result :content))
                    (is-error (harness-json-true-p (plist-get result :is-error))))
                (push tool-id (harness-provider-claude-session-own-results entry))
                (harness-provider-claude--control-response
                 entry request-id
                 (list :jsonrpc "2.0" :id rpc-id
                       :result (list :content (list (list :type "text"
                                                          :text (if (stringp content) content
                                                                  (format "%s" (or content "")))))
                                     :isError (if is-error t :false)))))))))
    (if (harness-provider-claude-session-active entry)
        (harness-provider-claude--emit
         entry (list :type 'tool-call :id tool-id :name name :input input :respond respond))
      (funcall respond (list :content "The harness is not running a turn" :is-error t)))))

(defun harness-provider-claude--handle-mcp (entry request-id message)
  "Answer the JSON-RPC MESSAGE from the CLI under REQUEST-ID on ENTRY."
  (let ((method (plist-get message :method))
        (rpc-id (plist-get message :id)))
    (pcase method
      ("initialize"
       (harness-provider-claude--control-response
        entry request-id
        (list :jsonrpc "2.0" :id rpc-id
              :result (list :protocolVersion (or (harness-plist-get-in message '(:params :protocolVersion))
                                                 "2025-06-18")
                            :capabilities '(:tools :empty)
                            :serverInfo '(:name "harness" :version "3.0.0")))))
      ("notifications/initialized"
       ;; The CLI waits for an answer even though this is a notification.
       (harness-provider-claude--control-response
        entry request-id '(:jsonrpc "2.0" :id 0 :result :empty)))
      ("tools/list"
       (harness-provider-claude--control-response
        entry request-id
        (list :jsonrpc "2.0" :id rpc-id
              :result (list :tools (harness-json-array (harness-provider-claude--tool-list entry))))))
      ("tools/call"
       (harness-provider-claude--tools-call entry request-id message))
      (_
       (harness-log 'debug "provider-claude: unhandled MCP method %s" method)
       (if rpc-id
           (harness-provider-claude--control-response
            entry request-id (list :jsonrpc "2.0" :id rpc-id :result :empty))
         (harness-provider-claude--control-response
          entry request-id '(:jsonrpc "2.0" :id 0 :result :empty)))))))

(defun harness-provider-claude--handle-control (entry msg)
  "Handle a control_request MSG from the CLI on ENTRY."
  (let* ((request-id (plist-get msg :request_id))
         (request (plist-get msg :request))
         (subtype (plist-get request :subtype)))
    (pcase subtype
      ("mcp_message"
       (if (equal (plist-get request :server_name) "harness")
           (harness-provider-claude--handle-mcp entry request-id (plist-get request :message))
         (harness-provider-claude--control-error
          entry request-id (format "unknown MCP server %s" (plist-get request :server_name)))))
      (_
       (harness-log 'warn "provider-claude: unsupported control request %s" subtype)
       (harness-provider-claude--control-error
        entry request-id (format "unsupported control request %s" subtype))))))

;;;; Messages in

(defun harness-provider-claude--usage-context (usage)
  "Return the prompt size described by the Anthropic USAGE plist, or nil."
  (when (and usage (plist-get usage :input_tokens))
    (+ (or (plist-get usage :input_tokens) 0)
       (or (plist-get usage :cache_read_input_tokens) 0)
       (or (plist-get usage :cache_creation_input_tokens) 0))))

(defun harness-provider-claude--handle-stream (entry event)
  "Handle an Anthropic streaming EVENT on ENTRY."
  (pcase (plist-get event :type)
    ("message_start"
     (when-let* ((ctx (harness-provider-claude--usage-context
                       (plist-get (plist-get event :message) :usage))))
       (setf (harness-provider-claude-session-context entry) ctx)))
    ("message_delta"
     (when-let* ((ctx (harness-provider-claude--usage-context (plist-get event :usage))))
       (setf (harness-provider-claude-session-context entry) ctx)))
    ("content_block_start"
     (let ((block (plist-get event :content_block)))
       (when (equal (plist-get block :type) "tool_use")
         (harness-provider-claude--remember-tool-use
          entry (plist-get block :id) (plist-get block :name)))))
    ("content_block_delta"
     (let* ((delta (plist-get event :delta))
            (kind (plist-get delta :type)))
       (pcase kind
         ("text_delta"
          (let ((text (plist-get delta :text)))
            (unless (harness-string-blank-p text)
              (harness-provider-claude--emit entry (list :type 'text :delta text)))))
         ("thinking_delta"
          (let ((text (plist-get delta :thinking)))
            (unless (or (null text) (string-empty-p text))
              (harness-provider-claude--emit entry (list :type 'thinking :delta text))))))))))

(defun harness-provider-claude--handle-assistant (entry message)
  "Remember tool_use ids from the authoritative assistant MESSAGE on ENTRY."
  (dolist (block (plist-get message :content))
    (when (equal (plist-get block :type) "tool_use")
      (harness-provider-claude--remember-tool-use
       entry (plist-get block :id) (plist-get block :name))))
  (when-let* ((ctx (harness-provider-claude--usage-context (plist-get message :usage))))
    (setf (harness-provider-claude-session-context entry) ctx)))

(defun harness-provider-claude--result-text (content)
  "Flatten a tool_result CONTENT (string or list of blocks) into text."
  (cond ((stringp content) content)
        ((listp content)
         (mapconcat (lambda (b) (or (plist-get b :text) "")) content "\n"))
        (t (format "%s" content))))

(defun harness-provider-claude--handle-user-echo (entry message)
  "Emit tool results from an echoed user MESSAGE on ENTRY, unless they are ours."
  (dolist (block (plist-get message :content))
    (when (equal (plist-get block :type) "tool_result")
      (let ((id (plist-get block :tool_use_id)))
        (if (member id (harness-provider-claude-session-own-results entry))
            (setf (harness-provider-claude-session-own-results entry)
                  (delete id (harness-provider-claude-session-own-results entry)))
          (harness-provider-claude--emit
           entry (list :type 'tool-result :id id
                       :content (harness-provider-claude--result-text (plist-get block :content))
                       :is-error (harness-json-true-p (plist-get block :is_error)))))))))

(defun harness-provider-claude--windows (info)
  "Convert the CLI's rate limit INFO into quota window plists."
  (let (out)
    (cl-loop for (key win) on (plist-get info :unifiedWindows) by #'cddr
             do (push (list :name (pcase key
                                    (:five_hour "5h")
                                    (:seven_day "7d")
                                    (_ (string-remove-prefix ":" (symbol-name key))))
                            :used (plist-get win :utilization)
                            :resets (plist-get win :resetsAt))
                      out))
    (nreverse out)))

(defun harness-provider-claude--handle-init (entry msg)
  "Handle the system/init banner MSG on ENTRY."
  (let ((id (plist-get msg :session_id))
        (model (plist-get msg :model)))
    (setf (harness-provider-claude-session-cli-session-id entry) id
          (harness-provider-claude-session-model entry) model)
    (harness-log 'info "provider-claude: session %s is CLI session %s (%s)"
                 (harness-provider-claude-session-id entry) id model)
    (harness-provider-claude--emit
     entry (list :type 'provider-state :state (list :cli-session-id id :model model)))
    (dolist (server (plist-get msg :mcp_servers))
      (when (and (equal (plist-get server :name) "harness")
                 (not (equal (plist-get server :status) "connected")))
        (harness-log 'error "provider-claude: harness MCP server status %s"
                     (plist-get server :status))
        (harness-provider-claude--emit
         entry (list :type 'hint
                     :text (format "Claude Code reports the harness tool server as %s; tools are unavailable this turn"
                                   (plist-get server :status))))))))

(defun harness-provider-claude--handle-result (entry msg)
  "Handle the turn-ending result MSG on ENTRY."
  (let* ((usage (plist-get msg :usage))
         (input (or (plist-get usage :input_tokens) 0))
         (cache-read (or (plist-get usage :cache_read_input_tokens) 0))
         (cache-write (or (plist-get usage :cache_creation_input_tokens) 0))
         (subtype (or (plist-get msg :subtype) ""))
         (is-error (or (harness-json-true-p (plist-get msg :is_error))
                       (string-prefix-p "error" subtype))))
    (when-let* ((id (plist-get msg :session_id)))
      (setf (harness-provider-claude-session-cli-session-id entry) id))
    (harness-provider-claude--emit
     entry (list :type 'usage :input input
                 :output (or (plist-get usage :output_tokens) 0)
                 :cache-read cache-read :cache-write cache-write
                 :cost (plist-get msg :total_cost_usd)
                 :context (or (harness-provider-claude-session-context entry)
                              (+ input cache-read cache-write))))
    (harness-provider-claude--finish
     entry
     (cond ((harness-provider-claude-session-cancelled entry)
            '(:type done :stop-reason cancelled))
           (is-error
            (list :type 'done :stop-reason 'error
                  :error (let ((text (plist-get msg :result)))
                           (if (and (stringp text) (not (string-empty-p text)))
                               text
                             (format "Claude Code: %s" subtype)))))
           ((equal (plist-get msg :stop_reason) "max_tokens")
            '(:type done :stop-reason max-tokens))
           (t '(:type done :stop-reason end-turn))))))

(defun harness-provider-claude--handle (entry msg)
  "Dispatch one parsed stdout MSG from the CLI on ENTRY."
  (let ((type (plist-get msg :type)))
    (pcase type
      ("control_request" (harness-provider-claude--handle-control entry msg))
      ("control_response"
       (harness-log 'debug "provider-claude: control_response %S" (plist-get msg :response)))
      ("system"
       (pcase (plist-get msg :subtype)
         ("init" (harness-provider-claude--handle-init entry msg))
         ("compact_boundary"
          (harness-provider-claude--emit
           entry '(:type hint :text "Context compacted by Claude Code")))
         (sub (harness-log 'debug "provider-claude: system/%s" sub))))
      ("stream_event" (harness-provider-claude--handle-stream entry (plist-get msg :event)))
      ("assistant" (harness-provider-claude--handle-assistant entry (plist-get msg :message)))
      ("user" (harness-provider-claude--handle-user-echo entry (plist-get msg :message)))
      ("rate_limit_event"
       (setq harness-provider-claude--quota
             (harness-provider-claude--windows (plist-get msg :rate_limit_info)))
       (harness-provider-claude--emit
        entry (list :type 'quota :windows harness-provider-claude--quota)))
      ("result" (harness-provider-claude--handle-result entry msg))
      (_ (harness-log 'debug "provider-claude: ignoring %s message" type)))))

(defun harness-provider-claude--filter (entry chunk)
  "Buffer CHUNK of stdout for ENTRY and handle every complete line."
  (let ((data (concat (harness-provider-claude-session-buffer entry) chunk))
        (start 0) pos)
    (while (setq pos (string-search "\n" data start))
      (let ((line (substring data start pos)))
        (setq start (1+ pos))
        (unless (harness-string-blank-p line)
          (condition-case err
              (let ((msg (harness-json-parse line)))
                (when msg (harness-provider-claude--handle entry msg)))
            (error (harness-log 'error "provider-claude: bad line %s: %S"
                                (harness-truncate-end line 200) err))))))
    (setf (harness-provider-claude-session-buffer entry) (substring data start))))

(defun harness-provider-claude--sentinel (entry proc _event)
  "Handle the death of ENTRY's process PROC."
  (unless (process-live-p proc)
    (when (eq proc (harness-provider-claude-session-process entry))
      (let ((code (process-exit-status proc))
            (tail (harness-provider-claude--stderr-tail entry)))
        (harness-log 'info "provider-claude: process for %s exited %s"
                     (harness-provider-claude-session-id entry) code)
        (harness-provider-claude--finish
         entry
         (if (harness-provider-claude-session-cancelled entry)
             '(:type done :stop-reason cancelled)
           (list :type 'done :stop-reason 'error
                 :error (format "claude exited with status %s%s" code
                                (if (string-empty-p tail) "" (concat ": " tail))))))
        (let ((buf (harness-provider-claude-session-stderr entry)))
          (when (buffer-live-p buf) (kill-buffer buf)))
        (setf (harness-provider-claude-session-stderr entry) nil)))))

;;;; Provider entry points

(defun harness-provider-claude--entry (session-id)
  "Return the process record for SESSION-ID, creating it when needed."
  (or (gethash session-id harness-provider-claude--sessions)
      (puthash session-id (harness-provider-claude--make-session :id session-id)
               harness-provider-claude--sessions)))

(defun harness-provider-claude--ensure-process (entry request)
  "Make sure ENTRY has a live process suitable for REQUEST, spawning if needed."
  (let* ((state (plist-get request :provider-state))
         (model (cdr (harness-provider-parse-model (plist-get request :model))))
         (key (list model (plist-get request :thinking) (plist-get request :system)))
         (proc (harness-provider-claude-session-process entry))
         (live (process-live-p proc)))
    (cond
     ((and live (equal key (harness-provider-claude-session-spawn-key entry))) proc)
     (t
      (let* ((fork (and (not live) (harness-json-true-p (plist-get state :fork-pending))))
             (resume (or (harness-provider-claude-session-cli-session-id entry)
                         (plist-get state :cli-session-id))))
        (when live
          (harness-log 'info "provider-claude: settings changed for %s; restarting with --resume"
                       (harness-provider-claude-session-id entry)))
        (harness-provider-claude--kill entry)
        (harness-provider-claude--spawn entry request resume fork))))))

(defun harness-provider-claude--complete (request)
  "Run REQUEST through the Claude Code CLI; return a handle with `:cancel'."
  (let* ((session (plist-get request :session))
         (sid (or (plist-get session :id) "default"))
         (entry (harness-provider-claude--entry sid))
         (on-event (plist-get request :on-event))
         (blocks (harness-provider-claude--user-blocks request)))
    (when (harness-provider-claude-session-active entry)
      (harness-provider-claude--finish
       entry '(:type done :stop-reason error :error "superseded by a new request")))
    (harness-provider-claude--ensure-process entry request)
    (setf (harness-provider-claude-session-request entry) request
          (harness-provider-claude-session-on-event entry) on-event
          (harness-provider-claude-session-active entry) t
          (harness-provider-claude-session-cancelled entry) nil
          (harness-provider-claude-session-cancel-timer entry) nil
          (harness-provider-claude-session-pending-tools entry) nil
          (harness-provider-claude-session-own-results entry) nil
          (harness-provider-claude-session-context entry) nil)
    (harness-provider-claude--emit entry '(:type start))
    (if (null blocks)
        (harness-provider-claude--finish
         entry '(:type done :stop-reason error :error "No user message to send"))
      (harness-provider-claude--send-user entry blocks))
    (list :cancel (lambda () (harness-provider-claude--cancel entry)))))

(defun harness-provider-claude--cancel (entry)
  "Interrupt the current turn on ENTRY, killing the process if it ignores us."
  (when (and (harness-provider-claude-session-active entry)
             (not (harness-provider-claude-session-cancelled entry)))
    (setf (harness-provider-claude-session-cancelled entry) t)
    (if (not (process-live-p (harness-provider-claude-session-process entry)))
        (harness-provider-claude--finish entry '(:type done :stop-reason cancelled))
      (harness-provider-claude--send
       entry (list :type "control_request" :request_id (harness-uuid)
                   :request '(:subtype "interrupt")))
      (setf (harness-provider-claude-session-cancel-timer entry)
            (run-at-time harness-provider-claude-interrupt-timeout nil
                         #'harness-provider-claude--force-cancel entry)))))

(defun harness-provider-claude--force-cancel (entry)
  "Kill ENTRY's process because an interrupt went unanswered."
  (when (harness-provider-claude-session-active entry)
    (harness-log 'warn "provider-claude: interrupt ignored for %s; killing the process"
                 (harness-provider-claude-session-id entry))
    (harness-provider-claude--kill entry)
    (harness-provider-claude--finish entry '(:type done :stop-reason cancelled))))

(defun harness-provider-claude--fork (_model-id state)
  "Return a promise of provider state for a fork of STATE.
The child starts from the parent's CLI session id; its first turn
resumes it with --fork-session so the cached prefix is reused."
  (let ((id (plist-get state :cli-session-id)))
    (harness-resolved (and id (list :cli-session-id id :fork-pending t)))))

(defun harness-provider-claude--quota ()
  "Return a promise of the last rate-limit windows seen."
  (harness-resolved (list :windows harness-provider-claude--quota)))

(defun harness-provider-claude--models ()
  "Return a promise of the static model catalogue."
  (harness-resolved (mapcar #'copy-sequence harness-provider-claude-models)))

(defun harness-provider-claude-close (session-id)
  "Shut down the CLI process serving SESSION-ID, if any."
  (when-let* ((entry (gethash session-id harness-provider-claude--sessions)))
    (harness-provider-claude--finish entry '(:type done :stop-reason cancelled))
    (harness-provider-claude--kill entry)
    (remhash session-id harness-provider-claude--sessions)
    t))

(defun harness-provider-claude-close-all ()
  "Shut down every CLI process."
  (dolist (id (hash-table-keys harness-provider-claude--sessions))
    (harness-provider-claude-close id)))

(defun harness-provider-claude--on-session-gone (session-id &rest _)
  "Close the process for SESSION-ID when its session is deleted or deactivated."
  (harness-provider-claude-close session-id))

(defun harness-provider-claude--init ()
  "Register the provider and subscribe to session lifecycle events."
  (harness-on 'session/deleted #'harness-provider-claude--on-session-gone)
  (harness-on 'session/deactivated #'harness-provider-claude--on-session-gone))

(harness-define-provider 'claude
  :label "Claude Code"
  :doc "Claude models through the official claude CLI (subscription friendly)."
  :models #'harness-provider-claude--models
  :complete #'harness-provider-claude--complete
  :fork #'harness-provider-claude--fork
  :quota #'harness-provider-claude--quota
  :capabilities harness-provider-claude-capabilities)

(harness-define-module 'provider-claude
  :doc "Claude Code CLI as a hosted-loop completion provider."
  :requires '(provider)
  :init #'harness-provider-claude--init
  :shutdown #'harness-provider-claude-close-all)

(provide 'harness-provider-claude)
;;; harness-provider-claude.el ends here
