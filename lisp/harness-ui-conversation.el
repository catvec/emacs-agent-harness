;;; harness-ui-conversation.el --- Conversation buffer and input area -*- lexical-binding: t; -*-

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

;; The buffer is a `special-mode' derivative whose output carries the
;; `read-only' text property, leaving only the input area at the bottom
;; editable -- the same technique `term-mode' and `eshell' use.  Editing,
;; killing and yanking therefore behave normally in the input, with no
;; comint-style prompt parsing.
;;
;; Layout, top to bottom, with one marker at each seam:
;;
;;   header line          (header-line-format, rebuilt on demand)
;;   messages             [harness-conversation--messages-end]
;;   approvals + queue    [harness-conversation--extras-end]
;;   input area           [harness-conversation--input-start]
;;
;; Rendering is incremental.  A streamed token is inserted at a marker, so the
;; cost is the token, not the transcript; a finished tool call re-renders only
;; its own block, again between markers.  The whole buffer is re-rendered only
;; on `g', on `harness-conversation-load-earlier', or after a hot reload.
;;
;; Rendering dispatches through `harness-ui-renderers', so the core's text,
;; thinking, error and diff renderers are registered with the same call a
;; plugin uses.  See DESIGN.md sections 9.1 and 13.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'button)
(require 'harness-core)
(require 'harness-session)
(require 'harness-agent)
(require 'harness-perms)
(require 'harness-queue)
(require 'harness-faces)

;; Commands owned by sibling UI modules.  They are declared rather than
;; required so that loading the conversation view never drags in the tree or
;; the model picker.
(declare-function harness-attachments-completion-at-point "harness-attachments" ())
(declare-function harness-tree "harness-ui-tree" (&optional session))
(declare-function harness-select-model "harness-ui-model" (&optional session))

(defcustom harness-ui-max-rendered-messages 200
  "How many recent messages a conversation buffer renders.
Older messages stay in the session; `harness-conversation-load-earlier' shows
more of them."
  :type 'integer
  :group 'harness-ui)

