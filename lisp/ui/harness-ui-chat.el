;;; harness-ui-chat.el --- The chat buffer  -*- lexical-binding: t; -*-

;;; Commentary:

;; One buffer per session, "*harness: NAME*", laid out top to bottom:
;;
;;   header line   name, model, permission mode, non-interactive (only
;;                 while it is on), thinking, context, cost, menu, after what
;;                 `harness-chat-header-functions' put in front (a BTW's
;;                 buttons); what the buffer shows already, it leaves out
;;   transcript    one block per node, rendered incrementally with markers
;;   top           what `harness-chat-top-functions' draw, first in the
;;                 tail: the companion pet, standing on whatever comes next
;;   queue         messages queued for the next turn, each drawn as the
;;                 user message it will be, "queued" and its buttons on
;;                 its sender line
;;   activity      while a turn runs, what it does and for how long, on a
;;                 background of its own, then a blank line
;;   pending panel permission requests and questions waiting for the user;
;;                 a question whose options have diagrams shows one of
;;                 them at a time, in one place, and switches between them
;;   todos         the session's todo items, one per line, or folded
;;   attachments   chips for files attached to the next message
;;   notice        the session was deleted, or is inactive (sending resumes it)
;;   compose       an editable region; C-c C-c sends, RET adds a newline
;;   mode line     status (the spinner while a turn runs), turn duration
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
(declare-function harness-ui-decision "harness-ui-decisions" (id))
(declare-function harness-ui-decision-help "harness-ui-decisions" (id way))
(declare-function harness-ui-decisions-store "harness-ui-decisions" (decision))
(declare-function harness-decision-undo "harness-ui-decisions" (id))
(declare-function harness-decision-redo "harness-ui-decisions" (id))
(defvar harness-state-directory)
(defvar harness-ui-decision-functions)
(defvar harness-ui-markdown-table-width)
(defvar harness-ui-markdown-hard-breaks)

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

