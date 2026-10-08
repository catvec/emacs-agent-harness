;;; harness-ui-chat.el --- The chat buffer  -*- lexical-binding: t; -*-

;;; Commentary:

;; One buffer per session, "*harness: NAME*", laid out top to bottom:
;;
;;   header line   status, name, todo progress, model, permission mode,
;;                 non-interactive or interactive, thinking, context,
;;                 output rate (tokens per second), cost, menu, after what
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
;; compaction summaries and runs of coalescable tools (with the thinking
;; between their calls) collapse under overlays that isearch opens, so
;; every word of the conversation stays searchable.  History loads lazily: the newest
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
(require 'harness-ui-drag)
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

(defconst harness-chat--render-spacing 5
  "How many times its last re-render's time a streaming block waits for the next.
When that is longer than `harness-chat--render-interval', it is the
wait: re-rendering a long message as it streams in then takes a sixth
of Emacs's time at most.")

(defconst harness-chat--coalesce-threshold 3
  "Coalescable tool calls a run needs to fold into one summary block.
Thinking between the calls does not break the run and is not counted.")

(defconst harness-chat--image-max-height 400
  "Maximum pixel height of inline images.")

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
  "A run of coalesced tool calls folded under one summary.
MEMBERS are the ids of its blocks, oldest first: the calls and the
thinking between them."
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
(defvar-local harness-chat--render-cost 0
  "Seconds the buffer's last re-render of a streaming block took.")
(defvar-local harness-chat--stale nil
  "Ids of streaming blocks left unrendered while no window showed the buffer.
Rendered once one does (`harness-chat--catch-up').")
(defvar-local harness-chat--redraw-pending nil
  "Non-nil when the buffer is to be rebuilt once a window shows it.
`harness-chat--redraw-all' leaves a hidden buffer so.")
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

(defun harness-chat--button (label action &rest props)
  "Return a button string LABEL running ACTION (a function of no arguments).
PROPS may hold `:help' and `:face'."
  (let ((s (copy-sequence label)))
    (add-text-properties
     0 (length s)
     (list 'face (or (plist-get props :face) 'button)
           'mouse-face 'highlight 'follow-link t 'pointer 'hand
           'help-echo (plist-get props :help)
           'harness-chat-action action
           'keymap (harness-chat--mouse-map #'harness-chat-push))
     s)
    s))

(defun harness-chat-push (&optional event)
  "Run the action of the button at point, or at the position of mouse EVENT.
Knows the chat's own `harness-chat-action' buttons and the shared
`harness-ui-action' ones the pending module draws."
  (interactive (list last-input-event))
  (when (mouse-event-p event) (mouse-set-point event))
  (let ((action (or (get-text-property (point) 'harness-chat-action)
                    (get-text-property (point) 'harness-ui-action)
                    (and (> (point) (point-min))
                         (or (get-text-property (1- (point)) 'harness-chat-action)
                             (get-text-property (1- (point)) 'harness-ui-action))))))
    (if action (funcall action) (push-button (point)))))

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

;;;; Scrolling by pixels
;;
;; An image is one character whose `display' draws it, so however tall
;; it is it makes one line, and Emacs scrolls by lines: the mouse wheel
;; and C-v jumped past a tall image whole, or stuck on one taller than
;; the window.  The chat scrolls by pixels instead, through the window's
;; vscroll as `pixel-scroll-precision-mode' does, a line's height for
;; every line asked for: the wheel (`mwheel-scroll' calls
;; `mwheel-scroll-up-function' and `mwheel-scroll-down-function' with a
;; number of lines) and C-v and M-v, which the mode remaps.  An image
;; goes by a line's height at a time like the text around it, and stays
;; whole: nothing about it is measured or changed when it is drawn.  The
;; window still starts at a whole line of text; only an image is left
;; partly scrolled at the top, or, when one taller than the window shows
;; from its top, the line above it scrolled out of view.

(defvar mwheel-scroll-up-function)
(defvar mwheel-scroll-down-function)

;; Where screen lines start and how high they are, in the selected window.
(defun harness-chat--line-start (pos)
  "Return where the screen line at POS starts."
  (save-excursion (goto-char pos) (vertical-motion 0) (point)))

(defun harness-chat--line-after (pos)
  "Return where the screen line after the one at POS starts, or nil at the end."
  (save-excursion
    (goto-char pos)
    (and (= (vertical-motion 1) 1) (> (point) pos) (point))))

(defun harness-chat--line-before (pos)
  "Return where the screen line before the one at POS starts, or nil at the top."
  (save-excursion
    (goto-char pos)
    (and (= (vertical-motion -1) -1) (< (point) pos) (point))))

(defun harness-chat--line-height (pos)
  "Return the height in pixels of the screen line at POS."
  (save-excursion (goto-char pos) (line-pixel-height)))

(defun harness-chat--scroll-pixels (pixels forward)
  "Scroll the selected window PIXELS pixels, FORWARD toward the end or back.
The window's start goes a screen line at a time and its vscroll takes
up the rest, so a line of any height goes by a pixel at a time.  Back,
it stops at the buffer's start; forward, with the last line of text at
the top, as `scroll-up' does.  Each line's height is its own, from
`line-pixel-height': `pixel-scroll-precision-scroll-up-page' measures
back with `window-text-pixel-size', which can overshoot a tall line
to start the window at the line above it."
  (let ((start (window-start))
        (vscroll (window-vscroll nil t)))
    (while (> pixels 0)
      (if forward
          (let ((next (harness-chat--line-after start)))
            (if (not (and next (< next (point-max))))
                (setq pixels 0)
              (let ((left (- (harness-chat--line-height start) vscroll)))
                (if (< pixels left)
                    (setq vscroll (+ vscroll pixels) pixels 0)
                  (setq start next vscroll 0 pixels (- pixels (max left 0)))))))
        (if (> vscroll 0)
            (let ((step (min pixels vscroll)))
              (setq vscroll (- vscroll step) pixels (- pixels step)))
          (let ((before (harness-chat--line-before start)))
            (if before
                (setq start before vscroll (harness-chat--line-height before))
              (setq pixels 0))))))
    ;; Forced, the start holds whatever redisplay finds; an unforced one
    ;; it may give up to recenter on point.  But forcing it loses the
    ;; vscroll at redisplay, so scrolled partway into a line the start
    ;; holds only while point's line shows whole above the window's
    ;; bottom edge (`harness-chat--point-into-view').
    (set-window-start nil start (> vscroll 0))
    (set-window-vscroll nil vscroll t t)))

(defun harness-chat--snap-start (forward)
  "Start the selected window at a whole screen line unless its first is tall.
Scrolling by pixels can stop partway into a line of text, which would
then show cut through at the top.  A line at least two lines of text
high, an image, keeps the part scrolled; any other goes back to its top,
or FORWARD on to the next line when more than half of it was scrolled."
  (let ((vscroll (window-vscroll nil t)))
    (when (> vscroll 0)
      (let* ((start (window-start))
             ;; The whole line: `window-text-pixel-size' from the window's
             ;; start counts only what the vscroll leaves of it, which near
             ;; an image's bottom is as little as a line of text.
             (height (harness-chat--line-height start)))
        (when (< height (* 2 (default-line-height)))
          (let ((next (and forward (> (* 2 vscroll) height)
                           (harness-chat--line-after start))))
            (set-window-vscroll nil 0 t t)
            ;; Nothing is scrolled partway now, so the start is forced,
            ;; as `harness-chat--scroll-pixels' forces it.
            (set-window-start nil (or next start))
            (when (and next (< (point) next)) (goto-char next))))))))

