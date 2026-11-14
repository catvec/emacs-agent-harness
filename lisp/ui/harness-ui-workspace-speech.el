;;; harness-ui-workspace-speech.el --- The workspace's speech floor on screen and in the speaker  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; What the workspace has to say, and who is saying it: one panel for
;; the floor the harness keeps (`workspace/speech', see
;; harness-workspace-speech.el), and the speaker that says the words.
;;
;; The panel is a side window on the left (`harness-workspace-speech',
;; `C-c w v'), so a desktop shows the waiting threads beside the chat
;; rather than inside it; the workspace buffer carries the same lines
;; inline, which is what a narrow frame, and the phone-shaped one, shows.
;; Either one is a view of the harness's record: nothing here queues
;; speech of its own, and nothing here decides whose turn it is.
;;
;; The lines, and nothing else:
;;
;;   Speech · 2 waiting
;;   Speaking · Kitchen renovation         4s    [Hold] [Skip]
;;   Waiting · 2
;;   ● Harness memory  Garden lights        [Solo]
;;   ● Kitchen renovation  Quote accepted    [Solo]
;;   Solo · Kitchen renovation              [Leave solo]
;;
;; They are nouns and adjectives, as this repository's interface copy
;; is, and so are the tooltips: `Speech · solo', not a sentence about
;; soloing.  A thread the user may not see is not named: the harness
;; answers the floor for this client, and a thread that is not in it is
;; not in the panel either.
;;
;; The speaker.  Playing the floor is the existing voice path, not a
;; second one: the words are synthesized by `speech/synthesize' over ACP
;; when this client has no synthesis command of its own
;; (`harness-voice-synthesize-command'), played by the same external
;; player the voice module uses (`harness-voice-player-command', else the
;; media module's), and cancelled the same way -- one cancellable process
;; at a time.  Before it synthesizes anything it *claims* the entry on
;; the floor (`workspace/speech/claim'), so a second Emacs, or a phone in
;; the room, stays quiet; and it reports back what happened
;; (`workspace/speech/advance'), so the queue moves only when the words
;; really ended.  A failed synthesis or a dead player is reported as
;; such and the floor moves on; it never replays.
;;
;; Hold keeps the playing words.  `harness-workspace-speech-hold' stops
;; the player and tells the floor how many seconds were played, so
;; `harness-workspace-speech-resume' can play the same WAV from that
;; point.  A client with no synthesis of its own gets a fresh WAV from
;; the harness on resume, so it restarts the utterance from the top
;; (`:restart'): the words are said again rather than lost, and the panel
;; says `From the start' while the position is unknown.
;;
;; Nothing here raises, focuses or selects a frame: the panel is shown,
;; never forced, and playback never moves the selection. Voice route
;; generation and the microphone are the voice module's; this module
;; only borrows its player and its synthesis settings.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-acp)
(require 'harness-ui)
(require 'harness-ui-compose)
(require 'harness-ui-media)

(defvar harness-ui-workspace--id)
(defvar harness-ui-workspace-mode)
(defvar harness-ui-workspace--render)
(defvar harness-ui-workspace--buffers)
(declare-function harness-ui-workspace-refresh "harness-ui-workspace")
(declare-function harness-ui-workspace-open-episode "harness-ui-workspace")
(declare-function harness-ui-workspace--select-thread "harness-ui-workspace")
(declare-function harness-voice--player "harness-ui-voice" (file))
(declare-function harness-voice--speech-text "harness-ui-voice" (text))
(declare-function harness-ui-pipeline-status "harness-ui-voice")

(defgroup harness-workspace-speech-ui nil
  "The workspace speech floor on screen and in the speaker."
  :group 'harness-workspace
  :prefix "harness-workspace-speech-")

(defcustom harness-workspace-speech-speak t
  "Whether this client says the workspace's speech floor aloud.
With nil the panel still shows the floor and its controls; nothing is
played here.  Turn it off on a client that should stay quiet while
another one speaks."
  :type 'boolean
  :group 'harness-workspace-speech-ui)

(defcustom harness-workspace-speech-side 'left
  "Side the speech panel opens on, `left' or `right'."
  :type '(choice (const left) (const right))
  :group 'harness-workspace-speech-ui)

(defcustom harness-workspace-speech-side-width 38
  "Width of the speech panel, in characters."
  :type 'integer
  :group 'harness-workspace-speech-ui)

(defcustom harness-workspace-speech-auto-show nil
  "Whether the panel opens by itself when the floor has something to say.
Nil keeps it closed until `harness-workspace-speech' is asked for; the
workspace buffer shows the same lines inline either way."
  :type 'boolean
  :group 'harness-workspace-speech-ui)

(defvar harness-workspace-speech--floors (make-hash-table :test 'equal)
  "Workspace id -> the floor this client last read.")

(defvar-local harness-workspace-speech--id nil
  "Workspace id of this panel.")

(defvar harness-workspace-speech--player nil
  "The utterance this client is playing, or nil.
A plist: `:workspace', `:entry', `:process', `:file', `:dir', `:started',
`:played' and `:held'.")

(defvar harness-workspace-speech--claim-timer nil
  "Timer renewing the claim on the playing entry.")

(defvar harness-workspace-speech--busy nil
  "Non-nil while this client is claiming or synthesizing an entry.")

(defvar harness-workspace-speech--subscribed nil
  "Non-nil once this module subscribed to the UI's events.")

;;;; Faces

(defface harness-workspace-speech-speaking-face
  '((t :inherit (harness-agent-label-face bold)))
  "Face of the thread that is speaking now."
  :group 'harness-workspace-speech-ui)

(defface harness-workspace-speech-held-face
  '((t :inherit harness-caution-face))
  "Face of the hold, of a held utterance and of a held queue."
  :group 'harness-workspace-speech-ui)

(defface harness-workspace-speech-waiting-face
  '((t :inherit harness-dim-face))
  "Face of the threads waiting to speak."
  :group 'harness-workspace-speech-ui)

;;;; Reading the floor

(defun harness-workspace-speech--floor (&optional id)
  "Return this client's copy of the floor of ID, or nil."
  (gethash (or id harness-workspace-speech--id) harness-workspace-speech--floors))

(defun harness-workspace-speech--note (id floor)
  "Take FLOOR as the copy of workspace ID's floor this client has.
A stale answer -- one whose revision is older than the copy in hand
-- changes nothing, so an out-of-order reply never rolls the panel
back to a queue that has moved."
  (when (and (stringp id) (listp floor) (plist-get floor :revision))
    (let ((known (gethash id harness-workspace-speech--floors)))
      (when (or (null known)
                (<= (or (plist-get known :revision) -1)
                    (or (plist-get floor :revision) 0)))
        (puthash id floor harness-workspace-speech--floors)
        t))))

(defun harness-workspace-speech--read (id &optional callback)
  "Read workspace ID's floor from the harness, then call CALLBACK.
The answer is noted whether or not it is newer, and every panel and
workspace buffer of ID is redrawn when it is."
  (when (stringp id)
    (harness-ui-call
     "_harness/workspace/speech" (list :id id)
     (lambda (floor)
       (when (harness-workspace-speech--note id floor)
         (harness-workspace-speech--redraw id))
       (when callback (funcall callback floor)))
     (lambda (err)
       (harness-log 'warn "workspace-speech: cannot read the floor of %s: %s"
                    id (harness-error-message err))
       (when callback (funcall callback nil))))))

(defun harness-workspace-speech--call (method params &optional callback)
  "Call the floor METHOD with PARAMS, then CALLBACK with its answer.
The answer of every method here is the floor, or a plist carrying one."
  (harness-ui-call
   (concat "_harness/" method) params
   (lambda (result)
     (let ((floor (or (and (plist-member result :floor) (plist-get result :floor))
                      result)))
       (when-let* ((id (plist-get floor :workspace)))
         (harness-workspace-speech--note id floor)
         (harness-workspace-speech--redraw id)))
     (when callback (funcall callback result)))
   (lambda (err)
     (message "Speech · %s" (harness-ui-one-line (harness-error-message err)))
     (when callback (funcall callback nil)))))

;;;; Copy

(defun harness-workspace-speech--count-label (floor)
  "Return FLOOR's one-line state, a noun phrase."
  (let ((count (or (plist-get floor :count) 0))
        (recent (plist-get floor :recent)))
    (cond
     ((plist-get floor :hold) "Held")
     ((plist-get floor :solo) "Solo")
     ((> count 0) (format "%d waiting" count))
     ((plist-get floor :speaking) "Speaking")
     (recent "Idle")
     (t "No speech"))))

(defun harness-workspace-speech--seconds-label (seconds)
  "Return SECONDS as a short label, or nil."
  (when (and (numberp seconds) (>= seconds 1))
    (format "%ds" (round seconds))))

(defun harness-workspace-speech--entry-label (entry)
  "Return ENTRY's thread and preview as one line of nouns."
  (let ((title (or (plist-get entry :thread-title) "Thread"))
        (preview (or (plist-get entry :preview) "")))
    (if (string-empty-p preview) title (format "%s · %s" title preview))))

;;;; Drawing

(defun harness-workspace-speech--button (label action help)
  "Insert a button LABEL running ACTION, with tooltip HELP."
  (insert-text-button
   (propertize (concat "[" label "]") 'face 'button)
   'action (lambda (_button) (funcall action))
   'follow-link t 'mouse-face 'highlight
   'help-echo help))

(defun harness-workspace-speech--insert-speaking (floor)
  "Insert the speaking entry of FLOOR, with its controls."
  (when-let* ((entry (and (not (plist-get floor :hold))
                          (plist-get floor :speaking))))
    (insert (propertize "Speaking" 'face 'harness-label-face)
            " · " (propertize (or (plist-get entry :thread-title) "Thread")
                              'face 'harness-workspace-speech-speaking-face)
            (if-let* ((seconds (harness-workspace-speech--seconds-label
                                (plist-get entry :played))))
                (format "  %s" seconds)
              "")
            "  ")
    (harness-workspace-speech--button "Hold" #'harness-workspace-speech-hold
                                      "Speech · hold")
    (insert " ")
    (harness-workspace-speech--button "Skip" #'harness-workspace-speech-skip
                                      "Speech · skip")
    (insert "\n")
    (insert (propertize (or (plist-get entry :preview) "")
                        'face 'harness-workspace-speech-waiting-face)
            "\n")))

(defun harness-workspace-speech--insert-held (floor)
  "Insert the held utterance of FLOOR, with its controls."
  (when-let* ((entry (and (plist-get floor :hold)
                          (plist-get floor :speaking))))
    (insert (propertize "Held" 'face 'harness-workspace-speech-held-face)
            " · " (propertize (or (plist-get entry :thread-title) "Thread")
                              'face 'harness-workspace-speech-speaking-face)
            (if-let* ((seconds (harness-workspace-speech--seconds-label
                                (plist-get entry :played))))
                (format "  %s" seconds)
              "")
            "  ")
    (harness-workspace-speech--button "Resume" #'harness-workspace-speech-resume
                                      "Speech · resume")
    (insert " ")
    (harness-workspace-speech--button "Skip" #'harness-workspace-speech-skip
                                      "Speech · skip")
    (insert "\n")
    (insert (propertize (or (plist-get entry :preview) "")
                        'face 'harness-workspace-speech-waiting-face)
            "\n")))

(defun harness-workspace-speech--insert-waiting (floor)
  "Insert the waiting entries of FLOOR, each with its Solo control."
  (let ((waiting (plist-get floor :waiting)))
    (when waiting
      (insert (propertize (format "Waiting · %d" (length waiting))
                          'face 'harness-label-face)
              "\n")
      (dolist (entry waiting)
        (let* ((thread (plist-get entry :thread))
               (title (or (plist-get entry :thread-title) "Thread"))
               (solo (equal thread (plist-get floor :solo)))
               (held (plist-get entry :held)))
          (insert (propertize "● " 'face 'harness-workspace-speech-waiting-face)
                  (propertize title
                              'face (if solo
                                        'harness-workspace-speech-speaking-face
                                      'harness-user-label-face))
                  (if held
                      (propertize "  Solo" 'face 'harness-workspace-speech-held-face)
                    "")
                  "  ")
          (if solo
              (harness-workspace-speech--button
               "Leave solo" (lambda () (harness-workspace-speech-unsolo))
               "Speech · leave solo")
            (harness-workspace-speech--button
             "Solo" (lambda () (harness-workspace-speech-solo thread))
             "Speech · solo"))
          (insert "\n")
          (insert (propertize (format "  %s" (or (plist-get entry :preview) ""))
                              'face 'harness-workspace-speech-waiting-face)
                  "\n"))))))

(defun harness-workspace-speech--insert-solo (floor)
  "Insert the solo line of FLOOR, with its way out."
  (when-let* ((solo (plist-get floor :solo)))
    (insert (propertize "Solo" 'face 'harness-workspace-speech-held-face)
            " · " (propertize (or (plist-get floor :solo-title) "Thread")
                              'face 'harness-workspace-speech-speaking-face)
            "  ")
    (harness-workspace-speech--button "Leave solo" #'harness-workspace-speech-unsolo
                                      "Speech · leave solo")
    (insert "\n")))

(defun harness-workspace-speech--insert-recent (floor)
  "Insert the entries of FLOOR that were spoken, failed or cancelled."
  (when-let* ((recent (plist-get floor :recent)))
    (insert (propertize "Recent" 'face 'harness-label-face) "\n")
    (dolist (entry (seq-take recent 4))
      (let* ((state (or (plist-get entry :state) "finished"))
             (why (or (plist-get entry :why) (plist-get entry :outcome)))
             (word (pcase state
                     ("finished" "Spoken")
                     ("failed" "Failed")
                     (_ "Cancelled"))))
        (insert (propertize (if why (format "%s · %s" word why) word)
                            'face 'harness-workspace-speech-waiting-face)
                " · " (propertize (or (plist-get entry :thread-title) "Thread")
                                  'face 'harness-dim-face)
                "\n")
        (insert (propertize (format "  %s" (or (plist-get entry :preview) ""))
                            'face 'harness-dim-face)
                "\n")))))

(defun harness-workspace-speech--insert (floor &optional no-heading)
  "Insert FLOOR as the panel draws it.
NO-HEADING leaves the title out, which the workspace buffer does: its
own header names the workspace."
  (unless no-heading
    (insert (propertize "Speech" 'face 'harness-header-face)
            " · " (propertize (harness-workspace-speech--count-label floor)
                              'face 'harness-dim-face)
            "  "))
  (unless no-heading
    (if (plist-get floor :hold)
        (harness-workspace-speech--button "Resume" #'harness-workspace-speech-resume
                                          "Speech · resume")
      (harness-workspace-speech--button "Hold" #'harness-workspace-speech-hold
                                        "Speech · hold"))
    (insert " "))
  (unless no-heading
    (harness-workspace-speech--button "Refresh" #'harness-workspace-speech-refresh
                                      "Speech · refresh")
    (insert "\n"))
  (harness-workspace-speech--insert-held floor)
  (harness-workspace-speech--insert-speaking floor)
  (harness-workspace-speech--insert-solo floor)
  (harness-workspace-speech--insert-waiting floor)
  (harness-workspace-speech--insert-recent floor)
  (unless (or (plist-get floor :speaking) (plist-get floor :waiting)
              (plist-get floor :recent))
    (insert (propertize (if (plist-get floor :hold) "Nothing to say · Held" "Nothing to say")
                        'face 'harness-dim-face)
            "\n")))

(declare-function harness-ui-workspace--render "harness-ui-workspace")

(defun harness-workspace-speech--redraw (id)
  "Redraw the panels and workspace buffers that show workspace ID."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (cond
       ((and (eq major-mode 'harness-workspace-speech-mode)
             (equal id harness-workspace-speech--id))
        (harness-workspace-speech--render-panel))
       ((and (derived-mode-p 'harness-ui-workspace-mode)
             (equal id harness-ui-workspace--id))
        (harness-ui-workspace--render))))))

;;;; The panel

(defvar harness-workspace-speech-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "h") #'harness-workspace-speech-hold)
    (define-key map (kbd "r") #'harness-workspace-speech-resume)
    (define-key map (kbd "s") #'harness-workspace-speech-solo)
    (define-key map (kbd "u") #'harness-workspace-speech-unsolo)
    (define-key map (kbd "n") #'harness-workspace-speech-skip)
    (define-key map (kbd "c") #'harness-workspace-speech-cancel)
    (define-key map (kbd "g") #'harness-workspace-speech-refresh)
    (define-key map (kbd "q") #'harness-ui-bury)
    map)
  "Keys of the speech panel.")

(define-derived-mode harness-workspace-speech-mode special-mode "Speech"
  "Major mode of the workspace speech panel.
It shows what the workspace has to say: the thread speaking, the hold,
the solo and the threads waiting, with their controls.
\\<harness-workspace-speech-mode-map>\\[harness-workspace-speech-hold] holds, \
\\[harness-workspace-speech-resume] resumes, \
\\[harness-workspace-speech-solo] solos the thread at point, and \
\\[harness-workspace-speech-unsolo] leaves solo."
  (setq buffer-read-only t)
  (setq-local truncate-lines nil
              word-wrap t))

(defun harness-workspace-speech--render-panel ()
  "Draw this panel's floor."
  (when (eq major-mode 'harness-workspace-speech-mode)
    (let* ((inhibit-read-only t)
           (id harness-workspace-speech--id)
           (floor (and id (harness-workspace-speech--floor id))))
      (erase-buffer)
      (cond
       ((null id)
        (insert (propertize "Speech · no workspace" 'face 'harness-header-face) "\n"))
       ((null floor)
        (insert (propertize "Speech · loading" 'face 'harness-header-face) "\n"))
       (t
        (harness-workspace-speech--insert floor)))
      (set-buffer-modified-p nil))))

(defun harness-workspace-speech--panel-buffer (id name)
  "Return the panel buffer of workspace ID, named for NAME."
  (let ((base (format "*harness speech: %s*" (or name "Workspace"))))
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (and (eq major-mode 'harness-workspace-speech-mode)
                   (equal id harness-workspace-speech--id)
                   (not (get-buffer-window buffer t)))
          (kill-buffer buffer))))
    (let ((buffer (get-buffer-create base)))
      (with-current-buffer buffer
        (unless (eq major-mode 'harness-workspace-speech-mode)
          (harness-workspace-speech-mode))
        (setq harness-workspace-speech--id id)
        (harness-workspace-speech--render-panel))
      buffer)))

(defun harness-workspace-speech--show (id &optional name)
  "Show the speech panel of workspace ID, named NAME, as a side window.
The window is shown, not selected: nothing here takes the keyboard, and
the frame is never raised, focused or resized."
  (let* ((buffer (harness-workspace-speech--panel-buffer id name))
         (side (if (eq harness-workspace-speech-side 'right) 'right 'left))
         (parameters (list (cons 'side side)
                           (cons 'slot 0)
                           (cons 'window-width harness-workspace-speech-side-width)
                           (cons 'window-parameters
                                 '((no-delete-other-windows . t)))
                           (cons 'preserve-size '(t . nil)))))
    (display-buffer-in-side-window buffer parameters)
    (harness-workspace-speech--redraw id)
    buffer))

;;;###autoload
(defun harness-workspace-speech (&optional id)
  "Show the speech floor of workspace ID, or of the current workspace.
The panel is a side window, on the left by default
\(`harness-workspace-speech-side'), so the waiting threads are visible
beside the chat.  It reads the harness's floor; it keeps no queue of its
own."
  (interactive)
  (let* ((workspace (harness-workspace-speech--workspace-at-point))
         (id (or id
                 (and workspace (plist-get workspace :id))
                 (and (derived-mode-p 'harness-ui-workspace-mode)
                      harness-ui-workspace--id)
                 (and (boundp 'harness-ui-workspace--last-id)
                      harness-ui-workspace--last-id))))
    (unless id
      (user-error "No workspace"))
    (harness-workspace-speech--show
     id (and workspace (plist-get workspace :name)))
    (harness-workspace-speech--read id)))

(defun harness-workspace-speech--workspace-at-point ()
  "Return the workspace plist this client knows, or nil.
That is the one the current buffer is of, else the one it read last."
  (cond
   ((and (derived-mode-p 'harness-ui-workspace-mode) harness-ui-workspace--id)
    (list :id harness-ui-workspace--id
          :name (plist-get (bound-and-true-p harness-ui-workspace--data) :name)))
   ((and (boundp 'harness-ui-workspace--last-id) harness-ui-workspace--last-id)
    (list :id harness-ui-workspace--last-id))
   (t nil)))

;;;; Controls

(defun harness-workspace-speech--id ()
  "Return the workspace id the current panel or buffer speaks for."
  (cond
   ((eq major-mode 'harness-workspace-speech-mode) harness-workspace-speech--id)
   ((derived-mode-p 'harness-ui-workspace-mode) harness-ui-workspace--id)
   (t (or (bound-and-true-p harness-ui-workspace--last-id)
          (and (harness-workspace-speech--workspace-at-point)
               (plist-get (harness-workspace-speech--workspace-at-point) :id))))))

(defun harness-workspace-speech-hold ()
  "Hold all speech of the workspace: nothing starts until the resume.
The utterance playing now is kept where it stopped, not discarded, so
the resume says the same words again from there.  Work in every thread
goes on."
  (interactive)
  (let ((id (harness-workspace-speech--id)))
    (unless id (user-error "No workspace"))
    (let* ((player harness-workspace-speech--player)
           (played (and player
                        ;; A position is worth keeping only for the WAV the
                        ;; floor's own synthesis made: this client's own
                        ;; synthesis makes a different file on resume.
                        (plist-get player :floor-wav)
                        (harness-workspace-speech--player-played player)))
           (entry (and player (plist-get player :entry))))
      ;; Stop the speaker first: the floor records the position the
      ;; words stopped at, and nothing is said after the hold.
      (harness-workspace-speech--stop-player "Hold")
      (harness-workspace-speech--call
       "workspace/speech/hold"
       (append (list :id id)
               (and entry (list :entry entry))
               (and played (list :played played)))))))

(defun harness-workspace-speech-resume ()
  "Resume the workspace's speech, one utterance at a time.
The held utterance goes on from where it stopped when this client held
it and its player can seek there; otherwise the floor starts the same
words again from the top, so they are said rather than lost.  The panel
says which, as `From the start'."
  (interactive)
  (let* ((id (harness-workspace-speech--id))
         (floor (and id (harness-workspace-speech--floor id)))
         (held (and floor (plist-get floor :speaking)))
         (player harness-workspace-speech--player)
         (mine (and held player
                    (equal (plist-get floor :solo) (plist-get floor :solo))
                    (equal (plist-get held :claimed)
                           (harness-workspace-speech--client-name))))
         (seek (and mine
                    (numberp (plist-get held :played))
                    (harness-workspace-speech--seekable-p
                     (harness-workspace-speech--player-command "/dev/null")))))
    (unless id (user-error "No workspace"))
    (harness-workspace-speech--call
     "workspace/speech/resume"
     (append (list :id id) (and (not seek) (list :restart t)))
     (lambda (result)
       (when result (harness-workspace-speech--pump id))))))

(defun harness-workspace-speech-solo (&optional thread)
  "Solo THREAD, by default the one at point, so no other thread interrupts.
The other threads keep working and their words stay waiting."
  (interactive)
  (let ((id (harness-workspace-speech--id))
        (thread (or thread (harness-workspace-speech--thread-at-point))))
    (unless id (user-error "No workspace"))
    (unless thread
      (setq thread
            (let ((floor (harness-workspace-speech--floor id)))
              (completing-read
               "Solo: "
               (mapcar (lambda (entry)
                         (cons (or (plist-get entry :thread-title) "Thread")
                               (plist-get entry :thread)))
                       (append (and (plist-get floor :speaking)
                                    (list (plist-get floor :speaking)))
                               (plist-get floor :waiting)))))))
    (harness-workspace-speech--call
     "workspace/speech/solo" (list :id id :thread thread)
     (lambda (floor)
       (when (and floor (not (plist-get floor :hold)))
         (harness-workspace-speech--pump id))))))

(defun harness-workspace-speech-unsolo ()
  "Let every thread of the workspace speak again.
A hold stays: it is the user's own pause, and resume is what lifts it."
  (interactive)
  (let ((id (harness-workspace-speech--id)))
    (unless id (user-error "No workspace"))
    (harness-workspace-speech--call
     "workspace/speech/unsolo" (list :id id)
     (lambda (floor)
       (when (and floor (not (plist-get floor :hold)))
         (harness-workspace-speech--pump id))))))

(defun harness-workspace-speech-skip ()
  "Skip the utterance playing now or waiting at the head of the queue."
  (interactive)
  (let* ((id (harness-workspace-speech--id))
         (floor (and id (harness-workspace-speech--floor id)))
         (entry (or (and floor (plist-get (plist-get floor :speaking) :id))
                    (and floor (plist-get (car (plist-get floor :waiting)) :id)))))
    (unless id (user-error "No workspace"))
    (unless entry (user-error "Nothing to skip"))
    (when (and harness-workspace-speech--player
               (equal entry (plist-get harness-workspace-speech--player :entry)))
      (harness-workspace-speech--stop-player "Skipped"))
    (harness-workspace-speech--call
     "workspace/speech/advance" (list :id id :entry entry :outcome "cancelled"
                                      :why "Skipped"))))

(defun harness-workspace-speech-cancel ()
  "Drop the utterances waiting in the workspace's queue.
The hold, and what is playing now, stay: this empties the queue."
  (interactive)
  (let ((id (harness-workspace-speech--id)))
    (unless id (user-error "No workspace"))
    (harness-workspace-speech--call
     "workspace/speech/cancel" (list :id id))))

(defun harness-workspace-speech-refresh ()
  "Read the workspace's speech floor again."
  (interactive)
  (let ((id (harness-workspace-speech--id)))
    (unless id (user-error "No workspace"))
    (harness-workspace-speech--read id)))

(defun harness-workspace-speech--thread-at-point ()
  "Return the thread id of the line at point, or nil."
  (or (get-text-property (point) 'harness-workspace-speech-thread)
      (and (derived-mode-p 'harness-ui-workspace-mode)
           (harness-workspace-speech--thread-on-line))))

(defun harness-workspace-speech--thread-on-line ()
  "Return the thread id of the workspace line at point, or nil."
  (when-let* ((pos (text-property-any (line-beginning-position) (line-end-position)
                                      'harness-workspace-thread nil)))
    (get-text-property pos 'harness-workspace-thread)))

;;;; The speaker

(defun harness-workspace-speech--player-played (player)
  "Return the seconds PLAYER had played, or nil."
  (when-let* ((started (plist-get player :started)))
    (max 0 (- (float-time) started))))

(defun harness-workspace-speech--player-dir ()
  "Return a private directory for one utterance's audio."
  (let ((dir (make-temp-file "harness-workspace-speech-" t)))
    (set-file-modes dir #o700)
    dir))

(defun harness-workspace-speech--dispose (player)
  "Stop and remove PLAYER's process and its audio."
  (when-let* ((process (plist-get player :process)))
    (set-process-sentinel process #'ignore)
    (when (process-live-p process) (delete-process process)))
  (when-let* ((dir (plist-get player :dir)))
    (when (file-directory-p dir) (ignore-errors (delete-directory dir t)))))

(defun harness-workspace-speech--stop-player (&optional why)
  "Stop this client's speaker now, keeping WHY for the floor.
The utterance is *reported* only when the caller does not report it
itself: a hold says so through the floor's own hold, and a skip through
the advance."
  (let ((player harness-workspace-speech--player))
    (when player
      (setq harness-workspace-speech--player nil)
      (harness-workspace-speech--dispose player)
      (when (and why (not (member why '("Hold" "Skipped"))))
        (harness-workspace-speech--call
         "workspace/speech/advance"
         (list :id (plist-get player :workspace)
               :entry (plist-get player :entry)
               :outcome "cancelled" :why why)))
      (when (timerp harness-workspace-speech--claim-timer)
        (cancel-timer harness-workspace-speech--claim-timer)
        (setq harness-workspace-speech--claim-timer nil)))
    player))

(defun harness-workspace-speech--synthesis-command (file)
  "Return the command that synthesizes into FILE, or nil for the pipeline.
It is the voice module's own synthesis setting: this module adds no
second speech engine."
  (when (bound-and-true-p harness-voice-synthesize-command)
    (let ((command harness-voice-synthesize-command))
      (mapcar (lambda (item) (if (eq item :file) file item)) command))))

(defun harness-workspace-speech--player-command (file)
  "Return the command playing FILE, signalling when there is none."
  (if (bound-and-true-p harness-voice-player-command)
      (mapcar (lambda (item) (if (eq item :file) file item))
              harness-voice-player-command)
    (let ((program (harness-ui-media--player-program)))
      (unless program
        (error "No audio player · mpv, pw-play, ffplay or paplay"))
      (harness-ui-media--player-command program file))))

(defun harness-workspace-speech--seekable-p (command)
  "Non-nil when COMMAND's player can start at a position.
mpv can; ffplay names its own option and the loopback players cannot.
A client that cannot seek asks the floor to start the words over, which
says them again rather than losing them."
  (and command
       (equal "mpv" (file-name-nondirectory (car command)))))

(defun harness-workspace-speech--seek-command (command seconds)
  "Return COMMAND started at SECONDS, or nil when it cannot seek."
  (when (and (harness-workspace-speech--seekable-p command)
             (numberp seconds) (> seconds 0))
    (append command (list (format "--start=%.2f" seconds)))))

(defun harness-workspace-speech--client-name ()
  "Return this client's name, so the floor knows whose claim it is."
  (or (and (fboundp 'harness-ui-client-name) (ignore-errors (harness-ui-client-name)))
      (format "emacs-%d" (emacs-pid))))

(defun harness-workspace-speech--play (id entry file &optional played floor-wav)
  "Play FILE for ENTRY of workspace ID, from PLAYED seconds.
FLOOR-WAV says FILE came from the harness's own synthesis, so PLAYED is
a position in the words rather than in a file of this client's making."
  (let* ((plain (harness-workspace-speech--player-command file))
         (command (or (harness-workspace-speech--seek-command plain played) plain))
         (player (list :workspace id :entry entry :file file
                       :dir (file-name-directory file)
                       :started (- (float-time) (or played 0))
                       :floor-wav (and floor-wav t)
                       :played played))
         (process (make-process
                   :name "harness-workspace-speech"
                   :command command
                   :noquery t :buffer nil
                   :sentinel (lambda (proc _event)
                               (when (memq (process-status proc) '(exit signal))
                                 (harness-workspace-speech--finished proc))))))
    (setq harness-workspace-speech--player
          (plist-put (plist-put player :process process) :entry entry))
    ;; The claim is renewed while the words play, so a long utterance is
    ;; not taken for a lost speaker.
    (when (timerp harness-workspace-speech--claim-timer)
      (cancel-timer harness-workspace-speech--claim-timer))
    (setq harness-workspace-speech--claim-timer
          (run-at-time 60 60 #'harness-workspace-speech--renew id entry))
    (harness-workspace-speech--redraw id)))

(defun harness-workspace-speech--renew (id entry)
  "Renew this client's claim on ENTRY of workspace ID."
  (when-let* ((player harness-workspace-speech--player)
              ((equal entry (plist-get player :entry))))
    (harness-ui-call
     "_harness/workspace/speech/claim"
     (list :id id :entry entry :client (harness-workspace-speech--client-name))
     (lambda (answer)
       (when-let* ((floor (plist-get answer :floor)))
         (harness-workspace-speech--note id floor))
       (unless (plist-get answer :claimed)
         ;; Another client took the floor, or the entry yielded: this
         ;; one must go quiet rather than talk over it.
         (when-let* ((player harness-workspace-speech--player)
                     ((equal entry (plist-get player :entry))))
           (harness-workspace-speech--stop-player nil))))
     (lambda (_err) nil))))

(defun harness-workspace-speech--finished (process)
  "Report the utterance that PROCESS played as finished, and move on."
  (when-let* ((player harness-workspace-speech--player)
              ((eq process (plist-get player :process))))
    (let* ((id (plist-get player :workspace))
           (entry (plist-get player :entry))
           (ok (and (eq (process-status process) 'exit)
                    (= (process-exit-status process) 0))))
      (setq harness-workspace-speech--player nil)
      (when (timerp harness-workspace-speech--claim-timer)
        (cancel-timer harness-workspace-speech--claim-timer)
        (setq harness-workspace-speech--claim-timer nil))
      (harness-workspace-speech--dispose player)
      (harness-workspace-speech--call
       "workspace/speech/advance"
       (list :id id :entry entry
             :outcome (if ok "finished" "failed")
             :why (unless ok "Playback failed"))
       (lambda (answer)
         (when answer (harness-workspace-speech--pump id)))))))

(defun harness-workspace-speech--pump (id)
  "Speak the next eligible entry of workspace ID, if this client should.
One utterance at a time: while one plays, or while this client is
claiming one, nothing else starts here.  A hold silences it entirely, and
a client with `harness-workspace-speech-speak' off stays quiet."
  (when (and harness-workspace-speech-speak id)
    (unless (or harness-workspace-speech--player harness-workspace-speech--busy)
      (let ((floor (harness-workspace-speech--floor id)))
        (when (and floor (not (plist-get floor :hold))
                   (plist-get (plist-get floor :speaking) :id))
          (harness-workspace-speech--claim-and-speak
           id (plist-get (plist-get floor :speaking) :id)
           (plist-get floor :speaking)))))))

(defun harness-workspace-speech--claim-and-speak (id entry record)
  "Claim ENTRY of workspace ID, then say RECORD's words here."
  (setq harness-workspace-speech--busy t)
  (harness-ui-call
   "_harness/workspace/speech/claim"
   (list :id id :entry entry :client (harness-workspace-speech--client-name))
   (lambda (answer)
     (setq harness-workspace-speech--busy nil)
     (when-let* ((floor (plist-get answer :floor)))
       (harness-workspace-speech--note id floor))
     (when (plist-get answer :claimed)
       (harness-workspace-speech--synthesize-and-play
        id entry record (plist-get answer :floor))))
   (lambda (err)
     (setq harness-workspace-speech--busy nil)
     (harness-log 'warn "workspace-speech: claim failed: %s"
                  (harness-error-message err)))))

(defun harness-workspace-speech--synthesize-and-play (id entry record floor)
  "Synthesize RECORD's words for ENTRY of workspace ID, then play them.
FLOOR is the answer the claim gave, whose entry carries the position to
resume from."
  (let* ((dir (harness-workspace-speech--player-dir))
         (file (expand-file-name "speech.wav" dir))
         (text (harness-workspace-speech--spoken-text (plist-get record :text)))
         (played (plist-get (plist-get floor :speaking) :played))
         (command (harness-workspace-speech--synthesis-command file)))
    (cond
     ((string-empty-p text)
      (ignore-errors (delete-directory dir t))
      (harness-workspace-speech--call
       "workspace/speech/advance"
       (list :id id :entry entry :outcome "cancelled" :why "Nothing to say")
       (lambda (answer) (when answer (harness-workspace-speech--pump id)))))
     (command
      (harness-workspace-speech--run-synthesis
       id entry dir file command text))
     (t
      (harness-ui-call
       "_harness/speech/synthesize" (list :text text)
       (lambda (result)
         (let ((audio (plist-get result :audio)))
           (if (and (stringp audio) (not (string-empty-p audio)))
               (progn
                 (with-temp-buffer
                   (set-buffer-multibyte nil)
                   (insert (base64-decode-string audio))
                   (write-region (point-min) (point-max) file nil 'silent))
                 (harness-workspace-speech--start-play id entry dir file played t))
             (ignore-errors (delete-directory dir t))
             (harness-workspace-speech--failed id entry "No audio"))))
       (lambda (err)
         (ignore-errors (delete-directory dir t))
         (harness-workspace-speech--failed
          id entry (harness-ui-one-line (harness-error-message err)))))))))

(defun harness-workspace-speech--run-synthesis (id entry dir file command text)
  "Run COMMAND to synthesize TEXT into FILE, then play it.
A client with its own synthesis command starts the words from the top on
a resume: it has the WAV it made, not the harness's, and no position in
it to seek to."
  (let ((process (make-process
                  :name "harness-workspace-synthesis"
                  :command command
                  :connection-type 'pipe
                  :coding 'utf-8-unix :noquery t :buffer nil
                  :sentinel
                  (lambda (proc _event)
                    (when (memq (process-status proc) '(exit signal))
                      (if (and (= (process-exit-status proc) 0)
                               (file-exists-p file)
                               (> (or (file-attribute-size (file-attributes file)) 0) 44))
                          (harness-workspace-speech--start-play
                           id entry dir file nil)
                        (ignore-errors (delete-directory dir t))
                        (harness-workspace-speech--failed
                         id entry "Synthesis failed")))))))
    (process-send-string process (concat text "\n"))
    (process-send-eof process)))

(defun harness-workspace-speech--failed (id entry why)
  "Report ENTRY of workspace ID as failed with WHY, and move on."
  (harness-workspace-speech--call
   "workspace/speech/advance"
   (list :id id :entry entry :outcome "failed" :why why)
   (lambda (answer) (when answer (harness-workspace-speech--pump id)))))

(defun harness-workspace-speech--start-play (id entry dir file played &optional floor-wav)
  "Play FILE for ENTRY of workspace ID, from PLAYED seconds, and clean DIR.
FLOOR-WAV says FILE is the harness's own synthesis of the words."
  (condition-case err
      (harness-workspace-speech--play id entry file played floor-wav)
    (error
     (ignore-errors (delete-directory dir t))
     (harness-workspace-speech--failed
      id entry (harness-ui-one-line (error-message-string err))))))

(defun harness-workspace-speech--spoken-text (text)
  "Return TEXT as it should be said: prose, not markup.
The voice module's filter is used when it is there, so a workspace reply
is read exactly as a chat reply is; with no voice module the same
filter is applied here, so a square bracket or a fence never reaches the
speaker as punctuation."
  (if (fboundp 'harness-voice--speech-text)
      (harness-voice--speech-text (or text ""))
    (with-temp-buffer
      (insert (or text ""))
      (goto-char (point-min))
      ;; Fenced blocks are not read aloud.
      (while (re-search-forward "^[ \t]*\\(```+\\|~~~+\\).*\n?" nil t)
        (let ((start (match-beginning 0)) (fence (match-string 1)))
          (if (re-search-forward (concat "^[ \t]*" (regexp-quote fence) ".*\n?") nil t)
              (delete-region start (point))
            (delete-region start (point-max)))))
      (let ((body (buffer-string)))
        (setq body (replace-regexp-in-string "!?\\[\\([^]\n]+\\)\\](\\([^)]*\\))" "\\1" body)
              body (replace-regexp-in-string "<[^>]+>" "" body)
              body (replace-regexp-in-string "^[ \t]*[#>*-]+[ \t]*" "" body)
              body (replace-regexp-in-string "[`*_]" "" body))
        (string-trim (replace-regexp-in-string "[ \t\n]+" " " body))))))

;;;; Following the harness

(defun harness-workspace-speech--on-event (event args)
  "Take the floor EVENT with ARGS into this client's copies."
  (let ((event (if (symbolp event) (symbol-name event) event)))
    (when (equal event "workspace/speech-changed")
      (pcase-let ((`(,id ,floor) args))
        (when (and (stringp id) (listp floor)
                   (harness-workspace-speech--note id floor))
          (harness-workspace-speech--redraw id)
          ;; A change can make an utterance eligible: this client speaks
          ;; it, unless a hold or another speaker holds the floor.
          (harness-workspace-speech--pump id))))))

(defun harness-workspace-speech--on-workspace-event (event args)
  "Read a workspace's floor when its buffer opens or the harness changed."
  (let ((event (if (symbolp event) (symbol-name event) event))
        (id (car-safe args)))
    (when (and (stringp id)
               (member event '("workspace/changed" "workspace/thread-changed"
                               "workspace/episode-changed" "harness/reloaded")))
      (harness-workspace-speech--read id))))

(defun harness-workspace-speech--on-connected ()
  "Read the floors this client shows after a reconnect.
Nothing replays: the floor is read as the harness has it, and what was
spoken while the connection was gone is history."
  (dolist (id (hash-table-keys harness-workspace-speech--floors))
    (harness-workspace-speech--read id))
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (cond
       ((and (eq major-mode 'harness-workspace-speech-mode)
             harness-workspace-speech--id)
        (harness-workspace-speech--read harness-workspace-speech--id))
       ((and (derived-mode-p 'harness-ui-workspace-mode)
             harness-ui-workspace--id)
        (harness-workspace-speech--read harness-ui-workspace--id))))))

(defun harness-workspace-speech--maybe-show (id)
  "Show the panel for ID when the option says so and it has something to say."
  (when harness-workspace-speech-auto-show
    (let ((floor (harness-workspace-speech--floor id)))
      (when (or (plist-get floor :waiting) (plist-get floor :speaking)
                (plist-get floor :solo) (plist-get floor :hold))
        (unless (get-buffer-window (harness-workspace-speech--panel-buffer id nil) t)
          (harness-workspace-speech--show id))))))

;;;; Module

(defun harness-workspace-speech-ui--init ()
  "Wire the speech floor into the workspace UI."
  (harness-workspace-speech-ui--install-keys)
  (unless harness-workspace-speech--subscribed
    (setq harness-workspace-speech--subscribed t)
    (add-hook 'harness-ui-event-functions #'harness-workspace-speech--on-event)
    (add-hook 'harness-ui-event-functions #'harness-workspace-speech--on-workspace-event)
    (add-hook 'harness-ui-connected-hook #'harness-workspace-speech--on-connected)
    (add-hook 'kill-emacs-hook #'harness-workspace-speech--shutdown-audio)))

(defun harness-workspace-speech-ui--install-keys ()
  "Bind the speech panel in the workspace and the harness's own map."
  (when (boundp 'harness-ui-workspace-mode-map)
    (define-key harness-ui-workspace-mode-map (kbd "C-c w v") #'harness-workspace-speech))
  (when (boundp 'harness-ui-map)
    (define-key harness-ui-map (kbd "C-c h W") #'harness-workspace-speech)))

(defun harness-workspace-speech--shutdown-audio ()
  "Stop this client's speaker and forget the floor it was reading.
Nothing is left playing after the module stops."
  (when harness-workspace-speech--player
    (harness-workspace-speech--stop-player nil))
  (when (timerp harness-workspace-speech--claim-timer)
    (cancel-timer harness-workspace-speech--claim-timer)
    (setq harness-workspace-speech--claim-timer nil)))

(defun harness-workspace-speech-ui--shutdown ()
  "Stop following the floor and remove the panel's keys."
  (when harness-workspace-speech--subscribed
    (setq harness-workspace-speech--subscribed nil)
    (remove-hook 'harness-ui-event-functions #'harness-workspace-speech--on-event)
    (remove-hook 'harness-ui-event-functions #'harness-workspace-speech--on-workspace-event)
    (remove-hook 'harness-ui-connected-hook #'harness-workspace-speech--on-connected)
    (remove-hook 'kill-emacs-hook #'harness-workspace-speech--shutdown-audio))
  (harness-workspace-speech--shutdown-audio)
  (clrhash harness-workspace-speech--floors)
  (when (boundp 'harness-ui-workspace-mode-map)
    (define-key harness-ui-workspace-mode-map (kbd "C-c w v") nil))
  (when (boundp 'harness-ui-map)
    (define-key harness-ui-map (kbd "C-c h W") nil)))

(harness-define-module 'ui-workspace-speech
  :doc "The workspace speech floor: its panel, the solo and hold controls, and this client's speaker."
  :requires '(ui ui-workspace)
  :init #'harness-workspace-speech-ui--init
  :shutdown #'harness-workspace-speech-ui--shutdown)

(provide 'harness-ui-workspace-speech)
;;; harness-ui-workspace-speech.el ends here
