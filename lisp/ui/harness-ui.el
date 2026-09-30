;;; harness-ui.el --- Local UI's ACP client host -*- lexical-binding: t; -*-

;; This file is part of Emacs Agent Harness.

;;; Commentary:

;; The presentation layer speaks ACP and nothing else.  This module owns
;; the local in-process connection to the harness agent: it initializes
;; the client, implements the client-side methods (file access and
;; permission prompts) and re-broadcasts ACP notifications as Emacs
;; events, so feature modules do not each talk to a connection.
;;
;; Events emitted:
;;
;;   harness-ui-update              session/update arrived
;;   harness-ui-session-status      _harness/session_status arrived
;;   harness-ui-sessions-changed    the harness session list changed
;;   harness-ui-permission-request  the agent needs a decision
;;   harness-ui-ready               initialize completed
;;
;; `harness-ui-request' is the way features call the harness; it returns a
;; deferred of the ACP result.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'harness-core)
(require 'harness-acp)
(require 'harness-acp-inprocess)
(require 'harness-perms)

(defgroup harness-ui nil
  "Harness user interface."
  :group 'harness)

(defcustom harness-ui-client-capabilities
  '(:fs (:readTextFile t :writeTextFile t)
        :terminal :false
        :_meta (:harness (:local t)))
  "Capabilities advertised in initialize."
  :type 'plist)

(defvar harness-ui--agent-connection nil
  "Agent side of the local ACP pair.")

(defvar harness-ui--client-connection nil
  "Client side of the local ACP pair; the UI's connection to the harness.")

(defvar harness-ui--agent-info nil
  "agentInfo from the initialize result.")

(defvar harness-ui-current-session nil
  "Session most recently displayed; configuration commands act on it.")

(defvar harness-ui--capabilities nil
  "agentCapabilities from the initialize result.")

(defvar harness-ui-refresh-functions nil
  "Functions run to redraw UI buffers after a reload.")

(defun harness-ui-agent-info ()
  "Information the connected agent reported during initialize."
  harness-ui--agent-info)

(defun harness-ui-connected-p ()
  "Return non-nil when the local ACP connection is up."
  (and harness-ui--client-connection
       (not (harness-acp-connection-closed-p harness-ui--client-connection))))

;;; Starting

(defun harness-ui-start ()
  "Connect to the local harness over the in-process ACP transport."
  (interactive)
  (unless (harness-ui-connected-p)
    (let ((pair (harness-acp-inprocess-pair)))
      (setq harness-ui--agent-connection (car pair)
            harness-ui--client-connection (cdr pair))
      (harness-ui--register-client-methods harness-ui--client-connection)
      (harness-ui--install-permission-asker)
      (harness-ui--install-question-function)
      (harness-deferred-then
       (harness-acp-connection-request
        harness-ui--client-connection "initialize"
        (list :protocolVersion harness-acp-protocol-version
              :clientCapabilities harness-ui-client-capabilities
              :clientInfo (list :name "emacs-agent-harness-ui"
                                :title "Emacs Agent Harness"
                                :version harness-version)))
       (lambda (result)
         (setq harness-ui--agent-info (plist-get result :agentInfo)
               harness-ui--capabilities (plist-get result :agentCapabilities))
         (harness-emit 'harness-ui-ready :agent-info harness-ui--agent-info)
         (harness-log "UI connected to %S" harness-ui--agent-info)))))
  harness-ui--client-connection)

(defun harness-ui-connect (host port)
  "Connect to a harness ACP server at HOST:PORT instead of the local one.
This is the client half of a remote session: the UI drives a harness
running on another machine (or in another Emacs) exactly like the local
one.  Pass HOST as nil for a local port."
  (interactive "sHost (empty for localhost): 
nPort: ")
  (let ((host (if (string-empty-p (string-trim (or host "")))
                  "127.0.0.1"
                (string-trim host)))
        (port (if (stringp port) (string-to-number port) port)))
    (unless (and (numberp port) (> port 0))
      (user-error "A port is needed"))
    (harness-ui-stop)
    (let ((connection (harness-acp-tcp-connect host port 'client)))
      (setq harness-ui--client-connection connection
            harness-ui--agent-connection nil)
      (harness-ui--register-client-methods connection)
      (harness-ui--install-permission-asker)
      (harness-ui--install-question-function)
      (harness-deferred-then
       (harness-acp-connection-request
        connection "initialize"
        (list :protocolVersion harness-acp-protocol-version
              :clientCapabilities harness-ui-client-capabilities
              :clientInfo (list :name "emacs-agent-harness-ui"
                                :title "Emacs Agent Harness"
                                :version harness-version)))
       (lambda (result)
         (setq harness-ui--agent-info (plist-get result :agentInfo)
               harness-ui--capabilities (plist-get result :agentCapabilities))
         (harness-emit 'harness-ui-ready :agent-info harness-ui--agent-info)
         (message "Connected to %s (%s)"
                  (or (plist-get harness-ui--agent-info :name) "harness")
                  (or (plist-get harness-ui--agent-info :version) "?"))
         (run-hooks 'harness-ui-refresh-functions))
       (lambda (error)
         (message "Could not connect to %s:%s: %S" host port error)))
      connection)))

(defun harness-ui-stop ()
  "Close the local ACP connection."
  (interactive)
  (when harness-ui--client-connection
    (harness-acp-connection-close harness-ui--client-connection "UI stopped"))
  (setq harness-ui--client-connection nil
        harness-ui--agent-connection nil)
  (when (eq harness-permission-ask-function #'harness-ui--ask-permission)
    (setq harness-permission-ask-function nil))
  (when (and (boundp 'harness-agent-question-function)
             (eq harness-agent-question-function #'harness-ui--ask-question))
    (setq harness-agent-question-function nil)))

;;; Requests

(defun harness-ui-request (method &optional params)
  "Send METHOD to the harness.  Returns a deferred of the result."
  (harness-ui-start)
  (harness-acp-connection-request harness-ui--client-connection method params))

(defun harness-ui-send (session-id blocks)
  "Send BLOCKS (a vector of content blocks) as a prompt to SESSION-ID."
  (harness-ui-request "session/prompt"
                      (list :sessionId session-id :prompt blocks)))

(defun harness-ui-steer (session-id blocks)
  "Steer SESSION-ID's running turn with BLOCKS.
The agent injects the message at the next step boundary; when no turn
is running it starts one with BLOCKS instead."
  (harness-ui-request "_harness/session/steer"
                      (list :sessionId session-id :blocks blocks)))

(defun harness-ui-cancel (session-id)
  "Cancel SESSION-ID's running turn."
  (harness-acp-connection-notify harness-ui--client-connection
                                 "session/cancel" (list :sessionId session-id)))

;;; Client-side methods

(defun harness-ui--register-client-methods (client)
  "Install the client method handlers on CLIENT."
  (harness-acp-connection-register-method
   client "session/update"
   (lambda (_connection params)
     (harness-emit 'harness-ui-update
                   :session-id (plist-get params :sessionId)
                   :update (plist-get params :update))))
  (harness-acp-connection-register-method
   client "_harness/session_status"
   (lambda (_connection params)
     (harness-emit 'harness-ui-session-status :status params)))
  (harness-acp-connection-register-method
   client "_harness/sessions_changed"
   (lambda (_connection _params)
     (harness-emit 'harness-ui-sessions-changed)))
  (harness-acp-connection-register-method
   client "session/request_permission"
   (lambda (_connection params)
     (harness-ui--permission-request params)))
  (harness-acp-connection-register-method
   client "_harness/question"
   (lambda (_connection params)
     (let ((deferred (harness-deferred-new)))
       (harness-emit 'harness-ui-question
                     :session-id (plist-get params :sessionId)
                     :question (plist-get params :question)
                     :options (plist-get params :options)
                     :freeform (plist-get params :freeform)
                     :respond (lambda (answer)
                                (harness-deferred-resolve
                                 deferred (list :answer (or answer "")))))
       deferred)))
  (harness-acp-connection-register-method
   client "fs/read_text_file"
   (lambda (_connection params) (harness-ui--read-text-file params)))
  (harness-acp-connection-register-method
   client "fs/write_text_file"
   (lambda (_connection params) (harness-ui--write-text-file params)))
  client)

(defun harness-ui--read-text-file (params)
  "Serve fs/read_text_file with Emacs' own file access."
  (let* ((path (plist-get params :path))
         (line (or (plist-get params :line) 1))
         (limit (plist-get params :limit)))
    (condition-case err
        (with-temp-buffer
          (insert-file-contents path)
          (goto-char (point-min))
          (forward-line (1- line))
          (let ((start (point)))
            (when limit
              (forward-line limit))
            (list :content (buffer-substring-no-properties start (point)))))
      (error (signal 'harness-acp-error
                     (list -32603 (error-message-string err) nil))))))

(defun harness-ui--write-text-file (params)
  "Serve fs/write_text_file with Emacs' own file access."
  (let ((path (plist-get params :path))
        (content (or (plist-get params :content) "")))
    (condition-case err
        (progn
          (make-directory (file-name-directory path) t)
          (with-temp-file path (insert content))
          (make-hash-table))
      (error (signal 'harness-acp-error
                     (list -32603 (error-message-string err) nil))))))

;;; Permission prompts

(defun harness-ui--permission-request (params)
  "Ask the user to decide PARAMS and return the ACP outcome.
The request is broadcast as `harness-ui-permission-request'; a feature
module answers it by calling the response function."
  (let ((deferred (harness-deferred-new))
        (tool-call (plist-get params :toolCall))
        (options (plist-get params :options)))
    (harness-emit 'harness-ui-permission-request
                  :session-id (plist-get params :sessionId)
                  :tool-call tool-call
                  :options options
                  :respond (lambda (option-id)
                             (harness-deferred-resolve
                              deferred
                              (list :outcome (list :outcome "selected"
                                                   :optionId option-id)))))
    ;; Safety net: if nothing answers, deny rather than hang forever.
    (run-at-time harness-ui-permission-timeout nil
                 (lambda ()
                   (when (harness-deferred-pending-p deferred)
                     (harness-deferred-resolve
                      deferred (list :outcome (list :outcome "selected"
                                                    :optionId "reject-once"))))))
    deferred))

