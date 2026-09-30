;;; harness-ui-btw.el --- BTW side conversations  -*- lexical-binding: t; -*-

;;; Commentary:

;; A "by the way" conversation is a fork of the current session opened
;; in a side window over it, so a quick question can be asked and
;; answered without leaving the main session or losing its output.
;; Closing the side window returns to the main session untouched.  BTW
;; sessions are ordinary forks and show up in the session list and the
;; conversation tree.

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
  "BTW session id -> parent session id, for open side conversations.")

;;;###autoload
(defun harness-btw (&optional session-id question)
  "Open a BTW side conversation forked from SESSION-ID and ask QUESTION."
  (interactive (list nil (read-string "BTW: ")))
  (let ((parent (or session-id (harness-ui-current-session-id))))
    (harness-ui-call
     "_harness/session/fork" (list :id parent :kind "btw"
                                   :name (format "btw: %s" (harness-truncate-end (or question "") 40)))
     (lambda (child)
       (let ((cid (plist-get child :id)))
         (puthash cid parent harness-ui-btw--open)
         (harness-ui-refresh-sessions
          (lambda (_)
            (unless harness-ui-open-session-function (user-error "No chat module loaded"))
            (let ((buf (funcall harness-ui-open-session-function cid)))
              (select-window (display-buffer-in-side-window buf harness-ui-btw-window-parameters))
              (with-current-buffer buf
                (setq-local harness-ui-position 'btw)
                (harness-ui-btw-minor-mode 1))
              (when (and question (not (string-empty-p question)))
                (harness-ui-call "session/prompt"
                                 (list :sessionId cid :prompt (list (list :type "text" :text question)))
                                 #'ignore))))))))))

(defun harness-ui-btw-close ()
  "Close this BTW window and return to the main session."
  (interactive)
  (let ((sid harness-ui-session-id)
        (win (selected-window)))
    (remhash sid harness-ui-btw--open)
    (when (window-parameter win 'window-side)
      (delete-window win))
    (let ((parent (gethash sid harness-ui-btw--open)))
      (when parent (harness-ui-display-session parent)))))

(defun harness-ui-btw-promote ()
  "Turn this BTW window into a normal session window."
  (interactive)
  (let ((sid harness-ui-session-id))
    (remhash sid harness-ui-btw--open)
    (harness-ui-btw-minor-mode -1)
    (harness-ui-display-session sid)))

(defvar harness-ui-btw-minor-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-k") #'harness-ui-btw-close)
    (define-key map (kbd "C-c C-o") #'harness-ui-btw-promote)
    map))

(define-minor-mode harness-ui-btw-minor-mode
  "Minor mode active in BTW side conversation buffers."
  :lighter " BTW" :keymap harness-ui-btw-minor-mode-map
  (when harness-ui-btw-minor-mode
    (setq-local header-line-format
                (list (propertize " BTW " 'face 'harness-label-face)
                      (propertize "side conversation" 'face 'harness-dim-face)
                      "  "
                      (propertize "[close]" 'face 'button 'mouse-face 'highlight
                                  'help-echo "Close and return to the main session (C-c C-k)"
                                  'local-map (harness-ui-mouse-keymap #'harness-ui-btw-close))
                      " "
                      (propertize "[keep]" 'face 'button 'mouse-face 'highlight
                                  'help-echo "Promote to a normal session window (C-c C-o)"
                                  'local-map (harness-ui-mouse-keymap #'harness-ui-btw-promote))))))

(defun harness-ui-btw--init ()
  (define-key harness-ui-map (kbd "b") #'harness-btw))

(harness-define-module 'ui-btw
  :doc "BTW side conversations over the current session."
  :requires '(ui)
  :init #'harness-ui-btw--init)

(provide 'harness-ui-btw)
;;; harness-ui-btw.el ends here
