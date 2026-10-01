;;; harness-ui-btw.el --- BTW side conversations  -*- lexical-binding: t; -*-

;;; Commentary:

;; A "by the way" conversation is a fork of the current session opened
;; in a side window over it, so a quick question can be asked and
;; answered without leaving the main session or losing its output.
;; Closing the side window returns to the main session untouched.  BTW
;; sessions are ordinary forks and show up in the session list and the
;; conversation tree.
;;
;; A view without a session of its own can host BTWs too: it sets
;; `harness-ui-btw-start-function' to start a conversation about itself
;; and `harness-ui-btw-about' to say what that is.  The task board does,
;; so a BTW over it asks how the tasks are going.

;;; Code:

(require 'cl-lib)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)

(defgroup harness-ui-btw nil
  "BTW side conversations." :group 'harness-ui)

(defcustom harness-ui-btw-window-parameters
  '((side . bottom) (slot . 1) (window-height . 0.35) (preserve-size . (nil . t)))
  "Where the BTW window appears."
  :type 'sexp :group 'harness-ui-btw)

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
The question prompt and the BTW window's header say it.")

(defvar-local harness-ui-btw--label nil
  "What the header of this BTW buffer calls the conversation.")

(defvar-local harness-ui-btw--saved-header nil
  "(HEADER) this buffer had before it showed a BTW, or nil.")

;;;###autoload
(defun harness-btw (&optional session-id question)
  "Open a BTW side conversation and ask QUESTION.
It forks SESSION-ID, by default the current buffer's session.  Over a
view that starts its own conversations (`harness-ui-btw-start-function'),
such as the task board, it is a new conversation about that view."
  (interactive (list nil (read-string (if harness-ui-btw-about
                                           (format "BTW about %s: " harness-ui-btw-about)
                                         "BTW: "))))
  (let* ((over (current-buffer))
         (start (and (null session-id) harness-ui-btw-start-function))
         (label (if (and start harness-ui-btw-about)
                    (format "about %s" harness-ui-btw-about)
                  "side conversation"))
         (name (format "btw: %s" (harness-truncate-end (or question "") 40))))
    (harness-then
     (if start
         (funcall start name)
       (harness-ui-request "_harness/session/fork"
                           (list :id (or session-id (harness-ui-current-session-id)) :kind "btw" :name name)))
     (lambda (child) (harness-ui-btw--show (plist-get child :id) over label question))
     (lambda (e) (message "BTW failed: %s" (harness-error-message e)) nil))))

(defun harness-ui-btw--show (id over label question)
  "Show BTW session ID in a side window over buffer OVER and ask QUESTION.
LABEL is what its header calls the conversation."
  (puthash id over harness-ui-btw--open)
  (harness-ui-refresh-sessions
   (lambda (_)
     (unless harness-ui-open-session-function (user-error "No chat module loaded"))
     (let ((buf (funcall harness-ui-open-session-function id)))
       (select-window (display-buffer-in-side-window buf harness-ui-btw-window-parameters))
       (with-current-buffer buf
         (setq-local harness-ui-position 'btw)
         (setq harness-ui-btw--label label)
         (harness-ui-btw-minor-mode 1))
       (when (and question (not (string-empty-p question)))
         (harness-ui-call "session/prompt"
                          (list :sessionId id :prompt (list (list :type "text" :text question)))
                          #'ignore))))))

(defun harness-ui-btw-close ()
  "Close this BTW window and return to the buffer it was opened over.
An idle conversation is closed as a session too, so it no longer
counts as waiting for direction; it stays in the session list and can
be resumed.  One still working carries on in the background."
  (interactive)
  (let ((sid harness-ui-session-id)
        (over (gethash harness-ui-session-id harness-ui-btw--open))
        (win (selected-window)))
    (remhash sid harness-ui-btw--open)
    (when (and sid (equal (format "%s" (plist-get (harness-ui-session sid) :status)) "idle"))
      (harness-ui-call "_harness/session/deactivate" (list :id sid) #'ignore))
    (when (window-parameter win 'window-side)
      (delete-window win))
    (when-let* ((back (and (buffer-live-p over) (get-buffer-window over))))
      (select-window back))))

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
        (setq-local header-line-format (harness-ui-btw--header)))
    ;; Back to the session's own header, as a kept BTW is a normal session.
    (when harness-ui-btw--saved-header
      (setq-local header-line-format (car harness-ui-btw--saved-header))
      (setq harness-ui-btw--saved-header nil))))

;; Its keys in the harness menu.  They beat the chat's own `C-c C-k'
;; there, in the menu as in the buffer.
(put 'harness-ui-btw-minor-mode 'harness-menu-group
     '("BTW"
       ["Side conversation"
        ("C-c C-k" "Close" harness-ui-btw-close)
        ("C-c C-o" "Keep as session" harness-ui-btw-promote)]))

(defun harness-ui-btw--init ()
  (define-key harness-ui-map (kbd "b") #'harness-btw))

(harness-define-module 'ui-btw
  :doc "BTW side conversations over the current session or view."
  :requires '(ui)
  :init #'harness-ui-btw--init)

(provide 'harness-ui-btw)
;;; harness-ui-btw.el ends here
