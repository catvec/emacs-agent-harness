;;; harness-ui-btw.el --- BTW side conversations  -*- lexical-binding: t; -*-

;;; Commentary:

;; A "by the way" conversation is a fork of the current session opened
;; in a side window over it, so a quick question can be asked and
;; answered without leaving the main session or losing its output.  It
;; opens blank, with point in its compose box: the box every session
;; has (multi-line editing, @file and /skill completion, attachments),
;; where C-c C-c asks.  Its first message names it.  Closing the side
;; window returns to the main session untouched; a BTW closed before
;; anything was asked in it is deleted, so one opened by mistake leaves
;; nothing behind.  BTW sessions are ordinary forks and show up in the
;; session list and the conversation tree.
;;
;; A view without a session of its own can host BTWs too: it sets
;; `harness-ui-btw-start-function' to start a conversation about itself
;; and `harness-ui-btw-about' to say what that is.  The task board does,
;; so a BTW over it asks how the tasks are going.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)
(require 'harness-ui-compose)

;; Buffer-local in the chat buffer a BTW shows.
(defvar harness-chat-send-functions)
(defvar harness-chat-placeholder)

(defgroup harness-ui-btw nil
  "BTW side conversations." :group 'harness-ui)

(defcustom harness-ui-btw-window-parameters
  '((side . bottom) (slot . 1) (window-height . 0.35) (preserve-size . (nil . t)))
  "Where the BTW window appears."
  :type 'sexp :group 'harness-ui-btw)

(defconst harness-ui-btw-blank-name "btw"
  "Name of a BTW until its first message names it.")

(defvar harness-ui-btw--open (make-hash-table :test 'equal)
  "BTW session id -> the buffer it was opened over, for open side conversations.")

(defvar-local harness-ui-btw-start-function nil
  "How `harness-btw' starts a conversation over this buffer instead of forking.
A view without a session of its own sets it to a function of the new
session's name returning a promise of the session (a wire plist), whose
system prompt says what the conversation is about.  The task board
starts one about its tasks this way.  nil forks the buffer's session.")

(defvar-local harness-ui-btw-about nil
  "What a BTW started over this buffer is about, such as \"the tasks\".
The BTW's compose box and its window's header say it.")

(defvar-local harness-ui-btw--label nil
  "What the header of this BTW buffer calls the conversation.")

(defvar-local harness-ui-btw--hint nil
  "What the empty compose box of this BTW buffer says.")

(defvar-local harness-ui-btw--asked nil
  "Non-nil once a message was sent in this BTW buffer.")

(defvar-local harness-ui-btw--saved-header nil
  "(HEADER) this buffer had before it showed a BTW, or nil.")

(defun harness-ui-btw-name (text)
  "Return the name of a BTW whose first message is TEXT."
  (format "btw: %s" (harness-first-line text 40)))

;;;###autoload
(defun harness-btw (&optional session-id question)
  "Open a BTW side conversation, blank, ready for a question.
It forks SESSION-ID, by default the current buffer's session.  Over a
view that starts its own conversations (`harness-ui-btw-start-function'),
such as the task board, it is a new conversation about that view.  The
question is written in the BTW's compose box like any message, and the
first one names the conversation.  From Lisp, QUESTION is asked at
once instead.  Return a promise that settles once the BTW is shown."
  (interactive)
  (let* ((over (current-buffer))
         (start (and (null session-id) harness-ui-btw-start-function))
         (about (and start harness-ui-btw-about))
         (question (and question (not (string-blank-p question)) question))
         (name (if question (harness-ui-btw-name question) harness-ui-btw-blank-name)))
    (harness-then
     (if start
         (funcall start name)
       (harness-ui-request "_harness/session/fork"
                           (list :id (or session-id (harness-ui-current-session-id)) :kind "btw" :name name)))
     (lambda (child) (harness-ui-btw--show (plist-get child :id) over about question))
     (lambda (e) (message "BTW failed: %s" (harness-error-message e)) nil))))

(defun harness-ui-btw--show (id over about question)
  "Show BTW session ID in a side window over buffer OVER, point in its box.
ABOUT says what the conversation is about, nil for one about OVER's
session.  QUESTION, when non-nil, is asked at once; otherwise the first
message sent from the box names the BTW."
  (puthash id over harness-ui-btw--open)
  (harness-ui-refresh-sessions
   (lambda (_)
     (unless harness-ui-open-session-function (user-error "No chat module loaded"))
     (let* ((buf (funcall harness-ui-open-session-function id))
            (window (display-buffer-in-side-window buf harness-ui-btw-window-parameters)))
       (select-window window)
       (with-current-buffer buf
         (setq-local harness-ui-position 'btw)
         (setq harness-ui-btw--label (if about (format "about %s" about) "side conversation")
               harness-ui-btw--hint (if about
                                        (format "Ask about %s\N{U+2026}" about)
                                      "Ask a side question\N{U+2026}"))
         (harness-ui-btw-minor-mode 1)
         (if question
             (progn
               (setq harness-ui-btw--asked t)
               (harness-ui-call "session/prompt"
                                (list :sessionId id :prompt (list (list :type "text" :text question)))
                                #'ignore))
           (add-hook 'harness-chat-send-functions #'harness-ui-btw--on-send nil t))
         ;; Ready for the question.
         (when (harness-compose-live-p)
           (goto-char harness-compose-end)
           (set-window-point window harness-compose-end)))))))

(defun harness-ui-btw--on-send (text _attachments)
  "Name this BTW after TEXT, the first message sent in it.
Runs from `harness-chat-send-functions'.  A message of attachments only
leaves the name to the next one, and a name given by hand meanwhile is
kept."
  (setq harness-ui-btw--asked t)
  (unless (string-blank-p text)
    (remove-hook 'harness-chat-send-functions #'harness-ui-btw--on-send t)
    (let ((session (harness-ui-session harness-ui-session-id)))
      (when (member (plist-get session :name) (list nil harness-ui-btw-blank-name))
        (harness-ui-call "_harness/session/update"
                         (list :id harness-ui-session-id :name (harness-ui-btw-name text) :silent t)
                         #'ignore)))))

(defun harness-ui-btw--blank-p ()
  "Non-nil when nothing was asked in this BTW buffer and its box is empty."
  (and (not harness-ui-btw--asked)
       (string-blank-p (harness-compose-text))
       (null harness-compose-attachments)))

(defun harness-ui-btw-close ()
  "Close this BTW window and return to the buffer it was opened over.
A BTW nothing was asked in is deleted with its buffer, so one opened by
mistake leaves nothing behind.  An idle conversation is closed as a
session too, so it no longer counts as waiting for direction; it stays
in the session list and can be resumed.  One still working carries on
in the background.  Either way its buffer shows it as a normal session
from then on."
  (interactive)
  (let ((sid harness-ui-session-id)
        (buffer (current-buffer))
        (over (gethash harness-ui-session-id harness-ui-btw--open))
        (blank (harness-ui-btw--blank-p))
        (win (selected-window)))
    (remhash sid harness-ui-btw--open)
    (cond ((null sid))
          (blank (harness-ui-btw--discard sid buffer))
          ((equal (format "%s" (plist-get (harness-ui-session sid) :status)) "idle")
           (harness-ui-call "_harness/session/deactivate" (list :id sid) #'ignore)))
    (when (window-parameter win 'window-side)
      (delete-window win))
    ;; Opened again later, from the session list say, it is a session like any.
    (unless blank
      (with-current-buffer buffer (harness-ui-btw-minor-mode -1)))
    (when-let* ((back (and (buffer-live-p over) (get-buffer-window over))))
      (select-window back))))

(defun harness-ui-btw--discard (sid buffer)
  "Delete the unused BTW session SID, then kill BUFFER, which showed it.
The harness has the last word: only a session still at the node it was
forked from (without nodes, for one started fresh), idle, with nothing
queued, is deleted.  Any other is closed like a BTW that was used."
  (harness-ui-call
   "_harness/session/get" (list :id sid)
   (lambda (session)
     (let ((idle (equal (format "%s" (plist-get session :status)) "idle")))
       (if (and idle
                (equal (plist-get session :head) (plist-get session :fork-node))
                (null (plist-get session :queue)))
           (harness-ui-call "_harness/session/delete" (list :id sid)
                            (lambda (_) (when (buffer-live-p buffer) (kill-buffer buffer))))
         (when idle (harness-ui-call "_harness/session/deactivate" (list :id sid) #'ignore))
         (when (buffer-live-p buffer)
           (with-current-buffer buffer (harness-ui-btw-minor-mode -1))))))))

(defun harness-ui-btw-promote ()
  "Keep this BTW: show it as a normal session instead of a side window.
It takes the position of the buffer it was opened over."
  (interactive)
  (let* ((sid harness-ui-session-id)
         (over (gethash sid harness-ui-btw--open))
         (position (and (buffer-live-p over) (buffer-local-value 'harness-ui-position over)))
         (win (selected-window)))
    (remhash sid harness-ui-btw--open)
    (harness-ui-btw-minor-mode -1)
    (when (window-parameter win 'window-side)
      (delete-window win))
    (harness-ui-display-session sid (and (not (eq position 'btw)) position))))

(defvar harness-ui-btw-minor-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-k") #'harness-ui-btw-close)
    (define-key map (kbd "C-c C-o") #'harness-ui-btw-promote)
    map))

(defun harness-ui-btw--header ()
  "The header line of a BTW window."
  (list (propertize " BTW " 'face 'harness-label-face)
        (propertize (or harness-ui-btw--label "side conversation") 'face 'harness-dim-face)
        "  "
        (propertize "[close]" 'face 'button 'mouse-face 'highlight
                    'help-echo "Close and go back to where it was opened (C-c C-k)"
                    'local-map (harness-ui-mouse-keymap #'harness-ui-btw-close))
        " "
        (propertize "[keep]" 'face 'button 'mouse-face 'highlight
                    'help-echo "Keep it as a normal session window (C-c C-o)"
                    'local-map (harness-ui-mouse-keymap #'harness-ui-btw-promote))))

(define-minor-mode harness-ui-btw-minor-mode
  "Minor mode active in BTW side conversation buffers."
  :lighter " BTW" :keymap harness-ui-btw-minor-mode-map
  (if harness-ui-btw-minor-mode
      (progn
        (unless harness-ui-btw--saved-header
          (setq harness-ui-btw--saved-header (list header-line-format)))
        (setq-local header-line-format (harness-ui-btw--header))
        (setq-local harness-chat-placeholder harness-ui-btw--hint))
    ;; Back to the session's own header and hint, as a kept BTW is a normal session.
    (when harness-ui-btw--saved-header
      (setq-local header-line-format (car harness-ui-btw--saved-header))
      (setq harness-ui-btw--saved-header nil))
    (kill-local-variable 'harness-chat-placeholder))
  (harness-compose-update-placeholder))

;; Its keys in the harness menu.  They beat the chat's own `C-c C-k'
;; there, in the menu as in the buffer.
(put 'harness-ui-btw-minor-mode 'harness-menu-group
     '("BTW"
       ["Side conversation"
        ("C-c C-k" "Close" harness-ui-btw-close)
        ("C-c C-o" "Keep as session" harness-ui-btw-promote)]))

(defun harness-ui-btw--init ()
  "Bind `harness-btw' in `harness-ui-map'."
  (define-key harness-ui-map (kbd "b") #'harness-btw))

(harness-define-module 'ui-btw
  :doc "BTW side conversations over the current session or view."
  :requires '(ui)
  :init #'harness-ui-btw--init)

(provide 'harness-ui-btw)
;;; harness-ui-btw.el ends here
