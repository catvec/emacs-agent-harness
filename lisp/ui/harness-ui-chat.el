;;; harness-ui-chat.el --- The chat buffer  -*- lexical-binding: t; -*-

;;; Commentary:

;; One buffer per session, "*harness: NAME*", laid out top to bottom:
;;
;;   header line   status, name, todo progress, model, permission mode,
;;                 non-interactive or interactive, thinking, context,
;;                 cost, menu, after what
;;                 `harness-chat-header-functions' put in front (a BTW's buttons)
;;   transcript    one block per node, rendered incrementally with markers
;;   activity      while a turn runs, what it does and for how long, on a
;;                 background of its own, then a blank line
;;   pending panel permission requests and questions waiting for the user;
;;                 a question whose options have diagrams shows one of
;;                 them at a time, in one place, and switches between them
;;   queue         messages queued for the next turn
;;   todos         the session's todo items, one per line, or folded
;;   attachments   chips for files attached to the next message
;;   notice        the session was deleted, or is inactive (sending resumes it)
;;   compose       an editable region; C-c C-c sends, RET adds a newline
;;   mode line     status, turn duration
;;
;; The transcript is never re-rendered on a delta: every node owns a
;; region delimited by two markers, streaming text is appended at the
;; end of the live node's region, and a block is rendered through the
;; Markdown renderer only when it is finalised or at most every
;; `harness-chat--render-interval' seconds.  Thinking, tool calls,
;; compaction summaries and runs of coalescable tools collapse under
;; overlays that isearch opens, so every word of the conversation stays
;; searchable.  History loads lazily: the newest
;; `harness-chat--history-limit' nodes at open, an older page whenever a
;; window scrolls near the top, and blocks far above every window are
;; dropped again so a long session never fills the buffer.
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
(require 'text-property-search)
(require 'dnd)
(require 'harness-core)
(require 'harness-util)
(require 'harness-acp)
(require 'harness-ui)
(require 'harness-ui-compose)
(require 'harness-files)
(require 'harness-ui-markdown)
(require 'harness-ui-pending)

(declare-function harness-ui-media-render-attachment "harness-ui-media" (attachment))
(defvar harness-state-directory)

(defgroup harness-ui-chat nil
  "The chat buffer." :group 'harness-ui :prefix "harness-chat-")

;;;; Customisation

(defconst harness-chat--history-limit 60
  "Number of nodes rendered when a session buffer opens.")

(defconst harness-chat--history-page 100
  "Number of older nodes loaded when a window scrolls near the top.
Once two pages of nodes lie above every window, all but one are dropped.")

(defconst harness-chat--compose-max-lines 8
  "Lines the compose box grows to before the window scrolls instead.")

(defconst harness-chat--tool-output-limit 3000
  "Characters of tool output shown before a \"show all\" button.")

(defconst harness-chat--render-interval 0.3
  "Seconds between Markdown re-renders of a streaming block.")

(defconst harness-chat--coalesce-threshold 3
  "Consecutive coalescable tool calls needed to fold into one summary block.")

(defcustom harness-chat-user-label "You"
  "Sender name shown above the user's messages."
  :type 'string :group 'harness-ui-chat)

(defcustom harness-chat-agent-label "Agent"
  "Sender name shown at the start of each agent turn."
  :type 'string :group 'harness-ui-chat)

(defcustom harness-chat-system-label "System"
  "Sender name shown above the messages the harness sent on its own.
A task carrying on after a restart, non-interactive mode after a denied
call and the merge queue send them; the part of the harness that sent
one follows the name."
  :type 'string :group 'harness-ui-chat)

(defcustom harness-chat-session-label "Session"
  "Sender name shown above the messages the agent of another session sent.
`session_send' and a sub-agent's parent send them; the name of the
session follows, a button that opens it."
  :type 'string :group 'harness-ui-chat)

(defface harness-chat-panel-face
  '((((background light)) :background "#d9f7fd" :extend t)
    (((background dark)) :background "#143c42" :extend t))
  "Background of the pending permission and question panel.
A cool teal of its own: it stands apart from the transcript's blocks
and the queue under it, and asks for an answer without the alarm of a
warning colour." :group 'harness-ui-chat)
(defface harness-chat-activity-face
  '((((background light)) :background "#efe9f9" :extend t)
    (((background dark)) :background "#2e2942" :extend t))
  "Background of the activity line, which says what a running turn does.