(defcustom harness-ui-follow t
  "Whether the conversation buffer follows streaming output.
Only windows already showing the end of the buffer are scrolled."
  :type 'boolean
  :group 'harness-ui)

(defcustom harness-ui-show-thinking nil
  "Whether reasoning traces are expanded by default."
  :type 'boolean
  :group 'harness-ui)

(defcustom harness-ui-tool-output-lines 12
  "Lines of tool output shown inline before the rest is folded."
  :type 'integer
  :group 'harness-ui)

(defcustom harness-ui-conversation-display-action nil
  "`display-buffer' action used for conversation buffers.
Nil means use the selected window."
  :type '(choice (const :tag "Selected window" nil) (repeat sexp))
  :group 'harness-ui)

(defconst harness-ui-prompt "❯ "
  "Prompt in front of the input area.")


;;; Renderer registry

(defvar harness-content-render-functions nil
  "Abnormal hook deciding how a message body is rendered.

Each function is called with the content string and should return non-nil when
it has inserted the content itself; the first one to do so wins.  This is the
hook the attachment renderer uses, so the core text renderer needs no special
case for attachments (or for anything else a plugin wants to style).")

(defvar harness-ui-renderers (make-hash-table :test #'eq)
  "Registry mapping a message part kind to a renderer function.
A renderer is called with (SESSION PART) and inserts into the current buffer.
The core registers `text', `thinking', `error' and `diff'; plugins register
their own with `harness-add-renderer'.")

(defvar harness-ui--renderer-owners (make-hash-table :test #'eq)
  "File that registered each renderer, so a reload can remove them.")

(defun harness-add-renderer (kind function &optional replace)
  "Register FUNCTION as the renderer for message part KIND.

KIND is a symbol and FUNCTION is called with (SESSION PART).  Unless REPLACE
is non-nil an existing renderer is kept, so a plugin cannot silently replace a
kind it does not own.  The defining file is recorded so that
`harness-unload-file' removes it on reload."
  (when (or replace (not (gethash kind harness-ui-renderers)))
    (puthash kind function harness-ui-renderers)
    (puthash kind (or load-file-name buffer-file-name (bound-and-true-p byte-compile-current-file))
             harness-ui--renderer-owners))
  kind)

(defun harness-remove-renderer (kind)
  "Remove the renderer for KIND."
  (remhash kind harness-ui-renderers)
  (remhash kind harness-ui--renderer-owners))

(defun harness-renderer (kind)
  "Return the renderer registered for KIND, or nil."
  (gethash kind harness-ui-renderers))

(defun harness-renderers-for-file (file)
  "Return the renderer kinds registered by FILE."
  (let (kinds)
    (maphash (lambda (kind owner)
               (when (equal owner file) (push kind kinds)))
             harness-ui--renderer-owners)
    kinds))


;;; Buffer state

(defvar-local harness-conversation--session nil
  "Session this buffer shows.")

(defvar-local harness-conversation--message-markers nil
  "Hash of message id to a markers plist.
Keys: `:start', `:content-end', `:thinking-end' and `:end'.")

(defvar-local harness-conversation--tool-markers nil
  "Hash of tool call id to (START . END) markers of its rendered block.")

(defvar-local harness-conversation--folds nil
  "Foldable regions, outermost first.
Each element is a plist with `:start', `:end' and `:hidden'.")

(defvar-local harness-conversation--messages-end nil
  "Marker after the last rendered message.  Insertion type t.")

(defvar-local harness-conversation--extras-end nil
  "Marker after the approval and queue section.  Insertion type t.")

(defvar-local harness-conversation--input-start nil
  "Marker at the first editable character of the input area.")

(defvar-local harness-conversation--suppress-refresh nil
  "Non-nil while the buffer is being rebuilt.")

(defvar-local harness-conversation--limit nil
  "How many messages this buffer renders; nil means the default.")

(defun harness-conversation--input-p ()
  "Return non-nil when point is in the input area."
  (and harness-conversation--input-start
       (>= (point) (marker-position harness-conversation--input-start))))

(defvar harness-conversation-mode-map
  (let ((map (make-sparse-keymap)))
    ;; `special-mode-map' is deliberately *not* the parent: it binds every
    ;; self-inserting key to `undefined' (`suppress-keymap'), which would make
    ;; the input area impossible to type into.  The transcript is already kept
    ;; read-only by the `read-only' text property (see
    ;; `harness-conversation--protect'), so the map only has to keep the
    ;; single-key commands below from swallowing what the user types (see
    ;; `harness-conversation--input-p').
    ;;
    ;; A non-nil parent is still required: `define-derived-mode' splices in the
    ;; parent mode's keymap when a mode's own map has no parent.
    (set-keymap-parent map (make-sparse-keymap))
    (define-key map (kbd "RET") #'harness-conversation-send)
    (define-key map (kbd "C-c C-c") #'harness-conversation-send)
    (define-key map (kbd "C-j") #'newline)
    (define-key map (kbd "C-c C-k") #'harness-conversation-clear-input)
    (define-key map (kbd "C-c C-b") #'harness-conversation-abort)
    (define-key map (kbd "C-c C-a") #'harness-conversation-approve)
    (define-key map (kbd "C-c C-d") #'harness-conversation-deny)
    (define-key map (kbd "C-c C-A") #'harness-conversation-approve-always)
    (define-key map (kbd "C-c C-t") #'harness-tree)
    (define-key map (kbd "C-c C-e") #'harness-queue-edit)
    (define-key map (kbd "C-c C-f") #'harness-conversation-search)
    (define-key map (kbd "C-c C-z") #'harness-compact-session)
    (define-key map (kbd "C-c C-m") #'harness-select-model)
    (define-key map (kbd "C-c C-l") #'harness-conversation-load-earlier)
    (define-key map (kbd "C-c C-w") #'harness-set-working-directory)
    (define-key map (kbd "TAB") #'harness-conversation-tab)
    (define-key map (kbd "<backtab>") #'harness-conversation-toggle-fold)
    (define-key map (kbd "n") #'harness-conversation--next-message-or-insert)
    (define-key map (kbd "p") #'harness-conversation--previous-message-or-insert)
    (define-key map (kbd "g") #'harness-conversation--refresh-or-insert)
    (define-key map (kbd "q") #'harness-conversation--bury-or-insert)
    (define-key map (kbd "SPC") #'harness-conversation--scroll-or-insert)
    map)
  "Keymap for `harness-conversation-mode'.")

(define-derived-mode harness-conversation-mode special-mode "Harness"
  "Major mode for a conversation with an agent.

Output is read-only; the input area at the bottom is not.
\\[harness-conversation-send] sends, \\[harness-conversation-abort] aborts the
run, \\[harness-conversation-toggle-fold] folds tool output and
\\[harness-conversation-refresh] re-renders."
  (setq-local buffer-read-only nil)
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (setq-local scroll-conservatively 101)
  (setq-local cursor-in-non-selected-windows t)
  (add-to-invisibility-spec '(harness-fold . t))
  (setq-local header-line-format '(:eval (harness-conversation--header-line)))
  (add-hook 'completion-at-point-functions
            #'harness-attachments-completion-at-point nil t))

(defun harness-conversation-session (&optional buffer)
  "Return the session shown in BUFFER, or the current buffer."
  (buffer-local-value 'harness-conversation--session (or buffer (current-buffer))))

(defun harness-conversation-buffer (session)
  "Return SESSION's conversation buffer, creating and initialising it if needed."
  (let ((buffer (harness-session-buffer session)))
    (unless (buffer-live-p buffer)
      (setq buffer (get-buffer-create
                    (format "*Harness: %s*" (harness-session-name session)))))
    (unless (eq (buffer-local-value 'harness-conversation--session buffer) session)
      (with-current-buffer buffer
        (harness-conversation-mode)
        (setq harness-conversation--session session)
        (setq harness-conversation--limit nil)
        (setq harness-conversation--message-markers (make-hash-table :test #'equal))
        (setq harness-conversation--tool-markers (make-hash-table :test #'equal))
        (harness-conversation--build)))
    (setf (harness-session-buffer session) buffer)
    buffer))

(defun harness-conversation-open (session &optional noshow)
  "Show SESSION's conversation buffer.  With NOSHOW, only create it."
  (let ((buffer (harness-conversation-buffer session)))
    (unless noshow
      (if harness-ui-conversation-display-action
          (display-buffer buffer harness-ui-conversation-display-action)
        (pop-to-buffer-same-window buffer)))
    buffer))

(defun harness-conversation-rename-buffer (session)
  "Refresh SESSION's conversation buffer name after a rename."
  (when-let* ((buffer (harness-session-buffer session)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (rename-buffer (format "*Harness: %s*" (harness-session-name session)) t)))))


;;; Insertion helpers

;; All rendering binds `inhibit-read-only': the `read-only' property is there
;; to stop the *user* editing the transcript, not to stop the renderer, and
;; inserting next to read-only text is otherwise an error.  Interactive
;; commands in the input area do not bind it, so the protection still holds
;; where it matters.
(defmacro harness-conversation--with-output (&rest body)
  "Evaluate BODY with the read-only property inhibited."
  (declare (indent 0))
  `(let ((inhibit-read-only t)) ,@body))

(defun harness-conversation--protect (start end)
  "Mark [START,END) read-only but not sticky in either direction.

`rear-nonsticky' is what makes the difference: without it Emacs refuses an
insertion at the end of a read-only region, which is exactly where the input
area starts and where streaming appends.  `front-sticky nil' does the same for
insertion at the start."
  (let ((inhibit-read-only t))
    (put-text-property start end 'read-only t)
    (put-text-property start end 'front-sticky nil)
    (put-text-property start end 'rear-nonsticky t)))

(defun harness-conversation--output (string &rest properties)
  "Insert read-only STRING with PROPERTIES at point."
  (let ((start (point))
        (text (if properties (apply #'propertize string properties) string)))
    (insert text)
    (harness-conversation--protect start (point))))

(defun harness-conversation--output-at (marker string &rest properties)
  "Insert read-only STRING at MARKER, leaving point where it is."
  (save-excursion
    (goto-char (marker-position marker))
    (apply #'harness-conversation--output string properties)))

(defun harness-conversation-insert (string &rest properties)
  "Insert read-only STRING with PROPERTIES into the current buffer.
This and `harness-conversation-insert-folded' are the public insertion API for
content renderers, so a plugin never has to reach for a private function."
  (apply #'harness-conversation--output string properties))

(defun harness-conversation-insert-folded (string &rest properties)
  "Insert STRING folded, with PROPERTIES applied.
Returns the fold, so a caller can unfold it later."
  (let ((start (point)))
    (apply #'harness-conversation--output string properties)
    (harness-conversation--fold start (point) t)))

(defun harness-conversation--fold (start end hidden)
  "Record a foldable region between START and END, hidden when HIDDEN."
  (let ((fold (list :start (copy-marker start)
                    :end (copy-marker end t)
                    :hidden hidden)))
    (when hidden
      (let ((inhibit-read-only t))
        (put-text-property start end 'invisible 'harness-fold)))
    (setq harness-conversation--folds
          (append harness-conversation--folds (list fold)))
    fold))

(defun harness-conversation--forget-folds ()
  "Drop every fold record."
  (dolist (fold harness-conversation--folds)
    (set-marker (plist-get fold :start) nil)
    (set-marker (plist-get fold :end) nil))
  (setq harness-conversation--folds nil))

(defun harness-conversation--windows-at-end ()
  "Return the windows showing this buffer with point at the end."
  (seq-filter (lambda (window)
                (with-selected-window window
                  (>= (point) (1- (point-max)))))
              (get-buffer-window-list (current-buffer) nil t)))

(defun harness-conversation--follow (windows)
  "Move point to the end in WINDOWS, if following is enabled."
  (when harness-ui-follow
    (dolist (window windows)
      (with-selected-window window
        (goto-char (point-max))))))


;;; Building and rendering

(defun harness-conversation--build ()
  "Create the buffer skeleton and render it.

The markers are created *after* the input area is inserted, so that inserting
the prompt cannot push the message and extras markers past it.  Their
insertion types are also deliberate: the message and extras markers must move
past text inserted at them (output grows downwards), while the input marker
must not, because text typed at `point-max' belongs to the input region."
  (let ((inhibit-read-only t)
        (windows (harness-conversation--windows-at-end)))
    (erase-buffer)
    (harness-conversation--forget-folds)
    (clrhash harness-conversation--message-markers)
    (clrhash harness-conversation--tool-markers)
    (insert "\n")
    (let ((messages-position (point)))
      (insert "\n")
      (let ((start (point)))
        (insert harness-ui-prompt)
        (put-text-property start (point) 'face 'harness-prompt)
        (put-text-property start (point) 'field 'harness-input)
        (harness-conversation--protect start (point))
        (setq harness-conversation--input-start (copy-marker (point))))
      (setq harness-conversation--messages-end (copy-marker messages-position t))
      (setq harness-conversation--extras-end (copy-marker messages-position t)))
    (harness-conversation--sync)
    (harness-conversation--follow windows)
    (goto-char (point-max))))

(defun harness-conversation--message-header (message)
  "Return the header text for MESSAGE."
  (let* ((role (harness-message-role message))
         (face (pcase role
                 ('user 'harness-role-user)
                 ('assistant 'harness-role-assistant)
                 ('system 'harness-role-system)
                 ('tool 'harness-role-tool)
                 (_ 'harness-muted)))
         (label (pcase role
                  ('user "You")
                  ('assistant "Assistant")
                  ('system "System")
                  ('tool (format "Tool: %s" (or (harness-message-tool-name message) "?")))
                  (_ (capitalize (symbol-name role)))))
         (meta (string-join
                (delq nil
                      (list (harness-format-time (harness-message-timestamp message))
                            (when-let* ((duration (harness-message-duration message)))
                              (format "%.1fs" duration))
                            (when-let* ((usage (harness-message-usage message)))
                              (harness-usage-format usage))))
                " · ")))
    (concat (propertize label 'face face)
            (unless (string-empty-p meta)
              (propertize (format "  %s" meta) 'face 'harness-muted)))))

(defun harness-conversation--render-message (session message)
  "Render MESSAGE of SESSION at the end of the message region.
Returns the markers plist, whose marks are positioned for later updates."
  (save-excursion
    (goto-char (marker-position harness-conversation--messages-end))
    (let ((start (point))
          thinking-end)
      (harness-conversation--output (harness-conversation--message-header message))
      (insert "\n")
      (when (harness-message-thinking message)
        (let ((body-start (point)))
          (harness-conversation--output "thinking…\n" 'face 'harness-thinking)
          (harness-conversation--output (harness-message-thinking message)
                                        'face 'harness-thinking)
          (insert "\n")
          (setq thinking-end (point))
          (harness-conversation--fold body-start thinking-end
                                      (not harness-ui-show-thinking))))
      (let ((content-start (point)))
        (harness-conversation--render-content session message content-start)
        (let ((content-end (point)))
          (insert "\n")
          (let ((end (point)))
            ;; Everything in the block is output, including the newlines.
            (harness-conversation--protect start end)
            (list :start (copy-marker start)
                  :thinking-end (and thinking-end (copy-marker thinking-end t))
                  :content-end (copy-marker content-end t)
                  :end (copy-marker end t))))))))

(defun harness-conversation--render-content (session message content-start)
  "Render MESSAGE's body of SESSION, dispatching to the `text' renderer."
  (ignore content-start)
  (let ((content (harness-message-content message)))
    (when (and content (not (string-empty-p content)))
      (if-let* ((renderer (harness-renderer 'text)))
          (funcall renderer session message)
        (harness-conversation--output content 'face 'harness-message-body))))
  (when (harness-message-error message)
    (harness-conversation--output (format "\n%s" (harness-message-error message))
                                  'face 'harness-error))
  (dolist (call (harness-message-tool-calls message))
    (harness-conversation--render-tool-call session call)))

(defun harness-conversation--render-tool-call (_session call)
  "Render tool CALL as a block at point."
  (let ((start (point))
        (tool (harness-tool-get (harness-tool-call-name call))))
    (harness-conversation--output
     (format "  %s %s  "
             (if (and tool (harness-tool-read-only tool)) "▷" "⏺")
             (harness-tool-call-summary call))
     'face 'harness-role-tool)
    (harness-conversation--output
     (format "%s\n" (harness-conversation--tool-status-label call))
     'face (harness-tool-status-face (harness-tool-call-status call)))
    (harness-conversation--insert-tool-output call)
    (let ((end (point)))
      (puthash (harness-tool-call-id call)
               (cons (copy-marker start) (copy-marker end t))
               harness-conversation--tool-markers))))

(defun harness-conversation--tool-status-label (call)
  "Return a label for CALL's status."
  (pcase (harness-tool-call-status call)
    ('ok "    ✔ done")
    ('error (format "    ✖ %s" (or (harness-tool-call-error call) "failed")))
    ('denied "    ✖ denied")
    ('aborted "    × aborted")
    ('running "    … running")
    ('awaiting-approval "    ! waiting for you")
    ('pending "    … pending")
    (_ (format "    %s" (harness-tool-call-status call)))))

(defun harness-conversation--insert-tool-output (call)
  "Insert CALL's output, folded when it is longer than the inline limit."
  (let* ((result (or (harness-tool-call-result call) ""))
         (lines (split-string result "\n"))
         (limit harness-ui-tool-output-lines))
    (when (not (string-empty-p result))
      (harness-conversation--output
       (format "    %s\n"
               (replace-regexp-in-string
                "\n" "\n    " (string-join (seq-take lines limit) "\n")))
       'face 'harness-tool-output)
      (when (> (length lines) limit)
        (let ((body-start (point)))
          (harness-conversation--output
           (format "    %s\n"
                   (replace-regexp-in-string
                    "\n" "\n    " (string-join (seq-drop lines limit) "\n")))
           'face 'harness-tool-output)
          (harness-conversation--fold body-start (point) t))))))

(defun harness-conversation--sync (&optional windows)
  "Render any messages that are not rendered yet.
WINDOWS, when given, are followed to the end of the buffer."
  (unless harness-conversation--suppress-refresh
    (harness-conversation--with-output
     (let* ((session harness-conversation--session)
           (messages (harness-session-messages session))
           (limit (or harness-conversation--limit harness-ui-max-rendered-messages))
           (visible (if (> (length messages) limit)
                        (seq-drop messages (- (length messages) limit))
                      messages))
           (windows (or windows (harness-conversation--windows-at-end))))
      (let ((harness-conversation--suppress-refresh t))
        (harness-conversation--clear-extras)
        (dolist (message visible)
          (unless (gethash (harness-message-id message)
                           harness-conversation--message-markers)
            (puthash (harness-message-id message)
                     (harness-conversation--render-message session message)
                     harness-conversation--message-markers)))
        (harness-conversation--render-extras))
       (harness-conversation--follow windows)))))

(defun harness-conversation--clear-extras ()
  "Delete the approval and queue region."
  (let ((start (marker-position harness-conversation--messages-end))
        (end (marker-position harness-conversation--extras-end)))
    (when (and start end (< start end))
      (let ((inhibit-read-only t))
        (delete-region start end)))))

(defun harness-conversation--render-extras ()
  "Render the approval prompts and queued messages at the end of the messages."
  (let ((session harness-conversation--session))
    (save-excursion
      (goto-char (marker-position harness-conversation--messages-end))
      (let ((start (point))
            (any nil))
        (dolist (approval (harness-approval-pending session))
          (harness-conversation--render-approval session approval)
          (setq any t))
        (when (harness-session-queue session)
          (harness-conversation--render-queue session)
          (setq any t))
        (when any
          (insert "\n")
          (harness-conversation--protect start (point)))))))

(defun harness-conversation--render-approval (session approval)
  "Render APPROVAL of SESSION with buttons."
  (ignore session)
  (let ((start (point)))
    (harness-conversation--output
     (format "⚠ %s\n" (harness-approval-prompt approval)) 'face 'harness-approval)
    (when-let* ((detail (harness-approval-detail approval)))
      (let ((summary (harness-conversation--summarize detail)))
        (unless (string-empty-p summary)
          (harness-conversation--output (format "  %s\n" summary)
                                        'face 'harness-muted))))
    (harness-conversation--output "  ")
    (harness-conversation--button "Allow" `(lambda (_) (harness-perms-resolve ,approval 'allow)))
    (harness-conversation--output " ")
    (harness-conversation--button "Always" `(lambda (_) (harness-perms-resolve ,approval 'allow-always)))
    (harness-conversation--output " ")
    (harness-conversation--button "Deny" `(lambda (_) (harness-perms-resolve ,approval 'deny)))
    (insert "\n")
    (let ((inhibit-read-only t))
      (put-text-property start (point) 'harness-approval approval))))

(defun harness-conversation--summarize (detail)
  "Return a one-line summary of approval DETAIL, which may not be JSON safe."
  (condition-case nil
      (truncate-string-to-width
       (replace-regexp-in-string "\n" " " (harness-json-write detail))
       120 nil nil "…")
    (error "")))

(defun harness-conversation--button (label action)
  "Insert clickable LABEL; ACTION is called with the button."
  (insert-text-button label
                      'action (lambda (button)
                                (let ((function (button-get button 'harness-action)))
                                  (funcall function button)))
                      'harness-action action
                      'follow-link t
                      'face 'harness-role-tool))

(defun harness-conversation--render-queue (session)
  "Render SESSION's queued messages."
  (harness-conversation--output
   (propertize (format "✎ Queued (%d)" (harness-queue-length session))
               'face 'harness-queue)
   'face 'harness-queue)
  (harness-conversation--output "  ")
  (insert-text-button "edit"
                      'action (lambda (_button) (harness-queue-edit session))
                      'follow-link t
                      'face 'harness-muted)
  (insert "\n")
  (dolist (queued (harness-session-queue session))
    (harness-conversation--output
     (format "  %s\n" (harness-queued-message-text queued)) 'face 'harness-queue)))

(defun harness-conversation--append-stream (session message kind text)
  "Append streamed TEXT of KIND to MESSAGE's block."
  (harness-conversation--with-output
   (let ((markers (gethash (harness-message-id message)
                          harness-conversation--message-markers)))
    (unless markers
      (harness-conversation--sync)
      (setq markers (gethash (harness-message-id message)
                             harness-conversation--message-markers)))
    (when markers
      (let ((marker (if (eq kind 'thinking)
                        (or (plist-get markers :thinking-end)
                            (plist-get markers :content-end))
                      (plist-get markers :content-end))))
        (when marker
          (harness-conversation--output-at
           marker text
           'face (if (eq kind 'thinking) 'harness-thinking 'harness-message-body)))))))
  (ignore session))

(defun harness-conversation--refresh-tool (call)
  "Re-render CALL's block in place, if it has one."
  (harness-conversation--with-output
   (let ((markers (gethash (harness-tool-call-id call)
                          harness-conversation--tool-markers)))
    (if (null markers)
        ;; Seen while streaming: the block is appended to the last message.
        (let* ((session harness-conversation--session)
               (message (harness-session-last-message session))
               (message-markers (and message
                                     (gethash (harness-message-id message)
                                              harness-conversation--message-markers))))
          (when message-markers
            (let ((inhibit-read-only t))
              (save-excursion
                (goto-char (marker-position (plist-get message-markers :end)))
                (harness-conversation--render-tool-call session call)))))
      (let ((start (marker-position (car markers)))
            (end (marker-position (cdr markers))))
        (when (and start end (<= start end) (not (= start end)))
          (let ((inhibit-read-only t))
            (save-excursion
              (goto-char start)
              (delete-region start end)
              (harness-conversation--render-tool-call
               harness-conversation--session call)))))))))

(defun harness-conversation--directory-label (session)
  "Return a short label for SESSION's working directory.

The project name when the session works in the project root, and the project
plus the relative path when it has been pointed somewhere else (a git
worktree, say)."
  (let ((directory (harness-session-cwd session))
        (root (harness-session-project-root session))
        (name (harness-session-project-name session)))
    (cond
     ((null root) (abbreviate-file-name directory))
     ((equal (file-name-as-directory (expand-file-name directory))
             (file-name-as-directory (expand-file-name root)))
      name)
     (t (format "%s/%s" name (harness-relative-path directory root))))))

(defun harness-conversation-context-string (session)
  "Return the context usage string for SESSION, or nil.
Uses the context module when it is loaded; the header line must not require
it, so that a minimal install still renders."
  (when (fboundp 'harness-context-stats-string)
    (let* ((ratio (harness-context-ratio session))
           (string (harness-context-stats-string session)))
      (propertize (format "  ctx %s" string)
                  'face (cond ((>= ratio 0.9) 'harness-error)
                              ((>= ratio (if (boundp 'harness-context-warn-at)
                                             (symbol-value 'harness-context-warn-at)
                                           0.6))
                               'harness-approval)
                              (t 'harness-muted))))))

(declare-function harness-context-stats-string "harness-context" (session))
(declare-function harness-context-ratio "harness-context" (session))
(declare-function harness-context-search "harness-context"
                  (session regexp callback &optional limit))
(declare-function harness-compact-session "harness-context" (&optional session))

(defun harness-conversation--header-line ()
  "Return the header line text for the current conversation buffer."
  (let ((session harness-conversation--session))
    (if (null session)
        " Harness"
      (let ((status (harness-session-status session)))
        (concat
         " "
         (propertize (harness-status-glyph status) 'face (harness-status-face status))
         " "
         (propertize (harness-session-status-string session)
                     'face (harness-status-face status))
         "  "
         (propertize (harness-session-name session) 'face 'bold)
         (propertize (format "  %s" (or (harness-session-model session) "no model"))
                     'face 'harness-muted)
         (when-let* ((directory (harness-conversation--directory-label session)))
           (propertize (format "  %s" directory) 'face 'harness-muted))
         (propertize (format "  %s" (harness-usage-format
                                     (harness-session-usage-total session)))
                     'face 'harness-cost)
         (when (harness-session-approvals session)
           (propertize (format "  ⚠ %d waiting"
                               (length (harness-session-approvals session)))
                       'face 'harness-approval))
         (when (harness-session-queue session)
           (propertize (format "  ✎ %d queued" (harness-queue-length session))
                       'face 'harness-queue))
         (harness-conversation-context-string session))))))


;;; Core renderers

(defun harness-conversation--render-text (session part)
  "Render the text of message PART.

Content renderers registered on `harness-content-render-functions' get first
refusal; the plain body is the fallback."
  (ignore session)
  (let ((content (or (harness-message-content part) "")))
    (unless (run-hook-with-args-until-success 'harness-content-render-functions
                                              content)
      (harness-conversation--output content 'face 'harness-message-body))))

(harness-add-renderer 'text #'harness-conversation--render-text)

(defun harness-conversation--render-thinking (session part)
  "Render the thinking trace of PART."
  (ignore session)
  (when-let* ((thinking (harness-message-thinking part)))
    (harness-conversation--output thinking 'face 'harness-thinking)))

(harness-add-renderer 'thinking #'harness-conversation--render-thinking)

(defun harness-conversation--render-error (session part)
  "Render the error of PART."
  (ignore session)
  (when-let* ((error (harness-message-error part)))
    (harness-conversation--output error 'face 'harness-error)))

(harness-add-renderer 'error #'harness-conversation--render-error)

(defun harness-conversation--render-diff (session part)
  "Render a diff from PART, a plist with `:old' and `:new'."
  (ignore session)
  (let ((old (harness-plist-or-alist-get :old part))
        (new (harness-plist-or-alist-get :new part)))
    (dolist (line (split-string (or old "") "\n"))
      (harness-conversation--output (format "- %s\n" line)
                                    'face 'harness-diff-remove))
    (dolist (line (split-string (or new "") "\n"))
      (harness-conversation--output (format "+ %s\n" line)
                                    'face 'harness-diff-add))))

(harness-add-renderer 'diff #'harness-conversation--render-diff)

(defun harness-conversation-render-diff (session detail)
  "Render DETAIL (a plist with `:old' and `:new') as a diff in SESSION's buffer."
  (harness-conversation--render-diff session detail))


;;; Event handlers

(defun harness-conversation--on-session-updated (session events)
  "React to SESSION changing; EVENTS says what changed."
  (when-let* ((buffer (harness-session-buffer session)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (unless harness-conversation--suppress-refresh
          (cond
           ((memq 'messages events)
            (harness-conversation--sync))
           ((memq 'meta events)
            (harness-conversation-rename-buffer session)
            (force-mode-line-update))
           ((or (memq 'approvals events) (memq 'queue events))
            (let ((windows (harness-conversation--windows-at-end)))
              (harness-conversation--with-output
               (let ((harness-conversation--suppress-refresh t))
                 (harness-conversation--clear-extras)
                 (harness-conversation--render-extras)))
              (harness-conversation--follow windows)))
           ((memq 'status events)
            (force-mode-line-update))
           (t nil)))))))

(defun harness-conversation--on-stream (session message kind text)
  "Append streamed TEXT of KIND to MESSAGE in SESSION's buffer."
  (when-let* ((buffer (harness-session-buffer session)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (unless harness-conversation--suppress-refresh
          (let ((windows (harness-conversation--windows-at-end)))
            (harness-conversation--append-stream session message kind text)
            (harness-conversation--follow windows)))))))

(defun harness-conversation--on-tool-call (session call)
  "Update CALL's block in SESSION's buffer."
  (when-let* ((buffer (harness-session-buffer session)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (unless harness-conversation--suppress-refresh
          (let ((harness-conversation--suppress-refresh t))
            (harness-conversation--refresh-tool call)))))))

(add-hook 'harness-session-updated-hook #'harness-conversation--on-session-updated)
(add-hook 'harness-stream-hook #'harness-conversation--on-stream)
(add-hook 'harness-tool-call-updated-hook #'harness-conversation--on-tool-call)


;;; Commands

(defun harness-conversation--input ()
  "Return the text in the input area."
  (buffer-substring-no-properties (marker-position harness-conversation--input-start)
                                  (point-max)))

(defun harness-conversation--clear-input ()
  "Delete the input area's contents."
  (let ((inhibit-read-only t))
    (delete-region (marker-position harness-conversation--input-start) (point-max))))

(defun harness-conversation-send ()
  "Send the text in the input area to the session."
  (interactive)
  (let* ((session harness-conversation--session)
         (text (string-trim (harness-conversation--input))))
    (unless session (user-error "This buffer is not a harness conversation"))
    (when (string-empty-p text)
      (user-error "Nothing to send"))
    (harness-conversation--clear-input)
    (harness-agent-send session text))
  (goto-char (point-max)))

(defun harness-conversation-send-text (session text)
  "Send TEXT to SESSION from anywhere."
  (interactive (list (or (harness-session--read-session "Send to")
                         (user-error "No live sessions"))
                     (read-string "Message: ")))
  (harness-agent-send session text))

(defun harness-conversation-clear-input ()
  "Clear the input area."
  (interactive)
  (harness-conversation--clear-input)
  (goto-char (point-max)))

(defun harness-conversation-abort ()
  "Abort the current run."
  (interactive)
  (let ((session harness-conversation--session))
    (unless session (user-error "This buffer is not a harness conversation"))
    (harness-agent-abort session)))

(defun harness-conversation--approval-at-point ()
  "Return the approval rendered at point, or the first pending one."
  (or (get-text-property (point) 'harness-approval)
      (car (harness-approval-pending harness-conversation--session))))

(defun harness-conversation-approve ()
  "Allow the pending approval in this buffer."
  (interactive)
  (let ((approval (harness-conversation--approval-at-point)))
    (unless approval (user-error "No pending approval"))
    (harness-perms-resolve approval 'allow)))

(defun harness-conversation-approve-always ()
  "Allow the pending approval and remember the decision."
  (interactive)
  (let ((approval (harness-conversation--approval-at-point)))
    (unless approval (user-error "No pending approval"))
    (harness-perms-resolve approval 'allow-always)))

(defun harness-conversation-deny ()
  "Deny the pending approval in this buffer."
  (interactive)
  (let ((approval (harness-conversation--approval-at-point)))
    (unless approval (user-error "No pending approval"))
    (harness-perms-resolve approval 'deny)))

(defun harness-conversation-refresh ()
  "Re-render the whole conversation buffer."
  (interactive)
  (let ((session harness-conversation--session))
    (unless session (user-error "This buffer is not a harness conversation"))
    (harness-conversation--build)))

(defun harness-conversation-load-earlier ()
  "Show more of the transcript, by rendering only what is missing.

Rebuilding the buffer would throw away the user's place (and, for a long
session, re-render hundreds of messages); prepending the earlier messages
keeps point, folds and the input area exactly where they were, because every
marker after them shifts automatically."
  (interactive)
  (let* ((session harness-conversation--session)
         (messages (harness-session-messages session))
         (total (length messages))
         (current (or harness-conversation--limit harness-ui-max-rendered-messages))
         (next (min total (* current 2))))
    (if (= next current)
        (message "The whole transcript is already shown (%d messages)" total)
      (setq harness-conversation--limit next)
      (let* ((visible (seq-drop messages (- total next)))
             (missing (seq-take visible (- next current)))
             (inhibit-read-only t))
        (save-excursion
          (goto-char (marker-position harness-conversation--messages-end))
          ;; Render the missing messages above the current ones, then move the
          ;; insertion point back to the top so they appear in order.
          (let ((insertion (point)))
            (dolist (message (reverse missing))
              (goto-char insertion)
              (let ((markers (harness-conversation--render-message session message)))
                (puthash (harness-message-id message) markers
                         harness-conversation--message-markers)
                (setq insertion (point))))))
      (message "Showing the last %d of %d messages" next total)))))

(defun harness-conversation-search (regexp)
  "Search this session's whole transcript for REGEXP.

The search runs in chunks (see `harness-context-search'), so a long session
does not block Emacs while it looks."
  (interactive "sSearch transcript: ")
  (let ((session harness-conversation--session))
    (unless session (user-error "This buffer is not a harness conversation"))
    (message "Searching…")
    (harness-context-search
     session regexp
     (lambda (results)
       (if (null results)
           (message "No matches for %s" regexp)
         (harness-conversation-show-search-results session regexp results))))))

(defun harness-conversation-show-search-results (session regexp results)
  "Show SEARCH RESULTS for REGEXP in a buffer, RET jumping to the message."
  (let ((buffer (get-buffer-create (format "*Harness Search: %s*"
                                           (harness-session-name session)))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (special-mode)
        (insert (propertize (format "%d match%s for %s\n\n"
                                    (length results)
                                    (if (= (length results) 1) "" "es")
                                    regexp)
                            'face 'bold))
        (dolist (result results)
          (let ((start (point)))
            (insert (propertize (format "#%d %s [%s]\n"
                                        (plist-get result :index)
                                        (harness-format-time
                                         (harness-message-timestamp
                                          (plist-get result :message)))
                                        (plist-get result :field))
                                'face 'harness-role-tool))
            (insert (format "    %s\n\n" (plist-get result :text)))
            (insert-text-button "jump"
                                'action (lambda (button)
                                          (harness-conversation-display-message
                                           session (button-get button 'harness-message)))
                                'harness-message (plist-get result :message)
                                'follow-link t
                                'face 'harness-muted)
            (insert "\n\n")
            (put-text-property start (point) 'harness-search-result result)))))
    (display-buffer buffer '(display-buffer-at-bottom (window-height . 0.4)))
    buffer))

(defun harness-conversation-next-message ()
  "Move to the next message header."
  (interactive)
  (let ((positions (harness-conversation--message-starts))
        (here (point)))
    (if-let* ((next (seq-find (lambda (position) (> position here)) positions)))
        (goto-char next)
      (goto-char (point-max)))))

(defun harness-conversation-previous-message ()
  "Move to the previous message header."
  (interactive)
  (let ((positions (harness-conversation--message-starts))
        (here (point)))
    (if-let* ((previous (car (last (seq-filter (lambda (position) (< position here))
                                               positions)))))
        (goto-char previous)
      (goto-char (point-min)))))

(defun harness-conversation--message-starts ()
  "Return the buffer positions of every rendered message header."
  (let (positions)
    (maphash (lambda (_id markers)
               (push (marker-position (plist-get markers :start)) positions))
             harness-conversation--message-markers)
    (sort positions #'<)))

(defmacro harness-conversation--define-or-insert (name command)
  "Define NAME: type the invoked key in the input area, else call COMMAND.

The input area shares its keymap with the transcript, so only the command can
know where point is (the same trick as `harness-conversation-tab')."
  (declare (indent 1))
  `(defun ,name ()
     ,(concat "Insert the typed key when point is in the input area.\n\n"
              "Elsewhere in the buffer the same key calls\n`"
              (symbol-name command) "'.")
     (interactive)
     (if (harness-conversation--input-p)
         (self-insert-command 1)
       (call-interactively #',command))))

(harness-conversation--define-or-insert
  harness-conversation--next-message-or-insert harness-conversation-next-message)
(harness-conversation--define-or-insert
  harness-conversation--previous-message-or-insert harness-conversation-previous-message)
(harness-conversation--define-or-insert
  harness-conversation--refresh-or-insert harness-conversation-refresh)
(harness-conversation--define-or-insert
  harness-conversation--bury-or-insert bury-buffer)
(harness-conversation--define-or-insert
  harness-conversation--scroll-or-insert scroll-up-command)

(defun harness-conversation-display-message (session message)
  "Show SESSION's buffer with point at MESSAGE.
This is the entry point other views (the tree, the session list) use."
  (let ((buffer (harness-conversation-open session)))
    (with-current-buffer buffer
      (unless (gethash (harness-message-id message)
                       harness-conversation--message-markers)
        (setq harness-conversation--limit nil)
        (harness-conversation--build))
      (when-let* ((markers (gethash (harness-message-id message)
                                    harness-conversation--message-markers)))
        (goto-char (marker-position (plist-get markers :start)))
        (recenter 2)))
    buffer))

(defun harness-conversation-tab ()
  "Complete in the input area, fold output elsewhere.

One key, because TAB on a line of the transcript clearly means \"fold this\"
and TAB while typing clearly means \"complete this\"."
  (interactive)
  (if (harness-conversation--input-p)
      (completion-at-point)
    (harness-conversation-toggle-fold)))

(defun harness-conversation-toggle-fold ()
  "Fold or unfold the block at point."
  (interactive)
  (let ((candidates
         (seq-filter (lambda (fold)
                       (and (<= (marker-position (plist-get fold :start)) (point))
                            (<= (point) (marker-position (plist-get fold :end)))))
                     harness-conversation--folds)))
    ;; Point is often on a tool header line, above the folded body, so fall
    ;; back to the innermost fold of the tool block containing point.
    (unless candidates
      (let ((block (harness-conversation--tool-block-at-point)))
        (when block
          (setq candidates
                (seq-filter (lambda (fold)
                              (and (<= (car block) (marker-position (plist-get fold :start)))
                                   (<= (marker-position (plist-get fold :end)) (cdr block))))
                            harness-conversation--folds)))))
    (if (null candidates)
        (user-error "Nothing to fold here")
      (let* ((fold (car (last candidates)))
             (start (marker-position (plist-get fold :start)))
             (end (marker-position (plist-get fold :end)))
             (hide (not (plist-get fold :hidden))))
        (let ((inhibit-read-only t))
          (if hide
              (put-text-property start end 'invisible 'harness-fold)
            (remove-text-properties start end '(invisible nil))))
        (plist-put fold :hidden hide)
        (when hide (goto-char start))))))

(defun harness-conversation--tool-block-at-point ()
  "Return the (START . END) of the tool block containing point, or nil."
  (let (found)
    (maphash (lambda (_id markers)
               (let ((start (marker-position (car markers)))
                     (end (marker-position (cdr markers))))
                 (when (and start end (<= start (point)) (<= (point) end))
                   (setq found (cons start end)))))
             harness-conversation--tool-markers)
    found))

(defun harness-conversation-toggle-thinking ()
  "Show or hide reasoning traces in this buffer."
  (interactive)
  (setq harness-ui-show-thinking (not harness-ui-show-thinking))
  (harness-conversation--build)
  (message "Thinking traces %s" (if harness-ui-show-thinking "shown" "hidden")))

(defun harness-conversation--reload-buffers ()
  "Re-render every conversation buffer after a reload."
  (dolist (session (harness-session-all))
    (when-let* ((buffer (harness-session-buffer session)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (harness-conversation--build))))))

(add-hook 'harness-after-reload-hook #'harness-conversation--reload-buffers)

(provide 'harness-ui-conversation)
;;; harness-ui-conversation.el ends here
