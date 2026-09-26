;;; harness-provider-claude.el --- Claude Code CLI provider -*- lexical-binding: t; -*-

;; This file is part of Emacs Agent Harness.

;;; Commentary:

;; A provider for users on Claude subscription plans: it shells out to the
;; official `claude' CLI in print mode with stream-json output instead of
;; calling the API directly, which is how Anthropic's policy allows
;; external tools to use a subscription.
;;
;; The CLI's own tools are disabled: the harness keeps its permission
;; model and its own tools, and this provider supplies plain completions
;; (text in, text out, with usage from the result event).

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'harness-core)
(require 'harness-provider)

(defcustom harness-provider-claude-program "claude"
  "The Claude Code CLI executable."
  :type 'string)

(defcustom harness-provider-claude-models
  '(("claude-sonnet" :name "Claude Sonnet (subscription)"
     :context-window 200000 :input-price 0.0 :output-price 0.0)
    ("claude-opus" :name "Claude Opus (subscription)"
     :context-window 200000 :input-price 0.0 :output-price 0.0)
    ("claude-haiku" :name "Claude Haiku (subscription)"
     :context-window 200000 :input-price 0.0 :output-price 0.0))
  "Models the Claude CLI provider offers."
  :type '(repeat (plist :key-type symbol :value-type sexp)))

(defcustom harness-provider-claude-timeout 300
  "Seconds before a Claude CLI turn is given up."
  :type 'num)

(defcustom harness-provider-claude-extra-arguments nil
  "Extra arguments passed to the Claude CLI."
  :type '(repeat string))

(cl-defstruct (harness-provider-claude--state
               (:constructor harness-provider-claude--state-create))
  deferred process text usage error seen-result)

(defun harness-provider-claude--program ()
  "Path of the Claude CLI, or nil."
  (executable-find harness-provider-claude-program))

(defun harness-provider-claude--prompt (request)
  "Render REQUEST's messages into a single CLI prompt."
  (let ((system (plist-get request :system))
        (messages (append (plist-get request :messages) nil)))
    (concat
     (if (and system (not (string-empty-p system)))
         (concat system "\n\n")
       "")
     (mapconcat
      (lambda (message)
        (let* ((role (plist-get message :role))
               (content (plist-get message :content))
               (text (mapconcat (lambda (block)
                                  (cond
                                   ((stringp block) block)
                                   ((equal (plist-get block :type) "text")
                                    (or (plist-get block :text) ""))
                                   ((equal (plist-get block :type) "tool_call")
                                    (format "[tool call: %s %s]"
                                            (plist-get block :name)
                                            (or (plist-get block :arguments) "")))
                                   ((equal (plist-get block :type) "tool_result")
                                    (format "[tool result]\n%s"
                                            (or (plist-get block :content) "")))
                                   (t "")))
                                (append content nil)
                                "\n")))
          (format "%s: %s"
                  (pcase role
                    ("user" "User")
                    ("assistant" "Assistant")
                    (_ (capitalize (or role "user"))))
                  text)))
      messages
      "\n\n")
     "\n\nAssistant:")))

(defun harness-provider-claude--handle-line (state line request)
  "Merge one JSONL LINE into STATE, streaming to REQUEST."
  (when (and line (not (string-empty-p (string-trim line))))
    (let ((event (condition-case err
                     (json-parse-string line :object-type 'plist)
                   (error
                    (harness-log "claude-cli: bad JSON line: %S" err)
                    nil))))
      (when event
        (pcase (plist-get event :type)
          ("stream_event"
           (let* ((inner (plist-get event :event))
                  (delta (plist-get inner :delta)))
             (when-let* ((text (and delta (plist-get delta :text))))
               (setf (harness-provider-claude--state-text state)
                     (concat (harness-provider-claude--state-text state) text))
               (when-let* ((on-text (plist-get request :on-text)))
                 (funcall on-text text)))))
          ((or "assistant" "message")
           ;; A complete message (also arrives without partial streaming).
           (let* ((message (or (plist-get event :message) event))
                  (content (append (plist-get message :content) nil))
                  (text (mapconcat (lambda (block)
                                     (if (equal (plist-get block :type) "text")
                                         (or (plist-get block :text) "")
                                       ""))
                                   content "")))
             (when (and (not (string-empty-p text))
                        (not (string= text (harness-provider-claude--state-text state)))
                        (not (harness-provider-claude--state-seen-result state)))
               (setf (harness-provider-claude--state-text state) text)
               (when-let* ((on-text (plist-get request :on-text)))
                 (funcall on-text text)))))
          ("result"
           (setf (harness-provider-claude--state-seen-result state) t)
           (let ((result (plist-get event :result))
                 (usage (plist-get event :usage)))
             (if (or (plist-get event :is_error)
                     (and (plist-get event :subtype)
                          (not (equal (plist-get event :subtype) "success"))))
                 ;; Authentication and other CLI failures arrive here.
                 (setf (harness-provider-claude--state-error state)
                       (or result "the Claude CLI reported an error"))
               (when (and result (not (harness-provider-claude--state-text state)))
                 (setf (harness-provider-claude--state-text state) result)))
             (when usage
               (setf (harness-provider-claude--state-usage state)
                     (list :input-tokens (or (plist-get usage :input_tokens) 0)
                           :output-tokens (or (plist-get usage :output_tokens) 0)
                           :cache-read (or (plist-get usage :cache_read_input_tokens) 0)
                           :cache-write (or (plist-get usage :cache_creation_input_tokens) 0)))))))))))

(defun harness-provider-claude--finish (state)
  "Resolve STATE's deferred with the accumulated result."
  (unless (not (harness-deferred-pending-p (harness-provider-claude--state-deferred state)))
    (let ((error (harness-provider-claude--state-error state))
          (text (or (harness-provider-claude--state-text state) "")))
      (if (and error (string-empty-p text))
          (harness-deferred-reject
           (harness-provider-claude--state-deferred state)
           (list 'harness-provider-error error))
        (harness-deferred-resolve
         (harness-provider-claude--state-deferred state)
         (list :text text
               :stop-reason "end_turn"
               :tool-calls []
               :usage (or (harness-provider-claude--state-usage state)
                          (list :input-tokens 0 :output-tokens 0))))))))

(defun harness-provider-claude--sentinel (state process event)
  "Handle PROCESS state changes for STATE."
  (when (memq (process-status process) '(exit signal))
    (when (and (/= (process-exit-status process) 0)
               (null (harness-provider-claude--state-error state)))
      (setf (harness-provider-claude--state-error state)
            (format "claude exited with status %s"
                    (process-exit-status process))))
    (harness-provider-claude--finish state)))

(defun harness-provider-claude-complete (request)
  "Run one completion through the Claude CLI for REQUEST."
  (let ((deferred (harness-deferred-new)))
    (if (null (harness-provider-claude--program))
        (progn
          (harness-deferred-reject
           deferred
           (list 'harness-provider-error
                 (format "The Claude CLI (%s) is not on PATH" harness-provider-claude-program)))
          deferred)
      (let* ((state (harness-provider-claude--state-create :deferred deferred))
             (model (harness-provider-model-name (or (plist-get request :model) "")))
             (arguments (append (list "-p"
                                      "--output-format" "stream-json"
                                      "--verbose"
                                      "--include-partial-messages"
                                      "--tools" ""
                                      "--model" (if (string-empty-p model) "sonnet" model))
                                harness-provider-claude-extra-arguments))
             (buffer (generate-new-buffer " *harness-claude*")))
        (condition-case err
            (let ((process (apply #'make-process
                                  :name "harness-claude"
                                  :buffer buffer
                                  :command (cons (harness-provider-claude--program) arguments)
                                  :coding 'utf-8-unix
                                  :noquery t
                                  :connection-type 'pipe
                                  (list :sentinel (lambda (proc event)
                                                    (harness-provider-claude--sentinel state proc event))
                                        :stderr buffer
                                        :filter (lambda (proc chunk)
                                                  (with-current-buffer (process-buffer proc)
                                                    (goto-char (point-max))
                                                    (insert chunk))
                                                  (harness-provider-claude--drain state request proc))))))
              (setf (harness-provider-claude--state-process state) process)
              (run-at-time harness-provider-claude-timeout nil
                           (lambda ()
                             (when (process-live-p process)
                               (setf (harness-provider-claude--state-error state)
                                     "claude timed out")
                               (delete-process process)
                               (harness-provider-claude--finish state))))
              (process-send-string process (harness-provider-claude--prompt request))
              (process-send-eof process)
              (harness-deferred-on-cancel deferred
                                          (lambda ()
                                            (when (process-live-p process)
                                              (delete-process process)))))
          (error
           (harness-deferred-reject
            deferred
            (list 'harness-provider-error (error-message-string err)))))
        deferred))))

(defun harness-provider-claude--drain (state request process)
  "Consume complete lines from PROCESS's buffer into STATE."
  (with-current-buffer (process-buffer process)
    (goto-char (point-min))
    (while (progn (skip-chars-forward "^\n")
                  (looking-at "\n"))
      (let ((line (buffer-substring-no-properties (point-min) (point))))
        (delete-region (point-min) (1+ (point)))
        (harness-provider-claude--handle-line state line request)))))

(defun harness-provider-claude--models ()
  "Model list for the provider registry."
  (mapcar (lambda (model)
            (list :model (car model)
                  :name (plist-get (cdr model) :name)
                  :context-window (plist-get (cdr model) :context-window)
                  :input-price (plist-get (cdr model) :input-price)
                  :output-price (plist-get (cdr model) :output-price)))
          harness-provider-claude-models))

(defun harness-provider-claude-setup ()
  "Register the Claude CLI provider when the CLI is available."
  (if (null (harness-provider-claude--program))
      (harness-log "claude-cli: %s not on PATH; provider not registered"
                   harness-provider-claude-program)
    (harness-provider-register
     "claude-cli"
     :description "Claude Code CLI (subscription plans)."
     :capabilities '(streaming)
     :models (harness-provider-claude--models)
     :complete #'harness-provider-claude-complete
     :token-fn (lambda (_model text)
                 (and text (ceiling (/ (length text) 4.0)))))))

(defun harness-provider-claude-teardown ()
  "Remove the Claude CLI provider."
  (harness-provider-unregister "claude-cli"))

(harness-module-define 'harness-provider-claude
  :version harness-version
  :description "Claude Code CLI provider for subscription plans."
  :requires '((harness-core "0.1.0")
              (harness-provider "0.1.0"))
  :provides '(harness-provider-claude)
  :setup #'harness-provider-claude-setup
  :teardown #'harness-provider-claude-teardown)

(provide 'harness-provider-claude)
;;; harness-provider-claude.el ends here