(defcustom harness-ui-permission-timeout 120
  "Seconds to wait for the user to answer a permission request."
  :type 'number)

(defun harness-ui--install-permission-asker ()
  "Route the agent-side permission asker through this ACP connection."
  (setq harness-permission-ask-function #'harness-ui--ask-permission))

(defun harness-ui--install-question-function ()
  "Route the agent-side question tool through this ACP connection."
  (when (boundp 'harness-agent-question-function)
    (setq harness-agent-question-function #'harness-ui--ask-question)))

(defun harness-ui--ask-question (request)
  "Ask the user REQUEST's question over ACP.  Returns a deferred of the answer."
  (harness-deferred-then
   (harness-acp-connection-request
    harness-ui--agent-connection "_harness/question"
    (harness-plist-omit-nil
     (list :sessionId (plist-get request :session-id)
           :question (plist-get request :question)
           :options (plist-get request :options)
           :freeform (plist-get request :freeform))))
   (lambda (result) (plist-get result :answer))
   (lambda (_error) nil)))

(defun harness-ui--ask-permission (request)
  "Called by the permission chain; asks this UI over ACP.
REQUEST is the plist from `harness-permission-check'."
  (let* ((tool-name (or (plist-get request :tool-name) "tool"))
         (arguments (plist-get request :arguments))
         (paths (plist-get request :paths))
         (params (list :sessionId (plist-get request :session-id)
                       :toolCall
                       (harness-plist-omit-nil
                        (list :toolCallId (or (plist-get request :tool-call-id)
                                              (harness-uuid))
                              :title (format "Run %s" tool-name)
                              :kind "other"
                              :status "pending"
                              :rawInput (or arguments (make-hash-table))
                              :content (vector (list :type "content"
                                                     :content
                                                     (list :type "text"
                                                           :text (or (plist-get request :reason)
                                                                     (format "Allow %s?" tool-name)))))))
                       :options (or (plist-get request :options)
                                    (harness-permission-options)))))
    (ignore paths)
    (harness-deferred-then
     (harness-acp-connection-request harness-ui--agent-connection
                                     "session/request_permission" params)
     (lambda (result)
       (let* ((outcome (plist-get result :outcome))
              (option (plist-get outcome :optionId))
              (cancelled (equal (plist-get outcome :outcome) "cancelled")))
         (cond
          (cancelled (list :outcome "deny" :always nil :reason "Cancelled"))
          ((and option (string-prefix-p "allow" option))
           (list :outcome "allow"
                 :always (string-suffix-p "always" option)))
          (t (list :outcome "deny"
                   :always (and option (string-suffix-p "always" option))
                   :reason "The user rejected this tool call.")))))
     (lambda (error)
       (list :outcome "deny" :always nil
             :reason (format "Permission prompt failed: %S" error))))))

;;; Redraws

(defun harness-ui-refresh-all ()
  "Redraw every UI buffer (used after reloads)."
  (run-hooks 'harness-ui-refresh-functions))

;;; Help

(defvar harness-ui-describe-buffer-name "*Harness Help*"
  "Buffer showing the commands available in a harness buffer.")

(defvar-local harness-ui-describe--source nil
  "Buffer whose commands the help buffer describes.")

(defun harness-ui-describe--bindings (keymap)
  "Return (KEY . COMMAND) bindings of KEYMAP, descending into prefixes."
  (let (bindings)
    (map-keymap
     (lambda (event definition)
       (unless (memq event '(remap menu-bar))
         (ignore-errors
           (let ((key (key-description (vector event))))
             (cond
              ((and (symbolp definition) (commandp definition))
               (push (cons key definition) bindings))
              ((keymapp definition)
               (dolist (inner (harness-ui-describe--bindings definition))
                 (push (cons (concat key " " (car inner)) (cdr inner))
                       bindings))))))))
     keymap)
    (sort bindings (lambda (a b) (string< (car a) (car b))))))

(defun harness-ui-describe--summary (command)
  "Return a one-line summary of COMMAND."
  (let ((doc (ignore-errors (documentation command))))
    (cond
     ((and doc (not (string-empty-p (string-trim doc))))
      (car (split-string (string-trim doc) "\n")))
     ((symbolp command) (symbol-name command))
     (t "anonymous command"))))

(defun harness-ui-describe--insert (prefix bindings)
  "Insert BINDINGS as an aligned table with PREFIX before each key."
  (let* ((keys (mapcar (lambda (binding) (concat prefix (car binding))) bindings))
         (width (if keys (apply #'max (mapcar #'length keys)) 0)))
    (dolist (binding bindings)
      (let ((key (concat prefix (car binding))))
        (insert "  " (propertize key 'face 'bold)
                (make-string (- (+ width 2) (length key)) ?\s)
                (harness-ui-describe--summary (cdr binding)) "\n")))))

(defun harness-ui-describe--global-map ()
  "Return the harness command prefix map, when one is available."
  (let ((bound (key-binding (kbd "C-c h"))))
    (cond
     ((keymapp bound) bound)
     ((and (boundp 'harness-command-map)
           (keymapp (symbol-value 'harness-command-map)))
      (symbol-value 'harness-command-map)))))

(defvar harness-ui-describe-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "?") #'harness-ui-describe-refresh)
    (define-key map (kbd "h") #'harness-ui-describe-refresh)
    (define-key map (kbd "g") #'harness-ui-describe-refresh)
    map)
  "Keymap for the harness help buffer.")

(define-derived-mode harness-ui-describe-mode special-mode "Harness-Help"
  "Major mode for the harness command help buffer."
  :group 'harness-ui
  (setq-local truncate-lines nil)
  (setq-local word-wrap t))

(defun harness-ui-describe-refresh ()
  "Redraw the help buffer for the buffer whose commands it describes."
  (interactive)
  (let ((source (and (boundp 'harness-ui-describe--source)
                     (buffer-live-p harness-ui-describe--source)
                     harness-ui-describe--source)))
    (if source
        (with-current-buffer source (harness-ui-describe))
      (harness-ui-describe))))

;;;###autoload
(defun harness-ui-describe ()
  "Show the harness commands available in this buffer.
Every harness screen binds this to `?' — except the chat composer,
where `?' types a question mark and help comes from the transcript."
  (interactive)
  (let* ((source (current-buffer))
         (mode major-mode)
         (local (harness-ui-describe--bindings (current-local-map)))
         (global-map (harness-ui-describe--global-map))
         (global (and global-map (harness-ui-describe--bindings global-map))))
    (with-current-buffer (get-buffer-create harness-ui-describe-buffer-name)
      (harness-ui-describe-mode)
      (setq-local harness-ui-describe--source source)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (format "Harness commands — %s\n\n" mode) 'face 'bold))
        (if local
            (harness-ui-describe--insert "" local)
          (insert "  (no buffer-specific commands)\n"))
        (when global
          (insert "\n" (propertize "Global commands\n\n" 'face 'bold))
          (harness-ui-describe--insert "C-c h " global))
        (insert "\n" (propertize "? refresh   q close   C-h m describe the mode\n"
                                 'face 'shadow)))
      (goto-char (point-min)))
    (pop-to-buffer (get-buffer harness-ui-describe-buffer-name))))

;;; Service and module

(defun harness-ui-setup ()
  "Set up the UI host."
  (harness-event-define 'harness-ui-update
    :module 'harness-ui
    :doc "A session/update notification arrived from the harness."
    :payload '((session-id . string) (update . plist)))
  (harness-event-define 'harness-ui-session-status
    :module 'harness-ui
    :doc "A session status notification arrived."
    :payload '((status . plist)))
  (harness-event-define 'harness-ui-sessions-changed
    :module 'harness-ui
    :doc "The harness session list changed."
    :payload '())
  (harness-event-define 'harness-ui-permission-request
    :module 'harness-ui
    :doc "The harness needs a permission decision."
    :payload '((session-id . string) (tool-call . plist)
               (options . vector) (respond . function)))
  (harness-event-define 'harness-ui-ready
    :module 'harness-ui
    :doc "The local ACP connection completed initialize."
    :payload '((agent-info . plist)))
  (harness-on 'harness-reloaded (lambda (_payload) (harness-ui-refresh-all))
              :module 'harness-ui)
  (harness-service-register
   "ui"
   :module 'harness-ui
   :doc "The local UI's ACP connection to the harness."
   :methods '((start . harness-ui-start)
              (stop . harness-ui-stop)
              (request . harness-ui-request)
              (send . harness-ui-send)
              (cancel . harness-ui-cancel)
              (refresh-all . harness-ui-refresh-all))))

(defun harness-ui-teardown ()
  "Tear down the UI host."
  (harness-ui-stop)
  (setq harness-ui-refresh-functions nil))

(harness-module-define 'harness-ui
  :version harness-version
  :description "Local UI's ACP client host."
  :requires '((harness-core "0.1.0")
              (harness-acp "0.1.0")
              (harness-acp-inprocess "0.1.0"))
  :provides '(harness-ui)
  :setup #'harness-ui-setup
  :teardown #'harness-ui-teardown)

(provide 'harness-ui)
;;; harness-ui.el ends here
