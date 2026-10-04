;;; harness-ui-switch.el --- The switch banner of a session  -*- lexical-binding: t; -*-

;;; Commentary:

;; A switch to a model that keeps its own conversation (Claude Code,
;; Copilot) starts a new conversation there, so the harness asks how to
;; hand the old one over.  The question shows as a banner above the
;; session's compose box -- a chat panel, as the review banner is -- with
;; what the switch costs and a button for every way to hand over:
;; summarise on the current model, have the new model summarise a limited
;; context, hand the whole transcript over as a file, switch without a
;; handoff, or cancel.
;;
;; The banner's options work as a question's do: each names its key, the
;; keys answer while point is on the banner, and a click answers from
;; anywhere.  Choosing runs `handoff/switch' (`handoff/switch-all' for a
;; batch) through the UI connection, and the banner goes away.  A batch
;; names the sessions that lose their conversation and says how many
;; change in all.
;;
;; A harness with no chat buffer to show (a switch asked for outside the
;; UI, or over ACP) cannot use the banner; the minibuffer question of
;; `harness-ui--read-handoff' asks instead (see
;; `harness-ui-switch-function').

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)

(defvar harness-chat-panel-functions)
(defvar harness-chat-mode-hook)
(defvar harness-ui-session-id)
(defvar harness-compose-redraw-function)
(declare-function harness-chat--button "harness-ui-chat" (label action &rest props))
(declare-function harness-chat--kbd "harness-ui-chat" (key))
(declare-function harness-chat--face "harness-ui-chat" (string face))
(declare-function harness-chat--buffer-for "harness-ui-chat" (sid))

