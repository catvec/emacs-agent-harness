;;; harness-ui-tool-slots-load.el --- Held-back tool slots, pinned above the compose box  -*- lexical-binding: t; -*-

;;; Commentary:

;; While this machine is busy, the tool-slots-load module
;; (harness-tool-slots-load.el) lowers how many calls of the tools that
;; start processes may run at once, and says so in the transcript of
;; every session: one note to a stretch of changes, which opens to each
;; of them.  That note is the history, and it stands where the first
;; change of its stretch landed, far up a session that has gone on since.
;; What a person watching a session whose commands wait wants to know
;; is how many slots there are now.
;;
;; So the chat pins that above its compose box, beside the todo list and
;; the sub-agents, for as long as the slots are held back:
;;
;;   Tool slots limited to 5 of 18: system load 1.8x on this machine
;;
;; It goes once the number is back to what it would be without the load
;; watch, and shows in no chat while the machine has all its slots.  The
;; tooltip says what the sessions were told of the last change, and when.
;;
;; The state is the harness's (`tool-slots/status'): the UI fetches it
;; when it connects and after the harness reloads, and the harness
;; announces every change as `tool-slots/changed', the watch ending
;; included.  Nothing polls.  A change draws the tail of every open chat
;; whose panel differs from what the UI shows now, once; a chat opened
;; later draws the panel with the rest of its tail.  A harness without
;; the module answers the fetch with an error, which shows nothing.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)

(defvar harness-chat-panel-functions)
(defvar harness-chat-mode-hook)
(defvar harness-chat--buffers)
(defvar harness-chat--blocks)
(defvar harness-chat--loading)
(defvar harness-compose-redraw-function)

(defgroup harness-ui-tool-slots-load nil
  "Showing the held-back tool slots above a chat's compose box."
  :group 'harness-ui)

(defface harness-chat-slots-face
  '((((background light)) :background "#fdf0d2" :extend t)
    (((background dark)) :background "#3b3016" :extend t))
  "Background of the panel saying the tool slots are held back.
An amber of its own, the colour of a caution, apart from the teal of
the sub-agents and the merge queue, which show in the same place."
  :group 'harness-ui-tool-slots-load)

(harness-ui-define-icon harness-ui-tool-slots-icon "tool" "◈" "slots"
  "The tool slots of this machine, held back.")

(defvar harness-ui-tool-slots-load--state nil
  "The tool slots of the harness's machine, while they are held back, or nil.
A plist, (:limit N :baseline B :pressure P :text TEXT :at TIME), as
`harness-ui-tool-slots-load--held' reads it from what the harness sends
\(`tool-slots/status', `tool-slots/changed'): nil is a machine with all
its slots, which no chat shows anything of.")

;;;; The state

(defun harness-ui-tool-slots-load--held (state)
  "Return what STATE, as the harness sent it, says of held-back slots, or nil.
STATE is (:limit N :baseline B :pressure P :text TEXT :at TIME) as the
`tool-slots/status' method gives it.  The slots are held back while N,
how many calls may run at once, is under B, how many would without the
load watch; then the answer is that plist with the numbers as numbers,
the load, text and time nil when STATE has none.  Nil when they are not
held back, or STATE is no state."
  (when (consp state)
    (let ((limit (plist-get state :limit))
          (baseline (plist-get state :baseline))
          (pressure (plist-get state :pressure))
          (text (plist-get state :text))
          (at (plist-get state :at)))
      (when (and (numberp limit) (numberp baseline) (< limit baseline))
        (list :limit (round limit)
              :baseline (round baseline)
              :pressure (and (numberp pressure) pressure)
              :text (and (stringp text) (not (string-empty-p text)) text)
              :at (and (numberp at) at))))))

(defun harness-ui-tool-slots-load--redraw ()
  "Draw the tail of every open chat again, so each shows the panel as it stands.
A chat that has not drawn its transcript yet is left to draw the panel
with the rest, and so is a buffer that shows no panel of this module."
  (dolist (buffer (and (boundp 'harness-chat--buffers) (hash-table-values harness-chat--buffers)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (and harness-chat--blocks
                   (not harness-chat--loading)
                   (memq #'harness-ui-tool-slots-load--panel harness-chat-panel-functions)
                   (functionp harness-compose-redraw-function))
          (funcall harness-compose-redraw-function))))))

(defun harness-ui-tool-slots-load--store (state)
  "Take STATE, what the harness says of its tool slots, in.
The chats are drawn again when what they show of it changed, so a state
that reads as the one they show -- an answer repeating what an
announcement said -- draws nothing."
  (let ((held (harness-ui-tool-slots-load--held state)))
    (unless (equal held harness-ui-tool-slots-load--state)
      (setq harness-ui-tool-slots-load--state held)
      (harness-ui-tool-slots-load--redraw))))

(defun harness-ui-tool-slots-load-refresh ()
  "Ask the harness how its tool slots stand, and show it.
A harness without the module answers with an error, which leaves the
state as it is: there is nothing to say about it."
  (harness-ui-call "_harness/tool-slots/status" nil
                   #'harness-ui-tool-slots-load--store
                   #'ignore))

;;;; The panel

(defun harness-ui-tool-slots-load--help (held)
  "Return the tooltip of the panel for HELD, the slots held back.
That is what the sessions were told of the last change, and when it was."
  (let ((text (plist-get held :text))
        (at (plist-get held :at)))
    (concat (or text
                (format "Tool slots limited to %d of %d" (plist-get held :limit) (plist-get held :baseline)))
            (if at (format-time-string " (at %H:%M:%S)" at) ""))))

(defun harness-ui-tool-slots-load--render (held)
  "Return the panel for HELD, the slots held back: one line.
It says how many calls may run at once of how many would, and the load
that took the number, when the harness knows it.  The tooltip is the
sessions' last note of it."
  (let* ((pressure (plist-get held :pressure))
         (line (concat (propertize (concat (harness-ui-icon 'harness-ui-tool-slots-icon)
                                           (format " Tool slots limited to %d of %d"
                                                   (plist-get held :limit) (plist-get held :baseline)))
                                   'face 'harness-label-face)
                       (if pressure
                           (propertize (format ": system load %.1fx on this machine" pressure)
                                       'face 'harness-dim-face)
                         "")
                       "\n")))
    (add-text-properties 0 (length line)
                         (list 'wrap-prefix "  "
                               'help-echo (harness-ui-tool-slots-load--help held))
                         line)
    (harness-ui-add-face line 'harness-chat-slots-face)))

(defun harness-ui-tool-slots-load--panel ()
  "Return the panel saying the tool slots are held back, or nil when they are not.
On `harness-chat-panel-functions', in every chat.  It is decoration,
so a failure to draw it draws nothing rather than take the compose box
down with it."
  (when-let* ((held harness-ui-tool-slots-load--state))
    (ignore-errors (harness-ui-tool-slots-load--render held))))

;;;; The module

(defun harness-ui-tool-slots-load--on-event (event args)
  "Follow the harness: EVENT with ARGS, from `_harness/event'.
`tool-slots/changed' brings the state as it is now; after
`harness/reloaded' it is asked for again."
  (pcase event
    ("tool-slots/changed" (harness-ui-tool-slots-load--store (car args)))
    ("harness/reloaded" (harness-ui-tool-slots-load-refresh))))

(defun harness-ui-tool-slots-load--connected ()
  "Forget what the harness this UI was connected to said of its slots, and ask.
On `harness-ui-connected-hook': the harness may be another one, or have
started again, and a harness without the module would leave what was
shown as it was."
  (harness-ui-tool-slots-load--store nil)
  (harness-ui-tool-slots-load-refresh))

(defun harness-ui-tool-slots-load--setup ()
  "Show the panel in this chat buffer."
  (add-hook 'harness-chat-panel-functions #'harness-ui-tool-slots-load--panel t t))

(defun harness-ui-tool-slots-load--init ()
  "Show the panel in every chat, and follow the harness's slots.
The chats open already are included.  When the UI is connected
already, ask for the slots now."
  (with-eval-after-load 'harness-ui-chat
    (add-hook 'harness-chat-mode-hook #'harness-ui-tool-slots-load--setup)
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (derived-mode-p 'harness-chat-mode)
          (harness-ui-tool-slots-load--setup)))))
  (add-hook 'harness-ui-event-functions #'harness-ui-tool-slots-load--on-event)
  (add-hook 'harness-ui-connected-hook #'harness-ui-tool-slots-load--connected)
  (when (harness-ui-connected-p)
    (harness-ui-tool-slots-load-refresh)))

(defun harness-ui-tool-slots-load--shutdown ()
  "Stop showing the panel: every chat is drawn without it, and stops following."
  (remove-hook 'harness-ui-event-functions #'harness-ui-tool-slots-load--on-event)
  (remove-hook 'harness-ui-connected-hook #'harness-ui-tool-slots-load--connected)
  (remove-hook 'harness-chat-mode-hook #'harness-ui-tool-slots-load--setup)
  ;; Drawn without the state first, while the panel is still there to
  ;; be asked, then taken out of the buffers.
  (harness-ui-tool-slots-load--store nil)
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      ;; Only a buffer that has the hook of its own: removing from the
      ;; local value of another would give it one.
      (when (local-variable-p 'harness-chat-panel-functions)
        (remove-hook 'harness-chat-panel-functions #'harness-ui-tool-slots-load--panel t)))))

(harness-define-module 'ui-tool-slots-load
  :doc "The tool slots held back by the machine's load, pinned above a chat's compose box while they are."
  :requires '(ui ui-chat)
  :init #'harness-ui-tool-slots-load--init
  :shutdown #'harness-ui-tool-slots-load--shutdown)

(provide 'harness-ui-tool-slots-load)
;;; harness-ui-tool-slots-load.el ends here