A colour of its own, so the line stands apart from the compose box
under it." :group 'harness-ui-chat)

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
(defvar-local harness-chat--pending nil
  "The session's requests, as the pending module last reported them.
The module owns them (`harness-ui-pending-items'); this mirror is for
the panels this buffer draws and for redraw decisions.")
(defvar-local harness-chat--editing nil "Queue item id loaded into the compose box.")
(defvar-local harness-chat--has-more nil "Non-nil when older nodes exist.")
(defvar-local harness-chat--loading nil "Non-nil while the transcript is being fetched.")
(defvar-local harness-chat--fetching nil "Non-nil while an older page is being fetched.")
(defvar-local harness-chat--history-timer nil "Timer of the pending `harness-chat--manage-history'.")
(defvar-local harness-chat--deferred nil "Updates that arrived while loading, newest first.")
(defvar-local harness-chat--coalescable nil "Names of coalescable tools.")
(defvar-local harness-chat--turn-start nil "Float time the running turn started.")
(defvar-local harness-chat--unseen nil "Non-nil when content arrived while scrolled up.")
(defvar-local harness-chat--dead nil "Non-nil once the session was deleted.")
(defvar-local harness-chat--render-timers nil "Node id -> throttle timer.")
(defvar-local harness-chat--generation 0 "Bumped on every reload to drop stale responses.")
(defvar-local harness-chat--session nil "Last session plist seen, for after deletion.")
(defvar-local harness-chat--unfinished nil "Ids of tool-call blocks without a result yet.")
(defvar-local harness-chat--inactive nil "Non-nil while the session is inactive; sending resumes it.")
(defvar-local harness-chat--todos nil
  "The session's todo list as last seen: a list of (:text :status).")
(defvar-local harness-chat--todos-collapsed nil
  "Non-nil when the todo panel shows its title line alone.")
(defvar-local harness-chat--activity nil
  "What the running turn does, as `agent/activity' last said (wire shape).")
(defvar-local harness-chat--activity-overlay nil
  "Overlay at the end of the transcript whose `before-string' is the activity line.")

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

(defalias 'harness-chat--face #'harness-ui-add-face
  "Alias of `harness-ui-add-face'.")

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

(defalias 'harness-chat--ensure-newline #'harness-ui-ensure-newline
  "Alias of `harness-ui-ensure-newline', for the chat's own use.")

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

(defalias 'harness-chat--kbd #'harness-ui-kbd
  "Alias of `harness-ui-kbd'.")

(defalias 'harness-chat--mouse-map #'harness-ui-action-map
  "Alias of `harness-ui-action-map'.")

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

(defalias 'harness-chat--button #'harness-ui-action-button
  "Alias of `harness-ui-action-button'.")

(defalias 'harness-chat-push #'harness-ui-action-push
  "Alias of `harness-ui-action-push'.")

;;;; Region editing that keeps windows still

(defalias 'harness-chat--fix-positions #'harness-ui--fix-positions
  "Alias of `harness-ui--fix-positions'.")

(defalias 'harness-chat--window-positions #'harness-ui--window-positions
  "Alias of `harness-ui--window-positions'.")

(defalias 'harness-chat--replace-region #'harness-ui-replace-region
  "Alias of `harness-ui-replace-region'.")

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

(defun harness-chat--attachment-mime (att)
  "Return the MIME type of the attachment plist ATT.
Guessed from the file name when ATT carries none, as the media module
does, so an attachment without one still shows as what it is."
  (or (plist-get att :mime)
      (let ((ext (file-name-extension (or (plist-get att :path) (plist-get att :name) ""))))
        (and ext (not (string-empty-p ext)) (mailcap-extension-to-mime (concat "." ext))))
      ""))

(defun harness-chat--media-mime-p (mime)
  "Non-nil when MIME is an image or a video, which the chat shows itself."
  (or (string-prefix-p "image/" mime) (string-prefix-p "video/" mime)))

(defun harness-chat--attachment-shows-media-p (att)
  "Non-nil when ATT is an image or a video, drawn in the transcript."
  (harness-chat--media-mime-p (harness-chat--attachment-mime att)))

(defun harness-chat--show-media (att)
  "Return the transcript string for media attachment ATT, or nil.
Images go through `harness-chat--image-string'; videos and audio
through the media module, so a video shows its poster and plays from
here.  Nil when ATT is not media, or the media module is not loaded."
  (let* ((mime (harness-chat--attachment-mime att))
         (path (plist-get att :path))
         (kind (cond ((string-prefix-p "image/" mime) 'image)
                     ((string-prefix-p "video/" mime) 'av)
                     ((string-prefix-p "audio/" mime) 'av))))
    (pcase kind
      ('image (harness-chat--image-string (or path (list :data (plist-get att :data))) mime))
      ('av (when (and path (fboundp 'harness-ui-media-render-attachment))
             (let ((s (ignore-errors (harness-ui-media-render-attachment att))))
               (and (stringp s) (not (string-blank-p s)) (harness-chat--ensure-newline s)))))
      (_ nil))))
(defalias 'harness-chat--image-string #'harness-ui-image-string
  "Alias of `harness-ui-image-string'.")

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
  "Return a string showing tool-result attachment ATT.
An image shows its picture, a video its poster (which plays), audio
its player, anything else a file button."
  (let* ((mime (harness-chat--attachment-mime att))
         (path (plist-get att :path))
         (media (and (not (string-prefix-p "image/" mime))
                     (fboundp 'harness-ui-media-render-attachment)
                     (ignore-errors (harness-ui-media-render-attachment att)))))
    (cond
     ((string-prefix-p "image/" mime) (harness-chat--image-string path mime))
     ((and (stringp media) (not (string-blank-p media))) (harness-chat--ensure-newline media))
     (path (harness-chat--file-button path (plist-get att :name) (plist-get att :size)))
     ((plist-get att :data) (harness-chat--image-string (list :data (plist-get att :data)) mime))
     (t ""))))

(defun harness-chat--blocks-string (blocks)
  "Return the non-text content BLOCKS of a node as a string."
  (mapconcat (lambda (b)
               (pcase (harness-chat--str (plist-get b :type))
                 ("image" (harness-chat--image-string (or (plist-get b :path) (list :data (plist-get b :data)))
                                                      (plist-get b :mime)))
                 ((or "video" "audio")
                  (or (harness-chat--show-media b)
                      (concat (propertize (format "[%s]" (harness-chat--str (plist-get b :type))) 'face 'harness-dim-face)
                              "\n")))
                 ;; A file a person attached is shown as what it is: a
                 ;; video plays from the transcript like one an agent
                 ;; read, which read_file itself returns.
                 ("file" (or (harness-chat--show-media b)
                             (harness-chat--file-button (plist-get b :path) (plist-get b :name) (plist-get b :size))))
                 (_ "")))
             blocks ""))

(defalias 'harness-chat--format-value #'harness-ui-format-value
  "Alias of `harness-ui-format-value'.")

(defalias 'harness-chat--option-label #'harness-ui-option-label
  "Alias of `harness-ui-option-label'.")

(defalias 'harness-chat--summary-value #'harness-ui-summary-value
  "Alias of `harness-ui-summary-value'.")

(defalias 'harness-chat--input-summary #'harness-ui-tool-input-summary
  "Alias of `harness-ui-tool-input-summary'.")

(defun harness-chat--objects-p (value)
  "Non-nil when VALUE is a list holding objects (plists), such as todos."
  (and (consp value) (not (keywordp (car value)))
       (cl-some (lambda (item) (and (consp item) (keywordp (car item)))) value)))

(defun harness-chat--format-objects (value)
  "Return VALUE, a list of objects (plists), one key per line, like YAML.
`- ' starts each item; a value of several lines, such as the diagram of
an ask_user option, goes under its key, indented."
  (mapconcat
   (lambda (item)
     (if (not (and (consp item) (keywordp (car item))))
         (concat "- " (harness-chat--format-value item) "\n")
       (let ((lead "- "))
         (cl-loop for (k v) on item by #'cddr
                  concat (let ((text (harness-chat--format-value v))
                               (key (substring (symbol-name k) 1)))
                           (prog1 (if (string-search "\n" text)
                                      (concat lead key ":\n"
                                              (mapconcat (lambda (line) (concat "    " line "\n"))
                                                         (split-string (string-trim-right text "\n+") "\n")
                                                         ""))
                                    (concat lead key ": " text "\n"))
                             (setq lead "  ")))))))
   value ""))

(defun harness-chat--input-listing (input)
  "Return tool INPUT pretty printed, one key per line."
  (let (out)
    (cl-loop for (k v) on input by #'cddr
             do (let ((text (if (harness-chat--objects-p v)
                                (harness-chat--format-objects v)
                              (harness-chat--format-value v)))
                      (key (substring (symbol-name k) 1)))
                  (push (if (string-search "\n" text)
                            (concat (propertize (concat key ":") 'face 'harness-dim-face) "\n"
                                    (propertize (harness-chat--ensure-newline text) 'face 'harness-ui-output-face
                                                'line-prefix "    " 'wrap-prefix "    "))
                          (concat (propertize (concat key ": ") 'face 'harness-dim-face) text "\n"))
                        out)))
    (apply #'concat (nreverse out))))

;;;; Rendering: blocks

(defun harness-chat--sender (text face)
  "Return a sender line naming TEXT in FACE."
  (concat (propertize text 'face face) "\n"))

(defun harness-chat--session-name (id &optional name)
  "Return the name of session ID to show: its name now, else NAME, else a short id."
  (let ((name (or (plist-get (and id (harness-ui-session id)) :name) name))
        (id (or id "?")))
    (if (and (stringp name) (not (string-blank-p name)))
        name
      (substring id 0 (min 8 (length id))))))

(defun harness-chat--from-line (from)
  "Return the sender line of a message FROM sent, rather than the user.
The harness reads \"System · SOURCE\", another session's agent
\"Session · NAME\", NAME a button that opens that session."
  (pcase-let ((`(,label . ,which)
               (pcase (harness-sender-kind from)
                 ('session
                  (let* ((id (plist-get from :id))
                         (name (harness-chat--session-name id (plist-get from :name))))
                    (cons harness-chat-session-label
                          (if id
                              (harness-chat--button name (lambda () (harness-open-session id))
                                                    :face 'harness-dim-face
                                                    :help (format "Open the session %s" name))
                            (propertize name 'face 'harness-dim-face)))))
                 (_ (let ((source (plist-get from :source)))
                      (cons harness-chat-system-label
                            (and (stringp source) (not (string-blank-p source))
                                 (propertize source 'face 'harness-dim-face))))))))
    (concat (propertize label 'face 'harness-system-label-face)
            (if which (concat (propertize " · " 'face 'harness-dim-face) which) "")
            "\n")))

