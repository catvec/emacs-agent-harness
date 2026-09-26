;;; harness-ui-chat.el --- The chat interface -*- lexical-binding: t; -*-

;; This file is part of Emacs Agent Harness.

;;; Commentary:

;; One buffer per session, showing the transcript top-to-bottom with the
;; message composer at the bottom.  Presentation is entirely Emacs-native:
;; faces for message types, `button' for every clickable action, overlays
;; for collapsing, `completion-at-point' for @-file references.
;;
;; All harness interaction goes through `harness-ui' (ACP); this buffer
;; never calls the session or agent modules.

;;; Code:

(require 'cl-lib)
(require 'button)
(require 'dnd)
(require 'project)
(require 'seq)
(require 'subr-x)
(require 'url-util)
(require 'harness-core)
(require 'harness-ui)

(defgroup harness-ui-chat nil
  "Harness chat buffers."
  :group 'harness-ui)

(defcustom harness-ui-chat-max-compose-height 10
  "Maximum visible height of the composer before it scrolls."
  :type 'natnum)

(defcustom harness-ui-chat-coalesce-tools
  '("read" "glob" "search" "list" "emacs-describe" "todo")
  "Tools whose consecutive calls may be coalesced into a summary.
Only non-blocking tools belong here; anything that can hold the session
(tools that ask, execute or edit) must stay visible."
  :type '(repeat string))

(defcustom harness-ui-chat-positions
  '((right . harness-ui-chat--display-right)
    (bottom . harness-ui-chat--display-bottom)
    (full . harness-ui-chat--display-full))
  "Named window presets for session buffers."
  :type '(alist :key-type symbol :value-type function))

(defcustom harness-ui-chat-auto-scroll t
  "Follow new messages when the end of the transcript is visible."
  :type 'boolean)

(defface harness-ui-user-face
  '((t :inherit (default secondary-selection) :weight bold :extend t))
  "Face for user messages.
Inheriting the theme's selection surface gives the message a bubble on
both light and dark themes without hardcoding a colour."
  :group 'harness-ui-chat)

(defface harness-ui-agent-face
  '((t :inherit default))
  "Face for agent messages."
  :group 'harness-ui-chat)

(defface harness-ui-thinking-face
  '((t :inherit shadow :slant italic))
  "Face for thinking text."
  :group 'harness-ui-chat)

(defface harness-ui-hint-face
  '((t :inherit shadow :height 0.9))
  "Face for harness system hints."
  :group 'harness-ui-chat)

(defface harness-ui-tool-face
  '((t :inherit font-lock-keyword-face))
  "Face for tool call labels."
  :group 'harness-ui-chat)

(defface harness-ui-tool-body-face
  '((t :inherit font-lock-string-face))
  "Face for tool output."
  :group 'harness-ui-chat)

(defface harness-ui-code-face
  '((t :inherit (fixed-pitch secondary-selection) :extend t))
  "Face for code blocks and inline code."
  :group 'harness-ui-chat)

(defface harness-ui-header-face
  '((t :inherit bold :height 1.05))
  "Face for markdown headings."
  :group 'harness-ui-chat)

(defface harness-ui-compose-face
  '((t :inherit default))
  "Face of the composer area."
  :group 'harness-ui-chat)

(defface harness-ui-prompt-face
  '((t :inherit shadow))
  "Face of the composer's prompt glyph."
  :group 'harness-ui-chat)

(defface harness-ui-tool-name-face
  '((t :inherit font-lock-keyword-face))
  "Face for the tool name in a tool call line."
  :group 'harness-ui-chat)

(defface harness-ui-tool-done-face
  '((t :inherit success))
  "Face for a finished tool call on the transcript line."
  :group 'harness-ui-chat)

(defface harness-ui-tool-failed-face
  '((t :inherit error))
  "Face for a failed tool call on the transcript line."
  :group 'harness-ui-chat)

(defface harness-ui-separator-face
  '((t :inherit shadow :extend t))
  "Face for structural separators."
  :group 'harness-ui-chat)

;;; Buffer state

(defvar-local harness-ui-chat--session-id nil
  "Session shown in this buffer.")

(defvar-local harness-ui-chat--info nil
  "Last session info plist.")

(defvar-local harness-ui-chat--status nil
  "Last known status symbol.")

(defvar-local harness-ui-chat--records nil
  "Rendered entry records, newest first.")
(defvar-local harness-ui-chat--needs-rebuild nil
  "Non-nil when the transcript must be re-laid-out before display.")

(defvar-local harness-ui-chat--queue nil
  "Client-side queue of (blocks . text) waiting for the next turn.")

(defvar-local harness-ui-chat--attachments nil
  "Files attached to the next message.")

(defvar-local harness-ui-chat--compose-start nil
  "Marker where the composer body starts.")

(defvar-local harness-ui-chat--compose-end nil
  "Marker just after the composer body (before its trailing newline).
Insertion type is t so typed text stays inside the body.")

(defvar-local harness-ui-chat--transcript-end nil
  "Marker where the transcript ends and the composer begins.")

(defvar-local harness-ui-chat--position nil
  "Position preset this buffer was opened with.")

(defvar harness-ui-chat--buffers (make-hash-table :test #'equal)
  "Session id -> chat buffer.")

(defvar harness-ui-chat--position-buffer (make-hash-table :test #'eq)
  "Position preset -> session id currently shown there.")

;;; Faces and text helpers

(defun harness-ui-chat--insert (string &rest properties)
  "Insert STRING with PROPERTIES."
  (insert (apply #'propertize string properties)))

(defun harness-ui-chat--button (label callback &rest properties)
  "Insert a button LABEL that calls CALLBACK.
PROPERTIES may carry :help-echo and :face; FACE is layered over the
theme's `button' face, which keeps action buttons looking like links
while quiet toggles can stay in the shadow face."
  (let ((start (point)))
    (insert-text-button label
                        'action (lambda (_button) (funcall callback))
                        'follow-link t
                        'mouse-face 'highlight
                        'help-echo (or (plist-get properties :help-echo)
                                       (format-message "Click: %s" label)))
    (when-let* ((face (plist-get properties :face)))
      (add-face-text-property start (point) face))))

