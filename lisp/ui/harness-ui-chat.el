;;; harness-ui-chat.el --- The chat buffer  -*- lexical-binding: t; -*-

;;; Commentary:

;; One buffer per session, "*harness: NAME*", laid out top to bottom:
;;
;;   header line   status, name, model, permission mode, thinking, context, cost, menu
;;   transcript    one block per node, rendered incrementally with markers
;;   pending panel permission requests and questions waiting for the user
;;   queue         messages queued for the next turn
;;   attachments   chips for files attached to the next message
;;   compose       an editable region; C-c C-c sends, RET adds a newline
;;   mode line     status, turn duration
;;
;; The transcript is never re-rendered on a delta: every node owns a
;; region delimited by two markers, streaming text is appended at the
;; end of the live node's region, and a block is rendered through the
;; Markdown renderer only when it is finalised or at most every
;; `harness-chat-render-interval' seconds.  Thinking, tool calls,
;; compaction summaries and runs of coalescable tools collapse under
;; overlays that isearch opens, so every word of the conversation stays
;; searchable.  History loads lazily: the newest
;; `harness-chat-history-limit' nodes at open, older pages on demand.
;;
;; Region bookkeeping: every block's text ends with a separator newline
;; that is never deleted, so re-rendering a block replaces the text
;; before that newline and the markers of neighbouring blocks stay put.
;; The region above the transcript and each coalesced summary line use
;; the same trick.
;;
;; Everything goes through the ACP connection held by `harness-ui';
;; this file never touches a session struct.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'button)
(require 'icons)
(require 'mailcap)
(require 'dnd)
(require 'harness-core)
(require 'harness-util)
(require 'harness-acp)
(require 'harness-ui)
(require 'harness-ui-compose)
(require 'harness-files)
(require 'harness-ui-markdown)

(declare-function harness-ui-media-render-attachment "harness-ui-media" (attachment))
(defvar harness-state-directory)

(defgroup harness-ui-chat nil
  "The chat buffer." :group 'harness-ui :prefix "harness-chat-")

;;;; Customisation

(defcustom harness-chat-history-limit 60
  "Number of nodes rendered when a session buffer opens."
  :type 'integer :group 'harness-ui-chat)

(defcustom harness-chat-history-page 100
  "Number of older nodes loaded by \"Show earlier messages\"."
  :type 'integer :group 'harness-ui-chat)

(defcustom harness-chat-compose-max-lines 8
  "Lines the compose box grows to before the window scrolls instead."
  :type 'integer :group 'harness-ui-chat)

(defcustom harness-chat-tool-output-limit 3000
  "Characters of tool output shown before a \"show all\" button."
  :type 'integer :group 'harness-ui-chat)

(defcustom harness-chat-render-interval 0.3
  "Seconds between Markdown re-renders of a streaming block."
  :type 'number :group 'harness-ui-chat)

(defcustom harness-chat-coalesce-threshold 3
  "Consecutive coalescable tool calls needed to fold into one summary block."
  :type 'integer :group 'harness-ui-chat)

(defcustom harness-chat-image-max-height 400
  "Maximum pixel height of inline images."
  :type 'integer :group 'harness-ui-chat)

(defcustom harness-chat-user-label "You"
  "Sender name shown above the user's messages."
  :type 'string :group 'harness-ui-chat)

(defcustom harness-chat-agent-label "Agent"
  "Sender name shown at the start of each agent turn."
  :type 'string :group 'harness-ui-chat)

(defface harness-chat-panel-face
  '((((background light)) :background "#fff1cf" :extend t)
    (((background dark)) :background "#463a1c" :extend t))
  "Background of the pending permission and question panel." :group 'harness-ui-chat)

(defface harness-chat-key-face '((t :inherit help-key-binding))
  "Keyboard shortcut hints in panels." :group 'harness-ui-chat)

(defface harness-chat-output-face '((t :inherit (fixed-pitch harness-md-code-block)))
  "Tool output." :group 'harness-ui-chat)

(defface harness-chat-plan-face
  '((((background light)) :background "#eef2ff" :extend t)
    (((background dark)) :background "#262a3a" :extend t))
  "Background of plan blocks." :group 'harness-ui-chat)

(harness-ui-define-icon harness-chat-icon-plan "plan" "≡" "plan" "A plan.")
(harness-ui-define-icon harness-chat-icon-compaction "compaction" "⟲" "compact" "A compaction.")
(harness-ui-define-icon harness-chat-icon-question "question" "?" "?" "A question.")

(defconst harness-chat--spinner-frames ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"]
  "Frames of the running spinner.")

;;;; Buffer state

(cl-defstruct (harness-chat-block (:constructor harness-chat--make-block) (:copier nil))
  "One rendered node."
  id kind node result start end fold collapsed show-all content streamed group
  head)                                 ; non-nil: first agent block of a turn, carries the sender name

(cl-defstruct (harness-chat-group (:constructor harness-chat--make-group-record) (:copier nil))
  "A run of coalesced tool blocks folded under one summary."
  id members start end overlay expanded)

(defvar harness-chat--buffers (make-hash-table :test 'equal)
  "Session id -> chat buffer.")

(defvar harness-chat--spinner-timer nil "Timer animating the header spinner.")
(defvar harness-chat--spinner-index 0)
(defvar harness-chat--segment-maps (make-hash-table :test 'eq) "Command -> header segment keymap.")
(defvar harness-chat--batch nil "Non-nil while many blocks are inserted at once (no auto-scroll).")

(defvar-local harness-chat--blocks nil "Node id -> `harness-chat-block'.")
(defvar-local harness-chat--calls nil "Tool call id -> node id of the tool-call block.")
(defvar-local harness-chat--order nil "Rendered node ids, newest first.")
(defvar-local harness-chat--groups nil "Group id -> `harness-chat-group'.")
(defvar-local harness-chat--group-seq 0)
(defvar-local harness-chat--transcript-start nil "Marker: first block.")
(defvar-local harness-chat--transcript-end nil "Marker: after the last block.")
(defvar-local harness-chat--queue nil "Queued items as last rendered.")
(defvar-local harness-chat--pending nil "Pending request records: (:id :kind :respond :created …).")
(defvar-local harness-chat--editing nil "Queue item id loaded into the compose box.")
(defvar-local harness-chat--has-more nil "Non-nil when older nodes exist.")
(defvar-local harness-chat--loading nil "Non-nil while the transcript is being fetched.")
(defvar-local harness-chat--deferred nil "Updates that arrived while loading, newest first.")
(defvar-local harness-chat--coalescable nil "Names of coalescable tools.")
(defvar-local harness-chat--turn-start nil "Float time the running turn started.")
(defvar-local harness-chat--unseen nil "Non-nil when content arrived while scrolled up.")
(defvar-local harness-chat--dead nil "Non-nil once the session was deleted.")
(defvar-local harness-chat--render-timers nil "Node id -> throttle timer.")
(defvar-local harness-chat--generation 0 "Bumped on every reload to drop stale responses.")
(defvar-local harness-chat--session nil "Last session plist seen, for after deletion.")
(defvar-local harness-chat--unfinished nil "Ids of tool-call blocks without a result yet.")

;;;; Small helpers

(defmacro harness-chat--writable (&rest body)
  "Run BODY with the buffer writable and undo off, keeping point."
  (declare (indent 0))
  `(let ((inhibit-read-only t) (buffer-undo-list t))
     (save-excursion ,@body)))

(defmacro harness-chat--with-display (&rest body)
  "Run BODY with the frame showing this buffer selected, so icons match it.
Icons pick image, symbol or text variants from the selected frame; a
render triggered from a timer or an emacsclient eval would otherwise
use whatever frame happens to be selected."
  (declare (indent 0))
  `(let ((buf (current-buffer))
         (w (car (harness-chat--windows))))
     (if (and w (not (eq (window-frame w) (selected-frame))))
         (with-selected-frame (window-frame w)
           (with-current-buffer buf ,@body))
       (progn ,@body))))

(defun harness-chat--session ()
  "Return the session plist of this buffer (cached, or the last one seen)."
  (or (harness-ui-session harness-ui-session-id) harness-chat--session))

(defun harness-chat--project ()
  "Return the project root of this buffer's session."
  (let ((s (harness-chat--session)))
    (or (plist-get s :project) (plist-get s :cwd) default-directory)))

(defun harness-chat--project-root (dir)
  "Return the project root of DIR."
  (harness-files-project-root dir))

(defun harness-chat--str (kind)
  "Return KIND (symbol or string) as a string."
  (if (symbolp kind) (symbol-name kind) kind))

(defun harness-chat--windows ()
  "Return the windows showing the current buffer."
  (get-buffer-window-list (current-buffer) nil t))

(defun harness-chat--face (string face)
  "Return STRING with FACE added on top of its faces."
  (let ((s (copy-sequence string)))
    (add-face-text-property 0 (length s) face t s)
    s))