(defun harness-chat--shown-whole-p (pos)
  "Return non-nil if the selected window shows the screen line at POS whole.
Scrolled into a tall line, the line has to end above the window's
bottom edge, not on it.  The window's start is not forced then, which
would lose the vscroll, and redisplay keeps a start it was not forced
to only while point's line ends above that edge; else it recenters on
point and keeps the vscroll, which cuts through the text at the top."
  (let ((shown (pos-visible-in-window-p pos nil t)))
    (and shown (null (cddr shown))
         (or (zerop (window-vscroll nil t))
             (< (+ (cadr shown) (harness-chat--line-height pos))
                (+ (window-tab-line-height) (window-header-line-height)
                   (window-text-height nil t)))))))

(defun harness-chat--bottom-line ()
  "Return a position on the selected window's bottom screen line, or nil."
  (posn-point (posn-at-x-y 0 (+ (window-tab-line-height) (window-header-line-height)
                                (1- (window-text-height nil t))))))

(defun harness-chat--point-into-view ()
  "Move point onto a screen line the selected window shows whole.
Point left out of view, or partly out, would have redisplay recenter
the window to show it, undoing the scroll.  Point below goes up to the
last line shown whole, as `scroll-down' moves it, and point above to
the first: a window scrolled into a tall line shows that line in part,
and point stays on it only when no line shows whole (see
`harness-chat--cursor-line-fully-visible')."
  (let ((start (window-start)))
    (unless (and (>= (point) start) (harness-chat--shown-whole-p (point)))
      (let ((pos (if (< (point) start)
                     start
                   (let ((bottom (harness-chat--bottom-line)))
                     (harness-chat--line-start
                      (if (and bottom (> (point) bottom)) bottom (point)))))))
        (while (and (> pos start) (not (harness-chat--shown-whole-p pos)))
          (setq pos (or (harness-chat--line-before pos) start)))
        (setq pos (max pos start))
        (unless (harness-chat--shown-whole-p pos)
          (let ((after (harness-chat--line-after pos)))
            (when (and after (harness-chat--shown-whole-p after))
              (setq pos after))))
        (goto-char pos)))))

(defun harness-chat--hold-tall-start ()
  "Keep a line taller than the selected window at its top, point on it.
That line fills the window, so point can be on no other, and redisplay
keeps point on a line that runs past the window's bottom only while the
window's start is forced, which lasts one redisplay.  The next, after
any change, would recenter on point and undo the scroll.  It leaves a
window with a vscroll alone, so the window starts at the line before
instead, scrolled out of view by the vscroll.  The window looks the
same, and its start holds."
  (let ((start (window-start)))
    (when (and (= (point) start)
               (zerop (window-vscroll nil t))
               (> (harness-chat--line-height start) (window-text-height nil t)))
      (when-let* ((before (harness-chat--line-before start)))
        (set-window-start nil before t)
        (set-window-vscroll nil (harness-chat--line-height before) t t)))))