(defun harness-ui-chat--toggle (label record &rest properties)
  "Insert LABEL as a clickable collapse toggle for RECORD.
The :face property replaces the theme's link-looking `button' face so
quiet toggles stay quiet."
  (let ((start (point)))
    (insert-text-button label
                        'action (lambda (_button) (harness-ui-chat-toggle record))
                        'follow-link t
                        'mouse-face 'highlight
                        'help-echo (or (plist-get properties :help-echo)
                                       "Show or hide this block")
                        'keymap harness-ui-chat--tool-line-keymap
                        'harness-ui-chat-record record)
    ;; Set the face last: button.el installs the link-looking `button'
    ;; face through the category, which otherwise wins over :face.
    (add-text-properties start (point)
                         (list 'face (or (plist-get properties :face) 'shadow)))))

(defun harness-ui-chat--mark-read-only (start end)
  "Mark START to END as read-only transcript text."
  (add-text-properties start end '(read-only t front-sticky t rear-nonsticky t)))

;;; Markdown-lite fontification

(defun harness-ui-chat--fontify (start end)
  "Render the markdown subset between START and END.
Faces style the text; structural markers are collapsed with display
properties so headings, emphasis, code and bullets read naturally while
the original text stays searchable."
  (let ((inhibit-read-only t))
    (save-excursion
      ;; Headings: hide the hashes, style the whole line.
      (goto-char start)
      (while (re-search-forward "^\\(#\\{1,6\\}\\) \\(.*\\)$" end t)
        (let ((hash-start (match-beginning 1))
              (hash-end (match-end 1)))
          (add-face-text-property (line-beginning-position) (line-end-position)
                                  'harness-ui-header-face)
          (add-text-properties hash-start (1+ hash-end) '(display ""))))
      ;; Bullets.
      (goto-char start)
      (while (re-search-forward "^\\([-*]\\) " end t)
        (let ((marker-start (match-beginning 1))
              (marker-end (match-end 1)))
          (add-text-properties marker-start marker-end '(display ""))
          (add-text-properties marker-end (1+ marker-end)
                               (list 'display (propertize "• " 'face 'shadow)))))
      ;; Block quotes: a quiet vertical rule instead of the markdown `>'.
      (goto-char start)
      (while (re-search-forward "^\\(>\\) \\(.*\\)$" end t)
        (add-text-properties (match-beginning 1) (1+ (match-beginning 1))
                             (list 'display (propertize "│ " 'face 'shadow)))
        (add-face-text-property (match-beginning 2) (match-end 2) 'shadow))
      ;; Inline emphasis and code: hide the markers, style the contents.
      (dolist (rule '(("\\*\\*\\([^*\n]+\\)\\*\\*" bold)
                      ("`\\([^`\n]+\\)`" harness-ui-code-face)))
        (goto-char start)
        (while (re-search-forward (nth 0 rule) end t)
          (let ((inner-start (match-beginning 1))
                (inner-end (match-end 1))
                (full-start (match-beginning 0))
                (full-end (match-end 0)))
            (add-face-text-property inner-start inner-end (nth 1 rule))
            (add-text-properties full-start inner-start '(display ""))
            (add-text-properties inner-end full-end '(display "")))))
      ;; _italic_ (word boundaries are unreliable around underscores).
      (goto-char start)
      (while (re-search-forward "\\(^\\|\\s-\\|[(\\[]\\)\\(_\\([^_\n]+\\)_\\)" end t)
        (let ((inner-start (match-beginning 3))
              (inner-end (match-end 3))
              (open-start (match-beginning 2))
              (close-end (match-end 2)))
          (add-face-text-property inner-start inner-end 'italic)
          (add-text-properties open-start inner-start '(display ""))
          (add-text-properties inner-end close-end '(display ""))))
      ;; Fenced code blocks: hide the fences completely (newline included,
      ;; otherwise their :extend face paints full-width bars) and style the
      ;; body lines.
      (goto-char start)
      (while (re-search-forward "^```" end t)
        (let* ((opening-start (line-beginning-position))
               (body-start (1+ (line-end-position))))
          (if (re-search-forward "^```[ \t]*$" end t)
              (let ((body-end (line-beginning-position))
                    (closing-end (min (1+ (line-end-position)) (point-max))))
                (when (< body-start body-end)
                  (add-face-text-property body-start body-end 'harness-ui-code-face))
                (add-text-properties opening-start body-start '(display ""))
                (add-text-properties body-end closing-end '(display "")))
            (goto-char end)))))))


;;; Entry model

(cl-defstruct (harness-ui-chat-record (:constructor harness-ui-chat-record-create))
  key kind text status tool-name title raw-input children collapsed start end)

(defun harness-ui-chat--previous-record (record)
  "Return the record laid out before RECORD, if any.
`harness-ui-chat--records' keeps newest first."
  (cadr (memq record harness-ui-chat--records)))

(defun harness-ui-chat--inline-record-p (record)
  "Return non-nil when RECORD renders as a single collapsed line."
  (and (harness-ui-chat--collapsible-p record)
       (harness-ui-chat-record-collapsed record)))

(defun harness-ui-chat--ensure-gap-before (record)
  "Insert a blank separator line before RECORD when it follows a block."
  (let ((previous (harness-ui-chat--previous-record record)))
    (when (and previous
               (not (harness-ui-chat--inline-record-p previous))
               (>= (point) 2)
               (not (and (eq (char-before (1- (point))) ?\n)
                         (eq (char-before) ?\n))))
      (insert "\n"))))

(defun harness-ui-chat--key (update)
  "Return a stable key for UPDATE."
  (or (plist-get update :messageId)
      (plist-get update :toolCallId)
      (plist-get update :id)
      (harness-uuid)))

(defun harness-ui-chat--kind (update)
  "Return the sessionUpdate kind of UPDATE."
  (plist-get update :sessionUpdate))

(defun harness-ui-chat--collapsible-p (record)
  "Return non-nil when RECORD should be collapsible."
  (member (harness-ui-chat-record-kind record)
          '("tool_call" "tool_call_update" "agent_thought_chunk")))

(defun harness-ui-chat--coalescable-p (record)
  "Return non-nil when RECORD may be folded into a tool run."
  (and (equal (harness-ui-chat-record-kind record) "tool_call")
       (member (harness-ui-chat-record-tool-name record)
               harness-ui-chat-coalesce-tools)
       t))

(defun harness-ui-chat--record-for (key)
  "Return the record with KEY in the current buffer."
  (seq-find (lambda (record) (equal (harness-ui-chat-record-key record) key))
            harness-ui-chat--records))

;;; Rendering

(defun harness-ui-chat--render-record (record)
  "Insert RECORD's rendering at point and return it."
  (setf (harness-ui-chat-record-start record) (copy-marker (point)))
  (harness-ui-chat--ensure-gap-before record)
  (pcase (harness-ui-chat-record-kind record)
    ((or "user_message_chunk" "agent_message_chunk" "agent_thought_chunk"
         "_harness/system_hint")
     (harness-ui-chat--render-message record))
    ((or "tool_call" "tool_call_update")
     (harness-ui-chat--render-tool record))
    ("tool_run"
     (harness-ui-chat--render-tool-run record))
    ("_harness/todo"
     (harness-ui-chat--render-todo record))
    ("plan"
     (harness-ui-chat--render-plan record))
    ((or "usage_update" "available_commands_update" "current_mode_update"
         "config_option_update" "session_info_update")
     nil))
  (setf (harness-ui-chat-record-end record) (copy-marker (point)))
  record)

(defun harness-ui-chat--first-line (text &optional width)
  "First non-empty line of TEXT, truncated to WIDTH."
  (let ((line (car (seq-filter (lambda (line) (not (string-empty-p (string-trim line))))
                               (split-string (or text "") "\n")))))
    (when line
      (truncate-string-to-width (string-trim line) (or width 68) nil nil "…"))))

(defun harness-ui-chat--render-message (record)
  "Render a text RECORD."
  (let* ((kind (harness-ui-chat-record-kind record))
         (text (string-trim-right (or (harness-ui-chat-record-text record) "") "[ \t\n\r]+"))
         (face (pcase kind
                 ("user_message_chunk" 'harness-ui-user-face)
                 ("agent_thought_chunk" 'harness-ui-thinking-face)
                 ("_harness/system_hint" 'harness-ui-hint-face)
                 (_ 'harness-ui-agent-face)))
         (collapsible (harness-ui-chat--collapsible-p record))
         (collapsed (and collapsible (harness-ui-chat-record-collapsed record)))
         (start (point)))
    (pcase kind
      ("agent_thought_chunk"
       (insert (propertize (if collapsed "▸ " "▾ ") 'face 'shadow))
       (harness-ui-chat--toggle
        (let ((lines (length (split-string text "\n" t))))
          (concat "Thinking"
                  (if collapsed
                      (let ((preview (harness-ui-chat--first-line text)))
                        (if (and preview (not (string-empty-p preview)))
                            (concat "  " preview)
                          ""))
                    (format " (%d %s)" lines (if (= lines 1) "line" "lines")))))
        record
        :face 'harness-ui-thinking-face
        :help-echo "Show or hide the thinking")
       (unless collapsed
         (insert "\n")
         (let ((body (point)))
           (insert (propertize text 'face face))
           (harness-ui-chat--fontify body (point)))))
      ("_harness/system_hint"
       (insert (propertize "· " 'face face))
       (insert (propertize text 'face face)))
      (_
       (when (equal kind "user_message_chunk")
         (insert (propertize "› " 'face 'shadow)))
       (let ((body (point)))
         (insert (propertize text 'face face))
         (harness-ui-chat--render-attachments record)
         ;; Fontify first, then layer the message face on top: markdown
         ;; sets faces itself and `add-face-text-property' appends.
         (harness-ui-chat--fontify body (point))
         (add-face-text-property body (point) face))))
    (insert "\n")
    (when (member kind '("user_message_chunk" "agent_message_chunk"))
      ;; The newline carries the face too so `:extend' fills the line.
      (add-face-text-property (1- (point)) (point) face))
    (harness-ui-chat--mark-read-only start (point))
    record))

(defun harness-ui-chat--render-attachments (record)
  "Render image/audio blocks attached to RECORD."
  (dolist (block (append (harness-ui-chat-record-children record) nil))
    (when (equal (plist-get block :type) "image")
      (let ((data (plist-get block :data))
            (mime (plist-get block :mime-type)))
        (insert "\n")
        (if (and (display-graphic-p) data
                 (fboundp 'create-image))
            (condition-case nil
                (insert-image (create-image (base64-decode-string data)
                                            (intern (or (and mime
                                                             (car (split-string
                                                                   (cadr (split-string mime "/")))))
                                                        "png"))
                                            t)
                              "[image]")
              (error (insert "[image]")))
          (insert "[image]"))))))

(defun harness-ui-chat--tool-status-label (record)
  "Return a human label for RECORD's tool status."
  (pcase (harness-ui-chat-record-status record)
    ("pending" "waiting")
    ("in_progress" "running")
    ("completed" "done")
    ("failed" "failed")
    (_ "")))

(defun harness-ui-chat--tool-status-face (record)
  "Face for RECORD's status word."
  (pcase (harness-ui-chat-record-status record)
    ("completed" 'harness-ui-tool-done-face)
    ("failed" 'harness-ui-tool-failed-face)
    (_ 'shadow)))

(defconst harness-ui-chat--tool-argument-keys
  '(:path :file :file_path :filePath :command :query :pattern :glob :url :skill :text :name)
  "Argument keys used, in order, to summarise a tool call.")

(defun harness-ui-chat--tool-argument (raw-input key)
  "Return KEY's value from RAW-INPUT (plist or JSON hash table)."
  (let ((name (substring (symbol-name key) 1)))
    (cond
     ((hash-table-p raw-input) (gethash name raw-input))
     ((and (listp raw-input) (plist-member raw-input key)) (plist-get raw-input key))
     (t nil))))

(defun harness-ui-chat--tool-summary (record)
  "A short, human description of what RECORD's tool call acts on."
  (let ((raw (harness-ui-chat-record-raw-input record)))
    (when (and raw (not (equal raw [])))
      (let ((value (seq-some (lambda (key)
                               (let ((value (harness-ui-chat--tool-argument raw key)))
                                 (when (and value (not (equal value "")))
                                   value)))
                             harness-ui-chat--tool-argument-keys)))
        (cond
         ((null value) nil)
         ((stringp value)
          (let ((value (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " value))))
            (when (not (string-empty-p value))
              (truncate-string-to-width value 72 nil nil "…"))))
         ((numberp value) (number-to-string value))
         (t nil))))))

(defun harness-ui-chat--render-tool-line (record)
  "Render RECORD's one-line tool summary.
Returns non-nil when the line was rendered, leaving point on it."
  (let* ((name (or (harness-ui-chat-record-tool-name record) "tool"))
         (status (harness-ui-chat--tool-status-label record))
         (summary (harness-ui-chat--tool-summary record))
         (collapsible (harness-ui-chat--collapsible-p record))
         (collapsed (and collapsible (harness-ui-chat-record-collapsed record))))
    (when collapsible
      (insert (propertize (if collapsed "▸ " "▾ ") 'face 'shadow)))
    (let ((line-start (point)))
      (insert (propertize name 'face 'harness-ui-tool-name-face))
      (when summary
        (insert " " (propertize summary 'face 'default)))
      (when (not (string-empty-p status))
        (insert (propertize (concat " · " status) 'face (harness-ui-chat--tool-status-face record))))
      ;; Keep the whole label clickable for the collapse toggle.
      (when collapsible
        (with-silent-modifications
          (add-text-properties line-start (point)
                               (list 'keymap harness-ui-chat--tool-line-keymap
                                     'mouse-face 'highlight
                                     'help-echo "Show or hide the call details"
                                     'harness-ui-chat-record record))))
      (unless collapsed
        (let ((text (string-trim-right (or (harness-ui-chat-record-text record) "") "[ \t\n\r]+")))
          (when (not (string-empty-p text))
            (insert "\n")
            (let ((body (point)))
              (insert (propertize text 'face 'harness-ui-tool-body-face))
              (add-face-text-property body (point) 'harness-ui-tool-body-face)))))
      (insert "\n")
      t)))

(defvar harness-ui-chat--tool-line-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'harness-ui-chat--tool-line-click)
    (define-key map [mouse-2] #'harness-ui-chat--tool-line-click)
    (define-key map "\r" #'harness-ui-chat--tool-line-click)
    map)
  "Keymap on tool call lines.")

(defun harness-ui-chat--tool-line-click (event)
  "Toggle the tool record under EVENT."
  (interactive "e")
  (let* ((position (event-start event))
         (record (get-pos-property (posn-point position)
                                   'harness-ui-chat-record
                                   (window-buffer (posn-window position)))))
    (when record
      (harness-ui-chat-toggle record))))

(defun harness-ui-chat--render-tool-run (record)
  "Render a coalesced run of allow-listed tool calls."
  (let* ((children (harness-ui-chat-record-children record))
         (counts nil)
         (start (point)))
    (dolist (child children)
      (let ((name (harness-ui-chat-record-tool-name child)))
        (setf (alist-get name counts nil nil #'equal)
              (1+ (or (alist-get name counts nil nil #'equal) 0)))))
    (harness-ui-chat--insert
     (if (harness-ui-chat-record-collapsed record) "▸ " "▾ ") 'face 'shadow)
    (harness-ui-chat--toggle
     (format "tools %s"
             (string-join (mapcar (lambda (entry)
                                    (format "%s ×%d" (car entry) (cdr entry)))
                                  (nreverse counts))
                          ", "))
     record
     :face 'harness-ui-tool-face
     :help-echo "Show or hide these tool calls")
    (unless (harness-ui-chat-record-collapsed record)
      (insert "\n")
      (dolist (child children)
        (insert "  ")
        (harness-ui-chat--render-record child)))
    (insert "\n")
    (add-face-text-property start (point) 'harness-ui-tool-face)
    (harness-ui-chat--mark-read-only start (point))))

(defun harness-ui-chat--render-tool (record)
  "Render a tool call RECORD."
  (let ((start (point)))
    (harness-ui-chat--render-tool-line record)
    (harness-ui-chat--mark-read-only start (point))))

(defun harness-ui-chat--render-todo (record)
  "Render the todo list RECORD."
  (let ((start (point)))
    (insert (propertize "Todos\n" 'face 'harness-ui-header-face))
    (insert (propertize (or (harness-ui-chat-record-text record) "")
                        'face 'harness-ui-tool-body-face))
    (insert "\n")
    (harness-ui-chat--mark-read-only start (point))))

(defun harness-ui-chat--render-plan (record)
  "Render a plan RECORD with its markdown body."
  (let ((start (point))
        (title (or (harness-ui-chat-record-title record) "Plan")))
    (insert (propertize title 'face 'harness-ui-header-face))
    (insert "\n")
    (let ((body (point)))
      (insert (or (harness-ui-chat-record-text record) ""))
      (harness-ui-chat--fontify body (point)))
    (insert "\n")
    (harness-ui-chat--mark-read-only start (point))))

(defun harness-ui-chat--rerender (record)
  "Redraw RECORD's region in place (contents only, no re-layout).
Falls back to a full layout when the record markers are stale (which can
happen after a reload re-adopts a buffer)."
  (let* ((inhibit-read-only t)
         (start (harness-ui-chat--safe-marker-position
                 (harness-ui-chat-record-start record)))
         (end (harness-ui-chat--safe-marker-position
               (harness-ui-chat-record-end record))))
    (if (and start end (<= start end))
        (progn
          (delete-region start end)
          (save-excursion
            (goto-char start)
            (harness-ui-chat--render-record record)))
      ;; Stale markers: lay the whole transcript out again.
      (setq harness-ui-chat--needs-rebuild t))))

(defun harness-ui-chat-toggle (record)
  "Toggle collapse state of RECORD."
  (setf (harness-ui-chat-record-collapsed record)
        (not (harness-ui-chat-record-collapsed record)))
  (harness-ui-chat--rerender record))

(defun harness-ui-chat--insert-record (record)
  "Queue RECORD for the next transcript layout."
  (push record harness-ui-chat--records)
  (setq harness-ui-chat--needs-rebuild t))

(defun harness-ui-chat-rebuild ()
  "Lay the transcript out from scratch above the composer.
Rendering every record in order is cheap enough for structural changes
and keeps ordering exact; streaming deltas only re-render their own
region."
  ;; Buffers created before this mode turned font-lock off still have its
  ;; idle fontifier running; it would strip the manually applied faces.
  (when font-lock-mode
    (font-lock-mode -1))
  (let ((inhibit-read-only t)
        (compose-offset (let ((end (harness-ui-chat--safe-marker-position
                                    harness-ui-chat--transcript-end)))
                          (when (and end (>= (point) end))
                            (- (point) end))))
        (compose-text (harness-ui-chat--compose-text)))
    (erase-buffer)
    (setq harness-ui-chat--transcript-end nil
          harness-ui-chat--compose-start nil
          harness-ui-chat--compose-end nil
          harness-ui-chat--needs-rebuild nil)
    (if (null harness-ui-chat--records)
        (insert (propertize "Ready when you are.\n\n" 'face 'bold)
                (propertize (concat "  Type a message and press RET\n\n"
                                    "  @ file reference      C-c C-s  sessions\n"
                                    "  # skill               C-c C-m  model\n"
                                    "  C-c C-q queue         C-c C-p  permissions\n"
                                    "  C-c C-k cancel        C-c C-t  thinking\n")
                            'face 'shadow))
      (dolist (record (reverse harness-ui-chat--records))
        ;; One malformed record must not cost the user their transcript.
        (condition-case err
            (harness-ui-chat--render-record record)
          (error
           (harness-log "cannot render %s record: %S"
                        (harness-ui-chat-record-kind record) err)))))
    (harness-ui-chat--render-composer compose-text)
    (when compose-offset
      (goto-char (min (point-max)
                      (+ (marker-position harness-ui-chat--transcript-end)
                         compose-offset))))))

;;; Updates from the harness

(defun harness-ui-chat--apply-update (buffer _session-id update)
  "Apply UPDATE in BUFFER."
  (with-current-buffer buffer
    (let* ((kind (harness-ui-chat--kind update))
           (key (harness-ui-chat--key update))
           (record (harness-ui-chat--record-for key))
           (text (harness-ui-chat--update-text update))
           (live (plist-get update :live)))
      (cond
       ;; Streaming delta: extend the live record.
       ((and live (plist-get update :delta))
        (if record
            (progn
              (setf (harness-ui-chat-record-text record)
                    (concat (or (harness-ui-chat-record-text record) "")
                            (plist-get update :delta)))
              (harness-ui-chat--rerender record))
          (let ((new (harness-ui-chat-record-create
                      :key key :kind kind :text (or text (plist-get update :delta))
                      :title (plist-get update :title)
                      :raw-input (plist-get update :rawInput)
                      :collapsed (not (member kind '("agent_message_chunk"))))))
            (harness-ui-chat--insert-record new))))
       ;; Live begin (no delta yet).
       ((and live (null record))
        (let ((new (harness-ui-chat-record-create
                    :key key :kind kind :text (or text "")
                    :tool-name (plist-get update :name)
                    :title (plist-get update :title)
                    :raw-input (plist-get update :rawInput)
                    :status (plist-get update :status)
                    :collapsed (not (member kind '("agent_message_chunk"))))))
          (harness-ui-chat--insert-record new)))
       (t
        (if record
            (progn
              (setf (harness-ui-chat-record-text record) (or text (harness-ui-chat-record-text record))
                    (harness-ui-chat-record-status record) (or (plist-get update :status)
                                                               (harness-ui-chat-record-status record))
                    (harness-ui-chat-record-tool-name record)
                    (or (plist-get update :name) (harness-ui-chat-record-tool-name record))
                    (harness-ui-chat-record-title record)
                    (or (plist-get update :title) (harness-ui-chat-record-title record))
                    (harness-ui-chat-record-raw-input record)
                    (or (plist-get update :rawInput) (harness-ui-chat-record-raw-input record)))
              (harness-ui-chat--rerender record))
          (let ((new (harness-ui-chat-record-create
                      :key key :kind kind :text (or text "")
                      :tool-name (plist-get update :name)
                      :title (plist-get update :title)
                      :status (plist-get update :status)
                      :collapsed (not (member kind '("agent_message_chunk")))
                      :children (plist-get update :content))))
            (harness-ui-chat--insert-record new)
            ;; Coalesce a run of allow-listed tool calls.
            (when (harness-ui-chat--coalescable-p new)
              (harness-ui-chat--absorb-into-tool-run new))))))
      (when (and harness-ui-chat-auto-scroll (harness-ui-chat--at-end-p))
        (harness-ui-chat--scroll-to-end))
      ;; Configuration changes carry the complete new state, but the
      ;; header also shows info (model name, tokens) that only the session
      ;; knows; refresh it.
      (when (member kind '("session_info_update" "config_option_update"
                           "current_mode_update" "usage_update"))
        (harness-ui-chat--refresh-info buffer _session-id)))))

(defun harness-ui-chat--refresh-info (buffer session-id)
  "Re-fetch SESSION-ID's info and redraw BUFFER's header."
  (harness-deferred-then
   (harness-ui-request "_harness/session/info" (list :sessionId session-id))
   (lambda (info)
     (when (buffer-live-p buffer)
       (with-current-buffer buffer
         (setq harness-ui-chat--info info
               harness-ui-chat--status (intern (or (plist-get info :status) "idle")))
         (harness-ui-chat--refresh-header))))
   (lambda (_error) nil)))

(defun harness-ui-chat--absorb-into-tool-run (record)
  "Merge RECORD into the previous allow-listed tool run, if adjacent."
  (let* ((records (cdr (memq record harness-ui-chat--records)))
         (previous (car records)))
    (when (and previous
               (harness-ui-chat--coalescable-p previous))
      ;; Fold both into a group record; the next layout draws it collapsed.
      (let ((group (harness-ui-chat-record-create
                    :key (list 'group (harness-ui-chat-record-key previous))
                    :kind "tool_run"
                    :children (list previous record)
                    :collapsed t
                    :tool-name (harness-ui-chat-record-tool-name previous))))
        (setq harness-ui-chat--records (cons group (cdr (cdr records)))
              harness-ui-chat--needs-rebuild t)))))

(defun harness-ui-chat--update-text (update)
  "Flatten UPDATE's content blocks into display text."
  (let ((content (plist-get update :content)))
    (cond
     ((null content) nil)
     ((stringp content) content)
     ((and (listp content) (plist-get content :type))
      (or (plist-get content :text)
          (harness-ui-chat--render-blocks (list content))))
     ((vectorp content) (harness-ui-chat--render-blocks content))
     ((listp content) (harness-ui-chat--render-blocks (vconcat content)))
     (t (format "%S" content)))))

(defun harness-ui-chat--render-blocks (blocks)
  "Render content BLOCKS to text."
  (mapconcat (lambda (block)
               (pcase (plist-get block :type)
                 ("text" (or (plist-get block :text) ""))
                 ("content" (harness-ui-chat--render-blocks
                             (let ((inner (plist-get block :content)))
                               (if (vectorp inner) inner (vector inner)))))
                 ("diff" (format "--- %s\n%s\n+++ %s\n%s"
                                 (plist-get block :path)
                                 (or (plist-get block :oldText) "")
                                 (plist-get block :path)
                                 (or (plist-get block :newText) "")))
                 (_ "")))
             (append blocks nil) "\n"))

(defun harness-ui-chat--at-end-p ()
  "Return non-nil when every window on this buffer shows its end."
  (let ((windows (get-buffer-window-list (current-buffer) nil t)))
    (or (null windows)
        (cl-every (lambda (window)
                    (with-selected-window window
                      (= (window-end window) (point-max))))
                  windows))))

(defun harness-ui-chat--scroll-to-end ()
  "Move point to the composer."
  (let ((windows (get-buffer-window-list (current-buffer) nil t)))
    (if windows
        (dolist (window windows)
          (with-selected-window window
            (goto-char (harness-ui-chat--compose-point))))
      (goto-char (harness-ui-chat--compose-point)))))

(defun harness-ui-chat--compose-point ()
  "Return the start of the composer body."
  (or (harness-ui-chat--safe-marker-position harness-ui-chat--compose-start)
      (point-max)))

;;; Header and composer

(defun harness-ui-chat--format-tokens (used size)
  "Format USED/SIZE tokens compactly."
  (cond
   ((and (> size 0) (>= size 1000))
    (format "%s/%.0fk"
            (if (>= used 1000) (format "%.1fk" (/ used 1000.0)) (number-to-string used))
            (/ size 1000.0)))
   ((> size 0) (format "%d/%d" used size))
   (t (format "%d tok" used))))

(defun harness-ui-chat--header-segment (label face help &optional action)
  "A propertized header-line segment.
With ACTION, the segment becomes a clickable button."
  (let ((string (propertize label 'face face 'help-echo help)))
    (if (and action (display-graphic-p))
        (propertize string
                    'mouse-face 'highlight
                    'keymap (let ((map (make-sparse-keymap)))
                              (define-key map [header-line mouse-1]
                                          (lambda () (interactive) (funcall action)))
                              (define-key map [mouse-1]
                                          (lambda () (interactive) (funcall action)))
                              map))
      string)))

(defun harness-ui-chat--in-buffer (session-id)
  "Return SESSION-ID's chat buffer when it exists."
  (and session-id (gethash session-id harness-ui-chat--buffers)))

(defun harness-ui-chat--call-in-chat-buffer (function)
  "Call FUNCTION in a chat buffer.
Return the symbol `redirected' when the call was delegated to another
buffer, and nil when the current buffer already is a chat buffer.
Timers and deferred callbacks call the rendering functions with an
arbitrary current buffer; running them there would set buffer-local
state in the wrong buffer."
  (cond
   ((derived-mode-p 'harness-ui-chat-mode) nil)
   ((when-let* ((buffer (harness-ui-chat--in-buffer harness-ui-current-session)))
      (with-current-buffer buffer (funcall function))
      'redirected))
   (t 'nowhere)))

(defun harness-ui-chat--refresh-header ()
  "Redraw the header line: title, status, model, tokens, cost, permissions.
Segments use only theme faces so light and dark themes stay legible on
the theme's own header-line background, and the important ones are
clickable."
  (unless (harness-ui-chat--call-in-chat-buffer #'harness-ui-chat--refresh-header)
    (let* ((info harness-ui-chat--info)
         (status (or harness-ui-chat--status 'idle))
         (title (truncate-string-to-width
                 (or (plist-get info :title)
                     (and (plist-get info :sessionId)
                          (substring (plist-get info :sessionId) 0 8))
                     "session")
                 48 nil nil "…"))
         (cost (plist-get info :cost))
         (used (or (plist-get info :contextUsed) 0))
         (size (or (plist-get info :contextSize) 0))
         (thinking (plist-get info :thinking))
         (separator (propertize "  ·  " 'face 'shadow)))
    (setq header-line-format
          (list
           " "
           (harness-ui-chat--header-segment
            title 'bold "Session list (C-c C-s)" #'harness-ui-sessions)
           separator
           (harness-ui-chat--header-segment
            (symbol-name status)
            (pcase status
              ('running 'success)
              ('blocked 'error)
              (_ 'shadow))
            (if (eq status 'running) "The agent is working" "Idle"))
           separator
           (harness-ui-chat--header-segment
            (or (plist-get info :model) "no model") 'shadow
            "Switch model (C-c C-m)" #'harness-ui-switch-model)
           separator
           (harness-ui-chat--header-segment
            (harness-ui-chat--format-tokens used size)
            (if (and (> size 0) (> used (* 0.8 size))) 'warning 'shadow)
            "Context window usage")
           (when cost
             (list separator
                   (harness-ui-chat--header-segment
                    (format "$%.3f" (or (plist-get cost :amount) 0))
                    'shadow "Estimated cost so far")))
           (when thinking
             (list separator
                   (harness-ui-chat--header-segment
                    (format "%s thinking" (if (symbolp thinking) (symbol-name thinking) thinking))
                    'shadow "Thinking level (C-c C-t)" #'harness-ui-set-thinking)))
           separator
           (harness-ui-chat--header-segment
            (format "%s" (or (plist-get info :permissionMode) "ask"))
            (pcase (plist-get info :permissionMode)
              ("auto" 'warning)
              ('auto 'warning)
              (_ 'shadow))
            "Permission mode (C-c C-p)" #'harness-ui-set-permission-mode)
           (when (>= (length harness-ui-chat--queue) 1)
             (list separator
                   (harness-ui-chat--header-segment
                    (format "%d queued" (length harness-ui-chat--queue))
                    'warning "Messages waiting for the next turn"))))))))

(defun harness-ui-chat--render-composer (&optional text)
  "(Re)draw the composer area and its action buttons.
TEXT defaults to the composer's current contents."
  (unless (harness-ui-chat--call-in-chat-buffer
           (lambda () (harness-ui-chat--render-composer text)))
    (let* ((inhibit-read-only t)
         (text (or text (harness-ui-chat--compose-text)))
         (running (eq harness-ui-chat--status 'running))
         (input-end nil)
         ;; Keep the cursor where the user left it inside the composer.
         (compose-point (let ((start (harness-ui-chat--safe-marker-position
                                      harness-ui-chat--compose-start)))
                          (when (and start (>= (point) start))
                            (- (point) start)))))
    (when-let* ((end (harness-ui-chat--safe-marker-position harness-ui-chat--transcript-end)))
      (delete-region end (point-max)))
    (goto-char (point-max))
    (setq harness-ui-chat--transcript-end (copy-marker (point)))
    (unless (and (>= (point) 2)
                 (eq (char-before (1- (point))) ?\n)
                 (eq (char-before) ?\n))
      (insert "\n"))
    (harness-ui-chat--render-queued)
    (harness-ui-chat--render-attachments-line)
    (insert (propertize "❯ " 'face 'harness-ui-prompt-face))
    (let ((start (point)))
      (insert (propertize text 'face 'harness-ui-compose-face))
      (setq harness-ui-chat--compose-start (copy-marker start)
            input-end (point)))
    (insert "\n")
    (insert (propertize "  " 'face 'shadow))
    (harness-ui-chat--button (if running "Queue" "Send")
                             (if running #'harness-ui-chat-queue #'harness-ui-chat-send)
                             :help-echo (if running
                                            "Queue for the next turn (C-c C-q)"
                                          "Send (RET)"))
    (insert (propertize "  ·  " 'face 'shadow))
    (harness-ui-chat--button "Queue" #'harness-ui-chat-queue
                             :help-echo "Queue for the next turn (C-c C-q)")
    (insert (propertize "  ·  " 'face 'shadow))
    (harness-ui-chat--button "Attach" #'harness-ui-chat-attach-file
                             :help-echo "Attach a file (@)")
    (when running
      (insert (propertize "  ·  " 'face 'shadow))
      (harness-ui-chat--button "Stop" #'harness-ui-chat-cancel
                               :help-echo "Cancel the running turn (C-c C-k)"))
    (insert "\n")
    ;; The marker is created last: inserting at its position would drag it
    ;; along, and it must sit right after the typed text.
    (setq harness-ui-chat--compose-end (copy-marker input-end t))
    (when compose-point
      (goto-char (min (point-max)
                      (+ (marker-position harness-ui-chat--compose-start) compose-point)))))))

(defun harness-ui-chat--safe-marker-position (marker)
  "Marker's position, clamped to the accessible buffer text."
  (when (and marker (marker-position marker))
    (min (marker-position marker) (point-max))))

(defun harness-ui-chat--compose-text ()
  "Return the composer's current text."
  (let ((start (harness-ui-chat--safe-marker-position harness-ui-chat--compose-start))
        (end (harness-ui-chat--safe-marker-position harness-ui-chat--compose-end)))
    (if (and start end (<= start end))
        (buffer-substring-no-properties start end)
      "")))

(defun harness-ui-chat--replace-compose (text)
  "Replace the composer's text with TEXT."
  (let ((inhibit-read-only t))
    (delete-region (harness-ui-chat--compose-point)
                   (or (harness-ui-chat--safe-marker-position harness-ui-chat--compose-end)
                       (point-max)))
    (goto-char (harness-ui-chat--compose-point))
    (let ((start (point)))
      (insert (propertize text 'face 'harness-ui-compose-face))
      (setq harness-ui-chat--compose-start (copy-marker start)
            harness-ui-chat--compose-end (copy-marker (point) t)))))

(defun harness-ui-chat--render-queued ()
  "Render the queued message list above the composer."
  (when harness-ui-chat--queue
    (let ((count (length harness-ui-chat--queue)))
      (insert (propertize (format "Queued (%d): " count) 'face 'shadow))
      (cl-loop for (blocks . text) in harness-ui-chat--queue
               for index from 0
               do (let ((i index))
                    (ignore blocks)
                    (harness-ui-chat--button
                     (format "[%d] %s " i (truncate-string-to-width text 50 nil nil "…"))
                     (lambda ()
                       (let ((entry (nth i harness-ui-chat--queue)))
                         (setq harness-ui-chat--queue (delq entry harness-ui-chat--queue))
                         (harness-ui-chat--replace-compose (cdr entry))
                         (harness-ui-chat--render-composer)))
                     :help-echo "Edit this queued message")
                    (insert " "))
               finally (insert "\n")))))

(defun harness-ui-chat--render-attachments-line ()
  "Render the attached-files line."
  (when harness-ui-chat--attachments
    (insert (propertize "Attached: " 'face 'shadow))
    (dolist (file harness-ui-chat--attachments)
      (harness-ui-chat--button
       (harness-ui-chat--short-path file)
       (lambda () (find-file-other-window file))
       :help-echo (format "Open %s" file))
      (insert " ")
      (harness-ui-chat--button "×" (lambda ()
                                     (setq harness-ui-chat--attachments
                                           (remove file harness-ui-chat--attachments))
                                     (harness-ui-chat--render-composer))
                              :help-echo "Remove attachment")
      (insert "  "))
    (insert "\n")))

(defun harness-ui-chat--short-path (path)
  "Shorten PATH in the middle."
  (let ((cwd (or (plist-get harness-ui-chat--info :cwd) default-directory)))
    (let ((relative (file-relative-name path cwd)))
      (if (> (length relative) 40)
          (concat (substring relative 0 18) "…" (substring relative (- (length relative) 18)))
        relative))))

;;; Public commands

(defun harness-ui-chat--buffer (session-id)
  "Return the chat buffer for SESSION-ID, creating it."
  (or (gethash session-id harness-ui-chat--buffers)
      (let ((buffer (get-buffer-create (format "*harness: %s*" session-id))))
        (with-current-buffer buffer
          (harness-ui-chat-mode)
          (setq harness-ui-chat--session-id session-id)
          (setq harness-ui-chat--records nil
                harness-ui-chat--queue nil
                harness-ui-chat--attachments nil
                harness-ui-chat--transcript-end (copy-marker (point-max)))
          (harness-ui-chat--render-composer))
        (puthash session-id buffer harness-ui-chat--buffers)
        buffer)))

(defun harness-ui-chat-open (session-id &optional position)
  "Open SESSION-ID in a chat buffer using POSITION preset."
  (interactive
   (list (or (harness-ui-chat--current-session)
             (read-string "Session id: "))))
  (let* ((position (or position 'right))
         (preset (or (alist-get position harness-ui-chat-positions)
                     (alist-get 'right harness-ui-chat-positions)))
         (buffer (harness-ui-chat--buffer session-id)))
    (puthash position session-id harness-ui-chat--position-buffer)
    (setq harness-ui-current-session session-id)
    (with-current-buffer buffer
      (setq harness-ui-chat--position position))
    (funcall preset buffer)
    (harness-deferred-then
     (harness-ui-request "session/load"
                         (list :sessionId session-id))
     (lambda (_result)
       (harness-deferred-then
        (harness-ui-request "session/info"
                            (list :sessionId session-id))
        (lambda (info)
          (with-current-buffer buffer
            (setq harness-ui-chat--info info
                  harness-ui-chat--status (intern (or (plist-get info :status) "idle")))
            (harness-ui-chat--refresh-header))))
       ))
    buffer))

(defun harness-ui-chat--current-session ()
  "Return the session of the current chat buffer."
  (and (derived-mode-p 'harness-ui-chat-mode)
       harness-ui-chat--session-id))

;;;###autoload
(defun harness-ui-chat-new (&optional directory)
  "Create a session in DIRECTORY and open its chat buffer."
  (interactive (list (read-directory-name "Session directory: "
                                          (or (and (project-current)
                                                   (project-root (project-current)))
                                              default-directory))))
  (let ((deferred (harness-ui-request
                   "session/new"
                   (list :cwd (file-name-as-directory (expand-file-name directory))
                         :mcpServers []))))
    (harness-deferred-then
     deferred
     (lambda (result)
       (harness-ui-chat-open (plist-get result :sessionId))))))

(defun harness-ui-chat--skill-names (text)
  "Return #name skill references in TEXT."
  (let (names)
    (with-temp-buffer
      (insert text)
      (goto-char (point-min))
      (while (re-search-forward "\\(?:\\`\\|[[:space:](]\\)#\\([[:alnum:]_-]+\\)\\b" nil t)
        (push (match-string 1) names)))
    (delete-dups (nreverse names))))

(defun harness-ui-chat--skill-blocks (names)
  "Load NAMES as skills.  Returns a deferred of their text blocks."
  (if (null names)
      (let ((deferred (harness-deferred-new))) (harness-deferred-resolve deferred nil) deferred)
    (harness-deferred-then
     (harness-deferred-all
      (mapcar (lambda (name)
                (harness-deferred-then
                 (harness-ui-request "_harness/skills/load" (list :name name))
                 (lambda (skill)
                   (list :type "text"
                         :text (format "Skill `%s` follows:\n\n%s"
                                       (plist-get skill :name)
                                       (or (plist-get skill :content) ""))))
                 (lambda (_error) nil)))
              names))
     (lambda (blocks) (delq nil blocks)))))

(defun harness-ui-chat-send ()
  "Send the composer's message, or queue it while a turn is running.
#name references load skills and attach their contents."
  (interactive)
  (let ((text (string-trim (harness-ui-chat--compose-text))))
    (when (or (not (string-empty-p text))
              harness-ui-chat--attachments)
      (let ((skill-names (harness-ui-chat--skill-names text))
            (attachments harness-ui-chat--attachments))
        (harness-ui-chat--replace-compose "")
        (harness-deferred-then
         (harness-ui-chat--skill-blocks skill-names)
         (lambda (skill-blocks)
           (let ((blocks (vconcat (append skill-blocks nil)
                                  (harness-ui-chat--message-blocks text))))
             (ignore attachments)
             (if (eq harness-ui-chat--status 'running)
                 (progn
                   (setq harness-ui-chat--queue
                         (append harness-ui-chat--queue (list (cons blocks text))))
                   (with-current-buffer (current-buffer)
                     (harness-ui-chat--render-composer))
                   (message "Queued; it will be sent at the next turn"))
               (harness-ui-chat--send-blocks blocks)))))))))

(defun harness-ui-chat--send-blocks (blocks)
  "Send BLOCKS to the session and mark the turn as running."
  (let ((buffer (current-buffer)))
    (setq harness-ui-chat--attachments nil)
    (setq harness-ui-chat--status 'running)
    (harness-ui-chat--refresh-header)
    (harness-ui-chat--render-composer)
    (harness-deferred-then
     (harness-ui-send harness-ui-chat--session-id blocks)
     (lambda (_result)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (setq harness-ui-chat--status 'idle)
           (harness-ui-chat--refresh-header)
           (harness-ui-chat--render-composer)
           (when harness-ui-chat--queue
             (let ((queued (copy-sequence harness-ui-chat--queue)))
               (setq harness-ui-chat--queue nil)
               (harness-ui-chat--send-blocks
                (vconcat (seq-mapcat #'car queued))))))))
     (lambda (error)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (setq harness-ui-chat--status 'idle)
           (harness-ui-chat--refresh-header)
           (harness-ui-chat--render-composer)
           (message "Prompt failed: %S" error)))))))

(defun harness-ui-chat-queue ()
  "Queue the composer's message for the next turn."
  (interactive)
  (let ((text (string-trim (harness-ui-chat--compose-text))))
    (when (not (string-empty-p text))
      (setq harness-ui-chat--queue
            (append harness-ui-chat--queue
                    (list (cons (harness-ui-chat--message-blocks text) text))))
      (harness-ui-chat--replace-compose "")
      (harness-ui-chat--render-composer))))

(defun harness-ui-chat-cancel ()
  "Cancel the running turn."
  (interactive)
  (when harness-ui-chat--session-id
    (harness-ui-cancel harness-ui-chat--session-id)
    (message "Cancelling…")))

(defun harness-ui-chat--message-blocks (text)
  "Turn TEXT plus attachments into ACP content blocks."
  (let ((blocks (list (list :type "text" :text text))))
    (dolist (file harness-ui-chat--attachments)
      (push (list :type "resource_link"
                  :uri (concat "file://" file)
                  :name (file-name-nondirectory file)
                  :size (or (ignore-errors (file-attribute-size (file-attributes file))) 0))
            blocks))
    (vconcat (nreverse blocks))))

(defun harness-ui-chat-attach-file (file)
  "Attach FILE to the next message."
  (interactive "fAttach file: ")
  (let ((file (expand-file-name file)))
    (unless (member file harness-ui-chat--attachments)
      (setq harness-ui-chat--attachments
            (append harness-ui-chat--attachments (list file))))
    (harness-ui-chat--render-composer)))

(defun harness-ui-chat-dnd-handler (uri action)
  "Handle dropped URI in a chat buffer."
  (when-let* ((session (harness-ui-chat--current-session)))
    (ignore session)
    (let ((path (url-unhex-string (string-remove-prefix "file://" uri))))
      (harness-ui-chat-attach-file path)
      action)))

(defun harness-ui-chat-back-to-end ()
  "Jump back to the composer."
  (interactive)
  (goto-char (point-max)))

(defun harness-ui-chat-ret ()
  "RET in the composer sends the message."
  (interactive)
  (if (>= (point) (harness-ui-chat--compose-point))
      (harness-ui-chat-send)
    (save-excursion (goto-char (point-max)) (harness-ui-chat-send))))

(defun harness-ui-chat-newline ()
  "Insert a newline in the composer."
  (interactive)
  (if (>= (point) (harness-ui-chat--compose-point))
      (insert "\n")
    (goto-char (point-max))
    (insert "\n")))

;;; @file references

(defun harness-ui-chat-completion-at-point ()
  "Complete @file references against the project."
  (let ((end (point))
        (start (save-excursion
                 (when (re-search-backward "@\\([^ \t\n@]*\\)\\=" nil t)
                   (match-beginning 0)))))
    (when start
      (list (1+ start) end
            (harness-ui-chat--file-candidates)
            :exclusive 'no
            :company-doc-buffer nil))))

(defun harness-ui-chat--file-candidates ()
  "List project files relative to the session directory."
  (let* ((cwd (or (plist-get harness-ui-chat--info :cwd) default-directory))
         (files (ignore-errors
                  (project-files (or (project-current nil cwd)
                                     (cons 'transient cwd))))))
    (mapcar (lambda (file) (file-relative-name file cwd))
            (or files
                (ignore-errors (directory-files-recursively cwd "" ))))))

(defvar harness-ui-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "RET") #'harness-ui-chat-ret)
    (define-key map (kbd "S-<return>") #'harness-ui-chat-newline)
    (define-key map (kbd "C-j") #'harness-ui-chat-newline)
    (define-key map (kbd "C-c C-c") #'harness-ui-chat-send)
    (define-key map (kbd "C-c C-k") #'harness-ui-chat-cancel)
    (define-key map (kbd "C-c C-q") #'harness-ui-chat-queue)
    (define-key map (kbd "C-c C-s") #'harness-ui-sessions)
    (define-key map (kbd "C-c C-m") #'harness-ui-switch-model)
    (define-key map (kbd "C-c C-p") #'harness-ui-set-permission-mode)
    (define-key map (kbd "C-c C-t") #'harness-ui-set-thinking)
    (define-key map (kbd "C-c C-e") #'harness-ui-chat-back-to-end)
    (define-key map (kbd "C-c C-a") #'harness-ui-chat-attach-file)
    (define-key map (kbd "q") #'bury-buffer)
    map)
  "Keymap for `harness-ui-chat-mode'.")

(define-derived-mode harness-ui-chat-mode special-mode "Harness-Chat"
  "Major mode for harness chat buffers."
  :group 'harness-ui-chat
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (setq-local buffer-read-only nil)
  (setq-local window-point-insertion-type t)
  ;; Rendering is manual (`harness-ui-chat--fontify'), and the global
  ;; font-lock mode's jit-lock timer would strip those faces a second
  ;; after the fact (leaving button faces showing through).
  (setq-local font-lock-defaults nil)
  (font-lock-mode -1)
  (add-hook 'completion-at-point-functions
            #'harness-ui-chat-completion-at-point nil t)
  (visual-line-mode 1))

;;; Display presets

(defun harness-ui-chat--display-right (buffer)
  "Show BUFFER in a right side window."
  (let ((window (display-buffer
                 buffer
                 '((display-buffer-reuse-window display-buffer-in-side-window)
                   (side . right)
                   (window-width . 0.5)))))
    (select-window window)
    (with-current-buffer buffer (goto-char (point-max)))))

(defun harness-ui-chat--display-bottom (buffer)
  "Show BUFFER in a bottom side window."
  (let ((window (display-buffer
                 buffer
                 '((display-buffer-reuse-window display-buffer-in-side-window)
                   (side . bottom)
                   (window-height . 0.4)))))
    (select-window window)
    (with-current-buffer buffer (goto-char (point-max)))))

(defun harness-ui-chat--display-full (buffer)
  "Show BUFFER in the selected window."
  (switch-to-buffer buffer)
  (goto-char (point-max)))

;;; Event wiring

(defvar harness-ui-chat--pending-updates (make-hash-table :test #'equal)
  "Session id -> list of updates waiting to be rendered.")

(defun harness-ui-chat--on-update (payload)
  "Handle `harness-ui-update' PAYLOAD."
  (let ((session-id (plist-get payload :session-id))
        (update (plist-get payload :update)))
    (when (gethash session-id harness-ui-chat--buffers)
      (puthash session-id
               (append (gethash session-id harness-ui-chat--pending-updates)
                       (list update))
               harness-ui-chat--pending-updates)
      (harness-batch (list 'harness-ui-chat-buffer session-id) 0.033
                     (lambda () (harness-ui-chat--flush session-id))))))

(defun harness-ui-chat--flush (session-id)
  "Render the pending updates of SESSION-ID."
  (let ((updates (gethash session-id harness-ui-chat--pending-updates))
        (buffer (gethash session-id harness-ui-chat--buffers)))
    (remhash session-id harness-ui-chat--pending-updates)
    (when (and updates (buffer-live-p buffer))
      (with-current-buffer buffer
        (dolist (update updates)
          (condition-case err
              (harness-ui-chat--apply-update buffer session-id update)
            (error
             (harness-log "chat update failed: %S" err)
             (setq harness-ui-chat--needs-rebuild t))))
        (when harness-ui-chat--needs-rebuild
          (condition-case err
              (harness-ui-chat-rebuild)
            (error (harness-log "chat rebuild failed: %S" err)))))
      (when-let* ((window (get-buffer-window buffer t)))
        (with-selected-window window
          (when harness-ui-chat-auto-scroll
            (goto-char (point-max))))))))

(defun harness-ui-chat--on-status (payload)
  "Handle `harness-ui-session-status' PAYLOAD."
  (let* ((status (plist-get payload :status))
         (session-id (plist-get status :sessionId))
         (buffer (gethash session-id harness-ui-chat--buffers)))
    (when buffer
      (with-current-buffer buffer
        (setq harness-ui-chat--status
              (intern (or (plist-get status :status) "idle")))
        (when (and (eq harness-ui-chat--status 'idle) harness-ui-chat--queue)
          (let ((queued (copy-sequence harness-ui-chat--queue)))
            (setq harness-ui-chat--queue nil)
            (harness-ui-chat--send-blocks (vconcat (seq-mapcat #'car queued)))))
        (harness-ui-chat--refresh-header)
        (harness-ui-chat--render-composer)))))

(defun harness-ui-chat-refresh-all ()
  "Redraw every chat buffer (after a reload)."
  (maphash (lambda (_session-id buffer)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (harness-ui-chat--refresh-header)
                 (harness-ui-chat-rebuild))))
           harness-ui-chat--buffers))

(defun harness-ui-chat-setup ()
  "Set up the chat module."
  (harness-on 'harness-ui-update #'harness-ui-chat--on-update :module 'harness-ui-chat)
  (harness-on 'harness-ui-session-status #'harness-ui-chat--on-status
              :module 'harness-ui-chat)
  (add-hook 'harness-ui-refresh-functions #'harness-ui-chat-refresh-all)
  (add-to-list 'dnd-protocol-alist '("^file://" . harness-ui-chat-dnd-handler)))

(defun harness-ui-chat-teardown ()
  "Tear down the chat module."
  (remove-hook 'harness-ui-refresh-functions #'harness-ui-chat-refresh-all)
  (setq dnd-protocol-alist
        (remove '("^file://" . harness-ui-chat-dnd-handler) dnd-protocol-alist))
  (maphash (lambda (_session-id buffer)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer (set-buffer-modified-p nil))))
           harness-ui-chat--buffers)
  (clrhash harness-ui-chat--buffers)
  (clrhash harness-ui-chat--position-buffer))

(harness-module-define 'harness-ui-chat
  :version harness-version
  :description "Chat buffers: transcript, composer, queue and attachments."
  :requires '((harness-core "0.1.0")
              (harness-ui "0.1.0"))
  :provides '(harness-ui-chat)
  :setup #'harness-ui-chat-setup
  :teardown #'harness-ui-chat-teardown)

(provide 'harness-ui-chat)
;;; harness-ui-chat.el ends here