(defun harness-chat--margin (string &optional face bar)
  "Return STRING indented by one column, keeping its own prefixes.
FACE, when given, colours the margin as well.  BAR, when given, is a
face whose foreground draws a bar in the margin instead of a space."
  (let* ((s (copy-sequence string))
         (margin (cond (bar (propertize "▌" 'face (if face (list bar face) bar)))
                       (face (propertize " " 'face face))
                       (t " ")))
         (pos 0) (len (length s)))
    (while (< pos len)
      (let* ((next (or (next-property-change pos s) len))
             (lp (get-text-property pos 'line-prefix s))
             (wp (get-text-property pos 'wrap-prefix s)))
        (put-text-property pos next 'line-prefix (concat margin (or lp "")) s)
        (put-text-property pos next 'wrap-prefix (concat margin (or wp "")) s)
        (setq pos next)))
    s))

(defun harness-chat--ensure-newline (string)
  "Return STRING ending in exactly one newline."
  (concat (string-trim-right (or string "") "\n+") "\n"))

(defun harness-chat--foldable (text)
  "Return TEXT marked as the folding part of a block.
Its final newline stays outside the fold, so a folded block's last
visible line ends in a newline of the block's own face."
  (if (string-empty-p (or text ""))
      ""
    (concat (propertize (string-trim-right text "\n+") 'harness-chat-fold t) "\n")))

(defun harness-chat--words (text)
  "Count the words in TEXT."
  (length (split-string (or text "") "[ \t\n]+" t)))

(defun harness-chat--kbd (key)
  "Return KEY as a key hint string."
  (propertize key 'face 'harness-chat-key-face))

(defun harness-chat--mouse-map (command)
  "Return a keymap running COMMAND on mouse-1, mouse-2 and RET."
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] command)
    (define-key map [mouse-2] command)
    (define-key map (kbd "RET") command)
    map))

(defun harness-chat--fold-button (collapsed action &optional help)
  "Return a ▸/▾ toggle button string for a block; ACTION runs on click.
COLLAPSED picks the icon; HELP is the tooltip."
  (let ((icon (harness-ui-icon (if collapsed 'harness-icon-collapsed 'harness-icon-expanded))))
    (propertize (if (string-empty-p icon) (if collapsed "+" "-") icon)
                'harness-chat-fold-icon t
                'face 'harness-dim-face
                'mouse-face 'highlight
                'help-echo (or help "mouse-1, TAB: expand or collapse")
                'follow-link t
                'keymap (harness-chat--mouse-map action))))

(defun harness-chat--button (label action &rest props)
  "Return a button string LABEL running ACTION (a function of no arguments).
PROPS may hold `:help' and `:face'."
  (let ((s (copy-sequence label)))
    (add-text-properties
     0 (length s)
     (list 'face (or (plist-get props :face) 'button)
           'mouse-face 'highlight 'follow-link t
           'help-echo (plist-get props :help)
           'harness-chat-action action
           'keymap (harness-chat--mouse-map #'harness-chat-push))
     s)
    s))

(defun harness-chat-push (&optional event)
  "Run the action of the button at point, or at the position of mouse EVENT."
  (interactive (list last-input-event))
  (when (mouse-event-p event) (mouse-set-point event))
  (let ((action (or (get-text-property (point) 'harness-chat-action)
                    (and (> (point) (point-min)) (get-text-property (1- (point)) 'harness-chat-action)))))
    (if action (funcall action) (push-button (point)))))

;;;; Region editing that keeps windows still

(defun harness-chat--fix-positions (fix pt windows)
  "Move point to (FIX PT) and every window in WINDOWS through FIX.
WINDOWS holds (WINDOW START POINT) triples recorded before the edit."
  (goto-char (funcall fix pt))
  (dolist (w windows)
    (when (window-live-p (car w))
      (set-window-start (car w) (funcall fix (nth 1 w)) t)
      (unless (eq (car w) (selected-window))
        (set-window-point (car w) (funcall fix (nth 2 w)))))))

(defun harness-chat--window-positions ()
  "Return (WINDOW START POINT) for every window showing the buffer."
  (mapcar (lambda (w) (list w (window-start w) (window-point w))) (harness-chat--windows)))

(defun harness-chat--replace-region (from to text)
  "Replace FROM..TO with TEXT, keeping point and window starts anchored.
Positions inside the region stay at the same offset from FROM; the
position just after the region moves to the end of TEXT."
  (let* ((from (if (markerp from) (marker-position from) from))
         (to (if (markerp to) (marker-position to) to))
         (len (length text))
         (fix (lambda (p)
                (cond ((< p from) p)
                      ((< p to) (min p (+ from (max 0 (1- len)))))
                      ((= p to) (+ from len))
                      (t (+ p (- len (- to from)))))))
         (windows (harness-chat--window-positions))
         (pt (point)))
    (let ((inhibit-read-only t) (buffer-undo-list t))
      (delete-region from to)
      (goto-char from)
      (insert text))
    (harness-chat--fix-positions fix pt windows)))

(defun harness-chat--insert-at (pos text)
  "Insert TEXT at POS, shifting point and window starts that were at POS."
  (let* ((pos (if (markerp pos) (marker-position pos) pos))
         (len (length text))
         (fix (lambda (p) (if (>= p pos) (+ p len) p)))
         (windows (harness-chat--window-positions))
         (pt (point)))
    (let ((inhibit-read-only t) (buffer-undo-list t))
      (goto-char pos)
      (insert text))
    (harness-chat--fix-positions fix pt windows)))

;;;; Auto-scroll

(defun harness-chat--at-bottom-p (&optional window)
  "Non-nil when WINDOW shows the end of the transcript.
WINDOW defaults to the first window showing the buffer; without one
the buffer counts as at the bottom."
  (let ((w (or window (car (harness-chat--windows)))))
    (or (null w)
        (not (eq (window-buffer w) (current-buffer)))
        (null harness-chat--transcript-end)
        (>= (window-point w) harness-chat--transcript-end)
        (pos-visible-in-window-p (max (point-min) (1- (marker-position harness-chat--transcript-end))) w))))

(defun harness-chat--bottom-windows ()
  "Return the windows of this buffer that are at the bottom."
  (unless harness-chat--batch
    (cl-remove-if-not #'harness-chat--at-bottom-p (harness-chat--windows))))

(defun harness-chat--pin (window)
  "Scroll WINDOW so the end of the buffer sits on its last line.
A transcript shorter than the window stays at the top."
  (when (window-live-p window)
    ;; `recenter' would count the top padding as lines to keep in view and
    ;; scroll a short transcript off the top: drop it, and let
    ;; `harness-compose-pad-window' size it again for the new start.
    (harness-compose-repad window)
    (with-selected-window window
      (save-excursion (goto-char (point-max)) (recenter -1)))))

(defun harness-chat--follow (windows)
  "Scroll WINDOWS to the end of the buffer; the others learn about new content."
  (unless harness-chat--batch
    (dolist (w (harness-chat--windows))
      (if (memq w windows)
          (progn
            (harness-chat--pin w)
            (when (< (window-point w) harness-chat--transcript-end)
              (set-window-point w (or harness-compose-end (point-max)))))
        (unless harness-chat--unseen
          (setq harness-chat--unseen t)
          (force-mode-line-update))))))

(defun harness-chat-scroll-to-bottom ()
  "Show the newest messages and put point in the compose box."
  (interactive)
  (setq harness-chat--unseen nil)
  (goto-char (or harness-compose-end (point-max)))
  (dolist (w (harness-chat--windows))
    (set-window-point w (point))
    (harness-chat--pin w))
  (force-mode-line-update))

(defun harness-chat--on-window-buffer-change (window)
  "Pin WINDOW, which just started showing this buffer, to the newest messages.
Without this Emacs centres point (the compose box) on first display and
the next streamed chunk snaps it to the bottom."
  (when (and (window-live-p window) (eq (window-buffer window) (current-buffer))
             harness-chat--transcript-end
             (>= (window-point window) harness-chat--transcript-end))
    (harness-chat--pin window)))

(defun harness-chat--window-anchors ()
  "Return (WINDOW BOTTOM NODE OFFSET START) for every window on the buffer.
NODE and OFFSET locate the window start inside a block, so it can be
found again after the transcript is rebuilt."
  (mapcar (lambda (w)
            (let* ((start (window-start w))
                   (node (get-text-property start 'harness-chat-node))
                   (block (and node harness-chat--blocks (gethash node harness-chat--blocks))))
              (list w (harness-chat--at-bottom-p w) node
                    (and block (- start (harness-chat-block-start block)))
                    start)))
          (harness-chat--windows)))

(defun harness-chat--restore-anchors (anchors)
  "Put the windows of ANCHORS back where `harness-chat--window-anchors' saw them."
  (pcase-dolist (`(,w ,bottom ,node ,offset ,start) anchors)
    (when (window-live-p w)
      (if bottom
          (progn (set-window-point w (or harness-compose-end (point-max)))
                 (harness-chat--pin w))
        (let ((block (and node (gethash node harness-chat--blocks))))
          (set-window-start w (if block
                                  (min (+ (harness-chat-block-start block) offset)
                                       (harness-chat-block-end block))
                                (min start (point-max)))
                            t))))))

;;;; Rendering: pieces

(defun harness-chat--label (icon text)
  "Return a label line with ICON and TEXT."
  (concat (propertize (concat (harness-ui-icon icon) " " text) 'face 'harness-label-face) "\n"))

(defun harness-chat--plain (text)
  "Return TEXT as wrapped plain paragraphs."
  (harness-chat--ensure-newline (or text "")))

(defun harness-chat--image-string (source &optional mime)
  "Return a string displaying SOURCE (a path or a (:data BASE64) plist).
MIME is a hint for the image type.  Without image support a button
opening the file is returned instead."
  (let* ((path (and (stringp source) source))
         (data (and (consp source) (plist-get source :data)))
         (label (if path (format "[image %s]" (abbreviate-file-name path)) "[image]")))
    (if (and (display-images-p) (or data (and path (file-readable-p path))))
        (let* ((w (car (harness-chat--windows)))
               (width (floor (* 0.6 (if w (window-body-width w t) 800))))
               (img (condition-case nil
                        (if data
                            (create-image (base64-decode-string data) nil t
                                          :max-width width :max-height harness-chat-image-max-height)
                          (create-image path nil nil
                                        :max-width width :max-height harness-chat-image-max-height))
                      (error nil))))
          (if img
              (concat (propertize label 'display img 'help-echo (or path mime "image")
                                  'keymap (and path (harness-chat--mouse-map
                                                     (lambda () (interactive) (find-file-other-window path)))))
                      "\n")
            (concat label "\n")))
      (if path
          (concat (harness-chat--button label (lambda () (find-file-other-window path))
                                        :help "Open the image")
                  "\n")
        (concat (propertize label 'face 'harness-dim-face) "\n")))))

(defun harness-chat--file-button (path name size)
  "Return a button line opening PATH, labelled NAME with SIZE bytes."
  (concat (harness-chat--button
           (format "%s %s%s" (harness-ui-icon 'harness-icon-attach)
                   (or name (and path (file-name-nondirectory path)) "file")
                   (if size (format " (%s)" (harness-format-bytes size)) ""))
           (lambda () (when path (find-file-other-window path)))
           :help path)
          "\n"))

(defun harness-chat--attachment-string (att)
  "Return a string showing tool-result attachment ATT."
  (let* ((mime (or (plist-get att :mime) ""))
         (path (plist-get att :path))
         (media (and (not (string-prefix-p "image/" mime))
                     (fboundp 'harness-ui-media-render-attachment)
                     (ignore-errors (harness-ui-media-render-attachment att)))))
    (cond
     ((and path (string-prefix-p "image/" mime)) (harness-chat--image-string path mime))
     ((and (stringp media) (not (string-blank-p media))) (harness-chat--ensure-newline media))
     (path (harness-chat--file-button path (plist-get att :name) (plist-get att :size)))
     (t ""))))

(defun harness-chat--blocks-string (blocks)
  "Return the non-text content BLOCKS of a node as a string."
  (mapconcat (lambda (b)
               (pcase (plist-get b :type)
                 ("image" (harness-chat--image-string (or (plist-get b :path) (list :data (plist-get b :data)))
                                                      (plist-get b :mime)))
                 ("file" (harness-chat--file-button (plist-get b :path) (plist-get b :name) (plist-get b :size)))
                 ("audio" (concat (propertize "[audio]" 'face 'harness-dim-face) "\n"))
                 (_ "")))
             blocks ""))

(defun harness-chat--format-value (value)
  "Return VALUE for display in a tool input listing."
  (cond ((stringp value) value)
        ((eq value :false) "false")
        ((eq value t) "true")
        ((null value) "null")
        ((numberp value) (number-to-string value))
        (t (format "%S" value))))

(defun harness-chat--input-summary (input)
  "Return a one-line summary of tool INPUT."
  (let (parts)
    (cl-loop for (k v) on input by #'cddr
             do (push (format "%s: %s" (substring (symbol-name k) 1)
                              (harness-first-line (harness-chat--format-value v) 60))
                      parts))
    (harness-truncate-end (string-join (nreverse parts) "  ") 110)))

(defun harness-chat--input-listing (input)
  "Return tool INPUT pretty printed, one key per line."
  (let (out)
    (cl-loop for (k v) on input by #'cddr
             do (let ((text (harness-chat--format-value v))
                      (key (substring (symbol-name k) 1)))
                  (push (if (string-search "\n" text)
                            (concat (propertize (concat key ":") 'face 'harness-dim-face) "\n"
                                    (propertize (harness-chat--ensure-newline text) 'face 'harness-chat-output-face
                                                'line-prefix "    " 'wrap-prefix "    "))
                          (concat (propertize (concat key ": ") 'face 'harness-dim-face) text "\n"))
                        out)))
    (apply #'concat (nreverse out))))

;;;; Rendering: blocks

(defun harness-chat--sender (text face)
  "Return a sender line naming TEXT in FACE."
  (concat (propertize text 'face face) "\n"))

(defun harness-chat--render-user (block)
  "Return the body of user BLOCK."
  (let* ((node (harness-chat-block-node block))
         (text (harness-chat--plain (plist-get node :content)))
         (body (concat (harness-chat--sender harness-chat-user-label 'harness-user-label-face)
                       (if (string-blank-p text) "" text)
                       (harness-chat--blocks-string (plist-get node :blocks)))))
    (harness-chat--margin (harness-chat--face body 'harness-user-face) 'harness-user-face
                          'harness-user-bar-face)))

(defconst harness-chat--agent-kinds '("assistant" "thinking" "tool-call" "tool-result" "plan")
  "Block kinds the agent produces; a run of them is one agent turn.")

(defun harness-chat--head-p (kind previous)
  "Non-nil when a KIND block after a PREVIOUS-kind block starts an agent turn."
  (and (member kind harness-chat--agent-kinds)
       (not (member previous harness-chat--agent-kinds))))

(defun harness-chat--agent-header ()
  "Return the sender line that opens an agent turn."
  (harness-chat--margin (harness-chat--sender harness-chat-agent-label 'harness-agent-label-face)))

(defun harness-chat--render-assistant (block)
  "Return the body of assistant BLOCK."
  (let ((content (or (harness-chat-block-content block) "")))
    (harness-chat--margin
     (if (string-blank-p content)
         "\n"
       (harness-chat--face (harness-chat--ensure-newline (harness-ui-markdown-render content))
                           'harness-agent-face)))))

(defun harness-chat--render-thinking (block)
  "Return the body of thinking BLOCK."
  (let* ((id (harness-chat-block-id block))
         (content (or (harness-chat-block-content block) ""))
         (header (concat (harness-chat--fold-button (harness-chat-block-collapsed block)
                                                    (lambda () (interactive) (harness-chat-toggle-block id)))
                         " "
                         (propertize (format "%s thinking (%d words)" (harness-ui-icon 'harness-icon-thinking)
                                             (harness-chat--words content))
                                     'face 'harness-thinking-face)
                         "\n"))
         (body (harness-chat--foldable (harness-chat--face (harness-chat--plain content) 'harness-thinking-face))))
    (harness-chat--margin (concat header body))))

(defun harness-chat--tool-status (result)
  "Return the status string for a tool call with RESULT (a node or nil)."
  (cond ((and (null result) (member (plist-get (harness-chat--session) :status) '("running" "blocked")))
         (propertize "⋯ running" 'face 'harness-dim-face))
        ((null result) (propertize "– no result" 'face 'harness-dim-face))
        ((harness-json-true-p (plist-get result :is-error)) (propertize "✗ failed" 'face 'error))
        (t (propertize "✓" 'face 'success))))

(defun harness-chat--render-tool (block)
  "Return the body of tool-call BLOCK (its result rendered with it)."
  (let* ((id (harness-chat-block-id block))
         (node (harness-chat-block-node block))
         (call-only (equal (harness-chat--str (plist-get node :kind)) "tool-call"))
         (result (if call-only (harness-chat-block-result block) node))
         (title (if call-only
                    (or (plist-get node :title) (plist-get node :tool) "tool")
                  (format "result %s" (or (plist-get node :call-id) ""))))
         (input (and call-only (plist-get node :input)))
         (output (or (plist-get result :output) ""))
         (error-p (and result (harness-json-true-p (plist-get result :is-error))))
         (bg (if error-p 'harness-tool-error-face 'harness-tool-face))
         (indent (propertize "  " 'face bg))
         (limit harness-chat-tool-output-limit)
         (long (and (not (harness-chat-block-show-all block)) (> (length output) limit)))
         (shown (if long (substring output 0 limit) output))
         (header (concat (harness-chat--fold-button (harness-chat-block-collapsed block)
                                                    (lambda () (interactive) (harness-chat-toggle-block id)))
                         " " (harness-ui-icon 'harness-icon-tool) " "
                         (propertize (harness-first-line title 120) 'face 'harness-tool-title-face)
                         "  " (harness-chat--tool-status result) "\n"))
         (summary (if input
                      (concat (propertize (concat "  " (harness-chat--input-summary input)) 'face 'harness-dim-face) "\n")
                    ""))
         (details
          (concat
           (if input (concat (propertize "  input\n" 'face 'harness-label-face)
                             (propertize (harness-chat--input-listing input) 'line-prefix indent 'wrap-prefix indent))
             "")
           (cond
            ((null result) "")
            ((string-empty-p output) (propertize "  (no output)\n" 'face 'harness-dim-face))
            (t (concat (propertize (format "  output (%s chars)\n" (harness-format-tokens (length output)))
                                   'face 'harness-label-face)
                       (propertize (harness-chat--ensure-newline shown) 'face 'harness-chat-output-face
                                   'line-prefix indent 'wrap-prefix indent)
                       (if long
                           (concat "  " (harness-chat--button
                                         (format "show all (%d more chars)" (- (length output) limit))
                                         (lambda () (harness-chat--show-all id)))
                                   "\n")
                         ""))))
           (mapconcat #'harness-chat--attachment-string (plist-get result :attachments) ""))))
    (harness-chat--margin
     (harness-chat--face (concat header summary (harness-chat--foldable details)) bg)
     bg)))

(defun harness-chat--render-hint (block)
  "Return the body of hint BLOCK."
  (let ((text (string-trim (or (plist-get (harness-chat-block-node block) :content) ""))))
    (harness-chat--margin
     (propertize (concat "    " text "\n") 'face 'harness-hint-face 'wrap-prefix "    "))))

(defun harness-chat--render-compaction (block)
  "Return the body of compaction BLOCK."
  (let* ((id (harness-chat-block-id block))
         (content (or (plist-get (harness-chat-block-node block) :content) ""))
         (header (concat (harness-chat--fold-button (harness-chat-block-collapsed block)
                                                    (lambda () (interactive) (harness-chat-toggle-block id)))
                         " "
                         (propertize (format "%s context compacted (%d words)"
                                             (harness-ui-icon 'harness-chat-icon-compaction)
                                             (harness-chat--words content))
                                     'face 'harness-summary-face)
                         "\n"))
         (body (harness-chat--foldable
                (harness-chat--face (harness-chat--ensure-newline (harness-ui-markdown-render content))
                                    'harness-thinking-face))))
    (harness-chat--margin (concat header body))))

(defun harness-chat--render-plan (block)
  "Return the body of plan BLOCK."
  (let* ((content (or (plist-get (harness-chat-block-node block) :content) ""))
         (body (concat (harness-chat--label 'harness-chat-icon-plan "plan")
                       (harness-chat--ensure-newline (harness-ui-markdown-render content)))))
    (harness-chat--margin (harness-chat--face body 'harness-chat-plan-face) 'harness-chat-plan-face)))

(defun harness-chat--render-error (block)
  "Return the body of local error BLOCK."
  (harness-chat--margin
   (propertize (concat (harness-ui-icon 'harness-icon-warning) " "
                       (or (plist-get (harness-chat-block-node block) :content) "") "\n")
               'face 'error)))

(defun harness-chat--render-group (group)
  "Return the body of the summary block of GROUP."
  (let* ((gid (harness-chat-group-id group))
         (names (mapcar (lambda (nid)
                          (let ((b (gethash nid harness-chat--blocks)))
                            (or (plist-get (harness-chat-block-node b) :tool) "tool")))
                        (harness-chat-group-members group)))
         (counts nil))
    (dolist (n names)
      (let ((cell (assoc n counts)))
        (if cell (cl-incf (cdr cell)) (push (cons n 1) counts))))
    (setq counts (nreverse counts))
    (concat
     (if (harness-chat-block-head (gethash (car (harness-chat-group-members group)) harness-chat--blocks))
         (harness-chat--agent-header)
       "")
     (harness-chat--margin
      (concat (harness-chat--fold-button (not (harness-chat-group-expanded group))
                                        (lambda () (interactive) (harness-chat-toggle-group gid))
                                        "mouse-1, TAB: show or hide the individual tool calls")
             " "
             (propertize (format "%s %d tool calls: %s" (harness-ui-icon 'harness-icon-tool) (length names)
                                 (mapconcat (lambda (c) (if (> (cdr c) 1) (format "%s ×%d" (car c) (cdr c)) (car c)))
                                            counts ", "))
                         'face 'harness-summary-face)
             "  "
             (harness-chat--button (if (harness-chat-group-expanded group) "[collapse]" "[expand]")
                                   (lambda () (harness-chat-toggle-group gid))
                                   :help "Show or hide the individual tool calls")
             "\n")))))

(defun harness-chat--render-block (block)
  "Return the full text of BLOCK: its body, then the separator newline."
  (let* ((kind (harness-chat-block-kind block))
         (body (harness-chat--with-display
                (pcase kind
                 ("user" (harness-chat--render-user block))
                 ("assistant" (harness-chat--render-assistant block))
                 ("thinking" (harness-chat--render-thinking block))
                 ((or "tool-call" "tool-result") (harness-chat--render-tool block))
                 ("hint" (harness-chat--render-hint block))
                 ("compaction" (harness-chat--render-compaction block))
                 ("plan" (harness-chat--render-plan block))
                 ("error" (harness-chat--render-error block))
                 (_ (harness-chat--margin
                     (harness-chat--plain (or (plist-get (harness-chat-block-node block) :content)
                                              (format "[%s]" kind))))))))
         (text (concat (if (and (harness-chat-block-head block) (not (harness-chat-block-group block)))
                           (harness-chat--agent-header)
                         "")
                       body "\n")))
    (add-text-properties 0 (length text)
                         (list 'harness-chat-node (harness-chat-block-id block) 'read-only t 'rear-nonsticky t)
                         text)
    text))

;;;; Folding

(defun harness-chat--make-fold (block)
  "Create the fold overlay of BLOCK over its `harness-chat-fold' range."
  (let* ((start (marker-position (harness-chat-block-start block)))
         (end (marker-position (harness-chat-block-end block)))
         (from (text-property-any start end 'harness-chat-fold t)))
    (when from
      (let* ((to (or (text-property-not-all from end 'harness-chat-fold t) end))
             ;; Hide "\n<details>" rather than "<details>\n" (see
             ;; `harness-chat--foldable'): the folded details would otherwise
             ;; leave an empty line drawn with their margin colour.
             ;; REAR-ADVANCE keeps streamed text inside the fold.
             (from (if (and (> from start) (eq (char-before from) ?\n)) (1- from) from))
             (ov (make-overlay from to nil nil t)))
        (overlay-put ov 'evaporate t)
        (overlay-put ov 'harness-chat-block (harness-chat-block-id block))
        (overlay-put ov 'invisible (and (harness-chat-block-collapsed block) 'harness-chat-fold))
        (overlay-put ov 'isearch-open-invisible #'harness-chat--isearch-open)
        (setf (harness-chat-block-fold block) ov)))))

(defun harness-chat--isearch-open (overlay)
  "Expand the block or group behind OVERLAY permanently (for isearch)."
  (let ((bid (overlay-get overlay 'harness-chat-block))
        (gid (overlay-get overlay 'harness-chat-group)))
    (cond (bid (let ((b (gethash bid harness-chat--blocks)))
                 (when (and b (harness-chat-block-collapsed b)) (harness-chat-toggle-block bid))))
          (gid (let ((g (gethash gid harness-chat--groups)))
                 (when (and g (not (harness-chat-group-expanded g))) (harness-chat-toggle-group gid)))))))

(defun harness-chat--swap-fold-icon (start end collapsed)
  "Replace the fold icon between START and END with the COLLAPSED state's icon."
  (when-let* ((pos (text-property-any start end 'harness-chat-fold-icon t)))
    (let* ((next (or (text-property-not-all pos end 'harness-chat-fold-icon t) end))
           (props (text-properties-at pos))
           (icon (harness-ui-icon (if collapsed 'harness-icon-collapsed 'harness-icon-expanded)))
           (new (apply #'propertize (if (string-empty-p icon) (if collapsed "+" "-") icon) props)))
      (harness-chat--writable
        (goto-char pos)
        (insert new)
        (delete-region (point) (+ (point) (- next pos)))))))

(defun harness-chat-toggle-block (&optional id)
  "Collapse or expand the block ID (default the one at point)."
  (interactive)
  (let* ((id (or id (get-text-property (point) 'harness-chat-node)))
         (block (and id (gethash id harness-chat--blocks))))
    (cond
     ((null block) (user-error "No block here"))
     ((null (harness-chat-block-fold block)) (user-error "This block has nothing to fold"))
     (t (let ((collapsed (not (harness-chat-block-collapsed block))))
          (setf (harness-chat-block-collapsed block) collapsed)
          (overlay-put (harness-chat-block-fold block) 'invisible (and collapsed 'harness-chat-fold))
          (harness-chat--swap-fold-icon (harness-chat-block-start block) (harness-chat-block-end block) collapsed))))))

(defun harness-chat--show-all (id)
  "Re-render block ID with its full tool output."
  (when-let* ((block (gethash id harness-chat--blocks)))
    (setf (harness-chat-block-show-all block) t)
    (harness-chat--rerender block)))

;;;; Block insertion and update

(defun harness-chat--collapsible-p (kind)
  "Non-nil when blocks of KIND start collapsed."
  (member kind '("thinking" "tool-call" "tool-result" "compaction")))

(defun harness-chat--new-block (node)
  "Return an unrendered block for NODE."
  (let ((kind (harness-chat--str (plist-get node :kind))))
    (harness-chat--make-block :id (plist-get node :id) :kind kind :node node
                              :content (plist-get node :content)
                              :collapsed (and (harness-chat--collapsible-p kind) t))))

(defun harness-chat--insert-block (block pos)
  "Insert the text of BLOCK at POS and set its markers."
  (let ((text (harness-chat--render-block block))
        (p (if (markerp pos) (marker-position pos) pos)))
    (harness-chat--insert-at p text)
    (setf (harness-chat-block-start block) (copy-marker p)
          (harness-chat-block-end block) (copy-marker (+ p (length text))))
    (harness-chat--make-fold block)
    (puthash (harness-chat-block-id block) block harness-chat--blocks)
    (when-let* ((call (and (equal (harness-chat-block-kind block) "tool-call")
                           (plist-get (harness-chat-block-node block) :call-id))))
      (puthash call (harness-chat-block-id block) harness-chat--calls)
      (unless (harness-chat-block-result block)
        (cl-pushnew (harness-chat-block-id block) harness-chat--unfinished :test #'equal)))
    block))

(defun harness-chat--append-block (block)
  "Append BLOCK at the end of the transcript."
  (let ((first (null harness-chat--order))
        (previous (and harness-chat--order (gethash (car harness-chat--order) harness-chat--blocks))))
    (setf (harness-chat-block-head block)
          (harness-chat--head-p (harness-chat-block-kind block)
                                (and previous (harness-chat-block-kind previous))))
    (harness-chat--insert-block block (marker-position harness-chat--transcript-end))
    (set-marker harness-chat--transcript-end (marker-position (harness-chat-block-end block)))
    (push (harness-chat-block-id block) harness-chat--order)
    ;; The first block replaces the "No messages yet" notice.
    (when (and first (not harness-chat--batch) (not harness-chat--loading))
      (harness-chat--render-top))
    block))

(defun harness-chat--rerender (block)
  "Render BLOCK again in place."
  (let ((text (harness-chat--render-block block))
        (windows (harness-chat--bottom-windows)))
    (when (harness-chat-block-fold block)
      (delete-overlay (harness-chat-block-fold block))
      (setf (harness-chat-block-fold block) nil))
    ;; Keep the trailing separator: replace everything before it so the
    ;; markers of the neighbouring blocks stay where they are.
    (harness-chat--replace-region (harness-chat-block-start block)
                                  (1- (marker-position (harness-chat-block-end block)))
                                  (substring text 0 -1))
    (harness-chat--make-fold block)
    (harness-chat--follow windows)))

(defun harness-chat--append-delta (block delta face)
  "Append streaming DELTA to BLOCK with FACE, cheaply."
  (let* ((pos (- (marker-position (harness-chat-block-end block)) 2))
         (bg (and (equal (harness-chat-block-kind block) "thinking") 'harness-thinking-face))
         (windows (harness-chat--bottom-windows))
         (text (harness-chat--margin (propertize delta 'face face 'harness-chat-node (harness-chat-block-id block)
                                                 'read-only t 'rear-nonsticky t)
                                     bg)))
    (harness-chat--writable
      (goto-char pos)
      (insert text))
    (harness-chat--follow windows)))

(defun harness-chat--schedule-render (block)
  "Re-render BLOCK after `harness-chat-render-interval' unless already scheduled."
  (let ((id (harness-chat-block-id block))
        (buf (current-buffer)))
    (unless (gethash id harness-chat--render-timers)
      (puthash id (run-at-time harness-chat-render-interval nil
                               (lambda ()
                                 (when (buffer-live-p buf)
                                   (with-current-buffer buf
                                     (remhash id harness-chat--render-timers)
                                     (when-let* ((b (gethash id harness-chat--blocks)))
                                       (harness-chat--rerender b))))))
               harness-chat--render-timers))))

(defun harness-chat--cancel-render (id)
  "Drop the pending re-render of block ID."
  (when-let* ((timer (and harness-chat--render-timers (gethash id harness-chat--render-timers))))
    (cancel-timer timer)
    (remhash id harness-chat--render-timers)))

(defun harness-chat--cancel-all-renders ()
  "Drop every pending re-render."
  (when harness-chat--render-timers
    (maphash (lambda (_ timer) (cancel-timer timer)) harness-chat--render-timers)
    (clrhash harness-chat--render-timers)))

;;;; Coalescing

(defun harness-chat--coalescable-block-p (id)
  "Non-nil when block ID is a tool call of a coalescable tool."
  (when-let* ((b (gethash id harness-chat--blocks)))
    (and (equal (harness-chat-block-kind b) "tool-call")
         (member (plist-get (harness-chat-block-node b) :tool) harness-chat--coalescable))))

(defun harness-chat--group-text (group)
  "Return the summary text of GROUP followed by its separator newline."
  (let ((text (concat (harness-chat--with-display (harness-chat--render-group group)) "\n")))
    (add-text-properties 0 (length text)
                         (list 'harness-chat-group (harness-chat-group-id group) 'read-only t 'rear-nonsticky t)
                         text)
    text))

(defun harness-chat--make-group (members)
  "Fold the blocks MEMBERS (oldest first) under a new summary block."
  (let* ((gid (format "g%d" (cl-incf harness-chat--group-seq)))
         (first (gethash (car members) harness-chat--blocks))
         (last (gethash (car (last members)) harness-chat--blocks))
         (group (harness-chat--make-group-record :id gid :members members))
         (pos (marker-position (harness-chat-block-start first)))
         (text (harness-chat--group-text group)))
    (harness-chat--insert-at pos text)
    (setf (harness-chat-group-start group) (copy-marker pos)
          (harness-chat-group-end group) (copy-marker (+ pos (length text))))
    (set-marker (harness-chat-block-start first) (+ pos (length text)))
    (let ((ov (make-overlay (harness-chat-block-start first) (harness-chat-block-end last) nil nil nil)))
      (overlay-put ov 'invisible 'harness-chat-fold)
      (overlay-put ov 'harness-chat-group gid)
      (overlay-put ov 'isearch-open-invisible #'harness-chat--isearch-open)
      (setf (harness-chat-group-overlay group) ov))
    (dolist (m members) (setf (harness-chat-block-group (gethash m harness-chat--blocks)) gid))
    (puthash gid group harness-chat--groups)
    ;; The summary now carries the turn's sender line.
    (when (harness-chat-block-head first) (harness-chat--rerender first))
    group))

(defun harness-chat--update-group-summary (group)
  "Render the summary line of GROUP again."
  (let ((text (harness-chat--group-text group)))
    (harness-chat--replace-region (harness-chat-group-start group)
                                  (1- (marker-position (harness-chat-group-end group)))
                                  (substring text 0 -1))))

(defun harness-chat--extend-group (group id)
  "Add block ID to GROUP, which ends right before it."
  (let ((block (gethash id harness-chat--blocks))
        (ov (harness-chat-group-overlay group)))
    (setf (harness-chat-group-members group) (append (harness-chat-group-members group) (list id)))
    (setf (harness-chat-block-group block) (harness-chat-group-id group))
    (move-overlay ov (overlay-start ov) (marker-position (harness-chat-block-end block)))
    (harness-chat--update-group-summary group)))

(defun harness-chat--maybe-coalesce (id)
  "Fold block ID into a run of coalescable tool calls when there is one."
  (when (harness-chat--coalescable-block-p id)
    (let* ((previous (cadr harness-chat--order))
           (prev-block (and previous (gethash previous harness-chat--blocks)))
           (gid (and prev-block (harness-chat-block-group prev-block))))
      (if gid
          (harness-chat--extend-group (gethash gid harness-chat--groups) id)
        (let ((run (list id)) (rest (cdr harness-chat--order)))
          (while (and rest (harness-chat--coalescable-block-p (car rest)))
            (push (car rest) run)
            (setq rest (cdr rest)))
          (when (>= (length run) harness-chat-coalesce-threshold)
            (harness-chat--make-group run)))))))

(defun harness-chat--clear-groups ()
  "Remove every group: summary blocks and overlays."
  (maphash (lambda (_ g)
             (delete-overlay (harness-chat-group-overlay g))
             (let ((inhibit-read-only t) (buffer-undo-list t))
               (delete-region (harness-chat-group-start g) (harness-chat-group-end g)))
             (dolist (m (harness-chat-group-members g))
               (when-let* ((b (gethash m harness-chat--blocks)))
                 (setf (harness-chat-block-group b) nil)
                 (when (harness-chat-block-head b) (harness-chat--rerender b)))))
           harness-chat--groups)
  (clrhash harness-chat--groups))

(defun harness-chat--regroup ()
  "Recompute every coalesced run over the rendered transcript."
  (harness-chat--clear-groups)
  (let ((run nil))
    (cl-flet ((flush () (when (>= (length run) harness-chat-coalesce-threshold)
                          (harness-chat--make-group (nreverse run)))
                      (setq run nil)))
      (dolist (id (reverse harness-chat--order))
        (if (harness-chat--coalescable-block-p id) (push id run) (flush)))
      (flush))))

(defun harness-chat-toggle-group (&optional gid)
  "Show or hide the tool calls of group GID (default the one at point)."
  (interactive)
  (let* ((gid (or gid (get-text-property (point) 'harness-chat-group)))
         (group (and gid (gethash gid harness-chat--groups))))
    (unless group (user-error "No coalesced group here"))
    (setf (harness-chat-group-expanded group) (not (harness-chat-group-expanded group)))
    (overlay-put (harness-chat-group-overlay group) 'invisible
                 (and (not (harness-chat-group-expanded group)) 'harness-chat-fold))
    (harness-chat--update-group-summary group)))

;;;; Incoming updates

(defun harness-chat--buffer-for (sid)
  "Return the live chat buffer of session SID, or nil."
  (let ((buf (and sid (gethash sid harness-chat--buffers))))
    (and buf (buffer-live-p buf) buf)))

(defun harness-chat--on-update (sid update)
  "Route session UPDATE of SID to its buffer."
  (when-let* ((buf (harness-chat--buffer-for sid)))
    (with-current-buffer buf
      (if harness-chat--loading
          (push update harness-chat--deferred)
        (harness-chat--apply-update update)))))

(defun harness-chat--apply-update (update)
  "Apply one session UPDATE to the current buffer."
  (pcase (plist-get update :sessionUpdate)
    ("_harness/node" (harness-chat--on-node (plist-get update :node)))
    ("agent_message_chunk" (harness-chat--on-chunk update "assistant"))
    ("agent_thought_chunk" (harness-chat--on-chunk update "thinking"))
    ("_harness/session" (harness-chat--on-session (plist-get update :session)))
    ("_harness/session_deleted" (harness-chat--on-deleted))))

(defun harness-chat--on-node (node)
  "Render or update NODE."
  (let* ((id (plist-get node :id))
         (kind (harness-chat--str (plist-get node :kind)))
         (block (gethash id harness-chat--blocks))
         (call (and (equal kind "tool-result") (not block)
                    (gethash (gethash (plist-get node :call-id) harness-chat--calls) harness-chat--blocks))))
    (cond
     ;; A tool result joins its call's block.
     (call
      (setf (harness-chat-block-result call) node)
      (setq harness-chat--unfinished (delete (harness-chat-block-id call) harness-chat--unfinished))
      (puthash id call harness-chat--blocks)
      (harness-chat--rerender call))
     ;; An update of a result already merged into its call block.
     ((and block (not (equal (harness-chat-block-id block) id)))
      (setf (harness-chat-block-result block) node)
      (harness-chat--rerender block))
     (block
      (setf (harness-chat-block-node block) node
            (harness-chat-block-content block) (plist-get node :content)
            (harness-chat-block-streamed block) t)
      (harness-chat--cancel-render id)
      (harness-chat--rerender block))
     (t
      (let ((windows (harness-chat--bottom-windows)))
        (harness-chat--append-block (harness-chat--new-block node))
        (harness-chat--maybe-coalesce id)
        (harness-chat--follow windows))))))

(defun harness-chat--on-chunk (update kind)
  "Append the streaming text of UPDATE to its node's block of KIND."
  (let* ((id (plist-get (plist-get update :_harness) :nodeId))
         (delta (or (plist-get (plist-get update :content) :text) ""))
         (block (and id (gethash id harness-chat--blocks))))
    (cond
     ((or (null id) (string-empty-p delta)) nil)
     ((null block)
      (let ((windows (harness-chat--bottom-windows))
            (b (harness-chat--new-block (list :id id :kind kind :content delta))))
        (setf (harness-chat-block-streamed b) t)
        (harness-chat--append-block b)
        (harness-chat--follow windows)))
     ((and (not (harness-chat-block-streamed block))
           (equal delta (harness-chat-block-content block)))
      ;; The node announcement already carried this first delta.
      (setf (harness-chat-block-streamed block) t))
     (t
      (let* ((before (or (harness-chat-block-content block) ""))
             (lead (if (and (string-suffix-p "\n" before)
                            (not (eq (char-before (- (marker-position (harness-chat-block-end block)) 2)) ?\n)))
                       "\n" "")))
        (setf (harness-chat-block-streamed block) t
              (harness-chat-block-content block) (concat before delta))
        (harness-chat--append-delta block (concat lead delta)
                                    (if (equal kind "thinking") 'harness-thinking-face 'harness-agent-face))
        (harness-chat--schedule-render block))))))

(defun harness-chat--on-session (session)
  "React to a fresh SESSION plist."
  (let ((status (plist-get session :status))
        (changed nil))
    (setq harness-chat--session session)
    (when-let* ((cwd (plist-get session :cwd)))
      (when (file-directory-p cwd) (setq default-directory (file-name-as-directory cwd))))
    (harness-chat--rename-buffer session)
    (cond ((equal status "running")
           (unless harness-chat--turn-start (setq harness-chat--turn-start (float-time)))
           (harness-chat--start-spinner))
          ((not (equal status "blocked"))
           (setq harness-chat--turn-start nil)
           ;; A cancelled turn leaves calls without results: stop calling them running.
           (dolist (id harness-chat--unfinished)
             (when-let* ((b (gethash id harness-chat--blocks))) (harness-chat--rerender b)))
           (setq harness-chat--unfinished nil)))
    (setq changed (harness-chat--sync-pending (plist-get session :pending)))
    (unless (equal (plist-get session :queue) harness-chat--queue)
      (setq harness-chat--queue (plist-get session :queue) changed t))
    (when changed (harness-chat--render-tail))
    (force-mode-line-update)))

(defun harness-chat--on-deleted ()
  "Mark the buffer as showing a deleted session."
  (setq harness-chat--dead t)
  (harness-chat--append-local-block "hint" "session deleted")
  (harness-chat--render-tail)
  (force-mode-line-update))

(defun harness-chat--on-event (event args)
  "React to bus EVENT with ARGS."
  (when-let* ((buf (and (member event '("agent/turn-started" "agent/turn-ended"))
                        (harness-chat--buffer-for (car args)))))
    (with-current-buffer buf
      (pcase event
        ("agent/turn-started" (setq harness-chat--turn-start (float-time)) (harness-chat--start-spinner))
        ("agent/turn-ended" (setq harness-chat--turn-start nil)))
      (force-mode-line-update))))

(defun harness-chat--append-local-block (kind text)
  "Append a block of KIND with TEXT that exists only in this buffer."
  (let ((windows (harness-chat--bottom-windows)))
    (harness-chat--append-block
     (harness-chat--new-block (list :id (concat "local-" (harness-short-id 6)) :kind kind :content text)))
    (harness-chat--follow windows)))

(defun harness-chat--buffer-name (session)
  "Return the buffer name for SESSION."
  (let ((name (plist-get session :name)) (id (or (plist-get session :id) "")))
    (format "*harness: %s*" (if (and name (not (string-empty-p name))) name
                               (format "session %s" (substring id 0 (min 8 (length id))))))))

(defun harness-chat--rename-buffer (session)
  "Rename the buffer after SESSION's name."
  (let ((wanted (harness-chat--buffer-name session)))
    (unless (equal (buffer-name) wanted)
      (rename-buffer wanted t))))

;;;; Pending requests

(defun harness-chat--pending-record (id)
  "Return the pending record with ID."
  (cl-find id harness-chat--pending :key (lambda (r) (plist-get r :id)) :test #'equal))

(defun harness-chat--add-pending (record)
  "Add or replace pending RECORD and redraw the panel."
  (let ((old (harness-chat--pending-record (plist-get record :id))))
    (setq harness-chat--pending
          (append (cl-remove old harness-chat--pending)
                  (list (if (and old (plist-get old :respond) (not (plist-get record :respond)))
                            old record)))))
  (harness-chat--render-tail)
  (harness-chat--start-spinner))

(defun harness-chat--remove-pending (id)
  "Forget pending request ID and redraw the panel."
  (setq harness-chat--pending (cl-remove id harness-chat--pending :key (lambda (r) (plist-get r :id)) :test #'equal))
  (harness-chat--render-tail))

(defun harness-chat--sync-pending (items)
  "Reconcile the panel records with the session's pending ITEMS.
Return non-nil when something changed."
  (let ((changed nil) (now (float-time)))
    (dolist (item items)
      (unless (harness-chat--pending-record (plist-get item :id))
        (let* ((payload (plist-get item :payload))
               (kind (harness-chat--str (plist-get item :kind))))
          (setq harness-chat--pending
                (append harness-chat--pending
                        (list (if (equal kind "question")
                                  (list :id (plist-get item :id) :kind "question" :created now
                                        :question (plist-get payload :question) :options (plist-get payload :options))
                                (list :id (plist-get item :id) :kind "permission" :created now
                                      :title (or (plist-get payload :title) (plist-get payload :tool) "tool call")
                                      :tool (plist-get payload :tool) :tool-kind (harness-chat--str (plist-get payload :kind))
                                      :input (plist-get payload :input) :paths (plist-get payload :paths)
                                      :reason (plist-get payload :reason))))))
          (setq changed t))))
    (dolist (r harness-chat--pending)
      (when (and (not (cl-find (plist-get r :id) items :key (lambda (i) (plist-get i :id)) :test #'equal))
                 (> (- now (or (plist-get r :created) 0)) 0.5))
        (setq harness-chat--pending (cl-remove r harness-chat--pending) changed t)))
    changed))

(defun harness-chat--on-permission (params respond)
  "Own permission request PARAMS when its session has a buffer.
The panel answers through RESPOND."
  (when-let* ((buf (harness-chat--buffer-for (plist-get params :sessionId))))
    (with-current-buffer buf
      (let* ((tc (plist-get params :toolCall))
             (extra (plist-get params :_harness))
             (pid (or (plist-get extra :pendingId) (plist-get tc :toolCallId) (harness-short-id 6))))
        (harness-chat--add-pending
         (list :id pid :kind "permission" :respond respond :created (float-time)
               :title (or (plist-get tc :title) (plist-get extra :tool) "tool call")
               :tool (plist-get extra :tool) :tool-kind (plist-get tc :kind)
               :input (plist-get tc :rawInput) :paths (plist-get extra :paths)
               :reason (plist-get extra :reason)
               :options (plist-get params :options)))))
    t))

(defun harness-chat--on-question (params respond)
  "Own the question PARAMS for a session with a buffer; answer via RESPOND."
  (when-let* ((buf (harness-chat--buffer-for (plist-get params :sessionId))))
    (with-current-buffer buf
      (harness-chat--add-pending
       (list :id (or (plist-get params :requestId) (harness-short-id 6)) :kind "question" :respond respond
             :created (float-time)
             :question (plist-get params :question) :options (plist-get params :options))))
    t))

(defun harness-chat--answer-permission (pid option)
  "Answer permission request PID with OPTION (an option id such as \"allow-once\")."
  (when-let* ((r (harness-chat--pending-record pid)))
    (if-let* ((respond (plist-get r :respond)))
        (funcall respond (list :outcome (list :outcome "selected" :optionId option)))
      (harness-ui-call "_harness/permission/answer"
                       (list :session-id harness-ui-session-id :pending-id pid :answer option)
                       #'ignore))
    (harness-chat--remove-pending pid)
    (message "%s" (pcase option
                    ("allow-once" "Allowed") ("allow-session" "Allowed for this session")
                    ("allow-always" "Always allowed") ("deny-always" "Always denied") (_ "Denied")))))

(defun harness-chat--answer-question (pid answer)
  "Answer question PID with ANSWER."
  (when-let* ((r (harness-chat--pending-record pid)))
    (if-let* ((respond (plist-get r :respond)))
        (funcall respond (list :answer answer))
      (harness-ui-call "_harness/question/answer"
                       (list :session-id harness-ui-session-id :pid pid :answer answer)
                       #'ignore))
    (harness-chat--remove-pending pid)))

(defun harness-chat--pending-at-point ()
  "Return the id of the pending request at point, or the newest one."
  (or (get-text-property (point) 'harness-chat-pending)
      (plist-get (car (last harness-chat--pending)) :id)))

(defun harness-chat--permission-command (option)
  "Return a command answering the permission at point with OPTION."
  (lambda ()
    (interactive)
    (let* ((pid (harness-chat--pending-at-point))
           (r (and pid (harness-chat--pending-record pid))))
      (if (and r (equal (plist-get r :kind) "permission"))
          (harness-chat--answer-permission pid option)
        (user-error "No permission request waiting")))))

(defvar harness-chat-panel-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "y") (harness-chat--permission-command "allow-once"))
    (define-key map (kbd "s") (harness-chat--permission-command "allow-session"))
    (define-key map (kbd "a") (harness-chat--permission-command "allow-always"))
    (define-key map (kbd "n") (harness-chat--permission-command "deny-once"))
    (define-key map (kbd "N") (harness-chat--permission-command "deny-always"))
    map)
  "Keys active while point is on a permission panel.")

(defun harness-chat-allow-newest ()
  "Allow the newest pending permission request once."
  (interactive)
  (funcall (harness-chat--permission-command "allow-once")))

(defun harness-chat-deny-newest ()
  "Deny the newest pending permission request once."
  (interactive)
  (funcall (harness-chat--permission-command "deny-once")))

(defun harness-chat--active-question ()
  "Return the newest pending question record, if any."
  (cl-find "question" (reverse harness-chat--pending) :key (lambda (r) (plist-get r :kind)) :test #'equal))

;;;; The tail: panel, queue, attachments, compose

(defun harness-chat--add-keymap (start end map)
  "Give START..END the keymap MAP, composed under any button keymaps."
  (let ((pos start))
    (while (< pos end)
      (let* ((next (min end (or (next-single-property-change pos 'keymap nil end) end)))
             (existing (get-text-property pos 'keymap)))
        (put-text-property pos next 'keymap (if existing (make-composed-keymap (list existing map)) map))
        (setq pos next)))))

(defun harness-chat--insert-permission-panel (r)
  "Insert the panel for permission record R."
  (let ((pid (plist-get r :id))
        (start (point)))
    (insert (propertize (concat " " (harness-ui-icon 'harness-icon-blocked) " Permission  ") 'face 'harness-label-face)
            (propertize (or (plist-get r :title) "tool call") 'face 'harness-tool-title-face)
            "\n")
    (let ((facts (delq nil (list (and (plist-get r :tool-kind) (format "kind: %s" (plist-get r :tool-kind)))
                                 (and (plist-get r :paths)
                                      (format "paths: %s" (mapconcat #'abbreviate-file-name (plist-get r :paths) " ")))))))
      (when facts (insert (propertize (concat "   " (string-join facts "   ") "\n") 'face 'harness-dim-face))))
    (when-let* ((input (plist-get r :input)))
      (insert (propertize (concat "   " (harness-chat--input-summary input) "\n") 'face 'harness-dim-face)))
    (when-let* ((reason (plist-get r :reason)))
      (insert (propertize (format "   %s\n" reason) 'face 'harness-hint-face)))
    (insert "   ")
    (dolist (o '(("Allow" "y" "allow-once") ("Allow for session" "s" "allow-session")
                 ("Always allow" "a" "allow-always") ("Deny" "n" "deny-once") ("Always deny" "N" "deny-always")))
      (let ((option (nth 2 o)))
        (insert (harness-chat--button (format "[%s]" (nth 0 o))
                                      (lambda () (harness-chat--answer-permission pid option))
                                      :help (format "Answer %s (%s)" (nth 0 o) (nth 1 o)))
                " " (harness-chat--kbd (nth 1 o)) "  ")))
    (insert "\n")
    (add-text-properties start (point) (list 'harness-chat-pending pid))
    (add-face-text-property start (point) 'harness-chat-panel-face t)
    (harness-chat--add-keymap start (point) harness-chat-panel-map)))

(defun harness-chat--insert-question-panel (r)
  "Insert the panel for question record R."
  (let ((pid (plist-get r :id))
        (start (point)))
    (insert (propertize (concat " " (harness-ui-icon 'harness-chat-icon-question) " Question  ") 'face 'harness-label-face)
            (propertize (or (plist-get r :question) "") 'face 'bold) "\n   ")
    (dolist (option (plist-get r :options))
      (insert (harness-chat--button (format "[%s]" option)
                                    (lambda () (harness-chat--answer-question pid option))
                                    :help "Answer with this option")
              "  "))
    (insert (propertize "or type an answer below and press C-c C-c" 'face 'harness-dim-face) "\n")
    (add-text-properties start (point) (list 'harness-chat-pending pid))
    (add-face-text-property start (point) 'harness-chat-panel-face t)))

(defun harness-chat--insert-queue ()
  "Insert the queued messages list."
  (when harness-chat--queue
    (let ((start (point)))
      (insert (propertize (format " queued for the next turn (%d)  " (length harness-chat--queue)) 'face 'harness-label-face)
              (harness-chat--button "[Send now]" #'harness-chat-send-queue :help "Send every queued message now")
              "\n")
      (dolist (item harness-chat--queue)
        (let ((qid (plist-get item :id)))
          (insert "   "
                  (harness-chat--button "[edit]" (lambda () (harness-chat-edit-queued qid)) :help "Edit this message")
                  " "
                  (harness-chat--button "[×]" (lambda () (harness-chat-remove-queued qid)) :help "Remove from the queue")
                  " "
                  (propertize (harness-first-line (plist-get item :text) 100) 'wrap-prefix "   ")
                  (if (plist-get item :attachments)
                      (propertize (format "  %s%d" (harness-ui-icon 'harness-icon-attach)
                                          (length (plist-get item :attachments)))
                                  'face 'harness-dim-face)
                    "")
                  "\n")))
      (add-face-text-property start (point) 'harness-queue-face t))))

(defun harness-chat--render-tail ()
  "Render everything below the transcript, keeping the compose text."
  (harness-chat--with-display (harness-chat--render-tail-1)))

(defun harness-chat--render-tail-1 ()
  "Do the work of `harness-chat--render-tail'."
  (harness-compose-capture)
  (let* ((offset (and (harness-compose-in-p) (- (point) harness-compose-start)))
         (in-tail (>= (point) harness-chat--transcript-end))
         (inhibit-read-only t)
         (buffer-undo-list t)
         (bottom (harness-chat--bottom-windows))
         (windows (mapcar (lambda (w) (cons w (window-start w))) (harness-chat--windows))))
    (save-excursion
      (delete-region harness-chat--transcript-end (point-max))
      (goto-char harness-chat--transcript-end)
      (let ((start (point)))
        (dolist (r harness-chat--pending)
          (if (equal (plist-get r :kind) "question")
              (harness-chat--insert-question-panel r)
            (harness-chat--insert-permission-panel r)))
        (harness-chat--insert-queue)
        (harness-compose-insert-attachments)
        (when harness-chat--dead
          (insert (propertize " This session was deleted; the transcript stays readable.\n" 'face 'harness-hint-face)))
        (put-text-property start (point) 'read-only t)
        (harness-compose-insert nil "C-c C-c sends, RET newline, C-c C-q queues, C-c C-k cancels, C-c C-a attaches")))
    (cond (offset (goto-char (min (+ harness-compose-start offset) harness-compose-end)))
          (in-tail (goto-char harness-compose-end)))
    (dolist (w windows)
      (cond ((not (window-live-p (car w))))
            ;; A window following the conversation keeps showing the newest
            ;; lines, so a new panel or queue entry never lands off screen.
            ((memq (car w) bottom)
             (unless (eq (car w) (selected-window))
               (set-window-point (car w) harness-compose-end))
             (harness-chat--pin (car w)))
            ((< (cdr w) harness-chat--transcript-end)
             (set-window-start (car w) (cdr w) t))))))

(defun harness-chat--placeholder ()
  "Return the hint for the empty compose box."
  (cond (harness-chat--dead "session deleted")
        ((harness-chat--active-question) "type an answer and press C-c C-c")
        (t "Message…")))

;;;; Bottom anchoring

;;;; Top region and history

(defun harness-chat--render-top ()
  "Render the region above the first block (its separator newline stays)."
  (let ((text (cond (harness-chat--loading (propertize " loading…" 'face 'harness-dim-face))
                    (harness-chat--has-more
                     (concat " " (harness-chat--button "Show earlier messages" #'harness-chat-load-earlier
                                                       :help "Load older history (C-c C-l)")))
                    ((null harness-chat--order) (propertize " No messages yet." 'face 'harness-dim-face))
                    (t ""))))
    (add-text-properties 0 (length text) '(read-only t rear-nonsticky t) text)
    (harness-chat--replace-region (point-min) (1- (marker-position harness-chat--transcript-start)) text)))

(defun harness-chat--reset-buffer ()
  "Empty the buffer and every rendering structure."
  (harness-chat--cancel-all-renders)
  (mapc #'delete-overlay (overlays-in (point-min) (point-max)))
  (let ((inhibit-read-only t) (buffer-undo-list t))
    (erase-buffer)
    (insert (propertize "\n" 'read-only t 'rear-nonsticky t)))
  (setq harness-chat--blocks (make-hash-table :test 'equal)
        harness-chat--calls (make-hash-table :test 'equal)
        harness-chat--groups (make-hash-table :test 'equal)
        harness-chat--render-timers (make-hash-table :test 'equal)
        harness-chat--order nil
        harness-chat--unfinished nil
        harness-compose-start nil
        harness-compose-end nil
        harness-chat--transcript-start (copy-marker (point-max))
        harness-chat--transcript-end (copy-marker (point-max))))

(defun harness-chat--render-nodes (nodes)
  "Render NODES (oldest first) as the whole transcript."
  (harness-compose-capture)
  (harness-chat--reset-buffer)
  (let ((harness-chat--batch t))
    (dolist (node nodes)
      (harness-chat--on-node node))
    (harness-chat--regroup))
  (harness-chat--render-top)
  (harness-chat--render-tail))

(defun harness-chat--oldest-id ()
  "Return the id of the oldest rendered node."
  (car (last harness-chat--order)))

(defun harness-chat-load-earlier ()
  "Load the previous page of history above the transcript."
  (interactive)
  (let ((buf (current-buffer))
        (before (harness-chat--oldest-id))
        (gen harness-chat--generation))
    (unless before (user-error "Nothing rendered yet"))
    (harness-ui-call "_harness/session/nodes"
                     (list :id harness-ui-session-id :opts (list :limit harness-chat-history-page :before before))
                     (lambda (nodes)
                       (when (buffer-live-p buf)
                         (with-current-buffer buf
                           (when (= gen harness-chat--generation)
                             (harness-chat--prepend-nodes nodes)
                             (setq harness-chat--has-more (>= (length nodes) harness-chat-history-page))
                             (harness-chat--render-top))))))))

(defun harness-chat--prepend-nodes (nodes)
  "Render NODES (oldest first) above the current first block."
  (when nodes
    (let ((harness-chat--batch t)
          (results nil)
          (ids nil))
      (harness-chat--clear-groups)
      (let* ((first (gethash (harness-chat--oldest-id) harness-chat--blocks))
             (anchor (harness-chat-block-start first))
             (pos (marker-position anchor)))
        (let ((previous nil))
          (dolist (node nodes)
            (if (and (equal (harness-chat--str (plist-get node :kind)) "tool-result")
                     (gethash (plist-get node :call-id) harness-chat--calls))
                (push node results)
              (let ((block (harness-chat--new-block node)))
                (setf (harness-chat-block-head block) (harness-chat--head-p (harness-chat-block-kind block) previous))
                (harness-chat--insert-block block pos)
                (setq pos (marker-position (harness-chat-block-end block))
                      previous (harness-chat-block-kind block))
                (push (harness-chat-block-id block) ids))))
          (set-marker anchor pos)
          ;; The old first block may no longer open a turn.
          (let ((head (harness-chat--head-p (harness-chat-block-kind first) previous)))
            (unless (eq (not head) (not (harness-chat-block-head first)))
              (setf (harness-chat-block-head first) head)
              (harness-chat--rerender first)))))
      (setq harness-chat--order (append harness-chat--order ids))
      (dolist (r (nreverse results))
        (when-let* ((call (gethash (gethash (plist-get r :call-id) harness-chat--calls) harness-chat--blocks)))
          (setf (harness-chat-block-result call) r)
          (puthash (plist-get r :id) call harness-chat--blocks)
          (harness-chat--rerender call)))
      (harness-chat--regroup))))

;;;; Loading

(defun harness-chat--load (&optional keep-bottom)
  "Fetch tools and the newest nodes, then render the buffer from scratch.
The old transcript stays on screen until the new one is ready, and
every window keeps its place.  With KEEP-BOTTOM non-nil scroll to the
end afterwards."
  (let* ((buf (current-buffer))
         (sid harness-ui-session-id)
         (gen (cl-incf harness-chat--generation)))
    (harness-compose-capture)
    (setq harness-chat--loading t harness-chat--deferred nil)
    ;; Only an empty buffer shows "loading…": blanking a full one would
    ;; flash the top of the buffer before the windows find their place again.
    (unless harness-chat--order (harness-chat--render-nodes nil))
    (if (harness-chat--session)
        (progn (harness-chat--fetch-session) (harness-compose-fetch-completions))
      ;; Completion sources need the project root: fetch them once the session is known.
      (harness-chat--fetch-session #'harness-compose-fetch-completions))
    (harness-then
     (harness-all (list (harness-ui-request "_harness/tools/list" (list :session-id sid))
                        (harness-ui-request "_harness/session/nodes"
                                            (list :id sid :opts (list :limit harness-chat-history-limit)))))
     (lambda (results)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (when (= gen harness-chat--generation)
             (setq harness-chat--coalescable
                   (delq nil (mapcar (lambda (tool) (and (harness-json-true-p (plist-get tool :coalescable))
                                                         (plist-get tool :name)))
                                     (car results))))
             (let ((nodes (cadr results))
                   (anchors (harness-chat--window-anchors))
                   (offset (and (harness-compose-in-p) (- (point) harness-compose-start))))
               (setq harness-chat--has-more (>= (length nodes) harness-chat-history-limit)
                     harness-chat--loading nil)
               (harness-chat--render-nodes nodes)
               (when offset
                 (goto-char (min (+ harness-compose-start offset) harness-compose-end)))
               (harness-chat--restore-anchors anchors)
               (dolist (u (nreverse harness-chat--deferred))
                 (when (and (equal (plist-get u :sessionUpdate) "_harness/node")
                            (harness-chat--node-current-p (plist-get u :node)))
                   (harness-chat--apply-update u)))
               (setq harness-chat--deferred nil)
               (when keep-bottom (harness-chat-scroll-to-bottom)))))))
     (lambda (err)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (when (= gen harness-chat--generation)
             (setq harness-chat--loading nil)
             (harness-chat--render-nodes nil)
             (harness-chat--append-local-block "error" (format "could not load the session: %s" (harness-error-message err)))
             (harness-chat--render-top))))))))

(defun harness-chat--node-current-p (node)
  "Non-nil when NODE is rendered already or continues the rendered transcript.
Used to replay announcements that arrived while the history was being
fetched: older nodes outside the fetched window are skipped."
  (let ((newest (and harness-chat--order (gethash (car harness-chat--order) harness-chat--blocks))))
    (or (gethash (plist-get node :id) harness-chat--blocks)
        (null newest)
        (equal (plist-get node :parent) (harness-chat-block-id newest))
        (let ((ts (plist-get node :ts)) (last (plist-get (harness-chat-block-node newest) :ts)))
          (and (numberp ts) (numberp last) (> ts last))))))

(defun harness-chat--fetch-session (&optional then)
  "Make sure the session plist is cached, then call THEN in the buffer."
  (let ((buf (current-buffer)))
    (harness-ui-call "_harness/session/get" (list :id harness-ui-session-id)
                     (lambda (session)
                       (harness-ui--cache-session session)
                       (when (buffer-live-p buf)
                         (with-current-buffer buf
                           (harness-chat--on-session session)
                           (when then (funcall then)))))
                     #'ignore)))

(defun harness-chat--redraw-all ()
  "Rebuild every chat buffer from scratch, keeping compose text and scroll state."
  (maphash (lambda (_ buf)
             (when (buffer-live-p buf)
               (with-current-buffer buf
                 (harness-chat--load (harness-chat--at-bottom-p)))))
           harness-chat--buffers))

;;;; Sending

(defun harness-chat--clear-compose ()
  "Empty the compose box and the attachments."
  (setq harness-chat--editing nil)
  (harness-compose-clear))

(defun harness-chat--take-message ()
  "Return (TEXT . ATTACHMENTS) from the compose box, or signal when empty."
  (when harness-chat--dead (user-error "This session was deleted"))
  (harness-compose-take))

(defun harness-chat--drop-edited-queue-item ()
  "Remove the queue item being edited, if any."
  (when harness-chat--editing
    (harness-ui-call "_harness/session/queue-remove" (list :id harness-ui-session-id :qid harness-chat--editing) #'ignore)
    (setq harness-chat--editing nil)))

(defun harness-chat--report-error (buf what err)
  "Append an error block to BUF saying WHAT failed with ERR."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (harness-chat--append-local-block "error" (format "%s failed: %s" what (harness-error-message err))))))

(defun harness-chat-send ()
  "Send the compose box, or answer the active question with it.
While the agent is running the message steers the current turn."
  (interactive)
  (let ((question (harness-chat--active-question))
        (typed (string-trim (harness-compose-text))))
    (if (and question (not (string-empty-p typed)))
        (progn (harness-chat--answer-question (plist-get question :id) typed)
               (harness-chat--clear-compose))
      (pcase-let ((`(,text . ,atts) (harness-chat--take-message))
                  (buf (current-buffer))
                  (sid harness-ui-session-id))
        (harness-chat--drop-edited-queue-item)
        (harness-chat--clear-compose)
        (harness-compose-with-expanded-text
         text
         (lambda (expanded)
           (let ((blocks (append (and (not (string-empty-p expanded)) (list (list :type "text" :text expanded)))
                                 (mapcar #'harness-compose-attachment-block atts))))
             (harness-ui-call "session/prompt" (list :sessionId sid :prompt blocks)
                              #'ignore
                              (lambda (err) (harness-chat--report-error buf "send" err))))))))))

(defun harness-chat-queue ()
  "Queue the compose box for the next turn."
  (interactive)
  (pcase-let ((`(,text . ,atts) (harness-chat--take-message))
              (buf (current-buffer))
              (sid harness-ui-session-id))
    (harness-chat--drop-edited-queue-item)
    (harness-chat--clear-compose)
    (harness-compose-with-expanded-text
     text
     (lambda (expanded)
       (harness-ui-call "_harness/agent/prompt"
                        (list :session-id sid :blocks (list (list :type "text" :text expanded))
                              :opts (list :queue t :attachments atts))
                        #'ignore
                        (lambda (err) (harness-chat--report-error buf "queue" err)))))))

(defun harness-chat-send-queue ()
  "Send every queued message now."
  (interactive)
  (harness-ui-call "_harness/agent/send-queue" (list :session-id harness-ui-session-id) #'ignore))

(defun harness-chat-edit-queued (qid)
  "Load queued item QID into the compose box; sending removes it from the queue."
  (interactive (list (plist-get (car harness-chat--queue) :id)))
  (when-let* ((item (cl-find qid harness-chat--queue :key (lambda (i) (plist-get i :id)) :test #'equal)))
    (harness-compose-set (or (plist-get item :text) ""))
    (setq harness-compose-attachments (plist-get item :attachments)
          harness-chat--editing qid)
    (harness-chat--render-tail)
    (goto-char harness-compose-end)))

(defun harness-chat-remove-queued (qid)
  "Remove queued item QID."
  (interactive (list (plist-get (car harness-chat--queue) :id)))
  (harness-ui-call "_harness/session/queue-remove" (list :id harness-ui-session-id :qid qid) #'ignore))

(defun harness-chat-cancel ()
  "Cancel the running turn."
  (interactive)
  (harness-cancel-turn harness-ui-session-id))

;;;; Header and mode lines

(defun harness-chat--segment-map (command)
  "Return a keymap running COMMAND on a header or mode line click.
COMMAND runs with the clicked window selected."
  (or (gethash command harness-chat--segment-maps)
      (let ((map (make-sparse-keymap))
            (fn (lambda (event)
                  (interactive "e")
                  (with-selected-window (posn-window (event-start event))
                    (call-interactively command)))))
        (define-key map [header-line mouse-1] fn)
        (define-key map [mode-line mouse-1] fn)
        (define-key map [mouse-1] fn)
        (puthash command map harness-chat--segment-maps))))

(defun harness-chat--segment (text command help &optional face)
  "Return TEXT as a clickable segment running COMMAND, with HELP and FACE.
Icons in TEXT stay clickable but are not hover-highlighted: an SVG keeps
the background it was rendered on, so it would show as a dark box."
  (let ((text (propertize text 'face face 'help-echo help 'mouse-face 'mode-line-highlight
                          'local-map (harness-chat--segment-map command)))
        (pos 0))
    (while (< pos (length text))
      (let ((next (next-single-property-change pos 'display text (length text))))
        (when (eq (car-safe (get-text-property pos 'display text)) 'image)
          (remove-text-properties pos next '(mouse-face nil) text))
        (setq pos next)))
    text))

(defun harness-chat--header ()
  "Return the header line."
  (let* ((s (harness-chat--session))
         (status (or (plist-get s :status) "idle"))
         (running (equal status "running"))
         (name (or (plist-get s :name) "unnamed"))
         (usage (plist-get s :usage)))
    (concat
     " "
     (if running
         (propertize (aref harness-chat--spinner-frames
                           (% harness-chat--spinner-index (length harness-chat--spinner-frames)))
                     'face 'harness-status-running-face 'help-echo "Running")
       (propertize (harness-ui-status-icon status) 'help-echo status))
     " "
     (harness-chat--segment name #'harness-rename-session "Session name (mouse-1: rename)" 'bold)
     "  "
     (harness-chat--segment (harness-ui-model-label (plist-get s :model)) #'harness-set-model
                            "Model (mouse-1: change)" 'harness-dim-face)
     "  "
     (harness-chat--segment (or (plist-get s :permission-mode) "ask") #'harness-set-permission-mode
                            "Permission mode (mouse-1: change)")
     "  "
     (harness-chat--segment (harness-ui-thinking-label (plist-get s :thinking))
                            #'harness-set-thinking "Thinking level (mouse-1: change)" 'harness-dim-face)
     "  "
     (harness-ui-format-context s)
     "  "
     (propertize (harness-format-cost (plist-get usage :cost)) 'help-echo "Session cost")
     "  "
     (harness-chat--segment "[menu]" #'harness-menu "The harness menu (C-c a ?)" 'harness-dim-face)
     (if harness-chat--unseen
         (concat "  " (harness-chat--segment "↓ new messages" #'harness-chat-scroll-to-bottom
                                             "New content below (mouse-1: jump to it)" 'harness-status-blocked-face))
       ""))))

(defun harness-chat--mode-line ()
  "Return the mode line text."
  (let* ((s (harness-chat--session))
         (status (or (plist-get s :status) "idle")))
    (concat
     (harness-ui-status-icon status) " "
     (propertize status 'face (harness-ui-status-face status))
     (if (and harness-chat--turn-start (member status '("running" "blocked")))
         (propertize (format " %s" (harness-format-duration (- (float-time) harness-chat--turn-start)))
                     'face 'harness-dim-face 'help-echo "Turn duration")
       ""))))

(defun harness-chat-reposition (position)
  "Show this session in POSITION instead."
  (interactive (list (harness-ui-read-position)))
  (harness-ui-display-session harness-ui-session-id position))

(defun harness-chat--spinner-tick ()
  "Advance the spinner while a visible session runs; stop otherwise."
  (let ((any nil))
    (maphash (lambda (_ buf)
               (when (and (buffer-live-p buf) (get-buffer-window buf 'visible))
                 (with-current-buffer buf
                   (when (member (plist-get (harness-chat--session) :status) '("running" "blocked"))
                     (setq any t)
                     (force-mode-line-update)))))
             harness-chat--buffers)
    (cl-incf harness-chat--spinner-index)
    (unless any
      (when harness-chat--spinner-timer (cancel-timer harness-chat--spinner-timer))
      (setq harness-chat--spinner-timer nil))))

(defun harness-chat--start-spinner ()
  "Start the spinner timer when it is not running."
  (unless harness-chat--spinner-timer
    (setq harness-chat--spinner-timer (run-at-time 0.1 0.1 #'harness-chat--spinner-tick))))

;;;; Other commands

(defun harness-chat-search ()
  "Search the transcript incrementally, opening collapsed blocks on a match."
  (interactive)
  (setq-local search-invisible 'open)
  (isearch-forward))

(defun harness-chat-copy-last-response ()
  "Copy the agent's last message (raw Markdown) to the kill ring."
  (interactive)
  (let ((id (cl-find-if (lambda (id) (equal (harness-chat-block-kind (gethash id harness-chat--blocks)) "assistant"))
                        harness-chat--order)))
    (unless id (user-error "No agent response yet"))
    (kill-new (or (harness-chat-block-content (gethash id harness-chat--blocks)) ""))
    (message "Copied the last response")))

(defun harness-chat-tab ()
  "Complete in the compose box; elsewhere expand or collapse the block at point."
  (interactive)
  (cond ((harness-compose-in-p) (completion-at-point))
        ((get-text-property (point) 'harness-chat-group) (harness-chat-toggle-group))
        ((get-text-property (point) 'harness-chat-node)
         (let ((b (gethash (get-text-property (point) 'harness-chat-node) harness-chat--blocks)))
           (if (and b (harness-chat-block-fold b)) (harness-chat-toggle-block)
             (goto-char harness-compose-end))))
        (t (goto-char harness-compose-end))))

(defun harness-chat-redraw ()
  "Render this buffer again from the harness."
  (interactive)
  (harness-chat--load (harness-chat--at-bottom-p)))

;;;###autoload
(defun harness-open-session (id &optional position)
  "Open session ID in POSITION (resuming it when inactive)."
  (interactive (list (plist-get (harness-ui-read-session "Open session: ") :id)
                     (and current-prefix-arg (harness-ui-read-position))))
  (harness-ui-call "_harness/session/resume" (list :id id)
                   (lambda (_) (harness-ui-display-session id position))
                   (lambda (_) (harness-ui-display-session id position))))

;;;###autoload
(defun harness-open-latest-session (&optional position)
  "Open the newest session of the current project in POSITION."
  (interactive (list (and current-prefix-arg (harness-ui-read-position))))
  (let* ((root (harness-chat--project-root default-directory))
         (mine (harness-ui-sessions (lambda (s) (equal (plist-get s :project) root)))))
    (if mine
        (harness-open-session (plist-get (car mine) :id) position)
      (harness-new-session root position))))

;;;; Mode

(define-obsolete-function-alias 'harness-chat-add-attachment #'harness-compose-add-attachment "3.1")
(define-obsolete-function-alias 'harness-chat-remove-attachment #'harness-compose-remove-attachment "3.1")
(define-obsolete-function-alias 'harness-chat-attach-clipboard #'harness-compose-attach-clipboard "3.1")
(define-obsolete-function-alias 'harness-chat-newline #'harness-compose-newline "3.1")
(define-obsolete-function-alias 'harness-chat-completion-at-point #'harness-compose-completion-at-point "3.1")

(defvar harness-chat-mode-map
  (let ((map (make-sparse-keymap)))
    ;; The compose box's keys; not `special-mode-map', whose letters would
    ;; eat typing in the box.
    (set-keymap-parent map harness-compose-map)
    (define-key map (kbd "TAB") #'harness-chat-tab)
    (define-key map (kbd "C-c C-q") #'harness-chat-queue)
    (define-key map (kbd "C-c C-c") #'harness-chat-send)
    (define-key map (kbd "C-c C-k") #'harness-chat-cancel)
    (define-key map (kbd "C-c C-s") #'harness-chat-search)
    (define-key map (kbd "C-c C-y") #'harness-chat-allow-newest)
    (define-key map (kbd "C-c C-n") #'harness-chat-deny-newest)
    (define-key map (kbd "C-c C-w") #'harness-chat-copy-last-response)
    (define-key map (kbd "C-c C-l") #'harness-chat-load-earlier)
    (define-key map (kbd "C-c C-r") #'harness-chat-redraw)
    (define-key map (kbd "C-c C-e") #'harness-chat-scroll-to-bottom)
    map)
  "Keymap of `harness-chat-mode'.")

(define-derived-mode harness-chat-mode special-mode "Chat"
  "Major mode of a harness session buffer.
The transcript is read-only; the compose box at the bottom is editable."
  (setq buffer-read-only nil)
  (setq-local truncate-lines nil
              word-wrap t
              search-invisible 'open
              header-line-format '(:eval (harness-chat--header))
              mode-line-format '(" " (:eval (harness-chat--mode-line)) "  " mode-line-misc-info))
  (add-to-invisibility-spec 'harness-chat-fold)
  (harness-compose-setup :project #'harness-chat--project
                         :placeholder #'harness-chat--placeholder
                         :redraw #'harness-chat--render-tail
                         :bottom t)
  (add-hook 'post-command-hook #'harness-chat--post-command nil t)
  (add-hook 'window-buffer-change-functions #'harness-chat--on-window-buffer-change nil t)
  (add-hook 'kill-buffer-hook #'harness-chat--on-kill nil t))

(defun harness-chat--post-command ()
  "Keep the new-messages indicator current."
  (when (and harness-chat--unseen (harness-chat--at-bottom-p (selected-window)))
    (setq harness-chat--unseen nil)
    (force-mode-line-update)))

(defun harness-chat--on-kill ()
  "Forget the buffer and its timers."
  (harness-chat--cancel-all-renders)
  (when (eq (gethash harness-ui-session-id harness-chat--buffers) (current-buffer))
    (remhash harness-ui-session-id harness-chat--buffers)))

(defun harness-chat-buffer (id)
  "Return the chat buffer of session ID, creating and loading it when needed."
  (or (harness-chat--buffer-for id)
      (let* ((session (harness-ui-session id))
             (buf (generate-new-buffer (harness-chat--buffer-name (or session (list :id id))))))
        (puthash id buf harness-chat--buffers)
        (with-current-buffer buf
          (harness-chat-mode)
          (setq harness-ui-session-id id)
          (setq default-directory (or (plist-get session :cwd) default-directory))
          (harness-chat--load t))
        buf)))

;;;; Module

(defun harness-chat--init ()
  "Hook the chat into the UI foundation."
  (setq harness-ui-open-session-function #'harness-chat-buffer)
  (add-hook 'harness-ui-update-functions #'harness-chat--on-update)
  (add-hook 'harness-ui-event-functions #'harness-chat--on-event)
  (add-hook 'harness-ui-permission-functions #'harness-chat--on-permission)
  (add-hook 'harness-ui-question-functions #'harness-chat--on-question)
  (add-hook 'harness-ui-redraw-hook #'harness-chat--redraw-all)
  (define-key harness-ui-map (kbd "o") #'harness-open-latest-session)
  (define-key harness-ui-map (kbd "O") #'harness-open-session)
  (ignore-errors
    (transient-append-suffix 'harness-menu "s" '("o" "Open latest session" harness-open-latest-session))))

(harness-define-module 'ui-chat
  :doc "The chat buffer: transcript, pending panel, queue, attachments and compose box."
  :requires '(ui)
  :init #'harness-chat--init)

(provide 'harness-ui-chat)
;;; harness-ui-chat.el ends here