(defun harness-chat--scroll (lines forward)
  "Scroll the selected window LINES lines' height, FORWARD toward the end or back.
LINES nil is the window's height less `next-screen-context-lines'
lines, as `scroll-up' takes it, negative LINES go the other way, and
zero stays.  Signals `end-of-buffer' or `beginning-of-buffer' when
nothing moves, as `scroll-up' and `scroll-down' do: `mwheel-scroll'
scrolls on until one does.  A terminal, which draws no images, scrolls
by lines."
  (cond
   ((eql lines 0))
   ((not (display-graphic-p))
    (if forward (scroll-up lines) (scroll-down lines)))
   (t
    (let* ((line (default-line-height))
           (forward (if (and lines (< lines 0)) (not forward) forward))
           (pixels (if lines (* (abs lines) line)
                     (max line (- (window-text-height nil t) (* next-screen-context-lines line)))))
           (before (cons (window-start) (window-vscroll nil t))))
      (harness-chat--scroll-pixels pixels forward)
      (harness-chat--snap-start forward)
      ;; Started at the very end, the window would show nothing; like
      ;; `scroll-up', stop with the last line of text at its top.
      (when (and forward (> (point-max) (point-min)) (>= (window-start) (point-max)))
        (set-window-vscroll nil 0 t t)
        (set-window-start nil (harness-chat--line-start (1- (point-max)))))
      (harness-chat--point-into-view)
      (harness-chat--hold-tall-start)
      (when (equal before (cons (window-start) (window-vscroll nil t)))
        (signal (if forward 'end-of-buffer 'beginning-of-buffer) nil))))))

(defun harness-chat-scroll-forward (&optional lines)
  "Scroll the chat LINES lines' height toward its end, by pixels.
The wheel's `mwheel-scroll-up-function' in the chat; LINES nil is
nearly a window.  See `harness-chat--scroll'."
  (harness-chat--scroll lines t))

(defun harness-chat-scroll-back (&optional lines)
  "Scroll the chat LINES lines' height toward its start, by pixels.
The wheel's `mwheel-scroll-down-function' in the chat; LINES nil is
nearly a window.  See `harness-chat--scroll'."
  (harness-chat--scroll lines nil))

(defun harness-chat--scroll-command (arg forward)
  "Scroll nearly a window, or ARG lines' height, FORWARD or back.
As `scroll-up-command' takes ARG: `-' goes a window the other way.
Where nothing is left to scroll, point moves that way instead when
`scroll-error-top-bottom' says so, as that command moves it: ARG lines,
or to the end of the buffer; else the error is signaled."
  (let ((forward (if (eq arg '-) (not forward) forward))
        (lines (and arg (not (eq arg '-)) (prefix-numeric-value arg))))
    (condition-case err
        (harness-chat--scroll lines forward)
      ((beginning-of-buffer end-of-buffer)
       (let* ((ahead (eq (car err) 'end-of-buffer))
              (edge (if ahead (point-max) (point-min))))
         (cond
          ((or (not scroll-error-top-bottom) (= (point) edge))
           (signal (car err) (cdr err)))
          (lines (forward-line (if ahead (abs lines) (- (abs lines)))))
          (t (goto-char edge))))))))

(defun harness-chat-scroll-up (&optional arg)
  "Scroll the chat nearly a window toward its end, by pixels.
`scroll-up-command' in the chat: an image goes by a line's height at a
time instead of all at once.  With ARG, scroll ARG lines' height; `-'
scrolls back."
  (interactive "^P")
  (harness-chat--scroll-command arg t))

(defun harness-chat-scroll-down (&optional arg)
  "Scroll the chat nearly a window toward its start, by pixels.
`scroll-down-command' in the chat; with ARG, ARG lines' height; `-'
scrolls forward."
  (interactive "^P")
  (harness-chat--scroll-command arg nil))

(dolist (command '(harness-chat-scroll-up harness-chat-scroll-down))
  (put command 'scroll-command t)
  (put command 'isearch-scroll t))

(defun harness-chat--cursor-line-fully-visible (window)
  "The chat's `make-cursor-line-fully-visible', for WINDOW.
Point's line is brought into full view, as by default, unless WINDOW
is scrolled partway into a tall line: that would undo the scroll.
`pixel-scroll-precision-mode' turns the option off everywhere for this
\(bug#65214)."
  (zerop (window-vscroll window t)))

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

(defvar harness-chat--to-pin nil
  "Windows to pin to the end of their chat once a slice of messages is handled.
`harness-chat--pin-soon' collects them while `harness-acp-receiving'.")

(defun harness-chat--bottom-windows ()
  "Return the windows of this buffer that are at the bottom.
A window waiting to be pinned to the end is: the text that came since
may have pushed the end out of its sight, but not out of its pin's."
  (unless harness-chat--batch
    (cl-remove-if-not (lambda (w) (or (memq w harness-chat--to-pin) (harness-chat--at-bottom-p w)))
                      (harness-chat--windows))))

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

(defun harness-chat--pin-soon (window)
  "Pin WINDOW to the end of the buffer, once whatever is under way is done.
That is now, unless received messages are being handled: then the
window is pinned once at the end of their slice (see
`harness-acp-received-hook'), where a burst of streamed text would pin
it once per message, and nothing is drawn in between anyway."
  (if harness-acp-receiving
      (unless (memq window harness-chat--to-pin)
        (push window harness-chat--to-pin))
    (harness-chat--pin window)))

(defun harness-chat--pin-waiting ()
  "Pin the windows `harness-chat--pin-soon' left for the end of a slice.
On `harness-acp-received-hook'."
  (let ((windows (nreverse harness-chat--to-pin)))
    (setq harness-chat--to-pin nil)
    (dolist (w windows)
      (when (window-live-p w)
        (with-current-buffer (window-buffer w)
          (when (derived-mode-p 'harness-chat-mode)
            (harness-chat--pin w)))))))

(defun harness-chat--follow (windows)
  "Scroll WINDOWS to the end of the buffer; the others learn about new content."
  (unless harness-chat--batch
    (dolist (w (harness-chat--windows))
      (if (memq w windows)
          (progn
            (harness-chat--pin-soon w)
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
  "Bring this buffer up to date for WINDOW, which just started showing it.
The buffer is rebuilt when a redraw passed it by as it was hidden (see
`harness-chat--redraw-all'), else the blocks that streamed in meanwhile
are rendered.  Then WINDOW is pinned to the newest messages: without
this Emacs centres point (the compose box) on first display and the
next streamed chunk snaps it to the bottom."
  (when (and (window-live-p window) (eq (window-buffer window) (current-buffer)))
    (cond (harness-chat--redraw-pending
           (setq harness-chat--redraw-pending nil)
           ;; From a timer: this runs as Emacs redisplays, and a harness in
           ;; this Emacs answers the requests of a load right away.
           (let ((buf (current-buffer)))
             (harness-run-soon (lambda ()
                                 (when (buffer-live-p buf)
                                   (with-current-buffer buf (harness-chat--load t)))))))
          (harness-chat--stale (harness-chat--catch-up)))
    (when (and harness-chat--transcript-end
               (>= (window-point window) harness-chat--transcript-end))
      (harness-chat--pin window))))

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
(defun harness-chat--image-string (source &optional mime)
  "Return a string displaying SOURCE (a path or a (:data BASE64) plist).
MIME is a hint for the image type.  The image can be dragged into
another application as a file, one held in memory written to the
session's temporary directory first (`harness-ui-drag-props').
Without image support, and for a path on a remote host, which reading
here would block on, a button opening the file is returned instead."
  (let* ((path (and (stringp source) source))
         (data (and (consp source) (plist-get source :data)))
         (label (if path (format "[image %s]" (abbreviate-file-name path)) "[image]"))
         (local (and path (not (file-remote-p path))))
         (open (and path (lambda () (interactive) (find-file-other-window path))))
         (img (and (display-images-p) (or data (and local (file-readable-p path)))
                   (let* ((w (car (harness-chat--windows)))
                          (width (floor (* 0.6 (if w (window-body-width w t) 800)))))
                     (condition-case nil
                         (if data
                             (create-image (base64-decode-string data) nil t
                                           :max-width width :max-height harness-chat--image-max-height)
                           (create-image path nil nil
                                         :max-width width :max-height harness-chat--image-max-height))
                       (error nil))))))
    (cond
     (img (concat (apply #'propertize label 'display img
                         (harness-ui-drag-props
                          (list 'pointer 'hand
                                'help-echo (if open (format "mouse-1 or RET: open %s" path) mime)
                                'keymap (and open (harness-chat--mouse-map open)))
                          path))
                  "\n"))
     (open (concat (harness-chat--button label open :help (format "Open %s" path)) "\n"))
     (t (concat (propertize label 'face 'harness-dim-face) "\n")))))

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

(defun harness-chat--image-label (block)
  "Return the label of image BLOCK, image 1, or nil when it has none.
The compose box labels the images it attaches, and the message's text
names each by its token, [image 1]."
  (let ((label (and (equal (harness-chat--str (plist-get block :type)) "image") (plist-get block :label))))
    (and (stringp label) (not (string-empty-p label)) label)))

(defun harness-chat--mark-image-tokens (text blocks)
  "Return TEXT with the tokens of the labelled images among BLOCKS styled.
They look as they did in the compose box, and as the captions over the
images below the text (`harness-chat--blocks-string')."
  (let ((labels (delq nil (mapcar #'harness-chat--image-label blocks))))
    (if (null labels)
        text
      (let ((text (copy-sequence text)))
        (dolist (label labels text)
          (let ((token (format "[%s]" label)) (start 0))
            (while (setq start (string-search token text start))
              (add-face-text-property start (+ start (length token)) 'harness-compose-token-face nil text)
              (setq start (+ start (length token))))))))))

(defun harness-chat--blocks-string (blocks)
  "Return the non-text content BLOCKS of a node as a string.
An image with a label has its token, [image 1], over it, as the text
above names it."
  (mapconcat (lambda (b)
               (pcase (harness-chat--str (plist-get b :type))
                 ("image" (concat
                           (if-let* ((label (harness-chat--image-label b)))
                               (concat (propertize (format "[%s]" label) 'face 'harness-compose-token-face) "\n")
                             "")
                           (harness-chat--image-string (or (plist-get b :path) (list :data (plist-get b :data)))
                                                       (plist-get b :mime))))
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

(defun harness-chat--handoff-line (handoff)
  "Return the line under a note that HANDOFF carried a conversation over.
It names the models and, for a transcript, offers to open the file."
  (let ((file (plist-get handoff :file)))
    (concat (propertize (format "%s → %s"
                                (harness-ui-model-label (plist-get handoff :from))
                                (harness-ui-model-label (plist-get handoff :to)))
                        'face 'harness-dim-face)
            (if (and (stringp file) (not (string-empty-p file)))
                (concat "  "
                        (harness-chat--button "[open the transcript]"
                                              (lambda () (find-file-other-window file))
                                              :help (format "Open %s" file)))
              "")
            "\n")))

(defun harness-chat--render-user (block)
  "Return the body of user BLOCK.
A message the user did not write names who sent it instead of the user
and sits on the system background (see `harness-node-sender').  One
that handed the conversation over to a model of another provider (see
`harness-node-handoff') also names the two models and links the
transcript it points the new model at."
  (let* ((node (harness-chat-block-node block))
         (from (harness-node-sender node))
         (handoff (harness-node-handoff node))
         (face (if from 'harness-system-face 'harness-user-face))
         (text (harness-chat--mark-image-tokens (harness-chat--plain (plist-get node :content))
                                                (plist-get node :blocks)))
         (body (concat (if from
                           (harness-chat--from-line from)
                         (harness-chat--sender harness-chat-user-label 'harness-user-label-face))
                       (if (string-blank-p text) "" text)
                       (if handoff (harness-chat--handoff-line handoff) "")
                       (harness-chat--blocks-string (plist-get node :blocks)))))
    (harness-chat--margin (harness-chat--face body face) face
                          (if from 'harness-system-bar-face 'harness-user-bar-face))))

(defconst harness-chat--agent-kinds '("assistant" "thinking" "tool-call" "tool-result" "plan")
  "Block kinds the agent produces; a run of them is one agent turn.")

(defun harness-chat--head-p (kind previous)
  "Non-nil when a KIND block after a PREVIOUS-kind block starts an agent turn.
Pass the kinds `harness-chat--turn-kind' gives."
  (and (member kind harness-chat--agent-kinds)
       (not (member previous harness-chat--agent-kinds))))

(defun harness-chat--turn-kind (block)
  "Return the kind of BLOCK as far as agent turns go.
A tool call the harness recorded (`harness-outside-node-p'), such as
the merge queue's conflict resolver, is no part of an agent turn: it
reads \"outside\", which opens none, and the agent's block after it
opens one again."
  (and block
       (if (harness-outside-node-p (harness-chat-block-node block))
           "outside"
         (harness-chat-block-kind block))))

(defun harness-chat--outside-header (block)
  "Return the sender line of BLOCK when the harness recorded its call, or nil.
It names who did, as a message the user did not write does, where the
agent's header would stand."
  (let ((node (harness-chat-block-node block)))
    (and (harness-outside-node-p node)
         (harness-chat--margin (harness-chat--from-line (harness-node-sender node))))))

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

(defun harness-chat--tool-status (result &optional call)
  "Return the status string for a tool call with RESULT (a node or nil).
A green circle when it ran, a yellow one while it runs or when it was
refused, a red triangle when it ran and failed.  CALL is the call's
node: one the harness recorded (`harness-outside-node-p') runs whatever
the session does, until the harness records its result."
  (let ((outcome (harness-ui-tool-outcome result)))
    (cond ((and (null result) (or (harness-outside-node-p call)
                                  (member (plist-get (harness-chat--session) :status) '("running" "blocked"))))
           (harness-chat--status 'caution "running" "The call has not finished yet"))
          ((null result) (propertize "– no result" 'face 'harness-dim-face))
          ((memq outcome '(failed denied)) (harness-chat--outcome-status outcome))
          (t (harness-chat--status 'success nil "The tool ran and reported no error")))))

(defun harness-chat--child-line (call result)
  "Return the line linking the session a tool call started, or \"\".
That is the sub-agent of a spawn_agent call, the `:child-id' in the
`:meta' of CALL or of RESULT: the merge queue's call names its conflict
resolver from the start, a model's spawn_agent call once it returns."
  (let ((id (or (plist-get (plist-get call :meta) :child-id)
                (plist-get (plist-get result :meta) :child-id))))
    (if (and (stringp id) (not (string-empty-p id)))
        (let ((name (harness-chat--session-name id (plist-get (plist-get call :input) :name))))
          (concat (propertize "  session: " 'face 'harness-dim-face)
                  (harness-chat--button name (lambda () (harness-open-session id))
                                        :help (format "Open the session %s" name))
                  "\n"))
      "")))

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
                         "  " (harness-chat--tool-status result (and call-only node)) "\n"))
         (line (and input (harness-chat--input-summary input title)))
         (summary (concat (if line (concat (propertize (concat "  " line) 'face 'harness-dim-face) "\n") "")
                          (harness-chat--child-line node result)))
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
  "Return the body of compaction BLOCK.
A summary made to hand the conversation over to a model of another
provider says which (see `harness-node-handoff')."
  (let* ((id (harness-chat-block-id block))
         (node (harness-chat-block-node block))
         (content (or (plist-get node :content) ""))
         (handoff (harness-node-handoff node))
         (header (concat (harness-chat--fold-button (harness-chat-block-collapsed block)
                                                    (lambda () (interactive) (harness-chat-toggle-block id)))
                         " "
                         (propertize (format "%s context compacted%s (%d words)"
                                             (harness-ui-icon 'harness-chat-icon-compaction)
                                             (if handoff
                                                 (format " to hand over to %s"
                                                         (harness-ui-model-label (plist-get handoff :to)))
                                               "")
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

(defun harness-chat--group-calls (group)
  "Return the blocks of GROUP's tool calls, oldest first.
The thinking folded in between them is left out."
  (cl-loop for nid in (harness-chat-group-members group)
           for b = (gethash nid harness-chat--blocks)
           when (and b (equal (harness-chat-block-kind b) "tool-call")) collect b))

(defun harness-chat--group-outcomes (group)
  "Return the status text counting GROUP's failed and denied tool calls.
Empty when none failed or was denied; a collapsed group would hide them."
  (let ((failed 0) (denied 0))
    (dolist (b (harness-chat--group-calls group))
      (pcase (harness-ui-tool-outcome (harness-chat-block-result b))
        ('failed (cl-incf failed))
        ('denied (cl-incf denied))))
    (concat (if (> failed 0) (concat "  " (harness-chat--outcome-status 'failed failed)) "")
            (if (> denied 0) (concat "  " (harness-chat--outcome-status 'denied denied)) ""))))

(defun harness-chat--render-group (group)
  "Return the body of the summary block of GROUP.
It counts the calls by label, then the thinking folded between them."
  (let* ((gid (harness-chat-group-id group))
         (names (mapcar (lambda (b) (harness-ui-tool-label (plist-get (harness-chat-block-node b) :tool)))
                        (harness-chat--group-calls group)))
         (thoughts (cl-count-if #'harness-chat--thinking-block-p (harness-chat-group-members group)))
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
             (propertize (format "%s %d tool calls: %s%s" (harness-ui-icon 'harness-icon-tool) (length names)
                                 (mapconcat (lambda (c) (if (> (cdr c) 1) (format "%s ×%d" (car c) (cdr c)) (car c)))
                                            counts ", ")
                                 (pcase thoughts
                                   (0 "")
                                   (1 " · thinking")
                                   (n (format " · thinking ×%d" n))))
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
         (text (concat (cond ((harness-chat-block-group block) "")
                             ((harness-chat--outside-header block))
                             ((harness-chat-block-head block) (harness-chat--agent-header))
                             (t ""))
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
          (harness-chat--head-p (harness-chat--turn-kind block) (harness-chat--turn-kind previous)))
    (harness-chat--insert-block block (marker-position harness-chat--transcript-end))
    (set-marker harness-chat--transcript-end (marker-position (harness-chat-block-end block)))
    (push (harness-chat-block-id block) harness-chat--order)
    ;; The first block replaces the "No messages yet" notice.
    (when (and first (not harness-chat--batch) (not harness-chat--loading))
      (harness-chat--render-top))
    block))

(defun harness-chat--rerender (block)
  "Render BLOCK again in place."
  (when harness-chat--stale
    (setq harness-chat--stale (delete (harness-chat-block-id block) harness-chat--stale)))
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

(defun harness-chat--attach-result (call result)
  "Render RESULT, a tool-result node, in CALL, the block of its call.
The result's id then finds the call's block, whose call has finished."
  (setf (harness-chat-block-result call) result)
  (setq harness-chat--unfinished (delete (harness-chat-block-id call) harness-chat--unfinished))
  (puthash (plist-get result :id) call harness-chat--blocks)
  (harness-chat--rerender call))

(defun harness-chat--remove-block (block)
  "Delete BLOCK from the buffer and the transcript, keeping windows still.
The block after it opens an agent turn or not by the block now before
it.  BLOCK must not be folded into a group."
  (let* ((id (harness-chat-block-id block))
         (pos (cl-position id harness-chat--order :test #'equal))
         (newer (and pos (> pos 0) (gethash (nth (1- pos) harness-chat--order) harness-chat--blocks)))
         (older (and pos (gethash (nth (1+ pos) harness-chat--order) harness-chat--blocks))))
    (harness-chat--cancel-render id)
    (when (harness-chat-block-fold block) (delete-overlay (harness-chat-block-fold block)))
    (harness-chat--replace-region (harness-chat-block-start block) (harness-chat-block-end block) "")
    (set-marker (harness-chat-block-start block) nil)
    (set-marker (harness-chat-block-end block) nil)
    (remhash id harness-chat--blocks)
    (setq harness-chat--order (delete id harness-chat--order)
          harness-chat--unfinished (delete id harness-chat--unfinished))
    (when newer
      (let ((head (harness-chat--head-p (harness-chat--turn-kind newer) (harness-chat--turn-kind older))))
        (unless (eq (not head) (not (harness-chat-block-head newer)))
          (setf (harness-chat-block-head newer) head)
          (harness-chat--rerender newer))))))

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
  "Re-render BLOCK shortly, unless that is scheduled already.
Shortly is `harness-chat--render-interval' seconds, or a few times what
the buffer's last such re-render took when that is longer: a message
streaming in is rendered whole each time, and a long one must not keep
Emacs busy rendering it again and again.  While no window shows the
buffer the block keeps its text as it streamed in, and is rendered once
a window does (see `harness-chat--catch-up')."
  (let ((id (harness-chat-block-id block)))
    (unless (gethash id harness-chat--render-timers)
      (puthash id (run-at-time (max harness-chat--render-interval
                                    (* harness-chat--render-spacing harness-chat--render-cost))
                               nil #'harness-chat--render-due (current-buffer) id)
               harness-chat--render-timers))))

(defun harness-chat--render-due (buffer id)
  "Re-render block ID of chat BUFFER, whose streaming re-render is due."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (remhash id harness-chat--render-timers)
      (when-let* ((block (gethash id harness-chat--blocks)))
        (if (null (harness-chat--windows))
            (cl-pushnew id harness-chat--stale :test #'equal)
          (let ((start (float-time)))
            (harness-chat--rerender block)
            (setq harness-chat--render-cost (- (float-time) start))))))))

(defun harness-chat--catch-up ()
  "Render the streaming blocks left as their text came while the buffer was hidden."
  (let ((ids (reverse harness-chat--stale)))
    (setq harness-chat--stale nil)
    (dolist (id ids)
      (when-let* ((block (gethash id harness-chat--blocks)))
        (harness-chat--rerender block)))))

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

(defun harness-chat--waiting-calls ()
  "Return the call ids of the tool calls waiting on the user's answer."
  (delq nil (mapcar (lambda (r) (plist-get r :call-id)) harness-chat--pending)))

(defun harness-chat--waiting-p (block)
  "Non-nil when BLOCK is a tool call waiting on the user's answer.
Such a call is not folded into a coalesced group while it waits: the
session is blocked on it, and a group would hide it."
  (and (harness-chat-block-p block)
       (member (plist-get (harness-chat-block-node block) :call-id) (harness-chat--waiting-calls))))

(defun harness-chat--coalescable-block-p (id)
  "Non-nil when block ID is a tool call of a coalescable tool.
A block whose result shows media is not coalescable, nor a call waiting
on the user, nor one the harness recorded: it is no agent's."
  (when-let* ((b (gethash id harness-chat--blocks)))
    (and (equal (harness-chat-block-kind b) "tool-call")
         (not (harness-chat--block-shows-media-p b))
         (not (harness-chat--waiting-p b))
         (not (harness-outside-node-p (harness-chat-block-node b)))
         (member (plist-get (harness-chat-block-node b) :tool) harness-chat--coalescable))))

(defun harness-chat--thinking-block-p (id)
  "Non-nil when block ID is thinking.
Thinking between coalescable tool calls does not break their run: a
model that thinks before every call would otherwise never have one, so
it folds into their group with them."
  (when-let* ((b (gethash id harness-chat--blocks)))
    (equal (harness-chat-block-kind b) "thinking")))

(defun harness-chat--run-calls (ids)
  "Return how many of the blocks IDS are coalescable tool calls."
  (cl-count-if #'harness-chat--coalescable-block-p ids))

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

(defun harness-chat--extend-group (group ids)
  "Add the blocks IDS (oldest first) to GROUP, which ends right before them."
  (let ((last (gethash (car (last ids)) harness-chat--blocks))
        (ov (harness-chat-group-overlay group)))
    (setf (harness-chat-group-members group) (append (harness-chat-group-members group) ids))
    (dolist (id ids)
      (setf (harness-chat-block-group (gethash id harness-chat--blocks)) (harness-chat-group-id group)))
    (move-overlay ov (overlay-start ov) (1- (marker-position (harness-chat-block-end last))))
    (harness-chat--update-group-summary group)))

(defun harness-chat--maybe-coalesce (id)
  "Fold block ID into a run of coalescable tool calls when there is one.
Only the newest block joins a run, with the thinking since the call
before it: the transcript grows at its end, and a result arriving for
an older call must not pull it into a run (`harness-chat--regroup'
groups a whole transcript).  A block whose result shows media is not
folded, and one that was folded before its result arrived is taken
out of its group again, so the picture stays visible; so is a call
once it waits on the user, until it is answered."
  (let ((block (gethash id harness-chat--blocks)))
    (cond
     ((or (harness-chat--block-shows-media-p block) (harness-chat--waiting-p block))
      (harness-chat--uncoalesce block))
     ((and (equal id (car harness-chat--order))
           (harness-chat--coalescable-block-p id)
           (not (harness-chat-block-group block)))
      ;; Walk back over the run ID ends: coalescable calls and the
      ;; thinking between them, up to a group it continues.
      (let ((run (list id)) (rest (cdr harness-chat--order)) (gid nil))
        (while (and rest (not gid)
                    (or (harness-chat--coalescable-block-p (car rest))
                        (harness-chat--thinking-block-p (car rest))))
          (if-let* ((g (harness-chat-block-group (gethash (car rest) harness-chat--blocks))))
              (setq gid g)
            (push (car rest) run)
            (setq rest (cdr rest))))
        (if-let* ((group (and gid (gethash gid harness-chat--groups))))
            (harness-chat--extend-group group run)
          ;; Thinking before the run's first call stays out of it.
          (while (harness-chat--thinking-block-p (car run)) (pop run))
          (when (>= (harness-chat--run-calls run) harness-chat--coalesce-threshold)
            (harness-chat--make-group run))))))))

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
The runs before and after it are grouped anew; what the user opened
stays open (see `harness-chat--regroup-keeping-open')."
  (when-let* ((gid (harness-chat-block-group block)))
    (when (gethash gid harness-chat--groups)
      (harness-chat--regroup-keeping-open))))

(defun harness-chat--regroup-keeping-open ()
  "Group the transcript anew, keeping open the groups the user opened.
A new group with a block of a group that was expanded is expanded too,
and the others are folded, as `harness-chat--regroup' makes them."
  (let ((open nil))
    (maphash (lambda (_ g)
               (when (harness-chat-group-expanded g)
                 (setq open (append (harness-chat-group-members g) open))))
             harness-chat--groups)
    (harness-chat--regroup)
    (when open
      (maphash (lambda (gid g)
                 (when (cl-intersection (harness-chat-group-members g) open :test #'equal)
                   (harness-chat-toggle-group gid)))
               harness-chat--groups))))

(defun harness-chat--clear-groups ()
  "Remove every group: summary blocks and overlays."
  (dolist (g (let (gs) (maphash (lambda (_ g) (push g gs)) harness-chat--groups) gs))
    (harness-chat--remove-group g))
  (clrhash harness-chat--groups))

(defun harness-chat--regroup ()
  "Recompute every coalesced run over the rendered transcript.
A run is coalescable tool calls with nothing but thinking between them;
the thinking before its first call and after its last stays out."
  (harness-chat--clear-groups)
  (let ((run nil))                      ; Newest first.
    (cl-flet ((flush ()
                (while (and run (harness-chat--thinking-block-p (car run))) (pop run))
                (when (>= (harness-chat--run-calls run) harness-chat--coalesce-threshold)
                  (harness-chat--make-group (nreverse run)))
                (setq run nil)))
      (dolist (id (reverse harness-chat--order))
        (if (or (harness-chat--coalescable-block-p id)
                (and run (harness-chat--thinking-block-p id)))
            (push id run)
          (flush)))
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
               ;; Activity and the session record are not transcript: they
               ;; are current however it loads.  Held back, a change of
               ;; status, queue or pending requests that came while every
               ;; buffer reloads (a reload, a reconnect) would be lost.
               (not (member (plist-get update :sessionUpdate) '("_harness/activity" "_harness/session"))))
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
      (harness-chat--attach-result call node)
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
  "React to bus EVENT with ARGS.
A head moved by a checkout makes the transcript another path: the
buffer loads it again, so it shows the conversation the next message
continues, not the branch left behind."
  (when-let* ((buf (and (member event '("agent/turn-started" "agent/turn-ended" "session/head-moved"))
                        (harness-chat--buffer-for (car args)))))
    (with-current-buffer buf
      (pcase event
        ("agent/turn-started" (setq harness-chat--turn-start (float-time)) (harness-chat--start-spinner))
        ("agent/turn-ended" (setq harness-chat--turn-start nil))
        ("session/head-moved" (harness-chat--load t)))
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
  "Answer the permission request at point, else the newest, with Allow.
That is its panel's [Allow] (y); see `harness-ui-pending-answer-help'
for what it covers."
  (interactive)
  (harness-ui-pending-allow-newest))

(defun harness-chat-deny-newest ()
  "Answer the permission request at point, else the newest, with Deny.
That is its panel's [Deny] (n)."
  (interactive)
  (harness-ui-pending-deny-newest))

(defun harness-chat-edit-permission-pattern (&optional pid)
  "Edit the glob pattern the permission request PID is answered for.
PID defaults to the request at point, or else the newest one with a
pattern: one about a path outside the allowed directories.  The
pattern, and editing it, belong to the pending module, so a popout
edits the same request the same way."
  (interactive)
  (harness-ui-pending-edit-pattern pid))

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
      (let ((before (harness-chat--waiting-calls)))
        (setq harness-chat--pending (harness-ui-pending-items sid))
        ;; A call now waiting on the user leaves its group, and an
        ;; answered one folds into its run again.  Other calls of its step
        ;; may have come after it meanwhile, so the transcript is grouped
        ;; anew, as a fresh load groups it.
        (when (and harness-chat--calls
                   (cl-some (lambda (call)
                              (when-let* ((b (gethash (gethash call harness-chat--calls) harness-chat--blocks)))
                                (member (plist-get (harness-chat-block-node b) :tool) harness-chat--coalescable)))
                            (cl-set-exclusive-or before (harness-chat--waiting-calls) :test #'equal)))
          (harness-chat--regroup-keeping-open)))
      (harness-chat--render-tail)
      (harness-chat--start-spinner))))

(defun harness-chat--drawn-p (sid)
  "Non-nil when a chat buffer draws session SID.
The pending module owns an ACP request only when some buffer draws it."
  (and (harness-chat--buffer-for sid) t))

(defun harness-chat--add-pending (record)
  "Add or replace pending RECORD, stored by the pending module.
The store is the one source of truth; the chat's mirror follows it."
  (harness-ui-pending-add harness-ui-session-id record))

(defun harness-chat--remove-pending (id)
  "Forget the request ID of this session, in the shared store."
  (harness-ui-pending-remove harness-ui-session-id id))

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
        (harness-compose-insert nil (concat "C-c C-c sends, RET newline, C-c C-q queues, C-c C-k cancels, "
                                            "C-c C-a attaches, C-c > quotes"))))
    (cond (offset (goto-char (min (+ harness-compose-start offset) harness-compose-end)))
          (in-tail (goto-char harness-compose-end)))
    (dolist (w windows)
      (cond ((not (window-live-p (car w))))
            ;; A window following the conversation keeps showing the newest
            ;; lines, so a new panel or queue entry never lands off screen.
            ((memq (car w) bottom)
             (unless (eq (car w) (selected-window))
               (set-window-point (car w) harness-compose-end))
             (harness-chat--pin-soon (car w)))
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
        harness-chat--stale nil
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
  (let* ((shown (reverse harness-chat--order))
         (first (gethash (car shown) harness-chat--blocks))
         (windows (cl-remove-if-not (lambda (w) (< (window-start w) (harness-chat-block-start first)))
                                    (harness-chat--windows)))
         (bottom (harness-chat--bottom-windows)))
    (harness-chat--prepend-nodes nodes)
    ;; The first block, a result alone, may have joined its call on the
    ;; new page: the oldest block still its own takes its place.
    (when-let* ((kept (cl-loop for id in shown
                               for b = (gethash id harness-chat--blocks)
                               when (and b (equal (harness-chat-block-id b) id)) return b)))
      (let ((start (marker-position (harness-chat-block-start kept))))
        (dolist (w windows)
          (if (memq w bottom)
              (harness-chat--pin w)
            (when (< (window-point w) start)
              (set-window-point w start)
              (when (eq w (selected-window)) (goto-char start)))
            (set-window-start w start t)))))))

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
        (let ((head (harness-chat--head-p (harness-chat--turn-kind keep) nil)))
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
                (setf (harness-chat-block-head block) (harness-chat--head-p (harness-chat--turn-kind block) previous))
                (harness-chat--insert-block block pos)
                (setq pos (marker-position (harness-chat-block-end block))
                      previous (harness-chat--turn-kind block))
                (push (harness-chat-block-id block) ids))))
          (set-marker anchor pos)
          ;; The old first block may no longer open a turn.
          (let ((head (harness-chat--head-p (harness-chat--turn-kind first) previous)))
            (unless (eq (not head) (not (harness-chat-block-head first)))
              (setf (harness-chat-block-head first) head)
              (harness-chat--rerender first)))))
      (setq harness-chat--order (append harness-chat--order ids))
      (dolist (r (nreverse results))
        (when-let* ((call (gethash (gethash (plist-get r :call-id) harness-chat--calls) harness-chat--blocks)))
          (harness-chat--attach-result call r)))
      (harness-chat--adopt-orphans)
      (harness-chat--regroup))))

(defun harness-chat--adopt-orphans ()
  "Join each result shown on its own to its call, now rendered above it.
A page of history may start with the result of a call made on the page
before it.  Until that page is loaded the result shows alone, as the
result of an earlier tool call; then it joins its call, which would
otherwise say it has no result, and the two stop breaking the run of
calls around them.  Groups must be cleared first."
  (dolist (id (copy-sequence harness-chat--order))
    (let* ((orphan (gethash id harness-chat--blocks))
           (call (and orphan (equal (harness-chat-block-kind orphan) "tool-result")
                      (gethash (gethash (plist-get (harness-chat-block-node orphan) :call-id) harness-chat--calls)
                               harness-chat--blocks))))
      (when (and call (null (harness-chat-block-result call)))
        (harness-chat--remove-block orphan)
        (harness-chat--attach-result call (harness-chat-block-node orphan))))))

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
    (setq harness-chat--loading t harness-chat--deferred nil harness-chat--redraw-pending nil)
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
               (harness-chat--replay-deferred t)
               (when keep-bottom (harness-chat-scroll-to-bottom))
               (harness-chat--schedule-history))))))
     (lambda (err)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (when (= gen harness-chat--generation)
             (setq harness-chat--loading nil)
             ;; Not a failure when the UI connected elsewhere meanwhile:
             ;; it redraws every buffer once it has.
             (unless (harness-ui-connection-replaced-p err)
               (harness-chat--render-nodes nil)
               (harness-chat--append-local-block "error" (format "could not load the session: %s" (harness-error-message err)))
               (harness-chat--render-top))
             (harness-chat--replay-deferred nil))))))))

(defun harness-chat--replay-deferred (loaded)
  "Apply the updates held back while the transcript loaded, then forget them.
With LOADED non-nil the transcript was just rendered: node updates that
continue it are applied, the older ones are in it already, as is the
text streamed meanwhile.  The todo list and the session being deleted
are state, not transcript, so they apply either way; the session record
and activity were never held back (see `harness-chat--on-update')."
  (dolist (u (nreverse harness-chat--deferred))
    (pcase (plist-get u :sessionUpdate)
      ;; The list is state, not transcript: the newest wins.
      ("plan" (harness-chat--apply-update u))
      ("_harness/node"
       (when (and loaded (harness-chat--node-current-p (plist-get u :node)))
         (harness-chat--apply-update u)))
      ("_harness/session_deleted" (harness-chat--apply-update u))))
  (setq harness-chat--deferred nil))

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
  "Rebuild every chat buffer from scratch, keeping compose text and scroll state.
A buffer no window shows is rebuilt once one does: rebuilding fetches
and renders a transcript, and a UI may hold dozens of them.  It fetches
its session at once, though, as the session is what the buffer and the
pending module report on (`harness-chat--on-session')."
  (maphash (lambda (_ buf)
             (when (buffer-live-p buf)
               (with-current-buffer buf
                 (if (harness-chat--windows)
                     (harness-chat--load (harness-chat--at-bottom-p))
                   (setq harness-chat--redraw-pending t)
                   (harness-chat--fetch-session)))))
           harness-chat--buffers))

(defun harness-chat--showed-open-p (buffer)
  "Non-nil when chat BUFFER last showed its session open, not inactive.
A buffer that has not shown its session yet does not count."
  (let ((seen (buffer-local-value 'harness-chat--session buffer)))
    (and seen (not (equal (format "%s" (plist-get seen :status)) "inactive")))))

(defun harness-chat--reopen-all ()
  "Open again the closed sessions that chat buffers showed open.
Run after connecting: a harness that just started (`harness-restart', a
crash) has every session closed, but one a buffer here showed open was
open, so it opens again.  One a buffer showed inactive, or has not shown
yet -- it opened as the UI connected -- stays as it is: an inactive
session opens as it is, and the first message sent from it resumes it."
  (maphash (lambda (id buf)
             (when (and (buffer-live-p buf) (harness-chat--showed-open-p buf))
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
C-c C-k cancels as usual.  A task in review is no such thing: the
harness takes any message to its session for the feedback that sends it
back (`harness-tasks--on-message').")

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
  "Append an error block to BUF saying WHAT failed with ERR.
Nothing failed when the UI let go of the connection on purpose while
waiting (`harness-ui-connection-replaced-p'): a message sent before it
connected again still runs its turn, as the redrawn transcript shows."
  (when (and (buffer-live-p buf) (not (harness-ui-connection-replaced-p err)))
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
                                (lambda (err) (harness-chat--report-error buf "send" err))))))))))))


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

(defalias 'harness-chat-show-usage #'harness-ui-show-usage
  "Alias of `harness-ui-show-usage', which the task board shares.")

(defun harness-chat--spend-segment (session)
  "Return the header segment showing what SESSION cost and who pays for it.
Per-token billing shows the cost; a subscription shows its plan and
quota.  Clicking it opens the usage dashboard (`harness-ui-spend-segment')."
  (harness-ui-spend-segment (harness-ui-format-spend session t)))

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

(defun harness-chat--on-rate (id _rate)
  "Redraw the header line of session ID's chat, which shows its output rate.
ID nil, after every rate was fetched again, redraws them all."
  (if (null id)
      (force-mode-line-update t)
    (when-let* ((buf (harness-chat--buffer-for id)))
      (with-current-buffer buf (force-mode-line-update)))))

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

(defun harness-chat--header (&optional width)
  "Return the header line, fitted to WIDTH, its window's by default.
In a window too narrow for all of it, the output rate goes first, then
the spend, the thinking level, the context, the non-interactive mode,
the model and the todos; the name shortens after those.  What
`harness-chat-header-functions' put in front, the status, the
permission mode, [menu] and the notice of new messages stay.  WIDTH is
as `harness-ui-fit-header' takes it."
  (let* ((s (harness-chat--session))
         (status (or (plist-get s :status) "idle"))
         (running (equal status "running"))
         (todos (harness-chat--todos-segment))
         (rate (harness-ui-format-rate s))
         (name (or (plist-get s :name) "unnamed")))
    (harness-ui-fit-header
     (list
      (harness-chat--header-prefix)
      (concat " "
              (if running
                  (propertize (harness-chat--spinner-frame)
                              'face 'harness-status-running-face
                              'help-echo (harness-chat--activity-text harness-chat--activity))
                (propertize (harness-ui-status-icon status) 'help-echo status)))
      (list (concat " " (harness-chat--segment name #'harness-rename-session
                                               "Session name (mouse-1: rename)" 'bold))
            70 (concat " " (harness-chat--segment (harness-truncate-end name 8) #'harness-rename-session
                                                 "Session name (mouse-1: rename)" 'bold)))
      ;; The segment ends in two spaces of its own; the list takes them
      ;; as the separator, as the plain header line did.
      (and todos (list (concat "  " (string-trim-right todos " +")) 55))
      (list (concat "  " (harness-chat--segment (harness-ui-model-label (plist-get s :model)) #'harness-set-model
                                                "Model (mouse-1: change)" 'harness-dim-face))
            50)
      (list (concat "  " (harness-chat--segment (harness-ui-permission-mode-label (plist-get s :permission-mode))
                                                #'harness-set-permission-mode
                                                "Permission mode (mouse-1: change)"))
            90)
      (list (concat "  " (harness-chat--non-interactive-segment s)) 40)
      (list (concat "  " (harness-chat--segment (harness-ui-thinking-label (plist-get s :thinking))
                                                #'harness-set-thinking "Thinking level (mouse-1: change)"
                                                'harness-dim-face))
            20)
      (list (concat "  " (harness-ui-format-context s)) 30)
      (and rate (list (concat "  " rate) 5))
      (list (concat "  " (harness-chat--spend-segment s)) 10)
      (list (concat "  " (harness-chat--segment "[menu]" #'harness-menu #'harness-chat--menu-help 'harness-dim-face))
            95)
      (and harness-chat--unseen
           (list (concat "  " (harness-chat--segment "↓ new messages" #'harness-chat-scroll-to-bottom
                                                     "New content below (mouse-1: jump to it)"
                                                     'harness-status-blocked-face))
                 88)))
     width)))

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

(defun harness-chat--block-markdown (block)
  "Return the Markdown BLOCK shows, as it was written, or nil for none."
  (let ((text (if (equal (harness-chat-block-kind block) "plan")
                  (plist-get (harness-chat-block-node block) :content)
                (harness-chat-block-content block))))
    (and (stringp text) (not (string-blank-p text)) text)))

(defun harness-chat--quote-at-point ()
  "Return the Markdown of the agent's message to quote from point, or nil.
That is the response, plan or thinking point is on; anywhere else -- a
tool call, the user's message, the compose box -- the response or plan
nearest above point, so the agent's last one from the box.  The chat's
`harness-compose-quote-function', for \\[harness-compose-quote-reply]."
  (let* ((id (get-text-property (point) 'harness-chat-node))
         (here (and id (gethash id harness-chat--blocks))))
    (or (and here (member (harness-chat-block-kind here) '("assistant" "plan" "thinking"))
             (harness-chat--block-markdown here))
        (cl-loop for id in harness-chat--order
                 for block = (gethash id harness-chat--blocks)
                 for start = (and block (harness-chat-block-start block))
                 thereis (and start (marker-position start) (< start (point))
                              (member (harness-chat-block-kind block) '("assistant" "plan"))
                              (harness-chat--block-markdown block))))))

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
  ;; By pixels, so a tall image goes by a bit at a time.
  (define-key map [remap scroll-up-command] #'harness-chat-scroll-up)
  (define-key map [remap scroll-down-command] #'harness-chat-scroll-down)
  (define-key map (kbd "TAB") #'harness-chat-tab)
  (define-key map (kbd "C-c C-q") #'harness-chat-queue)
  (define-key map (kbd "C-c C-c") #'harness-chat-send)
  (define-key map (kbd "C-c C-k") #'harness-chat-cancel)
  (define-key map (kbd "C-c C-s") #'harness-chat-search)
  (define-key map (kbd "C-c C-y") #'harness-chat-allow-newest)
  (define-key map (kbd "C-c C-n") #'harness-chat-deny-newest)
  (define-key map (kbd "C-c C-p") #'harness-chat-edit-permission-pattern)
  (define-key map (kbd "C-c C-f") #'harness-chat-next-diagram)
  (define-key map (kbd "C-c C-b") #'harness-chat-previous-diagram)
  (define-key map (kbd "C-c C-w") #'harness-chat-copy-last-response)
  (define-key map (kbd "C-c C-t") #'harness-chat-toggle-todos)
  (define-key map (kbd "C-c C-r") #'harness-chat-redraw)
  (define-key map (kbd "C-c C-e") #'harness-chat-scroll-to-bottom)
  ;; Plain q is typing here.
  (define-key map (kbd "C-c C-z") #'harness-ui-bury))

(define-derived-mode harness-chat-mode special-mode "Chat"
  "Major mode of a harness session buffer.
The transcript is read-only; the compose box at the bottom is editable.
Typing anywhere goes to the box, `?' included, so the harness menu is
on \\[harness-menu] here, or the [menu] button in the header line.  On
a request's panel its own keys answer it instead: a question's digits,
up to its number of options, and a permission's y, s, a, n and N, and
e when it has a pattern to edit.

\\[harness-compose-quote-reply] quotes the region, or the agent's message at point, in
the box, to reply to it; from the box, the agent's last message.

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
  (setq-local harness-compose-quote-function #'harness-chat--quote-at-point)
  (add-hook 'post-command-hook #'harness-chat--post-command nil t)
  (add-hook 'window-buffer-change-functions #'harness-chat--on-window-buffer-change nil t)
  (add-hook 'window-scroll-functions #'harness-chat--schedule-history nil t)
  ;; The wheel scrolls by pixels too (see "Scrolling by pixels").
  (setq-local mwheel-scroll-up-function #'harness-chat-scroll-forward
              mwheel-scroll-down-function #'harness-chat-scroll-back
              make-cursor-line-fully-visible #'harness-chat--cursor-line-fully-visible)
  (add-hook 'kill-buffer-hook #'harness-chat--on-kill nil t))

;; The chat's keys in the harness menu, as the buffer binds them.
(put 'harness-chat-mode 'harness-menu-group
     '("Chat"
       ["Message"
        ("C-c C-c" "Send" harness-chat-send)
        ("C-c C-q" "Queue for next turn" harness-chat-queue)
        ("C-c C-a" "Attach file" harness-compose-add-attachment)
        ("C-y" "Paste; an image attaches" harness-compose-yank)
        ("C-c >" "Quote reply: region or message" harness-compose-quote-reply)]
       ["Agent"
        ("C-c C-y" "Allow request" harness-chat-allow-newest)
        ("C-c C-n" "Deny request" harness-chat-deny-newest)
        ("C-c C-p" "Edit request's pattern" harness-chat-edit-permission-pattern)
        ("C-c C-f" "Next diagram" harness-chat-next-diagram)
        ("C-c C-b" "Previous diagram" harness-chat-previous-diagram)
        ("C-c C-t" "Show or hide the todo list" harness-chat-toggle-todos)
        ("C-c C-k" "Cancel turn" harness-chat-cancel)]
       ["Transcript"
        (". TAB" "Fold block" harness-chat-tab)
        ("C-c C-s" "Search" harness-chat-search)
        ("C-c C-w" "Copy last reply" harness-chat-copy-last-response)
        ("C-c C-e" "Jump to bottom" harness-chat-scroll-to-bottom)
        ("C-c C-r" "Redraw" harness-chat-redraw)
        ("C-c C-z" "Bury: back to the buffer before" harness-ui-bury)]))

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
  (add-hook 'harness-ui-rate-functions #'harness-chat--on-rate)
  ;; The pending module owns the requests themselves (it registers with
  ;; `harness-ui-permission-functions' and `harness-ui-question-functions');
  ;; a chat buffer drawing them makes them its own, and this mirror redraws.
  (add-hook 'harness-ui-pending-drawn-predicates #'harness-chat--drawn-p)
  (add-hook 'harness-ui-pending-changed-hook #'harness-chat--on-pending-changed)
  (add-hook 'harness-ui-redraw-hook #'harness-chat--redraw-all)
  (add-hook 'harness-ui-connected-hook #'harness-chat--reopen-all)
  (harness-chat--init-hooks)
  (define-key harness-ui-map (kbd "o") #'harness-open-latest-session)
  (define-key harness-ui-map (kbd "O") #'harness-open-session)
  (ignore-errors
    (transient-append-suffix 'harness-menu "s" '("o" "Open latest session" harness-open-latest-session))))

(defun harness-chat--init-hooks ()
  "Add the hooks that came after the module's first version.
A reload does not initialise a running module again, so the file adds
them itself when the module is ready (below)."
  ;; Windows following a streaming chat scroll once per slice of messages.
  (add-hook 'harness-acp-received-hook #'harness-chat--pin-waiting))

(harness-define-module 'ui-chat
  :doc "The chat buffer: transcript, pending panel, queue, attachments and compose box."
  :requires '(ui)
  :init #'harness-chat--init)

(when (harness-module-ready-p 'ui-chat)
  (harness-chat--init-hooks))

(provide 'harness-ui-chat)
;;; harness-ui-chat.el ends here