(defconst harness-chat--message-limit 20000
  "Characters of a message shown before a \"show more\" button.
A message longer than this shows its first `harness-chat--message-limit'
characters and a button that shows as much again, press by press.  A
message of hundreds of kilobytes -- the plan, a step prompt or a report
the supervisor sends a worker, or a model's own long answer -- would
otherwise sit in the buffer whole: redisplay wraps it, `recenter' and
`harness-ui-text-height' lay it out, and Emacs freezes for seconds
every time the chat is opened or scrolled.  Tool output has its own,
smaller, threshold (`harness-chat--tool-output-limit').")

(defconst harness-chat--render-interval 0.3
  "Seconds between Markdown re-renders of a streaming block.")

(defconst harness-chat--render-spacing 5
  "How many times its last re-render's time a streaming block waits for the next.
When that is longer than `harness-chat--render-interval', it is the
wait: re-rendering a long message as it streams in then takes a sixth
of Emacs's time at most.")

(defconst harness-chat--coalesce-threshold 1
  "Coalescable tool calls a run needs to fold into one summary block.
The first call opens a collapsed run; every later call, and the
thinking between the calls, is added to it.  Thinking does not break
the run and is not counted.")

(defconst harness-chat--dismissed-answer "The user dismissed the question"
  "The text `question/cancel' (harness-tools-agent.el) gives an ask_user call.
A dismissed question's call ends with it, as an ordinary result.  It is
the harness's text, not the user's, so the call's block shows no answer
of the user's for it.  It is matched here because the UI may run apart
from the harness and does not load that module.")

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
and the queued messages above it, and asks for an answer without the
alarm of a warning colour." :group 'harness-ui-chat)
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

(defface harness-chat-undone-face '((t :inherit harness-hint-face :strike-through t))
  "Face of the text of a lasting decision that was undone.
The note of a permission answer or of the cold-cache choice it tells
of, or the decision a later note says it follows from: what it set is
gone, so it is struck through." :group 'harness-ui-chat)

(defface harness-chat-found-face '((t :inherit match))
  "What a search found, where its session opens at it.
See `harness-ui-chat-goto-node'." :group 'harness-ui-chat)

(harness-ui-define-icon harness-chat-icon-plan "plan" "≡" "plan" "A plan.")
(harness-ui-define-icon harness-chat-icon-compaction "compaction" "⟲" "compact" "A compaction.")
(harness-ui-define-icon harness-chat-icon-question "question" "?" "?" "A question.")

(defconst harness-chat--spinner-frames ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"]
  "Frames of the running spinner.")

;;;; Buffer state

(cl-defstruct (harness-chat-block (:constructor harness-chat--make-block) (:copier nil))
  "One rendered node."
  id kind node result start end fold collapsed show-all shown content streamed group
  head)                                 ; non-nil: first agent block of a turn, carries the sender name

(cl-defstruct (harness-chat-group (:constructor harness-chat--make-group-record) (:copier nil))
  "A run of coalesced tool calls folded under one summary.
MEMBERS are the ids of its blocks, oldest first: the calls and the
thinking between them."
  id members start end overlay expanded)

(defvar harness-chat--buffers (make-hash-table :test 'equal)
  "Session id -> chat buffer.")

(defvar harness-chat--spinner-timer nil
  "Timer animating the spinners: the mode line's and the activity line's.")
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
(defvar-local harness-chat--queued-blocks nil
  "Queue item id -> the block that draws the queued message, or nil.
A queued message is drawn as the user block it will be once sent
\(`harness-chat--queued-block').  The blocks are kept from one render of
the tail to the next, so a long message keeps the part of it it shows
\(`harness-chat--show-more').")
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
(defvar-local harness-chat--notice nil
  "Non-nil while the newer-messages notice is drawn.
`harness-chat--update-notice' keeps it, from the post-command hook and
`window-scroll-functions'; the header line (`harness-chat--header')
reads it, as it must not measure the window itself.")
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
(defvar-local harness-chat--goto nil
  "The node the buffer is to show once it is rendered, or nil.
A plist: `:id' the node's id, `:regexp' what to find in it.  See
`harness-ui-chat-goto-node'.")
(defvar-local harness-chat--found nil
  "Overlays on what `harness-ui-chat-goto-node' found, until the next command.")
(defvar-local harness-chat--generation 0 "Bumped on every reload to drop stale responses.")
(defvar-local harness-chat--session nil "Last session plist seen, for after deletion.")
(defvar-local harness-chat--unfinished nil "Ids of tool-call blocks without a result yet.")
(defvar-local harness-chat--sending nil
  "Ids of the user blocks that may carry a note about their delivery.
They are the steering messages (sent while a turn ran) of the turn that
goes on, or, once it is over, the ones nothing answered.
`harness-chat--refresh-sending' keeps the list, and draws the blocks
again as the turn goes on and ends (`harness-chat--delivery-note').")
(defvar-local harness-chat--queue-running nil
  "Whether a turn ran when the queue was last drawn.
The buttons of a queued message say what sending it now does, which
depends on it (`harness-chat--insert-queue').")
(defvar-local harness-chat--inactive nil "Non-nil while the session is inactive; sending resumes it.")
(defvar-local harness-chat--todos nil
  "The session's todo list as last seen: a list of (:text :status).")
(defvar-local harness-chat--todos-collapsed nil
  "Non-nil when the todo panel shows its title line alone.")
(defvar-local harness-chat--activity nil
  "What the running turn does, as `agent/activity' last said (wire shape).")
(defvar-local harness-chat--notes nil
  "Tool call id -> the note the running turn's activity gives the call.
The note is drawn under the call's own block (see `harness-chat--note-lines').")
(defvar-local harness-chat--activity-overlay nil
  "Overlay whose `before-string' is the activity line.
It is empty and sits at `harness-chat--activity-position': the end of
the transcript, or the end of what `harness-chat-top-functions' drew
there.")

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

(defconst harness-chat--cursor-line-limit 10000
  "Longest line `harness-chat--cursor-line-fully-visible' brings into view.
A longer line is left as it is: it cannot fit whole, and asking
redisplay to try would rescan all of it on every redisplay.")

(defun harness-chat--line-at-most-p (position limit)
  "Non-nil when the line at POSITION is at most LIMIT characters long.
Looks at most LIMIT characters either side of POSITION, never the whole
line."
  (save-excursion
    (goto-char position)
    (let ((back (let ((found (search-backward "\n" (max (point-min) (- position limit)) t)))
                  (if found (- position (1+ found)) (- position (point-min))))))
      (and (<= back limit)
           (let ((end (min (point-max) (+ position (max 0 (- limit back))))))
             (or (search-forward "\n" end t)
                 (= end (point-max))))))))

(defun harness-chat--cursor-line-fully-visible (window)
  "The chat's `make-cursor-line-fully-visible', for WINDOW.
Point's line is brought into full view, as by default, unless WINDOW
is scrolled partway into a tall line: that would undo the scroll.
`pixel-scroll-precision-mode' turns the option off everywhere for this
\(bug#65214).

Redisplay asks this for every window it draws, so it must not look at
the line at all: a chat can hold a line megabytes long (a model wrote a
whole file, or a failure carried a request body), and measuring it
\(`line-end-position', `pos-visible-in-window-p', `line-pixel-height')
would rescan all of it on every redisplay.  Only `window-vscroll', which
is O(1), and a look at most `harness-chat--cursor-line-limit'
characters along the line are taken; a line longer than that is left as
it is rather than asked to be shown whole."
  (and (zerop (window-vscroll window t))
       (with-current-buffer (window-buffer window)
         (harness-chat--line-at-most-p (window-point window) harness-chat--cursor-line-limit))))

;;;; Auto-scroll

(defun harness-chat--at-bottom-p (&optional window)
  "Non-nil when WINDOW shows the end of the transcript.
WINDOW defaults to the first window showing the buffer; without one
the buffer counts as at the bottom.
Never call this from a header-line or mode-line `:eval': it measures
the window (`pos-visible-in-window-p'), which formats those lines, so
the call would run again inside itself, without end.  The header reads
`harness-chat--notice' instead."
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

(defun harness-chat--scrolled-up-p ()
  "Non-nil when a window on this buffer is not at the newest message.
Never call this from a header-line or mode-line `:eval': measuring a
window formats those lines, which would call it again, without end (see
`harness-chat--at-bottom-p').  The header reads `harness-chat--notice',
which `harness-chat--update-notice' sets from this."
  (cl-some (lambda (w) (not (harness-chat--at-bottom-p w)))
           (harness-chat--windows)))

(defun harness-chat--update-notice (&rest _)
  "Show or hide the newer-messages notice as the window's position is now.
The header line draws the notice from `harness-chat--notice', which
this sets: the header cannot measure the window itself (see
`harness-chat--at-bottom-p').  Emacs redraws the header only when told
to; this forces one redraw exactly when the notice changes.  Runs from
`harness-chat--post-command' and from `window-scroll-functions'."
  (let ((show (or harness-chat--unseen (harness-chat--scrolled-up-p))))
    (unless (eq show harness-chat--notice)
      (setq harness-chat--notice show)
      (force-mode-line-update))))

(defun harness-chat-scroll-to-bottom ()
  "Show the newest messages and put point in the compose box."
  (interactive)
  (setq harness-chat--unseen nil
        harness-chat--notice nil)
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

(defvar-local harness-chat--table-width nil
  "Columns Markdown tables were last rendered at in this buffer.
`harness-ui-markdown-table-width' is bound to this while a block is
rendered; a window resized later renders its tables again at the new
width (`harness-chat--refresh-tables').")

(defun harness-chat--content-width ()
  "Return the columns a block's text has to fit in.
That is the width of a window showing the chat, less the margin bar
and a column or two; a buffer no window shows gets a width its tables
still fit when one does."
  (if-let* ((window (car (harness-chat--windows))))
      (max 20 (- (window-body-width window) 4))
    80))

(defun harness-chat--render-markdown (text)
  "Return TEXT rendered as Markdown, its tables fitted to the window.
The width used is remembered in `harness-chat--table-width', so that a
window resized after the render draws the tables again at the new
width."
  (let ((harness-ui-markdown-table-width (harness-chat--content-width)))
    (setq harness-chat--table-width harness-ui-markdown-table-width)
    (harness-ui-markdown-render text)))

(defun harness-chat--block-has-table-p (block)
  "Non-nil when the rendering of BLOCK holds a Markdown table."
  (save-excursion
    (goto-char (harness-chat-block-start block))
    (and (text-property-search-forward 'harness-md-block 'table t)
         (<= (point) (harness-chat-block-end block)))))

(defun harness-chat--on-window-size (&optional _window)
  "Have the tables drawn again when a window gives them different room.
Runs from `window-size-change-functions'."
  (when (and harness-chat--table-width
             (not (equal (harness-chat--content-width) harness-chat--table-width)))
    (harness-debounce (list 'harness-chat-tables (current-buffer)) 0.2
                      #'harness-chat--refresh-tables (current-buffer))))

(defun harness-chat--refresh-tables (buffer)
  "Render again the table-holding blocks of BUFFER at its window's width."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and harness-chat--table-width harness-chat--blocks
                 (not harness-chat--loading))
        (let ((width (harness-chat--content-width)))
          (when (not (equal width harness-chat--table-width))
            ;; Bind the new width while rerendering, so a rerender does
            ;; not schedule another pass of its own.
            (let ((harness-chat--table-width width))
              (dolist (id harness-chat--order)
                (when-let* ((block (gethash id harness-chat--blocks)))
                  (when (harness-chat--block-has-table-p block)
                    (harness-chat--rerender block)))))
            (setq harness-chat--table-width width)))))))

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
MIME is a hint for the image type.  It is drawn in
`harness-ui-image-colors'.  The image can be dragged into another
application as a file, one held in memory written to the session's
temporary directory first (`harness-ui-drag-props').  Without image
support, and for a path on a remote host, which reading here would
block on, a button opening the file is returned instead.  An image too
large for Emacs to draw (`harness-ui-image-too-large') is a line saying
so, a button opening it outside Emacs."
  (let* ((path (and (stringp source) source))
         (data (and (consp source) (plist-get source :data)))
         (label (if path (format "[image %s]" (abbreviate-file-name path)) "[image]"))
         (local (and path (not (file-remote-p path))))
         (open (and path (lambda () (interactive) (find-file-other-window path))))
         (w (car (harness-chat--windows)))
         (frame (and w (window-frame w)))
         (drawable (and (display-images-p frame) (or data (and local (file-readable-p path)))))
         (too-large (and drawable (harness-ui-image-too-large source frame)))
         (img (and drawable (not too-large)
                   (let ((width (floor (* 0.6 (if w (window-body-width w t) 800)))))
                     (condition-case nil
                         (apply #'create-image (if data (base64-decode-string data) path) nil (and data t)
                                :max-width width :max-height harness-chat--image-max-height
                                (harness-ui-image-color-props))
                       (error nil))))))
    (cond
     (img (concat (apply #'propertize label 'display img
                         (harness-ui-drag-props
                          (list 'pointer 'hand
                                'help-echo (if open (format "mouse-1 or RET: open %s" path) mime)
                                'keymap (and open (harness-chat--mouse-map open)))
                          path))
                  "\n"))
     ((and too-large path)
      (concat (harness-chat--button (harness-ui-image-too-large-label label too-large)
                                    (harness-ui-open-image-outside path)
                                    :help (format "Open %s outside Emacs" path))
              "\n"))
     (too-large (concat (propertize (harness-ui-image-too-large-label label too-large) 'face 'harness-dim-face) "\n"))
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

(defun harness-chat--mark-references (text blocks)
  "Return TEXT with the references of the attachments among BLOCKS styled.
The tokens of images (`harness-chat--mark-image-tokens'), the @
references of the files attached -- a file's name, or a path that ends in
it -- and @task: ones show in the face they have in the compose box
\(`harness-compose-token-face'), so a reference looks the same before
and after it is sent.  The tooltip says what it is."
  (let ((text (copy-sequence (harness-chat--mark-image-tokens text blocks)))
        (files (delq nil (mapcar (lambda (b)
                                   (and (equal (harness-chat--str (plist-get b :type)) "file")
                                        (stringp (plist-get b :path))
                                        (cons (file-name-nondirectory (plist-get b :path)) (plist-get b :path))))
                                 blocks)))
        (case-fold-search nil)
        (start 0))
    (while (string-match harness-compose--reference-regexp text start)
      (let* ((from (1- (match-beginning 1)))
             (end (match-end 1))
             (word (match-string 1 text))
             ;; Punctuation after the reference, ending a sentence or a bracket, is no part of it.
             (name (replace-regexp-in-string "[]),.;:!?'\"`>}]+\\'" "" word))
             (task (string-prefix-p "task:" name))
             (file (and (not task) (assoc (file-name-nondirectory name) files))))
        (setq start end)
        (when (or file (and task (> (length name) (length "task:"))))
          (add-face-text-property from (+ from 1 (length name)) 'harness-compose-token-face nil text)
          (put-text-property from (+ from 1 (length name)) 'help-echo
                             (if task (format "task %s" (substring name (length "task:")))
                               (format "file: %s" (abbreviate-file-name (cdr file))))
                             text))))
    text))

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

;;;; Showing long messages

(defun harness-chat--message-text (block)
  "Return the whole message BLOCK holds, whether or not it is all shown."
  (let ((text (harness-chat-block-content block)))
    (if (stringp text)
        text
      (or (plist-get (harness-chat-block-node block) :content) ""))))

(defun harness-chat--page-limit (block)
  "Return how many characters of its message BLOCK shows.
The default page, or as many pages as `harness-chat--show-more' has
been asked for."
  (or (harness-chat-block-shown block) harness-chat--message-limit))

(defun harness-chat--page (block)
  "Return the part of BLOCK's message it shows now.
Everything, for a message no longer than `harness-chat--message-limit';
else its first `harness-chat--page-limit' characters, the rest waiting
behind the button `harness-chat--more-button' returns."
  (let* ((text (harness-chat--message-text block))
         (limit (harness-chat--page-limit block)))
    (if (> (length text) limit) (substring text 0 limit) text)))

(defun harness-chat--show-more (id)
  "Show another page of the message of block ID.
ID is a node's, or a queued message's (`harness-chat--queued-blocks'),
which the tail then draws again."
  (if-let* ((block (gethash id harness-chat--blocks)))
      (progn (setf (harness-chat-block-shown block)
                   (+ (harness-chat--page-limit block) harness-chat--message-limit))
             (harness-chat--rerender block))
    (when-let* ((queued (and harness-chat--queued-blocks (gethash id harness-chat--queued-blocks))))
      (setf (harness-chat-block-shown queued)
            (+ (harness-chat--page-limit queued) harness-chat--message-limit))
      (harness-chat--render-tail))))

(defun harness-chat--more-button (block)
  "Return BLOCK's button for the rest of its message, or nil.
Nil while the whole message shows."
  (let* ((text (harness-chat--message-text block))
         (rest (- (length text) (harness-chat--page-limit block))))
    (when (> rest 0)
      (harness-chat--button
       (format "show %s (%d more chars)"
               (if (> rest harness-chat--message-limit) "more" "the rest")
               rest)
       (lambda () (harness-chat--show-more (harness-chat-block-id block)))
       :help (format "Show the next %d characters of this message" harness-chat--message-limit)))))

(defun harness-chat--more-line (block)
  "Return the line holding BLOCK's \"show more\" button, or \"\"."
  (if-let* ((button (harness-chat--more-button block)))
      (concat "  " button "\n")
    ""))

;;;; Rendering: blocks

(defun harness-chat--sender (text face)
  "Return a sender line naming TEXT in FACE."
  (concat (propertize text 'face face) "\n"))

(defalias 'harness-chat--session-name #'harness-ui-session-name
  "Alias of `harness-ui-session-name'.")

(defun harness-chat--from-line (from)
  "Return the sender line of a message FROM sent, rather than the user.
The harness reads \"System · SOURCE\", another session's agent
\"Session · NAME\", NAME a session link that opens that session."
  (pcase-let ((`(,label . ,which)
               (pcase (harness-sender-kind from)
                 ('session
                  (let* ((id (plist-get from :id))
                         (name (harness-chat--session-name id (plist-get from :name))))
                    (cons harness-chat-session-label
                          (if id
                              (harness-ui-session-link id name (format "Open the session %s" name))
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

;;;;; The delivery of a message sent while a turn runs

;; A message sent while a turn runs steers it: its user node is marked
;; `:steering', and the turn gives it to the model at its next step.
;; Taking it marks the node `:delivered-after' (`harness-agent--take-steering'),
;; and that update reaches the chat as any node update.  The sender line
;; of such a message gives its state in a word while the turn goes on:
;; "sent", waiting for the model's next step, then "delivered", in the
;; model's hands.  Once the turn is over there is nothing to say, unless
;; the model never got it (the turn was cancelled) and nothing answered
;; it: "not delivered", and the next turn reads it.

(defvar harness-chat--agent-kinds)

(defun harness-chat--steering-p (node)
  "Non-nil when the user message NODE was sent while a turn ran, to steer it."
  (harness-json-true-p (plist-get (plist-get node :meta) :steering)))

(defun harness-chat--delivered-p (node)
  "Non-nil when the steering message NODE reached the model."
  (let ((after (plist-get (plist-get node :meta) :delivered-after)))
    (and (stringp after) (not (string-empty-p after)))))

(defun harness-chat--delivery-note (block)
  "Return the state of the delivery of user BLOCK, as a note, or nil.
Only a block in `harness-chat--sending' has one, a word: while the turn
goes on \"sent\" with a yellow circle until the model has the message,
then \"delivered\" with a green one.  Once the turn is over, a message it
never delivered is \"not delivered\".  The tooltip says what the state
means."
  (when (member (harness-chat-block-id block) harness-chat--sending)
    (let ((delivered (harness-chat--delivered-p (harness-chat-block-node block))))
      (cond ((and harness-chat--turn-start delivered)
             (concat (harness-ui-level-icon 'success) " "
                     (propertize "delivered" 'face (harness-ui-level-face 'success)
                                 'help-echo "The model has this message")))
            (harness-chat--turn-start
             (concat (harness-ui-level-icon 'caution) " "
                     (propertize "sent" 'face (harness-ui-level-face 'caution)
                                 'help-echo "The model gets this message at its next step")))
            ((not delivered)
             (propertize "not delivered" 'face 'harness-dim-face
                         'help-echo "The turn ended before the model got this message; the next turn reads it"))))))

(defun harness-chat--with-note (body note)
  "Return BODY, the text of a user message, with NOTE on its sender line.
NOTE goes after the sender's name, two spaces apart; nil leaves BODY as
it is."
  (let ((end (string-search "\n" body)))
    (if (and note end)
        (concat (substring body 0 end) "  " note (substring body end))
      body)))

(defun harness-chat--sending-candidates ()
  "Return the ids of the user blocks that may carry a delivery note now.
The transcript is read from its end back to the message that began the
turn last: while a turn goes on the steering messages of it all count,
and once it is over only those no agent output follows."
  (let (ids answered)
    (catch 'turn
      (dolist (id harness-chat--order)
        (when-let* ((block (gethash id harness-chat--blocks)))
          (let ((kind (harness-chat-block-kind block)))
            (cond ((equal kind "user")
                   (if (harness-chat--steering-p (harness-chat-block-node block))
                       (when (or harness-chat--turn-start (not answered)) (push id ids))
                     (throw 'turn nil)))
                  ((member kind harness-chat--agent-kinds) (setq answered t)))))))
    ids))

(defun harness-chat--redraw-sending ()
  "Work out which user blocks carry a delivery note, and draw them again.
That is those that had one and those that have one now."
  (let ((before harness-chat--sending)
        (after (harness-chat--sending-candidates)))
    (setq harness-chat--sending after)
    (dolist (id (cl-union before after :test #'equal))
      (when-let* ((block (gethash id harness-chat--blocks)))
        (harness-chat--rerender block)))))

(defun harness-chat--refresh-sending ()
  "Keep the delivery notes of the user blocks as the turn has them.
Called when a user message arrives, and when a turn begins or ends: the
notes follow the turn.  Not while the transcript is being rendered; it
calls `harness-chat--redraw-sending' itself once the transcript is whole."
  (unless (or harness-chat--batch harness-chat--loading (null harness-chat--blocks))
    (harness-chat--redraw-sending)))

(defun harness-chat--render-user (block &optional note)
  "Return the body of user BLOCK.
A message the user did not write names who sent it instead of the user
and sits on the system background (see `harness-node-sender').  One
that handed the conversation over to a model of another provider (see
`harness-node-handoff') also names the two models and links the
transcript it points the new model at.  NOTE is what the sender line
says after the name: by default the state of the message's delivery
\(`harness-chat--delivery-note').  A queued message is drawn so too,
NOTE its state and its buttons (`harness-chat--insert-queue')."
  (let* ((node (harness-chat-block-node block))
         (from (harness-node-sender node))
         (handoff (harness-node-handoff node))
         (face (if from 'harness-system-face 'harness-user-face))
         ;; A line break typed in the box is one: a pasted log, or items
         ;; without bullets, keep their lines.
         (text (harness-chat--mark-references
                (harness-chat--ensure-newline
                 (let ((harness-ui-markdown-hard-breaks t))
                   (harness-chat--render-markdown (harness-chat--page block))))
                (plist-get node :blocks)))
         (body (concat (if from
                           (harness-chat--from-line from)
                         (harness-chat--sender harness-chat-user-label 'harness-user-label-face))
                       (if (string-blank-p text) "" text)
                       (harness-chat--more-line block)
                       (if handoff (harness-chat--handoff-line handoff) "")
                       (harness-chat--blocks-string (plist-get node :blocks)))))
    (harness-chat--margin (harness-chat--face (harness-chat--with-note body (or note (harness-chat--delivery-note block)))
                                              face)
                          face
                          (if from 'harness-system-bar-face 'harness-user-bar-face))))

(defconst harness-chat--agent-kinds '("assistant" "thinking" "tool-call" "tool-result" "plan")
  "Block kinds the agent produces; a run of them is one agent turn.")

(defun harness-chat--head-p (kind previous)
  "Non-nil when a KIND block after one of kind PREVIOUS starts an agent turn.
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
  (let ((content (harness-chat--page block)))
    (harness-chat--margin
     (if (string-blank-p content)
         "\n"
       (concat (harness-chat--face (harness-chat--ensure-newline (harness-chat--render-markdown content))
                                   'harness-agent-face)
               (harness-chat--more-line block))))))

(defun harness-chat--render-thinking (block)
  "Return the body of thinking BLOCK."
  (let* ((id (harness-chat-block-id block))
         (content (harness-chat--page block))
         (header (concat (harness-chat--fold-button (harness-chat-block-collapsed block)
                                                    (lambda () (interactive) (harness-chat-toggle-block id)))
                         " "
                         (propertize (format "%s thinking (%d words)" (harness-ui-icon 'harness-icon-thinking)
                                             (harness-chat--words (harness-chat--message-text block)))
                                     'face 'harness-thinking-face)
                         "\n"))
         (body (harness-chat--foldable
                (concat (harness-chat--face (harness-chat--plain content) 'harness-thinking-face)
                        (harness-chat--more-line block)))))
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

(defun harness-chat--child-id (call result)
  "Return the id of the session a tool call started, or nil.
That is the sub-agent of a spawn_agent call: the `:child-id' in the
`:meta' of CALL, the call's node, or of RESULT, its result.  A call the
harness recorded (`harness-outside-node-p') names its child from the
start, and a model's spawn_agent call does from the moment the child
exists (`harness-tools-agent--name-child'); its result names it too."
  (let ((id (or (plist-get (plist-get call :meta) :child-id)
                (plist-get (plist-get result :meta) :child-id))))
    (and (stringp id) (not (string-empty-p id)) id)))

(defun harness-chat--block-child (block)
  "Return the id of the session BLOCK's tool call started, or nil.
Only a tool call's block names one (`harness-chat--child-id')."
  (and (member (harness-chat-block-kind block) '("tool-call" "tool-result"))
       (harness-chat--child-id (harness-chat-block-node block)
                               (harness-chat-block-result block))))

(defun harness-chat--call-sessions (call result)
  "Return the ids of the sessions a tool call names, in order, each once.
First the session CALL started (`harness-chat--child-id', which looks
in CALL and in RESULT), then the sessions its input refers to: its
`session_id', a reference as the session tools take one, and its
`session_ids', a list of them.  Any tool that is given sessions this way
-- session_read, session_send, session_wait, set_priority... -- names
them here.  Each reference is resolved against the session cache
\(`harness-ui-resolve-session'), so one that names no session, or
several, is left out, and so is the session this chat shows, which a
link would only lead back to."
  (let* ((input (plist-get call :input))
         (many (plist-get input :session_ids))
         (child (harness-chat--child-id call result))
         (ids (and child (list child))))
    (dolist (ref (cons (plist-get input :session_id)
                       (and (or (listp many) (vectorp many)) (append many nil))))
      (when-let* ((id (harness-ui-resolve-session ref)))
        (unless (equal id harness-ui-session-id)
          (cl-pushnew id ids :test #'equal))))
    (nreverse ids)))

(defun harness-chat--child-line (call result)
  "Return the line linking the sessions a tool call names, or \"\".
That is the sub-agent of a spawn_agent call, the `:child-id' in the
`:meta' of CALL or of RESULT: the merge queue's and the supervisor's
calls name their child from the start, and so does a model's
spawn_agent call from the moment its child exists.  It is also each
session the call's input refers to, such as the one session_read reads
or the ones session_wait waits for (`harness-chat--call-sessions').  One
session reads \"  session: NAME\", several \"  sessions: A, B\", each
name a session link (`harness-ui-session-link')."
  (if-let* ((ids (harness-chat--call-sessions call result)))
      (let ((child (harness-chat--child-id call result)))
        (concat (propertize (if (cdr ids) "  sessions: " "  session: ") 'face 'harness-dim-face)
                (mapconcat (lambda (id)
                             (let ((name (harness-chat--session-name
                                          id (and (equal id child)
                                                  (plist-get (plist-get call :input) :name)))))
                               (harness-ui-session-link id name (format "Open the session %s" name))))
                           ids (propertize ", " 'face 'harness-dim-face))
                "\n"))
    ""))

(defun harness-chat--note-lines (call)
  "Return the note under running CALL, dim and indented, or \"\".
The note is what the running turn's activity carries for the call's id:
a short report of what the call is doing -- a sub-agent's work, the
sessions a wait waits on, a long command's output -- which the harness
makes again as the call goes on (`harness-tools-watch-session')."
  (let* ((id (plist-get call :call-id))
         (note (and id harness-chat--notes (gethash id harness-chat--notes))))
    (if (and (stringp note) (not (string-blank-p note)))
        (mapconcat (lambda (line)
                     (concat (propertize "  " 'face 'harness-dim-face)
                             (propertize line 'face 'harness-dim-face)
                             "\n"))
                   (split-string note "\n")
                   "")
      "")))

(defun harness-chat--set-notes (activity)
  "Take the notes ACTIVITY carries and redraw the calls whose note changed.
The activity of a running `tool' phase carries `:calls', one plist per
running call, each with its `:note' when it has one (see
`agent/activity')."
  (let ((new (make-hash-table :test 'equal))
        (old (or harness-chat--notes (make-hash-table :test 'equal)))
        (changed nil))
    (dolist (call (append (plist-get activity :calls) nil))
      (let ((id (plist-get call :call-id))
            (note (plist-get call :note)))
        (when (and (stringp id) (stringp note) (not (string-blank-p note)))
          (puthash id note new))))
    (dolist (id (delete-dups (append (hash-table-keys old) (hash-table-keys new))))
      (unless (equal (gethash id old) (gethash id new))
        (push id changed)))
    (when (or changed (not harness-chat--notes))
      (setq harness-chat--notes new)
      (dolist (id changed)
        (when-let* ((block (gethash (gethash id harness-chat--calls) harness-chat--blocks)))
          (harness-chat--rerender block)
          (harness-chat--refresh-group-of block))))))

(defconst harness-chat--rerun-tool "rerun_approved"
  "Name of the tool that runs a denied call the user approved.
See `rerun_approved' in harness-perms.el.")

(defun harness-chat--denied-state (result)
  "Return what a refused call's RESULT node says of the user's approval, or nil.
RESULT is a tool result the permission system refused (`:meta'
`:denied').  Return (:approved BOOL :used BOOL), the flags the harness
wrote into its `:meta' when the user approved the call
\(`permission/approve-denied') and when the agent reran it
\(`rerun_approved').  nil for a call that ran, and one no harness
recorded."
  (let ((meta (and result (plist-get result :meta))))
    (when (harness-json-true-p (and meta (plist-get meta :denied)))
      (list :approved (harness-json-true-p (plist-get meta :approved))
            :used (harness-json-true-p (plist-get meta :used))))))

(defun harness-chat--approval-line (handle result)
  "Return the line of the user's approval of the denied call HANDLE, or \"\".
A refused call still waiting offers [Approve], which lets the agent run
it exactly as it was denied (`rerun_approved'); one the user approved
says so, and one already rerun says that."
  (when-let* ((state (harness-chat--denied-state result))
              (handle (and (stringp handle) (not (string-empty-p handle)) handle)))
    (concat
     "  "
     (cond
      ((plist-get state :used)
       (propertize "user-approved · rerun" 'face 'harness-dim-face))
      ((plist-get state :approved)
       (propertize "user-approved · the agent can rerun it" 'face 'harness-dim-face))
      (t (concat (harness-chat--button
                  "[Approve]"
                  (lambda () (harness-chat--approve-denied harness-ui-session-id handle))
                  :help "Let the agent run this call exactly as it was denied (rerun_approved)")
                 (propertize "  run this call exactly as it was denied" 'face 'harness-dim-face))))
     "\n")))

(defun harness-chat--approve-denied (session-id handle)
  "Approve the denied call HANDLE of SESSION-ID, for the user.
The harness marks the call approved and tells the session's agent to
rerun it unchanged with `rerun_approved'; the node the call is shown
from is updated, so the chat redraws it, and the echo area says how it
went."
  (harness-ui-call "_harness/permission/approve-denied"
                   (list :session-id session-id :handle handle)
                   (lambda (result) (message "%s" (or (plist-get result :message) "Approved")))))

(defun harness-chat--show-call (call-id)
  "Move point to the block of tool call CALL-ID, when the buffer shows it.
A run of calls the block was folded into opens, so the block is
visible.  Return non-nil when point moved."
  (let* ((node-id (gethash call-id harness-chat--calls))
         (block (and node-id (gethash node-id harness-chat--blocks))))
    (cond
     ((null block) (message "The call %s is not shown in this buffer" call-id) nil)
     (t (let ((gid (harness-chat-block-group block)))
          (when-let* ((group (and gid (gethash gid harness-chat--groups))))
            (unless (harness-chat-group-expanded group)
              (harness-chat-toggle-group gid))))
        (when-let* ((start (marker-position (harness-chat-block-start block))))
          (goto-char start)
          (ignore-errors (recenter))
          t)))))

(defun harness-chat--rerun-line (call result)
  "Return the line linking a rerun-approved CALL to the call it reran, or \"\".
CALL is the call's node, RESULT its result.  That is the call of
`rerun_approved' the harness ran in the user's stead: the line names the
tool the user approved and the handle, from the result's `:meta'
\(`:rerun-of', `:rerun-tool') or, for a result from before them, from
the call's own input.  The tool's name is a button that shows the
denied call's block where the buffer still has it."
  (let* ((meta (and result (plist-get result :meta)))
         (tool-name (or (plist-get call :tool) (and result (plist-get result :tool))))
         (handle (and (equal tool-name harness-chat--rerun-tool)
                      (or (plist-get meta :rerun-of)
                          (plist-get (plist-get call :input) :handle))))
         (denied (and (stringp handle)
                      (let* ((block (gethash (gethash handle harness-chat--calls) harness-chat--blocks)))
                        (plist-get (and block (harness-chat-block-node block)) :tool)))))
    (when (and (stringp handle) (not (string-empty-p handle)))
      (concat "  " (propertize "user-approved rerun of " 'face 'harness-dim-face)
              (harness-chat--button (or (plist-get meta :rerun-tool) denied "the denied call")
                                    (lambda () (harness-chat--show-call handle))
                                    :help (format "The user approved call %s; show it" handle))
              (propertize (format " · handle %s" handle) 'face 'harness-dim-face)
              "\n"))))

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
         (ask (and call-only (equal (plist-get node :tool) "ask_user")
                   (plist-get input :question)))
         (header (concat (harness-chat--fold-button (harness-chat-block-collapsed block)
                                                    (lambda () (interactive) (harness-chat-toggle-block id)))
                         " " (if ask
                                  (harness-ui-icon 'harness-icon-question)
                                (harness-ui-icon 'harness-icon-tool))
                         " "
                         (if ask
                             (propertize (harness-ui-tool-label "ask_user") 'face 'harness-tool-title-face)
                           (if call-only
                               (harness-ui-tool-title-string (plist-get node :tool) (plist-get node :title) 120)
                             (propertize title 'face 'harness-tool-title-face)))
                         "  " (harness-chat--tool-status result (and call-only node)) "\n"))
         (line (and input (harness-chat--input-summary input title)))
         (question (when ask
                     (propertize (harness-chat--ensure-newline
                                  (harness-chat--render-markdown (plist-get input :question)))
                                 'line-prefix indent 'wrap-prefix indent)))
         ;; Only what the user gave is their answer.  A call that failed
         ;; or was refused ends with an error or the permission system's
         ;; reason, which stay under the fold, and a dismissed question
         ;; with the harness's own words.
         (dismissed (and ask (eq outcome 'ok)
                         (equal (string-trim output) harness-chat--dismissed-answer)))
         (answer (when (and ask (eq outcome 'ok) (not dismissed) (not (string-blank-p output)))
                   (harness-chat--margin
                    (harness-chat--face
                     (concat (harness-chat--sender harness-chat-user-label 'harness-user-label-face)
                             ;; Typed, as a message in the box is: its
                             ;; line breaks are the user's.
                             (harness-chat--ensure-newline
                              (let ((harness-ui-markdown-hard-breaks t))
                                (harness-chat--render-markdown output))))
                     'harness-user-face)
                    'harness-user-face 'harness-user-bar-face)))
         ;; The block's last lines, after its details and outside the
         ;; fold, so a folded block still shows them.  Not above the fold:
         ;; a row is drawn to the window's edge in the face of the newline
         ;; that ends it, and the fold hides the newline before the
         ;; details (see `harness-chat--make-fold'), so the answer's last
         ;; row would end on the fold's own newline, in the tool's colour.
         (reply (cond (answer)
                      (dismissed (propertize "  dismissed\n" 'face 'harness-dim-face))
                      (t "")))
         ;; A session id in the call's input or output is a session link.
         (summary (concat (if ask
                              question
                            (if line
                                (concat (harness-ui-link-session-ids
                                         (propertize (concat "  " line) 'face 'harness-dim-face))
                                        "\n")
                              ""))
                          (harness-chat--child-line node result)
                          ;; A call a lasting decision's rule refused says
                          ;; which, with its undo, above the fold.
                          (harness-chat--decided-by-lines result "  " 'harness-dim-face)
                          (harness-chat--rerun-line node result)
                          (harness-chat--approval-line (plist-get result :call-id) result)
                          (harness-chat--note-lines node)))
         ;; What the user is shown of the result -- an image, a video
         ;; poster, an audio player -- stays above the fold: a folded
         ;; tool call still shows the picture it read.
         (media (and result (mapconcat #'harness-chat--attachment-string
                                       (plist-get result :attachments) "")))
         (details
          (or (run-hook-with-args-until-success 'harness-chat-tool-body-functions block result)
              (concat
               (if input (concat (propertize "  input\n" 'face 'harness-label-face)
                                 (propertize (harness-ui-link-session-ids (harness-chat--input-listing input))
                                             'line-prefix indent 'wrap-prefix indent))
                 "")
               (cond
                ;; A question's answer, or its dismissal, is the block's
                ;; reply, after the fold and outside it; the error of one that
                ;; failed and the reason of one refused fold as any call's do.
                ((and ask (not (memq outcome '(failed denied)))) "")
                ((null result) "")
                ((string-empty-p output) (propertize "  (no output)\n" 'face 'harness-dim-face))
                ;; A refused call never ran: its text is the permission
                ;; system's reason, not output.
                (t (concat (propertize (if (eq outcome 'denied)
                                           "  reason\n"
                                         (format "  output (%s chars)\n" (harness-format-tokens (length output))))
                                       'face 'harness-label-face)
                           (harness-ui-link-session-ids
                            (propertize (harness-chat--ensure-newline shown) 'face 'harness-ui-output-face
                                        'line-prefix indent 'wrap-prefix indent))
                           (if long
                               (concat "  " (harness-chat--button
                                             (format "show all (%d more chars)" (- (length output) limit))
                                             (lambda () (harness-chat--show-all id)))
                                       "\n")
                             ""))))))))
    (harness-chat--margin
     (harness-chat--face (concat header summary media (harness-chat--foldable details) reply) bg)
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
  "Return the body of hint BLOCK.
A note that tells of a lasting decision (`harness-node-decision') -- a
permission answer for the session or always, the cold-cache question
answered \"always\" -- ends in the decision's one button: [Undo] while
what it set is in effect, [Redo], its text struck through, once it was
undone.  Once the decision ended -- what it set was changed since by
something else, or is gone -- the note says so under it, with no
button.  Where the decision stands is what the harness last announced
of it, from whichever session moved it (harness-ui-decisions.el); see
`harness-chat--decision-state' for when the UI has not heard of it.  A
note written where a decision took effect, perhaps in another session,
names the decision on a line of its own, with the same button
\(`harness-chat--decided-by-lines').  A permission note written before
decisions were kept (`harness-node-permission' without a decision)
offers [Undo] alone, and says how that went: struck through when
undone, else with the reason under it.  The note that says how a new
session's opening message was judged (see `harness-node-supervisor')
carries the two things to do about the choice as buttons."
  (let* ((node (harness-chat-block-node block))
         (text (string-trim (or (plist-get node :content) "")))
         (record (harness-node-permission node))
         (id (harness-node-decision node))
         (decision (harness-chat--decision id))
         (state (if id
                    (harness-chat--decision-state decision record)
                  (harness-permission-undo-state record)))
         (judged (harness-node-supervisor node)))
    (harness-chat--margin
     (propertize
      (concat (propertize "    " 'face 'harness-hint-face)
              (propertize text 'face (if (eq state 'undone) 'harness-chat-undone-face 'harness-hint-face))
              (cond
               (judged (concat "  " (harness-chat--supervisor-buttons node judged)))
               (id (harness-chat--decision-tail id decision state record "    " 'harness-hint-face))
               ((eq state 'offered) (concat "  " (harness-chat--undo-button (plist-get node :id) record)))
               ((eq state 'undone) (propertize "  undone" 'face 'harness-hint-face 'help-echo (plist-get record :result)))
               ;; A note of an answer that recorded nothing new has no
               ;; state, and nothing to say under it.
               ((and record state)
                (propertize (format "\n    %s" (or (plist-get record :result) state)) 'face 'harness-hint-face)))
              (propertize "\n" 'face 'harness-hint-face)
              (harness-chat--decided-by-lines node "    " 'harness-hint-face))
      'wrap-prefix "    "))))

(defun harness-chat--permission-undo-help (record)
  "Return the tooltip of the [Undo] of a note of lasting permission answer RECORD.
It says that undoing leaves the call the answer answered as it was."
  (let ((denied (and (not (stringp (plist-get record :dir)))
                     (equal "deny" (format "%s" (plist-get (plist-get record :rule) :behavior))))))
    (format "Take back what this answer recorded; the call it answered stays %s"
            (if denied "denied" "allowed"))))

(defun harness-chat--undo-button (node-id record)
  "Return the [Undo] button of note NODE-ID, which tells of lasting answer RECORD.
That is the note of an answer given before the harness kept decisions,
which `permission/undo' takes back by the note."
  (let ((sid harness-ui-session-id))
    (harness-chat--button "[Undo]" (lambda () (harness-chat--undo-permission sid node-id))
                          :help (harness-chat--permission-undo-help record))))

(defun harness-chat--undo-permission (session-id node-id)
  "Undo the lasting permission answer that note NODE-ID of SESSION-ID tells of.
The harness removes what the answer recorded while it is still as the
answer left it (`permission/undo'); the echo area says how that went,
and the note changes when the harness updates it.  A harness that keeps
decisions keeps the answer as one from then on, which it answers with:
the UI's cache takes it at once, so the note offers its redo."
  (harness-ui-call "_harness/permission/undo" (list :session-id session-id :node-id node-id)
                   (lambda (result)
                     (when (and (plist-get result :decision) (fboundp 'harness-ui-decisions-store))
                       (harness-ui-decisions-store (plist-get result :decision)))
                     (message "%s" (or (plist-get result :message) "Undone")))))

;;;; Lasting decisions in notes

(defun harness-chat--decision (id)
  "Return the lasting decision ID as the UI last heard of it, or nil.
Nil too for no ID, and when the UI keeps no decisions: its decisions
module (harness-ui-decisions.el) is not loaded."
  (and id (fboundp 'harness-ui-decision) (harness-ui-decision id)))

(defun harness-chat--decision-state (decision record)
  "Return where the decision a note tells of stands, a symbol, or nil.
DECISION is the decision as the UI last heard of it, which says:
`done', `undone', `changed' or `gone'.  When the UI has not heard of it
\(DECISION nil), a permission note's RECORD says, as the harness keeps
its `:undo' in step with the decision: `offered' while it is in
effect, then `undone', `changed' or `gone'.  A note of another kind
says nothing, and its decision offers nothing until the UI hears of it."
  (if decision
      (harness-decision-state (plist-get decision :state))
    (let ((undo (harness-permission-undo-state record)))
      (if (eq undo 'offered) 'done (harness-decision-state undo)))))

(defun harness-chat--decision-tail (id decision state record indent face)
  "Return what ends a line naming decision ID: its button, or how it ended.
STATE is where the decision stands (`harness-chat--decision-state'):
`done' ends the line in [Undo], `undone' in [Redo].  `changed' and
`gone' put what the decision's last move said -- DECISION's `:result',
else RECORD's, the permission note's own -- on a line of its own,
INDENT first, in FACE.  Any other STATE adds nothing."
  (pcase state
    ((or 'done 'undone)
     (concat "  " (harness-chat--decision-button id state (harness-chat--decision-help id state record))))
    ((or 'changed 'gone)
     (propertize (concat "\n" indent
                         (or (cl-find-if (lambda (s) (and (stringp s) (not (string-blank-p s))))
                                         (list (plist-get decision :result) (plist-get record :result)))
                             (if (eq state 'gone) "No longer there" "Changed since")))
                 'face face))
    (_ "")))

(defun harness-chat--decision-help (id state record)
  "Return the tooltip of the button decision ID offers in STATE.
A permission note's RECORD says what its [Undo] leaves of the call it
answered, as the note of an earlier answer does; otherwise the
decision's kind says (`harness-ui-decision-help')."
  (let ((way (if (eq state 'done) 'undo 'redo)))
    (cond ((and record (eq way 'undo)) (harness-chat--permission-undo-help record))
          (record "Record this answer again")
          ((fboundp 'harness-ui-decision-help) (harness-ui-decision-help id way))
          ((eq way 'undo) "Take this decision back")
          (t "Make this decision again"))))

(defun harness-chat--decision-button (id state help)
  "Return the button of decision ID in STATE, or \"\".
It is [Undo] while STATE is `done' and [Redo] while it is `undone',
HELP its tooltip; a click moves the decision that way
\(`harness-chat--move-decision')."
  (pcase state
    ('done (harness-chat--button "[Undo]" (lambda () (harness-chat--move-decision id 'undo)) :help help))
    ('undone (harness-chat--button "[Redo]" (lambda () (harness-chat--move-decision id 'redo)) :help help))
    (_ "")))

(defun harness-chat--move-decision (id way)
  "Ask the harness to move decision ID one step WAY, `undo' or `redo'.
It moves whichever session made it.  The echo area says how that
went, and every note that refers to the decision is drawn again once
the harness announces it (`harness-chat--on-decision').  Without the
UI's decisions module the request is made from here, and the notes
follow what the harness writes into them."
  (cond
   ((and (eq way 'undo) (fboundp 'harness-decision-undo)) (harness-decision-undo id))
   ((and (eq way 'redo) (fboundp 'harness-decision-redo)) (harness-decision-redo id))
   (t (harness-ui-call (format "_harness/decision/%s" way) (list :id id)
                       (lambda (result)
                         (message "%s" (or (plist-get result :message)
                                           (if (eq way 'undo) "Undone" "Redone"))))))))

(defun harness-chat--struck (face)
  "Return FACE struck through, as the text of an undone decision is drawn."
  (if (eq face 'harness-hint-face) 'harness-chat-undone-face (list '(:strike-through t) face)))

(defun harness-chat--decided-by-lines (node indent face)
  "Return the lines naming the lasting decision NODE follows from, or \"\".
NODE is a hint or a tool result written where a decision took effect,
perhaps in another session -- a cold cache compacted unasked as its
default says, a call its rule refused -- whose `:meta' `:decided-by'
names the decision (`harness-node-decided-by').  The line is
\"decided by: \", the decision's text and its button: [Undo] while it
is in effect, [Redo], the text struck through, once undone.  Once it
ended, what its last move said follows on a line of its own.  INDENT
starts each line, FACE draws them.  Nothing when the UI has not heard
of the decision."
  (let* ((id (and node (harness-node-decided-by node)))
         (decision (harness-chat--decision id))
         (state (and decision (harness-decision-state (plist-get decision :state))))
         (text (and decision (plist-get decision :text))))
    (if (not (and state (stringp text) (not (string-blank-p text))))
        ""
      (concat (propertize (concat indent "decided by: ") 'face face)
              (propertize (string-trim text) 'face (if (eq state 'undone) (harness-chat--struck face) face))
              (harness-chat--decision-tail id decision state nil indent face)
              (propertize "\n" 'face face)))))

(defun harness-chat--decision-ids (block)
  "Return the ids of the lasting decisions BLOCK's notes refer to.
That is the decision its node tells of or follows from, and the one
its tool result follows from."
  (let ((node (harness-chat-block-node block))
        (result (harness-chat-block-result block)))
    (delq nil (list (harness-node-decision node) (harness-node-decided-by node)
                    (and result (harness-node-decided-by result))))))

(defun harness-chat--on-decision (id _decision)
  "Draw again, in every chat buffer, the blocks that refer to decision ID.
On `harness-ui-decision-functions': the decision was kept, named its
note, or was undone or redone, from any session.  ID nil means every
decision was fetched again, so every block that refers to one is
drawn.  A block is drawn once, though its tool result's id finds it
too, and the summary of the group it is folded into follows.  A buffer
loading its transcript is left alone: it draws its blocks from the
decisions as they are once it renders them."
  (dolist (buf (hash-table-values harness-chat--buffers))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (and harness-chat--blocks (not harness-chat--loading))
          (let ((blocks nil))
            (maphash (lambda (_ block)
                       (let ((ids (harness-chat--decision-ids block)))
                         (when (if id (member id ids) ids)
                           (cl-pushnew block blocks :test #'eq))))
                     harness-chat--blocks)
            (dolist (block blocks)
              (when (and (markerp (harness-chat-block-start block))
                         (marker-buffer (harness-chat-block-start block)))
                (harness-chat--rerender block)
                (harness-chat--refresh-group-of block)))))))))

(defun harness-chat--supervisor-buttons (node record)
  "Return the buttons of the session judge's note NODE, RECORD being its record.
Each of the note's actions (`harness-node-supervisor') is one button:
the action itself while it was not taken, [undo: it] once it was, and
[redo: it] once it was taken back again.  Clicking or RET on one asks
the harness to move it on, and the note is redrawn with what it did."
  (mapconcat
   (lambda (action)
     (let* ((name (format "%s" (plist-get action :action)))
            (label (format "%s" (or (plist-get action :label) name)))
            (state (plist-get action :state)))
       (harness-chat--button
        (format "[%s%s]" (pcase state ('done "undo: ") ('undone "redo: ") (_ "")) label)
        (lambda () (harness-chat--supervisor-act (plist-get node :id) name))
        :help (pcase state
                ('done "Take this back")
                ('undone "Do it again")
                (_ (plist-get action :help))))))
   (plist-get record :actions)
   " "))

(defun harness-chat--supervisor-act (node-id action)
  "Ask the harness to move ACTION of the judge's note NODE-ID on.
The harness does what the action says -- stop judging new sessions, or
put this session in the other mode -- or takes it back when it was done
\(`supervisor/act'), and updates the note, which the chat draws with its
undo, or its redo once undone.  The echo area says what happened."
  (harness-ui-call "_harness/supervisor/act"
                   (list :session-id harness-ui-session-id :node-id node-id :action action)
                   (lambda (result) (message "%s" (or (plist-get result :message) "Done")))))

(defun harness-chat--render-compaction (block)
  "Return the body of compaction BLOCK.
A summary made to hand the conversation over to a model of another
provider says which (see `harness-node-handoff').  Otherwise the header
says what kind of compaction it was (`harness-node-compaction-kind'): a
brief summary names the model that wrote it, a transcript file offers
to open the file, a fresh start says so, and a cut old context says the
oldest of it went.  One made because a message met a cold prompt cache
\(harness-cowboy.el) says that too."
  (let* ((id (harness-chat-block-id block))
         (node (harness-chat-block-node block))
         (content (or (plist-get node :content) ""))
         (handoff (harness-node-handoff node))
         (kind (harness-node-compaction-kind node))
         (meta (plist-get node :meta))
         (file (and (equal kind "transcript") (plist-get meta :file)))
         (header (concat (harness-chat--fold-button (harness-chat-block-collapsed block)
                                                    (lambda () (interactive) (harness-chat-toggle-block id)))
                         " "
                         (propertize (format "%s context compacted%s%s (%d words)"
                                             (harness-ui-icon 'harness-chat-icon-compaction)
                                             (cond
                                              (handoff
                                               (format " to hand over to %s"
                                                       (harness-ui-model-label (plist-get handoff :to))))
                                              ((equal kind "brief")
                                               (format " into a brief summary by %s"
                                                       (harness-ui-model-label (plist-get meta :model))))
                                              ((equal kind "transcript") " into a transcript file")
                                              ((equal kind "fresh") " to start afresh")
                                              ((equal kind "truncate") " by cutting its oldest context away")
                                              (t ""))
                                             (if (consp (plist-get meta :cowboy))
                                                 ", the prompt cache being cold"
                                               "")
                                             (harness-chat--words content))
                                     'face 'harness-summary-face)
                         (if (and (stringp file) (not (string-empty-p file)))
                             (concat "  "
                                     (harness-chat--button "[open the transcript]"
                                                           (lambda () (find-file-other-window file))
                                                           :help (format "Open %s" file)))
                           "")
                         "\n"))
         (body (harness-chat--foldable
                (concat (harness-chat--face (harness-chat--ensure-newline
                                             (harness-chat--render-markdown (harness-chat--page block)))
                                            'harness-thinking-face)
                        (harness-chat--more-line block)))))
    (harness-chat--margin (concat header body))))

(defun harness-chat--render-plan (block)
  "Return the body of plan BLOCK."
  (let ((body (concat (harness-chat--label 'harness-chat-icon-plan "plan")
                      (harness-chat--ensure-newline
                       (harness-chat--render-markdown (harness-chat--page block)))
                      (harness-chat--more-line block))))
    (harness-chat--margin (harness-chat--face body 'harness-chat-plan-face) 'harness-chat-plan-face)))

(defun harness-chat--render-error (block)
  "Return the body of local error BLOCK."
  (harness-chat--margin
   (propertize (concat (harness-ui-icon 'harness-icon-warning) " "
                       (harness-chat--page block) "\n"
                       (harness-chat--more-line block))
               'face 'error)))

(defun harness-chat--render-failed (block err)
  "Return the body of BLOCK, whose renderer signalled ERR, as plain text.
A block that cannot be rendered must not take the rest of the buffer
down with it: the transcript below it and the compose box still draw."
  (let* ((node (harness-chat-block-node block))
         (text (harness-chat--page block)))
    (harness-chat--margin
     (concat (harness-chat--plain (if (string-empty-p text)
                                      (or (plist-get node :title) (format "[%s]" (harness-chat-block-kind block)))
                                    text))
             (harness-chat--more-line block)
             (propertize (format "(shown unformatted: rendering failed with %s)\n"
                                 (harness-error-short-message err))
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
It counts the calls by label, then the thinking folded between them.
A run of one call names it as its header does, label and subject:
\"1 tool call: Read file x.el\"."
  (let* ((gid (harness-chat-group-id group))
         (calls (harness-chat--group-calls group))
         (names (mapcar (lambda (b) (harness-ui-tool-label (plist-get (harness-chat-block-node b) :tool)))
                        calls))
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
             (propertize (format "%s %d tool call%s: %s%s" (harness-ui-icon 'harness-icon-tool) (length names)
                                 (if (= (length names) 1) "" "s")
                                 (if (= (length calls) 1)
                                     ;; What the lone call is about, as its
                                     ;; own header would say it.
                                     (let ((node (harness-chat-block-node (car calls))))
                                       (substring-no-properties
                                        (harness-ui-tool-title-string (plist-get node :tool)
                                                                      (plist-get node :title) 100)))
                                   (mapconcat (lambda (c) (if (> (cdr c) 1) (format "%s ×%d" (car c) (cdr c)) (car c)))
                                              counts ", "))
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
                      (_ (let ((text (harness-chat--page block)))
                           (harness-chat--margin
                            (concat (harness-chat--plain (if (string-empty-p text)
                                                             (format "[%s]" kind)
                                                           text))
                                    (harness-chat--more-line block))))))
                  (error (harness-chat--render-failed block err)))))
         (text (concat (cond ((harness-chat-block-group block) "")
                             ((harness-chat--outside-header block))
                             ((harness-chat-block-head block) (harness-chat--agent-header))
                             (t ""))
                       body "\n")))
    (add-text-properties 0 (length text)
                         (list 'harness-chat-node (harness-chat-block-id block) 'read-only t 'rear-nonsticky t)
                         text)
    ;; A call that started a sub-agent opens its session from anywhere on
    ;; the block, not only from its session line: mouse-1 or RET on the
    ;; title, the input, the output.  Buttons keep their own keys.  The
    ;; action is the session link's, so the block opens the sub-agent in
    ;; its project as the session line does.
    (when-let* ((child (harness-chat--block-child block)))
      (harness-ui-add-session-keys
       text child
       (harness-chat--session-name
        child (plist-get (plist-get (harness-chat-block-node block) :input) :name))
       nil nil (harness-ui-session-action child)))
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
    ("_harness/node" (harness-chat--on-node (plist-get update :node))
                     ;; A message of the user's may steer the turn that goes on.
                     (when (equal (harness-chat--str (plist-get (plist-get update :node) :kind)) "user")
                       (harness-chat--refresh-sending)))
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
      (harness-chat--rerender block)
      ;; The summary of a run of one call shows the call's title.
      (when (equal kind "tool-call")
        (harness-chat--refresh-group-of block)))
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
                       "\n" ""))
             ;; Only the page is drawn: the rest waits behind the block's
             ;; button (see `harness-chat--message-limit'), which the next
             ;; re-render draws.  Appending it all would put the enormous
             ;; message in the buffer regardless.
             (room (max 0 (- (harness-chat--page-limit block) (length before) (length lead))))
             (text (if (or (zerop room) (string-empty-p delta))
                       ""
                     (concat lead (substring delta 0 (min room (length delta)))))))
        (setf (harness-chat-block-streamed block) t
              (harness-chat-block-content block) (concat before delta))
        (unless (string-empty-p text)
          (harness-chat--append-delta block text
                                      (if (equal kind "thinking") 'harness-thinking-face 'harness-agent-face)))
        (harness-chat--schedule-render block))))))

(defun harness-chat--on-session (session)
  "React to a fresh SESSION plist."
  (let ((status (plist-get session :status))
        (was-running harness-chat--turn-start)
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
    ;; A turn began or ended: the notes on the messages that steer it follow.
    (unless (eq (and was-running t) (and harness-chat--turn-start t))
      (harness-chat--refresh-sending))
    ;; The pending module owns the requests; it calls back to redraw the tail
    ;; when they change (see `harness-chat--on-pending-changed').
    (harness-ui-pending-sync (plist-get session :id) (plist-get session :pending))
    ;; Entering or leaving `inactive' shows or hides the notice above the box.
    (unless (eq (equal status "inactive") harness-chat--inactive)
      (setq harness-chat--inactive (equal status "inactive") changed t))
    (unless (equal (plist-get session :queue) harness-chat--queue)
      (setq harness-chat--queue (plist-get session :queue) changed t))
    ;; The queue's buttons say what sending now does, and a turn running changes it.
    (when (harness-chat--queue-stale-p)
      (setq changed t))
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
        ("agent/turn-started" (setq harness-chat--turn-start (float-time)) (harness-chat--start-spinner)
                              (harness-chat--turn-changed))
        ("agent/turn-ended" (setq harness-chat--turn-start nil)
                            (harness-chat--turn-changed))
        ("session/head-moved" (harness-chat--load t)))
      (force-mode-line-update))))

(defun harness-chat--turn-changed ()
  "Draw again what depends on a turn running, as one begins or ends.
That is the notes on the messages that steer it, and the queue, whose
buttons say what sending a message now does."
  (harness-chat--refresh-sending)
  (when (harness-chat--queue-stale-p)
    (harness-chat--render-tail)))

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

(defun harness-chat--answer-question (pid answer &optional attachments)
  "Answer question PID of this session with ANSWER.
ATTACHMENTS, the files attached to it in the box, go with it to the
model (see `harness-ui-pending-answer-question')."
  (harness-ui-pending-answer-question harness-ui-session-id pid answer nil attachments))

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

(defun harness-chat-approve-denied-call ()
  "Approve the denied call whose block point is on.
The user's approval lets the session's agent run that call exactly as
it was denied, with `rerun_approved', which the harness tells it; the
call's block offers the same as its [Approve] button.  A block that is
no call the permission system refused, or one the user already
approved, is not something to approve."
  (interactive)
  (let* ((id (get-text-property (point) 'harness-chat-node))
         (block (and id (gethash id harness-chat--blocks)))
         (node (and block (harness-chat-block-node block)))
         (result (and block (if (equal (harness-chat-block-kind block) "tool-call")
                                (harness-chat-block-result block)
                              node)))
         (handle (or (plist-get result :call-id) (plist-get node :call-id)))
         (state (and result (harness-chat--denied-state result))))
    (unless (and handle state)
      (user-error "No call the permission system refused is here"))
    (when (plist-get state :approved)
      (user-error "The user already approved that call"))
    (harness-chat--approve-denied harness-ui-session-id handle)))

(defun harness-chat-next-diagram (&optional n)
  "Show the diagram of the next option of the question waiting with diagrams.
With prefix argument N, move N options on; a negative N moves back."
  (interactive "p")
  (harness-ui-pending-next-diagram n))

(defun harness-chat-previous-diagram (&optional n)
  "Show the diagram of the previous option of the question waiting with diagrams.
With prefix argument N, move N options back."
  (interactive "p")
  (harness-ui-pending-previous-diagram n))

(defun harness-chat--on-pending-changed (sid)
  "Mirror the requests of session SID and redraw the tail showing them.
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

;;;; The tail: queue, panel, attachments, compose

(defun harness-chat--queue-stale-p ()
  "Non-nil when the queue was drawn for a turn running or not, and that changed.
Its buttons say what sending a message now does, which depends on it."
  (and harness-chat--queue
       (not (eq harness-chat--queue-running (and harness-chat--turn-start t)))))

(defun harness-chat--queued-block (item)
  "Return the block that draws queued ITEM: the user block it will be once sent.
Its node is ITEM as `harness-queued-message-node' reads it, the id
ITEM's.  An item drawn before keeps the part of a long message it
showed (`harness-chat--queued-blocks')."
  (let ((block (harness-chat--new-block (harness-queued-message-node item)))
        (old (and harness-chat--queued-blocks
                  (gethash (plist-get item :id) harness-chat--queued-blocks))))
    (when old
      (setf (harness-chat-block-shown block) (harness-chat-block-shown old)))
    block))

(defun harness-chat--queued-note (qid running)
  "Return what the sender line of queued message QID says after the name.
Its state, \"queued\", after a grey circle (the yellow one of \"sent\"
and the green one of \"delivered\" come after it, as
`harness-chat--delivery-note' draws them), then its buttons: [send now]
sends it at once, the others staying queued; [edit] takes it back into
the box; [×] drops it.  RUNNING says whether a turn runs, which the
tooltip of [send now] follows: sent now, the message steers that turn,
which gives it to the model at its next step, or is a turn of its own."
  (concat (propertize (harness-ui-icon 'harness-icon-caution) 'face 'harness-dim-face)
          " "
          (propertize "queued" 'face 'harness-dim-face
                      'help-echo "Not sent yet: the model does not have this message")
          "  "
          (harness-chat--button "[send now]" (lambda () (harness-chat-send-queued qid))
                                :help (if running
                                          "Send this message now: the running turn gets it at its next step. The others stay queued"
                                        "Send this message now, as a turn of its own. The others stay queued"))
          " "
          (harness-chat--button "[edit]" (lambda () (harness-chat-edit-queued qid)) :help "Edit this message")
          " "
          (harness-chat--button "[×]" (lambda () (harness-chat-remove-queued qid)) :help "Remove from the queue")))

(defun harness-chat--insert-queue ()
  "Insert the queued messages, each as the user message it will be.
They come first under the transcript, the newest messages of the
conversation, and the activity line goes under them
\(`harness-chat--activity-position').  A queued message is drawn by the
code that draws the user's messages in the transcript
\(`harness-chat--render-user'), from the block it will be once sent
\(`harness-chat--queued-block'): the name, the bar and the background,
the text and its references, the attachments.  Only its sender line
differs: after the name it says it is queued and has its buttons
\(`harness-chat--queued-note').  A blank line follows each, as it
follows a block of the transcript.  The queue is marked
`harness-chat-queue', and each message `harness-chat-queued', its id:
point anywhere on a message finds it (`harness-chat--queued-at-point')."
  (let ((blocks (make-hash-table :test 'equal))
        (running (and harness-chat--turn-start t))
        (start (point)))
    (setq harness-chat--queue-running running)
    (dolist (item harness-chat--queue)
      (let* ((qid (plist-get item :id))
             (block (harness-chat--queued-block item))
             (note (harness-chat--queued-note qid running))
             (text (concat (condition-case err
                               (harness-chat--render-user block note)
                             ;; Drawn unformatted, it keeps its buttons.
                             (error (concat (harness-chat--margin (concat harness-chat-user-label "  " note "\n"))
                                            (harness-chat--render-failed block err))))
                           "\n")))
        (puthash qid block blocks)
        ;; Point anywhere on the message, [send now] by keyboard or `M-x', finds it.
        (put-text-property 0 (length text) 'harness-chat-queued qid text)
        (insert text)))
    (when (> (point) start)
      (put-text-property start (point) 'harness-chat-queue t))
    (setq harness-chat--queued-blocks blocks)))


;;;; The todo list

;; The agent replaces the session's plan with every `todo_write' call;
;; the harness emits `session/todos' for it, and ACP announces the same
;; list as a plan update.  The chat renders it from that data, never by
;; reading a tool block (those fold, and at work the list is the point):
;; a panel above the compose box with the progress and one line and a
;; status icon per item, which folds away to the progress and the item
;; in hand, or disappears with the list.  The header line leaves it to
;; the panel, right above the box.

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
folded panel names it."
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
    (harness-chat--render-tail)))

(defun harness-chat--todo-mark (status)
  "Return (ICON . FACE) marking a todo in STATUS."
  (pcase status
    ("done" '(harness-icon-success . harness-success-face))
    ("in-progress" '(harness-icon-running . harness-status-running-face))
    (_ '(harness-icon-idle . harness-dim-face))))

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
  (harness-chat--render-tail))

(defvar harness-chat-top-functions nil
  "Functions putting something at the top of the tail, first below the transcript.
Each is called without arguments in the chat buffer on every render of
the tail and returns a string of whole lines, or nil for nothing.  The
strings go in order, read-only and without the panel background, above
the activity line, the pending requests, the queue, the todo list and
the panels: what they draw stands on whichever of those comes first,
or on the compose box when none shows.  A function that signals an
error draws nothing: what it draws is decoration, which must not take
the compose box down with it.  Add to it buffer-locally, with a symbol,
so a reload redefines it.  The companion pet sits there this way.")

(defun harness-chat--insert-top ()
  "Insert what `harness-chat-top-functions' return, in order, as they are.
Unlike a panel's (`harness-chat--insert-panels'), a string gets no
background of its own: what it draws keeps the window's.  A string that
does not end in a newline gets one, so the top is whole lines.  All of
it is marked `harness-chat-top', which is how the activity line finds
where it ends (`harness-chat--activity-position').  A function cannot
move point, where its lines go: it may measure text in a window, which
takes the window's point.  One that signals an error draws nothing."
  (let ((start (point)))
    (run-hook-wrapped 'harness-chat-top-functions
                      (lambda (fn)
                        (when-let* ((text (ignore-errors (save-excursion (funcall fn)))))
                          (unless (string-empty-p text)
                            (insert text)
                            (unless (eq (char-before) ?\n) (insert "\n"))))
                        nil))
    (when (> (point) start)
      (put-text-property start (point) 'harness-chat-top t))))

(defvar harness-chat-panel-functions nil
  "Functions putting a panel of their own below the transcript.
Each is called without arguments in the chat buffer on every render of
the tail and returns a string, or nil for nothing.  The strings go
between the queue and the attachments, in order, read-only and above
the compose box.  Add to it buffer-locally, with a symbol, so a reload
redefines it.  The task module shows its review banner this way.")

(defvar harness-chat-tool-body-functions nil
  "Functions giving a tool call block a body of their own.
Each is called with the BLOCK and its result node in the chat buffer and
returns a string to show in place of the call's input and output, or nil
to let the generic rendering show them.  The header, the one-line
summary, the status and the fold stay the chat's either way.  The report
module shows the report a hand_in call handed in this way.")

(defun harness-chat--insert-panels ()
  "Insert what `harness-chat-panel-functions' return, in order.
Each string gets the panel background, which its own properties may
override, as the pending panel's do.  A function cannot move point,
where its panel goes: it may measure text in a window, which takes the
window's point."
  (run-hook-wrapped 'harness-chat-panel-functions
                    (lambda (fn)
                      (when-let* ((text (save-excursion (funcall fn))))
                        (unless (string-empty-p text)
                          (insert (harness-chat--face text 'harness-chat-panel-face))))
                      nil)))


(defun harness-chat--box-help ()
  "Return the tooltip of the compose box's prompt: its keys, in brief.
The box's key for a panel's keys (`harness-compose-panel-key') is named
as the box binds it, with the example of a panel's key after it, as the
tooltips of the task board's box and a popout's name it.  Attaching
takes a task as well as a file (task:ID)."
  (concat "C-c C-c sends, RET newline, C-c C-q queues, C-c C-k cancels, "
          "C-c C-a attaches a file or task, C-c > quotes, "
          (harness-compose-panel-keys) " KEY: a key of the panel above"))

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
        ;; First: what `harness-chat-top-functions' draw, so it stands on
        ;; whatever comes next, then the queued messages, which read as the
        ;; newest of the conversation.
        (harness-chat--insert-top)
        (harness-chat--insert-queue)
        (harness-ui-pending-insert-panels harness-ui-session-id)

        (harness-chat--insert-todos)
        (harness-chat--insert-panels)

        (harness-compose-insert-attachments)
        (when harness-chat--dead
          (insert (propertize " This session was deleted; the transcript stays readable.\n" 'face 'harness-hint-face)))
        (when (and harness-chat--inactive (not harness-chat--dead))
          (insert (propertize " This session is inactive. Sending a message resumes it.\n" 'face 'harness-hint-face)))
        (put-text-property start (point) 'read-only t)
        (harness-compose-insert nil (harness-chat--box-help))))
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
    ;; The new tail went in where the activity line was: put it back,
    ;; under the queued messages and above the rest.
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
        harness-chat--sending nil
        harness-compose-start nil
        harness-compose-end nil
        harness-chat--transcript-start (copy-marker (point-max))
        harness-chat--transcript-end (copy-marker (point-max))))

(defun harness-chat--render-nodes (nodes)
  "Render NODES (oldest first) as the whole transcript."
  (harness-compose-capture)
  (harness-chat--reset-buffer)
  (unwind-protect
      (progn
        (let ((harness-chat--batch t))
          (dolist (node nodes)
            (harness-chat--on-node node))
          (harness-chat--regroup))
        ;; Only the whole transcript tells which messages the turn at its
        ;; end sent; nothing scrolls, the tail is drawn next.
        (let ((harness-chat--batch t))
          (harness-chat--redraw-sending)))
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
                             (harness-chat--schedule-history))
                           ;; The node to show may be on this page, or an older one.
                           (harness-chat--goto-pending))))
                     (lambda (err)
                       (when (buffer-live-p buf)
                         (with-current-buffer buf
                           (setq harness-chat--fetching nil)
                           (when harness-chat--goto
                             (setq harness-chat--goto nil)
                             (message "Could not load the earlier messages: %s" (harness-error-message err)))))))))

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

;;;; Going to a node
;;
;; A search's hit, or a row of the conversation tree, opens its session
;; at a node.  The buffer may still be loading, and it renders only the
;; newest nodes: the node waits in `harness-chat--goto' until the
;; transcript has loaded, then older pages load until it is rendered.
;; A node off the session's current branch is on none of them: the
;; search ends there, and says so.

(defun harness-ui-chat-goto-node (node-id &optional session-id regexp)
  "Show node NODE-ID in the chat buffer of session SESSION-ID.
SESSION-ID defaults to the current buffer's session.  Point goes to the
node once it is rendered, which may take a load and pages of older
history; a group or a fold that hides it opens.  With REGEXP, an Emacs
regexp, point goes to its first match in the node instead, and its
matches there are highlighted until the next command.  Return the chat
buffer, or nil when the session has none open."
  (when-let* ((buf (if session-id
                       (harness-chat--buffer-for session-id)
                     (and (derived-mode-p 'harness-chat-mode) (current-buffer)))))
    (with-current-buffer buf
      (setq harness-chat--goto (list :id node-id :regexp regexp))
      (harness-chat--goto-pending))
    buf))

(defun harness-chat--goto-pending ()
  "Show the node `harness-chat--goto' waits for, once it is rendered.
Load the page of history before the oldest rendered node until it is;
with none left, give up and say so.  A load or a page on its way calls
this again once it is rendered."
  (when-let* ((goto harness-chat--goto))
    (let ((id (plist-get goto :id)))
      (cond
       ((or harness-chat--loading harness-chat--fetching))
       ((and harness-chat--blocks (gethash id harness-chat--blocks))
        (setq harness-chat--goto nil)
        (harness-chat--show-node id (plist-get goto :regexp)))
       ((and harness-chat--has-more harness-chat--order) (harness-chat--load-earlier))
       (t (setq harness-chat--goto nil)
          (message "%s" (substitute-command-keys
                         "That message is not on this session's current branch: \
the tree (\\[harness-tree]) shows every branch")))))))

(defun harness-chat--show-node (id &optional regexp)
  "Put point on the block of node ID, opening what hides it, in sight.
With REGEXP, point goes to its first match in the block, and the
matches are highlighted until the next command."
  (let* ((block (gethash id harness-chat--blocks))
         (group (and (harness-chat-block-group block)
                     (gethash (harness-chat-block-group block) harness-chat--groups))))
    (when (and group (not (harness-chat-group-expanded group)))
      (harness-chat-toggle-group (harness-chat-group-id group)))
    (when (and (harness-chat-block-fold block) (harness-chat-block-collapsed block))
      (harness-chat-toggle-block (harness-chat-block-id block)))
    (let* ((found (lambda () (harness-chat--highlight-found
                              regexp (harness-chat-block-start block) (harness-chat-block-end block))))
           (pos (or (and regexp
                         (or (funcall found)
                             ;; It may be in the part of a long output not shown.
                             (and (equal (harness-chat-block-kind block) "tool-call")
                                  (not (harness-chat-block-show-all block))
                                  (progn (harness-chat--show-all (harness-chat-block-id block))
                                         (funcall found)))))
                    (marker-position (harness-chat-block-start block))))
           (start (marker-position (harness-chat-block-start block)))
           (window (or (get-buffer-window (current-buffer)) (car (harness-chat--windows)))))
      (goto-char pos)
      (when (window-live-p window)
        (set-window-point window pos)
        (with-selected-window window
          ;; The block's top in sight, unless that leaves the match out of it.
          (if (< (count-screen-lines start pos) (- (window-body-height) 2))
              (set-window-start window (save-excursion (goto-char start) (line-beginning-position)))
            (recenter (min 4 (/ (window-body-height) 3))))))
      (harness-chat--schedule-history))))

(defun harness-chat--highlight-found (regexp start end)
  "Highlight the visible matches of REGEXP between START and END.
Return where the first begins, or nil.  The highlights go at the next
command in this buffer."
  (harness-chat--clear-found)
  (let ((case-fold-search t) first)
    (save-excursion
      (goto-char start)
      (while (and (< (point) end) (ignore-errors (re-search-forward regexp end t)))
        (let ((from (match-beginning 0)) (to (match-end 0)))
          (if (= from to)
              (forward-char 1)
            (unless (invisible-p from)
              (let ((ov (make-overlay from to)))
                (overlay-put ov 'face 'harness-chat-found-face)
                (overlay-put ov 'priority 100)
                (push ov harness-chat--found))
              (setq first (or first from)))))))
    (when harness-chat--found
      (add-hook 'pre-command-hook #'harness-chat--clear-found nil t))
    first))

(defun harness-chat--clear-found ()
  "Remove the highlights of what `harness-ui-chat-goto-node' found."
  (mapc #'delete-overlay harness-chat--found)
  (setq harness-chat--found nil)
  (remove-hook 'pre-command-hook #'harness-chat--clear-found t))

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
               (harness-chat--schedule-history)
               (harness-chat--goto-pending))))))
     (lambda (err)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (when (= gen harness-chat--generation)
             (setq harness-chat--loading nil
                   harness-chat--goto nil)
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
waiting question still goes to the question, and\\<harness-chat-mode-map>
\\[harness-chat-queue] queues and \\[harness-chat-cancel] cancels as usual.
A task in review is no such thing: the harness takes any message the
user sends its session for the feedback that sends it back
\(`harness-tasks--on-message').")

(defvar harness-chat-send-functions nil
  "Functions run with the TEXT and ATTACHMENTS of each message sent.
`harness-chat-send' and `harness-chat-queue' run them in the chat
buffer as a message from its compose box goes out: TEXT as typed,
before skill references are expanded, ATTACHMENTS as the box held
them.  An answer to a question is not a message.  A function that
signals stops neither the message nor the other functions.  The BTW
module names a side conversation after its first message this way.")

(defvar harness-chat-commands nil
  "Commands a chat's message box runs instead of sending: (NAME . FUNCTION).
A message that is only /NAME, maybe followed by words on its line, with
nothing attached, calls FUNCTION in the chat buffer with the words after
the name (\"\" when none) rather than going to the session; the box is
emptied once FUNCTION returns, and kept if it signals.  A skill of the
same name wins: /NAME then expands it as usual.  / completion in the
box offers the names with the skills.  Modules add their commands: the
`ui-compact' module adds /compact.")

(defun harness-chat--command (text)
  "Return (FUNCTION . ARGS) when TEXT, a whole message, is a chat command.
See `harness-chat-commands'."
  (let ((case-fold-search nil))
    (when (string-match "\\`/\\([[:alnum:]_-]+\\)\\(?:[ \t]+\\([^\n]*\\)\\)?\\'" text)
      (let ((name (match-string 1 text))
            (args (string-trim (or (match-string 2 text) ""))))
        (when-let* ((fn (cdr (assoc name harness-chat-commands))))
          (unless (member name harness-compose--skills)
            (cons fn args)))))))

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
While the agent is running the message steers the current turn.  An
answer takes the box's attachments with it: a screenshot its text names
by its token, [image 1], reaches the model with the answer.  The files
its @ references name stay references in its text, as an answer's do.
A module showing something of its own in this buffer
\(`harness-chat-send-function') gets the box instead of the session."
  (interactive)
  (let ((question (harness-chat--active-question))
        (typed (string-trim (harness-compose-text))))
    (cond
     ((and question (not (string-empty-p typed)))
      ;; Taken, so the tokens and the images agree and no download is
      ;; still on its way; the box's own attachments go with the answer.
      (let ((text (car (harness-chat--take-message))))
        (harness-chat--answer-question (plist-get question :id) text harness-compose-attachments))
      (harness-chat--clear-compose))
     ;; A module whose panel owns the box takes its text.
     (harness-chat-send-function
      (let ((send harness-chat-send-function))
        (pcase-let ((`(,text . ,atts) (harness-chat--take-message)))
          (harness-chat--clear-compose)
          (funcall send text atts))))
     ;; /compact and the like run here instead of going to the session.
     ((and (null harness-compose-attachments) (harness-chat--command typed))
      (when harness-chat--dead (user-error "This session was deleted"))
      (pcase-let ((`(,fn . ,args) (harness-chat--command typed))
                  (buf (current-buffer)))
        (funcall fn args)
        (with-current-buffer buf (harness-chat--clear-compose))))
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
               (harness-ui-call-turn sid "session/prompt" (list :sessionId sid :prompt blocks)
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
  (harness-ui-call-turn harness-ui-session-id "_harness/agent/send-queue"
                        (list :session-id harness-ui-session-id) #'ignore))

(defun harness-chat--queued-at-point ()
  "Return the id of the queued message point is on, else the first one's.
Point is on a queued message anywhere from its sender line to the blank
line under it."
  (or (get-text-property (point) 'harness-chat-queued)
      (plist-get (car harness-chat--queue) :id)))

(defun harness-chat-send-queued (&optional qid)
  "Send the queued message QID now; the others stay queued.
Interactively QID is the queued message point is on, above the compose
box, else the first one.  While a turn runs the message
steers it: the model gets it at its next step, and its sender line says
\"sent\" until then, \"delivered\" after (`harness-chat--delivery-note').
Otherwise it goes out now, as a turn of its own.  Either way it leaves
the queue for the transcript."
  (interactive (list (harness-chat--queued-at-point)))
  (unless qid (user-error "No queued message to send"))
  (let ((buf (current-buffer)))
    (harness-ui-call-turn harness-ui-session-id "_harness/agent/send-queue"
                          (list :session-id harness-ui-session-id :qids (list qid))
                          #'ignore
                          (lambda (err) (harness-chat--report-error buf "send" err)))))

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
;; compose box below.  Queued messages read as the newest messages, so
;; the line goes under them (`harness-chat--activity-position').
;;
;; What `harness-chat-top-functions' draw -- the companion pet -- goes
;; first in the tail, so it stands on the line.  The overlay sits where
;; that text ends, which a property marks
;; (`harness-chat--activity-position'): where there is none, at the end
;; of the transcript.

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
apart from what comes below, the compose box or a panel."
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
      ;; precedes: the box's prompt or a panel, whose background would
      ;; make the line look like their first.  Both lines are drawn over
      ;; `default' instead, extended: the space after the end of a line
      ;; takes only faces that extend, so the box's would fill it.
      (let ((ground '(:inherit default :extend t)))
        (add-face-text-property 0 (length line) 'harness-chat-activity-face t line)
        (add-face-text-property 0 (length line) ground t line)
        (concat line (propertize "\n" 'face ground))))))

(defun harness-chat--activity-position ()
  "Return where the activity line goes: under the top of the tail and the queue.
That is the end of the transcript, or, when text marked `harness-chat-top'
starts there (see `harness-chat--insert-top'), the end of that text: what
`harness-chat-top-functions' drew stands on the line.  When queued
messages follow (`harness-chat--insert-queue'), the end of the last of
them: they read as the newest messages, and the line under them all says
what the turn does."
  (let ((end (marker-position harness-chat--transcript-end)))
    (dolist (prop '(harness-chat-top harness-chat-queue))
      (when (get-text-property end prop)
        (setq end (or (next-single-property-change end prop) (point-max)))))
    end))

(defun harness-chat--activity-overlay ()
  "Return the activity line's overlay, empty where the line goes.
That is `harness-chat--activity-position'.  At the end of the
transcript, FRONT-ADVANCE and REAR-ADVANCE carry it past blocks
appended there; under the top of the tail and the queue the blocks go in before it,
and the text around carries it along.  A render of the tail takes it
off its place, and `harness-chat--refresh-activity' puts it back."
  (let ((pos (harness-chat--activity-position))
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
  (harness-chat--set-notes activity)
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
FACE is applied over TEXT when non-nil, so a figure that brings its own
face keeps it.  Icons in TEXT stay clickable but are not
hover-highlighted: an SVG keeps the background it was rendered on, so
it would show as a dark box."
  (let ((text (propertize text 'help-echo help 'mouse-face 'mode-line-highlight
                          'local-map (harness-chat--segment-map command)))
        (pos 0))
    ;; Face only when given: a segment around a figure that brings its
    ;; own face, as the context one does, must not wipe it.
    (when face (put-text-property 0 (length text) 'face face text))
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
  "Return the header segment saying SESSION never waits for the user, or nil.
It reads \"non-interactive\" while SESSION is, and a click makes it
interactive again.  An interactive session, the usual kind, has no
segment: `harness-toggle-non-interactive' (`i' after the harness prefix
key, or the menu) turns the mode on."
  (let ((value (plist-get session :non-interactive)))
    (when (harness-json-true-p value)
      (harness-chat--segment (harness-ui-non-interactive-label value)
                             #'harness-toggle-non-interactive
                             (concat (harness-ui-non-interactive-help value)
                                     " (mouse-1: make it interactive)")
                             'harness-non-interactive-face))))

(defun harness-chat--on-quota (_provider _quota)
  "Redraw the header lines, which show the plan's quota."
  (force-mode-line-update t))

(defun harness-chat--on-live (id _live)
  "Redraw the header line of session ID's chat, which shows its context in use.
It grows while its turn streams, a few times a second at most.  ID
nil, after every session's figures were fetched again, redraws them all."
  (if (null id)
      (force-mode-line-update t)
    (when-let* ((buf (harness-chat--buffer-for id)))
      (with-current-buffer buf (force-mode-line-update)))))

;;;; The session this one was started from

;; A fork, a sub-agent, a BTW and a session the merge queue started to
;; resolve a conflict all record the session they were started from as
;; their `:parent-id' (see `session/fork', `session/btw' and
;; `harness-session-parent-id').  The header line says which session that
;; is and what the relation is, and clicking it goes up to it: a child
;; session tells you where it came from and leads back there
;; (`harness-up-to-parent').  A seed conversation in between is stepped
;; over rather than named: a fork made through a seed is the seed's
;; child, and a seed is a prompt cache, not a conversation to open
;; (`harness-ui-seed-session-p').

(defconst harness-chat--parent-labels
  '((fork . "fork of")
    (subagent . "sub-agent of")
    (btw . "opened over"))
  "How the header reads the session a child session was started from.
The kind of the child names the relation; any other kind with a parent
is a \"child of\" it.")

(defun harness-chat--parent-label (kind)
  "Return how the header names the parent of a child session of KIND.
KIND is the child's `:kind' as the session cache holds it, a symbol or,
over ACP, a string."
  (or (alist-get (if (stringp kind) (intern kind) kind) harness-chat--parent-labels)
      "child of"))

(defun harness-chat--parent-id ()
  "Return the id of the session this buffer's session was started from, or nil.
See `harness-chat--parent-label'.  A seed conversation in between is
stepped over: a fork made through a seed is the seed's child, and the
seed is the shared prompt cache, not a conversation to open (see
harness-seed.el).  The id is then the nearest ancestor that is not a
seed -- the session the whole family was started from -- so the header
segment and `harness-up-to-parent' lead there rather than into a seed.
A session whose parent is a seed with no parent of its own has none to
lead to, and gets nil."
  (let ((id (plist-get (harness-chat--session) :parent-id))
        (steps 0))
    ;; A cycle, which nothing should make, must not hang a redisplay.
    (while (and (stringp id) (not (string-empty-p id))
                (< steps 100)
                (harness-ui-seed-session-p (harness-ui-session id)))
      (setq id (plist-get (harness-ui-session id) :parent-id))
      (setq steps (1+ steps)))
    (and (stringp id) (not (string-empty-p id)) id)))

(defun harness-chat--parent-is-seed-p ()
  "Non-nil when the session this one was started from is a seed conversation.
The seed is then not opened (`harness-chat--parent-id' steps over it);
this says why `harness-up-to-parent' has nowhere to go when it has no
ancestor of its own."
  (harness-ui-seed-session-p
   (plist-get (harness-chat--session) :parent-id)))

(defun harness-chat--parent-help (window _object _pos)
  "Return the tooltip of the parent segment in WINDOW's header line.
A `help-echo' function, so the keys are searched on hover, not on every
redisplay of the header line."
  (with-current-buffer (if (window-live-p window) (window-buffer window) (current-buffer))
    (substitute-command-keys
     "The session this one was started from (mouse-1: go up to it, \\[harness-up-to-parent])" t)))

(defun harness-chat--parent-segment ()
  "Return the header segment leading to this session's parent, or nil.
A fork, a sub-agent and a BTW name the session they were started from,
and the whole segment -- the arrow, the relation and the name -- opens
it (`harness-up-to-parent').  A seed conversation in between is not
named or opened: the segment leads to the nearest ancestor that is not
a seed (`harness-chat--parent-id').  A session with no such parent, or
whose parent the harness no longer has, has no segment."
  (when-let* ((id (harness-chat--parent-id))
              (parent (harness-ui-session id)))
    (let* ((label (harness-chat--parent-label (plist-get (harness-chat--session) :kind)))
           (name (harness-chat--session-name id))
           (segment (lambda (name)
                      ;; The name is drawn by the shared session link, so it
                      ;; wears `harness-ui-session-link-face' as a session
                      ;; name does everywhere; the segment's own keymap takes
                      ;; the click, though, running `harness-up-to-parent':
                      ;; the arrow and the relation are part of the same
                      ;; target, and a click on a header line is a
                      ;; `[header-line mouse-1]' the link's own map does not
                      ;; bind (see `harness-chat--segment').
                      (harness-chat--segment
                       (concat "  " (harness-ui-icon 'harness-icon-up) " "
                               (propertize (concat label " ") 'face 'harness-dim-face)
                               (harness-ui-session-link id name))
                       #'harness-up-to-parent #'harness-chat--parent-help))))
      ;; Shown after the session's own name, which matters more: a narrow
      ;; window drops this before the name, and shortens it before that.
      (list (funcall segment name) 65 (funcall segment (harness-truncate-end name 12))))))

(defvar harness-chat-header-functions nil
  "Functions putting segments in front of the chat header line.
Each is called without arguments in the chat buffer whenever the header
line is drawn, and returns a string, or (TEXT PRIORITY MIN) as
`harness-ui-fit-header' takes it, or nil for nothing.  The header shows
their segments first, in order, then the session's own segments:
name, model, permission mode and the rest.  A
segment with a low PRIORITY makes room before any of the session's own
do in a narrow window.  Add to it buffer-locally, so only that buffer's
header changes, and with a symbol, so a reload redefines it.  The BTW
module marks a side conversation and gives it its [close] and [keep]
buttons this way.")

(defun harness-chat--header-prefix-segments ()
  "Return what `harness-chat-header-functions' put in front of the header.
Each is a string, or (TEXT PRIORITY MIN) as `harness-ui-fit-header' takes
it, in the order the functions add them."
  (let ((segments nil))
    (run-hook-wrapped 'harness-chat-header-functions
                      (lambda (fn)
                        (when-let* ((segment (funcall fn)))
                          (push segment segments))
                        nil))
    (nreverse segments)))

(defun harness-chat--header-prefix ()
  "Return what `harness-chat-header-functions' put in front, as one string.
That is the text of `harness-chat--header-prefix-segments', for a caller
that wants the whole prefix as text: the header line itself fits the
segments one by one, each with the priority its function gave it."
  (mapconcat (lambda (segment)
               (if (consp segment) (car segment) segment))
             (harness-chat--header-prefix-segments)
             ""))

(defvar harness-chat-header-end-functions nil
  "Functions adding segments of their own to the chat header line.
Each is called without arguments in the chat buffer whenever the header
line is drawn, and returns a segment as `harness-ui-fit-header' takes
it -- a string, or (TEXT PRIORITY MIN) -- or nil for nothing.  TEXT
carries its separator in front.  The segments show after the session's
own, before [menu], in order; one with a low PRIORITY makes room before
the session's own do in a narrow window.  Add to it buffer-locally or
globally, with a symbol, so a reload redefines it.  The companion pet
shows its face this way.")

(defun harness-chat--header-end ()
  "Return the segments `harness-chat-header-end-functions' add, in order."
  (let ((segments nil))
    (run-hook-wrapped 'harness-chat-header-end-functions
                      (lambda (fn)
                        (when-let* ((segment (ignore-errors (funcall fn))))
                          (push segment segments))
                        nil))
    (nreverse segments)))

(defun harness-chat--header (&optional width)
  "Return the header line, fitted to WIDTH, its window's by default.
It holds what the buffer below does not show and is worth a glance:
the session's name, the session it was started from, model, permission
mode, non-interactive mode while it is on, thinking level, context and
spend.  The status is the mode line's (`harness-chat--mode-line'), the
todo list the panel's above the compose box, and the output tokens and
rate the session list's.

In a window too narrow for all of it, the spend goes first, then the
thinking level, the context, the non-interactive mode and the model;
the name and the session it was started from shorten after those.
What `harness-chat-header-functions' put in front leads the line and
makes room as its own priorities say, before any of the session's own
do; the permission mode, [menu] and the newer-messages notice stay.
What `harness-chat-header-end-functions' add shows before [menu],
making room as its priorities say.  WIDTH is as
`harness-ui-fit-header' takes it."
  (let* ((s (harness-chat--session))
         (non-interactive (harness-chat--non-interactive-segment s))
         (name (or (plist-get s :name) "unnamed")))
    (harness-ui-fit-header
     (append
      ;; Other modules' leading segments, each as the fit takes it: a
      ;; string for a BTW's buttons, (TEXT PRIORITY MIN) for a badge
      ;; that gives way before the session's own do.
      (harness-chat--header-prefix-segments)
      (list
       (list (concat " " (harness-chat--segment name #'harness-rename-session
                                                "Session name (mouse-1: rename)" 'bold))
             70 (concat " " (harness-chat--segment (harness-truncate-end name 8) #'harness-rename-session
                                                  "Session name (mouse-1: rename)" 'bold)))
       ;; Where the session came from, right after its own name.
       (harness-chat--parent-segment)
       (list (concat "  " (harness-chat--segment (harness-ui-model-label (plist-get s :model)) #'harness-set-model
                                                 "Model (mouse-1: change)" 'harness-dim-face))
             50)
       (list (concat "  " (harness-chat--segment (harness-ui-permission-mode-label (plist-get s :permission-mode))
                                                 #'harness-set-permission-mode
                                                 "Permission mode (mouse-1: change)"))
             90)
       (and non-interactive (list (concat "  " non-interactive) 40))
       (list (concat "  " (harness-chat--segment (harness-ui-thinking-label (plist-get s :thinking))
                                                 #'harness-set-thinking "Thinking level (mouse-1: change)"
                                                 'harness-dim-face))
             20)
       (list (concat "  " (harness-chat--segment
                           (harness-ui-format-context s)
                           #'harness-set-context-limit
                           (harness-ui-context-limit-help
                            s (harness-ui-model-context-window (plist-get s :model)))))
             30)
       (list (concat "  " (harness-chat--spend-segment s)) 10))
      ;; Other modules' segments, the companion pet's face say.
      (harness-chat--header-end)
      (list
       (list (concat "  " (harness-chat--segment "[menu]" #'harness-menu #'harness-chat--menu-help 'harness-dim-face))
             95)
       ;; The cached flag, never `harness-chat--scrolled-up-p': measuring
       ;; the window (`pos-visible-in-window-p') formats its header line,
       ;; which would evaluate this again, and again, until
       ;; `max-lisp-eval-depth' -- the header drawn empty, and a redisplay
       ;; taking seconds.  `harness-chat--update-notice' keeps it current.
       (and (or harness-chat--unseen harness-chat--notice)
            (list (concat "  " (harness-chat--segment "↓ newer messages" #'harness-chat-scroll-to-bottom
                                                      "Newer content below (mouse-1: jump to it)"
                                                      'harness-status-blocked-face))
                  88))))
     width)))

(defun harness-chat--mode-line ()
  "Return the mode line text: the session's status and the turn's clock.
This is the one place a chat shows its status: the spinner and the word
while a turn runs, else the status's icon and word, then how long the
turn has gone on while it runs.  A session blocked on a question waits
with no clock, however long it takes.  What the turn does now is the
activity line's, above the compose box, and the spinner's tooltip."
  (let* ((s (harness-chat--session))
         (status (or (plist-get s :status) "idle"))
         (running (equal status "running"))
         (help (if running (harness-chat--activity-text harness-chat--activity) status)))
    (concat
     (if running
         (propertize (harness-chat--spinner-frame) 'face 'harness-status-running-face 'help-echo help)
       (propertize (harness-ui-status-icon status) 'help-echo help))
     " "
     (propertize status 'face (harness-ui-status-face status) 'help-echo help)
     (if (and harness-chat--turn-start running)
         (propertize (format " %s" (harness-format-duration (- (float-time) harness-chat--turn-start)))
                     'face 'harness-dim-face 'help-echo "Turn duration")
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

;;;; Jumping between blocks

(defconst harness-chat--message-kinds '("user" "assistant" "plan")
  "Node kinds of the transcript's real messages.
What you and the agent wrote, the agent's plan included.  Thinking, tool
calls and their results, hints and compactions are the agent's work and
the harness's notes, not messages.")

(defconst harness-chat--action-kinds '("thinking" "tool-call" "tool-result")
  "Node kinds of the agent's work between messages.
A tool result is its call's block, so `tool-result' is here for the
result of a call the transcript does not show.")

(defun harness-chat--jump-stops (kinds)
  "Return where the buffer shows the blocks of KINDS, oldest first.
A run of blocks folded into a collapsed group is one stop, on its
summary line; expanded, its blocks are stops of their own.  A block the
buffer does not show yet -- one still streaming, say -- is no stop."
  (let ((stops nil) (groups nil))
    ;; Newest first in `harness-chat--order'; the stops are collected
    ;; oldest first, so a collapsed group is met before its members.
    (dolist (id (reverse harness-chat--order))
      (let* ((block (gethash id harness-chat--blocks))
             (kind (and block (harness-chat-block-kind block))))
        (when (member kind kinds)
          (let* ((gid (harness-chat-block-group block))
                 (group (and gid (gethash gid harness-chat--groups)))
                 (pos (marker-position (harness-chat-block-start block))))
            (cond
             ;; The run's blocks are hidden under one summary line: that
             ;; line is what a jump can show the reader.
             ((and group (not (harness-chat-group-expanded group)))
              (unless (member gid groups)
                (push gid groups)
                (when-let* ((start (marker-position (harness-chat-group-start group))))
                  (push start stops))))
             (pos (push pos stops)))))))
    (nreverse stops)))

(defun harness-chat--jump (kinds n what)
  "Move point N blocks of KINDS on, back when N is negative.
WHAT names the class of block in the error when the transcript has none
left that way.  Point lands where the target block starts; a block it is
already on is passed over, not counted again."
  (let ((forward (> n 0))
        (stops (harness-chat--jump-stops kinds)))
    (unless forward (setq stops (reverse stops)))
    (dotimes (_ (abs n))
      (let ((target (cl-find-if (if forward
                                    (lambda (pos) (> pos (point)))
                                  (lambda (pos) (< pos (point))))
                                stops)))
        (unless target
          (user-error "No %s %s" what (if forward "below" "above")))
        (goto-char target)))))

(defun harness-chat-next-message (&optional n)
  "Move point to the next real message.
A real message is what you or the agent wrote, the agent's plan
included; thinking, tool calls and their results are passed over.  With
prefix argument N, move N messages on; a negative N moves back."
  (interactive "p")
  (harness-chat--jump harness-chat--message-kinds (or n 1) "message"))

(defun harness-chat-previous-message (&optional n)
  "Move point to the previous real message.
With prefix argument N, move N messages back; a negative N moves on.
See `harness-chat-next-message'."
  (interactive "p")
  (harness-chat--jump harness-chat--message-kinds (- (or n 1)) "message"))

(defun harness-chat-next-user-message (&optional n)
  "Move point to the next message of your side of the conversation.
The agent's messages, thinking and tool calls are passed over, so the
first of them is the prompt the session started with.  With a prefix
argument N, move N messages on; a negative N moves back."
  (interactive "p")
  (harness-chat--jump '("user") (or n 1) "message of yours"))

(defun harness-chat-previous-user-message (&optional n)
  "Move point to the previous message of your side of the conversation.
With prefix argument N, move N messages back; a negative N moves on.
See `harness-chat-next-user-message'."
  (interactive "p")
  (harness-chat--jump '("user") (- (or n 1)) "message of yours"))

(defun harness-chat-next-action (&optional n)
  "Move point to the next tool call or thinking block.
A run of tool calls folded under one summary line is one stop, however
many calls it holds.  With a prefix argument N, move N blocks on; a
negative N moves back."
  (interactive "p")
  (harness-chat--jump harness-chat--action-kinds (or n 1) "tool call or thinking"))

(defun harness-chat-previous-action (&optional n)
  "Move point to the previous tool call or thinking block.
With prefix argument N, move N blocks back; a negative N moves on.
See `harness-chat-next-action'."
  (interactive "p")
  (harness-chat--jump harness-chat--action-kinds (- (or n 1)) "tool call or thinking"))

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
`compose-quote-function', for \\[compose-quote-reply]."
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
(defun harness-up-to-parent ()
  "Show the session this one was started from, and return its buffer.
A fork, a sub-agent and a BTW record the session they were started from
as their parent (`:parent-id'); the header line names it, and this
command, like a click on that name, goes up to it.  A seed
conversation in between is stepped over: a fork made through a seed is
the seed's child, and this leads to the nearest ancestor that is not a
seed (`harness-chat--parent-id').  The window that shows the parent
already is selected when there is one; a parent in no window opens
where this session is shown.  After a window prefix -- `C-x 4 4',
`C-x 5 5', `C-x t t' -- it opens where the prefix says instead
\(`harness-ui-display-override-p').  A session that was not started from
another, or whose parent the harness no longer has, says so instead."
  (interactive)
  (let ((id (harness-chat--parent-id)))
    (unless id
      (if (harness-chat--parent-is-seed-p)
          (user-error "This session was started from a seed conversation, which is not opened")
        (user-error "This session was not started from another")))
    (unless (harness-ui-session id)
      (user-error "The session this one was started from is gone (%s)"
                  (harness-chat--session-name id)))
    (unless harness-ui-open-session-function
      (user-error "No chat module loaded"))
    (let ((buffer (funcall harness-ui-open-session-function id)))
      ;; After a window prefix (C-x 4 4, C-x 5 5) the parent shows where
      ;; it says, though a window shows it already.
      (if-let* ((window (and (not (harness-ui-display-override-p)) (get-buffer-window buffer))))
          (progn (select-window window) buffer)
        (harness-ui-display-buffer buffer harness-ui-position)))))

;;;###autoload
(defun harness-open-session (id &optional position)
  "Open session ID in POSITION.
An inactive session opens as it is, compose box included; the first
message sent from it resumes it.  The session chosen to open is never
a seed conversation (`harness-ui-navigable-session-p')."
  (interactive (list (plist-get (harness-ui-read-session "Open session: "
                                                         #'harness-ui-navigable-session-p)
                                :id)
                     (and current-prefix-arg (harness-ui-read-position))))
  (harness-ui-display-session id position))

(defun harness-chat--project-sessions (root)
  "Return the sessions of the project at ROOT to open, newest first."
  (harness-ui-user-sessions (lambda (s)
                              (and (equal (plist-get s :project) root)
                                   (harness-ui-navigable-session-p s)))))

;;;###autoload
(defun harness-open-latest-session (&optional position)
  "Open the newest session of the current project in POSITION.
A seed conversation is none of the project's sessions to open, however
newly it was touched: it is a shared prompt cache, not a conversation
\(`harness-ui-navigable-session-p').  A project whose only sessions are
seeds has none to open, so a new one starts as it would with no
session at all."
  (interactive (list (and current-prefix-arg (harness-ui-read-position))))
  (let* ((root (harness-chat--project-root default-directory))
         (mine (harness-chat--project-sessions root)))
    (if mine
        (harness-open-session (plist-get (car mine) :id) position)
      (harness-new-session root position))))

;;;; Prompting with the region

;; The region of any buffer starts a message.  In a buffer with a compose
;; box it is quoted there, as `harness-compose-quote-reply' does.  In any
;; other it is put, with where it comes from, in the box of the newest
;; session of the buffer's project -- or of a new one -- which opens for
;; the request.

(defun harness-chat--code-language (&optional mode)
  "Return the Markdown language tag of major mode MODE, default `major-mode'.
That is the mode's name without its -mode, or -ts-mode when a
tree-sitter one: `emacs-lisp-mode' is emacs-lisp, `python-ts-mode'
python and `c++-mode' c++.  A mode derived from `emacs-lisp-mode', such
as `lisp-interaction-mode', is emacs-lisp too."
  (let ((mode (or mode major-mode)))
    (if (provided-mode-derived-p mode 'emacs-lisp-mode)
        "emacs-lisp"
      (let ((name (symbol-name mode)))
        (if (string-match "\\`\\(.+?\\)\\(?:-ts\\)?-mode\\'" name)
            (match-string 1 name)
          name)))))

(defun harness-chat--fence (text language)
  "Return TEXT as a Markdown code block in LANGUAGE, a string.
The fence is longer than any run of backticks in TEXT, so nothing in
TEXT ends the block early."
  (let ((longest 0) (pos 0))
    (while (string-match "`+" text pos)
      (setq longest (max longest (- (match-end 0) (match-beginning 0)))
            pos (match-end 0)))
    (let ((fence (make-string (max 3 (1+ longest)) ?`)))
      (concat fence language "\n" text "\n" fence))))

(defun harness-chat--region-origin (first last root)
  "Return the line saying where lines FIRST to LAST of this buffer come from.
A buffer visiting a file names its path, relative to ROOT when inside
that project, else abbreviated; any other buffer names itself."
  (if-let* ((file buffer-file-name))
      (format "From `%s` (%s):"
              (if (string-prefix-p root (expand-file-name file))
                  (file-relative-name file root)
                (abbreviate-file-name file))
              (if (= first last)
                  (format "line %d" first)
                (format "lines %d–%d" first last)))
    (format "From the buffer `%s`:" (buffer-name))))

(defun harness-chat--region-prompt (beg end root)
  "Return the start of a message made of the text from BEG to END of this buffer.
A line says where the text comes from (`harness-chat--region-origin';
ROOT is the project to name a path in).  Under it comes the text, a
programming or configuration buffer's in a fenced code block in its
language and any other's as a Markdown quote.  Blank lines around the
text are left out; the lines named are those of what is left."
  (let* ((from (save-excursion (goto-char beg) (skip-chars-forward " \t\n" end) (point)))
         (to (save-excursion (goto-char end) (skip-chars-backward " \t\n" beg) (point))))
    (when (>= from to)
      (user-error "The region is blank: select the text to prompt with"))
    (let ((text (string-trim (buffer-substring-no-properties beg end) "\\(?:[ \t]*\n\\)+" "[ \t\n]+")))
      (concat (harness-chat--region-origin (line-number-at-pos from t) (line-number-at-pos (1- to) t) root)
              "\n\n"
              (if (derived-mode-p 'prog-mode 'conf-mode)
                  (harness-chat--fence text (harness-chat--code-language))
                (harness-compose-quote-string text))))))

(defun harness-chat--prompt-labels (sessions)
  "Return (LABEL . SESSION) for each of SESSIONS, the labels all different.
Sessions that share a name are told apart by their ids."
  (let ((labels (mapcar (lambda (s)
                          (format "%s  %s" (harness-ui-session-label s)
                                  (propertize (harness-ui-model-label (plist-get s :model))
                                              'face 'harness-dim-face)))
                        sessions)))
    (cl-mapcar (lambda (s label)
                 (cons (if (> (cl-count label labels :test #'equal) 1)
                           (format "%s  %s" label (truncate-string-to-width (plist-get s :id) 8))
                         label)
                       s))
               sessions labels)))

(defun harness-chat--read-prompt-session (sessions)
  "Read where the region goes: one of SESSIONS, newest first, or a new session.
Return the session's plist, or nil for a new session."
  (let* ((new "New session")
         (table (append (harness-chat--prompt-labels sessions) (list (cons new nil))))
         (choice (completing-read
                  "Prompt session: "
                  ;; In the order given: the newest first, the new session last.
                  (lambda (string predicate action)
                    (if (eq action 'metadata)
                        '(metadata (display-sort-function . identity)
                                   (cycle-sort-function . identity))
                      (complete-with-action action table string predicate)))
                  nil t nil nil (caar table))))
    (cdr (assoc choice table))))

(defun harness-chat--append-to-box (buffer text)
  "Put TEXT at the end of the compose box of chat BUFFER, and point after it.
A blank line comes between a draft in the box and TEXT, and another
follows TEXT, where the request goes.  Point ends there, the windows of
BUFFER showing it.  The text is kept for the box when it is not drawn
yet."
  (with-current-buffer buffer
    (let ((draft (string-trim-right (or (harness-compose-text) ""))))
      (harness-compose-set (concat draft (if (string-empty-p draft) "" "\n\n") text "\n\n")))
    (harness-chat-scroll-to-bottom)))

;;;###autoload
(defun harness-prompt-region (&optional choose)
  "Prompt a session with the region: start a message in its box with it.
The region of any buffer will do.  In one with a compose box -- a chat,
the task board, a popout -- it is quoted there, as
\\[harness-compose-quote-reply] does.  In any other buffer the box of the
newest session of the buffer's project gets it, as the start of a
message: a line saying where it comes from -- the file and its lines, or
the buffer's name -- and the text, in a fenced code block when the
buffer is for programming or configuration, else as a Markdown quote.
The project has no session yet: a new one opens for it.  The session's
chat is shown and selected, point in its box after the text, ready for
the request; a draft already in the box stays above it.

With a prefix argument CHOOSE, choose the session among the project's,
or a new one."
  (interactive "P")
  (unless (use-region-p)
    (user-error "Select the text to prompt with first"))
  (if (harness-compose-live-p)
      (harness-compose-quote-reply (region-beginning) (region-end))
    (let* ((root (harness-chat--project-root default-directory))
           (text (harness-chat--region-prompt (region-beginning) (region-end) root))
           (sessions (harness-chat--project-sessions root))
           (session (if (and choose sessions)
                        (harness-chat--read-prompt-session sessions)
                      (car sessions)))
           (seed (lambda (buffer) (harness-chat--append-to-box buffer text))))
      (deactivate-mark)
      (if session
          (funcall seed (harness-ui-display-session (plist-get session :id)))
        (harness-new-session root nil seed)))))

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
  ;; Moving by block: M-n and M-p by message, M-N and M-P by one of
  ;; yours, C-M-n and C-M-p by tool call or thinking.  No printable key,
  ;; so typing still goes to the box wherever point is.
  (define-key map (kbd "M-n") #'harness-chat-next-message)
  (define-key map (kbd "M-p") #'harness-chat-previous-message)
  (define-key map (kbd "M-N") #'harness-chat-next-user-message)
  (define-key map (kbd "M-P") #'harness-chat-previous-user-message)
  (define-key map (kbd "C-M-n") #'harness-chat-next-action)
  (define-key map (kbd "C-M-p") #'harness-chat-previous-action)
  (define-key map (kbd "C-c C-w") #'harness-chat-copy-last-response)
  (define-key map (kbd "C-c C-t") #'harness-chat-toggle-todos)
  (define-key map (kbd "C-c C-u") #'harness-up-to-parent)
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
e when it has a pattern to edit.  In the box those keys type, so
\\[harness-compose-panel-key] and then a key presses it on the nearest panel above the box that
has it, point coming back to the box (a numeric argument takes the Nth
panel up): \\[harness-compose-panel-key] 1 picks a question's first option, \\[harness-compose-panel-key] y allows a
permission.  Each panel says so in a dim line of its own.

\\[harness-compose-beginning-of-buffer] and \\[harness-compose-end-of-buffer] in the box go to its top and its bottom, not the
buffer's; pressed again, from outside the box or with a prefix argument
they go on to the buffer's.

\\<harness-chat-mode-map>\\[compose-quote-reply] quotes the region, or the agent's message at point, in
the box, to reply to it; from the box, the agent's last message.  Answer
a quote inline, part by part: in a quote in the box,
\\<compose-quote-inline-mode-map>\\[compose-quote-split] splits it where point is, to answer that part, and
\\[compose-quote-elide] elides the region, or the rest of the paragraph, as [...].
\\[harness-prompt-region] does the same for the region, here and in any
other buffer, where it opens the box of the project's newest session
with the text and where it comes from.

\\[harness-compose-add-attachment] attaches a file, or a task as task:ID.  The attachment
has its reference in the text -- [image 1], @notes.txt, @task:ID --
shown as a chip: a click opens it, mouse-3 offers the rest, and deleting
the reference removes the attachment.

\\[harness-chat-queue] queues the message for the next turn.  A queued message shows
above the box as it will in the transcript, its sender line saying
\"queued\" and holding its buttons: [send now] sends it alone, the
others staying queued, [edit] takes it back into the box and [×] drops
it.  The queued messages come last in the conversation, the line saying
what a running turn does under them.  \\[harness-chat-send-queued] sends the
queued message point is on, \\[harness-chat-send-queue] every one.
A message sent while a turn runs, queued or not, gives its state on its
sender line: \"sent\" until the model has it, then \"delivered\"; \"not
delivered\" when the turn ended before the model got it.

\\<harness-chat-mode-map>Point moves from block to block without a mouse:
\\[harness-chat-next-message] and \\[harness-chat-previous-message] go to the next and previous
real message -- what you or the agent wrote, plans included -- past
thinking and tool calls;
\\[harness-chat-next-user-message] and \\[harness-chat-previous-user-message] to the next and
previous message of your own, the prompt the session started with
included; \\[harness-chat-next-action] and \\[harness-chat-previous-action] to the next and
previous tool call or thinking block.  A run of tool calls folded under
one summary line is one stop.

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
  (setq-local compose-quote-function #'harness-chat--quote-at-point
              harness-compose-commands (mapcar #'car harness-chat-commands))
  (add-hook 'post-command-hook #'harness-chat--post-command nil t)
  (add-hook 'window-buffer-change-functions #'harness-chat--on-window-buffer-change nil t)
  (add-hook 'window-scroll-functions #'harness-chat--schedule-history nil t)
  (add-hook 'window-scroll-functions #'harness-chat--update-notice nil t)
  (add-hook 'window-size-change-functions #'harness-chat--on-window-size nil t)
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
        ("C-c C-a" "Attach file or task" harness-compose-add-attachment)
        ("C-y" "Paste; an image attaches" harness-compose-yank)
        ("C-c >" "Quote reply: region or message" compose-quote-reply)
        ("M-RET" "Split a quote to answer inline" compose-quote-split)
        ("C-c [" "Elide part of a quote: [...]" compose-quote-elide)
        ("M-<" "Top of the box, then the buffer" harness-compose-beginning-of-buffer)
        ("M->" "Bottom of the box, then the buffer" harness-compose-end-of-buffer)]
       ["Agent"
        ("C-c C-y" "Allow request" harness-chat-allow-newest)
        ("C-c C-n" "Deny request" harness-chat-deny-newest)
        ("C-c C-p" "Edit request's pattern" harness-chat-edit-permission-pattern)
        ("C-c ." "A key of the panel above, from the box" harness-compose-panel-key)
        ("C-c C-f" "Next diagram" harness-chat-next-diagram)
        ("C-c C-b" "Previous diagram" harness-chat-previous-diagram)
        ("C-c C-t" "Show or hide the todo list" harness-chat-toggle-todos)
        ("C-c C-k" "Cancel turn" harness-chat-cancel)]
       ["Session"
        ("C-c C-u" "Go to the session this one came from" harness-up-to-parent)]
       ["Transcript"
        (". TAB" "Fold block" harness-chat-tab)
        ("M-n" "Next message" harness-chat-next-message)
        ("M-p" "Previous message" harness-chat-previous-message)
        ("M-N" "Next message you wrote" harness-chat-next-user-message)
        ("M-P" "Previous message you wrote" harness-chat-previous-user-message)
        ("C-M-n" "Next tool call or thinking" harness-chat-next-action)
        ("C-M-p" "Previous tool call or thinking" harness-chat-previous-action)
        ("C-c C-s" "Search" harness-chat-search)
        ("C-c C-w" "Copy last reply" harness-chat-copy-last-response)
        ("C-c C-e" "Jump to bottom" harness-chat-scroll-to-bottom)
        ("C-c C-r" "Redraw" harness-chat-redraw)
        ("C-c C-z" "Bury: back to the buffer before" harness-ui-bury)]))

(defun harness-chat--post-command ()
  "Keep the newer-messages notice current.
Point moved onto an option of a question with diagrams shows its diagram."
  (when (and harness-chat--unseen (harness-chat--at-bottom-p (selected-window)))
    (setq harness-chat--unseen nil))
  (harness-chat--update-notice)
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
  (add-hook 'harness-ui-live-functions #'harness-chat--on-live)
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
  "Add the hooks and keys that came after the module's first version.
A reload does not initialise a running module again, so the file adds
them itself when the module is ready (below)."
  ;; Windows following a streaming chat scroll once per slice of messages.
  (add-hook 'harness-acp-received-hook #'harness-chat--pin-waiting)
  ;; A lasting decision undone or redone, from any session, redraws the
  ;; notes that refer to it (harness-ui-decisions.el keeps them).
  (add-hook 'harness-ui-decision-functions #'harness-chat--on-decision)
  ;; The region of any buffer starts a message: C-c h > (see
  ;; `harness-prompt-region'); the harness menu has it too.
  (define-key harness-ui-map (kbd ">") #'harness-prompt-region))

(harness-define-module 'ui-chat
  :doc "The chat buffer: transcript, pending panel, queue, attachments and compose box."
  :requires '(ui)
  :init #'harness-chat--init)

(when (harness-module-ready-p 'ui-chat)
  (harness-chat--init-hooks))

(provide 'harness-ui-chat)
;;; harness-ui-chat.el ends here