(defun harness-chat--render-user (block)
  "Return the body of user BLOCK.
A message the user did not write names who sent it instead of the user
and sits on the system background (see `harness-node-sender')."
  (let* ((node (harness-chat-block-node block))
         (from (harness-node-sender node))
         (face (if from 'harness-system-face 'harness-user-face))
         (text (harness-chat--plain (plist-get node :content)))
         (body (concat (if from
                           (harness-chat--from-line from)
                         (harness-chat--sender harness-chat-user-label 'harness-user-label-face))
                       (if (string-blank-p text) "" text)
                       (harness-chat--blocks-string (plist-get node :blocks)))))
    (harness-chat--margin (harness-chat--face body face) face
                          (if from 'harness-system-bar-face 'harness-user-bar-face))))

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

(defun harness-chat--status (level word help)
  "Return a tool call's status: the icon of LEVEL, then WORD in its face.
LEVEL is a level of `harness-ui-level-icon'; WORD is nil for the icon
alone.  HELP is the tooltip."
  (propertize (concat (harness-ui-level-icon level)
                      (if word (concat " " (propertize word 'face (harness-ui-level-face level))) ""))
              'help-echo help))

(defun harness-chat--outcome-status (outcome &optional count)
  "Return the status text of a tool call that ended with OUTCOME.
OUTCOME is `failed', the call ran and reported an error (a red
triangle), or `denied', the permission system refused it, so it never
ran (a yellow circle).  With COUNT, say how many calls ended so, as a
group summary does."
  (harness-chat--status (harness-ui-tool-level outcome)
                        (format "%s%s" (if count (format "%d " count) "") outcome)
                        (if (eq outcome 'denied) "The permission system refused this call, so it never ran"
                          "The tool ran and reported an error")))

(defun harness-chat--tool-status (result)
  "Return the status string for a tool call with RESULT (a node or nil).
A green circle when it ran, a yellow one while it runs or when it was
refused, a red triangle when it ran and failed."
  (let ((outcome (harness-ui-tool-outcome result)))
    (cond ((and (null result) (member (plist-get (harness-chat--session) :status) '("running" "blocked")))
           (harness-chat--status 'caution "running" "The call has not finished yet"))
          ((null result) (propertize "– no result" 'face 'harness-dim-face))
          ((memq outcome '(failed denied)) (harness-chat--outcome-status outcome))
          (t (harness-chat--status 'success nil "The tool ran and reported no error")))))

(defun harness-chat--render-tool (block)
  "Return the body of tool-call BLOCK (its result rendered with it)."
  (let* ((id (harness-chat-block-id block))
         (node (harness-chat-block-node block))
         (call-only (equal (harness-chat--str (plist-get node :kind)) "tool-call"))
         (result (if call-only (harness-chat-block-result block) node))
         (title (if call-only
                    (harness-ui-tool-title (plist-get node :tool) (plist-get node :title))
                  "result of an earlier tool call"))
         (input (and call-only (plist-get node :input)))
         (output (or (plist-get result :output) ""))
         (outcome (harness-ui-tool-outcome result))
         (bg (pcase outcome
               ('denied 'harness-tool-denied-face)
               ('failed 'harness-tool-error-face)
               (_ 'harness-tool-face)))
         (indent (propertize "  " 'face bg))
         (limit harness-chat--tool-output-limit)
         (long (and (not (harness-chat-block-show-all block)) (> (length output) limit)))
         (shown (if long (substring output 0 limit) output))
         (header (concat (harness-chat--fold-button (harness-chat-block-collapsed block)
                                                    (lambda () (interactive) (harness-chat-toggle-block id)))
                         " " (harness-ui-icon 'harness-icon-tool) " "
                         (if call-only
                             (harness-ui-tool-title-string (plist-get node :tool) (plist-get node :title) 120)
                           (propertize title 'face 'harness-tool-title-face))
                         "  " (harness-chat--tool-status result) "\n"))
         (line (and input (harness-chat--input-summary input title)))
         (summary (if line (concat (propertize (concat "  " line) 'face 'harness-dim-face) "\n") ""))
         ;; What the user is shown of the result -- an image, a video
         ;; poster, an audio player -- stays above the fold: a folded
         ;; tool call still shows the picture it read.
         (media (and result (mapconcat #'harness-chat--attachment-string
                                       (plist-get result :attachments) "")))
         (details
          (concat
           (if input (concat (propertize "  input\n" 'face 'harness-label-face)
                             (propertize (harness-chat--input-listing input) 'line-prefix indent 'wrap-prefix indent))
             "")
           (cond
            ((null result) "")
            ((string-empty-p output) (propertize "  (no output)\n" 'face 'harness-dim-face))
            ;; A refused call never ran: its text is the permission
            ;; system's reason, not output.
            (t (concat (propertize (if (eq outcome 'denied)
                                       "  reason\n"
                                     (format "  output (%s chars)\n" (harness-format-tokens (length output))))
                                   'face 'harness-label-face)
                       (propertize (harness-chat--ensure-newline shown) 'face 'harness-ui-output-face
                                   'line-prefix indent 'wrap-prefix indent)
                       (if long
                           (concat "  " (harness-chat--button
                                         (format "show all (%d more chars)" (- (length output) limit))
                                         (lambda () (harness-chat--show-all id)))
                                   "\n")
                         "")))))))
    (harness-chat--margin
     (harness-chat--face (concat header summary media (harness-chat--foldable details)) bg)
     bg)))

(defun harness-chat--rerender-media (id)
  "Redraw every chat block whose rendering shows the media ID, if any.
Return non-nil when a chat buffer showed it.  Each block is redrawn
whole, so its fold overlay follows the new rendering; editing the media
in place would leave the fold covering the picture or the player.  Every
block showing it is redrawn: the same video may appear in a tool result
and in the message that attached it."
  (let (handled)
    (dolist (buf (buffer-list))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (when (and harness-chat--blocks (not harness-chat--loading))
            (let (nodes m)
              (save-excursion
                (goto-char (point-min))
                (while (setq m (text-property-search-forward 'harness-ui-media-id id t))
                  (when-let* ((node (get-text-property (prop-match-beginning m) 'harness-chat-node)))
                    (cl-pushnew node nodes :test #'equal))))
              (when nodes
                (setq handled t)
                (dolist (node nodes)
                  (when-let* ((block (gethash node harness-chat--blocks)))
                    (harness-chat--rerender block)))))))))
    handled))

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

(defun harness-chat--render-failed (block err)
  "Return the body of BLOCK, whose renderer signalled ERR, as plain text.
A block that cannot be rendered must not take the rest of the buffer
down with it: the transcript below it and the compose box still draw."
  (let ((node (harness-chat-block-node block)))
    (harness-chat--margin
     (concat (harness-chat--plain (or (harness-chat-block-content block)
                                      (plist-get node :content) (plist-get node :title)
                                      (format "[%s]" (harness-chat-block-kind block))))
             (propertize (format "(shown unformatted: rendering failed with %s)\n" (error-message-string err))
                         'face 'harness-dim-face)))))

(defun harness-chat--group-outcomes (group)
  "Return the status text counting GROUP's failed and denied tool calls.
Empty when none failed or was denied; a collapsed group would hide them."
  (let ((failed 0) (denied 0))
    (dolist (nid (harness-chat-group-members group))
      (let ((b (gethash nid harness-chat--blocks)))
        (pcase (and b (harness-ui-tool-outcome (harness-chat-block-result b)))
          ('failed (cl-incf failed))
          ('denied (cl-incf denied)))))
    (concat (if (> failed 0) (concat "  " (harness-chat--outcome-status 'failed failed)) "")
            (if (> denied 0) (concat "  " (harness-chat--outcome-status 'denied denied)) ""))))

(defun harness-chat--render-group (group)
  "Return the body of the summary block of GROUP."
  (let* ((gid (harness-chat-group-id group))
         (names (mapcar (lambda (nid)
                          (let ((b (gethash nid harness-chat--blocks)))
                            (harness-ui-tool-label (plist-get (harness-chat-block-node b) :tool))))
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
             (harness-chat--group-outcomes group)
             "  "
             (harness-chat--button (if (harness-chat-group-expanded group) "[collapse]" "[expand]")
                                   (lambda () (harness-chat-toggle-group gid))
                                   :help "Show or hide the individual tool calls")
             "\n")))))

(defun harness-chat--render-block (block)
  "Return the full text of BLOCK: its body, then the separator newline."
  (let* ((kind (harness-chat-block-kind block))
         (body (harness-chat--with-display
                (condition-case err
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
                                                   (format "[%s]" kind))))))
                  (error (harness-chat--render-failed block err)))))
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
  "Replace the fold icon between START and END with the COLLAPSED state's icon.
The new icon keeps the old one's properties (its button, faces and
margin) but not its `display': an image icon is a space whose `display'
draws it, so carrying that over would keep drawing the old image."
  (when-let* ((pos (text-property-any start end 'harness-chat-fold-icon t)))
    (let* ((next (or (text-property-not-all pos end 'harness-chat-fold-icon t) end))
           (props (harness-ui--plist-without (text-properties-at pos) 'display))
           (icon (harness-chat--with-display
                   (harness-ui-icon (if collapsed 'harness-icon-collapsed 'harness-icon-expanded))))
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
  "Re-render BLOCK after `harness-chat--render-interval' unless already scheduled."
  (let ((id (harness-chat-block-id block))
        (buf (current-buffer)))
    (unless (gethash id harness-chat--render-timers)
      (puthash id (run-at-time harness-chat--render-interval nil
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

(defun harness-chat--block-shows-media-p (block)
  "Non-nil when BLOCK's result carries an image or a video to show.
Such a block is never folded into a coalesced group: the group would
hide the picture the read brought."
  (and (harness-chat-block-p block)
       (cl-some #'harness-chat--attachment-shows-media-p
                (plist-get (harness-chat-block-result block) :attachments))))

(defun harness-chat--coalescable-block-p (id)
  "Non-nil when block ID is a tool call of a coalescable tool.
A block whose result shows media is not coalescable."
  (when-let* ((b (gethash id harness-chat--blocks)))
    (and (equal (harness-chat-block-kind b) "tool-call")
         (not (harness-chat--block-shows-media-p b))
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
    ;; Hide "\n<members>" rather than "<members>\n": a hidden stretch that
    ;; starts on the first member's fold icon still draws that icon's
    ;; `display' image, at the start of the next visible block's line.
    ;; FRONT-ADVANCE keeps a re-rendered summary out of the overlay and
    ;; REAR-ADVANCE keeps a re-rendered last member in it.
    (let ((ov (make-overlay (1- (harness-chat-block-start first)) (1- (harness-chat-block-end last)) nil t t)))
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

(defun harness-chat--refresh-group-of (block)
  "Render again the summary of the group BLOCK is folded into, if any.
The summary counts the group's failed and denied calls, so a result
arriving for one of them changes it."
  (when-let* ((gid (harness-chat-block-group block))
              (group (gethash gid harness-chat--groups)))
    (harness-chat--update-group-summary group)))

(defun harness-chat--extend-group (group id)
  "Add block ID to GROUP, which ends right before it."
  (let ((block (gethash id harness-chat--blocks))
        (ov (harness-chat-group-overlay group)))
    (setf (harness-chat-group-members group) (append (harness-chat-group-members group) (list id)))
    (setf (harness-chat-block-group block) (harness-chat-group-id group))
    (move-overlay ov (overlay-start ov) (1- (marker-position (harness-chat-block-end block))))
    (harness-chat--update-group-summary group)))

(defun harness-chat--maybe-coalesce (id)
  "Fold block ID into a run of coalescable tool calls when there is one.
A block whose result shows media is not folded, and one that was
folded before its result arrived is taken out of its group again, so
the picture stays visible."
  (let ((block (gethash id harness-chat--blocks)))
    (cond
     ((harness-chat--block-shows-media-p block) (harness-chat--uncoalesce block))
     ((and (harness-chat--coalescable-block-p id) (not (harness-chat-block-group block)))
      (let* ((previous (cadr harness-chat--order))
             (prev-block (and previous (gethash previous harness-chat--blocks)))
             (gid (and prev-block (harness-chat-block-group prev-block))))
        (if gid
            (harness-chat--extend-group (gethash gid harness-chat--groups) id)
          (let ((run (list id)) (rest (cdr harness-chat--order)))
            (while (and rest (harness-chat--coalescable-block-p (car rest)))
              (push (car rest) run)
              (setq rest (cdr rest)))
            (when (>= (length run) harness-chat--coalesce-threshold)
              (harness-chat--make-group run)))))))))

(defun harness-chat--remove-group (group)
  "Remove GROUP: its summary block, its overlay and its membership."
  (delete-overlay (harness-chat-group-overlay group))
  (let ((inhibit-read-only t) (buffer-undo-list t))
    (delete-region (harness-chat-group-start group) (harness-chat-group-end group)))
  (dolist (m (harness-chat-group-members group))
    (when-let* ((b (gethash m harness-chat--blocks)))
      (setf (harness-chat-block-group b) nil)
      (when (harness-chat-block-head b) (harness-chat--rerender b))))
  (remhash (harness-chat-group-id group) harness-chat--groups))

(defun harness-chat--uncoalesce (block)
  "Take BLOCK out of the group it is folded into, splitting the group.
The runs before and after it are grouped anew, keeping the expanded
state the group had."
  (when-let* ((gid (harness-chat-block-group block))
              (group (gethash gid harness-chat--groups)))
    (let ((expanded (harness-chat-group-expanded group)))
      (harness-chat--remove-group group)
      (harness-chat--regroup)
      (when expanded
        (maphash (lambda (_ g)
                   (setf (harness-chat-group-expanded g) t)
                   (overlay-put (harness-chat-group-overlay g) 'invisible nil))
                 harness-chat--groups)))))

(defun harness-chat--clear-groups ()
  "Remove every group: summary blocks and overlays."
  (dolist (g (let (gs) (maphash (lambda (_ g) (push g gs)) harness-chat--groups) gs))
    (harness-chat--remove-group g))
  (clrhash harness-chat--groups))

(defun harness-chat--regroup ()
  "Recompute every coalesced run over the rendered transcript."
  (harness-chat--clear-groups)
  (let ((run nil))
    (cl-flet ((flush () (when (>= (length run) harness-chat--coalesce-threshold)
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
      (if (and harness-chat--loading
               ;; Activity is not transcript: it is current however it loads.
               (not (equal (plist-get update :sessionUpdate) "_harness/activity")))
          (push update harness-chat--deferred)
        (harness-chat--apply-update update)))))

(defun harness-chat--apply-update (update)
  "Apply one session UPDATE to the current buffer."
  (pcase (plist-get update :sessionUpdate)
    ("_harness/node" (harness-chat--on-node (plist-get update :node)))
    ("agent_message_chunk" (harness-chat--on-chunk update "assistant"))
    ("agent_thought_chunk" (harness-chat--on-chunk update "thinking"))
    ("_harness/activity" (harness-chat--on-activity (plist-get update :activity)))
    ("plan" (harness-chat--on-plan update))
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
      (harness-chat--rerender call)
      ;; A result that brings a picture must not stay hidden in a group.
      (harness-chat--maybe-coalesce (harness-chat-block-id call))
      (harness-chat--refresh-group-of call))
     ;; An update of a result already merged into its call block.
     ((and block (not (equal (harness-chat-block-id block) id)))
      (setf (harness-chat-block-result block) node)
      (harness-chat--rerender block)
      (harness-chat--maybe-coalesce (harness-chat-block-id block))
      (harness-chat--refresh-group-of block))
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
           (setq harness-chat--turn-start nil
                 ;; The turn is over, even if the news of it was lost.
                 harness-chat--activity nil)
           ;; A cancelled turn leaves calls without results: stop calling them running.
           (dolist (id harness-chat--unfinished)
             (when-let* ((b (gethash id harness-chat--blocks))) (harness-chat--rerender b)))
           (setq harness-chat--unfinished nil)))
    ;; The pending module owns the requests; it calls back to redraw the tail
    ;; when they change (see `harness-chat--on-pending-changed').
    (harness-ui-pending-sync (plist-get session :id) (plist-get session :pending))
    ;; Entering or leaving `inactive' shows or hides the notice above the box.
    (unless (eq (equal status "inactive") harness-chat--inactive)
      (setq harness-chat--inactive (equal status "inactive") changed t))
    (unless (equal (plist-get session :queue) harness-chat--queue)
      (setq harness-chat--queue (plist-get session :queue) changed t))
    (when (harness-chat--set-todos (plist-get session :todos))
      (setq changed t))
    (if changed
        (harness-chat--render-tail)
      (harness-chat--refresh-activity))
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
;;
;; The requests themselves -- the permission prompts and questions a
;; session waits on, their panels, answering them and the popout that
;; shows them on their own -- live in the pending module.  The chat
;; mirrors them for the session it draws and keeps the names its own
;; keys, menu and tests know.

(defun harness-chat--on-permission (params respond)
  "Own permission request PARAMS, with RESPOND (see the pending module)."
  (harness-ui-pending--on-permission params respond))

(defun harness-chat--on-question (params respond)
  "Own question PARAMS, with RESPOND (see the pending module)."
  (harness-ui-pending--on-question params respond))

(defun harness-chat--active-question ()
  "Return the newest pending question record of this session, if any."
  (harness-ui-pending-question harness-ui-session-id))

(defun harness-chat--answer-question (pid answer)
  "Answer question PID of this session with ANSWER."
  (harness-ui-pending-answer-question harness-ui-session-id pid answer))

(defun harness-chat--answer-permission (pid option)
  "Answer permission PID of this session with OPTION."
  (harness-ui-pending-answer-permission harness-ui-session-id pid option))

(defun harness-chat--permission-buttons (r)
  "Return the (LABEL KEY OPTION) buttons for permission record R."
  (harness-ui-pending-permission-buttons r))

(defun harness-chat-allow-newest ()
  "Allow the newest pending permission request once."
  (interactive)
  (harness-ui-pending-allow-newest))

(defun harness-chat-deny-newest ()
  "Deny the newest pending permission request once."
  (interactive)
  (harness-ui-pending-deny-newest))

(defun harness-chat-next-diagram (&optional n)
  "Show the diagram of the next option of the question waiting with diagrams."
  (interactive "p")
  (harness-ui-pending-next-diagram n))

(defun harness-chat-previous-diagram (&optional n)
  "Show the diagram of the previous option of the question waiting with diagrams."
  (interactive "p")
  (harness-ui-pending-previous-diagram n))

(defun harness-chat--on-pending-changed (sid)
  "Mirror SESSION-ID's requests and redraw the tail showing them.
On `harness-ui-pending-changed-hook'."
  (when-let* ((buf (harness-chat--buffer-for sid)))
    (with-current-buffer buf
      (setq harness-chat--pending (harness-ui-pending-items sid))
      (harness-chat--render-tail)
      (harness-chat--start-spinner))))

(defun harness-chat--drawn-p (sid)
  "Non-nil when a chat buffer draws session SID.
The pending module owns an ACP request only when some buffer draws it."
  (and (harness-chat--buffer-for sid) t))

(defvaralias 'harness-chat-panel-map 'harness-ui-pending-permission-map)
(defvaralias 'harness-chat-question-map 'harness-ui-pending-question-map)
(defvaralias 'harness-chat-diagram-question-map 'harness-ui-pending-diagram-map)

;;;; The tail: panel, queue, attachments, compose

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


;;;; The todo list

;; The agent replaces the session's plan with every `todo_write' call;
;; the harness emits `session/todos' for it, and ACP announces the same
;; list as a plan update.  The chat renders it from that data, never by
;; reading a tool block (those fold, and at work the list is the point):
;; a header segment with the progress and the item in hand, always on
;; screen, and a panel above the compose box with one line and a status
;; icon per item, which folds away or disappears with the list.

(defconst harness-chat--todos-limit 20
  "Most todo items the panel lists before it counts the rest.")

(defun harness-chat--todo-status (value)
  "Return VALUE as one of \"pending\", \"in-progress\" or \"done\".
Both the tool's spelling (`done', `in-progress') and ACP's
\(\"completed\", \"in_progress\") are understood."
  (let ((s (downcase (format "%s" (or value "pending")))))
    (cond ((member s '("done" "completed" "complete")) "done")
          ((member s '("in-progress" "in_progress" "in progress" "active" "doing")) "in-progress")
          (t "pending"))))

(defun harness-chat--todo-text (item)
  "Return the text of todo ITEM, a plist or a plain string."
  (if (stringp item)
      item
    (or (plist-get item :text) (plist-get item :content) "")))

(defun harness-chat--normalise-todos (todos)
  "Return TODOS as the one shape the chat renders: a list of (:text :status).
TODOS is the session's wire list (`session/get', `_harness/session') or
the entries of an ACP plan update; both spell their statuses their own
way, and an entry without an id is as good as one with."
  (mapcar (lambda (item)
            (list :text (harness-chat--todo-text item)
                  :status (harness-chat--todo-status (and (consp item) (plist-get item :status)))))
          todos))

(defun harness-chat--todo-summary ()
  "Return (DONE TOTAL CURRENT) for the session's todo list, or nil.
CURRENT is the item in progress, else the first one not done, as the
header names it."
  (when harness-chat--todos
    (let* ((status (lambda (item) (plist-get item :status)))
           (current (or (cl-find "in-progress" harness-chat--todos :key status :test #'equal)
                        (cl-find-if (lambda (item) (not (equal "done" (plist-get item :status))))
                                    harness-chat--todos))))
      (list (cl-count "done" harness-chat--todos :key status :test #'equal)
            (length harness-chat--todos)
            (and current (plist-get current :text))))))

(defun harness-chat--set-todos (todos)
  "Record TODOS (wire shape) as the session's list.
Return non-nil when the rendered list changed.  Comparing texts and
statuses alone, an ACP plan update and the session plist that follows
it redraw once, not twice."
  (let ((todos (harness-chat--normalise-todos todos)))
    (unless (equal todos harness-chat--todos)
      (setq harness-chat--todos todos)
      t)))

(defun harness-chat--on-plan (update)
  "Take the todo list carried by an ACP plan UPDATE.
This is the live signal of a `todo_write' call, ahead of the debounced
session plist that repeats it."
  (when (harness-chat--set-todos (plist-get update :entries))
    (harness-chat--render-tail)
    (force-mode-line-update)))

(defun harness-chat--todo-mark (status)
  "Return (ICON . FACE) marking a todo in STATUS."
  (pcase status
    ("done" '(harness-icon-success . harness-success-face))
    ("in-progress" '(harness-icon-running . harness-status-running-face))
    (_ '(harness-icon-idle . harness-dim-face))))

(defun harness-chat--todos-help ()
  "Return the tooltip of the header's todo segment: every item, marked."
  (let ((summary (harness-chat--todo-summary)))
    (concat (format "Todo list (%d/%d) — mouse-1, C-c C-t: show or hide it"
                    (nth 0 summary) (nth 1 summary))
            "\n"
            (mapconcat (lambda (item)
                         (format "%s %s"
                                 (pcase (plist-get item :status)
                                   ("done" "[x]") ("in-progress" "[~]") (_ "[ ]"))
                                 (harness-chat--todo-text item)))
                       harness-chat--todos "\n"))))

(defun harness-chat--todos-segment ()
  "Return the header segment for the session's todo list, or nil.
It names the progress and the item in hand, so a running turn's plan
is on screen without opening its `todo_write' block."
  (when-let* ((summary (harness-chat--todo-summary)))
    (let* ((done (nth 0 summary))
           (total (nth 1 summary))
           (current (nth 2 summary))
           (text (concat (harness-ui-icon 'harness-chat-icon-plan)
                         (format " %d/%d" done total)
                         (cond (current (concat " \N{U+00B7} " (harness-first-line current 34)))
                               ((= done total) " done")
                               (t "")))))
      (concat (harness-chat--segment text #'harness-chat-toggle-todos
                                     (harness-chat--todos-help)
                                     (and (= done total) 'harness-dim-face))
              "  "))))

(defun harness-chat--insert-todos ()
  "Insert the panel listing the session's todo items.
A fold button leads its title; every item follows with a status icon,
the one in progress in bold and the rest dim.  A list longer than
`harness-chat--todos-limit' counts the rest instead of showing them."
  (when harness-chat--todos
    (let* ((summary (harness-chat--todo-summary))
           (done (nth 0 summary))
           (total (nth 1 summary))
           (shown (seq-take harness-chat--todos harness-chat--todos-limit))
           (fold (harness-chat--fold-button harness-chat--todos-collapsed
                                            #'harness-chat-toggle-todos
                                            "mouse-1, TAB: show or hide the todo list"))
           (start (point)))
      (add-text-properties 0 (length fold) '(harness-chat-todos t) fold)
      (insert fold
              " "
              (propertize (concat (harness-ui-icon 'harness-chat-icon-plan)
                                  (format " Todo list  %d/%d" done total))
                          'face 'harness-label-face
                          'harness-chat-todos t)
              (if harness-chat--todos-collapsed
                  (concat "  " (propertize (or (nth 2 summary) "") 'face 'harness-dim-face))
                "")
              "\n")
      (unless harness-chat--todos-collapsed
        (dolist (item shown)
          (let* ((status (plist-get item :status))
                 (mark (harness-chat--todo-mark status)))
            (insert "   "
                    (propertize (harness-ui-icon (car mark)) 'face (cdr mark))
                    " "
                    (propertize (harness-first-line (plist-get item :text) 100)
                                'face (if (equal status "in-progress") 'bold 'harness-dim-face)
                                'wrap-prefix "   ")
                    "\n")))
        (when (> total (length shown))
          (insert "   "
                  (propertize (format "… %d more" (- total (length shown))) 'face 'harness-dim-face)
                  "\n")))
      (add-face-text-property start (point) 'harness-chat-plan-face t))))

(defun harness-chat-toggle-todos ()
  "Show or hide the session's todo list above the compose box."
  (interactive)
  (unless harness-chat--todos (user-error "This session has no todo list"))
  (setq harness-chat--todos-collapsed (not harness-chat--todos-collapsed))
  (harness-chat--render-tail)
  (force-mode-line-update))

(defvar harness-chat-panel-functions nil
  "Functions putting a panel of their own below the transcript.
Each is called without arguments in the chat buffer on every render of
the tail and returns a string, or nil for nothing.  The strings go
between the queue and the attachments, in order, read-only and above
the compose box.  Add to it buffer-locally, with a symbol, so a reload
redefines it.  The task module shows its review banner this way.")

(defun harness-chat--insert-panels ()
  "Insert what `harness-chat-panel-functions' return, in order.
Each string gets the panel background, which its own properties may
override, as the pending panel's do."
  (run-hook-wrapped 'harness-chat-panel-functions
                    (lambda (fn)
                      (when-let* ((text (funcall fn)))
                        (unless (string-empty-p text)
                          (insert (harness-chat--face text 'harness-chat-panel-face))))
                      nil)))


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
        (harness-ui-pending-insert-panels harness-ui-session-id)
        (harness-chat--insert-queue)

        (harness-chat--insert-todos)
        (harness-chat--insert-panels)

        (harness-compose-insert-attachments)
        (when harness-chat--dead
          (insert (propertize " This session was deleted; the transcript stays readable.\n" 'face 'harness-hint-face)))
        (when (and harness-chat--inactive (not harness-chat--dead))
          (insert (propertize " This session is inactive. Sending a message resumes it.\n" 'face 'harness-hint-face)))
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
             (set-window-start (car w) (cdr w) t))))
    ;; The new tail went in where the activity line was: put it back above.
    (harness-chat--refresh-activity)))

(defvar-local harness-chat-placeholder nil
  "What the empty compose box says when nothing more pressing does.
nil keeps the usual \"Message\" hint.  A deleted session, a question
waiting for its answer and an inactive session have hints of their
own.  The BTW module says what a side conversation is for with it.")

(defun harness-chat--placeholder ()
  "Return the hint for the empty compose box."
  (cond (harness-chat--dead "session deleted")
        ((harness-chat--active-question) "type an answer and press C-c C-c")
        (harness-chat--inactive "Message\N{U+2026} (sending resumes this session)")
        ((stringp harness-chat-placeholder) harness-chat-placeholder)
        (t "Message…")))

;;;; Bottom anchoring

;;;; Top region and history

(defun harness-chat--render-top ()
  "Render the region above the first block (its separator newline stays)."
  (let ((text (cond (harness-chat--loading (propertize " loading…" 'face 'harness-dim-face))
                    (harness-chat--has-more (propertize " loading earlier messages…" 'face 'harness-dim-face))
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
  (unwind-protect
      (let ((harness-chat--batch t))
        (dolist (node nodes)
          (harness-chat--on-node node))
        (harness-chat--regroup))
    ;; Whatever happened above, the buffer keeps its panel and compose box.
    (harness-chat--render-top)
    (harness-chat--render-tail)))

(defun harness-chat--oldest-id ()
  "Return the id of the oldest rendered node."
  (car (last harness-chat--order)))

(defun harness-chat--schedule-history (&rest _)
  "Run `harness-chat--manage-history' shortly, once however often scrolled."
  (unless harness-chat--history-timer
    (let ((buf (current-buffer)))
      (setq harness-chat--history-timer
            (run-at-time 0.05 nil (lambda ()
                                    (when (buffer-live-p buf)
                                      (with-current-buffer buf
                                        (setq harness-chat--history-timer nil)
                                        (harness-chat--manage-history)))))))))

(defun harness-chat--near-top-p (window)
  "Non-nil when WINDOW starts less than a screen below the transcript top."
  (save-excursion
    (goto-char (window-start window))
    (forward-line (- (window-body-height window)))
    (<= (point) harness-chat--transcript-start)))

(defun harness-chat--manage-history ()
  "Load older history near the top of a window; drop it far above every window."
  (let ((windows (harness-chat--windows)))
    (unless (or harness-chat--loading harness-chat--fetching (null harness-chat--order) (null windows))
      (if (and harness-chat--has-more (cl-some #'harness-chat--near-top-p windows))
          (harness-chat--load-earlier)
        (harness-chat--drop-earlier (apply #'min (mapcar #'window-start windows)))))))

(defun harness-chat--load-earlier ()
  "Fetch the previous page of history and render it above the transcript."
  (let ((buf (current-buffer))
        (before (harness-chat--oldest-id))
        (gen harness-chat--generation))
    (setq harness-chat--fetching t)
    (harness-ui-call "_harness/session/nodes"
                     (list :id harness-ui-session-id :opts (list :limit harness-chat--history-page :before before))
                     (lambda (nodes)
                       (when (buffer-live-p buf)
                         (with-current-buffer buf
                           (setq harness-chat--fetching nil)
                           (when (and (= gen harness-chat--generation) (equal before (harness-chat--oldest-id)))
                             (harness-chat--prepend-keeping-view nodes)
                             (setq harness-chat--has-more (>= (length nodes) harness-chat--history-page))
                             (harness-chat--render-top)
                             ;; A page shorter than the window leaves it near the top still.
                             (harness-chat--schedule-history)))))
                     (lambda (_err)
                       (when (buffer-live-p buf)
                         (with-current-buffer buf (setq harness-chat--fetching nil)))))))

(defun harness-chat--prepend-keeping-view (nodes)
  "Render NODES above the transcript without moving what the windows show.
A window starting above the first block would otherwise show the new
page from its top, and land near the top again."
  (let* ((first (gethash (harness-chat--oldest-id) harness-chat--blocks))
         (windows (cl-remove-if-not (lambda (w) (< (window-start w) (harness-chat-block-start first)))
                                    (harness-chat--windows)))
         (bottom (harness-chat--bottom-windows)))
    (harness-chat--prepend-nodes nodes)
    (let ((start (marker-position (harness-chat-block-start first))))
      (dolist (w windows)
        (if (memq w bottom)
            (harness-chat--pin w)
          (when (< (window-point w) start)
            (set-window-point w start)
            (when (eq w (selected-window)) (goto-char start)))
          (set-window-start w start t))))))

(defun harness-chat--drop-earlier (top)
  "Drop the oldest blocks once two pages of them end above TOP, keeping one page."
  (let* ((oldest (reverse harness-chat--order))
         (above (cl-loop for id in oldest
                         while (<= (harness-chat-block-end (gethash id harness-chat--blocks)) top)
                         count t))
         (drop (min (- above harness-chat--history-page)
                    (- (length oldest) harness-chat--history-limit))))
    (when (and (>= above (* 2 harness-chat--history-page)) (> drop 0))
      (let ((victims (seq-take oldest drop))
            (keep (gethash (nth drop oldest) harness-chat--blocks)))
        (harness-chat--clear-groups)
        (let ((inhibit-read-only t) (buffer-undo-list t))
          (delete-region harness-chat--transcript-start (harness-chat-block-start keep)))
        (dolist (id victims)
          (let ((b (gethash id harness-chat--blocks)))
            (harness-chat--cancel-render id)
            (when (harness-chat-block-fold b) (delete-overlay (harness-chat-block-fold b)))
            (when-let* ((r (harness-chat-block-result b))) (remhash (plist-get r :id) harness-chat--blocks))
            (when-let* ((call (and (equal (harness-chat-block-kind b) "tool-call")
                                   (plist-get (harness-chat-block-node b) :call-id))))
              (remhash call harness-chat--calls))
            (setq harness-chat--unfinished (delete id harness-chat--unfinished))
            (remhash id harness-chat--blocks)
            (set-marker (harness-chat-block-start b) nil)
            (set-marker (harness-chat-block-end b) nil)))
        (setq harness-chat--order (butlast harness-chat--order drop)
              harness-chat--has-more t)
        ;; The new first block opens a turn, as it would at open.
        (let ((head (harness-chat--head-p (harness-chat-block-kind keep) nil)))
          (unless (eq (not head) (not (harness-chat-block-head keep)))
            (setf (harness-chat-block-head keep) head)
            (harness-chat--rerender keep)))
        (harness-chat--regroup)
        (harness-chat--render-top)))))

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
    (harness-chat--fetch-activity)
    (harness-then
     ;; Every tool, not just the session's: its transcript may hold calls
     ;; of tools it no longer has, and they too go by their labels.
     (harness-all (list (harness-ui-fetch-tools)
                        (harness-ui-request "_harness/session/nodes"
                                            (list :id sid :opts (list :limit harness-chat--history-limit)))))
     (lambda (results)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (when (= gen harness-chat--generation)
             (setq harness-chat--coalescable
                   (let (names)
                     (maphash (lambda (name spec)
                                (when (harness-json-true-p (plist-get spec :coalescable)) (push name names)))
                              (car results))
                     names))
             (let ((nodes (cadr results))
                   (anchors (harness-chat--window-anchors))
                   (offset (and (harness-compose-in-p) (- (point) harness-compose-start))))
               (setq harness-chat--has-more (>= (length nodes) harness-chat--history-limit)
                     harness-chat--loading nil)
               (harness-chat--render-nodes nodes)
               (when offset
                 (goto-char (min (+ harness-compose-start offset) harness-compose-end)))
               (harness-chat--restore-anchors anchors)
               (dolist (u (nreverse harness-chat--deferred))
                 (pcase (plist-get u :sessionUpdate)
                   ;; The list is state, not transcript: the newest wins.
                   ("plan" (harness-chat--apply-update u))
                   ("_harness/node"
                    (when (harness-chat--node-current-p (plist-get u :node))
                      (harness-chat--apply-update u)))))
               (setq harness-chat--deferred nil)
               (when keep-bottom (harness-chat-scroll-to-bottom))
               (harness-chat--schedule-history))))))
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

(defun harness-chat--reopen-all ()
  "Open again the closed sessions that chat buffers show.
Run after connecting: a harness that just started (`harness-restart', a
crash) has every session closed, but one on screen here is open, as
`harness-open-session' made it."
  (maphash (lambda (id buf)
             (when (buffer-live-p buf)
               (harness-ui-call "_harness/session/get" (list :id id)
                                (lambda (session)
                                  (when (equal (format "%s" (plist-get session :status)) "inactive")
                                    (harness-ui-call "_harness/session/resume" (list :id id) #'ignore #'ignore)))
                                #'ignore)))
           harness-chat--buffers))

;;;; Sending

(defvar-local harness-chat-send-function nil
  "When non-nil, where `harness-chat-send' gives the compose box instead.
A function of TEXT and ATTACHMENTS, called in the chat buffer with what
the box held, after it is emptied.  It sends them wherever they belong
instead of prompting the session, for a module showing something of its
own in the buffer (see `harness-chat-panel-functions').  An answer to a
waiting question still goes to the question, and C-c C-q queues and
C-c C-k cancels as usual.")

(defvar harness-chat-send-functions nil
  "Functions run with the TEXT and ATTACHMENTS of each message sent.
`harness-chat-send' and `harness-chat-queue' run them in the chat
buffer as a message from its compose box goes out: TEXT as typed,
before skill references are expanded, ATTACHMENTS as the box held
them.  An answer to a question is not a message.  A function that
signals stops neither the message nor the other functions.  The BTW
module names a side conversation after its first message this way.")

(defun harness-chat--run-send-functions (text atts)
  "Run `harness-chat-send-functions' with TEXT and ATTS, demoting errors."
  (run-hook-wrapped 'harness-chat-send-functions
                    (lambda (fn text atts)
                      (with-demoted-errors "harness-chat-send-functions: %S"
                        (funcall fn text atts))
                      nil)
                    text atts))

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
While the agent is running the message steers the current turn.
A module showing something of its own in this buffer
\(`harness-chat-send-function') gets the box instead of the session."
  (interactive)
  (let ((question (harness-chat--active-question))
        (typed (string-trim (harness-compose-text))))
    (cond
     ((and question (not (string-empty-p typed)))
      (harness-chat--answer-question (plist-get question :id) typed)
      (harness-chat--clear-compose))
     ;; A module whose panel owns the box takes its text.
     (harness-chat-send-function
      (let ((send harness-chat-send-function))
        (pcase-let ((`(,text . ,atts) (harness-chat--take-message)))
          (harness-chat--clear-compose)
          (funcall send text atts))))
     (t
      (pcase-let ((`(,text . ,atts) (harness-chat--take-message))
                  (buf (current-buffer))
                  (sid harness-ui-session-id))
        (harness-chat--drop-edited-queue-item)
        (harness-chat--clear-compose)

        (if harness-chat-send-function
            (funcall harness-chat-send-function text atts)
          (harness-chat--run-send-functions text atts)
          (harness-compose-with-expanded-text
           text
           (lambda (expanded)
             (let ((blocks (append (and (not (string-empty-p expanded)) (list (list :type "text" :text expanded)))
                                   (mapcar #'harness-compose-attachment-block atts))))
               (harness-ui-call "session/prompt" (list :sessionId sid :prompt blocks)
                                #'ignore
                                (lambda (err) (harness-chat--report-error buf "send" err)))))))))))


(defun harness-chat-queue ()
  "Queue the compose box for the next turn."
  (interactive)
  (pcase-let ((`(,text . ,atts) (harness-chat--take-message))
              (buf (current-buffer))
              (sid harness-ui-session-id))
    (harness-chat--drop-edited-queue-item)
    (harness-chat--clear-compose)
    (harness-chat--run-send-functions text atts)
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

;;;; The activity line
;;
;; While a turn runs, a line at the end of the transcript says what it
;; is doing and for how long.  Text alone cannot: the model may think
;; for minutes and stream nothing (the Claude CLI never sends thinking
;; text), write a long tool input, or wait on a slow tool.  The line is
;; an overlay string, so its spinner ticks without editing the buffer.
;; Its own background and a blank line under it keep it apart from the
;; compose box below.

(defun harness-chat--spinner-frame ()
  "Return the current frame of the running spinner."
  (aref harness-chat--spinner-frames (% harness-chat--spinner-index (length harness-chat--spinner-frames))))

(defun harness-chat--activity-text (activity)
  "Say what ACTIVITY (`agent/activity', wire shape) is, such as \"Thinking\".
The text ends in an ellipsis.  Without an activity, as from a harness
that does not report one, it is \"Working\"."
  (let* ((tool (plist-get activity :tool))
         (count (plist-get activity :count))
         (call (concat (if (or tool (plist-get activity :title))
                           (harness-ui-tool-title tool (plist-get activity :title))
                         "a tool")
                       (if (and (numberp count) (> count 1)) (format " and %d more" (1- count)) ""))))
    (concat
     (pcase (plist-get activity :phase)
       ("waiting" "Waiting for the model")
       ("thinking" "Thinking")
       ("writing" "Writing")
       ("compacting" "Compacting the conversation")
       ("tool-input" (concat "Preparing " (if tool (harness-ui-tool-label tool) "a tool call")))
       ("tool" (if (harness-json-true-p (plist-get activity :checking))
                   (concat "Checking permission for " call)
                 (concat "Running " call)))
       (_ "Working"))
     "\N{U+2026}")))

(defun harness-chat--activity-label (activity)
  "Return a word or two for ACTIVITY, for the mode line: \"thinking\", \"Bash\".
A tool goes by its label."
  (let ((tool (if (plist-get activity :tool) (harness-ui-tool-label (plist-get activity :tool)) "a call")))
    (pcase (plist-get activity :phase)
      ("tool-input" (concat "preparing " tool))
      ("tool" (if (harness-json-true-p (plist-get activity :checking)) (concat "checking " tool) tool))
      ((and (pred stringp) phase) phase)
      (_ "working"))))

(defun harness-chat--activity-details (activity)
  "Return what shows ACTIVITY progressing, as a list of strings.
The size of the tool input written so far, the latest line a tool reported."
  (delq nil (list (let ((chars (plist-get activity :chars)))
                    (and (numberp chars) (> chars 0) (format "%s chars" (harness-format-tokens chars))))
                  (let ((detail (plist-get activity :detail)))
                    (and (stringp detail) (not (string-blank-p detail)) detail)))))

(defun harness-chat--format-elapsed (seconds)
  "Format SECONDS as a running clock: 7s, 1m04s, 2h05m."
  (let ((s (max 0 (truncate seconds))))
    (cond ((< s 60) (format "%ds" s))
          ((< s 3600) (format "%dm%02ds" (/ s 60) (% s 60)))
          (t (format "%dh%02dm" (/ s 3600) (/ (% s 3600) 60))))))

(defun harness-chat--activity-line ()
  "Return the activity line due now, or nil unless the session runs.
A blocked session shows its panel instead.  The line wears
`harness-chat-activity-face' and a blank line follows it: both keep it
apart from what comes below, the compose box or the queue."
  (when (and (equal (plist-get (harness-chat--session) :status) "running")
             (not harness-chat--dead))
    (let* ((activity harness-chat--activity)
           (since (or (plist-get activity :since) harness-chat--turn-start))
           (elapsed (and (numberp since) (- (float-time) since)))
           (head (concat (harness-chat--activity-text activity)
                         (if (and elapsed (>= elapsed 1)) (concat " " (harness-chat--format-elapsed elapsed)) "")))
           (text (string-join (cons head (harness-chat--activity-details activity)) " \N{U+00B7} "))
           (w (car (harness-chat--windows)))
           ;; One screen line, so the box below never jumps.
           (room (max 12 (- (if w (window-body-width w) 80) 4)))
           (line (concat " " (propertize (harness-chat--spinner-frame) 'face 'harness-status-running-face) " "
                         (propertize (truncate-string-to-width text room nil nil "\N{U+2026}") 'face 'harness-dim-face)
                         "\n")))
      ;; Emacs draws an overlay string over the face of the text it
      ;; precedes: the box's prompt or the queue, whose background would
      ;; make the line look like their first.  Both lines are drawn over
      ;; `default' instead, extended: the space after the end of a line
      ;; takes only faces that extend, so the box's would fill it.
      (let ((ground '(:inherit default :extend t)))
        (add-face-text-property 0 (length line) 'harness-chat-activity-face t line)
        (add-face-text-property 0 (length line) ground t line)
        (concat line (propertize "\n" 'face ground))))))

(defun harness-chat--activity-overlay ()
  "Return the activity line's overlay, empty at the end of the transcript.
FRONT-ADVANCE and REAR-ADVANCE carry it past blocks appended there."
  (let ((pos (marker-position harness-chat--transcript-end))
        (ov harness-chat--activity-overlay))
    (if (and ov (overlay-buffer ov))
        (unless (and (= pos (overlay-start ov)) (= pos (overlay-end ov)))
          (move-overlay ov pos pos))
      (setq ov (make-overlay pos pos nil t t)
            harness-chat--activity-overlay ov)
      (overlay-put ov 'harness-chat-activity t))
    ov))

(defun harness-chat--show-activity (line)
  "Make LINE, or nothing when nil, the activity line.
A line appearing or going changes the height of the text above the
compose box: its padding is sized again and the windows that showed
the end keep showing it."
  (let* ((ov (harness-chat--activity-overlay))
         (old (overlay-get ov 'before-string)))
    (cond ((equal old line))
          ((eq (null old) (null line)) (overlay-put ov 'before-string line))
          (t (let ((bottom (harness-chat--bottom-windows)))
               (overlay-put ov 'before-string line)
               (dolist (w (harness-chat--windows)) (harness-compose-repad w))
               (dolist (w bottom) (harness-chat--pin w)))))))

(defun harness-chat--refresh-activity ()
  "Draw the activity line as things are now."
  (when (and harness-chat--transcript-end (marker-buffer harness-chat--transcript-end))
    (harness-chat--show-activity (harness-chat--activity-line))))

(defun harness-chat--on-activity (activity)
  "Note that the running turn now does ACTIVITY (nil once it ended)."
  (setq harness-chat--activity activity)
  (when (and activity (equal (plist-get (harness-chat--session) :status) "running"))
    (harness-chat--start-spinner))
  (harness-chat--refresh-activity)
  (force-mode-line-update))

(defun harness-chat--fetch-activity ()
  "Ask what the session's turn does now: the buffer may open while it runs.
Changes then arrive as `_harness/activity' updates."
  (let ((buf (current-buffer)))
    (harness-ui-call "_harness/agent/activity" (list :session-id harness-ui-session-id)
                     (lambda (activity)
                       (when (buffer-live-p buf)
                         (with-current-buffer buf (harness-chat--on-activity activity))))
                     #'ignore)))

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
HELP is the `help-echo': a string, or a function computing one on hover.
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

(defun harness-chat--menu-help (window _object _pos)
  "Return the tooltip of the [menu] button in WINDOW's header line.
It names the keys that open the menu there, following
`harness-ui-prefix-key' and the user's bindings: in a chat buffer `?'
types into the compose box.  A `help-echo' function, so the keymaps
are searched on hover, not on every redisplay of the header line."
  (with-current-buffer (if (window-live-p window) (window-buffer window) (current-buffer))
    (substitute-command-keys "The harness menu (\\[harness-menu])" t)))

(defun harness-chat-show-usage ()
  "Show the usage dashboard, with the plan's quota."
  (interactive)
  (if (fboundp 'harness-usage)
      (harness-usage)
    (user-error "The usage dashboard (module ui-usage) is not loaded")))

(defun harness-chat--spend-segment (session)
  "Return the header segment showing what SESSION cost and who pays for it.
Per-token billing shows the cost; a subscription shows its plan and
quota.  Clicking it opens the usage dashboard.  Its percentages are
escaped, or the header line would take \"23% \" for a %-construct."
  (let ((text (harness-ui-mode-line-escape (harness-ui-format-spend session t))))
    (add-text-properties 0 (length text)
                         (list 'mouse-face 'mode-line-highlight
                               'local-map (harness-chat--segment-map #'harness-chat-show-usage))
                         text)
    text))

(defun harness-chat--non-interactive-segment (session)
  "Return the header segment saying whether SESSION waits for the user.
It reads \"non-interactive\" or \"interactive\"; clicking it toggles."
  (let ((value (plist-get session :non-interactive)))
    (harness-chat--segment (harness-ui-non-interactive-label value)
                           #'harness-toggle-non-interactive
                           (concat (harness-ui-non-interactive-help value)
                                   (if (harness-json-true-p value)
                                       " (mouse-1: make it interactive)"
                                     " (mouse-1: make it non-interactive)"))
                           (if (harness-json-true-p value) 'harness-non-interactive-face 'harness-dim-face))))

(defun harness-chat--on-quota (_provider _quota)
  "Redraw the header lines, which show the plan's quota."
  (force-mode-line-update t))

(defvar harness-chat-header-functions nil
  "Functions putting segments in front of the chat header line.
Each is called without arguments in the chat buffer whenever the header
line is drawn, and returns a string, or nil for nothing.  The header
shows their strings first, in order, then the session's own segments:
status, name, model, permission mode, non-interactive and the rest.  Add to it
buffer-locally, so only that buffer's header changes, and with a
symbol, so a reload redefines it.  The BTW module marks a side
conversation and gives it its [close] and [keep] buttons this way.")

(defun harness-chat--header-prefix ()
  "Return what `harness-chat-header-functions' put in front of the header."
  (let ((segments nil))
    (run-hook-wrapped 'harness-chat-header-functions
                      (lambda (fn)
                        (when-let* ((segment (funcall fn)))
                          (push segment segments))
                        nil))
    (apply #'concat (nreverse segments))))

(defun harness-chat--header ()
  "Return the header line."
  (let* ((s (harness-chat--session))
         (status (or (plist-get s :status) "idle"))
         (running (equal status "running"))
         (name (or (plist-get s :name) "unnamed")))
    (concat
     (harness-chat--header-prefix)
     " "
     (if running
         (propertize (harness-chat--spinner-frame)
                     'face 'harness-status-running-face
                     'help-echo (harness-chat--activity-text harness-chat--activity))
       (propertize (harness-ui-status-icon status) 'help-echo status))
     " "
     (harness-chat--segment name #'harness-rename-session "Session name (mouse-1: rename)" 'bold)
     "  "
     (harness-chat--todos-segment)
     (harness-chat--segment (harness-ui-model-label (plist-get s :model)) #'harness-set-model
                            "Model (mouse-1: change)" 'harness-dim-face)
     "  "
     (harness-chat--segment (harness-ui-permission-mode-label (plist-get s :permission-mode))
                            #'harness-set-permission-mode
                            "Permission mode (mouse-1: change)")
     "  "
     (harness-chat--non-interactive-segment s)
     "  "
     (harness-chat--segment (harness-ui-thinking-label (plist-get s :thinking))
                            #'harness-set-thinking "Thinking level (mouse-1: change)" 'harness-dim-face)
     "  "
     (harness-ui-format-context s)
     "  "
     (harness-chat--spend-segment s)
     "  "
     (harness-chat--segment "[menu]" #'harness-menu #'harness-chat--menu-help 'harness-dim-face)
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
       "")
     (if (and harness-chat--activity (equal status "running"))
         (propertize (concat " \N{U+00B7} " (harness-chat--activity-label harness-chat--activity))
                     'face 'harness-dim-face
                     'help-echo (harness-chat--activity-text harness-chat--activity))
       ""))))

(defun harness-chat-reposition (position)
  "Show this session in POSITION instead."
  (interactive (list (harness-ui-read-position)))
  (harness-ui-display-session harness-ui-session-id position))

(defun harness-chat--spinner-tick ()
  "Advance the spinners and activity lines of the visible running sessions.
The timer runs while a session with a buffer runs, hidden ones included,
so a buffer shown again mid-turn ticks at once rather than after the
next change of its session; a blocked one, which may wait for hours,
keeps it only while it is visible."
  (let ((any nil))
    (cl-incf harness-chat--spinner-index)
    (maphash (lambda (_ buf)
               (when (buffer-live-p buf)
                 (with-current-buffer buf
                   (let ((status (plist-get (harness-chat--session) :status))
                         (visible (get-buffer-window buf 'visible)))
                     (when (or (equal status "running") (and visible (equal status "blocked")))
                       (setq any t))
                     (when (and visible (member status '("running" "blocked")))
                       (force-mode-line-update)
                       (harness-chat--refresh-activity))))))
             harness-chat--buffers)
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
        ((get-text-property (point) 'harness-chat-todos) (harness-chat-toggle-todos))
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
  "Open session ID in POSITION.
An inactive session opens as it is, compose box included; the first
message sent from it resumes it."
  (interactive (list (plist-get (harness-ui-read-session "Open session: ") :id)
                     (and current-prefix-arg (harness-ui-read-position))))
  (harness-ui-display-session id position))

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

(defvar harness-chat-mode-map (make-sparse-keymap)
  "Keymap of `harness-chat-mode'.")

;; Filled at top level, not in the `defvar', so a reload updates the map.
(let ((map harness-chat-mode-map))
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
  (define-key map (kbd "C-c C-f") #'harness-chat-next-diagram)
  (define-key map (kbd "C-c C-b") #'harness-chat-previous-diagram)
  (define-key map (kbd "C-c C-w") #'harness-chat-copy-last-response)
  (define-key map (kbd "C-c C-t") #'harness-chat-toggle-todos)
  (define-key map (kbd "C-c C-r") #'harness-chat-redraw)
  (define-key map (kbd "C-c C-e") #'harness-chat-scroll-to-bottom))

(define-derived-mode harness-chat-mode special-mode "Chat"
  "Major mode of a harness session buffer.
The transcript is read-only; the compose box at the bottom is editable.
Typing anywhere goes to the box, `?' included, so the harness menu is
on \\[harness-menu] here, or the [menu] button in the header line.

\\{harness-chat-mode-map}"
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
  (add-hook 'window-scroll-functions #'harness-chat--schedule-history nil t)
  (add-hook 'kill-buffer-hook #'harness-chat--on-kill nil t))

;; The chat's keys in the harness menu, as the buffer binds them.
(put 'harness-chat-mode 'harness-menu-group
     '("Chat"
       ["Message"
        ("C-c C-c" "Send" harness-chat-send)
        ("C-c C-q" "Queue for next turn" harness-chat-queue)
        ("C-c C-a" "Attach file" harness-compose-add-attachment)
        ("C-c C-v" "Attach clipboard" harness-compose-attach-clipboard)]
       ["Agent"
        ("C-c C-y" "Allow request" harness-chat-allow-newest)
        ("C-c C-n" "Deny request" harness-chat-deny-newest)
        ("C-c C-f" "Next diagram" harness-chat-next-diagram)
        ("C-c C-b" "Previous diagram" harness-chat-previous-diagram)
        ("C-c C-t" "Show or hide the todo list" harness-chat-toggle-todos)
        ("C-c C-k" "Cancel turn" harness-chat-cancel)]
       ["Transcript"
        (". TAB" "Fold block" harness-chat-tab)
        ("C-c C-s" "Search" harness-chat-search)
        ("C-c C-w" "Copy last reply" harness-chat-copy-last-response)
        ("C-c C-e" "Jump to bottom" harness-chat-scroll-to-bottom)
        ("C-c C-r" "Redraw" harness-chat-redraw)]))

(defun harness-chat--post-command ()
  "Keep the new-messages indicator current.
Point moved onto an option of a question with diagrams shows its diagram."
  (when (and harness-chat--unseen (harness-chat--at-bottom-p (selected-window)))
    (setq harness-chat--unseen nil)
    (force-mode-line-update))
  (with-demoted-errors "harness-chat: %S"
    (harness-ui-pending--follow-option)))

(defun harness-chat--on-kill ()
  "Forget the buffer and its timers."
  (harness-chat--cancel-all-renders)
  (when harness-chat--history-timer (cancel-timer harness-chat--history-timer))
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
  ;; Media the transcript shows redraws through its block, not in place.
  (add-hook 'harness-ui-media-rerender-functions #'harness-chat--rerender-media)
  (add-hook 'harness-ui-update-functions #'harness-chat--on-update)
  (add-hook 'harness-ui-event-functions #'harness-chat--on-event)
  (add-hook 'harness-ui-quota-functions #'harness-chat--on-quota)
  ;; The pending module owns the requests themselves (it registers with
  ;; `harness-ui-permission-functions' and `harness-ui-question-functions');
  ;; a chat buffer drawing them makes them its own, and this mirror redraws.
  (add-hook 'harness-ui-pending-drawn-predicates #'harness-chat--drawn-p)
  (add-hook 'harness-ui-pending-changed-hook #'harness-chat--on-pending-changed)
  (add-hook 'harness-ui-redraw-hook #'harness-chat--redraw-all)
  (add-hook 'harness-ui-connected-hook #'harness-chat--reopen-all)
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
