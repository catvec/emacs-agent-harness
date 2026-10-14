;;; harness-ui-handoff.el --- The handoff banner of a model switch  -*- lexical-binding: t; -*-

;;; Commentary:

;; The UI half of the handoff module (harness-handoff.el), which loads
;; with it.
;;
;; A switch to a model that keeps its own conversation (Claude Code,
;; Copilot) starts a new conversation there, so the harness asks how to
;; hand the old one over.  The question shows as a banner above the
;; session's compose box -- a chat panel, as the review banner is -- with
;; what the switch costs and a button for every way to hand over:
;; summarise on the current model, have the new model summarise a limited
;; context, hand the whole transcript over as a file, switch without a
;; handoff, or cancel.
;;
;; Summarising on the current model is the cheap choice while that
;; model's prompt cache is warm, as it reads the conversation back from
;; it; once the cache lapsed (or is another model's) it reads all of it
;; again uncached, and the option says so instead (see
;; `harness-ui--handoff-choices-for').  The cache panel
;; (harness-ui-cache.el) stays away while the banner asks, and draws the
;; tail again when the cache lapses, which brings the banner up to date.
;;
;; The banner's options work as a question's do: each names its key, the
;; keys answer while point is on the banner, and a click answers from
;; anywhere.  In the compose box the keys type; C-c . and a key press it
;; on the banner from there (`harness-compose-panel-key'), which the
;; banner's last line says.  Choosing runs `handoff/switch'
;; (`handoff/switch-all' for a batch) through the UI connection, and the
;; banner goes away.  A batch names the sessions that lose their
;; conversation and says how many change in all.
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
(declare-function harness-compose-panel-hint "harness-ui-compose" (key))

(defgroup harness-ui-handoff nil
  "Choosing how to hand a conversation over when the model changes."
  :group 'harness-ui)

(defface harness-chat-switch-face
  '((((background light)) :background "#fff3d6" :extend t)
    (((background dark)) :background "#3a3117" :extend t))
  "Background of the switch banner: a model switch waiting for your choice."
  :group 'harness-ui-handoff)

(defvar-local harness-ui-handoff--prompt nil
  "The switch waiting to be answered in this buffer, or nil.
A plist (:checks CHECKS :label LABEL :total N :session SID :callback FN).")

;;;; Where the banner shows

(defun harness-ui-handoff--chat-buffer (sid)
  "Return the live chat buffer of session SID, or nil."
  (and (fboundp 'harness-chat--buffer-for) (harness-chat--buffer-for sid)))

(defun harness-ui-handoff--host (session host)
  "Return the chat buffer to show a switch banner in, or nil.
SESSION's own chat buffer serves; for a switch of many (SESSION nil)
the HOST the command ran in does."
  (or (and session (harness-ui-handoff--chat-buffer session))
      (and (buffer-live-p host) host)))

(defun harness-ui-handoff--redraw ()
  "Draw the tail of this chat buffer again."
  (when (functionp harness-compose-redraw-function)
    (funcall harness-compose-redraw-function)))

(defun harness-ui-handoff--banner-pos ()
  "Return where the switch banner starts in this buffer, or nil."
  (text-property-any (point-min) (point-max) 'harness-ui-handoff-panel t))

(defun harness-ui-handoff--focus ()
  "Put point on the switch banner when this buffer shows, so its keys work."
  (when-let* ((pos (harness-ui-handoff--banner-pos)))
    (when (get-buffer-window (current-buffer))
      (goto-char pos))))

(defun harness-ui-handoff--ask (checks label total session host callback)
  "Ask how to hand over: show a banner, or ask in the minibuffer.
See `harness-ui-switch-function' for CHECKS, LABEL, TOTAL, SESSION, HOST
and CALLBACK.  The banner shows in SESSION's chat buffer, else in HOST;
without either, the minibuffer asks."
  (let ((target (harness-ui-handoff--host session host)))
    (if (null target)
        (funcall callback (harness-ui--read-handoff checks label total))
      (with-current-buffer target
        (setq harness-ui-handoff--prompt
              (list :checks checks :label label :total (or total (length checks))
                    :session session :callback callback))
        (harness-ui-handoff--redraw)
        (harness-ui-handoff--focus)
        (unless (get-buffer-window target)
          (message "How to hand over: choose in %s" (buffer-name target))))
      t)))

;;;; Answering

(defun harness-ui-handoff--choose (buffer prompt mode)
  "Answer the switch PROMPT shown in BUFFER with MODE, running its callback."
  (let ((current nil))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (eq harness-ui-handoff--prompt prompt)
          (setq current t)
          (setq harness-ui-handoff--prompt nil)
          (harness-ui-handoff--redraw))))
    (when current
      (funcall (plist-get prompt :callback) mode))))

(defun harness-ui-handoff--command (buffer prompt mode)
  "Return the command answering PROMPT in BUFFER with MODE."
  (lambda () (interactive) (harness-ui-handoff--choose buffer prompt mode)))

(defun harness-ui-handoff--keymap (buffer prompt)
  "Return a keymap whose keys answer PROMPT in BUFFER."
  (let ((map (make-sparse-keymap)))
    (dolist (choice harness-ui--handoff-choices)
      (define-key map (kbd (char-to-string (nth 0 choice)))
                  (harness-ui-handoff--command buffer prompt (nth 2 choice))))
    map))

