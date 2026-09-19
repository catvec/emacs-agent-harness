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
(require 'display-line-numbers)
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

(defcustom harness-ui-input-display-action
  '((display-buffer-in-side-window)
    (side . bottom)
    (window-height . 2)
    (slot . 1))
  "`display-buffer' action for the input side window.
The input lives in its own buffer so it stays pinned to the bottom of the
frame instead of floating up under a short transcript.  Keep the
`window-height' here in step with `harness-ui-input-min-height'."
  :type '(repeat sexp)
  :group 'harness-ui)

(defcustom harness-ui-input-min-height 2
  "Smallest height, in lines, of the input side window.
The input shrinks back to this height when its contents are cleared."
  :type 'integer
  :group 'harness-ui)

(defcustom harness-ui-input-max-height 10
  "Largest height, in lines, the input side window grows to.
The window grows with the message being composed and stops here; a longer
message scrolls inside the window instead of covering the transcript."
  :type 'integer
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

(defvar-local harness-conversation--input-buffer nil
  "SESSION's input buffer, set in the transcript buffer.")

(defun harness-conversation--no-line-numbers ()
  "Opt the current buffer out of `display-line-numbers-mode'.

Neither the transcript nor the editable input is source code, and the
line-number gutter pushes the `❯' prompt to the right.  Toggle the mode off
rather than `setq-local'ing `display-line-numbers' directly: only an explicit
toggle marks the buffer as deliberately configured, which is what lets
`global-display-line-numbers-mode' leave it alone."
  (display-line-numbers-mode -1))

(defun harness-conversation--disable-line-numbers ()
  "Turn line numbers off in a harness buffer.

Run from `after-change-major-mode-hook' rather than from the mode bodies:
Doom enables `display-line-numbers-mode' from `text-mode-hook' (and other
major-mode hooks), which runs after a mode's body, so a body call would be
undone for the `text-mode'-derived input buffer.  This hook runs last, after
both those hooks and the globalized minor mode's turn-on."
  (when (derived-mode-p 'harness-conversation-mode
                        'harness-conversation-input-mode)
    (harness-conversation--no-line-numbers)))

(add-hook 'after-change-major-mode-hook #'harness-conversation--disable-line-numbers)

(defvar harness-conversation-mode-map
  (let ((map (make-sparse-keymap)))
    ;; `special-mode-map' is deliberately *not* the parent: it binds every
    ;; self-inserting key to `undefined' (`suppress-keymap').  The transcript
    ;; is read-only, so the keys below are free to mean navigation; typing
    ;; happens in `harness-conversation-input-mode' instead.
    ;;
    ;; A non-nil parent is still required: `define-derived-mode' splices in the
    ;; parent mode's keymap when a mode's own map has no parent.
    (set-keymap-parent map (make-sparse-keymap))
    (define-key map (kbd "C-c C-c") #'harness-conversation-send)
    (define-key map (kbd "C-c C-k") #'harness-conversation-clear-input)
    (define-key map (kbd "C-c C-b") #'harness-conversation-abort)
    (define-key map (kbd "C-c C-a") #'harness-conversation-approve)
    (define-key map (kbd "C-c C-d") #'harness-conversation-deny)
    ;; `C-c C-A' is the same event as `C-c C-a' (control does not case-fold),
    ;; so "always" needs a key of its own.
    (define-key map (kbd "C-c C-y") #'harness-conversation-approve-always)
    (define-key map (kbd "C-c C-t") #'harness-tree)
    (define-key map (kbd "C-c C-e") #'harness-queue-edit)
    (define-key map (kbd "C-c C-f") #'harness-conversation-search)
    (define-key map (kbd "C-c C-z") #'harness-compact-session)
    (define-key map (kbd "C-c C-m") #'harness-select-model)
    (define-key map (kbd "C-c C-l") #'harness-conversation-load-earlier)
    (define-key map (kbd "C-c C-w") #'harness-set-working-directory)
    (define-key map (kbd "TAB") #'harness-conversation-toggle-fold)
    (define-key map (kbd "<backtab>") #'harness-conversation-toggle-fold)
    (define-key map (kbd "n") #'harness-conversation-next-message)
    (define-key map (kbd "p") #'harness-conversation-previous-message)
    (define-key map (kbd "g") #'harness-conversation-refresh)
    (define-key map (kbd "q") #'bury-buffer)
    (define-key map (kbd "SPC") #'scroll-up-command)
    map)
  "Keymap for `harness-conversation-mode'.")

(define-derived-mode harness-conversation-mode special-mode "Harness"
  "Major mode for the transcript of a conversation with an agent.

Output is read-only; typing happens in the input side window (see
`harness-conversation-input-mode').
\\[harness-conversation-abort] aborts the run,
\\[harness-conversation-toggle-fold] folds tool output and
\\[harness-conversation-refresh] re-renders."
  (setq-local buffer-read-only nil)
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (setq-local scroll-conservatively 101)
  (setq-local cursor-in-non-selected-windows t)
  (add-to-invisibility-spec '(harness-fold . t))
  (setq-local header-line-format '(:eval (harness-conversation--header-line)))
  (add-hook 'kill-buffer-hook #'harness-conversation--kill-input nil t))

(defvar harness-conversation-input-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map text-mode-map)
    ;; `RET' sends, so the common case is one keystroke.  A newline is
    ;; `S-<return>'; `C-j' stays on `newline' as a fallback for terminals
    ;; that cannot report Shift+Return distinctly from Return.  `C-c C-c'
    ;; remains an alternative send for muscle memory.
    (define-key map (kbd "RET") #'harness-conversation-send)
    (define-key map (kbd "<return>") #'harness-conversation-send)
    (define-key map (kbd "S-<return>") #'newline)
    (define-key map (kbd "S-RET") #'newline)
    (define-key map (kbd "C-c C-c") #'harness-conversation-send)
    (define-key map (kbd "C-j") #'newline)
    (define-key map (kbd "C-c C-k") #'harness-conversation-clear-input)
    (define-key map (kbd "C-c C-b") #'harness-conversation-abort)
    (define-key map (kbd "C-c C-a") #'harness-conversation-approve)
    (define-key map (kbd "C-c C-y") #'harness-conversation-approve-always)
    (define-key map (kbd "C-c C-d") #'harness-conversation-deny)
    (define-key map (kbd "C-c C-t") #'harness-tree)
    (define-key map (kbd "C-c C-e") #'harness-queue-edit)
    (define-key map (kbd "TAB") #'completion-at-point)
    map)
  "Keymap for `harness-conversation-input-mode'.")

(define-derived-mode harness-conversation-input-mode text-mode "Harness-Input"
  "Major mode for the harness conversation input area.

\[harness-conversation-send] sends the message (also on `RET'), `S-<return>'
or \[newline] inserts a newline, \[harness-conversation-clear-input] clears
the area and \[harness-conversation-abort] aborts the run.  The window grows
with the message up to `harness-ui-input-max-height' lines and then scrolls."
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (setq-local mode-line-format
              '(:eval (harness-conversation-input--mode-line)))
  (add-hook 'after-change-functions #'harness-conversation-input--fit nil t)
  (add-hook 'completion-at-point-functions
            #'harness-attachments-completion-at-point nil t))

(defun harness-conversation-input--mode-line ()
  "Return the input window's mode line, which separates it from the transcript."
  (let ((session harness-conversation--session))
    (concat
     " "
     (propertize "Harness" 'face 'mode-line-buffer-id)
     (when session
       (concat
        " "
        (propertize (or (harness-session-model session) "no model")
                    'face 'mode-line-emphasis)
        (when (harness-session-status-detail session)
          (propertize (format " · %s" (harness-session-status-string session))
                      'face 'mode-line-inactive))
        (when (harness-session-approvals session)
          (propertize (format "  ⚠%d" (length (harness-session-approvals session)))
                      'face 'harness-approval))
        (when (harness-session-queue session)
          (propertize (format "  ✎%d" (harness-queue-length session))
                      'face 'harness-queue))))
     (when-let* ((hint (harness-key-hint #'harness-conversation-send
                                         harness-conversation-input-mode-map)))
       (concat "  " (propertize (format "%s send" hint) 'face 'mode-line-inactive)))
     " ")))

(defun harness-conversation-session (&optional buffer)
  "Return the session shown in BUFFER, or the current buffer."
  (buffer-local-value 'harness-conversation--session (or buffer (current-buffer))))

(defun harness-conversation--kill-input ()
  "Kill the input buffer that belongs to the current transcript buffer."
  (let ((input harness-conversation--input-buffer))
    (when (buffer-live-p input)
      (with-current-buffer input
        (setq buffer-read-only nil)
        (kill-buffer input)))))

(defun harness-conversation-input-buffer (session)
  "Return SESSION's input buffer, creating and initialising it if needed."
  (let* ((transcript (harness-session-buffer session))
         (buffer (and (buffer-live-p transcript)
                      (buffer-local-value 'harness-conversation--input-buffer
                                          transcript))))
    (unless (buffer-live-p buffer)
      (setq buffer (get-buffer-create
                    (format "*Harness Input: %s*" (harness-session-name session))))
      (with-current-buffer buffer
        (harness-conversation-input-mode)
        (setq harness-conversation--session session)
        (harness-conversation-input--reset)))
    (when (buffer-live-p transcript)
      (with-current-buffer transcript
        (setq harness-conversation--input-buffer buffer)))
    buffer))

(defun harness-conversation-buffer (session)
  "Return SESSION's conversation (transcript) buffer, creating it if needed."
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
    (harness-conversation-input-buffer session)
    buffer))

(defun harness-conversation-open (session &optional noshow)
  "Show SESSION's conversation, with the input pinned in a bottom side window.
With NOSHOW, only create the buffers."
  (let ((buffer (harness-conversation-buffer session))
        (input (harness-conversation-input-buffer session)))
    (unless noshow
      (if harness-ui-conversation-display-action
          (display-buffer buffer harness-ui-conversation-display-action)
        (pop-to-buffer-same-window buffer))
      (display-buffer input harness-ui-input-display-action)
      ;; The input is where the user types, so give it the cursor without
      ;; stealing the transcript's follow (which only moves transcript windows).
      (when-let* ((window (get-buffer-window input)))
        (select-window window)
        ;; `display-buffer' resets the side window to its configured height;
        ;; restore a taller window if the input was not empty.
        (with-current-buffer input
          (harness-conversation-input--fit))))
    buffer))

(defun harness-conversation-rename-buffer (session)
  "Refresh SESSION's conversation and input buffer names after a rename."
  (when-let* ((buffer (harness-session-buffer session)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (rename-buffer (format "*Harness: %s*" (harness-session-name session)) t))
      (let ((input (buffer-local-value 'harness-conversation--input-buffer buffer)))
        (when (buffer-live-p input)
          (with-current-buffer input
            (rename-buffer (format "*Harness Input: %s*"
                                   (harness-session-name session))
                           t)))))))


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
  "Create the transcript buffer skeleton and render it.

The message and extras markers use insertion type t so output grows
downwards.  The editable input lives in a separate buffer (see
`harness-conversation-input-mode'), so nothing here is editable."
  (let ((inhibit-read-only t)
        (windows (harness-conversation--windows-at-end)))
    (erase-buffer)
    (harness-conversation--forget-folds)
    (clrhash harness-conversation--message-markers)
    (clrhash harness-conversation--tool-markers)
    (insert "\n")
    (let ((messages-position (point)))
      (setq harness-conversation--messages-end (copy-marker messages-position t))
      (setq harness-conversation--extras-end (copy-marker messages-position t)))
    (harness-conversation--sync)
    (harness-conversation--follow windows)
    (goto-char (point-max))))

(defun harness-conversation-input--reset ()
  "Reset the input buffer to just its read-only prompt."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (let ((start (point)))
      (insert harness-ui-prompt)
      (put-text-property start (point) 'face 'harness-prompt)
      (put-text-property start (point) 'field 'harness-input)
      (harness-conversation--protect start (point))
      (setq harness-conversation--input-start (copy-marker (point))))
    (goto-char (point-max))))

(defun harness-conversation-input--fit (&rest _)
  "Grow or shrink the input window to fit its contents.
The window grows with the message being composed and stops at
`harness-ui-input-max-height' lines, scrolling to keep point visible beyond
that.  Called from `after-change-functions', so every edit -- including the
deletion that follows a send -- resizes the window."
  (dolist (window (get-buffer-window-list (current-buffer) nil t))
    (when (window-live-p window)
      (fit-window-to-buffer window
                            harness-ui-input-max-height
                            harness-ui-input-min-height)
      ;; `fit-window-to-buffer' measures from `window-start', so it will not
      ;; scroll a window that is already at the limit.  Keep the cursor (where
      ;; the next character goes) on screen when the contents do not fit.
      (with-selected-window window
        (unless (pos-visible-in-window-p (window-point window) window)
          (recenter -1))))))

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
          thinking-end thinking-fold)
      (harness-conversation--output (harness-conversation--message-header message))
      (insert "\n")
      (when (harness-message-thinking message)
        (let ((body-start (point)))
          (harness-conversation--output "thinking…\n" 'face 'harness-thinking)
          (harness-conversation--output (harness-message-thinking message)
                                        'face 'harness-thinking)
          ;; `thinking-end' is where later deltas are appended, so it stays
          ;; before the separator and streamed reasoning never runs into the
          ;; answer below it.
          (setq thinking-end (point))
          (insert "\n")
          (setq thinking-fold (harness-conversation--fold
                               body-start (point)
                               (not harness-ui-show-thinking)))))
      (let ((content-start (point)))
        (harness-conversation--render-content session message content-start)
        (let ((content-end (point)))
          (insert "\n")
          (let ((end (point)))
            ;; Everything in the block is output, including the newlines.
            (harness-conversation--protect start end)
            (list :start (copy-marker start)
                  :content-start (copy-marker content-start t)
                  :thinking-end (and thinking-end (copy-marker thinking-end t))
                  :thinking-fold thinking-fold
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
  "Render the approval prompts and queued messages after the messages.

The extras are written at `extras-end' and `messages-end' is left at their
start, so the next message lands above them.  If both markers advanced
together the region between them would stay empty and
`harness-conversation--clear-extras' could never remove the previous render,
duplicating every prompt on the next sync."
  (let ((session harness-conversation--session))
    (save-excursion
      (let ((start (marker-position harness-conversation--extras-end))
            (any nil))
        (goto-char start)
        (dolist (approval (harness-approval-pending session))
          ;; Questions have their own widget buffer; rendering Allow/Always/Deny
          ;; for one here would be nonsense.
          (when (eq (harness-approval-kind approval) 'tool)
            (harness-conversation--render-approval session approval)
            (setq any t)))
        (when (harness-session-queue session)
          (harness-conversation--render-queue session)
          (setq any t))
        (when any
          (insert "\n")
          (harness-conversation--protect start (point)))
        (set-marker harness-conversation--messages-end start)))))

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
    ;; The key is in the label: the buttons are clickable, but a user reading
    ;; the transcript should not have to guess how to answer from the keyboard.
    ;; The hint is looked up live (see `harness-key-hint'), never spelled out.
    (harness-conversation--output "  ")
    (harness-conversation--approval-button
     "Allow" #'harness-conversation-approve
     `(lambda (_) (harness-perms-resolve ,approval 'allow)))
    (harness-conversation--approval-button
     "Always" #'harness-conversation-approve-always
     `(lambda (_) (harness-perms-resolve ,approval 'allow-always)))
    (harness-conversation--approval-button
     "Deny" #'harness-conversation-deny
     `(lambda (_) (harness-perms-resolve ,approval 'deny)))
    (insert "\n")
    (let ((inhibit-read-only t))
      (put-text-property start (point) 'harness-approval approval))))

(defun harness-conversation--approval-button (label command action)
  "Insert clickable LABEL for ACTION, followed by COMMAND's live key hint."
  (harness-conversation--button label action)
  (when-let* ((hint (harness-key-hint command harness-conversation-mode-map)))
    (harness-conversation--output (concat " " hint)))
  (harness-conversation--output "  "))

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
      (if (eq kind 'thinking)
          (harness-conversation--append-thinking markers text)
        (harness-conversation--output-at
         (plist-get markers :content-end) text
         'face 'harness-message-body)))))
  (ignore session))

(defun harness-conversation--append-thinking (markers text)
  "Append streamed TEXT to MARKERS's reasoning region.

The message is rendered before the first delta arrives, so a streamed trace
usually has no region yet.  Open one with the \"thinking…\" label and the
newline that separates it from the answer, then append above that newline."
  (if-let* ((thinking-end (plist-get markers :thinking-end)))
      (let ((start (marker-position thinking-end)))
        (harness-conversation--output-at thinking-end text 'face 'harness-thinking)
        (harness-conversation--hide-thinking markers start))
    (harness-conversation--open-thinking markers text)))

(defun harness-conversation--open-thinking (markers text)
  "Open MARKERS's reasoning region with the first TEXT and return its marker."
  (let* ((content-start (plist-get markers :content-start))
         (body-start (marker-position content-start)))
    (harness-conversation--output-at content-start "thinking…\n"
                                     'face 'harness-thinking)
    ;; Remember the spot before the separator: the reasoning streams there,
    ;; so its deltas stay on one line and the answer keeps its own.
    (let ((insertion (marker-position content-start)))
      (harness-conversation--output-at content-start "\n" 'face 'harness-thinking)
      (let ((thinking-end (copy-marker insertion t)))
        (harness-conversation--output-at thinking-end text 'face 'harness-thinking)
        (plist-put markers :thinking-end thinking-end)
        (plist-put markers :thinking-fold
                   (harness-conversation--fold
                    body-start (marker-position content-start)
                    (not harness-ui-show-thinking)))
        thinking-end))))

(defun harness-conversation--hide-thinking (markers start)
  "Keep the reasoning appended at START hidden when MARKERS's fold is folded."
  (when-let* ((fold (plist-get markers :thinking-fold)))
    (when (plist-get fold :hidden)
      (harness-conversation--with-output
       (put-text-property start
                          (marker-position (plist-get markers :thinking-end))
                          'invisible 'harness-fold)))))

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

(defun harness-conversation-context-string (session)
  "Return the context usage string for SESSION, or nil.
Shown only once the context is filling, so the header line stays short.
Uses the context module when it is loaded; the header line must not require
it, so that a minimal install still renders."
  (when (and (fboundp 'harness-context-stats-string)
             (>= (harness-context-ratio session)
                 (if (boundp 'harness-context-warn-at)
                     (symbol-value 'harness-context-warn-at)
                   0.6)))
    (let* ((ratio (harness-context-ratio session))
           (string (harness-context-stats-string session)))
      (propertize (format "  ctx %s" string)
                  'face (if (>= ratio 0.9) 'harness-error 'harness-approval)))))

(declare-function harness-context-stats-string "harness-context" (session))
(declare-function harness-context-ratio "harness-context" (session))
(declare-function harness-context-search "harness-context"
                  (session regexp callback &optional limit))
(declare-function harness-compact-session "harness-context" (&optional session))

(defun harness-conversation--header-line ()
  "Return the header line text for the current conversation buffer.

Kept deliberately short: the input window's mode line and
`harness-describe-session' carry the directory, cost and token detail, and a
header line that overflows hides the status it exists to show.  The waiting
count, queue length and context ratio appear only when there is something to
say."
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
         (when (harness-session-approvals session)
           (concat
            (propertize (format "  ⚠%d " (length (harness-session-approvals session)))
                        'face 'harness-approval)
            (harness-key-hints
             (cons "allow" #'harness-conversation-approve)
             (cons "always" #'harness-conversation-approve-always)
             (cons "deny" #'harness-conversation-deny))))
         (when (harness-session-queue session)
           (propertize (format "  ✎%d" (harness-queue-length session))
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

(defun harness-conversation--current-input-buffer ()
  "Return the input buffer for the current buffer, or nil."
  (cond
   ((and (bound-and-true-p harness-conversation--input-start)
         harness-conversation--input-start)
    (current-buffer))
   (harness-conversation--session
    (harness-conversation-input-buffer harness-conversation--session))))

(defun harness-conversation--input (&optional buffer)
  "Return the text in BUFFER's input area, defaulting to the session's."
  (with-current-buffer (or buffer (harness-conversation--current-input-buffer)
                           (user-error "This buffer is not a harness conversation"))
    (buffer-substring-no-properties (marker-position harness-conversation--input-start)
                                    (point-max))))

(defun harness-conversation--clear-input ()
  "Delete the current input buffer's contents."
  (let ((inhibit-read-only t))
    (delete-region (marker-position harness-conversation--input-start) (point-max))))

(defun harness-conversation-send ()
  "Send the text in the input area to the session."
  (interactive)
  (let* ((input (harness-conversation--current-input-buffer))
         (session (and input
                       (buffer-local-value 'harness-conversation--session input)))
         (text (and input (string-trim (harness-conversation--input input)))))
    (unless session (user-error "This buffer is not a harness conversation"))
    (when (string-empty-p text)
      (user-error "Nothing to send"))
    (with-current-buffer input
      (harness-conversation--clear-input)
      (goto-char (point-max)))
    (harness-agent-send session text)
    ;; Point stays in the input; the transcript window follows the stream.
    (when-let* ((transcript (harness-session-buffer session)))
      (when (buffer-live-p transcript)
        (with-current-buffer transcript
          (harness-conversation--follow (harness-conversation--windows-at-end)))))))

(defun harness-conversation-send-text (session text)
  "Send TEXT to SESSION from anywhere."
  (interactive (list (or (harness-session--read-session "Send to")
                         (user-error "No live sessions"))
                     (read-string "Message: ")))
  (harness-agent-send session text))

(defun harness-conversation-clear-input ()
  "Clear the input area."
  (interactive)
  (let ((input (harness-conversation--current-input-buffer)))
    (unless input (user-error "This buffer is not a harness conversation"))
    (with-current-buffer input
      (harness-conversation--clear-input)
      (goto-char (point-max)))))

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

(defun harness-conversation-display-message (session message)
  "Show SESSION's transcript with point at MESSAGE.
This is the entry point other views (the tree, the session list) use."
  (let ((buffer (harness-conversation-open session)))
    (with-current-buffer buffer
      (unless (gethash (harness-message-id message)
                       harness-conversation--message-markers)
        (setq harness-conversation--limit nil)
        (harness-conversation--build))
      (when-let* ((markers (gethash (harness-message-id message)
                                    harness-conversation--message-markers)))
        (goto-char (marker-position (plist-get markers :start)))))
    ;; `harness-conversation-open' leaves point in the input; jumping to a
    ;; message means the transcript.  A batch test has no window to recenter.
    (when-let* ((window (get-buffer-window buffer)))
      (select-window window)
      (with-current-buffer buffer (recenter 2)))
    buffer))

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
