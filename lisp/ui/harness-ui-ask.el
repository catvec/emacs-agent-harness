;;; harness-ui-ask.el --- Approval and question panels -*- lexical-binding: t; -*-

;; This file is part of Emacs Agent Harness.

;;; Commentary:

;; When the harness needs a decision, this module shows a small, focused
;; panel in a bottom side window: no mode line, a one-line context header,
;; the essential details, and buttons with keyboard letters.  Answering is
;; one keystroke or one click; the panel disappears and the turn resumes.
;; Pending decisions queue, so two agents asking at once never collide.

;;; Code:

(require 'button)
(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'harness-core)
(require 'harness-ui)

(defgroup harness-ui-ask nil
  "Approval and question panels."
  :group 'harness-ui)

(defcustom harness-ui-ask-position 'bottom
  "Side used for the approval panel."
  :type '(choice (const bottom) (const right)))

(defcustom harness-ui-ask-auto-answer nil
  "When non-nil, auto-answer allow-once instead of showing the panel."
  :type 'boolean)

(defface harness-ui-ask-title-face
  '((t :inherit bold :height 1.1))
  "Face for the panel's title."
  :group 'harness-ui-ask)

(defface harness-ui-ask-key-face
  '((t :inherit shadow))
  "Face for keyboard hints."
  :group 'harness-ui-ask)

(defface harness-ui-ask-reason-face
  '((t :inherit shadow :slant italic))
  "Face for the harness' reason."
  :group 'harness-ui-ask)

(defface harness-ui-ask-args-face
  '((t :inherit fixed-pitch :background "grey95" :extend t))
  "Face for tool arguments."
  :group 'harness-ui-ask)

(defvar harness-ui-ask--queue nil
  "Pending requests, oldest first.")

(defvar harness-ui-ask--current nil
  "The request shown in the panel.")

(defvar-local harness-ui-ask--answer-start nil
  "Marker where a free-form answer begins.")

(defun harness-ui-ask--digit (n)
  "Answer the current question with option N, when there is one."
  (let* ((options (append (plist-get harness-ui-ask--current :options) nil))
         (answer (nth (1- n) options)))
    (when answer (harness-ui-ask-answer answer))))

(defvar harness-ui-ask-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "y") (lambda () (interactive) (harness-ui-ask-answer "allow-once")))
    (define-key map (kbd "a") (lambda () (interactive) (harness-ui-ask-answer "allow-always")))
    (define-key map (kbd "n") (lambda () (interactive) (harness-ui-ask-answer "reject-once")))
    (define-key map (kbd "N") (lambda () (interactive) (harness-ui-ask-answer "reject-always")))
    (define-key map (kbd "C-g") #'harness-ui-ask-cancel)
    (define-key map (kbd "q") #'harness-ui-ask-cancel)
    (define-key map (kbd "TAB") #'forward-button)
    (define-key map (kbd "<backtab>") #'backward-button)
    (define-key map (kbd "RET") #'harness-ui-ask-press)
    (dotimes (digit 9)
      (let ((n (1+ digit)))
        (define-key map (number-to-string n)
                    (lambda () (interactive) (harness-ui-ask--digit n)))))
    map)
  "Keymap for `harness-ui-ask-mode'.")

(define-derived-mode harness-ui-ask-mode special-mode "Harness-Ask"
  "Major mode for approval and question panels."
  :group 'harness-ui-ask
  (setq-local mode-line-format nil)
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (setq-local buffer-read-only nil))

;;; The panel

(defun harness-ui-ask--buffer ()
  "Return the panel buffer."
  (get-buffer-create "*harness-approval*"))

(defun harness-ui-ask--insert (string &rest properties)
  "Insert STRING with PROPERTIES."
  (insert (apply #'propertize string properties)))

(defun harness-ui-ask--button (label hint callback)
  "Insert a button LABEL with keyboard HINT calling CALLBACK."
  (insert-text-button label
                      'action (lambda (_button) (funcall callback))
                      'follow-link t
                      'mouse-face 'highlight
                      'help-echo (format "Click or press %s" hint))
  (insert (propertize (format "  %s\n" hint) 'face 'harness-ui-ask-key-face)))

(defun harness-ui-ask--render-permission (request)
  "Render a permission REQUEST."
  (let* ((tool-call (plist-get request :tool-call))
         (content (plist-get tool-call :content))
         (reason (or (and (vectorp content)
                          (plist-get (plist-get (aref content 0) :content) :text))
                     (plist-get tool-call :title)))
         (args (plist-get tool-call :rawInput)))
    (harness-ui-ask--insert "Approval needed\n" 'face 'harness-ui-ask-title-face)
    (harness-ui-ask--insert (format "%s\n\n" (or (plist-get tool-call :title) "Tool call"))
                            'face 'default)
    (when (and args (not (equal args (make-hash-table))))
      (harness-ui-ask--insert
       (format "%s\n\n" (truncate-string-to-width
                          (or (ignore-errors (harness-json-serialize args)) (format "%S" args))
                          200 nil nil "…"))
       'face 'harness-ui-ask-args-face))
    (when reason
      (harness-ui-ask--insert (format "%s\n\n" reason) 'face 'harness-ui-ask-reason-face))
    (harness-ui-ask--button "Allow once" "y" (lambda () (harness-ui-ask-answer "allow-once")))
    (harness-ui-ask--button "Always allow this session" "a"
                            (lambda () (harness-ui-ask-answer "allow-always")))
    (harness-ui-ask--button "Reject" "n" (lambda () (harness-ui-ask-answer "reject-once")))
    (harness-ui-ask--button "Always reject this session" "N"
                            (lambda () (harness-ui-ask-answer "reject-always")))))

(defun harness-ui-ask--render-question (request)
  "Render a question REQUEST."
  (harness-ui-ask--insert "Question\n" 'face 'harness-ui-ask-title-face)
  (harness-ui-ask--insert (format "%s\n\n" (plist-get request :question)) 'face 'default)
  (let ((options (append (plist-get request :options) nil))
        (index 0))
    (dolist (option options)
      (let ((i (cl-incf index)))
        (harness-ui-ask--button (format "%d. %s" i option)
                                (number-to-string i)
                                (lambda () (harness-ui-ask-answer (nth (1- i) options)))))))
  (harness-ui-ask--insert "\nRET submits, C-g cancels\n" 'face 'harness-ui-ask-key-face)
  (when (plist-get request :freeform)
    (harness-ui-ask--insert "Answer: " 'face 'harness-ui-ask-key-face)
    (setq-local harness-ui-ask--answer-start (copy-marker (point)))))

(defun harness-ui-ask--render (request)
  "Render REQUEST in the panel buffer."
  (with-current-buffer (harness-ui-ask--buffer)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (harness-ui-ask-mode)
      (pcase (plist-get request :kind)
        ('permission (harness-ui-ask--render-permission request))
        ('question (harness-ui-ask--render-question request)))
      (when (> (length harness-ui-ask--queue) 1)
        (harness-ui-ask--insert (format "\n%d more waiting\n" (1- (length harness-ui-ask--queue)))
                                'face 'harness-ui-ask-key-face))
      (goto-char (point-min))
      (ignore-errors (forward-button 1 t)))
    (harness-ui-ask--display)))

(defun harness-ui-ask--display ()
  "Show the panel in a side window sized to its content."
  (let* ((buffer (harness-ui-ask--buffer))
         (window (display-buffer
                  buffer
                  `((display-buffer-in-side-window)
                    (side . ,harness-ui-ask-position)
                    (window-height . fit-window-to-buffer)
                    (preserve-size . (nil . t))))))
    (when (window-live-p window)
      (with-selected-window window
        (fit-window-to-buffer nil nil 4 3)
        (goto-char (point-min))))))

;;; Answering

(defun harness-ui-ask--pop ()
  "Remove the current request and show the next one, if any."
  (setq harness-ui-ask--queue (delq harness-ui-ask--current harness-ui-ask--queue)
        harness-ui-ask--current nil)
  (let ((buffer (harness-ui-ask--buffer)))
    (when-let* ((window (get-buffer-window buffer t)))
      (ignore-errors (delete-window window)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((inhibit-read-only t)) (erase-buffer)))))
  (when harness-ui-ask--queue
    (setq harness-ui-ask--current (car harness-ui-ask--queue))
    (harness-ui-ask--render harness-ui-ask--current)))

(defun harness-ui-ask-answer (value)
  "Answer the current request with VALUE."
  (interactive)
  (when harness-ui-ask--current
    (let ((request harness-ui-ask--current))
      (harness-ui-ask--pop)
      (funcall (plist-get request :respond) value))))

(defun harness-ui-ask-cancel ()
  "Cancel the current request (reject or no answer)."
  (interactive)
  (pcase (plist-get harness-ui-ask--current :kind)
    ('permission (harness-ui-ask-answer "reject-once"))
    ('question (harness-ui-ask-answer nil))))

(defun harness-ui-ask-press ()
  "Activate the button at point, or submit a free-form answer."
  (interactive)
  (if (and (bound-and-true-p harness-ui-ask--answer-start)
           (>= (point) (marker-position harness-ui-ask--answer-start))
           (plist-get harness-ui-ask--current :freeform))
      (let ((answer (string-trim
                     (buffer-substring-no-properties
                      (marker-position harness-ui-ask--answer-start) (point-max)))))
        (harness-ui-ask-answer (if (string-empty-p answer) nil answer)))
    (push-button (point))))

;;; Request handling

(defun harness-ui-ask--enqueue (request)
  "Add REQUEST to the queue; show it when nothing else is pending."
  (setq harness-ui-ask--queue (append harness-ui-ask--queue (list request)))
  (if harness-ui-ask--current
      ;; Already showing one: refresh so the waiting count is visible.
      (harness-ui-ask--render harness-ui-ask--current)
    (setq harness-ui-ask--current (car harness-ui-ask--queue))
    (harness-ui-ask--render harness-ui-ask--current)))

(defun harness-ui-ask--on-permission (payload)
  "Handle a `harness-ui-permission-request' PAYLOAD."
  (let ((request (list :kind 'permission
                       :session-id (plist-get payload :session-id)
                       :tool-call (plist-get payload :tool-call)
                       :options (plist-get payload :options)
                       :respond (lambda (option-id)
                                  (funcall (plist-get payload :respond) option-id)))))
    (if harness-ui-ask-auto-answer
        (funcall (plist-get request :respond) "allow-once")
      (harness-ui-ask--enqueue request))))

(defun harness-ui-ask--on-question (payload)
  "Handle a `harness-ui-question' PAYLOAD."
  (harness-ui-ask--enqueue
   (list :kind 'question
         :session-id (plist-get payload :session-id)
         :question (plist-get payload :question)
         :options (plist-get payload :options)
         :freeform (plist-get payload :freeform)
         :respond (plist-get payload :respond))))

(defun harness-ui-ask-setup ()
  "Set up the ask panels."
  (harness-event-define 'harness-ui-question
    :module 'harness-ui-ask
    :doc "The harness asks a question and waits for an answer."
    :payload '((session-id . string) (question . string) (options . vector)
               (freeform . boolean) (respond . function)))
  (harness-on 'harness-ui-permission-request #'harness-ui-ask--on-permission
              :module 'harness-ui-ask)
  (harness-on 'harness-ui-question #'harness-ui-ask--on-question
              :module 'harness-ui-ask))

(defun harness-ui-ask-teardown ()
  "Tear down the ask panels."
  (dolist (request harness-ui-ask--queue)
    (condition-case nil
        (funcall (plist-get request :respond)
                 (pcase (plist-get request :kind)
                   ('permission "reject-once")
                   ('question nil)))
      (error nil)))
  (setq harness-ui-ask--queue nil
        harness-ui-ask--current nil))

(harness-module-define 'harness-ui-ask
  :version harness-version
  :description "Focused approval and question panels."
  :requires '((harness-core "0.1.0")
              (harness-ui "0.1.0"))
  :provides '(harness-ui-ask)
  :setup #'harness-ui-ask-setup
  :teardown #'harness-ui-ask-teardown)

(provide 'harness-ui-ask)
;;; harness-ui-ask.el ends here
