;;; harness-ui-ask.el --- ask_user_question tool and its UI -*- lexical-binding: t; -*-

;; Copyright (C) 2026 the emacs-agent-harness authors

;; Author: the emacs-agent-harness authors
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, ai
;; URL: https://git.sr.ht/~catvec/emacs-agent-harness

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; The `ask_user_question' tool lets the model ask something it cannot find
;; out on its own.  The UI is modelled on `customize': a real buffer, real
;; widgets (radio buttons, checkboxes, an editable field), a description area
;; and Submit/Cancel buttons -- rather than a minibuffer prompt, because the
;; question is part of the conversation and the user may want to read it, think
;; and switch buffers before answering.
;;
;; Like approvals, questions are asynchronous: the tool records a
;; `harness-approval' of kind `question' and returns.  Submitting resolves it,
;; which is what resumes the run.  A session waiting on a question reports
;; `awaiting-answer', so the browser and the mode line show it like any other
;; blocked session.
;;
;; See DESIGN.md section 9.2.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'widget)
(require 'wid-edit)
(require 'harness-core)
(require 'harness-session)
(require 'harness-tools)
(require 'harness-perms)
(require 'harness-faces)

(defcustom harness-ask-display-action
  '(display-buffer-at-bottom (window-height . 0.4))
  "`display-buffer' action for the question buffer."
  :type '(repeat sexp)
  :group 'harness-ui)

(defvar-local harness-ask--approval nil
  "Approval this buffer is answering.")

(defvar-local harness-ask--widgets nil
  "Widget per question, in order.")