;;;; The banner

(defun harness-ui-handoff--heading (prompt)
  "Return the heading of the switch banner: what switches to what.
PROMPT is the switch it asks about, as `harness-ui-handoff--prompt' holds it."
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

(defun harness-ui-handoff--rows (rows)
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

(defun harness-ui-handoff--risk-row (risk)
  "Return RISK, a \"label: what it means\" sentence, as banner row cells."
  (let ((colon (string-match ":" risk)))
    (if colon
        (list (substring risk 0 colon) (string-trim (substring risk (1+ colon))))
      (list risk ""))))

(defun harness-ui-handoff--facts (prompt)
  "Return the labelled facts of the switch banner for PROMPT."
  (let* ((checks (plist-get prompt :checks))
         (first (car checks))
         (total (plist-get prompt :total))
         (running (cl-some (lambda (c) (harness-json-true-p (plist-get c :running))) checks)))
    (append
     (mapcar #'harness-ui-handoff--risk-row (plist-get first :risks))
     (when (plist-get first :cache-cost)
       (list (list "Cost" (format "%s (list prices)" (plist-get first :cache-cost)))))
     (when running
       (list (list "Turn" "running; it finishes its current step first")))
     (when (> total 1)
       (list (list "Sessions" (format "%s (%d of %d change)"
                                      (mapconcat #'harness-ui--check-session-label checks
                                                 " · ")
                                      (length checks) total)))))))

(defun harness-ui-handoff--options (buffer prompt)
  "Return the options of the switch banner for PROMPT, answered in BUFFER.
Each names its key, so the banner answers like a question's options.
Summarising on the current model says whether its cache is still warm
\(`harness-ui--handoff-choices-for'), as of when the banner is drawn:
the cache panel draws it again the moment the cache lapses."
  (let* ((choices (harness-ui--handoff-choices-for (plist-get prompt :checks)))
         (width (apply #'max (mapcar (lambda (c) (string-width (nth 1 c))) choices))))
    (mapconcat
     (lambda (choice)
       (let* ((key (nth 0 choice))
              (name (nth 1 choice))
              (prefix (concat "   " (harness-chat--kbd (format " %c " key)) " "))
              (indent (make-string (+ (length prefix) width 2) ?\s)))
         (concat prefix
                 (harness-chat--button name (harness-ui-handoff--command buffer prompt (nth 2 choice))
                                       :help (format "%s (press %c, or click)" (nth 3 choice) key))
                 (make-string (max 0 (- width (string-width name))) ?\s)
                 "  "
                 (propertize (nth 3 choice) 'face 'harness-dim-face 'wrap-prefix indent)
                 "\n")))
     choices)))

(defun harness-ui-handoff--box-hint ()
  "Return the line saying how to press an option's key from the compose box.
The options' keys type in the box: its key for a panel's keys does what
they do (`harness-compose-panel-hint'), the first option's key the
example."
  (propertize (concat "   " (harness-compose-panel-hint (char-to-string (car (car harness-ui--handoff-choices))))
                      "\n")
              'wrap-prefix "   "))

(defun harness-ui-handoff--banner (prompt)
  "Return the banner asking how to hand over, as PROMPT says."
  (let* ((buffer (current-buffer))
         (first (car (plist-get prompt :checks)))
         (string (concat
                  (harness-ui-handoff--heading prompt)
                  (propertize (concat "   " (plist-get first :reason))
                              'face 'harness-dim-face 'wrap-prefix "   ")
                  "\n"
                  (harness-ui-handoff--rows (harness-ui-handoff--facts prompt))
                  "\n"
                  (harness-ui-handoff--options buffer prompt)
                  (harness-ui-handoff--box-hint))))
    ;; A panel of the compose box too: C-c . presses its keys from there.
    (add-text-properties 0 (length string) (list 'harness-ui-handoff-panel t 'harness-compose-panel 'switch)
                         string)
    (harness-ui-with-keymap string (harness-ui-handoff--keymap buffer prompt))
    (harness-chat--face string 'harness-chat-switch-face)))

(defun harness-ui-handoff--panel ()
  "Return the switch banner when this buffer waits for its answer."
  (when harness-ui-handoff--prompt
    (harness-ui-handoff--banner harness-ui-handoff--prompt)))

;;;; Setup

(defun harness-ui-handoff--setup ()
  "Show the switch banner in this chat buffer."
  (add-hook 'harness-chat-panel-functions #'harness-ui-handoff--panel t))

(defun harness-ui-handoff--init ()
  "Let the UI show its switch question as a banner in the chat."
  (setq harness-ui-switch-function #'harness-ui-handoff--ask)
  (with-eval-after-load 'harness-ui-chat
    (add-hook 'harness-chat-mode-hook #'harness-ui-handoff--setup)))

(harness-define-module 'ui-handoff
  :doc "The switch banner of a session: choose how to hand the conversation over."
  :requires '(ui ui-chat)
  :init #'harness-ui-handoff--init)

(provide 'harness-ui-handoff)
;;; harness-ui-handoff.el ends here