(defgroup harness-ui-switch nil
  "Choosing how to hand a conversation over when the model changes."
  :group 'harness-ui)

(defface harness-chat-switch-face
  '((((background light)) :background "#fff3d6" :extend t)
    (((background dark)) :background "#3a3117" :extend t))
  "Background of the switch banner: a model switch waiting for your choice."
  :group 'harness-ui-switch)

(defvar-local harness-ui-switch--prompt nil
  "The switch waiting to be answered in this buffer, or nil.
A plist (:checks CHECKS :label LABEL :total N :session SID :callback FN).")

;;;; Where the banner shows

(defun harness-ui-switch--chat-buffer (sid)
  "Return the live chat buffer of session SID, or nil."
  (and (fboundp 'harness-chat--buffer-for) (harness-chat--buffer-for sid)))

(defun harness-ui-switch--host (session host)
  "Return the chat buffer to show a switch banner in, or nil.
SESSION's own chat buffer serves; for a switch of many (SESSION nil)
the HOST the command ran in does."
  (or (and session (harness-ui-switch--chat-buffer session))
      (and (buffer-live-p host) host)))

(defun harness-ui-switch--redraw ()
  "Draw the tail of this chat buffer again."
  (when (functionp harness-compose-redraw-function)
    (funcall harness-compose-redraw-function)))

(defun harness-ui-switch--banner-pos ()
  "Return where the switch banner starts in this buffer, or nil."
  (text-property-any (point-min) (point-max) 'harness-ui-switch-panel t))

(defun harness-ui-switch--focus ()
  "Put point on the switch banner when this buffer shows, so its keys work."
  (when-let* ((pos (harness-ui-switch--banner-pos)))
    (when (get-buffer-window (current-buffer))
      (goto-char pos))))

(defun harness-ui-switch--ask (checks label total session host callback)
  "Ask how to hand over: show a banner, or ask in the minibuffer.
See `harness-ui-switch-function'."
  (let ((target (harness-ui-switch--host session host)))
    (if (null target)
        (funcall callback (harness-ui--read-handoff checks label total))
      (with-current-buffer target
        (setq harness-ui-switch--prompt
              (list :checks checks :label label :total (or total (length checks))
                    :session session :callback callback))
        (harness-ui-switch--redraw)
        (harness-ui-switch--focus)
        (unless (get-buffer-window target)
          (message "How to hand over: choose in %s" (buffer-name target))))
      t)))

;;;; Answering

(defun harness-ui-switch--choose (buffer prompt mode)
  "Answer the switch PROMPT shown in BUFFER with MODE, running its callback."
  (let ((current nil))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (eq harness-ui-switch--prompt prompt)
          (setq current t)
          (setq harness-ui-switch--prompt nil)
          (harness-ui-switch--redraw))))
    (when current
      (funcall (plist-get prompt :callback) mode))))

(defun harness-ui-switch--command (buffer prompt mode)
  "Return the command answering PROMPT in BUFFER with MODE."
  (lambda () (interactive) (harness-ui-switch--choose buffer prompt mode)))

(defun harness-ui-switch--keymap (buffer prompt)
  "Return a keymap whose keys answer PROMPT in BUFFER."
  (let ((map (make-sparse-keymap)))
    (dolist (choice harness-ui--handoff-choices)
      (define-key map (kbd (char-to-string (nth 0 choice)))
                  (harness-ui-switch--command buffer prompt (nth 2 choice))))
    map))

(defun harness-ui-switch--with-keymap (string map)
  "Return STRING with MAP answering under the keymaps it already carries.
A button's own keymap stays in front, so a click still answers with it."
  (let ((pos 0)
        (len (length string)))
    (while (< pos len)
      (let* ((next (or (next-single-property-change pos 'keymap string len) len))
             (existing (get-text-property pos 'keymap string)))
        (put-text-property pos next 'keymap
                           (if existing (make-composed-keymap (list existing map)) map)
                           string)
        (setq pos next))))
  string)

;;;; The banner

(defun harness-ui-switch--heading (prompt)
  "Return the heading of the switch banner: what switches to what."
  (let* ((first (car (plist-get prompt :checks)))
         (total (plist-get prompt :total))
         (from (or (plist-get first :from-label)
                   (harness-ui-model-label (plist-get first :from)))))
    (concat
     " " (propertize (concat (harness-ui-icon 'harness-icon-system) " Switch model")
                     'face 'harness-label-face)
     "  "
     (propertize (if (= 1 total)
                     (format "%s → %s" from (plist-get prompt :label))
                   (format "%d sessions → %s" total (plist-get prompt :label)))
                 'face 'bold)
     "\n")))

(defun harness-ui-switch--rows (rows)
  "Return ROWS, a list of (LABEL TEXT), as aligned banner lines.
The labels are padded to their widest, and a long TEXT wraps under
itself, not under its label."
  (let* ((width (apply #'max 0 (mapcar (lambda (row) (string-width (car row))) rows)))
         (format-string (format "   %%-%ds  " width)))
    (mapconcat
     (lambda (row)
       (let* ((prefix (format format-string (propertize (car row) 'face 'harness-label-face)))
              (indent (make-string (length prefix) ?\s)))
         (concat prefix
                 (propertize (cadr row) 'face 'harness-dim-face 'wrap-prefix indent)
                 "\n")))
     rows "")))

(defun harness-ui-switch--risk-row (risk)
  "Return RISK, a \"label: what it means\" sentence, as banner row cells."
  (let ((colon (string-match ":" risk)))
    (if colon
        (list (substring risk 0 colon) (string-trim (substring risk (1+ colon))))
      (list risk ""))))

(defun harness-ui-switch--facts (prompt)
  "Return the labelled facts of the switch banner for PROMPT."
  (let* ((checks (plist-get prompt :checks))
         (first (car checks))
         (total (plist-get prompt :total))
         (running (cl-some (lambda (c) (harness-json-true-p (plist-get c :running))) checks)))
    (append
     (mapcar #'harness-ui-switch--risk-row (plist-get first :risks))
     (when (plist-get first :cache-cost)
       (list (list "Cost" (format "%s (list prices)" (plist-get first :cache-cost)))))
     (when running
       (list (list "Turn" "running; it finishes its current step first")))
     (when (> total 1)
       (list (list "Sessions" (format "%s (%d of %d change)"
                                      (mapconcat #'harness-ui--check-session-label checks
                                                 " · ")
                                      (length checks) total)))))))

(defun harness-ui-switch--options (buffer prompt)
  "Return the options of the switch banner for PROMPT, answered in BUFFER.
Each names its key, so the banner answers like a question's options."
  (let* ((choices harness-ui--handoff-choices)
         (width (apply #'max (mapcar (lambda (c) (string-width (nth 1 c))) choices))))
    (mapconcat
     (lambda (choice)
       (let* ((key (nth 0 choice))
              (name (nth 1 choice))
              (prefix (concat "   " (harness-chat--kbd (format " %c " key)) " "))
              (indent (make-string (+ (length prefix) width 2) ?\s)))
         (concat prefix
                 (harness-chat--button name (harness-ui-switch--command buffer prompt (nth 2 choice))
                                       :help (format "%s (press %c, or click)" (nth 3 choice) key))
                 (make-string (max 0 (- width (string-width name))) ?\s)
                 "  "
                 (propertize (nth 3 choice) 'face 'harness-dim-face 'wrap-prefix indent)
                 "\n")))
     choices)))

(defun harness-ui-switch--banner (prompt)
  "Return the banner asking how to hand over, as PROMPT says."
  (let* ((buffer (current-buffer))
         (first (car (plist-get prompt :checks)))
         (string (concat
                  (harness-ui-switch--heading prompt)
                  (propertize (concat "   " (plist-get first :reason))
                              'face 'harness-dim-face 'wrap-prefix "   ")
                  "\n"
                  (harness-ui-switch--rows (harness-ui-switch--facts prompt))
                  "\n"
                  (harness-ui-switch--options buffer prompt))))
    (add-text-properties 0 (length string) (list 'harness-ui-switch-panel t) string)
    (harness-ui-switch--with-keymap string (harness-ui-switch--keymap buffer prompt))
    (harness-chat--face string 'harness-chat-switch-face)))

(defun harness-ui-switch--panel ()
  "Return the switch banner when this buffer waits for its answer."
  (when harness-ui-switch--prompt
    (harness-ui-switch--banner harness-ui-switch--prompt)))

;;;; Setup

(defun harness-ui-switch--setup ()
  "Show the switch banner in this chat buffer."
  (add-hook 'harness-chat-panel-functions #'harness-ui-switch--panel t))

(defun harness-ui-switch--init ()
  "Let the UI show its switch question as a banner in the chat."
  (setq harness-ui-switch-function #'harness-ui-switch--ask)
  (with-eval-after-load 'harness-ui-chat
    (add-hook 'harness-chat-mode-hook #'harness-ui-switch--setup)))

(harness-define-module 'ui-switch
  :doc "The switch banner of a session: choose how to hand the conversation over."
  :requires '(ui ui-chat)
  :init #'harness-ui-switch--init)

(provide 'harness-ui-switch)
;;; harness-ui-switch.el ends here
