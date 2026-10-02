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
;; - The harness's permission system decides every tool call, so the
;;   CLI only has to let the harness's tools through, never bypass its
;;   checks: `harness-provider-claude-permission-args' fixes its
;;   permission mode and allows `mcp__harness__*' by rule.  When a
;;   permission prompt tool sends the CLI's prompts here instead
;;   (`can_use_tool' control requests), the harness's tools are allowed
;;   and any other refused.  A call the CLI refuses on its own
;;   (`system/permission_denied') becomes a hint.
;; - One built-in tool can stand in for a harness tool: WebSearch for
;;   web_search (`harness-provider-claude-builtin-tools').  A request
;;   whose `:builtin-tools' names it gets `--tools WebSearch', and
;;   `--permission-prompt-tool stdio' unless the permission arguments
;;   already send the prompts somewhere, so the CLI asks before each
;;   search.  The model's tool_use becomes a `tool-call' marked
;;   `:builtin', the CLI's question a `tool-permission' that the
;;   harness's permission chain answers, and the echoed tool_result a
;;   `tool-result'; all three name the harness tool.
;; - Streaming deltas arrive as `stream_event' messages carrying
;;   Anthropic streaming events; `assistant' messages are authoritative
;;   and are used to remember tool_use ids; `result' ends the turn.
;;   The start of each content block, the size of a tool call's input
;;   as it streams and the CLI's compacting notice become `activity'
;;   events: thinking arrives without its text, so they are all that
;;   shows the model is busy.
;; - `--resume ID' recreates a session after a restart and `--resume ID
;;   --fork-session' implements `:fork': the new session starts from
;;   the parent's cached prefix.
;; - Every new process is sent an `initialize' and a `get_usage' control
;;   request.  The initialize answer names the account the CLI is logged
;;   in with, which decides how turns are billed; the usage report (the
;;   data behind the CLI's /usage, fetched without a model call) gives
;;   the plan's quota and the cost total the process starts from.
;;
;; Pricing.  A `result' carries `total_cost_usd', a running total for
;; the whole process that `--resume' seeds with the session's earlier
;; spend, so a turn costs the difference to the previous total.  That
;; figure is the CLI's estimate at API list prices.  With an API key, a
;; bearer token or a cloud provider it is what the turn costs.  With a
;; claude.ai subscription nobody pays it: the usage event says
;; `:billing subscription' with the plan, `:cost 0' and the estimate as
;; `:list-cost', unless the account is drawing on extra usage, which is
;; billed at API prices (`:billing extra-usage').
;;
;; Quota.  The plan's windows (the 5-hour session, the week, per-model
;; weeks) and its extra usage come from usage reports and
;; `rate_limit_event' messages.  `provider/quota' returns them, fetched
;; again through a live process, or a short-lived probe process when
;; none runs, once they are older than `harness-provider-claude-quota-ttl';
;; every change is announced as `provider/quota-updated'.
;;
;; Nothing here blocks: output is handled in a process filter, death in
;; a sentinel, and cancellation by an interrupt request plus a timer.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'parse-time)
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

(defcustom harness-provider-claude-permission-args
  '("--permission-mode" "default" "--allowedTools" "mcp__harness__*")
  "Arguments that let the `claude' CLI run the harness's tools.
The CLI gets the harness's own MCP tools and no built-in tools, but
those standing in for a harness tool (WebSearch for web_search, see
`harness-provider-claude-builtin-tools'), and the harness's permission
system decides each call, so the CLI only has to let them through.  The
default fixes the CLI's permission mode, so no settings file starts it
in plan or auto mode, and allows every harness tool by rule.  When
WebSearch is on, \"--permission-prompt-tool stdio\" is added so that
the CLI asks the harness before each search, unless these arguments
already settle where its prompts go.

Where managed settings make the CLI ignore such rules,
\(\"--permission-mode\" \"default\" \"--permission-prompt-tool\" \"stdio\")
has the CLI ask the harness instead, which lets its own tools through,
decides the stand-ins with its permission rules and refuses any other.
\(\"--permission-mode\" \"bypassPermissions\") skips the CLI's checks
altogether, as the harness once did, so WebSearch then runs without
the harness's say; managed settings may forbid it."
  :type '(choice (const :tag "Allow the harness's tools by rule"
                        ("--permission-mode" "default" "--allowedTools" "mcp__harness__*"))
                 (const :tag "Let the CLI ask the harness"
                        ("--permission-mode" "default" "--permission-prompt-tool" "stdio"))
                 (const :tag "Bypass the CLI's permission checks"
                        ("--permission-mode" "bypassPermissions"))
                 (repeat :tag "Other arguments" string))
  :group 'harness)

(defcustom harness-provider-claude-quota-ttl 60
  "Seconds after which the plan's quota report counts as stale.
A stale report is fetched again after a turn and when `provider/quota'
is asked.  The report comes from the CLI's usage endpoint and makes no
model call.  nil fetches it only when nothing is known yet."
  :type '(choice (const :tag "Only once" nil) number) :group 'harness)

(defcustom harness-provider-claude-probe-timeout 20
  "Seconds to wait for a usage report before answering with what is known."
  :type 'number :group 'harness)

(defcustom harness-provider-claude-progress-interval 0.25
  "Seconds between reports of how much of a tool call's input has streamed."
  :type 'number :group 'harness)

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

(defconst harness-provider-claude-builtin-tools
  '(("web_search" . "WebSearch"))
  "Harness tools that a tool of Claude Code can stand in for.
Each entry is (HARNESS-NAME . CLI-NAME).  WebSearch searches the web on
Anthropic's side.  A request's `:builtin-tools' (see `tools/builtin')
names the harness tools whose stand-ins to turn on.")

(defconst harness-provider-claude-capabilities
  '(:hosted-loop t :fork t :resume t :vision t :thinking t :quota t
    :compaction hosted :cost-reported t :billing t :cache-status t
    :builtin-tools ("web_search"))
  "Capabilities of every Claude Code model.
`:builtin-tools' names the harness tools of
`harness-provider-claude-builtin-tools'.")

(defconst harness-provider-claude--api-token-sources '("ANTHROPIC_AUTH_TOKEN" "apiKeyHelper")
  "Token sources the CLI reports for credentials billed per token.")

(defconst harness-provider-claude--window-keys
  '((five_hour "5h" "Current session (5 hours)")
    (seven_day "7d" "This week, all models")
    (seven_day_opus "7d Opus" "This week, Opus")
    (seven_day_sonnet "7d Sonnet" "This week, Sonnet")
    (seven_day_oauth_apps "7d apps" "This week, apps"))
  "Rate-limit window keys of the CLI as (KEY NAME LABEL).")

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
  context            ; input size of the last API call, from stream usage
  ;; Slots added later go last, see `harness-provider-claude--drop-stale-entries'.
  account            ; how this process is billed, from its initialize answer
  cost-total         ; the CLI's running cost total so far; nil while unknown
  baseline-id        ; id of the usage request whose session total starts it
  seen-output        ; non-nil once the CLI produced a reply or a result
  probe)             ; non-nil for a quota probe, which serves no session

(defvar harness-provider-claude--sessions (make-hash-table :test 'equal)
  "Harness session id -> `harness-provider-claude-session'.")

(defvar harness-provider-claude--status nil
  "What the CLI last said about the account, in the shape `provider/quota' returns.")

(defvar harness-provider-claude--refresh nil
  "The usage request in flight as (REQUEST-ID PROMISE TIMER), or nil.")

(defvar harness-provider-claude--probe nil
  "The running quota probe record, or nil.")

(defvar harness-provider-claude--request-count 0
  "Counter that keeps control request ids unique.")

(defvar harness-provider-claude--asked nil
  "When a usage report was last asked for, as a float time.")

(defvar harness-provider-claude--blocks (make-hash-table :test 'equal)
  "Harness session id -> the tool_use block streaming now, as a plist.
Kept beside the session records rather than in them, so reloading this
file leaves the running CLI processes alone.")

(defvar harness-provider-claude--builtin-calls (make-hash-table :test 'equal)
  "Harness session id -> the calls of the CLI's own tools in the current turn.
Each is a plist (:id TOOL-USE-ID :name HARNESS-NAME :input INPUT :asked
BOOL), `:asked' once the CLI asked whether it may run.  Kept beside the
session records, as `harness-provider-claude--blocks' is.")

(defun harness-provider-claude--drop-stale-entries ()
  "Stop the CLI processes of records older than the current record layout.
A reload keeps live records; one made before slots were added has no
room for them, so its process stops and the session's next turn
resumes the CLI session in a new one."
  (let ((size (length (harness-provider-claude--make-session))))
    (maphash (lambda (id entry)
               (when (< (length entry) size)
                 (let ((proc (harness-provider-claude-session-process entry))
                       (stderr (harness-provider-claude-session-stderr entry))
                       (fn (harness-provider-claude-session-on-event entry)))
                   (when (process-live-p proc)
                     (set-process-sentinel proc #'ignore)
                     (set-process-filter proc #'ignore)
                     (delete-process proc))
                   (when (buffer-live-p stderr) (kill-buffer stderr))
                   (when (and fn (harness-provider-claude-session-active entry))
                     (ignore-errors
                       (funcall fn '(:type done :stop-reason error
                                     :error "The Claude provider was reloaded during this turn")))))
                 (remhash id harness-provider-claude--sessions)))
             harness-provider-claude--sessions)))

(harness-provider-claude--drop-stale-entries)

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
    (harness-provider-claude--end-block entry)
    (remhash (harness-provider-claude-session-id entry) harness-provider-claude--builtin-calls)
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

(defun harness-provider-claude--prompts-routed-p (args)
  "Non-nil when the CLI arguments ARGS settle where its permission prompts go.
They name a permission prompt tool, or skip the CLI's checks."
  (cl-some (lambda (a)
             (or (member a '("--permission-prompt-tool" "--dangerously-skip-permissions"))
                 (string-prefix-p "--permission-prompt-tool=" a)
                 (equal a "--permission-mode=bypassPermissions")))
           (append args
                   (cl-loop for (a b) on args
                            when (equal a "--permission-mode")
                            collect (concat a "=" b)))))

(defun harness-provider-claude--ask-args (builtin)
  "Return the arguments that make the CLI ask before it runs a BUILTIN tool.
BUILTIN lists the CLI's own tools turned on.  The CLI then sends its
permission prompts here as `can_use_tool' requests, which the harness's
permission chain answers for those tools; the harness's own tools stay
allowed by rule.  Nothing when there is no BUILTIN tool, or when
`harness-provider-claude-permission-args' or
`harness-provider-claude-extra-args' already settle where the prompts
go."
  (unless (or (null builtin)
              (harness-provider-claude--prompts-routed-p
               (append harness-provider-claude-permission-args harness-provider-claude-extra-args)))
    (list "--permission-prompt-tool" "stdio")))

(defun harness-provider-claude--command (model effort system resume fork &optional builtin)
  "Build the `claude' command line.
MODEL is the model name, EFFORT the thinking level or nil, SYSTEM the
system prompt or nil, RESUME a CLI session id to continue or nil, and
FORK non-nil to fork RESUME into a new session.  BUILTIN lists the
CLI's own tools to turn on (\"WebSearch\"); every other one is off."
  (append
   (list harness-provider-claude-program
         "-p" "--input-format" "stream-json" "--output-format" "stream-json"
         "--verbose" "--include-partial-messages"
         "--tools" (string-join builtin ",")
         "--strict-mcp-config"
         "--mcp-config" (harness-json-encode
                         '(:mcpServers (:harness (:type "sdk" :name "harness")))))
   harness-provider-claude-permission-args
   (harness-provider-claude--ask-args builtin)
   (list "--model" model)
   (when effort (list "--effort" effort))
   (when (and system (not (harness-string-blank-p system)))
     (list "--system-prompt" system))
   (when resume (list "--resume" resume))
   (when (and resume fork) (list "--fork-session"))
   harness-provider-claude-extra-args))

(defun harness-provider-claude--cli-tools (request)
  "Return the CLI's own tools that REQUEST turns on, by their CLI names.
They stand in for the harness tools its `:builtin-tools' names."
  (let ((wanted (plist-get request :builtin-tools)))
    (delq nil (mapcar (lambda (cell) (and (member (car cell) wanted) (cdr cell)))
                      harness-provider-claude-builtin-tools))))

(defun harness-provider-claude--spawn-key (request)
  "Return the settings a CLI process must have been started with to serve REQUEST.
That is (MODEL EFFORT SYSTEM), and the CLI tools it turns on when it
turns any on: a process started otherwise is restarted."
  (let ((builtin (harness-provider-claude--cli-tools request)))
    (append (list (cdr (harness-provider-parse-model (plist-get request :model)))
                  (plist-get request :thinking)
                  (plist-get request :system))
            (and builtin (list builtin)))))

(defun harness-provider-claude--builtin-name (entry name)
  "Return the harness tool that the CLI's tool NAME stands in for on ENTRY, or nil.
Only the tools ENTRY's process was started with count."
  (and (stringp name)
       (member name (nth 3 (harness-provider-claude-session-spawn-key entry)))
       (car (rassoc name harness-provider-claude-builtin-tools))))

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
         (command (harness-provider-claude--command model effort system resume fork
                                                    (harness-provider-claude--cli-tools request)))
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
    (harness-log 'info "provider-claude: spawned for %s%s%s%s"
                 (harness-provider-claude-session-id entry)
                 (if resume (format " (resume %s)" resume) "")
                 (if fork " forked" "")
                 (let ((builtin (harness-provider-claude--cli-tools request)))
                   (if builtin (format " with %s" (string-join builtin ", ")) "")))
    (setf (harness-provider-claude-session-process entry) proc
          (harness-provider-claude-session-stderr entry) stderr
          (harness-provider-claude-session-buffer entry) ""
          (harness-provider-claude-session-spawn-key entry) (harness-provider-claude--spawn-key request)
          (harness-provider-claude-session-account entry) nil
          ;; A fresh CLI session starts from zero; a resumed or forked
          ;; one from the spend it restores, which the usage report says.
          (harness-provider-claude-session-cost-total entry) (if resume nil 0.0)
          (harness-provider-claude-session-seen-output entry) nil)
    (harness-provider-claude--send
     entry '(:type "control_request" :request_id "init-1"
             :request (:subtype "initialize" :sdkMcpServers ("harness"))))
    (setf (harness-provider-claude-session-baseline-id entry)
          (harness-provider-claude--request-usage entry))
    proc))

(defun harness-provider-claude--kill (entry)
  "Kill ENTRY's process and its stderr buffer."
  (let ((proc (harness-provider-claude-session-process entry))
        (buf (harness-provider-claude-session-stderr entry)))
    (when (process-live-p proc)
      (set-process-sentinel proc #'ignore)
      (delete-process proc))
    (when (buffer-live-p buf) (kill-buffer buf))
    (harness-provider-claude--end-block entry)
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

(defun harness-provider-claude--answer-permission (entry request-id answer)
  "Answer the CLI's permission prompt REQUEST-ID on ENTRY with ANSWER."
  (harness-provider-claude--send
   entry (list :type "control_response"
               :response (list :subtype "success" :request_id request-id :response answer))))

(defun harness-provider-claude--can-use-tool (entry request-id request)
  "Answer the CLI's permission prompt REQUEST under REQUEST-ID on ENTRY.
The CLI asks when a permission prompt tool sends its prompts here (see
`harness-provider-claude-permission-args' and
`harness-provider-claude--ask-args').  The harness's own tools are let
through, since the harness's permission system decides each call when
it serves it.  A tool of the CLI's that stands in for a harness tool
goes to the turn, whose permission chain decides it (see
`harness-provider-claude--ask-builtin'); any other tool is refused."
  (let* ((name (plist-get request :tool_name))
         (ours (and (stringp name) (string-prefix-p harness-provider-claude-tool-prefix name)))
         (builtin (and (not ours) (harness-provider-claude--builtin-name entry name))))
    (if (and builtin (harness-provider-claude-session-active entry))
        (harness-provider-claude--ask-builtin entry request-id request builtin)
      (harness-log 'debug "provider-claude: %s %s for %s"
                   (if ours "allowing" "refusing") name (harness-provider-claude-session-id entry))
      (harness-provider-claude--answer-permission
       entry request-id
       (cond (ours
              ;; Parsing turned {} into nil, which would go back as null.
              (list :behavior "allow" :updatedInput (or (plist-get request :input) :empty)))
             (builtin (list :behavior "deny" :message "The harness is not running a turn"))
             (t (list :behavior "deny"
                      :message (format "The harness runs only its own tools, and %s is not one of them"
                                       name))))))))

;;;; The CLI's own tools

(defun harness-provider-claude--builtin-calls (entry)
  "Return the calls of the CLI's own tools in ENTRY's current turn."
  (gethash (harness-provider-claude-session-id entry) harness-provider-claude--builtin-calls))

(defun harness-provider-claude--builtin-call (entry id)
  "Return the record of call ID of one of the CLI's own tools on ENTRY, or nil."
  (cl-find id (harness-provider-claude--builtin-calls entry)
           :key (lambda (c) (plist-get c :id)) :test #'equal))

(defun harness-provider-claude--announce-builtin (entry id name input)
  "Report call ID on ENTRY of the CLI's tool standing in for harness tool NAME.
INPUT is its input.  The turn hears of each call once, as a `tool-call'
marked `:builtin'.  Return the call's record."
  (or (harness-provider-claude--builtin-call entry id)
      (let ((call (list :id id :name name :input input :asked nil))
            (sid (harness-provider-claude-session-id entry)))
        (puthash sid (append (gethash sid harness-provider-claude--builtin-calls) (list call))
                 harness-provider-claude--builtin-calls)
        (harness-provider-claude--emit
         entry (list :type 'tool-call :id id :name name :input input :builtin t))
        call)))

(defun harness-provider-claude--ask-builtin (entry request-id request name)
  "Ask the turn on ENTRY whether the CLI may run its tool standing in for NAME.
REQUEST is the CLI's `can_use_tool' prompt, answered under REQUEST-ID
once the harness has decided: the `tool-permission' event's `:respond'
gets the harness's DECISION.  CLIs that do not say which call they ask
about mean the oldest one not asked about yet."
  (let* ((id (or (plist-get request :tool_use_id)
                 (plist-get (cl-find-if (lambda (c) (and (equal name (plist-get c :name))
                                                         (not (plist-get c :asked))))
                                        (harness-provider-claude--builtin-calls entry))
                            :id)
                 (concat "toolu_" (harness-short-id 12))))
         (input (or (plist-get request :input)
                    (plist-get (harness-provider-claude--builtin-call entry id) :input)))
         (call (harness-provider-claude--announce-builtin entry id name input))
         (answered nil))
    (plist-put call :asked t)
    (harness-log 'debug "provider-claude: asking the harness about %s (%s) for %s"
                 name id (harness-provider-claude-session-id entry))
    (harness-provider-claude--emit
     entry
     (list :type 'tool-permission :id id :name name :input input
           :respond
           (lambda (decision)
             (unless answered
               (setq answered t)
               (harness-provider-claude--answer-permission
                entry request-id
                (if (eq (plist-get decision :behavior) 'allow)
                    ;; Parsing turned {} into nil, which would go back as null.
                    (list :behavior "allow" :updatedInput (or (plist-get decision :input) input :empty))
                  (list :behavior "deny"
                        :message (or (plist-get decision :message) "The harness denied this call"))))))))))

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
      ("can_use_tool" (harness-provider-claude--can-use-tool entry request-id request))
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

;; What the model is producing, as `activity' events.  The CLI streams a
;; thinking block without its text (only a signature arrives, at its
;; end) and a tool call's input as JSON fragments nobody reads before
;; the call itself, so without these a turn shows nothing for as long
;; as the model thinks or writes a large input.

(defun harness-provider-claude--start-tool-input (entry name)
  "Begin reporting the input of a call to tool NAME streaming on ENTRY."
  (puthash (harness-provider-claude-session-id entry)
           (list :tool name :chars 0 :sent-at (float-time) :timer nil)
           harness-provider-claude--blocks)
  (harness-provider-claude--emit entry (list :type 'activity :phase 'tool-input :tool name :chars 0)))

(defun harness-provider-claude--report-input (entry block)
  "Report how much of BLOCK's tool input has streamed on ENTRY.
BLOCK's keys all exist from the start, so it is updated in place."
  (when-let* ((timer (plist-get block :timer)))
    (cancel-timer timer))
  (setf (plist-get block :timer) nil
        (plist-get block :sent-at) (float-time))
  (harness-provider-claude--emit entry (list :type 'activity :phase 'tool-input
                                             :tool (plist-get block :tool)
                                             :chars (plist-get block :chars))))

(defun harness-provider-claude--input-progress (entry chars)
  "Count CHARS more characters of the tool input streaming on ENTRY.
Reports go out at most every `harness-provider-claude-progress-interval'
seconds; one held back goes out when the interval is up, unless the
block has ended by then, so a report never follows the call it is about."
  (when-let* ((block (gethash (harness-provider-claude-session-id entry) harness-provider-claude--blocks)))
    (setf (plist-get block :chars) (+ chars (plist-get block :chars)))
    (let ((wait (- (+ (plist-get block :sent-at) harness-provider-claude-progress-interval) (float-time))))
      (cond ((<= wait 0) (harness-provider-claude--report-input entry block))
            ((null (plist-get block :timer))
             (setf (plist-get block :timer)
                   (run-at-time wait nil
                                (lambda ()
                                  (setf (plist-get block :timer) nil)
                                  (when (eq block (gethash (harness-provider-claude-session-id entry)
                                                           harness-provider-claude--blocks))
                                    (harness-provider-claude--report-input entry block))))))))))

(defun harness-provider-claude--end-block (entry)
  "Forget the tool input streaming on ENTRY, if any."
  (let ((sid (harness-provider-claude-session-id entry)))
    (when-let* ((block (gethash sid harness-provider-claude--blocks)))
      (when-let* ((timer (plist-get block :timer)))
        (cancel-timer timer))
      (remhash sid harness-provider-claude--blocks))))

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
       (harness-provider-claude--end-block entry)
       (pcase (plist-get block :type)
         ("tool_use"
          (harness-provider-claude--remember-tool-use
           entry (plist-get block :id) (plist-get block :name))
          (harness-provider-claude--start-tool-input
           entry (or (harness-provider-claude--builtin-name entry (plist-get block :name))
                     (harness-provider-claude--strip-prefix (plist-get block :name)))))
         ((or "thinking" "redacted_thinking")
          (harness-provider-claude--emit entry '(:type activity :phase thinking)))
         ("text"
          (harness-provider-claude--emit entry '(:type activity :phase writing))))))
    ("content_block_stop" (harness-provider-claude--end-block entry))
    ("content_block_delta"
     (let* ((delta (plist-get event :delta))
            (kind (plist-get delta :type)))
       (pcase kind
         ;; Whitespace counts: a delta of "\n\n" separates paragraphs.
         ;; The agent keeps whitespace from opening a message by itself.
         ("text_delta"
          (let ((text (plist-get delta :text)))
            (unless (or (not (stringp text)) (string-empty-p text))
              (harness-provider-claude--emit entry (list :type 'text :delta text)))))
         ("thinking_delta"
          (let ((text (plist-get delta :thinking)))
            (unless (or (not (stringp text)) (string-empty-p text))
              (harness-provider-claude--emit entry (list :type 'thinking :delta text)))))
         ("input_json_delta"
          (let ((json (plist-get delta :partial_json)))
            (when (stringp json)
              (harness-provider-claude--input-progress entry (length json))))))))))

(defun harness-provider-claude--handle-assistant (entry message)
  "Remember tool_use ids from the authoritative assistant MESSAGE on ENTRY.
A call of the CLI's own tools that stands in for a harness tool is
reported to the turn here, where its input is complete."
  (dolist (block (plist-get message :content))
    (when (equal (plist-get block :type) "tool_use")
      (harness-provider-claude--remember-tool-use
       entry (plist-get block :id) (plist-get block :name))
      (when-let* ((name (harness-provider-claude--builtin-name entry (plist-get block :name))))
        (harness-provider-claude--announce-builtin
         entry (plist-get block :id) name (plist-get block :input)))))
  (when-let* ((ctx (harness-provider-claude--usage-context (plist-get message :usage))))
    (setf (harness-provider-claude-session-context entry) ctx)))

(defun harness-provider-claude--result-text (content)
  "Flatten a tool_result CONTENT (string or list of blocks) into text."
  (cond ((stringp content) content)
        ((listp content)
         (mapconcat (lambda (b) (or (plist-get b :text) "")) content "\n"))
        (t (format "%s" content))))

(defun harness-provider-claude--handle-user-echo (entry message)
  "Emit tool results from an echoed user MESSAGE on ENTRY, unless they are ours.
The result of a call of the CLI's own tools that the turn has not heard
of yet comes after the call itself."
  (dolist (block (plist-get message :content))
    (when (equal (plist-get block :type) "tool_result")
      (let ((id (plist-get block :tool_use_id)))
        (if (member id (harness-provider-claude-session-own-results entry))
            (setf (harness-provider-claude-session-own-results entry)
                  (delete id (harness-provider-claude-session-own-results entry)))
          (when-let* ((name (harness-provider-claude--builtin-name
                             entry (cdr (assoc id (harness-provider-claude-session-pending-tools entry))))))
            (harness-provider-claude--announce-builtin entry id name nil))
          (harness-provider-claude--emit
           entry (list :type 'tool-result :id id
                       :content (harness-provider-claude--result-text (plist-get block :content))
                       :is-error (harness-json-true-p (plist-get block :is_error)))))))))

(defun harness-provider-claude--handle-denial (entry msg)
  "Report that the CLI refused to run a tool, from the system MSG on ENTRY.
The harness never hears of a harness tool's call that the CLI refuses,
so the user learns of it here; nor does it decide on one of the CLI's
own tools that the CLI's rules refuse."
  (let* ((name (plist-get msg :tool_name))
         (why (or (plist-get msg :message) "permission denied"))
         (builtin (harness-provider-claude--builtin-name entry name)))
    (cond
     ((and (stringp name) (string-prefix-p harness-provider-claude-tool-prefix name))
      (harness-log 'warn "provider-claude: Claude Code denied %s for %s: %s"
                   name (harness-provider-claude-session-id entry) why)
      (harness-provider-claude--emit
       entry (list :type 'hint
                   :text (format (concat "Claude Code refused to run %s; its permission rules must let"
                                         " the harness's tools through (see the setting"
                                         " harness-provider-claude-permission-args).  It said: %s")
                                 (harness-provider-claude--strip-prefix name) why))))
     (builtin
      (harness-log 'warn "provider-claude: Claude Code denied its %s for %s: %s"
                   name (harness-provider-claude-session-id entry) why)
      (harness-provider-claude--emit
       entry (list :type 'hint
                   :text (format (concat "Claude Code refused to run its %s, which stands in for %s;"
                                         " its permission rules must leave the decision to the harness"
                                         " (see the setting harness-provider-claude-permission-args)."
                                         "  It said: %s")
                                 name builtin why)))))))

;;;; Account, billing and quota

(defun harness-provider-claude--compact (plist)
  "Return PLIST without the keys whose value is nil."
  (let (out)
    (cl-loop for (k v) on plist by #'cddr
             when v do (setq out (append out (list k v))))
    out))

(defun harness-provider-claude--time (value)
  "Return VALUE, epoch seconds or an ISO 8601 string, as a float time, or nil."
  (cond ((numberp value) (float value))
        ((and (stringp value) (not (string-empty-p value)))
         (condition-case nil (float-time (parse-iso8601-time-string value)) (error nil)))))

(defun harness-provider-claude--plan-id (label)
  "Return the plan id of subscription LABEL (\"Claude Max\" gives \"max\"), or nil."
  (when (and (stringp label) (string-match "\\([[:alnum:]_]+\\)[[:space:]]*\\'" label))
    (let ((id (downcase (match-string 1 label))))
      ;; Old CLIs called every login "Claude API".
      (unless (member id '("api" "claude")) id))))

(defun harness-provider-claude--plan-label (plan)
  "Return the display name of subscription PLAN (\"max\" gives \"Claude Max\")."
  (when (and (stringp plan) (not (string-empty-p plan)))
    (concat "Claude " (capitalize (replace-regexp-in-string "_" " " plan)))))

(defun harness-provider-claude-account-info (account)
  "Classify ACCOUNT, the `account' plist of the CLI's initialize answer.
Return (:billing BILLING :plan ID :plan-label LABEL :auth SOURCE
:api-provider NAME :account (:email :organization)).  BILLING is
`subscription' for a claude.ai login (Pro, Max, Team, Enterprise),
`api' for an API key, an API key helper, a bearer token or a cloud
provider (Bedrock, Vertex, Foundry), and nil when the answer does
not say."
  (let* ((provider (plist-get account :apiProvider))
         (key (plist-get account :apiKeySource))
         (token (plist-get account :tokenSource))
         (label (plist-get account :subscriptionType))
         (email (plist-get account :email))
         (key (and (stringp key) (not (member key '("" "none"))) key))
         (cloud (and (stringp provider) (not (member provider '("" "firstParty"))) provider))
         (bearer (and (member token harness-provider-claude--api-token-sources) token))
         (billing (cond ((or cloud key bearer) 'api)
                        ((or (stringp label) (stringp email)
                             (equal token "CLAUDE_CODE_OAUTH_TOKEN"))
                         'subscription)))
         (subscription (eq billing 'subscription))
         (plan (and subscription (harness-provider-claude--plan-id label))))
    (list :billing billing
          :plan plan
          :plan-label (and plan label)
          :auth (or cloud key bearer
                    (and (stringp token) (not (member token '("" "none"))) token)
                    (and subscription "claude.ai"))
          :api-provider (and (stringp provider) provider)
          :account (and subscription (stringp email)
                        (harness-provider-claude--compact
                         (list :email email :organization (plist-get account :organization)))))))

(defun harness-provider-claude--window-name (key)
  "Return (NAME LABEL) of the rate-limit window KEY, a keyword or symbol."
  (let* ((name (string-remove-prefix ":" (format "%s" key)))
         (known (assq (intern name) harness-provider-claude--window-keys)))
    (if known (cdr known) (list name (replace-regexp-in-string "_" " " name)))))

(defun harness-provider-claude--limit-window (limit)
  "Convert LIMIT, one entry of a usage report's `limits', into a window plist."
  (let* ((kind (format "%s" (or (plist-get limit :kind) "limit")))
         (scope (plist-get limit :scope))
         (model (or (harness-plist-get-in scope '(:model :display_name))
                    (harness-plist-get-in scope '(:surface :display_name))))
         (percent (plist-get limit :percent)))
    (harness-provider-claude--compact
     (list :name (pcase kind
                   ("session" "5h")
                   ("weekly_all" "7d")
                   ("weekly_scoped" (if model (concat "7d " model) "7d scoped"))
                   (_ (if model (format "%s %s" kind model) kind)))
           :label (pcase kind
                    ("session" "Current session (5 hours)")
                    ("weekly_all" "This week, all models")
                    ("weekly_scoped" (concat "This week, " (or model "scoped")))
                    (_ (concat (replace-regexp-in-string "_" " " kind)
                               (if model (concat ", " model) ""))))
           :kind kind
           :model model
           :used (and (numberp percent) (/ percent 100.0))
           :resets (harness-provider-claude--time (plist-get limit :resets_at))
           :severity (plist-get limit :severity)
           :active (harness-json-true-p (plist-get limit :is_active))))))

(defun harness-provider-claude--usage-windows (rate-limits)
  "Return the quota windows a usage report's RATE-LIMITS describes.
Recent CLIs list them under `limits'; older ones only name each window."
  (let ((limits (plist-get rate-limits :limits)))
    (if (consp limits)
        (mapcar #'harness-provider-claude--limit-window limits)
      (let (out)
        (dolist (k harness-provider-claude--window-keys)
          (let ((w (plist-get rate-limits (intern (format ":%s" (car k))))))
            (when (and (consp w) (numberp (plist-get w :utilization)))
              (push (harness-provider-claude--compact
                     (list :name (nth 1 k) :label (nth 2 k)
                           :used (/ (plist-get w :utilization) 100.0)
                           :resets (harness-provider-claude--time (plist-get w :resets_at))))
                    out))))
        (dolist (m (plist-get rate-limits :model_scoped))
          (when (numberp (plist-get m :utilization))
            (let ((model (or (plist-get m :display_name) "model")))
              (push (harness-provider-claude--compact
                     (list :name (concat "7d " model) :label (concat "This week, " model)
                           :model model :used (/ (plist-get m :utilization) 100.0)
                           :resets (harness-provider-claude--time (plist-get m :resets_at))))
                    out))))
        (nreverse out)))))

(defun harness-provider-claude--money (amount)
  "Return AMOUNT, a (:amount_minor N :exponent E) plist, in major units, or nil."
  (let ((minor (plist-get amount :amount_minor)))
    (and (numberp minor) (/ minor (expt 10.0 (or (plist-get amount :exponent) 2))))))

(defun harness-provider-claude--extra (rate-limits)
  "Return the extra usage a usage report's RATE-LIMITS describes, or nil.
The result is (:enabled BOOL :used F :limit F :currency STRING
:disabled-reason STRING); extra usage is what a subscription draws on,
at API prices, once a window is used up."
  (let ((spend (plist-get rate-limits :spend))
        (extra (plist-get rate-limits :extra_usage)))
    (cond
     ((consp spend)
      (harness-provider-claude--compact
       (list :enabled (harness-json-true-p (plist-get spend :enabled))
             :used (harness-provider-claude--money (plist-get spend :used))
             :limit (harness-provider-claude--money (plist-get spend :limit))
             :currency (or (harness-plist-get-in spend '(:limit :currency))
                           (harness-plist-get-in spend '(:used :currency))
                           "USD")
             :disabled-reason (plist-get spend :disabled_reason))))
     ((consp extra)
      (let ((scale (expt 10.0 (or (plist-get extra :decimal_places) 2)))
            (used (plist-get extra :used_credits))
            (limit (plist-get extra :monthly_limit)))
        (harness-provider-claude--compact
         (list :enabled (harness-json-true-p (plist-get extra :is_enabled))
               :used (and (numberp used) (/ used scale))
               :limit (and (numberp limit) (/ limit scale))
               :currency (or (plist-get extra :currency) "USD")
               :disabled-reason (plist-get extra :disabled_reason))))))))

(defun harness-provider-claude--usage-changes (report)
  "Return the account status changes a get_usage REPORT implies, or nil."
  (when (or (plist-member report :rate_limits_available) (plist-member report :subscription_type))
    (let* ((status harness-provider-claude--status)
           (available (harness-json-true-p (plist-get report :rate_limits_available)))
           (rate-limits (plist-get report :rate_limits))
           (plan (plist-get report :subscription_type))
           (plan (and (stringp plan) (not (string-empty-p plan)) (downcase plan))))
      (append
       (list :updated (float-time) :available available
             :windows (and available (harness-provider-claude--usage-windows rate-limits))
             :extra (and available (harness-provider-claude--extra rate-limits)))
       (when plan
         (list :plan plan
               :plan-label (if (equal plan (plist-get status :plan))
                               (or (plist-get status :plan-label) (harness-provider-claude--plan-label plan))
                             (harness-provider-claude--plan-label plan))))
       ;; A plan with quota is a subscription even when the account said nothing.
       (when (and (null (plist-get status :billing)) (or plan available))
         (list :billing 'subscription))))))

(defun harness-provider-claude--windows (info)
  "Convert the `unifiedWindows' of a rate_limit_event INFO into window plists."
  (let (out)
    (cl-loop for (key win) on (plist-get info :unifiedWindows) by #'cddr
             do (pcase-let ((`(,name ,label) (harness-provider-claude--window-name key)))
                  (push (harness-provider-claude--compact
                         (list :name name :label label
                               :used (plist-get win :utilization)
                               :resets (harness-provider-claude--time (plist-get win :resetsAt))))
                        out)))
    (nreverse out)))

(defun harness-provider-claude--merge-windows (old new)
  "Return quota windows OLD updated with NEW ones, matched by name."
  (let ((name (lambda (w) (plist-get w :name))))
    (append (mapcar (lambda (w)
                      (let ((n (cl-find (plist-get w :name) new :key name :test #'equal)))
                        (if n (harness-plist-merge w n) w)))
                    old)
            (cl-remove-if (lambda (n) (cl-find (plist-get n :name) old :key name :test #'equal))
                          new))))

(defun harness-provider-claude--publish (changes)
  "Merge CHANGES into the account status, announce it, and return it."
  (let* ((old harness-provider-claude--status)
         (new (harness-plist-merge old changes)))
    (setq harness-provider-claude--status new)
    (unless (equal old new)
      (harness-emit 'provider/quota-updated 'claude new))
    new))

(defun harness-provider-claude--request-usage (entry)
  "Ask ENTRY's CLI for a usage report; return the request id."
  (let ((id (format "usage-%d" (cl-incf harness-provider-claude--request-count))))
    (setq harness-provider-claude--asked (float-time))
    (harness-provider-claude--send
     entry (list :type "control_request" :request_id id
                 :request '(:subtype "get_usage" :skip_behaviors t)))
    id))

(defun harness-provider-claude--handle-account (entry account)
  "Remember how ENTRY's process is billed, from its ACCOUNT plist."
  (let ((info (harness-provider-claude-account-info account)))
    (setf (harness-provider-claude-session-account entry) info)
    (harness-log 'info "provider-claude: %s bills %s%s"
                 (harness-provider-claude-session-id entry)
                 (pcase (plist-get info :billing)
                   ('subscription "through a subscription")
                   ('api (format "per token (%s)" (or (plist-get info :auth) "API")))
                   (_ "in a way the CLI did not say"))
                 (if (plist-get info :plan-label) (format " (%s)" (plist-get info :plan-label)) ""))
    (harness-provider-claude--publish
     (if (eq (plist-get info :billing) 'api)
         ;; Plan quota does not apply to per-token billing.
         (append info '(:available nil :windows nil :extra nil :limit-status nil :using-extra nil))
       (harness-provider-claude--compact info)))))

(defun harness-provider-claude--handle-usage (entry id report error)
  "Handle the usage REPORT (nil after ERROR) answering request ID on ENTRY."
  (when (equal id (harness-provider-claude-session-baseline-id entry))
    (setf (harness-provider-claude-session-baseline-id entry) nil)
    ;; The process's running cost total starts here, unless the CLI has
    ;; already answered, in which case the total may include a turn.
    (let ((total (harness-plist-get-in report '(:session :total_cost_usd))))
      (when (and (numberp total) (not (harness-provider-claude-session-seen-output entry)))
        (setf (harness-provider-claude-session-cost-total entry) (float total)))))
  (if error
      (harness-log 'debug "provider-claude: usage report failed: %s" error)
    (when-let* ((changes (harness-provider-claude--usage-changes report)))
      (when-let* ((windows (plist-get (harness-provider-claude--publish changes) :windows)))
        (harness-provider-claude--emit entry (list :type 'quota :windows windows)))))
  (harness-provider-claude--settle-refresh)
  (when (harness-provider-claude-session-probe entry)
    (harness-provider-claude--end-probe entry)))

(defun harness-provider-claude--handle-rate-limit (entry info)
  "Fold the rate_limit_event INFO into the account status and ENTRY's turn."
  (let ((status (harness-provider-claude--publish
                 (list :windows (harness-provider-claude--merge-windows
                                 (plist-get harness-provider-claude--status :windows)
                                 (harness-provider-claude--windows info))
                       :limit-status (plist-get info :status)
                       :using-extra (harness-json-true-p (plist-get info :isUsingOverage))))))
    (when-let* ((windows (plist-get status :windows)))
      (harness-provider-claude--emit entry (list :type 'quota :windows windows)))))

(defun harness-provider-claude--handle-response (entry msg)
  "Handle the CLI's answer MSG to one of our control requests on ENTRY."
  (let* ((response (plist-get msg :response))
         (id (plist-get response :request_id))
         (ok (equal (plist-get response :subtype) "success"))
         (payload (plist-get response :response)))
    (cond
     ((equal id "init-1")
      (when-let* ((account (and ok (plist-get payload :account))))
        (harness-provider-claude--handle-account entry account)))
     ((and (stringp id) (string-prefix-p "usage-" id))
      (harness-provider-claude--handle-usage entry id (and ok payload)
                                             (unless ok (or (plist-get response :error) "failed"))))
     (t (harness-log 'debug "provider-claude: control_response %S" response)))))

(defun harness-provider-claude--turn-cost (entry msg)
  "Return the API-price cost of the turn that result MSG ends on ENTRY, or nil.
The CLI reports a running total for its process, so the turn costs the
difference to the total before it; a total below that one means the
CLI started counting again.  Nil when the starting total is unknown, so
the turn is priced from the model catalogue instead."
  (let ((total (plist-get msg :total_cost_usd))
        (base (harness-provider-claude-session-cost-total entry)))
    (when (numberp total)
      (setf (harness-provider-claude-session-cost-total entry) (float total)))
    (cond ((not (numberp total)) nil)
          ((null base) nil)
          ((>= total base) (- total base))
          (t (float total)))))

(defun harness-provider-claude--billing-fields (entry cost)
  "Return the billing part of a usage event on ENTRY whose API price is COST."
  (let* ((status harness-provider-claude--status)
         (info (or (harness-provider-claude-session-account entry) status))
         (billing (plist-get info :billing))
         (plan (or (plist-get status :plan) (plist-get info :plan))))
    (pcase billing
      ('subscription
       (if (plist-get status :using-extra)
           (list :billing 'extra-usage :plan plan :cost cost :list-cost cost)
         (list :billing 'subscription :plan plan :cost 0.0 :list-cost cost)))
      (_ (list :billing billing :cost cost :list-cost cost)))))

(defun harness-provider-claude--stale-p ()
  "Non-nil when the account status should be fetched again.
Asking counts like an answer, so a CLI that cannot report usage is not
asked again before `harness-provider-claude-quota-ttl' has passed."
  (let* ((status harness-provider-claude--status)
         (last (max (or (plist-get status :updated) 0) (or harness-provider-claude--asked 0))))
    (cond ((zerop last) t)
          ((eq (plist-get status :billing) 'api) nil)
          ((null harness-provider-claude-quota-ttl) nil)
          (t (> (- (float-time) last) harness-provider-claude-quota-ttl)))))

(defun harness-provider-claude--live-entry ()
  "Return a session record with a live CLI process, idle ones first, or nil."
  (let (best)
    (maphash (lambda (_ e)
               (when (and (process-live-p (harness-provider-claude-session-process e))
                          (or (null best)
                              (and (harness-provider-claude-session-active best)
                                   (not (harness-provider-claude-session-active e)))))
                 (setq best e)))
             harness-provider-claude--sessions)
    best))

(defun harness-provider-claude--settle-refresh ()
  "Resolve the usage request in flight with what is known now."
  (when-let* ((refresh harness-provider-claude--refresh))
    (setq harness-provider-claude--refresh nil)
    (cancel-timer (nth 2 refresh))
    (harness-resolve (nth 1 refresh) harness-provider-claude--status)))

(defun harness-provider-claude--refresh (&optional entry)
  "Fetch a fresh usage report; return a promise of the account status.
ENTRY's process asks when it is alive, else any live process, else a
probe started for the purpose.  The promise resolves with what is known
once the report arrives, or after `harness-provider-claude-probe-timeout'."
  (if harness-provider-claude--refresh
      (nth 1 harness-provider-claude--refresh)
    (let ((promise (harness-make-promise)))
      (condition-case err
          (let* ((asker (or (and entry (process-live-p (harness-provider-claude-session-process entry)) entry)
                            (harness-provider-claude--live-entry)
                            (harness-provider-claude--start-probe)))
                 (id (harness-provider-claude--request-usage asker)))
            (setq harness-provider-claude--refresh
                  (list id promise (run-at-time harness-provider-claude-probe-timeout nil
                                                #'harness-provider-claude--settle-refresh))))
        (error
         (harness-log 'warn "provider-claude: cannot ask for usage: %s" (harness-error-message err))
         (harness-resolve promise harness-provider-claude--status)))
      promise)))

(defun harness-provider-claude--start-probe ()
  "Return the quota probe, starting a CLI process that only answers reports.
The probe sends no message, so it makes no model call; it exits once
its usage report has arrived."
  (if (and harness-provider-claude--probe
           (process-live-p (harness-provider-claude-session-process harness-provider-claude--probe)))
      harness-provider-claude--probe
    (let* ((entry (harness-provider-claude--make-session :id "quota-probe" :probe t))
           (default-directory (file-name-as-directory (expand-file-name temporary-file-directory)))
           (process-environment (harness-provider-claude--environment))
           (stderr (generate-new-buffer " *harness-claude-probe-stderr*" t))
           (proc (condition-case err
                     (make-process :name "harness-claude-probe"
                                   :command (append (list harness-provider-claude-program
                                                          "-p" "--input-format" "stream-json"
                                                          "--output-format" "stream-json" "--verbose"
                                                          "--tools" "" "--strict-mcp-config")
                                                    harness-provider-claude-extra-args)
                                   :coding '(utf-8 . utf-8)
                                   :connection-type 'pipe
                                   :noquery t
                                   :stderr stderr
                                   :filter (lambda (_p chunk) (harness-provider-claude--filter entry chunk))
                                   :sentinel (lambda (p _e) (harness-provider-claude--probe-sentinel entry p)))
                   (error (kill-buffer stderr) (signal (car err) (cdr err))))))
      (when-let* ((ep (get-buffer-process stderr)))
        (set-process-query-on-exit-flag ep nil)
        (set-process-sentinel ep #'ignore))
      (setf (harness-provider-claude-session-process entry) proc
            (harness-provider-claude-session-stderr entry) stderr)
      (setq harness-provider-claude--probe entry)
      (harness-log 'info "provider-claude: probing the account and its quota")
      (harness-provider-claude--send
       entry '(:type "control_request" :request_id "init-1" :request (:subtype "initialize")))
      (run-at-time (+ 5 harness-provider-claude-probe-timeout) nil
                   #'harness-provider-claude--end-probe entry t)
      entry)))

(defun harness-provider-claude--end-probe (entry &optional kill)
  "Let the probe ENTRY exit by closing its input, or KILL it."
  (let ((proc (harness-provider-claude-session-process entry)))
    (when (process-live-p proc)
      (if kill (delete-process proc) (process-send-eof proc)))))

(defun harness-provider-claude--probe-sentinel (entry proc)
  "Clean up after the probe ENTRY once its process PROC has ended."
  (unless (process-live-p proc)
    (unless (zerop (process-exit-status proc))
      (harness-log 'warn "provider-claude: the quota probe exited with status %s%s"
                   (process-exit-status proc)
                   (let ((tail (harness-provider-claude--stderr-tail entry)))
                     (if (string-empty-p tail) "" (concat ": " (harness-truncate-end tail 300))))))
    (let ((buf (harness-provider-claude-session-stderr entry)))
      (when (buffer-live-p buf) (kill-buffer buf)))
    (when (eq harness-provider-claude--probe entry)
      (setq harness-provider-claude--probe nil))
    (harness-provider-claude--settle-refresh)))

(defun harness-provider-claude--handle-init (entry msg)
  "Handle the system/init banner MSG on ENTRY."
  (let ((id (plist-get msg :session_id))
        (model (plist-get msg :model)))
    (setf (harness-provider-claude-session-cli-session-id entry) id
          (harness-provider-claude-session-model entry) model)
    (harness-log 'info "provider-claude: session %s is CLI session %s (%s)"
                 (harness-provider-claude-session-id entry) id model)
    ;; CLIs whose initialize answer has no account still name an API key here.
    (let ((key (plist-get msg :apiKeySource)))
      (when (and (null (harness-provider-claude-session-account entry))
                 (stringp key) (not (member key '("" "none"))))
        (harness-provider-claude--handle-account entry (list :apiKeySource key))))
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
    (setf (harness-provider-claude-session-seen-output entry) t)
    (harness-provider-claude--emit
     entry (append (list :type 'usage :input input
                         :output (or (plist-get usage :output_tokens) 0)
                         :cache-read cache-read :cache-write cache-write
                         :context (or (harness-provider-claude-session-context entry)
                                      (+ input cache-read cache-write)))
                   (harness-provider-claude--billing-fields
                    entry (harness-provider-claude--turn-cost entry msg))))
    (when (harness-provider-claude--stale-p)
      (harness-provider-claude--refresh entry))
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
      ("control_response" (harness-provider-claude--handle-response entry msg))
      ("system"
       (pcase (plist-get msg :subtype)
         ("init" (harness-provider-claude--handle-init entry msg))
         ("permission_denied" (harness-provider-claude--handle-denial entry msg))
         ;; Compacting takes a while and streams nothing; a null status
         ;; ends it and the CLI waits for the model again.
         ("status"
          (let ((status (plist-get msg :status)))
            (cond ((equal status "compacting")
                   (harness-provider-claude--emit entry '(:type activity :phase compacting)))
                  ((null status)
                   (harness-provider-claude--emit entry '(:type activity :phase waiting)))
                  (t (harness-log 'debug "provider-claude: status %s" status)))))
         ("compact_boundary"
          (harness-provider-claude--emit
           entry '(:type hint :text "Context compacted by Claude Code")))
         (sub (harness-log 'debug "provider-claude: system/%s" sub))))
      ("stream_event" (harness-provider-claude--handle-stream entry (plist-get msg :event)))
      ("assistant"
       (setf (harness-provider-claude-session-seen-output entry) t)
       (harness-provider-claude--handle-assistant entry (plist-get msg :message)))
      ("user" (harness-provider-claude--handle-user-echo entry (plist-get msg :message)))
      ("rate_limit_event"
       (harness-provider-claude--handle-rate-limit entry (plist-get msg :rate_limit_info)))
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
         (key (harness-provider-claude--spawn-key request))
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
    (remhash sid harness-provider-claude--builtin-calls)
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

(defun harness-provider-claude--quota (&optional refresh)
  "Return a promise of how the account is billed and of its plan quota.
The shape is the one `provider/quota' documents.  A new usage report is
fetched first when REFRESH is non-nil or the last one is stale (see
`harness-provider-claude-quota-ttl'); it makes no model call."
  (if (or refresh (harness-provider-claude--stale-p))
      (harness-provider-claude--refresh)
    (harness-resolved harness-provider-claude--status)))

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
  "Shut down every CLI process, the quota probe included."
  (dolist (id (hash-table-keys harness-provider-claude--sessions))
    (harness-provider-claude-close id))
  (when harness-provider-claude--probe
    (harness-provider-claude--end-probe harness-provider-claude--probe t))
  (harness-provider-claude--settle-refresh))

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