(defvar harness-ask-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "C-c C-c") #'harness-ask-submit)
    (define-key map (kbd "C-c C-k") #'harness-ask-cancel)
    ;; `C-c C-A' is the same event as `C-c C-a' (control does not case-fold),
    ;; so "always" needs a key of its own.
    (define-key map (kbd "C-c C-y") #'harness-ask-approve-always)
    (define-key map (kbd "TAB") #'widget-forward)
    (define-key map (kbd "<backtab>") #'widget-backward)
    (define-key map (kbd "q") #'bury-buffer)
    map)
  "Keymap for `harness-ask-mode'.")

(defun harness-ask--header-line ()
  "Return the header line for the request being answered.
The keys are looked up live (see `harness-key-hints') so the prompt cannot
drift from the keymap."
  (let ((approval harness-ask--approval))
    (if (null approval)
        " Harness"
      (let ((name (harness-session-name (harness-approval-session approval))))
        (if (eq (harness-approval-kind approval) 'question)
            (concat
             (format " %s asks — " name)
             (harness-key-hints
              (list "move" #'widget-forward harness-ask-mode-map)
              (list "pick" #'widget-button-press widget-keymap)
              (list "send" #'harness-ask-submit harness-ask-mode-map)
              (list "skip" #'harness-ask-cancel harness-ask-mode-map)))
          (concat
           (format " %s — " (harness-approval-prompt approval))
           (harness-key-hints
            (list "allow" #'harness-ask-submit harness-ask-mode-map)
            (list "always" #'harness-ask-approve-always harness-ask-mode-map)
            (list "deny" #'harness-ask-cancel harness-ask-mode-map))))))))

(define-derived-mode harness-ask-mode special-mode "Harness-Ask"
  "Major mode for answering a question or a tool-permission request.

\[harness-ask-submit] confirms (send answers or allow the tool);
\[harness-ask-cancel] declines (skip the question or deny the tool);
\[harness-ask-approve-always] allows a tool and remembers the decision."
  (setq-local buffer-read-only nil)
  (setq-local truncate-lines nil)
  (setq-local header-line-format '(:eval (harness-ask--header-line))))


;;; The tool

(harness-define-tool "ask_user_question"
  :description "Ask the user a question and wait for the answer. Use this when you need a decision or information only the user has."
  :parameters '(:type "object"
                :properties
                (:questions
                 (:type "array"
                  :items
                  (:type "object"
                   :properties
                   (:question (:type "string" :description "The question to ask")
                              :header (:type "string" :description "Short label, at most a few words")
                              :options (:type "array"
                                        :description "Choices; omit for a free text answer"
                                        :items (:type "object"
                                                :properties (:label (:type "string")
                                                             :description (:type "string"))))
                              :multi_select (:type "boolean")
                              :allow_custom (:type "boolean"))
                   :required ("question"))))
                :required ("questions"))
  :category 'meta
  :read-only t
  :approval 'allow
  :async
  (lambda (args context done)
    (let* ((session (harness-tool-context-session context))
           (tool-call (harness-tool-context-tool-call context))
           (questions (harness-ask--normalize-questions
                       (harness-tools-arg args :questions))))
      (cond
       ((null questions)
        (funcall done (harness-tool-result-create
                       :content "ask_user_question needs at least one question"
                       :error "no questions")))
       ((harness-ask-pending session)
        (funcall done (harness-tool-result-create
                       :content "A question is already waiting for the user; wait for the answer before asking again."
                       :error "question already pending")))
       (t
        (let ((approval (harness-approval-create
                         :session session
                         :tool-call tool-call
                         :kind 'question
                         :prompt (harness-ask--summarize questions)
                         :detail questions
                         :choices '(submit cancel)
                         :callback
                         (lambda (answers)
                           (if (null answers)
                               (funcall done
                                        (harness-tool-result-create
                                         :content "The user declined to answer."
                                         :error "cancelled by the user"))
                             (funcall done
                                      (harness-tool-result-create
                                       :content (harness-ask--format-answers answers)
                                       :detail (list :kind 'answers
                                                     :answers answers))))))))
          (setf (harness-session-approvals session)
                (cons approval (harness-session-approvals session)))
          (harness-session-set-status
           session 'awaiting-answer
           (list :label (harness-approval-prompt approval)
                 :approval (harness-approval-id approval)))
          (run-hook-with-args 'harness-approval-added-hook session approval)
          (harness-session-notify session 'approvals)
          ;; The display hook opens the buffer; nothing here blocks.
          nil))))))

(defun harness-ask--normalize-questions (raw)
  "Return RAW questions as a list of plists."
  (delq nil
        (mapcar
         (lambda (question)
           (let ((text (harness-tools-arg question :question)))
             (when (and text (not (string-empty-p (format "%s" text))))
               (list :question (format "%s" text)
                     :header (or (harness-tools-arg question :header) "Question")
                     :options (harness-ask--normalize-options
                               (harness-tools-arg question :options))
                     ;; JSON `false' parses to the symbol `:false', which is
                     ;; truthy; normalise through `harness-json-true-p' so the
                     ;; widget choice (radio vs checkbox) is right.
                     :multi-select (harness-json-true-p
                                    (harness-tools-arg question :multi_select))
                     :allow-custom (harness-json-true-p
                                    (harness-tools-arg question :allow_custom))))))
         (if (listp raw) raw nil))))

(defun harness-ask--normalize-options (raw)
  "Return RAW options as a list of plists."
  (delq nil
        (mapcar
         (lambda (option)
           (let ((label (harness-tools-arg option :label)))
             (when label
               (list :label (format "%s" label)
                     :description (harness-tools-arg option :description)))))
         (if (listp raw) raw nil))))

(defun harness-ask--summarize (questions)
  "Return a one-line summary of QUESTIONS."
  (let ((first (car questions)))
    (format "Question: %s" (truncate-string-to-width
                            (harness-plist-or-alist-get :question first)
                            60 nil nil "…"))))

(defun harness-ask--format-answers (answers)
  "Render ANSWERS as text for the model and the transcript."
  (string-join
   (mapcar (lambda (answer)
             (format "%s: %s"
                     (or (harness-plist-or-alist-get :header answer) "Answer")
                     (or (harness-plist-or-alist-get :answer answer) "(no answer)")))
           (append answers nil))
   "\n"))


;;; Answers

(defun harness-ask-pending (session)
  "Return SESSION's pending question approval, or nil."
  (cl-find-if (lambda (approval)
                (eq (harness-approval-kind approval) 'question))
              (harness-approval-pending session)))

(defun harness-ask-answer (approval answers)
  "Resolve APPROVAL with ANSWERS and resume the run.
ANSWERS is a list of answer alists, or nil when the user declined."
  (harness-approval-resolve
   approval (and answers (harness-json-array answers))))

(defun harness-ask-answers-from-buffer (&optional buffer)
  "Collect answers from the widgets in BUFFER, or the current buffer.
Each entry of `harness-ask--widgets' is a plist with `:choice' (the radio or
checklist widget) and `:field' (the free text widget, when there is one)."
  (with-current-buffer (or buffer (current-buffer))
    (let ((questions (harness-approval-detail harness-ask--approval))
          (widgets harness-ask--widgets))
      (cl-mapcar #'harness-ask--answer-for questions widgets))))

(defun harness-ask--answer-for (question widgets)
  "Return the answer alist for QUESTION given its WIDGETS plist."
  (let* ((multi (harness-plist-or-alist-get :multi-select question))
         (choice (harness-ask--widget-value (plist-get widgets :choice)))
         (selected (cond
                    ((null choice) nil)
                    (multi (if (listp choice) choice (list choice)))
                    ((listp choice) choice)
                    (t (list choice))))
         (free (harness-ask--widget-value (plist-get widgets :field)))
         (answer (cond
                  ((and (stringp free) (not (string-empty-p free))) free)
                  (selected (string-join selected ", "))
                  (t ""))))
    (list (cons 'header (or (harness-plist-or-alist-get :header question) "Question"))
          (cons 'question (harness-plist-or-alist-get :question question))
          (cons 'answer answer)
          (cons 'selected selected))))

(defun harness-ask--widget-value (widget)
  "Return WIDGET's value, or nil when there is no widget."
  (when widget
    (condition-case nil (widget-value widget) (error nil))))

(defun harness-ask-submit ()
  "Confirm the request: send the answers, or allow the tool call.

Both kinds of request share this buffer (see `harness-ask--display'), so the
primary key sends a question and allows a permission.  The buffer itself is
dismissed by `harness-ask--on-approval-resolved', which runs when the
approval is resolved, however it was resolved."
  (interactive)
  (let ((approval harness-ask--approval))
    (unless approval (user-error "This buffer is not answering a request"))
    (if (eq (harness-approval-kind approval) 'question)
        ;; Collect the answers before resolving: resolving dismisses this
        ;; buffer, so the widgets must be read while they still exist.
        (let ((answers (harness-ask-answers-from-buffer)))
          (harness-ask-answer approval answers)
          (message "Answer sent"))
      (harness-perms-resolve approval 'allow)
      (message "Allowed"))))

(defun harness-ask-cancel ()
  "Decline the request: skip the question, or deny the tool call."
  (interactive)
  (let ((approval harness-ask--approval))
    (unless approval (user-error "This buffer is not answering a request"))
    (if (eq (harness-approval-kind approval) 'question)
        (progn
          (harness-ask-answer approval nil)
          (message "Question skipped"))
      (harness-perms-resolve approval 'deny)
      (message "Denied"))))

(defun harness-ask-approve-always ()
  "Allow the pending tool call and remember the decision.
This only applies to a tool permission; a question has no always-answer."
  (interactive)
  (let ((approval harness-ask--approval))
    (unless approval (user-error "This buffer is not answering a request"))
    (unless (eq (harness-approval-kind approval) 'tool)
      (user-error "A question has no always-answer"))
    (harness-perms-resolve approval 'allow-always)
    (message "Always allowed")))

(defun harness-ask-answer-pending ()
  "Answer the oldest pending question from the minibuffer."
  (interactive)
  (let ((approval (car (seq-filter (lambda (approval)
                                     (eq (harness-approval-kind approval) 'question))
                                   (harness-approvals-pending)))))
    (unless approval (user-error "No pending questions"))
    (let ((answers
           (delq nil
                 (mapcar
                  (lambda (question)
                    (let* ((header (or (harness-plist-or-alist-get :header question)
                                       "Question"))
                           (options (harness-plist-or-alist-get :options question))
                           (answer (if options
                                       (completing-read
                                        (format "%s: " (harness-plist-or-alist-get :question question))
                                        (mapcar (lambda (option)
                                                  (harness-plist-or-alist-get :label option))
                                                options)
                                        nil (not (harness-plist-or-alist-get :multi-select question)))
                                     (read-string
                                      (format "%s: " (harness-plist-or-alist-get :question question))))))
                      (list (cons 'header header)
                            (cons 'question (harness-plist-or-alist-get :question question))
                            (cons 'answer (format "%s" answer))
                            (cons 'selected (list (format "%s" answer))))))
                  (harness-approval-detail approval)))))
      (harness-ask-answer approval answers))))


;;; The buffer

(defun harness-ask--buffer-name (session approval)
  "Return the widget buffer name for APPROVAL of SESSION."
  (format "*Harness %s: %s*"
          (if (eq (harness-approval-kind approval) 'question) "Ask" "Approve")
          (harness-session-name session)))

(defun harness-ask--display (session approval)
  "Show the widget buffer for APPROVAL of SESSION.

Questions get the answer widgets; a tool permission gets the request and
Allow/Always/Deny buttons.  Both share `harness-ask-mode', so the UI, the
faces and the live key hints are one implementation instead of two."
  (let ((buffer (get-buffer-create (harness-ask--buffer-name session approval))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (harness-ask-mode)
        (erase-buffer)
        (setq harness-ask--approval approval)
        (setq harness-ask--widgets nil)
        (if (eq (harness-approval-kind approval) 'question)
            (progn
              (harness-ask--insert-intro session)
              (dolist (question (harness-approval-detail approval))
                (harness-ask--insert-question question))
              (harness-ask--insert-buttons))
          (harness-ask--insert-permission session approval))
        (goto-char (point-min))
        (unless (widget-at (point))
          (widget-forward 1)))
      (set-buffer-modified-p nil))
    (display-buffer buffer harness-ask-display-action)
    buffer))

(defun harness-ask--insert-intro (session)
  "Insert the buffer's introduction for SESSION."
  (insert (propertize (format "%s asks:\n" (harness-session-name session))
                      'face 'bold
                      'read-only t))
  (insert (propertize
           (harness-key-hints
            (list "move" #'widget-forward harness-ask-mode-map)
            (list "pick" #'widget-button-press widget-keymap)
            (list "send" #'harness-ask-submit harness-ask-mode-map)
            (list "skip" #'harness-ask-cancel harness-ask-mode-map))
           'face 'harness-muted
           'read-only t))
  (insert "\n\n"))

(defun harness-ask--insert-permission (session approval)
  "Insert the request and decision buttons for tool APPROVAL."
  (insert (propertize (format "%s wants to run:\n\n" (harness-session-name session))
                      'face 'bold 'read-only t))
  (insert (propertize (format "  %s\n" (harness-approval-prompt approval))
                      'face 'harness-approval 'read-only t))
  (when-let* ((detail (harness-approval-detail approval)))
    (insert (propertize "\nArguments:\n" 'face 'harness-role-tool 'read-only t))
    (insert (propertize (harness-ask--format-detail detail)
                        'face 'harness-message-body 'read-only t)))
  (insert "\n")
  (harness-ask--button "Allow" #'harness-ask-submit)
  (harness-ask--button "Always" #'harness-ask-approve-always)
  (harness-ask--button "Deny" #'harness-ask-cancel)
  (insert "\n")
  (use-local-map harness-ask-mode-map)
  (widget-setup))

(defun harness-ask--button (label command)
  "Insert a push-button LABEL running COMMAND, followed by its key hint."
  (widget-create 'push-button
                 :notify (lambda (&rest _) (call-interactively command))
                 :tag label)
  (when-let* ((hint (harness-key-hint command harness-ask-mode-map)))
    (insert (propertize (format " %s" hint) 'face 'harness-muted)))
  (insert "  "))

(defun harness-ask--format-detail (detail)
  "Return DETAIL pretty-printed for the approval buffer."
  (condition-case nil
      (concat (harness-json-write detail t) "\n")
    (error (format "%S\n" detail))))

(defun harness-ask--insert-question (question)
  "Insert one QUESTION with its widgets."
  (let* ((header (or (harness-plist-or-alist-get :header question) "Question"))
         (text (harness-plist-or-alist-get :question question))
         (options (harness-plist-or-alist-get :options question))
         (multi (harness-plist-or-alist-get :multi-select question))
         (allow-custom (harness-plist-or-alist-get :allow-custom question))
         (choice nil)
         (field nil))
    ;; Nothing here is marked read-only: widgets insert and delete text, and
    ;; a read-only property in the way would break them.
    (insert (propertize (format "%s\n" header) 'face 'harness-role-tool))
    (insert (propertize (format "%s\n" text) 'face 'harness-message-body))
    (when options
      (insert "\n")
      ;; Plain strings only: a propertized label would become the widget's
      ;; value and leak text properties into the answer.
      ;; `:args' must be widget type forms, not bare strings.
      (setq choice (widget-create
                    (if multi 'checklist 'radio-button-choice)
                    :args (mapcar (lambda (option)
                                    (let ((label (harness-plist-or-alist-get :label option)))
                                      (list 'item :value label :tag label)))
                                  options)))
      (dolist (option options)
        (when-let* ((description (harness-plist-or-alist-get :description option)))
          (insert (propertize (format "      %s\n" description)
                              'face 'harness-muted))))
      (insert "\n"))
    (when (or allow-custom (null options))
      (insert (propertize "Answer: " 'face 'harness-prompt))
      (setq field (widget-create 'editable-field :size 50 :value ""))
      (insert "\n"))
    (setq harness-ask--widgets
          (append harness-ask--widgets (list (list :choice choice :field field))))
    (insert "\n")))

(defun harness-ask--insert-buttons ()
  "Insert the Submit and Cancel buttons, each with its live key hint."
  (insert "\n")
  (harness-ask--button "Submit" #'harness-ask-submit)
  (harness-ask--button "Cancel" #'harness-ask-cancel)
  (insert "\n")
  (use-local-map harness-ask-mode-map)
  (widget-setup))

(defun harness-ask-open (&optional session)
  "Show the pending question or permission for SESSION."
  (interactive)
  (let* ((session (or session
                      (when (fboundp 'harness-conversation-session)
                        (harness-conversation-session))
                      (harness-session--read-session "Answer for")))
         (approval (and session
                        (or (harness-ask-pending session)
                            (seq-find (lambda (candidate)
                                        (eq (harness-approval-kind candidate) 'tool))
                                      (harness-approval-pending session))))))
    (unless approval (user-error "Nothing is waiting for an answer"))
    (harness-ask--display session approval)))

(defun harness-ask--on-approval-added (session approval)
  "Open the widget buffer for APPROVAL.
Questions and tool permissions both go through `harness-ask--display'.
Errors are reported rather than swallowed: a request buffer that fails to
render would otherwise look like the session simply hanging."
  (condition-case err
      (harness-ask--display session approval)
    (error (harness--log "could not display the request: %s"
                         (error-message-string err))
           (message "Harness could not display the request: %s"
                    (error-message-string err)))))

(defun harness-ask--dismiss-buffer (buffer)
  "Remove BUFFER from every window and kill it.
`bury-buffer' is not enough: called with a buffer argument it only moves the
buffer down the list and leaves it displayed, so the window would linger and
the next request would open another one beside it.  `quit-window' honours the
`quit-restore' parameter that `display-buffer' recorded, putting the previous
layout back before the buffer is thrown away.

`quit-window' can change the current buffer when it restores a window, and
this runs from `harness-approval-resolved-hook', where the caller expects its
own buffer to stay current, so the caller's buffer is restored afterwards."
  (let ((caller (current-buffer)))
    (dolist (window (get-buffer-window-list buffer nil t))
      (quit-window nil window))
    (when (buffer-live-p buffer)
      (kill-buffer buffer))
    (when (buffer-live-p caller)
      (set-buffer caller))))

(defun harness-ask--on-approval-resolved (_session approval _decision)
  "Dismiss the widget buffer that was answering APPROVAL.
The approval may have been resolved from here, from the minibuffer or from
the inline prompt in the conversation; all of them leave a stale window
otherwise, and a stale buffer could still resolve the approval a second
time."
  (save-current-buffer
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (and (derived-mode-p 'harness-ask-mode)
                   (eq harness-ask--approval approval))
          (setq harness-ask--approval nil)
          (harness-ask--dismiss-buffer buffer))))))

(add-hook 'harness-approval-added-hook #'harness-ask--on-approval-added)
(add-hook 'harness-approval-resolved-hook #'harness-ask--on-approval-resolved)

(provide 'harness-ui-ask)
;;; harness-ui-ask.el ends here
