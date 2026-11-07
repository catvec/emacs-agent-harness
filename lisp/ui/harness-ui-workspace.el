;;; harness-ui-workspace.el --- The workspace chat: threads, timeline and compose box -*- lexical-binding: t; -*-

;;; Commentary:

;; The Emacs front end of workspace mode.  It is one buffer: a header,
;; a thread list, the timeline of messages and dividers, and the same
;; compose box a chat uses.  It talks to the harness only through ACP:
;; `_harness/workspace/get', `_harness/workspace/timeline',
;; `_harness/workspace/prompt', and the `workspace/*' events.
;;
;; The timeline is the workspace's, not a session's.  Each entry knows
;; the episode it belongs to, so `Open episode' opens the ordinary
;; session behind the thread when the user wants the full transcript.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-acp)
(require 'harness-ui)
(require 'harness-ui-chat)
(require 'harness-ui-compose)

(defvar harness-ui-workspace--last-id nil
  "The workspace this UI opened last.")

(defvar-local harness-ui-workspace--id nil
  "Workspace id of this buffer.")

(defvar-local harness-ui-workspace--data nil
  "The workspace plist this buffer shows.")

(defvar-local harness-ui-workspace--entries nil
  "Timeline entries this buffer shows, oldest first.")

(defvar-local harness-ui-workspace--memory nil
  "The memory status of this workspace, or nil.")

(defvar-local harness-ui-workspace--thread nil
  "The thread id this buffer is composing into.")

(defvar-local harness-ui-workspace--state nil
  "One of `loading', `ready' or `error'.")

(defvar-local harness-ui-workspace--error nil
  "The last error this buffer met.")

(defvar-local harness-ui-workspace--fetch-timer nil
  "Timer that refreshes this buffer after an event.")

(defvar-local harness-ui-workspace--request nil
  "The generation of the last fetch, so a late answer is dropped.")

(defvar-local harness-ui-workspace--rendered-key nil
  "What the last drawing depended on.")

(defvar harness-ui-workspace-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'harness-ui-workspace-send)
    (define-key map (kbd "C-c C-k") #'harness-ui-workspace-clear)
    (define-key map (kbd "C-c w n") #'harness-ui-workspace-new-thread)
    (define-key map (kbd "C-c w o") #'harness-ui-workspace-open-episode)
    (define-key map (kbd "C-c w g") #'harness-ui-workspace-refresh)
    (define-key map (kbd "C-c w R") #'harness-ui-workspace-resources)
    (define-key map (kbd "C-c w b") #'harness-ui-workspace-open-board)
    (define-key map (kbd "C-c w s") #'harness-ui-workspace-stop)
    (define-key map (kbd "C-c w q") #'harness-ui-bury)
    (define-key map (kbd "C-c w ?") #'harness-menu)
    map)
  "Keys of the workspace buffer.
Letters type into the compose box; these chords act on the workspace.")

(defun harness-ui-workspace--thread-at-point ()
  "Return the thread id at point, or nil."
  (get-text-property (point) 'harness-workspace-thread))

(defun harness-ui-workspace--current-thread ()
  "Return the thread record this buffer is composing into."
  (let ((threads (plist-get harness-ui-workspace--data :threads)))
    (or (cl-find harness-ui-workspace--thread threads
                 :key (lambda (thread) (plist-get thread :id)) :test #'equal)
        (car threads))))

(defun harness-ui-workspace--selected-thread ()
  "Return the thread id this buffer sends to, defaulting to the last."
  (or harness-ui-workspace--thread
      (plist-get (harness-ui-workspace--current-thread) :id)))

(defun harness-ui-workspace--insert-button (label action &optional help)
  "Insert a clickable LABEL that runs ACTION."
  (harness-ui-button label action :help help))

(defun harness-ui-workspace--state-glyph (thread)
  "Return the state glyph of THREAD."
  (pcase (plist-get thread :state)
    ("live" "●")
    ("waiting" "?")
    (_ "○")))

(defun harness-ui-workspace--state-face (thread)
  "Return the face of THREAD's state."
  (pcase (plist-get thread :state)
    ("live" 'harness-status-running-face)
    ("waiting" 'harness-status-blocked-face)
    (_ 'harness-dim-face)))

(defun harness-ui-workspace--insert-header ()
  "Insert the header line of the workspace."
  (let* ((workspace harness-ui-workspace--data)
         (name (or (plist-get workspace :name) "Workspace"))
         (thread (harness-ui-workspace--current-thread))
         (thread-title (or (plist-get thread :title) "All threads"))
         (memory (if (eq harness-ui-workspace--state 'error)
                     "Memory · unavailable"
                   (if harness-ui-workspace--memory
                       "Memory · ready"
                     "Memory · unavailable"))))
    (insert (propertize "Workspace" 'face 'harness-header-face)
            " · " (propertize name 'face 'harness-header-face)
            "   " (propertize (format "Thread · %s" thread-title) 'face 'harness-dim-face)
            "   " (propertize memory 'face 'harness-dim-face)
            "   ")
    (harness-ui-workspace--insert-button
     "Tasks" #'harness-ui-workspace-open-board "The task board of this workspace")
    (insert " ")
    (harness-ui-workspace--insert-button
     "New thread" #'harness-ui-workspace-new-thread "Start a new topic")
    (insert " ")
    (harness-ui-workspace--insert-button
     "Open episode" #'harness-ui-workspace-open-episode "The session behind this thread")
    (insert " ")
    (harness-ui-workspace--insert-button
     "Stop" #'harness-ui-workspace-stop "Stop the live turn")
    (insert " ")
    (harness-ui-workspace--insert-button
     "Refresh" #'harness-ui-workspace-refresh "Read the workspace again")
    (insert " ")
    (harness-ui-workspace--insert-button
     "Resources" #'harness-ui-workspace-resources
     "The browser, wallet and credentials of this workspace")
    (insert "\n")))

(defun harness-ui-workspace--insert-threads ()
  "Insert the thread list."
  (let ((threads (plist-get harness-ui-workspace--data :threads)))
    (insert (propertize "Threads" 'face 'harness-label-face) "\n")
    (if (null threads)
        (insert (propertize "No threads" 'face 'harness-dim-face) "\n")
      (dolist (thread threads)
        (let* ((id (plist-get thread :id))
               (active (equal id (harness-ui-workspace--selected-thread)))
               (line (concat (harness-ui-workspace--state-glyph thread) " "
                             (or (plist-get thread :title) "Thread")))
               (start (point)))
          (insert-text-button line
                              'action (lambda (_button)
                                        (harness-ui-workspace--select-thread id))
                              'follow-link t
                              'face (if active 'harness-user-label-face 'harness-dim-face)
                              'help-echo (format "Open %s" (or (plist-get thread :title) "thread")))
          (put-text-property start (point) 'harness-workspace-thread id)
          (insert "  ")
          (when (plist-get thread :pinned)
            (insert (propertize "★ " 'face 'harness-caution-face)))
          (insert "\n"))))))

(defun harness-ui-workspace--insert-divider (entry)
  "Insert a divider for ENTRY."
  (let* ((reason (let ((reason (plist-get entry :reason)))
                   (cond ((symbolp reason) reason)
                         ((stringp reason) (intern reason))
                         (t 'new-thread))))
         (word (pcase reason
                 ('new-thread "New thread")
                 ('revived "Resumed")
                 ('long-context "Continued")
                 (_ "New thread")))
         (thread (cl-find (plist-get entry :thread)
                          (plist-get harness-ui-workspace--data :threads)
                          :key (lambda (item) (plist-get item :id)) :test #'equal))
         (title (or (and thread (plist-get thread :title))
                    (plist-get entry :title) "Thread")))
    (insert (propertize (format "── %s · %s ──" word title)
                        'face 'harness-hint-face)
            "\n\n")))

(defun harness-ui-workspace--insert-message (entry)
  "Insert a message ENTRY."
  (let* ((role (let ((role (plist-get entry :role)))
                 (cond ((symbolp role) role) ((stringp role) (intern role)) (t 'user))))
         (agent (eq role 'assistant))
         (label (if agent "Agent" "You"))
         (text (or (plist-get entry :text) "")))
    (insert (propertize label 'face (if agent 'harness-agent-label-face
                                       'harness-user-label-face))
            "\n")
    (insert text)
    (unless (string-suffix-p "\n" text) (insert "\n"))
    (insert "\n")))

(defun harness-ui-workspace--insert-brief (entry)
  "Insert a brief card for ENTRY."
  (let ((tokens (plist-get entry :tokens)))
    (insert (propertize (format "Brief · %s tokens" (or tokens 0))
                        'face 'harness-hint-face)
            "\n\n")))

(defun harness-ui-workspace--insert-timeline ()
  "Insert the timeline."
  (if (null harness-ui-workspace--entries)
      (insert (propertize "No messages" 'face 'harness-dim-face) "\n")
    (dolist (entry harness-ui-workspace--entries)
      (pcase (let ((kind (plist-get entry :kind)))
               (cond ((symbolp kind) kind) ((stringp kind) (intern kind)) (t nil)))
        ('divider (harness-ui-workspace--insert-divider entry))
        ('brief (harness-ui-workspace--insert-brief entry))
        ('message (harness-ui-workspace--insert-message entry))
        (_ nil)))))

(defun harness-ui-workspace--render ()
  "Draw the workspace buffer."
  (when (derived-mode-p 'harness-ui-workspace-mode)
    (let* ((inhibit-read-only t)
           (draft (and (harness-compose-live-p) (harness-compose-text)))
           (selected (harness-ui-workspace--selected-thread)))
      (harness-compose-hide)
      (erase-buffer)
      (pcase harness-ui-workspace--state
        ('loading
         (insert (propertize "Workspace · loading" 'face 'harness-header-face) "\n\n"
                 (propertize "Loading…" 'face 'harness-dim-face) "\n"))
        ('error
         (insert (propertize "Workspace · unavailable" 'face 'harness-header-face) "\n\n"
                 (propertize (or harness-ui-workspace--error "Workspace unavailable")
                             'face 'harness-failure-face)
                 "\n\n")
         (harness-ui-workspace--insert-button "Retry" #'harness-ui-workspace-refresh))
        (_
         (harness-ui-workspace--insert-header)
         (insert "\n")
         (harness-ui-workspace--insert-threads)
         (insert "\n")
         (harness-ui-workspace--insert-timeline)))
      (insert "\n")
      (harness-compose-insert (or draft "") "Workspace message")
      (when (and harness-compose-start harness-compose-end)
        (put-text-property (point-min) (1- harness-compose-start) 'read-only t)
        (put-text-property (1+ harness-compose-end) (point-max) 'read-only t))
      (setq harness-ui-workspace--rendered-key
            (list harness-ui-workspace--id selected harness-ui-workspace--state
                  (length harness-ui-workspace--entries)))
      (harness-compose-fetch-completions)
      (set-buffer-modified-p nil))))

(defun harness-ui-workspace--render-tail ()
  "Redraw the compose box after the compose module changed its state."
  (harness-ui-workspace--render))

(defun harness-ui-workspace--use-root (workspace)
  "Make this buffer's `default-directory' the root of WORKSPACE."
  (when-let* ((root (plist-get workspace :root)))
    (setq default-directory (file-name-as-directory (expand-file-name root)))))

(defun harness-ui-workspace--set-data (workspace entries memory)
  "Take WORKSPACE, its ENTRIES and MEMORY as this buffer's state."
  (setq harness-ui-workspace--data workspace
        harness-ui-workspace--entries entries
        harness-ui-workspace--memory memory
        harness-ui-workspace--error nil
        harness-ui-workspace--state 'ready)
  (harness-ui-workspace--use-root workspace)
  (unless (and harness-ui-workspace--thread
               (cl-find harness-ui-workspace--thread (plist-get workspace :threads)
                        :key (lambda (thread) (plist-get thread :id)) :test #'equal))
    (setq harness-ui-workspace--thread
          (or (plist-get workspace :last-thread)
              (plist-get (car (plist-get workspace :threads)) :id))))
  (harness-ui-workspace--render))

(defun harness-ui-workspace--fetch ()
  "Read this workspace from the harness and draw it."
  (when (and (derived-mode-p 'harness-ui-workspace-mode) harness-ui-workspace--id)
    (let* ((buffer (current-buffer))
           (id harness-ui-workspace--id)
           (generation (1+ (or harness-ui-workspace--request 0)))
           (get (harness-ui-request "_harness/workspace/get" (list :id id)))
           (timeline (harness-ui-request "_harness/workspace/timeline"
                                         (list :id id :opts (list :limit 200))))
           (memory (harness-catch
                    (harness-ui-request "_harness/memory/status" (list :workspace id))
                    (lambda (_) nil))))
      (setq harness-ui-workspace--request generation)
      (unless (eq harness-ui-workspace--state 'ready)
        (setq harness-ui-workspace--state 'loading)
        (harness-ui-workspace--render))
      (harness-then
       (harness-all (list get timeline memory))
       (lambda (values)
         (when (and (buffer-live-p buffer)
                    (eq generation (buffer-local-value 'harness-ui-workspace--request buffer)))
           (with-current-buffer buffer
             (when (derived-mode-p 'harness-ui-workspace-mode)
               (harness-ui-workspace--set-data (nth 0 values) (nth 1 values) (nth 2 values))))))
       (lambda (err)
         (when (and (buffer-live-p buffer)
                    (eq generation (buffer-local-value 'harness-ui-workspace--request buffer)))
           (with-current-buffer buffer
             (setq harness-ui-workspace--state 'error
                   harness-ui-workspace--error (harness-error-message err))
             (harness-ui-workspace--render))))))))

(defun harness-ui-workspace--schedule-fetch ()
  "Refresh this buffer after the current events have landed."
  (when (derived-mode-p 'harness-ui-workspace-mode)
    (when (timerp harness-ui-workspace--fetch-timer)
      (cancel-timer harness-ui-workspace--fetch-timer))
    (setq harness-ui-workspace--fetch-timer
          (run-at-time 0.1 nil (lambda (buffer)
                                 (when (buffer-live-p buffer)
                                   (with-current-buffer buffer
                                     (setq harness-ui-workspace--fetch-timer nil)
                                     (harness-ui-workspace--fetch))))
                       (current-buffer)))))



;;;; Commands

(declare-function harness-tasks "harness-ui-tasks")
(declare-function harness-ui-session-opener "harness-ui")

(defun harness-ui-workspace--select-thread (id)
  "Make thread ID the one this buffer composes into."
  (interactive)
  (setq harness-ui-workspace--thread id)
  (harness-ui-workspace--render))

(defun harness-ui-workspace-send ()
  "Send the compose box's text to the workspace."
  (interactive)
  (let ((text (string-trim (harness-compose-text))))
    (if (string-blank-p text)
        (user-error "Empty message")
      (let ((workspace harness-ui-workspace--id)
            (thread (harness-ui-workspace--selected-thread))
            (buffer (current-buffer)))
        (let ((inhibit-read-only t))
          (harness-compose-insert ""))
        (harness-ui-workspace--render)
        (harness-ui-call
         "_harness/workspace/prompt"
         (append (list :id workspace :text text)
                 (and thread (list :opts (list :thread thread))))
         (lambda (_result)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (harness-ui-workspace--fetch))))
         (lambda (err)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (message "Workspace · %s" (harness-error-message err))
               (harness-ui-workspace--fetch)))))
        (harness-ui-workspace--schedule-fetch)))))

(defun harness-ui-workspace-clear ()
  "Clear the compose box."
  (interactive)
  (let ((inhibit-read-only t))
    (harness-compose-insert ""))
  (harness-ui-workspace--render))

(defun harness-ui-workspace-refresh ()
  "Read the workspace again."
  (interactive)
  (harness-ui-workspace--fetch))

(defun harness-ui-workspace-stop ()
  "Stop the live turn of the selected thread."
  (interactive)
  (let ((buffer (current-buffer)))
    (harness-ui-call
     "_harness/workspace/cancel"
     (list :id harness-ui-workspace--id
           :thread (harness-ui-workspace--selected-thread))
     (lambda (_result)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer (harness-ui-workspace--fetch))))
     (lambda (err) (message "Workspace · %s" (harness-error-message err))))))

(defun harness-ui-workspace-new-thread ()
  "Create a new thread and compose into it."
  (interactive)
  (let ((title (string-trim (read-string "Thread title: ")))
        (buffer (current-buffer)))
    (when (string-blank-p title) (setq title "New thread"))
    (harness-ui-call
     "_harness/workspace/thread/create"
     (list :id harness-ui-workspace--id :title title)
     (lambda (thread)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (setq harness-ui-workspace--thread (plist-get thread :id))
           (harness-ui-workspace--fetch))))
     (lambda (err)
       (message "Workspace · %s" (harness-error-message err))))))

(defun harness-ui-workspace-open-episode ()
  "Open the ordinary session behind the selected thread."
  (interactive)
  (let* ((thread (harness-ui-workspace--current-thread))
         (session (and thread (plist-get thread :live))))
    (unless session
      (user-error "No live episode"))
    (funcall (harness-ui-session-opener) session)))

(defun harness-ui-workspace-open-board ()
  "Open the task board of this workspace."
  (interactive)
  (unless (fboundp 'harness-tasks)
    (user-error "Task mode off"))
  (harness-tasks (plist-get harness-ui-workspace--data :root)))

(defun harness-ui-workspace--buffers ()
  "Return the live workspace buffers."
  (cl-remove-if-not
   (lambda (buffer)
     (and (buffer-live-p buffer)
          (with-current-buffer buffer
            (derived-mode-p 'harness-ui-workspace-mode))))
   (buffer-list)))

(defun harness-ui-workspace--on-event (event args)
  "Refresh the workspace buffers an EVENT with ARGS is about."
  (let ((event (if (symbolp event) (symbol-name event) event)))
    (when (member event '("workspace/changed" "workspace/deleted"
                          "workspace/timeline-appended" "workspace/thread-changed"
                          "workspace/episode-changed" "workspace/memory-changed"))
      (let ((id (car-safe args)))
      (dolist (buffer (harness-ui-workspace--buffers))
        (with-current-buffer buffer
            (when (or (null id) (equal id harness-ui-workspace--id))
              (harness-ui-workspace--schedule-fetch))))))))

(defun harness-ui-workspace--on-redraw ()
  "Refresh every workspace buffer after a reload or a reconnect."
  (dolist (buffer (harness-ui-workspace--buffers))
    (with-current-buffer buffer
      (harness-ui-workspace--fetch))))

(defun harness-ui-workspace--buffer-name (workspace)
  "Return the buffer name for WORKSPACE."
  (let* ((name (or (plist-get workspace :name) "Workspace"))
         (base (format "*harness workspace: %s*" name))
         (mine (get-buffer base)))
    (if (or (null mine)
            (equal (buffer-local-value 'harness-ui-workspace--id mine)
                   (plist-get workspace :id)))
        base
      (format "*harness workspace: %s <%s>*" name (plist-get workspace :id)))))

(defun harness-ui-workspace--open (workspace &optional position)
  "Show WORKSPACE in its buffer, at POSITION."
  (let* ((id (plist-get workspace :id))
         (buffer (get-buffer-create (harness-ui-workspace--buffer-name workspace))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'harness-ui-workspace-mode)
        (harness-ui-workspace-mode))
      ;; The root is known before the workspace itself is read: the box
      ;; that draws the loading state completes from it, not from nil.
      (harness-ui-workspace--use-root workspace)
      (setq harness-ui-workspace--id id
            harness-ui-workspace--state (or harness-ui-workspace--state 'loading)
            harness-ui-workspace--thread (and (plist-get workspace :last-thread)
                                              (plist-get workspace :last-thread))))
    (setq harness-ui-workspace--last-id id)
    (with-current-buffer buffer
      (harness-ui-workspace--fetch))
    (harness-ui-display-view buffer position)))

(defun harness-ui-workspace--create (name &optional root position)
  "Create a workspace called NAME at ROOT and show it at POSITION."
  (harness-ui-call
   "_harness/workspace/create"
   (append (list :name name) (and root (list :root root)))
   (lambda (workspace)
     (harness-ui-workspace--open workspace position))
   (lambda (err)
     (message "Workspace · %s" (harness-error-message err)))))

;;;###autoload
(defun harness-workspace (&optional position new)
  "Open the persistent workspace chat at POSITION.
With a prefix argument NEW, create a workspace first: ask for its name
and root.  With more than one workspace, choose one by name."
  (interactive (list (and current-prefix-arg (harness-ui-read-position))
                     current-prefix-arg))
  (if new
      (let ((name (string-trim (read-string "Workspace name: " "Home")))
            (root (read-directory-name "Workspace root: " nil nil t)))
        (harness-ui-workspace--create (if (string-blank-p name) "Home" name) root position))
    (harness-ui-call
     "_harness/workspace/list"
     nil
     (lambda (workspaces)
       (cond
        ((null workspaces)
         (harness-ui-workspace--create "Home" nil position))
        ((= (length workspaces) 1)
         (harness-ui-workspace--open (car workspaces) position))
        (t
         (let* ((names (mapcar (lambda (workspace)
                                 (cons (or (plist-get workspace :name) "Workspace") workspace))
                               workspaces))
                (choice (completing-read "Workspace: " names nil t)))
           (harness-ui-workspace--open (cdr (assoc choice names)) position)))))
     (lambda (err)
       (message "Workspace · %s" (harness-error-message err))))))

(defun harness-ui-workspace--kill ()
  "Stop the timer of a workspace buffer that is going away."
  (when (timerp harness-ui-workspace--fetch-timer)
    (cancel-timer harness-ui-workspace--fetch-timer)
    (setq harness-ui-workspace--fetch-timer nil)))

;;;; Mode and module

(define-derived-mode harness-ui-workspace-mode special-mode "Workspace"
  "Major mode of the persistent workspace chat.
The header shows the workspace, the thread and the memory state; the
thread list selects a topic; the timeline is the one chat.  Letters
type in the compose box.
\<harness-ui-workspace-mode-map>\[harness-ui-workspace-send] sends;
the `C-c w' keys act on the workspace."
  (setq buffer-read-only nil)
  (setq-local truncate-lines nil
              word-wrap t
              truncate-partial-width-windows nil)
  (harness-compose-setup
   ;; Before the first answer from the harness there is no workspace plist:
   ;; the box still completes and attaches from the buffer's directory,
   ;; which `harness-ui-workspace--open' set to the workspace root.
   :project (lambda () (or (plist-get harness-ui-workspace--data :root)
                           default-directory))
   :placeholder (lambda () "Message…")
   :redraw #'harness-ui-workspace--render-tail
   :bottom t)
  (add-hook 'kill-buffer-hook #'harness-ui-workspace--kill nil t)
  (harness-ui-view-install #'harness-ui-workspace-refresh))

(put 'harness-ui-workspace-mode 'harness-menu-group
     '("Workspace"
       ["Workspace"
        ("C-c w n" "New thread" harness-ui-workspace-new-thread)
        ("C-c w o" "Open episode" harness-ui-workspace-open-episode)
        ("C-c w b" "Task board" harness-ui-workspace-open-board)
        ("C-c w s" "Stop" harness-ui-workspace-stop)
        ("C-c w g" "Refresh" harness-ui-workspace-refresh)
        ("C-c w R" "Resources" harness-ui-workspace-resources)
        ("C-c w q" "Bury" harness-ui-bury)
        ("C-c C-c" "Send" harness-ui-workspace-send)
        ("C-c C-k" "Clear" harness-ui-workspace-clear)]))

(defun harness-ui-workspace--init ()
  "Add the workspace mode to the harness UI."
  (add-hook 'harness-ui-event-functions #'harness-ui-workspace--on-event)
  (add-hook 'harness-ui-redraw-hook #'harness-ui-workspace--on-redraw)
  (add-hook 'harness-ui-connected-hook #'harness-ui-workspace--on-redraw)
  (define-key harness-ui-map (kbd "Y") #'harness-workspace))

(defun harness-ui-workspace--shutdown ()
  "Remove the workspace mode from the harness UI."
  (remove-hook 'harness-ui-event-functions #'harness-ui-workspace--on-event)
  (remove-hook 'harness-ui-redraw-hook #'harness-ui-workspace--on-redraw)
  (remove-hook 'harness-ui-connected-hook #'harness-ui-workspace--on-redraw)
  (define-key harness-ui-map (kbd "Y") nil))

(harness-define-module 'ui-workspace
  :doc "The workspace chat: one timeline over threads, with a compose box."
  :requires '(ui ui-chat ui-compose)
  :init #'harness-ui-workspace--init
  :shutdown #'harness-ui-workspace--shutdown)

(provide 'harness-ui-workspace)
;;; harness-ui-workspace.el ends here

;;;; Workspace resources

;; The resources page of workspace mode: the browser, the wallet, the
;; credentials and the access the agent has to each.  It reads the same
;; `_harness/workspace/resources/status' as the Flutter client, and it shows
;; metadata only: no cookie value, password, card number or token is ever
;; inserted in this buffer.  The box and the payment broker are staged, so
;; the browser and wallet sections say what is missing; the credentials are
;; the harness's declared secrets, through the secret-sandbox module.

(defvar harness-ui-workspace-resources--id nil
  "Workspace id of the resources buffer.")

(defvar-local harness-ui-workspace-resources--data nil
  "The resources answer this buffer shows.")

(defvar-local harness-ui-workspace-resources--error nil
  "Why the last resources request failed, or nil.")

(defvar-local harness-ui-workspace-resources--loading nil
  "Whether a resources request is on its way.")

(defvar harness-ui-workspace-resources-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'harness-ui-workspace-resources-refresh)
    (define-key map (kbd "q") #'harness-ui-bury)
    map)
  "Keys of the resources buffer.")

(define-derived-mode harness-ui-workspace-resources-mode special-mode "Workspace Resources"
  "Major mode of the workspace's resources page.
It is read-only: the browser, the wallet and the credentials are shown
with their owner, scope, state and access; a value is never shown.
\\<harness-ui-workspace-resources-mode-map>\\[harness-ui-workspace-resources-refresh] reads it again."
  (setq buffer-read-only t)
  (setq-local truncate-lines nil
              word-wrap t))

(defun harness-ui-workspace-resources--heading (text)
  "Insert TEXT as a section heading."
  (insert "\n" (propertize text 'face 'harness-label-face) "\n"))

(defun harness-ui-workspace-resources--line (label value &optional face)
  "Insert LABEL and VALUE on one line, VALUE with FACE."
  (insert "  " (propertize label 'face 'harness-dim-face) "  "
          (propertize (format "%s" (or value "")) 'face (or face 'default))
          "\n"))

(defun harness-ui-workspace-resources--money (minor currency)
  "Return MINOR in CURRENCY as a short amount."
  (let ((minor (or minor 0))
        (currency (or currency "USD")))
    (if (equal currency "USD")
        (format "$%d.%02d" (/ minor 100) (% minor 100))
      (format "%s %d.%02d" currency (/ minor 100) (% minor 100)))))

(defun harness-ui-workspace-resources--amount (value)
  "Return VALUE as a short amount without a currency."
  (or value "—"))

(defun harness-ui-workspace-resources--render-browser (browser)
  "Insert the browser section of BROWSER."
  (harness-ui-workspace-resources--heading "Browser")
  (if (null browser)
      (insert "  " (propertize "Box staged" 'face 'harness-dim-face)
              "  ·  " (propertize "No browser data" 'face 'harness-dim-face) "\n")
    (let ((profile (plist-get browser :profile)))
      (harness-ui-workspace-resources--line
       (format "Profile · %s" (or (plist-get profile :label) "default"))
       (format "%s · %s sites"
               (or (plist-get profile :kind) "Chromium")
               (or (plist-get profile :sites) 0)))
      (dolist (site (plist-get browser :sites))
        (harness-ui-workspace-resources--line
         (or (plist-get site :origin) "Site")
         (format "%s cookies · signed %s"
                 (or (plist-get site :cookies) 0)
                 (pcase (plist-get site :auth)
                   ("signed-in" "in")
                   ("signed-out" "out")
                   (_ "unknown")))))
      (when (plist-get browser :logins)
        (insert "  " (propertize "Saved logins" 'face 'harness-dim-face) "\n")
        (dolist (login (plist-get browser :logins))
          (harness-ui-workspace-resources--line
           (or (plist-get login :origin) "Login")
           (format "%s · %s"
                   (or (plist-get login :username) "account")
                   (or (plist-get login :state) "unknown")))))
      (insert "  " (propertize "Export / Import · needs box · approval"
                               'face 'harness-dim-face) "\n")))
  (insert "\n"))

(defun harness-ui-workspace-resources--render-wallet (wallet)
  "Insert the wallet section of WALLET."
  (harness-ui-workspace-resources--heading "Wallet")
  (if (null wallet)
      (insert "  " (propertize "Payment broker" 'face 'harness-dim-face)
              "  ·  " (propertize "No wallet" 'face 'harness-dim-face) "\n")
    (dolist (card (plist-get wallet :cards))
      (harness-ui-workspace-resources--line
       (or (plist-get card :label) "Card")
       (format "%s · %02d/%d · %s"
               (or (plist-get card :network) "")
               (or (plist-get card :exp-month) 0)
               (or (plist-get card :exp-year) 0)
               (or (plist-get card :state) "unknown"))))
    (dolist (authorization (plist-get wallet :authorizations))
      (let ((amount (harness-ui-workspace-resources--money
                     (plist-get authorization :amount)
                     (plist-get authorization :currency))))
        (harness-ui-workspace-resources--line
         (format "%s · %s" amount
                 (if (equal (plist-get authorization :cap-kind) "per-transaction")
                     "Per transaction" "Cumulative"))
         (format "%s · %s · %s"
                 (or (plist-get authorization :merchant-scope) "Any merchant")
                 (or (plist-get authorization :status) "active")
                 (if (plist-get authorization :advisory)
                     "Advisory · no broker" "Enforced")))))
    (dolist (purchase (plist-get wallet :purchases))
      (harness-ui-workspace-resources--line
       (format "Purchase · %s" (harness-ui-workspace-resources--money
                                (plist-get purchase :amount)
                                (plist-get purchase :currency)))
       (format "%s · %s"
               (or (plist-get purchase :merchant) "Merchant")
               (or (plist-get purchase :status) "proposed")))))
  (insert "\n"))

(defun harness-ui-workspace-resources--render-credentials (credentials status)
  "Insert the credentials section of CREDENTIALS and STATUS."
  (harness-ui-workspace-resources--heading "Credentials")
  (let ((state (plist-get status :status)))
    (insert "  " (propertize (or (plist-get status :why) "Secrets module")
                             'face 'harness-dim-face)
            "  ·  "
            (propertize (pcase state
                          ("ready" "Locked run · ready")
                          ("needs-approval" "Needs approval")
                          (_ "Unavailable"))
                        'face (if (equal state "ready")
                                  'harness-status-running-face
                                'harness-dim-face))
            "\n"))
  (if (null credentials)
      (insert "  " (propertize "No credentials" 'face 'harness-dim-face) "\n")
    (dolist (credential credentials)
      (harness-ui-workspace-resources--line
       (or (plist-get credential :label) "Credential")
       (format "%s · %s · last used %s"
               (if (plist-get credential :usable) "Ready" "Unavailable")
               (or (plist-get credential :fingerprint) "no fingerprint")
               (or (plist-get credential :last-use) "never")))))
  (insert "\n"))

(defun harness-ui-workspace-resources--render-access (access audit)
  "Insert the access and audit sections of ACCESS and AUDIT."
  (harness-ui-workspace-resources--heading "Access")
  (if (null access)
      (insert "  " (propertize "No grants" 'face 'harness-dim-face) "\n")
    (dolist (grant access)
      (harness-ui-workspace-resources--line
       (or (plist-get grant :label) "Resource")
       (format "%s · %s · %s · %s"
               (or (plist-get grant :kind) "resource")
               (or (plist-get grant :scope) "workspace")
               (or (plist-get grant :owner) "user")
               (or (plist-get grant :access) "none")))))
  (harness-ui-workspace-resources--heading "Audit")
  (if (null audit)
      (insert "  " (propertize "No audit" 'face 'harness-dim-face) "\n")
    (dolist (entry audit)
      (harness-ui-workspace-resources--line
       (format "%s · %s" (or (plist-get entry :action) "Changed")
               (or (plist-get entry :resource) "Resource"))
       (format "%s · %s" (or (plist-get entry :actor) "user")
               (or (plist-get entry :scope) "workspace"))))))

(defun harness-ui-workspace-resources--render ()
  "Insert the resources answer in the current buffer."
  (let ((inhibit-read-only t)
        (data harness-ui-workspace-resources--data))
    (erase-buffer)
    (insert (propertize "Workspace resources" 'face 'harness-header-face)
            "  ·  "
            (propertize (or harness-ui-workspace-resources--id "Workspace")
                        'face 'harness-header-face)
            "  ·  "
            (propertize (pcase (plist-get data :status)
                          ("ready" "ready")
                          ("preview" "Preview · sample data")
                          ("unavailable" "unavailable")
                          (_ "Loading"))
                        'face (if (equal (plist-get data :status) "ready")
                                  'harness-status-running-face
                                'harness-dim-face))
            "  ·  "
            (propertize "Metadata only" 'face 'harness-dim-face)
            "   ")
    (harness-ui-button "Refresh" #'harness-ui-workspace-resources-refresh
                       :help "Read the resources again")
    (insert "\n")
    (when harness-ui-workspace-resources--error
      (insert (propertize harness-ui-workspace-resources--error
                          'face 'harness-caution-face)
              "\n"))
    (when harness-ui-workspace-resources--loading
      (insert (propertize "Loading…" 'face 'harness-dim-face) "\n"))
    (harness-ui-workspace-resources--render-browser
     (plist-get data :browser))
    (harness-ui-workspace-resources--render-wallet
     (plist-get data :wallet))
    (harness-ui-workspace-resources--render-credentials
     (plist-get data :credentials)
     (plist-get data :credentials-status))
    (harness-ui-workspace-resources--render-access
     (plist-get data :access)
     (plist-get data :audit))
    (insert "\n"
            (propertize "g · refresh" 'face 'harness-hint-face)
            "   "
            (propertize "q · bury" 'face 'harness-hint-face)
            "\n")
    (goto-char (point-min))))

(defun harness-ui-workspace-resources-refresh (&optional buffer)
  "Read the resources of the buffer's workspace again."
  (interactive)
  (let* ((buffer (or buffer (current-buffer)))
         (id (buffer-local-value 'harness-ui-workspace-resources--id buffer)))
    (with-current-buffer buffer
      (setq harness-ui-workspace-resources--loading t
            harness-ui-workspace-resources--error nil)
      (harness-ui-workspace-resources--render))
    (harness-ui-call
     "_harness/workspace/resources/status"
     (list :id id)
     (lambda (result)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (setq harness-ui-workspace-resources--data result
                 harness-ui-workspace-resources--loading nil)
           (harness-ui-workspace-resources--render))))
     (lambda (error)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (setq harness-ui-workspace-resources--loading nil
                 harness-ui-workspace-resources--error
                 (harness-error-message error))
           (harness-ui-workspace-resources--render)))))))

;;;###autoload
(defun harness-ui-workspace-resources (&optional workspace)
  "Show the resources of WORKSPACE, or of the current workspace.
The page lists the browser, the wallet, the credentials and the access
the agent has to each, metadata only.  With no workspace, it uses the
one the workspace buffer opened last."
  (interactive)
  (let ((id (or workspace
                (and (derived-mode-p 'harness-ui-workspace-mode)
                     harness-ui-workspace--id)
                harness-ui-workspace--last-id)))
    (unless id
      (user-error "No workspace: open one with M-x harness-workspace first"))
    (let ((buffer (get-buffer-create "*Workspace Resources*")))
      (with-current-buffer buffer
        (harness-ui-workspace-resources-mode)
        (setq harness-ui-workspace-resources--id id
              harness-ui-workspace-resources--data nil
              harness-ui-workspace-resources--error nil
              harness-ui-workspace-resources--loading t)
        (harness-ui-workspace-resources--render))
      (pop-to-buffer buffer)
      (harness-ui-workspace-resources-refresh buffer))))
