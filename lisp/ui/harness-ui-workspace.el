;;; harness-ui-workspace.el --- The workspace chat: threads, timeline and compose box -*- lexical-binding: t; -*-

;;; Commentary:

;; The Emacs front end of workspace mode.  It is one buffer: a header,
;; a thread list, the timeline of messages and dividers, and the same
;; compose box a chat uses.  It talks to the harness only through ACP:
;; `_harness/workspace/get', `_harness/workspace/timeline',
;; `_harness/workspace/prompt', and the `workspace/*' events.
;;
;; The timeline is the workspace's, not a session's.  Each entry knows
;; the episode it belongs to, so `Episode' opens the ordinary
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

(defvar-local harness-ui-workspace--knowledge nil
  "The knowledge status of this workspace, or nil.")

(defvar-local harness-ui-workspace--box nil
  "The computer status of this workspace, or nil.")

(defvar-local harness-ui-workspace--computers nil
  "The registered computers the harness may use, as `computer/list' gives them.")

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

(defvar harness-ui-workspace--syncing-p nil
  "Non-nil while the pending store is being read, so no redraw loops.")

(declare-function harness-workspace-speech "harness-ui-workspace-speech" (&optional id))
(declare-function harness-workspace-speech--insert "harness-ui-workspace-speech" (floor &optional no-heading))
(declare-function harness-workspace-speech--floor "harness-ui-workspace-speech" (&optional id))

(defvar harness-ui-workspace-mode-map
  (let ((map (make-sparse-keymap)))
    ;; The compose box's keys (RET newline, C-c C-a, C-y pasting images).
    ;; Not `special-mode-map', whose letters would eat typing in the box:
    ;; a parent set here is the one `define-derived-mode' keeps.
    (set-keymap-parent map harness-compose-map)
    (define-key map (kbd "C-c C-c") #'harness-ui-workspace-send)
    (define-key map (kbd "C-c C-k") #'harness-ui-workspace-clear)
    (define-key map (kbd "C-c w n") #'harness-ui-workspace-new-thread)
    (define-key map (kbd "C-c w o") #'harness-ui-workspace-open-episode)
    (define-key map (kbd "C-c w g") #'harness-ui-workspace-refresh)
    (define-key map (kbd "C-c w l") #'harness-ui-workspace-graph)
    (define-key map (kbd "C-c w c") #'harness-ui-workspace-computer)
    (define-key map (kbd "C-c w R") #'harness-ui-workspace-resources)
    (define-key map (kbd "C-c w b") #'harness-ui-workspace-open-board)
    (define-key map (kbd "C-c w r") #'harness-ui-workspace-reassign)
    (define-key map (kbd "C-c w i") #'harness-workspace-inbox)
    (define-key map (kbd "C-c w s") #'harness-ui-workspace-stop)
    (define-key map (kbd "C-c w v") #'harness-workspace-speech)
    (define-key map (kbd "C-c w q") #'harness-ui-bury)
    (define-key map (kbd "C-c w ?") #'harness-ui-menu)
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

(defun harness-ui-workspace--live-session (&optional thread)
  "Return the live episode of THREAD, or of the selected thread."
  (plist-get (or thread (harness-ui-workspace--current-thread)) :live))

(defun harness-ui-workspace--compose-context ()
  "Return what this workspace's compose box composes into.
The selected thread, asked each time, so a thread switch moves the
words; a workspace with no thread yet still has a target, because its
own prompt path makes the first one (`_harness/workspace/prompt')."
  (let* ((thread (harness-ui-workspace--selected-thread))
         (record (harness-ui-workspace--current-thread)))
    (list :kind 'workspace
          :workspace harness-ui-workspace--id
          :thread thread
          :session (and thread (harness-ui-workspace--live-session record))
          :name (or (plist-get record :title)
                    thread
                    harness-ui-workspace--id
                    "Workspace"))))

(defun harness-ui-workspace--episode-of-p (session-id)
  "Non-nil when SESSION-ID is the live episode of a thread here."
  (and (stringp session-id)
       (cl-some (lambda (thread) (equal session-id (plist-get thread :live)))
                (plist-get harness-ui-workspace--data :threads))))

(defun harness-ui-workspace--insert-button (label action &optional help)
  "Insert a clickable LABEL that runs ACTION."
  (harness-ui-button label action :help help))

(defun harness-ui-workspace--episode-status (thread)
  "Return THREAD's episode status as a string.
That is `:episode-status' from the harness (running, blocked, idle,
failed, stopped, inactive or parked) or, from a harness that does not
send it, the coarser `:state' and the cached session's own status."
  (let ((status (plist-get thread :episode-status)))
    (if (and (stringp status) (not (string-empty-p status)))
        status
      (pcase (format "%s" (or (plist-get thread :state) "parked"))
        ("waiting" "blocked")
        ("live"
         (let ((session (harness-ui-session (plist-get thread :live))))
           (if (and session
                    (equal "running" (format "%s" (plist-get session :status))))
               "running"
             "live")))
        (_ "parked")))))

(defun harness-ui-workspace--pending-kind (thread)
  "Return question, permission or nil: what THREAD waits on."
  (when-let* ((item (car (harness-ui-pending-items (plist-get thread :live)))))
    (if (equal "question" (format "%s" (plist-get item :kind)))
        "question"
      "permission")))

(defun harness-ui-workspace--status-label (thread)
  "Return the words THREAD's episode status shows."
  (pcase (harness-ui-workspace--episode-status thread)
    ("running" "Running")
    ("blocked" (if (equal (harness-ui-workspace--pending-kind thread) "question")
                   "Blocked · Question"
                 "Blocked · Permission"))
    ("idle" "Idle")
    ("failed" "Failed")
    ("stopped" "Stopped")
    ("inactive" "Inactive")
    ("live" "Live")
    (_ "Parked")))

(defun harness-ui-workspace--status-face (status)
  "Return the face STATUS shows in."
  (pcase status
    ("running" 'harness-status-running-face)
    ("blocked" 'harness-status-blocked-face)
    ("failed" 'harness-failure-face)
    ("stopped" 'harness-caution-face)
    ((or "idle" "live" "inactive") 'harness-status-idle-face)
    (_ 'harness-dim-face)))

(defun harness-ui-workspace--status-icon (status)
  "Return the icon STATUS shows."
  (pcase status
    ("running" (harness-ui-icon 'harness-icon-running))
    ("blocked" (harness-ui-icon 'harness-icon-blocked))
    ("failed" (harness-ui-icon 'harness-icon-failure))
    ("stopped" (harness-ui-icon 'harness-icon-caution))
    (_ (harness-ui-icon 'harness-icon-idle))))

(declare-function harness-chat--activity-text "harness-ui-chat" (activity))

(defun harness-ui-workspace--activity-label (thread)
  "Return what THREAD's running episode does now, or nil.
The words are the chat's (`harness-chat--activity-text'), so a workspace
says \"Waiting for the model…\", \"Thinking…\" or \"Running Read file…\"
as a chat does.  Only a running episode has them: a stale activity from
the turn before does not outlive its state words."
  (when (and (equal "running" (harness-ui-workspace--episode-status thread))
             (plist-get thread :activity))
    (harness-chat--activity-text (plist-get thread :activity))))

(defun harness-ui-workspace--activity-line (thread)
  "Return the line above the box that says what THREAD's turn does, or nil.
A running turn with no activity yet -- before the harness's first
update, or from a harness that reports none -- says \"Working…\", as
the chat's activity line does.  An episode that does not run says
nothing, so the box moves up to the timeline."
  (when (equal "running" (harness-ui-workspace--episode-status thread))
    (let ((activity (plist-get thread :activity)))
      (concat " "
              (propertize (if activity
                              (harness-chat--activity-text activity)
                            "Working…")
                          'face 'harness-dim-face)))))

(defun harness-ui-workspace--setting-values (&optional thread)
  "Return the settings the settings line shows for THREAD.
They are what its live episode runs with, or the workspace's defaults
when it has none (or when there is no thread yet), as the harness sends
them."
  (let ((workspace harness-ui-workspace--data))
    (list :model (or (plist-get thread :model) (plist-get workspace :model))
          :thinking (or (plist-get thread :thinking) (plist-get workspace :thinking))
          :permission-mode (or (plist-get thread :permission-mode)
                               (plist-get workspace :permission-mode))
          :non-interactive (if (plist-member thread :non-interactive)
                               (plist-get thread :non-interactive)
                             (plist-get workspace :non-interactive)))))

(defun harness-ui-workspace--setting-target ()
  "Return what the setting commands change in this buffer.
That is the selected thread's live episode, or its workspace's defaults
for the next episode: (VALUES SET-FUNCTION CONTEXT), as
`harness-ui-setting-target-function' takes a non-session target."
  (let* ((thread (harness-ui-workspace--current-thread))
         (live (and thread (plist-get thread :live))))
    (or live
        (and harness-ui-workspace--data
             (list (harness-ui-workspace--setting-values thread)
                   #'harness-ui-workspace--set-default
                   "this workspace")))))

(defun harness-ui-workspace--set-default (key value)
  "Set the workspace default for setting KEY to VALUE.
It applies to the next episode, not to one that is already live."
  (let ((buffer (current-buffer)))
    (harness-ui-call
     "_harness/workspace/update"
     (list :id harness-ui-workspace--id key
           (if (and (eq key :non-interactive) (not value)) :false value))
     (lambda (_workspace)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (harness-ui-workspace--fetch))))
     (lambda (err)
       (message "Workspace · %s" (harness-error-message err))))))

(defun harness-ui-workspace--setting-button (spec)
  "Return the button standing for setting SPEC of `harness-ui-setting-specs'."
  (let ((command (plist-get spec :command)))
    (harness-ui-action-button (plist-get spec :label)
                              (lambda () (call-interactively command))
                              :help (plist-get spec :help)
                              :face (or (plist-get spec :face) 'harness-dim-face))))

(defun harness-ui-workspace--settings-room ()
  "Return how many columns the workspace settings line has.
The narrowest window showing the buffer decides, so the line fits them
all, less a column for the continuation glyph of a window without
fringes; 80 when no window shows it."
  (let ((windows (get-buffer-window-list (current-buffer) nil t)))
    (if windows
        (max 20 (1- (apply #'min (mapcar #'window-body-width windows))))
      80)))

(defun harness-ui-workspace--settings-line (&optional room)
  "Return the workspace's settings line, or nil when there is none.
It is drawn below the compose box, as a chat's is: the selected
thread's model, thinking level, permission mode and interactive switch
-- its live episode's, or the workspace defaults when it has no episode
-- and, while an episode is live, what it has used: the context and the
cost.  The settings are buttons of the shared settings line
\(`harness-ui-settings-line'), fitted to ROOM columns."
  (let* ((thread (harness-ui-workspace--current-thread))
         (live (and thread (plist-get thread :live)))
         (session (and live (harness-ui-session live)))
         (values (or (and session (list :model (plist-get session :model)
                                        :thinking (plist-get session :thinking)
                                        :permission-mode (plist-get session :permission-mode)
                                        :non-interactive (plist-get session :non-interactive)))
                     (harness-ui-workspace--setting-values thread)))
         (scope (if live "this thread" "this workspace"))
         (figures
          (when session
            (delq nil
                  (list (let ((context (harness-ui-format-context session t)))
                          (and context (not (string-empty-p context))
                               (list (harness-ui-string-action
                                      context (lambda () (harness-set-context-limit live)))
                                     30)))
                        (let ((spend (harness-ui-format-spend
                                      session t "This episode" t)))
                          (and spend (not (string-empty-p spend))
                               (list (harness-ui-string-action
                                      spend (lambda () (harness-ui-show-usage)))
                                     10))))))))
    (when (and values (or thread (plist-get harness-ui-workspace--data :model)))
      (harness-ui-settings-line
       (list (harness-ui-setting-items
              (harness-ui-setting-specs values :scope scope)
              #'harness-ui-workspace--setting-button)
             figures)
       room))))

(defun harness-ui-workspace--insert-header ()
  "Insert the header line of the workspace."
  (let* ((workspace harness-ui-workspace--data)
         (name (or (plist-get workspace :name) "Workspace"))
         (thread (harness-ui-workspace--current-thread))
         (thread-title (or (plist-get thread :title) "All threads"))
         (status (harness-ui-workspace--episode-status thread))
         (activity (harness-ui-workspace--activity-label thread))
         (knowledge (if (and (not (eq harness-ui-workspace--state 'error))
                             harness-ui-workspace--knowledge
                             (plist-get harness-ui-workspace--knowledge :available))
                        "Knowledge · ready"
                      "Knowledge · unavailable"))
         (box (plist-get harness-ui-workspace--box :state))
         (computer (cond ((equal box "running") "Computer · live")
                         ((equal box "starting") "Computer · starting")
                         (t "Computer · off"))))
    (insert (propertize "Workspace" 'face 'harness-header-face)
            " · " (propertize name 'face 'harness-header-face)
            "   " (propertize "Thread · " 'face 'harness-dim-face)
            (propertize thread-title 'face 'harness-dim-face)
            " · " (propertize (harness-ui-workspace--status-label thread)
                              'face (harness-ui-workspace--status-face status))
            (if activity
                (concat " · " (propertize activity 'face 'harness-dim-face))
              "")
            "   " (propertize knowledge 'face 'harness-dim-face)
            "   " (propertize computer 'face 'harness-dim-face)
            "   ")
    (harness-ui-workspace--insert-button
     "Tasks" #'harness-ui-workspace-open-board "The task board of this workspace")
    (insert " ")
    (harness-ui-workspace--insert-button
     "Inbox" #'harness-workspace-inbox
     "The messages waiting in each thread's queue")
    (insert " ")
    (harness-ui-workspace--insert-button
     "New thread" #'harness-ui-workspace-new-thread "Start a new topic")
    (insert " ")
    (harness-ui-workspace--insert-button
     "Episode" #'harness-ui-workspace-open-episode "The session behind this thread")
    (insert " ")
    (harness-ui-workspace--insert-button
     "Stop" #'harness-ui-workspace-stop "Stop the live turn")
    (insert " ")
    (harness-ui-workspace--insert-button
     "Refresh" #'harness-ui-workspace-refresh "Read the workspace again")
    (insert " ")
    (harness-ui-workspace--insert-button
     "Graph" #'harness-ui-workspace-graph
     "The Logseq nodes of this thread")
    (insert " ")
    (harness-ui-workspace--insert-button
     "Workspace computer" #'harness-ui-workspace-computer
     "workspace computer page")
    (insert " ")
    (harness-ui-workspace--insert-button
     "Resources" #'harness-ui-workspace-resources
     "The browser, wallet and credentials of this workspace")
    (insert "\n")))

(defun harness-ui-workspace--insert-speech ()
  "Insert the workspace's speech floor into the chat.
The optional speech module draws it; nothing here keeps a queue of its
own, and a harness without the floor inserts nothing."
  (when (fboundp 'harness-workspace-speech--insert)
    (let ((floor (and (fboundp 'harness-workspace-speech--floor)
                      (harness-workspace-speech--floor harness-ui-workspace--id))))
      (when floor
        (insert "\n")
        (harness-workspace-speech--insert floor t)
        (insert "\n")))))

(defun harness-ui-workspace--insert-threads ()
  "Insert the thread list."
  (let ((threads (plist-get harness-ui-workspace--data :threads)))
    (insert (propertize "Threads" 'face 'harness-label-face) "\n")
    (if (null threads)
        (insert (propertize "No threads" 'face 'harness-dim-face) "\n")
      (dolist (thread threads)
        (let* ((id (plist-get thread :id))
               (active (equal id (harness-ui-workspace--selected-thread)))
               (title (or (plist-get thread :title) "Thread"))
               (status (harness-ui-workspace--episode-status thread))
               (face (harness-ui-workspace--status-face status))
               ;; A running thread says what its turn does now, as a chat's
               ;; activity line does; the state words say what it is otherwise.
               (label (or (harness-ui-workspace--activity-label thread)
                          (harness-ui-workspace--status-label thread)))
               (start (point))
               (title-end (+ start (length (harness-ui-workspace--status-icon status))
                             1 (length title) 2)))
          (insert-text-button
           (concat (propertize (harness-ui-workspace--status-icon status) 'face face)
                   " " title "  " label)
           'action (lambda (_button) (harness-ui-workspace--select-thread id))
           'follow-link t
           'face (if active 'harness-user-label-face 'harness-dim-face)
           'help-echo (format "Open %s · %s" title label))
          (put-text-property start (point) 'harness-workspace-thread id)
          ;; The status word keeps its own colour over the row's.
          (add-face-text-property title-end (point) face)
          (insert "  ")
          (when (plist-get thread :pinned)
            (insert (propertize "★ " 'face 'harness-caution-face)))
          (insert "\n"))))))

(defun harness-ui-workspace--thread-title (thread)
  "Return the title of the thread THREAD, an id, or \"Thread\"."
  (let ((record (cl-find thread (plist-get harness-ui-workspace--data :threads)
                         :key (lambda (item) (plist-get item :id)) :test #'equal)))
    (or (and record (plist-get record :title)) "Thread")))

(defun harness-ui-workspace--entry-kind (entry)
  "Return ENTRY's kind as a symbol."
  (let ((kind (plist-get entry :kind)))
    (cond ((symbolp kind) kind) ((stringp kind) (intern kind)) (t nil))))

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
         (thread (plist-get entry :thread))
         (title (if thread
                    (harness-ui-workspace--thread-title thread)
                  (or (plist-get entry :title) "Thread"))))
    (insert (propertize (format "── %s · %s ──" word title)
                        'face 'harness-hint-face)
            "\n\n")))

(defun harness-ui-workspace--insert-thread-line (thread)
  "Insert a line naming the thread THREAD a message was routed to."
  (insert (propertize (format "Thread · %s" (harness-ui-workspace--thread-title thread))
                      'face 'harness-dim-face)
          "\n"))

(defun harness-ui-workspace--origin-label (entry)
  "Return the words naming where ENTRY came from, or nil when that is plain.
The timeline entry keeps the thread the message was addressed to, the
thread that handles it and the profile it arrived through, so this reads
them from the entry itself: the UI is a client and asks the harness for
no second lookup.  An entry written before provenance existed has none,
and its origin and handling are its own thread, so it reads as plain."
  (let* ((thread (plist-get entry :thread))
         (origin (or (plist-get entry :origin) thread))
         (handling (or (plist-get entry :handling) thread))
         (profile (or (plist-get entry :profile) "text"))
         (default (or (plist-get harness-ui-workspace--data :profile)
                      "text"))
         (title (harness-ui-workspace--thread-title origin)))
    (cond
     ((and (equal origin handling) (equal profile default)) nil)
     ((and title (not (equal origin handling)))
      (if (equal profile default)
          (format "From %s" title)
        (format "From %s · %s" title profile)))
     ((not (equal profile default)) (format "From %s" profile))
     (t nil))))

(defun harness-ui-workspace--reassigned-label (entry)
  "Return the words naming where ENTRY was moved to, or nil.
Nil when the message was never reassigned.  The words name the thread it
went to and who moved it, so a reader can tell a person's decision from
the mediator's."
  (let ((moved (plist-get entry :reassigned)))
    (when moved
      (let* ((to (if (consp moved) (plist-get moved :to) moved))
             (by (and (consp moved) (plist-get moved :by)))
             (title (or (harness-ui-workspace--thread-title to) to)))
        (if (and (stringp by) (not (string-empty-p by)))
            (format "Reassigned to %s · %s" title by)
          (format "Reassigned to %s" title))))))

(defun harness-ui-workspace--insert-message (entry)
  "Insert a message ENTRY, with where it came from when that is not plain.
A message the router put in another thread, or one that arrived
through another profile, says so above its text: the reader keeps
one conversation and still knows which thread began the exchange.
A reassigned message says where it went and who moved it."
  (let* ((role (let ((role (plist-get entry :role)))
                 (cond ((symbolp role) role)
                       ((stringp role) (intern role))
                       (t 'user))))
         (agent (eq role 'assistant))
         (label (if agent "Agent" "You"))
         (text (or (plist-get entry :text) ""))
         (origin (harness-ui-workspace--origin-label entry))
         (moved (harness-ui-workspace--reassigned-label entry)))
    (insert (propertize label 'face (if agent 'harness-agent-label-face
                                       'harness-user-label-face)))
    (when origin
      (insert " " (propertize origin 'face 'harness-dim-face)))
    (insert "\n")
    (when moved
      (insert (propertize moved 'face 'harness-hint-face) "\n"))
    (insert text)
    (unless (string-suffix-p "\n" text) (insert "\n"))
    (insert "\n")))

(defun harness-ui-workspace--insert-brief (entry)
  "Insert a brief card for ENTRY."
  (let ((tokens (plist-get entry :tokens)))
    (insert (propertize (format "Brief · %s tokens" (or tokens 0))
                        'face 'harness-hint-face)
            "\n\n")))

(defun harness-ui-workspace--insert-reassignment (entry)
  "Insert a line for a reassignment ENTRY.
The words name where the message went and what became of the copy
that stood in the thread it was written in, so a reader can tell a
message moved before it was read from one the model already had."
  (let* ((to (or (harness-ui-workspace--thread-title
                  (plist-get entry :thread))
                 "another thread"))
         (from (and (plist-get entry :origin)
                    (harness-ui-workspace--thread-title
                     (plist-get entry :origin))))
         (delivery (format "%s"
                           (or (plist-get entry :delivery) "uncertain")))
         (words (if from
                    (format "Reassigned %s → %s · %s" from to delivery)
                  (format "Reassigned to %s · %s" to delivery))))
    (insert (propertize words 'face 'harness-hint-face) "\n\n")))

(defun harness-ui-workspace--insert-entry (entry insert)
  "Insert ENTRY with INSERT, remembering ENTRY in the text it wrote.
The commands that act on a message find it here, so a person's command
acts on the message under point and never on the last one in the buffer
or on words read back from the text."
  (let ((start (point)))
    (funcall insert entry)
    (put-text-property start (point) 'harness-workspace-entry entry)))

(defun harness-ui-workspace--insert-timeline ()
  "Insert the timeline.
A message the router put in another thread than the one before it is
named with its thread, so a switch back is visible where it happened."
  (if (null harness-ui-workspace--entries)
      (insert (propertize "No messages" 'face 'harness-dim-face) "\n")
    (let ((previous nil))
      (dolist (entry harness-ui-workspace--entries)
        (pcase (harness-ui-workspace--entry-kind entry)
          ('divider
           (harness-ui-workspace--insert-entry
            entry #'harness-ui-workspace--insert-divider)
           (setq previous (plist-get entry :thread)))
          ('brief (harness-ui-workspace--insert-entry
            entry #'harness-ui-workspace--insert-brief))
          ('reassignment (harness-ui-workspace--insert-entry
            entry #'harness-ui-workspace--insert-reassignment))
          ('message
           (let ((thread (plist-get entry :thread)))
             (when (and previous thread (not (equal previous thread)))
               (harness-ui-workspace--insert-thread-line thread))
             (setq previous thread)
             (harness-ui-workspace--insert-entry
             entry #'harness-ui-workspace--insert-message)))
          (_ nil))))))

(defun harness-ui-workspace--computer-state (computer)
  "Return COMPUTER's state as a word for the workspace."
  (cond ((plist-get computer :connected) "Live")
        ((eq (intern (format "%s" (or (plist-get computer :state) ""))) 'registered)
         "Registered")
        (t "Off")))

(defun harness-ui-workspace--computer-view (computer)
  "Open COMPUTER's screen share, or say there is none."
  (let ((url (plist-get computer :vnc)))
    (cond
     ((and (stringp url) (not (string-blank-p url)))
      (if (fboundp 'harness-computer-endpoint-view)
          (harness-computer-endpoint-view url)
        (browse-url url)))
     ((fboundp 'harness-computers) (harness-computers))
     (t (message "No screen share · %s" (or (plist-get computer :name) "computer"))))))

(defun harness-ui-workspace--computer-control (computer)
  "Take control of COMPUTER for this client."
  (let ((buffer (current-buffer)))
    (harness-ui-call
     "_harness/computer/take-control" (list :id (plist-get computer :id))
     (lambda (_)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer (harness-ui-workspace--fetch))))
     (lambda (err) (message "Harness: %s" (harness-error-message err))))))

(defun harness-ui-workspace--computer-return (computer)
  "Give control of COMPUTER back to the agent."
  (let ((buffer (current-buffer)))
    (harness-ui-call
     "_harness/computer/release-control" (list :id (plist-get computer :id))
     (lambda (_)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer (harness-ui-workspace--fetch))))
     (lambda (err) (message "Harness: %s" (harness-error-message err))))))

(defun harness-ui-workspace--insert-computers ()
  "Insert the registered computers, with a screen view and the control toggle."
  (insert (propertize "Computers" 'face 'harness-label-face) "  ")
  (harness-ui-workspace--insert-button "All computers" #'harness-computers
                                       "The computers page")
  (insert "\n")
  (let ((computers harness-ui-workspace--computers))
    (if (null computers)
        (insert (propertize "No computers" 'face 'harness-dim-face) "\n")
      (dolist (computer (seq-take computers 4))
        (let ((name (or (plist-get computer :name) (plist-get computer :id) "computer"))
              (control (plist-get computer :control)))
          (insert "  " (propertize name 'face 'harness-user-label-face)
                  "  " (propertize (harness-ui-workspace--computer-state computer)
                                    'face (if (plist-get computer :connected)
                                              'harness-status-running-face
                                            'harness-dim-face))
                  "  ")
          (when (plist-get computer :vnc)
            (harness-ui-workspace--insert-button
             "View" (lambda () (harness-ui-workspace--computer-view computer))
             (format "screen share of %s" name))
            (insert "  "))
          (if control
              (harness-ui-workspace--insert-button
               "Return" (lambda () (harness-ui-workspace--computer-return computer))
               (format "control return of %s" name))
            (harness-ui-workspace--insert-button
             "Control" (lambda () (harness-ui-workspace--computer-control computer))
             (format "control of %s" name)))
          (insert "\n"))))))

(defun harness-ui-workspace--insert-pending ()
  "Insert the requests the selected thread's live episode waits on.
They are the shared pending module's panels, drawn as the chat draws
them, so the answers and their tooltips are the ones every view has."
  (let ((session (harness-ui-workspace--live-session)))
    (when (and session (harness-ui-pending-items session))
      (insert (propertize "Pending requests" 'face 'harness-label-face) "\n")
      (harness-ui-pending-insert-panels session)
      (insert "\n"))))

(defun harness-ui-workspace--render ()
  "Draw the workspace buffer."
  (when (derived-mode-p 'harness-ui-workspace-mode)
    (let* ((inhibit-read-only t)
           (draft (and (harness-compose-live-p) (harness-compose-text)))
           (selected (harness-ui-workspace--selected-thread))
           (session (harness-ui-workspace--live-session))
           (in-compose (and (harness-compose-live-p)
                            (integerp harness-compose-start)
                            (harness-compose-in-p)
                            (- (point) harness-compose-start)))
           (panel (get-text-property (point) 'harness-ui-pending)))
      ;; The panel keys answer the request of the episode this buffer
      ;; shows; a thread switch or a new episode rebinds it here.
      (setq harness-ui-pending-session-id session)
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
         ;; What the workspace has to say, before the threads: a waiting
         ;; thread is what the person acts on first.
         (harness-ui-workspace--insert-speech)
         (harness-ui-workspace--insert-threads)
         (insert "\n")
         (harness-ui-workspace--insert-timeline)
         (insert "\n")
         (harness-ui-workspace--insert-computers)
         (insert "\n")
         (harness-ui-workspace--insert-pending)))
      (insert "\n")
      ;; The header and the thread rail scroll away with a long timeline;
      ;; the line above the box says what the selected turn does where the
      ;; person types.
      (when-let* ((activity (harness-ui-workspace--activity-line
                             (harness-ui-workspace--current-thread))))
        (insert activity "\n"))
      (harness-compose-insert (or draft "") "Workspace message")
      (let ((compose-end (and (markerp harness-compose-end)
                              (marker-position harness-compose-end)))
            (settings (and (eq harness-ui-workspace--state 'ready)
                           (harness-ui-workspace--settings-line
                            (harness-ui-workspace--settings-room)))))
        (when settings
          (insert "\n" settings)
          ;; The settings are not part of the box: its end stays before
          ;; them, so the read-only region below begins after the box.
          (when (and compose-end (markerp harness-compose-end))
            (set-marker harness-compose-end compose-end))))
      (when (and harness-compose-start harness-compose-end)
        (put-text-property (point-min) (1- harness-compose-start) 'read-only t)
        (put-text-property (1+ harness-compose-end) (point-max) 'read-only t))
      ;; A redraw for a pending change must not take the box from under
      ;; the person typing in it, nor point from the panel being read.
      (cond
       ((and (integerp in-compose) harness-compose-start harness-compose-end)
        (goto-char (min (+ harness-compose-start in-compose) harness-compose-end)))
       (panel
        (when-let* ((pos (text-property-any (point-min) (point-max)
                                            'harness-ui-pending panel)))
          (goto-char pos)))
       ;; The settings line follows the box, so the end of the buffer is no
       ;; longer where typing goes: a redraw leaves point in the box, as it
       ;; did before the line existed.
       (t (when (and harness-compose-end (>= (point) (point-max)))
            (goto-char harness-compose-end))))
      (setq harness-ui-workspace--rendered-key
            (list harness-ui-workspace--id selected harness-ui-workspace--state
                  (length harness-ui-workspace--entries)
                  (and session (length (harness-ui-pending-items session)))))
      ;; Before the first answer there is no root to list, and a file
      ;; listing without one is an error, not an empty list.
      (when (plist-get harness-ui-workspace--data :root)
        (harness-compose-fetch-completions))
      (set-buffer-modified-p nil))))

(defun harness-ui-workspace--render-tail ()
  "Redraw the compose box after the compose module changed its state."
  (harness-ui-workspace--render))

(defun harness-ui-workspace--use-root (workspace)
  "Make this buffer's `default-directory' the root of WORKSPACE."
  (when-let* ((root (plist-get workspace :root)))
    (setq default-directory (file-name-as-directory (expand-file-name root)))))

(defun harness-ui-workspace--sync-pending (workspace)
  "Read the pending requests WORKSPACE's threads name into the shared store.
A harness that sends `:pending' with the view is the word of what its
episodes wait on, and reconciles a request answered elsewhere; one that
does not send it is read from the session cache."
  (let ((harness-ui-workspace--syncing-p t))
    (dolist (thread (plist-get workspace :threads))
      (when-let* ((session (plist-get thread :live)))
        (if (plist-member thread :pending)
            (harness-ui-pending-sync session (plist-get thread :pending))
          (harness-ui-pending-sync-session session))))))

(defun harness-ui-workspace--set-data (workspace entries knowledge &optional box computers)
  "Take WORKSPACE, its ENTRIES, KNOWLEDGE, BOX and COMPUTERS as this state."
  (setq harness-ui-workspace--data workspace
        harness-ui-workspace--entries entries
        harness-ui-workspace--knowledge knowledge
        harness-ui-workspace--box box
        harness-ui-workspace--computers computers
        harness-ui-workspace--error nil
        harness-ui-workspace--state 'ready)
  (harness-ui-workspace--use-root workspace)
  (unless (and harness-ui-workspace--thread
               (cl-find harness-ui-workspace--thread (plist-get workspace :threads)
                        :key (lambda (thread) (plist-get thread :id)) :test #'equal))
    (setq harness-ui-workspace--thread
          (or (plist-get workspace :last-thread)
              (plist-get (car (plist-get workspace :threads)) :id))))
  (harness-ui-workspace--sync-pending workspace)
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
           (knowledge (harness-catch
                       (harness-ui-request "_harness/knowledge/status" (list :workspace id))
                       (lambda (_) nil)))
           (box (harness-catch
                 (harness-ui-request "_harness/workspace/box/status" (list :workspace id))
                 (lambda (_) nil)))
           (computers (harness-catch
                       (harness-ui-request "_harness/computer/list" nil)
                       (lambda (_) nil))))
      (setq harness-ui-workspace--request generation)
      (unless (eq harness-ui-workspace--state 'ready)
        (setq harness-ui-workspace--state 'loading)
        (harness-ui-workspace--render))
      (harness-then
       (harness-all (list get timeline knowledge box computers))
       (lambda (values)
         (when (and (buffer-live-p buffer)
                    (eq generation (buffer-local-value 'harness-ui-workspace--request buffer)))
           (with-current-buffer buffer
             (when (derived-mode-p 'harness-ui-workspace-mode)
               (harness-ui-workspace--set-data (nth 0 values) (nth 1 values)
                                               (nth 2 values) (nth 3 values)
                                               (nth 4 values))))))
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
  "Send the compose box's text to the workspace.
When the selected thread's live episode waits on a question, the text
is the answer to it, as it is in a chat: the harness keeps the turn
blocked otherwise, and a message sent beside it would only queue."
  (interactive)
  (let* ((text (string-trim (harness-compose-text)))
         (session (harness-ui-workspace--live-session))
         (question (and session (harness-ui-pending-question session))))
    (cond
     ((and question (or (not (string-blank-p text))
                        (harness-ui-pending-picked-any-p session)))
      (let ((inhibit-read-only t))
        (harness-compose-insert ""))
      (harness-ui-pending-answer-question
       session (plist-get question :id)
       (harness-ui-pending-compose-answer session question text))
      (harness-ui-workspace--render))
     ((string-blank-p text)
      (user-error "Empty message"))
     (t
      (let ((workspace harness-ui-workspace--id)
            (thread (harness-ui-workspace--selected-thread))
            (buffer (current-buffer)))
        (let ((inhibit-read-only t))
          (harness-compose-insert ""))
        ;; The model is loading before the harness's first activity says so:
        ;; the thread, the header and the line above the box say it at once,
        ;; not only after a round trip.
        (when thread
          (harness-ui-workspace--change-thread
           thread (list :episode-status "running"
                        :activity (list :phase "waiting" :since (float-time)))))
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
        (harness-ui-workspace--schedule-fetch))))))

(defun harness-ui-workspace-clear ()
  "Clear the compose box."
  (interactive)
  (let ((inhibit-read-only t))
    (harness-compose-insert ""))
  (harness-ui-workspace--render))
(defun harness-ui-workspace--reassign-summary (result)
  "Return the words naming what became of a reassignment RESULT.
The status says what happened and the delivery says what became of the
copy in the thread the message was written in; a reader sees both, so
a message moved before it was read is not confused with one the model
already had."
  (let* ((status (format "%s" (or (plist-get result :status) "stale")))
         (thread (or (plist-get result :thread) ""))
         (title (or (harness-ui-workspace--thread-title thread) thread))
         (delivery (format "%s" (or (plist-get result :delivery) "uncertain")))
         (why (plist-get result :why)))
    (cond
     ((equal status "repeated") (format "Repeated · %s" title))
     ((equal status "queued") (format "Queued · %s" title))
     ((equal status "waiting") (format "Waiting · %s" title))
     ((equal status "forwarded") (format "Forwarded · %s · %s" title delivery))
     ((equal status "stale") (format "Stale · %s" (or why title)))
     ((equal status "unreachable") (format "Unreachable · %s" (or why title)))
     (t (format "%s · %s" (capitalize status) title)))))

(defun harness-ui-workspace--message-at-point ()
  "Return the timeline entry at point, or nil.
An entry is a message, a divider, a brief or a reassignment line; each
carries its own entry, so a command acts on what the person is looking
at rather than on the last message in the buffer."
  (get-text-property (point) 'harness-workspace-entry))

(defun harness-ui-workspace--reassign-target ()
  "Ask for the thread to reassign to, and return its id, or nil.
The threads the workspace holds are offered by title, and a message
cannot be reassigned to the thread it is already in."
  (let* ((threads (plist-get harness-ui-workspace--data :threads))
         (names (mapcar (lambda (thread)
                          (cons (or (plist-get thread :title) "Thread")
                                (plist-get thread :id)))
                        threads))
         (choice (completing-read "Thread: " names nil t)))
    (cdr (assoc choice names))))

(defun harness-ui-workspace-reassign ()
  "Reassign the message at point to another thread.
The message the person is looking at is the one moved: its node id is
sent, so a message is never guessed from its words.  A message nothing
has read yet leaves its queue and is queued in the target's; one the
transcript already holds is forwarded, naming the thread it came from,
and the answer says which happened."
  (interactive)
  (let ((entry (harness-ui-workspace--message-at-point)))
    (unless (and entry (eq (harness-ui-workspace--entry-kind entry) 'message))
      (user-error "No message here"))
    (let* ((node (plist-get entry :node))
           (thread (plist-get entry :thread))
           (target (harness-ui-workspace--reassign-target)))
      (unless target
        (user-error "No thread"))
      (when (equal target thread)
        (user-error "Already in %s" (harness-ui-workspace--thread-title thread)))
      (harness-ui-call
       "_harness/workspace/reassign"
       (list :id harness-ui-workspace--id
             :message (list :node node)
             :to target)
       (lambda (result)
         (message "Reassigned · %s" (harness-ui-workspace--reassign-summary result))
         (harness-ui-workspace-refresh))
       (lambda (err)
         (message "Reassign · %s" (harness-error-message err)))))))


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

(defun harness-ui-workspace--drawn-p (session-id)
  "Non-nil when a workspace buffer draws the requests of SESSION-ID.
The pending module then owns its ACP request, and this view answers it
with the same panels and keys as a chat."
  (cl-some (lambda (buffer)
             (with-current-buffer buffer
               (and (derived-mode-p 'harness-ui-workspace-mode)
                    (equal session-id (harness-ui-workspace--live-session)))))
           (harness-ui-workspace--buffers)))

(defun harness-ui-workspace--set-thread (session-id changes)
  "Merge CHANGES into the thread of SESSION-ID in this buffer's data."
  (when (harness-ui-workspace--episode-of-p session-id)
    (setf (plist-get harness-ui-workspace--data :threads)
          (mapcar (lambda (thread)
                    (if (equal session-id (plist-get thread :live))
                        (harness-plist-merge thread changes)
                      thread))
                  (plist-get harness-ui-workspace--data :threads)))))

(defun harness-ui-workspace--change-thread (thread-id changes)
  "Merge CHANGES into the thread THREAD-ID of this buffer's data."
  (setf (plist-get harness-ui-workspace--data :threads)
        (mapcar (lambda (thread)
                  (if (equal thread-id (plist-get thread :id))
                      (harness-plist-merge thread changes)
                    thread))
                (plist-get harness-ui-workspace--data :threads))))

(defun harness-ui-workspace--on-update (session-id update)
  "Take SESSION-ID's UPDATE into the thread it is an episode of.
An activity change says what a running turn does now, and the thread
and header words follow it at once; a session change carries the model,
thinking level and permission mode the settings line shows."
  (pcase (plist-get update :sessionUpdate)
    ("_harness/activity"
     (let ((activity (plist-get update :activity)))
       (dolist (buffer (harness-ui-workspace--buffers))
         (with-current-buffer buffer
           (when (harness-ui-workspace--episode-of-p session-id)
             (let* ((thread (cl-find session-id (plist-get harness-ui-workspace--data :threads)
                                     :key (lambda (item) (plist-get item :live))
                                     :test #'equal))
                    (old (plist-get thread :activity)))
               (unless (equal old activity)
                 (harness-ui-workspace--set-thread
                  session-id (append (list :activity activity)
                                     (and activity (list :episode-status "running"))))
                 (harness-ui-workspace--render))))))))
    ("_harness/session"
     (let ((session (plist-get update :session)))
       (when (listp session)
         (dolist (buffer (harness-ui-workspace--buffers))
           (with-current-buffer buffer
             (when (harness-ui-workspace--episode-of-p session-id)
               (let* ((thread (cl-find session-id (plist-get harness-ui-workspace--data :threads)
                                       :key (lambda (item) (plist-get item :live))
                                       :test #'equal))
                      (changes (list :model (plist-get session :model)
                                     :thinking (plist-get session :thinking)
                                     :permission-mode (plist-get session :permission-mode)
                                     :non-interactive (plist-get session :non-interactive))))
                 (when (cl-some (lambda (key)
                                  (not (equal (plist-get thread key) (plist-get changes key))))
                                '(:model :thinking :permission-mode :non-interactive))
                   (harness-ui-workspace--set-thread session-id changes)
                   (harness-ui-workspace--render)))))))))))

(defun harness-ui-workspace--on-pending-changed (session-id)
  "Redraw the buffers showing SESSION-ID, whose requests changed."
  (unless harness-ui-workspace--syncing-p
    (dolist (buffer (harness-ui-workspace--buffers))
      (with-current-buffer buffer
        (when (equal session-id (harness-ui-workspace--live-session))
          (harness-ui-workspace--render))))))

(defun harness-ui-workspace--on-event (event args)
  "Refresh the workspace buffers an EVENT with ARGS is about.
A workspace event refetches the view; a session event of a live episode
refetches its status, and its pending list is brought in at once, so
that a request answered elsewhere leaves no stale card."
  (let ((event (if (symbolp event) (symbol-name event) event)))
    (cond
     ((member event '("workspace/changed" "workspace/deleted"
                      "workspace/timeline-appended" "workspace/thread-changed"
                      "workspace/episode-changed" "workspace/knowledge-changed"
                      "workspace/box-status"))
      (let ((id (car-safe args)))
        (dolist (buffer (harness-ui-workspace--buffers))
          (with-current-buffer buffer
            (when (or (null id) (equal id harness-ui-workspace--id))
              (harness-ui-workspace--schedule-fetch))))))
     ((equal event "computers/changed")
      (dolist (buffer (harness-ui-workspace--buffers))
        (with-current-buffer buffer
          (harness-ui-workspace--schedule-fetch))))
     ((equal event "session/pending-changed")
      (pcase-let ((`(,session ,items) args))
        (when (and (stringp session) (listp items))
          (dolist (buffer (harness-ui-workspace--buffers))
            (with-current-buffer buffer
              (when (harness-ui-workspace--episode-of-p session)
                (let ((harness-ui-workspace--syncing-p t))
                  (harness-ui-pending-sync session items))
                ;; A request that still waits blocks the episode; one
                ;; that went does not say the episode is idle, which a
                ;; running turn is not.  The fetch that follows answers.
                (harness-ui-workspace--set-thread
                 session (append
                          (list :pending items)
                          (and items (list :episode-status "blocked"))))
                (when (equal session (harness-ui-workspace--live-session))
                  (harness-ui-workspace--render))
                (harness-ui-workspace--schedule-fetch)))))))
     ((member event '("session/status" "agent/turn-started"
                      "agent/turn-ended" "session/deleted"))
      (pcase-let ((`(,session . ,rest) args))
        (when (stringp session)
          (dolist (buffer (harness-ui-workspace--buffers))
            (with-current-buffer buffer
              (when (harness-ui-workspace--episode-of-p session)
                (when (and (equal event "session/status") (car rest))
                  (harness-ui-workspace--set-thread
                   session (list :episode-status
                                 (format "%s" (car rest)))))
                (harness-ui-workspace--schedule-fetch))))))))))

(defun harness-ui-workspace--on-redraw ()
  "Refresh every workspace buffer after a reload or a reconnect.
What the selected episode waits on is read from the session cache
first, so its cards are there even before the workspace answers."
  (dolist (buffer (harness-ui-workspace--buffers))
    (with-current-buffer buffer
      (when-let* ((session (harness-ui-workspace--live-session)))
        (harness-ui-pending-sync-session session))
      (harness-ui-workspace--render)
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

;;;; Choosing a workspace
;;
;; The list is one round trip, and the harness may take a while to answer
;; it: a process that is still starting, a connection that is still
;; authenticating, a server on another machine.  The command says it is
;; loading before it asks, so the wait is never silent, and it keeps one
;; choice at a time: a second invocation while the first waits joins it
;; instead of opening a second menu.  The wait is the command loop's own
;; (`recursive-edit'), so a redisplay and C-g arrive as they do for any
;; command and no filter waits in a loop; the answer is read by the
;; command that asked, so a menu never opens from a process filter.
;; An answer that comes after the wait was given up, after the frame
;; that asked is gone, or while a minibuffer of the person's own is in
;; use, opens nothing.

(cl-defstruct (harness-ui-workspace--choice
               (:constructor harness-ui-workspace--choice-make)
               (:copier nil))
  id                ; its generation, for the log
  frame             ; the frame it was asked in
  asked             ; when it was asked
  in-wait           ; non-nil while the command waits in a `recursive-edit'
  answered          ; non-nil once the harness answered
  workspaces        ; what the answer holds, when it answered
  error             ; what the harness said instead, when it failed
  timed-out         ; non-nil when the wait ended without an answer
  cancelled)        ; non-nil once the person gave it up

(defvar harness-ui-workspace--choosing nil
  "The choice of workspace in flight, a `harness-ui-workspace--choice', or nil.")

(defvar harness-ui-workspace--choice-generation 0
  "Generation of the last choice of workspace, so a late answer is dropped.")

(defconst harness-ui-workspace--choice-delay 0.2
  "Seconds before the workspace selector says it is still waiting.
The first message shows at once; this one follows when the harness has
not answered yet, so a prompt answer does not flash two messages.")

(defconst harness-ui-workspace--choice-timeout 60
  "Seconds the workspace selector waits for the harness before giving up.")

(defun harness-ui-workspace--choosing-p ()
  "Non-nil while a choice of workspace waits for the harness."
  (and harness-ui-workspace--choosing
       (not (harness-ui-workspace--choice-cancelled harness-ui-workspace--choosing))))

(defun harness-ui-workspace--choice-current-p (choice)
  "Non-nil when CHOICE is still the one the person waits for."
  (eq choice harness-ui-workspace--choosing))

(defun harness-ui-workspace--choice-live-p (choice)
  "Non-nil when CHOICE may still show what it read.
That is false once another choice was asked, once this one was given
up, and once the frame that asked is gone: its menu would open in a
frame the person is no longer looking at."
  (and (harness-ui-workspace--choice-current-p choice)
       (not (harness-ui-workspace--choice-cancelled choice))
       (frame-live-p (harness-ui-workspace--choice-frame choice))))

(defun harness-ui-workspace--choice-answered-p (choice)
  "Non-nil when CHOICE has its answer, a list of workspaces or an error."
  (or (harness-ui-workspace--choice-answered choice)
      (harness-ui-workspace--choice-error choice)))

(defun harness-ui-workspace--choice-stop (choice)
  "Stop waiting on CHOICE, which has its answer or was given up."
  (when (harness-ui-workspace--choice-current-p choice)
    (setq harness-ui-workspace--choosing nil)))

(defun harness-ui-workspace--choice-wake (choice)
  "End the wait of CHOICE, whose answer is in it.
An answer that arrives after the wait ended does nothing here: the
command that asked has already read the choice and moved on."
  (when (harness-ui-workspace--choice-in-wait choice)
    (setf (harness-ui-workspace--choice-in-wait choice) nil)
    (exit-recursive-edit)))

(defun harness-ui-workspace--choice-failed (err)
  "Say in the echo area that the workspace list failed with ERR."
  (if (harness-ui-connection-replaced-p err)
      (message "Workspace selector · connection replaced · try again")
    (message "Workspace selector · %s · try again"
             (harness-error-message err))))

(defun harness-ui-workspace--choice-show (choice position)
  "Show what CHOICE read at POSITION, or say why there is nothing to show.
The caller has decided CHOICE is still the one being asked for."
  (cond
   ((harness-ui-workspace--choice-error choice)
    (harness-ui-workspace--choice-failed (harness-ui-workspace--choice-error choice)))
   ((harness-ui-workspace--choice-timed-out choice)
    (message "Workspace selector · timed out · try again"))
   ((harness-ui-workspace--choice-answered choice)
    (if (active-minibuffer-window)
        ;; A minibuffer of the person's own is in use: a menu here would
        ;; take it from them.
        (message "Workspace selector · cancelled")
      (harness-ui--in-frame
       (harness-ui-workspace--choice-frame choice)
       (lambda ()
         (harness-ui-workspace--read-workspace
          (harness-ui-workspace--choice-workspaces choice) position)))))
   (t nil)))

(defun harness-ui-workspace--read-workspace (workspaces position)
  "Offer WORKSPACES by name and open the one chosen, at POSITION.
A list of one opens it; an empty list creates the first workspace, as
`harness-workspace' always has."
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

(defun harness-ui-workspace--choose (position)
  "Read the workspaces and let the person choose one, at POSITION.
The wait runs in the command loop, so Emacs stays responsive: the
message says what is happening, and \\[keyboard-quit] gives the wait up.
An answer that comes after that, or once the frame that asked is gone,
opens nothing."
  (let* ((choice (harness-ui-workspace--choice-make
                  :id (cl-incf harness-ui-workspace--choice-generation)
                  :frame (selected-frame)
                  :asked (float-time)))
         (slow nil)
         (timeout nil))
    (setq harness-ui-workspace--choosing choice)
    ;; The acknowledgment comes before the request, so a harness that
    ;; never answers is never a silent wait.
    (message "Workspace selector · loading")
    (unwind-protect
        (progn
          (harness-then (harness-ui-request "_harness/workspace/list" nil)
                        (lambda (workspaces)
                          (setf (harness-ui-workspace--choice-answered choice) t)
                          (setf (harness-ui-workspace--choice-workspaces choice) workspaces)
                          (harness-ui-workspace--choice-wake choice))
                        (lambda (err)
                          (setf (harness-ui-workspace--choice-error choice) err)
                          (harness-ui-workspace--choice-wake choice)))
          ;; The in-process harness may answer in the call above, and a
          ;; wait for an answer already here waits for nothing.
          (unless (harness-ui-workspace--choice-answered-p choice)
            (setq slow (run-at-time harness-ui-workspace--choice-delay nil
                                    (lambda ()
                                      (when (harness-ui-workspace--choice-live-p choice)
                                        (message "Workspace selector · waiting")))))
            (setq timeout (run-at-time harness-ui-workspace--choice-timeout nil
                                       (lambda ()
                                         (when (harness-ui-workspace--choice-live-p choice)
                                           (setf (harness-ui-workspace--choice-timed-out choice) t)
                                           (harness-ui-workspace--choice-wake choice)))))
            (setf (harness-ui-workspace--choice-in-wait choice) t)
            ;; Nothing polls here: the command loop runs, so the
            ;; answer's callback, a redisplay and C-g all arrive as they
            ;; normally do.  A quit is the person giving the wait up.
            (condition-case nil (recursive-edit) (quit nil))
            (setf (harness-ui-workspace--choice-in-wait choice) nil)))
      (when (timerp slow) (cancel-timer slow))
      (when (timerp timeout) (cancel-timer timeout)))
    (cond
     ;; Another choice took over while this one waited: what the harness
     ;; said is not the answer to the question being asked now.
     ((not (harness-ui-workspace--choice-current-p choice)) nil)
     ((and (harness-ui-workspace--choice-answered-p choice)
           (frame-live-p (harness-ui-workspace--choice-frame choice)))
      (harness-ui-workspace--choice-stop choice)
      (harness-ui-workspace--choice-show choice position))
     ((harness-ui-workspace--choice-answered-p choice)
      ;; The frame that asked is gone: its menu would open where the
      ;; person is no longer looking.
      (harness-ui-workspace--choice-stop choice))
     ((harness-ui-workspace--choice-timed-out choice)
      ;; The timer said so already, and says to try again.
      (harness-ui-workspace--choice-stop choice)
      (harness-ui-workspace--choice-show choice position))
     (t
      ;; The wait ended with no answer and no timeout: C-g, which is no
      ;; failure, and opens nothing when the answer finally comes.
      (setf (harness-ui-workspace--choice-cancelled choice) t)
      (harness-ui-workspace--choice-stop choice)
      (message "Workspace selector · cancelled")))))

;;;###autoload
(defun harness-workspace (&optional position new)
  "Open the persistent workspace chat at POSITION.
With a prefix argument NEW, create a workspace first: ask for its name
and root.  With more than one workspace, choose one by name.
The list is read asynchronously, and the command says so at once, so a
harness that is slow to answer is never a silent wait;
\\[keyboard-quit] stops waiting, and no menu opens afterwards."
  (interactive (list (and current-prefix-arg (harness-ui-read-position))
                     current-prefix-arg))
  (if new
      (let ((name (string-trim (read-string "Workspace name: " "Home")))
            (root (read-directory-name "Workspace root: " nil nil t)))
        (harness-ui-workspace--create (if (string-blank-p name) "Home" name) root position))
    (if (harness-ui-workspace--choosing-p)
        ;; A second invocation joins the choice that waits: two menus
        ;; over one list would answer the same question twice.
        (message "Workspace selector · loading")
      (harness-ui-workspace--choose position))))

(defun harness-ui-workspace-tool-open (root &optional thread workspace)
  "Show a workspace of ROOT in its buffer with THREAD selected.
This is the fixed view a tool opens, so it never asks: ROOT names the
project, WORKSPACE the workspace to show there, and THREAD the thread a
person asked for.  Nothing is created or started; a thread this
workspace does not hold leaves the one it was showing."
  (harness-then
   (harness-ui-request "_harness/workspace/list" nil)
   (lambda (workspaces)
     (let* ((root (file-name-as-directory
                   (expand-file-name (or root default-directory))))
            (mine (cl-remove-if-not
                   (lambda (entry)
                     (let ((entry-root (plist-get entry :root)))
                       (and (stringp entry-root)
                            (equal root (file-name-as-directory
                                         (expand-file-name entry-root))))))
                   workspaces))
            (chosen (or (and workspace
                             (cl-find workspace mine
                                      :key (lambda (entry) (plist-get entry :id))
                                      :test #'equal))
                        (car mine))))
       (unless chosen
         (user-error "No workspace at %s" root))
       (let ((buffer (harness-ui-workspace--open chosen)))
         (when (and thread (harness-ui-workspace--thread-title thread))
           (harness-ui-workspace--select-thread thread))
         buffer)))))

(defun harness-ui-workspace--kill ()
  "Stop the timer of a workspace buffer that is going away."
  (when (timerp harness-ui-workspace--fetch-timer)
    (cancel-timer harness-ui-workspace--fetch-timer)
    (setq harness-ui-workspace--fetch-timer nil)))

;;;; Inbox

;; A workspace runs several threads, and each thread's episode has a
;; queue of messages its turn has not read yet.  The inbox shows those
;; where they stand -- the session's own queue and steering list -- so
;; sending, withdrawing or answering one elsewhere is seen here at once
;; and nothing is copied into a second queue.  A session that cannot be
;; read says so: an empty inbox and an unreadable one are different
;; facts, and a person acting on the first would miss the second.

(defconst harness-ui-inbox--scopes
  '(("workspace" "Workspace" "Every thread of this workspace")
    ("thread" "Thread" "The thread in view")
    ("session" "Session" "The episode of the thread in view")
    ("all" "All" "Every workspace"))
  "The scopes the inbox reads: each scope, the word naming it, and its help.
The help is a noun phrase naming what the scope covers, so the button
says which messages pressing it would show.")

(defvar-local harness-ui-inbox--id nil
  "Workspace id of this inbox buffer.")

(defvar-local harness-ui-inbox--scope "workspace"
  "The scope this inbox buffer reads.")

(defvar-local harness-ui-inbox--inbox nil
  "The inbox this buffer shows, as `workspace/inbox' answered it.")

(defvar-local harness-ui-inbox--state nil
  "One of `loading', `ready' or `error'.")

(defvar-local harness-ui-inbox--error nil
  "The last error this buffer met.")

(defvar-local harness-ui-inbox--request nil
  "The generation of the last fetch, so a late answer is dropped.")

(defvar harness-ui-inbox-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'harness-ui-inbox-refresh)
    (define-key map (kbd "s") #'harness-ui-inbox-scope)
    (define-key map (kbd "TAB") #'forward-button)
    (define-key map (kbd "q") #'harness-ui-bury)
    map)
  "Keys of the inbox buffer.")

(defun harness-ui-inbox--state-label (state)
  "Return the word for an item in STATE, a word the harness used."
  (pcase state
    ("queued" "Queued")
    ("waiting" "Waiting")
    ("unavailable" "Unavailable")
    ((or 'nil "") "Unavailable")
    (_ (capitalize (format "%s" state)))))

(defun harness-ui-inbox--state-face (state)
  "Return the face of an item in STATE."
  (pcase state
    ("queued" 'harness-dim-face)
    ("waiting" 'harness-caution-face)
    (_ 'harness-failure-face)))

(defun harness-ui-inbox--counts (inbox)
  "Return the words naming how many INBOX items are in each state."
  (let* ((counts (plist-get inbox :counts))
         (queued (or (plist-get counts :queued) 0))
         (waiting (or (plist-get counts :waiting) 0))
         (unavailable (or (plist-get counts :unavailable) 0)))
    (string-join
     (cl-remove-if #'string-empty-p
                   (list (if (> queued 0) (format "%d queued" queued) "")
                         (if (> waiting 0) (format "%d waiting" waiting) "")
                         (if (> unavailable 0) (format "%d unavailable" unavailable) "")))
     " · ")))

(defun harness-ui-inbox--scope-label (scope)
  "Return the word naming SCOPE, defaulting to the workspace scope."
  (or (nth 1 (assoc scope harness-ui-inbox--scopes))
      (nth 1 (assoc "workspace" harness-ui-inbox--scopes))))

(defun harness-ui-inbox--insert-header ()
  "Insert the header line of the inbox."
  (insert (propertize "Inbox" 'face 'harness-header-face))
  (let ((name (and harness-ui-inbox--inbox
                   (or (plist-get harness-ui-inbox--inbox :name)
                       (plist-get harness-ui-inbox--inbox :workspace)
                       harness-ui-inbox--id))))
    (when name
      (insert " · " (propertize name 'face 'harness-header-face))))
  (insert "   " (propertize "Scope · " 'face 'harness-dim-face)
          (propertize (harness-ui-inbox--scope-label harness-ui-inbox--scope)
                      'face 'harness-dim-face))
  (let ((counts (and harness-ui-inbox--inbox
                     (harness-ui-inbox--counts harness-ui-inbox--inbox))))
    (when (and counts (not (string-empty-p counts)))
      (insert "   " (propertize counts 'face 'harness-dim-face))))
  (insert "   ")
  (harness-ui-button "Refresh" #'harness-ui-inbox-refresh
                    :help "Read the inbox again")
  (insert " ")
  (harness-ui-button "Scope" #'harness-ui-inbox-scope
                    :help "Choose what the inbox covers")
  (insert "\n"))

(defun harness-ui-inbox--insert-scopes ()
  "Insert the scope buttons."
  (dolist (entry harness-ui-inbox--scopes)
    (let ((scope (nth 0 entry)) (label (nth 1 entry)) (help (nth 2 entry)))
      (insert-text-button
       label
       'action (lambda (_button) (harness-ui-inbox--set-scope scope))
       'follow-link t
       'face (if (equal scope harness-ui-inbox--scope)
                 'harness-user-label-face 'harness-dim-face)
       'help-echo help)
      (insert "  ")))
  (insert "\n"))

(defun harness-ui-inbox--insert-item (item)
  "Insert one ITEM of the inbox: its thread, its words and its state.
A row whose workspace is not the one this buffer shows names it too, so
the \"all\" scope says which workspace each message waits in; a row of
this workspace leaves that out, because the header already says it."
  (let* ((thread (or (plist-get item :title) "Thread"))
         (state (plist-get item :state))
         (text (or (plist-get item :text) ""))
         (why (plist-get item :why))
         (session (plist-get item :session))
         (workspace (plist-get item :workspace))
         (mine (or (plist-get harness-ui-inbox--inbox :workspace)
                   harness-ui-inbox--id))
         (elsewhere (and (stringp workspace)
                         (not (string-empty-p workspace))
                         (not (equal workspace mine))
                         (plist-get item :workspace-name))))
    (when elsewhere
      (insert (propertize (format "%s · " elsewhere) 'face 'harness-dim-face)))
    (insert (propertize thread 'face 'harness-label-face)
            "  "
            (propertize (harness-ui-inbox--state-label state)
                        'face (harness-ui-inbox--state-face state)))
    (when (and (stringp session) (not (string-empty-p session)))
      (insert "  " (propertize session 'face 'harness-dim-face)))
    (insert "\n")
    (if (equal state "unavailable")
        (insert (propertize (or why "Session unavailable") 'face 'harness-failure-face) "\n")
      (when (not (string-blank-p text))
        (insert (propertize text 'face 'default) "\n")))
    (insert "\n")))

(defun harness-ui-inbox--render ()
  "Draw the inbox buffer."
  (when (derived-mode-p 'harness-ui-inbox-mode)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (pcase harness-ui-inbox--state
        ('loading
         (insert (propertize "Inbox · loading" 'face 'harness-header-face) "\n\n"
                 (propertize "Loading…" 'face 'harness-dim-face) "\n"))
        ('error
         (insert (propertize "Inbox · unavailable" 'face 'harness-header-face) "\n\n"
                 (propertize (or harness-ui-inbox--error "Inbox unavailable")
                             'face 'harness-failure-face)
                 "\n\n")
         (harness-ui-button "Retry" #'harness-ui-inbox-refresh))
        (_
         (harness-ui-inbox--insert-header)
         (insert "\n")
         (harness-ui-inbox--insert-scopes)
         (insert "\n")
         (let ((items (plist-get harness-ui-inbox--inbox :items)))
           (if (null items)
               (insert (propertize "No messages waiting" 'face 'harness-dim-face) "\n")
             (dolist (item items)
               (harness-ui-inbox--insert-item item))))))
      (set-buffer-modified-p nil))))

(defun harness-ui-inbox--set-scope (scope)
  "Read the inbox in SCOPE and draw it."
  (setq harness-ui-inbox--scope scope)
  (harness-ui-inbox-refresh))

(defun harness-ui-inbox-scope ()
  "Choose what the inbox covers."
  (interactive)
  (let* ((names (mapcar (lambda (entry) (cons (nth 1 entry) (nth 0 entry)))
                        harness-ui-inbox--scopes))
         (choice (completing-read "Inbox scope: " names nil t))
         (scope (cdr (assoc choice names))))
    (when scope (harness-ui-inbox--set-scope scope))))

(defun harness-ui-inbox--fetch ()
  "Read the inbox from the harness and draw it."
  (when (and (derived-mode-p 'harness-ui-inbox-mode) harness-ui-inbox--id)
    (let* ((buffer (current-buffer))
           (id harness-ui-inbox--id)
           (scope harness-ui-inbox--scope)
           (generation (1+ (or harness-ui-inbox--request 0)))
           (params (append (list :id id)
                           (list :opts (list :scope scope)))))
      (setq harness-ui-inbox--request generation
            harness-ui-inbox--state 'loading
            harness-ui-inbox--error nil)
      (harness-ui-inbox--render)
      (harness-then
       (harness-ui-request "_harness/workspace/inbox" params)
       (lambda (inbox)
         (when (and (buffer-live-p buffer)
                    (= generation (buffer-local-value 'harness-ui-inbox--request buffer)))
           (with-current-buffer buffer
             (setq harness-ui-inbox--inbox inbox
                   harness-ui-inbox--state 'ready
                   harness-ui-inbox--error nil)
             (harness-ui-inbox--render))))
       (lambda (err)
         (when (and (buffer-live-p buffer)
                    (= generation (buffer-local-value 'harness-ui-inbox--request buffer)))
           (with-current-buffer buffer
             (setq harness-ui-inbox--state 'error
                   harness-ui-inbox--error (harness-error-message err))
             (harness-ui-inbox--render))))))))

(defun harness-ui-inbox-refresh ()
  "Read the inbox again."
  (interactive)
  (harness-ui-inbox--fetch))

(define-derived-mode harness-ui-inbox-mode special-mode "Inbox"
  "Major mode of the workspace inbox.
The inbox shows the messages waiting in each thread's own queue, where
they stand, so a person sees what has not been sent yet.
\\<harness-ui-inbox-mode-map>\\[harness-ui-inbox-refresh] reads it again;
\\[harness-ui-inbox-scope] chooses what it covers."
  (setq buffer-read-only nil)
  (setq-local truncate-lines nil
              word-wrap t)
  (harness-ui-view-install #'harness-ui-inbox-refresh))

;;;###autoload
(defun harness-workspace-inbox (&optional workspace)
  "Open the inbox of WORKSPACE, or of the workspace this buffer shows."
  (interactive)
  (let ((id (or workspace harness-ui-workspace--id)))
    (unless id
      (user-error "No workspace"))
    (let ((buffer (get-buffer-create "*Inbox*")))
      (with-current-buffer buffer
        (unless (derived-mode-p 'harness-ui-inbox-mode)
          (harness-ui-inbox-mode))
        (setq harness-ui-inbox--id id)
        (harness-ui-inbox--fetch))
      (pop-to-buffer buffer))))



(define-derived-mode harness-ui-workspace-mode special-mode "Workspace"
  "Major mode of the persistent workspace chat.
The header shows the workspace, the thread, what its turn does now and
the knowledge state; the thread list selects a topic; the timeline is
the one chat; the settings line under the box shows the model, thinking
level, permission mode and the workspace's defaults.  Letters type in
the compose box.
\<harness-ui-workspace-mode-map>\[harness-ui-workspace-send] sends;
the `C-c w' keys act on the workspace, and \[harness-workspace-speech]
opens the speech panel beside it."
  (setq buffer-read-only nil)
  (setq-local truncate-lines nil
              word-wrap t
              truncate-partial-width-windows nil
              ;; A setting clicked here changes the selected thread's live
              ;; episode, or the workspace defaults when it has none.
              harness-ui-setting-target-function #'harness-ui-workspace--setting-target
              ;; [Send answer] on a question that allows several options
              ;; sends this box, as the chat's sends its own.
              harness-ui-pending-send-function #'harness-ui-workspace-send)
  (harness-compose-setup
   ;; Before the first answer from the harness there is no workspace plist:
   ;; the box still completes and attaches from the buffer's directory,
   ;; which `harness-ui-workspace--open' set to the workspace root.
   :project (lambda () (or (plist-get harness-ui-workspace--data :root)
                           default-directory))
   :placeholder (lambda () "Message…")
   :redraw #'harness-ui-workspace--render-tail
   ;; The box composes into the selected thread, asked each time: a
   ;; thread switch moves where the words go, and a new workspace's first
   ;; message has a thread to create rather than one to name.
   :context #'harness-ui-workspace--compose-context
   :bottom t)
  (add-hook 'kill-buffer-hook #'harness-ui-workspace--kill nil t)
  (harness-ui-view-install #'harness-ui-workspace-refresh))

(put 'harness-ui-workspace-mode 'harness-menu-group
     '("Workspace"
       ["Workspace"
        ("C-c w n" "New thread" harness-ui-workspace-new-thread)
        ("C-c w i" "Inbox" harness-workspace-inbox)
        ("C-c w r" "Reassign" harness-ui-workspace-reassign)
        ("C-c w o" "Episode" harness-ui-workspace-open-episode)
        ("C-c w c" "Computer" harness-ui-workspace-computer)
        ("C-c w b" "Task board" harness-ui-workspace-open-board)
        ("C-c w s" "Stop" harness-ui-workspace-stop)
        ("C-c w g" "Refresh" harness-ui-workspace-refresh)
        ("C-c w v" "Speech" harness-workspace-speech)
        ("C-c w R" "Resources" harness-ui-workspace-resources)
        ("C-c w q" "Previous buffer" harness-ui-bury)
        ("C-c C-c" "Send" harness-ui-workspace-send)
        ("C-c C-k" "Reset" harness-ui-workspace-clear)]))

(defun harness-ui-workspace--init ()
  "Add the workspace mode to the harness UI."
  (add-hook 'harness-ui-event-functions #'harness-ui-workspace--on-event)
  (add-hook 'harness-ui-update-functions #'harness-ui-workspace--on-update)
  (add-hook 'harness-ui-redraw-hook #'harness-ui-workspace--on-redraw)
  (add-hook 'harness-ui-connected-hook #'harness-ui-workspace--on-redraw)
  (add-hook 'harness-ui-pending-drawn-predicates #'harness-ui-workspace--drawn-p)
  (add-hook 'harness-ui-pending-changed-hook #'harness-ui-workspace--on-pending-changed)
  (harness-ui-bind "Y" #'harness-workspace "Workspace" :group 'views :column "Views"))

(defun harness-ui-workspace--shutdown ()
  "Remove the workspace mode from the harness UI."
  (remove-hook 'harness-ui-event-functions #'harness-ui-workspace--on-event)
  (remove-hook 'harness-ui-update-functions #'harness-ui-workspace--on-update)
  (remove-hook 'harness-ui-redraw-hook #'harness-ui-workspace--on-redraw)
  (remove-hook 'harness-ui-connected-hook #'harness-ui-workspace--on-redraw)
  (remove-hook 'harness-ui-pending-drawn-predicates #'harness-ui-workspace--drawn-p)
  (remove-hook 'harness-ui-pending-changed-hook #'harness-ui-workspace--on-pending-changed)
  (harness-ui-unbind "Y" harness-ui-views-map))

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
;; inserted in this buffer.  A running box gives a real Firefox profile;
;; a stopped one says why.  The payment broker is still absent, so the
;; wallet says so; the credentials are the harness's declared secrets,
;; through the secret-sandbox module.

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
      (insert "  " (propertize (or (plist-get (plist-get harness-ui-workspace-resources--data
                                                       :browser-reason)
                                               :code)
                                    "Computer off")
                               'face 'harness-dim-face)
              "  ·  " (propertize "No browser data" 'face 'harness-dim-face) "\n")
    (let ((profile (plist-get browser :profile)))
      (harness-ui-workspace-resources--line
       (format "Profile · %s" (or (plist-get profile :label) "default"))
       (format "%s · %s sites"
               (or (plist-get profile :kind) "Firefox")
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
                   (if-let* ((username (plist-get login :username))
                             ((not (harness-string-blank-p username))))
                       username
                     "site session")
                   (or (plist-get login :state) "unknown")))))
      (insert "  " (propertize "Export / Import · later stage"
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
      (user-error "No workspace open"))
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

;;;; Workspace graph

;; The Logseq graph behind a thread: the page the thread writes, the
;; nodes on it -- the turns and the notes -- the pages they link to and
;; the nodes that link back.  It is read-only, and it explores: RET
;; follows a node or a page, `b' comes back, `g' reads it again.

(defvar harness-ui-workspace-graph--last-id nil
  "The workspace the graph buffer opened last.")

(defvar-local harness-ui-workspace-graph--id nil
  "Workspace id of this graph buffer.")

(defvar-local harness-ui-workspace-graph--name nil
  "Name of the workspace this graph buffer shows.")

(defvar-local harness-ui-workspace-graph--thread nil
  "Thread this graph buffer opened with, or nil for the workspace's last.")

(defvar-local harness-ui-workspace-graph--view nil
  "What this graph buffer shows.
That is (:kind thread), (:kind node :id ID) or (:kind page :name NAME).")

(defvar-local harness-ui-workspace-graph--data nil
  "The answer of the last graph request this buffer drew.")

(defvar-local harness-ui-workspace-graph--stack nil
  "The views before this one, newest first.")

(defvar-local harness-ui-workspace-graph--loading nil
  "Whether a graph request is on its way.")

(defvar-local harness-ui-workspace-graph--error nil
  "Why the last graph request failed, or nil.")

(defvar harness-ui-workspace-graph-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'harness-ui-workspace-graph-refresh)
    (define-key map (kbd "RET") #'harness-ui-workspace-graph-open)
    (define-key map (kbd "b") #'harness-ui-workspace-graph-back)
    (define-key map (kbd "q") #'harness-ui-bury)
    map)
  "Keys of the graph buffer.")

(define-derived-mode harness-ui-workspace-graph-mode special-mode "Workspace Graph"
  "Major mode of a thread's Logseq graph.
It is read-only: the thread's page, its nodes with their role, time,
tags, links and properties, and the nodes that link to it.  A node's
id or a linked page at point opens with \\[harness-ui-workspace-graph-open],
\\[harness-ui-workspace-graph-back] returns to the view before it, and
\\[harness-ui-workspace-graph-refresh] reads the graph again."
  (setq buffer-read-only t)
  (setq-local truncate-lines nil
              word-wrap t))

(defun harness-ui-workspace-graph--heading (text)
  "Insert TEXT as a section heading, after one blank line."
  (unless (or (bobp) (looking-back "\n\n" 2 t))
    (insert "\n"))
  (insert (propertize text 'face 'harness-label-face) "\n"))

(defun harness-ui-workspace-graph--line (label value &optional face)
  "Insert LABEL and VALUE on one line, VALUE with FACE."
  (insert "  " (propertize label 'face 'harness-dim-face) "  "
          (propertize (format "%s" (or value "")) 'face (or face 'default))
          "\n"))

(defun harness-ui-workspace-graph--pair (entry)
  "Return ENTRY, a property, as (NAME . VALUE).
The bus gives a property as a cons; a client over ACP reads it as a
two-element list, because JSON has no pair."
  (if (and (consp entry) (consp (cdr entry)) (stringp (car entry)))
      (cons (car entry) (cadr entry))
    entry))

(defun harness-ui-workspace-graph--pairs (properties)
  "Return PROPERTIES as (NAME . VALUE) conses, whichever shape they come in."
  (mapcar #'harness-ui-workspace-graph--pair properties))

(defun harness-ui-workspace-graph--role (block)
  "Return BLOCK's role as the word the graph shows."
  (let ((role (cdr (assoc "role"
                          (harness-ui-workspace-graph--pairs
                           (plist-get block :properties))))))
    ;; A value the graph gives as several is read by its first title.
    (when (listp role)
      (setq role (car role)))
    (pcase (downcase (format "%s" role))
      ((or "user" "you") "You")
      ((or "assistant" "agent") "Agent")
      ((or "note" "memory") "Note")
      ;; A block on a thread's page is durable knowledge, not a turn.
      (_ (if (assoc "thread" (harness-ui-workspace-graph--pairs
                              (plist-get block :properties)))
             "Note"
           "Block")))))

(defun harness-ui-workspace-graph--role-face (block)
  "Return the face of BLOCK's role."
  (pcase (harness-ui-workspace-graph--role block)
    ("You" 'harness-user-label-face)
    ("Agent" 'harness-agent-label-face)
    (_ 'harness-label-face)))

(defun harness-ui-workspace-graph--time (block)
  "Return BLOCK's creation time as a short local time, or nil."
  (let ((created (plist-get block :created)))
    (when (numberp created)
      (format-time-string "%Y-%m-%d %H:%M" (seconds-to-time (/ created 1000.0))))))

(defun harness-ui-workspace-graph--target-button (label target &optional help)
  "Insert LABEL as a button that opens TARGET, with HELP as its tooltip."
  (let ((start (point)))
    (harness-ui-button label (lambda () (harness-ui-workspace-graph--follow target))
                       :face 'link :help help)
    (put-text-property start (point) 'harness-graph-target target)))

(defun harness-ui-workspace-graph--properties-lines (properties)
  "Insert PROPERTIES, one per line, under the Properties label."
  (when properties
    (insert "  " (propertize "Properties" 'face 'harness-dim-face) "\n")
    (dolist (pair properties)
      (insert "    " (propertize (format "%s" (car pair)) 'face 'harness-dim-face)
              "  " (propertize (format "%s" (cdr pair)) 'face 'default)
              "\n"))))

(defun harness-ui-workspace-graph--properties (block)
  "Insert BLOCK's properties, but its role."
  (harness-ui-workspace-graph--properties-lines
   (cl-remove-if (lambda (pair) (equal (car pair) "role"))
                 (harness-ui-workspace-graph--pairs
                  (plist-get block :properties)))))

(defun harness-ui-workspace-graph--page-buttons (links)
  "Insert LINKS as page buttons on the line, and end the line."
  (let ((first t))
    (dolist (link links)
      (unless first (insert "  "))
      (setq first nil)
      (harness-ui-workspace-graph--target-button
       link (list :kind 'page :name link) "The page in the graph")))
  (insert "\n"))

(defun harness-ui-workspace-graph--node (block)
  "Insert BLOCK as a node of the page, clickable by its id."
  (let* ((target (list :kind 'node :id (plist-get block :id)))
         (time (harness-ui-workspace-graph--time block))
         (start (point)))
    (harness-ui-workspace-graph--target-button
     (harness-ui-workspace-graph--role block) target
     "The node in the graph")
    (add-face-text-property start (point) (harness-ui-workspace-graph--role-face block))
    (when time
      (insert " · " (propertize time 'face 'harness-dim-face)))
    (insert "\n  "
            (replace-regexp-in-string "\n" "\n  "
                                      (or (plist-get block :text) ""))
            "\n")
    (let ((tags (plist-get block :tags)))
      (when tags
        (insert "  " (propertize "Tags" 'face 'harness-dim-face) "  "
                (mapconcat #'identity tags ", ") "\n")))
    (let ((links (plist-get block :links)))
      (when links
        (insert "  " (propertize "Links" 'face 'harness-dim-face) "  ")
        (harness-ui-workspace-graph--page-buttons links)))
    (harness-ui-workspace-graph--properties block)))

(defun harness-ui-workspace-graph--nodes (blocks)
  "Insert BLOCKS as the nodes of a page."
  (if (null blocks)
      (insert "  " (propertize "No nodes" 'face 'harness-dim-face) "\n")
    (let ((first t))
      (dolist (block blocks)
        (unless first (insert "\n"))
        (setq first nil)
        (harness-ui-workspace-graph--node block)))))

(defun harness-ui-workspace-graph--backlink (block)
  "Insert BLOCK as a node that links to the page."
  (let ((page (plist-get block :page)))
    (insert "  ")
    (when page
      (harness-ui-workspace-graph--target-button
       page (list :kind 'page :name page) "The page in the graph")
      (insert "  "))
    (insert (propertize (or (plist-get block :text) "") 'face 'default) "\n")))

(defun harness-ui-workspace-graph--backlinks (blocks)
  "Insert BLOCKS as the nodes that link to the page."
  (if (null blocks)
      (insert "  " (propertize "No backlinks" 'face 'harness-dim-face) "\n")
    (dolist (block blocks)
      (harness-ui-workspace-graph--backlink block))))

(defun harness-ui-workspace-graph--status (data)
  "Return DATA's status as the header says it."
  (pcase (plist-get data :status)
    ("ready" "ready")
    ("missing" "not found")
    ("unavailable" "unavailable")
    ("error" "error")
    (_ "loading")))

(defun harness-ui-workspace-graph--refresh-button ()
  "Insert the header's Refresh button."
  (harness-ui-button "Refresh" #'harness-ui-workspace-graph-refresh
                     :help "Read the graph again"))

(defun harness-ui-workspace-graph--header ()
  "Insert the header of the graph buffer."
  (let* ((data harness-ui-workspace-graph--data)
         (view harness-ui-workspace-graph--view)
         (kind (plist-get view :kind))
         (thread (or (plist-get data :thread) harness-ui-workspace-graph--thread))
         (what (pcase kind
                 ('node (format "Node · %s" (plist-get view :id)))
                 ('page (format "Page · %s" (plist-get view :name)))
                 (_ (format "Thread · %s" (or thread "All threads")))))
         (status (harness-ui-workspace-graph--status data)))
    (insert (propertize "Graph" 'face 'harness-header-face)
            " · " (propertize (or harness-ui-workspace-graph--name "Workspace")
                              'face 'harness-header-face)
            "   " (propertize what 'face 'harness-dim-face)
            "   " (propertize (format "Logseq · %s" status) 'face 'harness-dim-face)
            "   ")
    (harness-ui-workspace-graph--refresh-button)
    (insert " ")
    (when harness-ui-workspace-graph--stack
      (harness-ui-button "Back" #'harness-ui-workspace-graph-back
                         :help "go back to the node or page before this one")
      (insert " "))
    (harness-ui-button "Workspace" #'harness-ui-workspace-graph-workspace
                       :help "open the workspace chat")
    (insert "\n")))


(defun harness-ui-workspace-graph--record (page &optional title)
  "Insert PAGE's TITLE, tags, links and properties."
  (when page
    (when title
      (harness-ui-workspace-graph--line "Title" (plist-get page :title)))
    (when (plist-get page :tags)
      (harness-ui-workspace-graph--line "Tags"
                                        (mapconcat #'identity (plist-get page :tags) ", ")))
    (harness-ui-workspace-graph--properties-lines
     (harness-ui-workspace-graph--pairs (plist-get page :properties)))
    (when (plist-get page :links)
      (insert "  " (propertize "Links" 'face 'harness-dim-face) "  ")
      (harness-ui-workspace-graph--page-buttons (plist-get page :links)))))

(defun harness-ui-workspace-graph--render-thread ()
  "Insert the thread's page, nodes and backlinks."
  (let ((data harness-ui-workspace-graph--data))
    (harness-ui-workspace-graph--heading "Page")
    (if (equal "ready" (plist-get data :status))
        (progn
          (harness-ui-workspace-graph--line "Name" (plist-get data :page-name))
          (harness-ui-workspace-graph--line "Nodes" (format "%s" (or (plist-get data :count) 0)))
          (harness-ui-workspace-graph--record (plist-get data :page))
          (harness-ui-workspace-graph--heading "Nodes")
          (harness-ui-workspace-graph--nodes (plist-get data :blocks))
          (harness-ui-workspace-graph--heading "Backlinks")
          (harness-ui-workspace-graph--backlinks (plist-get data :backlinks)))
      (insert "  " (propertize (if (equal "missing" (plist-get data :status))
                                    "No page" "No graph")
                                'face 'harness-dim-face)
              "\n")
      (when (plist-get data :why)
        (insert "  " (propertize (format "%s" (plist-get data :why))
                                 'face 'harness-dim-face)
                "\n")))))

(defun harness-ui-workspace-graph--render-node ()
  "Insert one node, its children and the pages it links to."
  (let* ((data harness-ui-workspace-graph--data)
         (block (plist-get data :block)))
    (harness-ui-workspace-graph--heading "Node")
    (if (null block)
        (insert "  " (propertize "No node" 'face 'harness-dim-face) "\n")
      (harness-ui-workspace-graph--line "Role" (harness-ui-workspace-graph--role block))
      (harness-ui-workspace-graph--line "Time" (harness-ui-workspace-graph--time block))
      (harness-ui-workspace-graph--line "Text" (plist-get block :text))
      (when (plist-get block :page)
        (insert "  " (propertize "Page" 'face 'harness-dim-face) "  ")
        (harness-ui-workspace-graph--target-button
         (plist-get block :page)
         (list :kind 'page :name (plist-get block :page))
         "The page in the graph")
        (insert "\n"))
      (let ((tags (plist-get block :tags)))
        (when tags
          (harness-ui-workspace-graph--line "Tags" (mapconcat #'identity tags ", "))))
      (let ((links (plist-get block :links)))
        (when links
          (insert "  " (propertize "Links" 'face 'harness-dim-face) "  ")
          (harness-ui-workspace-graph--page-buttons links)))
      (harness-ui-workspace-graph--properties block)
      (harness-ui-workspace-graph--heading "Children")
      (harness-ui-workspace-graph--nodes (plist-get data :children)))))

(defun harness-ui-workspace-graph--render-page ()
  "Insert a page, its nodes and the nodes that link to it."
  (let ((data harness-ui-workspace-graph--data))
    (harness-ui-workspace-graph--heading "Page")
    (if (or (null (plist-get data :page))
            (equal "missing" (plist-get data :status)))
        (insert "  " (propertize "No page" 'face 'harness-dim-face) "\n")
      (harness-ui-workspace-graph--line "Name" (or (plist-get data :name)
                                                  (plist-get data :page-name)))
      (harness-ui-workspace-graph--record (plist-get data :page) t))
    (harness-ui-workspace-graph--heading "Nodes")
    (harness-ui-workspace-graph--nodes (plist-get data :blocks))
    (harness-ui-workspace-graph--heading "Backlinks")
    (harness-ui-workspace-graph--backlinks (plist-get data :backlinks))))

(defun harness-ui-workspace-graph--hints ()
  "Insert the keys every view of the graph buffer offers."
  (let ((hints '("g · refresh" "RET · open")))
    (when harness-ui-workspace-graph--stack
      (setq hints (append hints '("b · back"))))
    (setq hints (append hints '("q · bury")))
    (insert "\n"
            (mapconcat (lambda (hint) (propertize hint 'face 'harness-hint-face))
                       hints "   ")
            "\n")))

(defun harness-ui-workspace-graph--render ()
  "Draw the graph buffer."
  (when (derived-mode-p 'harness-ui-workspace-graph-mode)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (harness-ui-workspace-graph--header)
      (when harness-ui-workspace-graph--error
        (insert "\n" (propertize harness-ui-workspace-graph--error
                                 'face 'harness-caution-face)
                "\n"))
      (when harness-ui-workspace-graph--loading
        (insert "\n" (propertize "Loading…" 'face 'harness-dim-face) "\n"))
      (pcase (plist-get harness-ui-workspace-graph--view :kind)
        ('node (harness-ui-workspace-graph--render-node))
        ('page (harness-ui-workspace-graph--render-page))
        (_ (harness-ui-workspace-graph--render-thread)))
      (harness-ui-workspace-graph--hints)
      (goto-char (point-min)))))

(defun harness-ui-workspace-graph--request (view)
  "Return the (METHOD . PARAMS) that reads VIEW."
  (pcase (plist-get view :kind)
    ('node (cons "_harness/knowledge/graph/node"
                 (list :workspace harness-ui-workspace-graph--id
                       :node (plist-get view :id)
                       :opts (list :thread harness-ui-workspace-graph--thread))))
    ('page (cons "_harness/knowledge/graph/page"
                 (list :workspace harness-ui-workspace-graph--id
                       :name (plist-get view :name))))
    (_ (cons "_harness/knowledge/graph"
             (list :workspace harness-ui-workspace-graph--id
                   :opts (list :thread harness-ui-workspace-graph--thread))))))

(defun harness-ui-workspace-graph--fetch ()
  "Read what this buffer shows from the harness and draw it."
  (when (and (derived-mode-p 'harness-ui-workspace-graph-mode)
             harness-ui-workspace-graph--id)
    (let* ((buffer (current-buffer))
           (request (harness-ui-workspace-graph--request harness-ui-workspace-graph--view)))
      (setq harness-ui-workspace-graph--loading t
            harness-ui-workspace-graph--error nil)
      (harness-ui-workspace-graph--render)
      (harness-ui-call
       (car request) (cdr request)
       (lambda (result)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (when (derived-mode-p 'harness-ui-workspace-graph-mode)
               (setq harness-ui-workspace-graph--data result
                     harness-ui-workspace-graph--name
                     (or (plist-get result :workspace-name)
                         harness-ui-workspace-graph--name)
                     harness-ui-workspace-graph--loading nil)
               (harness-ui-workspace-graph--render)))))
       (lambda (error)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (when (derived-mode-p 'harness-ui-workspace-graph-mode)
               (setq harness-ui-workspace-graph--loading nil
                     harness-ui-workspace-graph--error (harness-error-message error))
               (harness-ui-workspace-graph--render)))))))))

(defun harness-ui-workspace-graph--follow (target)
  "Show TARGET, a node or a page, keeping the view before it."
  (when target
    (push harness-ui-workspace-graph--view harness-ui-workspace-graph--stack)
    (setq harness-ui-workspace-graph--view target
          harness-ui-workspace-graph--data nil)
    (harness-ui-workspace-graph--fetch)))

(defun harness-ui-workspace-graph-open ()
  "Open the node or page at point."
  (interactive)
  (let ((target (or (get-text-property (point) 'harness-graph-target)
                    (and (> (point) (point-min))
                         (get-text-property (1- (point)) 'harness-graph-target)))))
    (unless target
      (user-error "No node or page here"))
    (harness-ui-workspace-graph--follow target)))

(defun harness-ui-workspace-graph-back ()
  "Show the view before this one."
  (interactive)
  (unless harness-ui-workspace-graph--stack
    (user-error "No earlier view"))
  (setq harness-ui-workspace-graph--view (pop harness-ui-workspace-graph--stack)
        harness-ui-workspace-graph--data nil)
  (harness-ui-workspace-graph--fetch))

(defun harness-ui-workspace-graph-refresh ()
  "Read the graph again."
  (interactive)
  (harness-ui-workspace-graph--fetch))

(defun harness-ui-workspace-graph-workspace ()
  "Show the workspace chat of this graph."
  (interactive)
  (let ((buffer (cl-find-if (lambda (candidate)
                              (and (buffer-live-p candidate)
                                   (with-current-buffer candidate
                                     (and (derived-mode-p 'harness-ui-workspace-mode)
                                          (equal harness-ui-workspace--id
                                                 harness-ui-workspace-graph--id)))))
                            (harness-ui-workspace--buffers))))
    (if buffer
        (pop-to-buffer buffer)
      (user-error "No workspace buffer"))))

;;;###autoload
(defun harness-ui-workspace-graph (&optional workspace thread)
  "Show the Logseq graph of THREAD in WORKSPACE, or of the current one.
The graph is the thread's page: its nodes are the turns and the notes,
with the pages they link to and the nodes that link back.  A node or a
linked page at point opens with `harness-ui-workspace-graph-open'."
  (interactive)
  (let* ((here (derived-mode-p 'harness-ui-workspace-mode))
         (id (or workspace
                 (and here harness-ui-workspace--id)
                 harness-ui-workspace-graph--last-id))
         (thread (or thread
                     (and here (harness-ui-workspace--selected-thread))))
         (name (and here (plist-get harness-ui-workspace--data :name))))
    (unless id
      (user-error "No workspace open"))
    (setq harness-ui-workspace-graph--last-id id)
    (let ((buffer (get-buffer-create "*Workspace Graph*")))
      (with-current-buffer buffer
        (harness-ui-workspace-graph-mode)
        (setq harness-ui-workspace-graph--id id
              harness-ui-workspace-graph--name name
              harness-ui-workspace-graph--thread thread
              harness-ui-workspace-graph--view '(:kind thread)
              harness-ui-workspace-graph--data nil
              harness-ui-workspace-graph--stack nil
              harness-ui-workspace-graph--error nil
              harness-ui-workspace-graph--loading t)
        (harness-ui-workspace-graph--render))
      (pop-to-buffer buffer)
      (harness-ui-workspace-graph--fetch))))

;;;; Workspace computer

(defvar-local harness-ui-workspace-computer--workspace nil
  "Workspace id of the computer buffer.")

(defvar-local harness-ui-workspace-computer--data nil
  "The `workspace/box/status' answer this buffer shows.")

(defvar-local harness-ui-workspace-computer--error nil
  "Why the last computer request failed, or nil.")

(defvar-local harness-ui-workspace-computer--busy nil
  "The action in flight, or nil.")

(defvar-local harness-ui-workspace-computer--shot nil
  "The last screenshot file this buffer drew, or nil.")

(defvar harness-ui-workspace-computer-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "s") #'harness-ui-workspace-computer-start)
    (define-key map (kbd "S") #'harness-ui-workspace-computer-stop)
    (define-key map (kbd "r") #'harness-ui-workspace-computer-refresh)
    (define-key map (kbd "t") #'harness-ui-workspace-computer-take-over)
    (define-key map (kbd "T") #'harness-ui-workspace-computer-return-control)
    (define-key map (kbd "o") #'harness-ui-workspace-computer-open-vnc)
    (define-key map (kbd "p") #'harness-ui-workspace-computer-screenshot)
    (define-key map (kbd "q") #'harness-ui-bury)
    map)
  "Keys of the workspace computer buffer.")

(define-derived-mode harness-ui-workspace-computer-mode special-mode "Workspace Computer"
  "Major mode of the workspace's computer page.
It shows the real box's state and VNC endpoint, starts and stops it,
hands control between the agent and the user, opens the noVNC page and
draws a screenshot the box took.
\\<harness-ui-workspace-computer-mode-map>\\[harness-ui-workspace-computer-refresh] reads it again."
  (setq buffer-read-only t)
  (setq-local truncate-lines nil
              word-wrap t))

(defun harness-ui-workspace-computer--run-state (data)
  "Return how DATA's box reads in one word."
  (pcase (plist-get data :state)
    ("running" "Live")
    ("starting" "Starting")
    ("failed" "Unavailable")
    ("stopped" "Off")
    (_ "Off")))

(defun harness-ui-workspace-computer--line (label value &optional face)
  "Insert LABEL and VALUE on one line, VALUE with FACE."
  (insert "  " (propertize label 'face 'harness-dim-face) "  "
          (propertize (format "%s" (or value "")) 'face (or face 'default))
          "\n"))

(defun harness-ui-workspace-computer--render ()
  "Draw the computer buffer."
  (let ((inhibit-read-only t)
        (data harness-ui-workspace-computer--data))
    (erase-buffer)
    (insert (propertize "Workspace computer" 'face 'harness-header-face)
            "  ·  "
            (propertize (or (plist-get data :name)
                            harness-ui-workspace-computer--workspace
                            "Workspace")
                        'face 'harness-header-face)
            "  ·  "
            (propertize (harness-ui-workspace-computer--run-state data)
                        'face (if (harness-json-true-p (plist-get data :running))
                                  'harness-status-running-face
                                'harness-dim-face))
            "\n\n")
    (when harness-ui-workspace-computer--busy
      (insert (propertize (format "%s…" harness-ui-workspace-computer--busy)
                          'face 'harness-dim-face)
              "\n\n"))
    (when harness-ui-workspace-computer--error
      (insert (propertize harness-ui-workspace-computer--error
                          'face 'harness-failure-face)
              "\n\n"))
    (insert (propertize "State" 'face 'harness-label-face) "\n")
    (harness-ui-workspace-computer--line
     "Backend" (or (plist-get data :backend) "local"))
    (harness-ui-workspace-computer--line
     "Isolation" (or (plist-get data :isolation) "—"))
    (harness-ui-workspace-computer--line
     "Control" (pcase (plist-get data :control)
                 ("user" "You")
                 (_ "Agent")))
    (harness-ui-workspace-computer--line
     "Display" (or (plist-get data :display) "—"))
    (harness-ui-workspace-computer--line
     "Screen" (if (and (plist-get data :width) (plist-get data :height))
                  (format "%s × %s"
                          (plist-get data :width) (plist-get data :height))
                "—"))
    (when-let* ((reason (plist-get data :reason)))
      (harness-ui-workspace-computer--line
       "Reason" (or (plist-get reason :text) reason) 'harness-caution-face))
    (when-let* ((missing (plist-get data :missing)))
      (harness-ui-workspace-computer--line
       "Missing" (mapconcat (lambda (tool) (format "%s" tool)) missing " ")
       'harness-caution-face))
    (insert "\n" (propertize "Screen" 'face 'harness-label-face) "\n")
    (harness-ui-workspace-computer--line
     "VNC" (or (plist-get data :url) "—"))
    (harness-ui-workspace-computer--line
     "Socket" (or (plist-get data :socket) "—"))
    (insert "  ")
    (harness-ui-button "Start" #'harness-ui-workspace-computer-start
                       :help "start the workspace computer (s)")
    (insert "  ")
    (harness-ui-button "Stop" #'harness-ui-workspace-computer-stop
                       :help "stop the workspace computer (S)")
    (insert "  ")
    (harness-ui-button "Restart" #'harness-ui-workspace-computer-restart
                       :help "restart the workspace computer (R)")
    (insert "  ")
    (harness-ui-button "Take over" #'harness-ui-workspace-computer-take-over
                       :help "take control from the agent (t)")
    (insert "  ")
    (harness-ui-button "Return control" #'harness-ui-workspace-computer-return-control
                       :help "return control to the agent (T)")
    (insert "  ")
    (harness-ui-button "Open VNC page" #'harness-ui-workspace-computer-open-vnc
                       :help "open the noVNC page in a browser (o)")
    (insert "  ")
    (harness-ui-button "Screenshot" #'harness-ui-workspace-computer-screenshot
                       :help "take a picture of the screen (p)")
    (insert "  ")
    (harness-ui-button "Refresh" #'harness-ui-workspace-computer-refresh
                       :help "refresh the computer's state (r)")
    (insert "\n")
    (when (and harness-ui-workspace-computer--shot
               (file-readable-p harness-ui-workspace-computer--shot))
      (insert "\n" (propertize "Picture" 'face 'harness-label-face) "\n")
      (insert-image (create-image harness-ui-workspace-computer--shot 'png t)
                    "[Screenshot]")
      (insert "\n"))
    (insert "\n"
            (propertize "s · start" 'face 'harness-hint-face) "   "
            (propertize "S · stop" 'face 'harness-hint-face) "   "
            (propertize "t · take over" 'face 'harness-hint-face) "   "
            (propertize "T · return control" 'face 'harness-hint-face) "   "
            (propertize "o · open VNC page" 'face 'harness-hint-face) "   "
            (propertize "p · screenshot" 'face 'harness-hint-face) "   "
            (propertize "r · refresh" 'face 'harness-hint-face) "   "
            (propertize "q · bury" 'face 'harness-hint-face) "\n")
    (goto-char (point-min))))

(defun harness-ui-workspace-computer--done (result &optional _action)
  "Take RESULT of ACTION and draw it."
  (when (buffer-live-p (current-buffer))
    (setq harness-ui-workspace-computer--data result
          harness-ui-workspace-computer--error nil
          harness-ui-workspace-computer--busy nil)
    (harness-ui-workspace-computer--render)))

(defun harness-ui-workspace-computer-refresh (&optional buffer)
  "Read the computer of the buffer's workspace again."
  (interactive)
  (let* ((buffer (or buffer (current-buffer)))
         (id (buffer-local-value 'harness-ui-workspace-computer--workspace buffer)))
    (with-current-buffer buffer
      (setq harness-ui-workspace-computer--busy "Reading")
      (harness-ui-workspace-computer--render))
    (harness-ui-call
     "_harness/workspace/box/status"
     (list :workspace id)
     (lambda (result)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (harness-ui-workspace-computer--done result))))
     (lambda (err)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (setq harness-ui-workspace-computer--busy nil
                 harness-ui-workspace-computer--error (harness-error-message err))
           (harness-ui-workspace-computer--render)))))))

(defun harness-ui-workspace-computer--action (method label)
  "Call METHOD for the computer, showing LABEL while it runs."
  (let ((id harness-ui-workspace-computer--workspace)
        (buffer (current-buffer)))
    (setq harness-ui-workspace-computer--busy label
          harness-ui-workspace-computer--error nil)
    (harness-ui-workspace-computer--render)
    (harness-ui-call
     method (list :workspace id)
     (lambda (result)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (harness-ui-workspace-computer--done result))))
     (lambda (err)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (setq harness-ui-workspace-computer--busy nil
                 harness-ui-workspace-computer--error (harness-error-message err))
           (harness-ui-workspace-computer--render)
           (harness-ui-workspace-computer-refresh buffer)))))))

(defun harness-ui-workspace-computer-start ()
  "Start the workspace computer."
  (interactive)
  (harness-ui-workspace-computer--action "_harness/workspace/box/start" "Starting"))

(defun harness-ui-workspace-computer-stop ()
  "Stop the workspace computer."
  (interactive)
  (harness-ui-workspace-computer--action "_harness/workspace/box/stop" "Stopping"))

(defun harness-ui-workspace-computer-restart ()
  "Restart the workspace computer."
  (interactive)
  (harness-ui-workspace-computer--action "_harness/workspace/box/restart" "Restarting"))

(defun harness-ui-workspace-computer-take-over ()
  "Give the reviewer control of the workspace computer."
  (interactive)
  (harness-ui-workspace-computer--action "_harness/workspace/box/take-over" "Taking over"))

(defun harness-ui-workspace-computer-return-control ()
  "Return control of the workspace computer to the agent."
  (interactive)
  (harness-ui-workspace-computer--action "_harness/workspace/box/return-control" "Returning control"))

(defun harness-ui-workspace-computer-open-vnc ()
  "Open the workspace computer's noVNC page."
  (interactive)
  (let ((url (plist-get harness-ui-workspace-computer--data :url)))
    (unless (and (stringp url) (not (string-empty-p url)))
      (user-error "No VNC page · computer off"))
    (browse-url url)))

(defun harness-ui-workspace-computer-screenshot ()
  "Take a screenshot of the workspace computer and draw it here."
  (interactive)
  (let ((id harness-ui-workspace-computer--workspace)
        (buffer (current-buffer)))
    (setq harness-ui-workspace-computer--busy "Screenshot"
          harness-ui-workspace-computer--error nil)
    (harness-ui-workspace-computer--render)
    (harness-ui-call
     "_harness/workspace/box/screenshot"
     (list :workspace id)
     (lambda (result)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (let ((data (plist-get result :data))
                 (mime (or (plist-get result :mime) "image/png")))
             (if (not (stringp data))
                 (setq harness-ui-workspace-computer--error "No screenshot")
               (let ((file (make-temp-file "harness-workspace-screen-" nil
                                           (if (string-match-p "jpe?g" mime) ".jpg" ".png"))))
                 (with-temp-file file
                   (set-buffer-multibyte nil)
                   (insert (base64-decode-string data)))
                 (setq harness-ui-workspace-computer--shot file))))
           (setq harness-ui-workspace-computer--busy nil)
           (harness-ui-workspace-computer--render))))
     (lambda (err)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (setq harness-ui-workspace-computer--busy nil
                 harness-ui-workspace-computer--error (harness-error-message err))
           (harness-ui-workspace-computer--render)))))))

;;;###autoload
(defun harness-ui-workspace-computer (&optional workspace)
  "Show the computer of WORKSPACE, or of the current workspace."
  (interactive)
  (let* ((source (and (derived-mode-p 'harness-ui-workspace-mode)
                      (current-buffer)))
         (id (or workspace
                 (and source (buffer-local-value 'harness-ui-workspace--id source))
                 harness-ui-workspace--last-id))
         (box (and source (buffer-local-value 'harness-ui-workspace--box source))))
    (unless id
      (user-error "No workspace open"))
    (let ((buffer (get-buffer-create "*Workspace Computer*")))
      (with-current-buffer buffer
        (harness-ui-workspace-computer-mode)
        (setq harness-ui-workspace-computer--workspace id
              harness-ui-workspace-computer--data box
              harness-ui-workspace-computer--error nil
              harness-ui-workspace-computer--busy nil
              harness-ui-workspace-computer--shot nil)
        (harness-ui-workspace-computer--render))
      (pop-to-buffer buffer)
      (harness-ui-workspace-computer-refresh buffer))))
