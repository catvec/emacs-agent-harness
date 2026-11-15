;;; harness-ui-report.el --- A task's report: its final message and evidence  -*- lexical-binding: t; -*-

;;; Commentary:

;; What a task's session hands in with `hand_in': the final message, in
;; markdown, and the evidence for it -- images, videos, files, code,
;; notes, and references to earlier tool calls of the session.  It shows
;; in a popout (`harness-ui-popout'), so it can be read without opening
;; the session, from
;;
;;   the board  [Review Changes] on a card waiting for review that has
;;              one; the board's item at point (`SPC', through the
;;              shared `harness-ui-popout-at-point-functions') on a
;;              card of any column;
;;   the chat   the review banner's [Review Changes] button.
;;
;; The button reads [Review Changes], to look the changes and the work
;; over, not [Report], which reads as reporting the agent for something
;; bad.
;;
;; Inside the task's session the report is not behind a button: while
;; the task waits for review, the review banner shows it in full,
;; expanded, between its heading and its buttons
;; (`harness-ui-report-string'), and the hand_in call above the banner
;; stays folded then, so the report is read once.
;;
;; The transcript's hand_in calls draw it too, each call its own round's
;; report, expanded with the call.  What the review draws with a report
;; -- the files and threads of its changes -- is added through
;; `harness-ui-report-hand-in-functions', so a hand_in call reads as the
;; review banner does; the review module adds the one drawing both use
;; (`harness-ui-review--hand-in').  A fold in either draws where it is
;; again: the call's buttons draw the call
;; (`harness-ui-report--redraw-function'), the banner's draw the chat's
;; tail, and a popout's draw the popout.
;;
;; The report is drawn from the task record the harness holds: the board
;; and the chat both pass the record they already have, and a popout
;; follows `task/changed' so what it shows is current.  Once the task
;; is verified or sent back its popout closes, wherever that was done --
;; the board, the session's banner, turning review off, an agent: the
;; review the report was opened for is over.  The report of a task
;; decided before it opened, a done one, stays open.  A referenced tool
;; call is the link it is, drawn as the chat draws calls: its title and
;; status, the input it ran with, its output (capped in the popout, with
;; a button for the rest; whole in the session), and [Open in the
;; session], which shows the session and takes point to the call.
;;
;; A round of work whose turn ended without `hand_in' -- the model
;; replied instead, or could not call the tool -- gets a report from
;; the harness marked `:missing' (`harness-tasks--missing-report').  It
;; draws as what it is: "Not handed in", with no evidence, the
;; session's last message under it and [Open the session], where the
;; work has to be checked.  The board's button for it reads [No report].
;;
;; A report folds.  Each piece of evidence has a fold button of its own,
;; [Collapse all] and [Expand all] above them fold or open them together,
;; and the Evidence heading folds them all at once.  What the reader
;; folds is kept by the task and the section
;; (`harness-ui-report--folds'), so it stands when the report is drawn
;; again, at the next hand-in: from the second hand-in on, or once the
;; task was reopened, every section starts folded
;; (`harness-ui-report-auto-fold'), that a report already read does not
;; bury the conversation under it.  The changes and threads sections of
;; the review fold the same way, in the same store; what they hold -- the
;; files' directories, each file's threads and each thread -- folds in
;; the review itself, for its round.
;;
;; Images are the evidence most worth seeing, so they show large: the
;; popout's width and much of the frame's height, the popout growing
;; taller than others for them (`harness-ui-report-max-height').
;; Clicking one, or RET on it, shows it larger still in a popout of its
;; own (`harness-ui-popout-image'), which q closes, back to the report.
;; Dragging one, from either, drops its file into another application,
;; a chat app or a browser, to pass the evidence on (harness-ui-drag.el).
;; The popout opens before its images are drawn -- a line says each is
;; loading -- because decoding a screenshot of a whole frame takes a
;; moment (`harness-ui-image-load').  The report a session's banner
;; shows is drawn into a string, where nothing can draw later: its
;; images are drawn with it.
;;
;; Other modules add to the popout as they add to a chat:
;; `harness-ui-report-panel-functions' draws a panel at the end of the
;; report and `harness-ui-report-compose-functions' gives it a compose
;; box.  The review module puts the banner a task's session shows there,
;; [Verify] and [Send back], with the box taking the feedback, so work
;; can be accepted from its report.
;;
;; What cannot be drawn does not take the rest down.  A piece of evidence
;; that fails says so in a line and the others draw; a report that fails
;; says so and its panels draw; a panel that fails says so and the panels
;; after it draw -- the review banner's [Verify] and [Send back] come
;; after the changes, and the work must be acceptable whether or not they
;; could be read.  The line is short, whatever the error carries
;; (`harness-error-short-message'): an `args-out-of-range' names the
;; record it was about whole, and a review holds the task's hand-in.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'button)
(require 'mailcap)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)
(require 'harness-ui-drag)
(require 'harness-ui-markdown)
(require 'harness-ui-popout)
(require 'harness-ui-tasks)

(defgroup harness-ui-report nil
  "A task's report: its final message and evidence." :group 'harness-ui)

(defcustom harness-ui-report-output-limit 1200
  "Characters of a referenced tool call's output shown before [show all]."
  :type 'integer :group 'harness-ui-report)

(defcustom harness-ui-report-max-height 0.75
  "Height a report popout grows to at most, as a fraction of its frame's.
More than other popouts take (`harness-ui-popout-max-height'), so the
images of a report show large."
  :type 'number :group 'harness-ui-report)

(defcustom harness-ui-report-image-max-height 0.55
  "Height an evidence image of a report takes at most.
A fraction of the frame's height, or a number of pixels; either way the
image fits the popout whole.  Its width is the popout's.  Clicking it
shows it larger still (`harness-ui-popout-image-max-height')."
  :type '(choice (float :tag "Fraction of the frame's height") (integer :tag "Pixels"))
  :group 'harness-ui-report)

(defcustom harness-ui-report-design-max-chars 60000
  "Characters of a design document the report draws.
The whole document is kept in the report and opened with [Open
design]; the report draws this much of it, so a long design does not
bury the rest of the review."
  :type 'integer :group 'harness-ui-report)

(defcustom harness-ui-report-walkthrough-voice t
  "When non-nil, a walkthrough turns voice on where the voice module is loaded.
Voice is the point of a walkthrough: the reviewer listens, interrupts
and asks.  Without the module, or with this off, the conversation is
the same in text."
  :type 'boolean :group 'harness-ui-report)

(defvar harness-ui-report--demo-runs (make-hash-table :test 'equal)
  "Report and evidence number -> the demo run this Emacs started for it.
The run is `demo/start''s: its id names what it may stop, and its state
is asked of the harness when the row is drawn.")

(defvar harness-ui-report--demo-results (make-hash-table :test 'equal)
  "Report and evidence number -> the answer the last demo start gave.
A start that did not run says why in the row, until another start is
made.")

(defvar harness-ui-report--demo-processes (make-hash-table :test 'equal)
  "Task and evidence number -> the demo process started from a report.")

(defvar harness-ui-report-panel-functions nil
  "Functions putting a panel of their own at the end of a report popout.
Each is called with the TASK the popout shows, in the popout buffer, on
every draw, and returns a string, or nil for nothing.  The strings go
after the evidence, in order, read-only, above the compose box when
there is one.  The review module shows a task's review banner this way:
the one its session shows, with [Verify] and [Send back].")

(defvar harness-ui-report-compose-functions nil
  "Functions giving a report popout a compose box.
Each is called with the TASK the popout shows, in the popout buffer, on
every draw, and returns nil, or (SUBMIT . PLACEHOLDER): SUBMIT, a
function of TEXT and ATTACHMENTS, takes what the box holds when
\\<harness-ui-popout-mode-map>\\[harness-ui-popout-submit] sends it, the popout buffer current;
PLACEHOLDER is the empty box's hint.  The first function returning
non-nil wins; with none, the popout has no box.  The review module
takes the feedback that sends a task back this way.")

(defvar harness-ui-report--redraw-function nil
  "Function that draws a report again where it is, or nil.
Bound while a report is drawn into a string for a view other than a
popout -- the review banner in a chat's tail, a hand_in call in the
transcript -- to what draws that view again when a fold changes.  The
buttons the drawing makes keep it, so a fold still works after the
drawing is done.  Nil draws the report's popout and the review banner
of its task again, as the popout's own folds ask.")

(defvar harness-ui-report-hand-in-functions nil
  "Functions that draw what a hand_in call shows with its report.
Each is called in the buffer the call is drawn in, with the REPORT
plist the call handed in, the TASK, the WINDOW the drawing is sized
for, and REDRAW, a function that draws the call again where it is; it
returns the string to draw, or nil to draw the report alone.  A module
that knows more of the hand-in adds one: the review module draws the
changes and threads of the task's review with the report, the same
drawing its banner has, so the current hand-in and a previous call
read the same.")

(defvar harness-ui-report--reports (make-hash-table :test 'equal)
  "Popout key -> the task record its popout shows, kept current.")

(defvar-local harness-ui-report--task nil
  "The task record this popout shows.")

(defvar-local harness-ui-report--box nil
  "What `harness-ui-report-compose-functions' gave this popout at its last draw.
That is (SUBMIT . PLACEHOLDER), or nil for no box.")

(defcustom harness-ui-report-auto-fold t
  "Non-nil: the second hand-in of a task opens with its sections folded.
The evidence, the files and the threads of a review are long, and a task
looked at again and again should not show them all every time: from the
review after the first one on, they start folded, and what the reader
opens or folds stays so for the next.  Nil opens every review whole."
  :type 'boolean :group 'harness-ui)

(defvar harness-ui-report--folds (make-hash-table :test 'equal)
  "What the reader folded in a report, by task and section.
Keys are (TASK-ID . SECTION), values t folded and nil open.  A section
not here uses its default: the evidence starts folded from the second
hand-in of a task on, so a review does not open as a wall of evidence
every time.")

(defconst harness-ui-report--unset (make-symbol "unset")
  "The value of a fold that was never set.")

(defun harness-ui-report--fold-key (task key)
  "Return the key of TASK's fold KEY in `harness-ui-report--folds'."
  (cons (plist-get task :id) key))

(defun harness-ui-report--folded-p (task key default)
  "Non-nil when TASK's KEY is folded; DEFAULT when it was never set."
  (let ((value (gethash (harness-ui-report--fold-key task key) harness-ui-report--folds
                        harness-ui-report--unset)))
    (if (eq value harness-ui-report--unset) default value)))

(defun harness-ui-report--set-fold (task key folded)
  "Fold TASK's KEY when FOLDED, else open it; return the value."
  (puthash (harness-ui-report--fold-key task key) (and folded t)
           harness-ui-report--folds))

(defun harness-ui-report--default-folded-p (task)
  "Non-nil from the second hand-in of TASK on.
The first report opens whole; the ones after a round of feedback, or
after a task was reopened, start folded, and what the reader did with
one stays so for the next."
  (and harness-ui-report-auto-fold
       (or (plist-get task :feedback) (plist-get task :reopened)) t))

(defun harness-ui-report--refresh (task &optional redraw)
  "Draw TASK's report again where it shows: its popout or its chat.
REDRAW draws it there when given; without it the drawing's own
`harness-ui-report--redraw-function' says, and with neither the popout
and the review banner of the task are drawn again, as a popout's folds
ask."
  (if-let* ((redraw (or redraw harness-ui-report--redraw-function)))
      (funcall redraw)
    (let ((id (plist-get task :id)))
      (when (and (fboundp 'harness-ui-report-task) (harness-ui-report-task)
                 (fboundp 'harness-ui-popout-refresh))
        (harness-ui-popout-refresh (list 'report id)))
      (when (and (fboundp 'harness-ui-review--redraw) (plist-get task :session))
        (harness-ui-review--redraw (plist-get task :session))))))

(defun harness-ui-report--button (label function help)
  "Return LABEL as a button running FUNCTION, with HELP."
  (propertize (buttonize label (lambda (_) (funcall function)) nil help)
              'mouse-face 'highlight))

(defun harness-ui-report--fold-button (task key folded label &optional indent)
  "Return LABEL as the fold button of TASK's KEY, folded when FOLDED.
INDENT, when given, is what stood before the button: the arrow goes in
the left gutter and INDENT keeps the label in the column it had."
  (let* ((arrow (if folded "▸" "▾"))
         (text (if indent
                   (concat (harness-ui-fold-gutter arrow indent) label)
                 (format "%s %s" arrow label)))
         (redraw harness-ui-report--redraw-function))
    (harness-ui-report--button
     text
     (lambda ()
       (harness-ui-report--set-fold task key (not folded))
       (harness-ui-report--refresh task redraw))
     (if folded "Show it" "Hide it"))))

(defun harness-ui-report--set-evidence-fold (task report
                                             folded &optional redraw)
  "Fold every piece of REPORT, TASK's, when FOLDED, else open them.
The section and each item are set, so the next report of the task opens
as the reader left this one.  REDRAW draws the report again where it is,
as `harness-ui-report--refresh' says."
  (harness-ui-report--set-fold task "evidence" folded)
  (let ((n (length (append (plist-get report :evidence) nil))))
    (dotimes (i n)
      (harness-ui-report--set-fold task (list 'evidence (1+ i)) folded)))
  (harness-ui-report--refresh task redraw))

(defun harness-ui-report--evidence-controls (task report)
  "Return the [Collapse all] and [Expand all] buttons of TASK's REPORT."
  (if (null (plist-get report :evidence))
      ""
    (let ((redraw harness-ui-report--redraw-function))
      (concat "  "
              (harness-ui-report--button
               "[Collapse all]"
               (lambda ()
                 (harness-ui-report--set-evidence-fold
                  task report t redraw))
               "Hide every piece of evidence")
              " "
              (harness-ui-report--button
               "[Expand all]"
               (lambda ()
                 (harness-ui-report--set-evidence-fold
                  task report nil redraw))
               "Show every piece of evidence")))))

(defvar-local harness-ui-report--expanded (make-hash-table :test 'equal)
  "Referenced tool calls whose full output this popout shows.")

(defvar harness-ui-report--full nil
  "Non-nil while a report is drawn in full: every call's whole output.")

(defvar harness-ui-report--window nil
  "The window a report drawn away from its buffer is sized for.
`harness-ui-report-string' draws in a scratch buffer no window shows;
its images fit this one instead.")

(defvar harness-ui-report--defer-images t
  "Non-nil while a report shows its images as they come.
Its popout draws them that way: a loading line goes where each image
will be, and the image is drawn a moment later, so the report appears
at once rather than after Emacs decoded every screenshot it shows
\(`harness-ui-image-load').  A report drawn into a string, for a view
that shows it among its own text, draws them straight away instead: a
string has nowhere to draw an image later.")

(defvar harness-chat--transcript-end)
(defvar harness-chat--calls)
(defvar harness-compose-redraw-function)
(defvar harness-ui-session-id)
(declare-function harness-chat-block-node "harness-ui-chat" (block))
(declare-function harness-chat--rerender "harness-ui-chat" (block))
(declare-function harness-chat--str "harness-ui-chat" (kind))
(declare-function harness-ui-review--task "harness-ui-review" (sid))
(declare-function harness-ui-session "harness-ui" (id))
(declare-function harness-ui-display-session "harness-ui" (id))
(declare-function harness-ui-call-turn "harness-ui" (session-id method params callback &optional on-error))
(defvar harness-ui-open-session-function)
(defvar harness-ui-btw--asked)

(defun harness-ui-report--report (task)
  "Return TASK's report plist, or nil."
  (plist-get task :report))

(defun harness-ui-report-task ()
  "Return the task record the report popout in this buffer shows, or nil.
Nil in any other buffer."
  harness-ui-report--task)

(defun harness-ui-report--verified-p (task)
  "Non-nil when the user verified TASK's work."
  (harness-json-true-p (plist-get task :verified)))

(defun harness-ui-report--decided-p (shown task)
  "Non-nil when the review of SHOWN is decided in TASK.
SHOWN is the task record a popout drew last, TASK the one it has now:
the work was verified since, or sent back, which adds a round of
feedback to `:feedback'."
  (or (and (harness-ui-report--verified-p task) (not (harness-ui-report--verified-p shown)))
      (> (length (plist-get task :feedback)) (length (plist-get shown :feedback)))))

(defun harness-ui-report--title (task)
  "Return the title of TASK, as the board shows it."
  (if (fboundp 'harness-ui-tasks--title)
      (harness-ui-tasks--title task)
    (harness-first-line (or (plist-get task :prompt) "task") 60)))

(defun harness-ui-report--text (value)
  "Return VALUE as a non-blank trimmed string, or nil."
  (and (stringp value) (not (harness-string-blank-p value)) (string-trim value)))

;;;; Drawing the evidence

(defun harness-ui-report--file-attachment (path)
  "Return PATH as a media attachment plist for its extension."
  (let* ((extension (downcase (or (file-name-extension path) "")))
         (mime (or (cdr (assoc extension '( ("mp4" . "video/mp4") ("webm" . "video/webm") ("mov" . "video/quicktime")
                                            ("mkv" . "video/x-matroska") ("avi" . "video/x-msvideo"))))
                   (condition-case nil
                       (let ((m (mailcap-extension-to-mime extension)))
                         (and (stringp m) (not (string= m "application/octet-stream")) m))
                     (error nil))
                   "application/octet-stream"))
         (size (file-attribute-size (file-attributes path))))
    (list :path path :mime mime :size size :name (file-name-nondirectory path))))

(defun harness-ui-report--insert-media (path)
  "Insert the media line for PATH, with ui-media when it is loaded."
  (if (and (fboundp 'harness-ui-media-render-attachment) (file-exists-p path))
      (progn
        (insert (harness-ui-media-render-attachment (harness-ui-report--file-attachment path)))
        ;; A rendering ends its last line without a newline.
        (unless (bolp) (insert "\n")))
    ;; `harness-ui-button' inserts the button itself, at point.
    (insert " ")
    (harness-ui-button (format "[%s]" (file-name-nondirectory path))
                       (lambda () (harness-ui-report--open-file path))
                       :help path)
    (insert "\n")))

(defun harness-ui-report--open-file (path)
  "Open PATH with the desktop's opener, or in Emacs.
See `harness-ui-popout-open-file'."
  (harness-ui-popout-open-file path))

;;;; The design document

(defun harness-ui-report--first-heading (text)
  "Return the first Markdown heading of TEXT, or nil."
  (when (and (stringp text)
             (string-match "^#+[ \t]+\\(.+?\\)[ \t]*\r?$" text))
    (string-trim (match-string 1 text))))

(defun harness-ui-report--design-sections (text)
  "Return TEXT as its Markdown sections, a list of (TEXT START END).
START and END are the 1-based lines of TEXT the section covers; a
section starts at a heading and ends before the next, and a line inside
a fenced code block is no heading."
  (let* ((lines (split-string text "\n"))
         (count (length lines))
         (sections nil)
         (start 1)
         (fence nil)
         (number 1))
    (dolist (line lines)
      (when (and (> number start) (not fence)
                 (string-match-p "\\`#+[ \t]+" line))
        (push (list (mapconcat #'identity (cl-subseq lines (1- start) (1- number)) "\n")
                    start (1- number))
              sections)
        (setq start number))
      (when (string-match-p "\\`[ \t]*\\(```\\|~~~\\)" line)
        (setq fence (not fence)))
      (setq number (1+ number)))
    (push (list (mapconcat #'identity (cl-subseq lines (1- start)) "\n")
                start count)
          sections)
    (nreverse sections)))

(defun harness-ui-report--open-design (design)
  "Open DESIGN's document in a window of its own."
  (let ((path (plist-get design :path)))
    (if (and path (file-readable-p path))
        (find-file-other-window path)
      (user-error "No design file here"))))

(defun harness-ui-report--insert-design-section (design section start end)
  "Insert a SECTION of DESIGN, a quote target for lines START to END."
  (let ((from (point))
        (file (or (plist-get design :name) "design"))
        (last end))
    (harness-ui-report--insert-markdown section)
    (when (> (point) from)
      (harness-quote--mark
       from (point)
       (lambda (beg end)
         (let ((selected (string-trim (buffer-substring-no-properties beg end))))
           (list (list :kind "buffer" :file file
                       :line start :end last
                       :text (if (string-blank-p selected) section selected)))))
       "C-c >: a thread on this section of the design"))))

(defun harness-ui-report--insert-design (design task)
  "Insert DESIGN, TASK's design document, first in its report.
The document is read as a whole and commented on a section at a time:
C-c > quotes a section in a thread whose place is the document and its
lines.  It folds as the report's other sections do; folding it leaves
the title and [Open design]."
  (let* ((text (or (plist-get design :text) ""))
         (title (plist-get design :title))
         (summary (plist-get design :summary))
         (name (plist-get design :name))
         (folded (harness-ui-report--folded-p task "design" nil))
         (limit harness-ui-report-design-max-chars))
    (insert (harness-ui-report--fold-button
             task "design" folded (if title (format "Design: %s" title) "Design"))
            "\n")
    (insert "  ")
    (when name
      (insert (propertize name 'face 'harness-dim-face) "  "))
    (insert (harness-ui-report--button
             "[Open design]"
             (lambda () (harness-ui-report--open-design design))
             "The design document, in a window of its own")
            "\n")
    (unless folded
      (insert "\n")
      (when summary
        (harness-ui-report--insert-message summary)
        (insert "\n"))
      (let ((shown (if (> (length text) limit) (substring text 0 limit) text)))
        (dolist (section (harness-ui-report--design-sections shown))
          (harness-ui-report--insert-design-section
           design (nth 0 section) (nth 1 section) (nth 2 section))))
      (when (> (length text) limit)
        (insert (propertize (format "  More in %s" (or name "the design file"))
                            'face 'harness-dim-face)
                "\n")))
    (insert "\n")))

;;;; Interactive demos

(defun harness-ui-report--demo-key (task number)
  "Return the key of evidence NUMBER of TASK in the demo processes."
  (format "%s/%s" (or (plist-get task :id) "task") number))

(defun harness-ui-report--demo-process (task number)
  "Return the demo process of evidence NUMBER of TASK, or nil."
  (gethash (harness-ui-report--demo-key task number) harness-ui-report--demo-processes))

(defun harness-ui-report--demo-running-p (task number)
  "Return non-nil when the demo of evidence NUMBER of TASK runs."
  (let ((process (harness-ui-report--demo-process task number)))
    (and process (process-live-p process))))

(defun harness-ui-report--demo-run (task number)
  "Return the demo run of evidence NUMBER of TASK, as the harness has it now.
That is the last `demo/start' this Emacs made for it, asked of the
harness (`demo/status'), or nil when there is none and the harness does
not offer one."
  (let ((run (gethash (harness-ui-report--demo-key task number) harness-ui-report--demo-runs)))
    (and run (harness-method-exists-p 'demo/status)
         (ignore-errors (harness-call 'demo/status run)))))

(defun harness-ui-report--demo-result (task number)
  "Return the last demo start answer of evidence NUMBER of TASK, or nil."
  (gethash (harness-ui-report--demo-key task number) harness-ui-report--demo-results))

(defun harness-ui-report--start-demo (task number item)
  "Start ITEM's demo, evidence NUMBER of TASK, where the review runs it.
The start binds the task's report and demo and the demo's workspace,
runs it there, and opens the presenter that drives it; the row says
what it got, and the presenter's conversation is shown so the reviewer
can talk to it."
  (let* ((key (harness-ui-report--demo-key task number))
         (session (plist-get task :session))
         (demo (plist-get item :id)))
    (unless (harness-method-exists-p 'demo/start)
      (user-error "This harness has no demo start"))
    (unless (and (stringp session) (not (string-empty-p session)))
      (user-error "No session for this task"))
    (let ((answer (harness-call 'demo/start session demo)))
      (puthash key answer harness-ui-report--demo-results)
      (when (equal (plist-get answer :state) "running")
        (puthash key (plist-get answer :run) harness-ui-report--demo-runs)
        (harness-ui-report--show-presenter (plist-get answer :presenter)))
      (harness-ui-report--refresh task)
      (if (equal (plist-get answer :state) "running")
          (message "Demo running%s"
                   (if-let* ((vnc (plist-get answer :vnc))
                             (url (plist-get vnc :url)))
                       (format ": %s" url)
                     ""))
        (message "Demo %s: %s" (plist-get answer :state)
                 (or (plist-get (plist-get answer :reason) :text)
                     "not started"))))))

(defun harness-ui-report--show-presenter (presenter)
  "Show PRESENTER, the conversation `demo/start' opened, and say so.
The conversation is where the demo is spoken through: the reviewer
talks to it, and it drives the computer with `present_demo'."
  (when-let* ((id (plist-get presenter :session)))
    (cond ((and (fboundp 'harness-ui-display-session) (functionp 'harness-ui-display-session))
           (harness-ui-display-session id)
           (message "Presenter: %s" (or (plist-get presenter :name) id)))
          (t (message "Presenter: %s" id)))))

(defun harness-ui-report--stop-demo-run (task number)
  "Stop the demo run of evidence NUMBER of TASK, and forget it."
  (let* ((key (harness-ui-report--demo-key task number))
         (run (gethash key harness-ui-report--demo-runs)))
    (when (and run (harness-method-exists-p 'demo/stop))
      (let ((answer (ignore-errors (harness-call 'demo/stop run))))
        (puthash key answer harness-ui-report--demo-results)))
    (remhash key harness-ui-report--demo-runs)
    (harness-ui-report--refresh task)
    (message "Demo stopped")))

(defun harness-ui-report--open-vnc (run)
  "Open RUN's VNC screen in this desktop's browser, when it is a page.
The box publishes its noVNC page; Emacs cannot draw the screen itself,
and says where it is rather than pretending to."
  (let* ((vnc (plist-get run :vnc))
         (url (plist-get vnc :url)))
    (cond
     ((and (stringp url) (string-match-p "\\`https?://" url)) (browse-url url))
     ((stringp url) (kill-new url) (message "VNC address copied: %s" url))
     (t (user-error "No VNC screen")))))

(defun harness-ui-report--open-demo (item)
  "Open ITEM's demo: its URL, its page, or its directory.
A demo that is a page opens in the browser; anything else opens with
the desktop's opener, or in Emacs."
  (let ((url (plist-get item :url))
        (path (plist-get item :path)))
    (cond
     (url (browse-url url))
     ((and path (file-directory-p path))
      (let ((index (expand-file-name "index.html" path)))
        (if (file-exists-p index)
            (browse-url-of-file index)
          (harness-ui-report--open-file path))))
     ((and path (file-exists-p path))
      (if (string-match-p "\\.html?\\'" path)
          (browse-url-of-file path)
        (harness-ui-report--open-file path)))
     (t (user-error "No demo to open")))))

(defun harness-ui-report--stop-demo (task number)
  "Stop the demo of evidence NUMBER of TASK."
  (when-let* ((process (harness-ui-report--demo-process task number)))
    (when (process-live-p process) (delete-process process))
    (remhash (harness-ui-report--demo-key task number) harness-ui-report--demo-processes)
    (harness-ui-report--refresh task)
    (message "Demo stopped")))

(defun harness-ui-report--run-demo (task number item)
  "Run ITEM's demo command for TASK, the NUMBERth evidence, after a confirmation.
The command is an argv list, never a shell string.  Its output goes to
a buffer of its own, `*harness demo: TITLE*'; [Stop demo] stops it."
  (let* ((command (plist-get item :command))
         (cwd (or (plist-get item :cwd) (plist-get task :project) default-directory))
         (title (or (plist-get item :title) "demo"))
         (key (harness-ui-report--demo-key task number))
         (name (format "*harness demo: %s*" title)))
    (unless (and command (listp command) command)
      (user-error "No demo command"))
    (unless (file-directory-p cwd)
      (user-error "No demo directory"))
    (when-let* ((old (gethash key harness-ui-report--demo-processes)))
      (when (process-live-p old) (delete-process old)))
    (when (y-or-n-p (format "Run %s in %s?"
                            (mapconcat #'shell-quote-argument command " ") cwd))
      (let ((buffer (get-buffer-create name)))
        (with-current-buffer buffer
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert (format "$ %s\n\n" (mapconcat #'shell-quote-argument command " ")))))
        (condition-case err
            (let ((default-directory cwd)
                  (process (make-process
                            :name name :buffer buffer :stderr buffer
                            :command command :noquery t
                            :connection-type 'pipe
                            :sentinel
                            (lambda (process _event)
                              (unless (process-live-p process)
                                (remhash key harness-ui-report--demo-processes)
                                (ignore-errors (harness-ui-report--refresh task)))))))
              (set-process-query-on-exit-flag process nil)
              (puthash key process harness-ui-report--demo-processes)
              (message "Demo running: %s" title)
              (harness-ui-report--refresh task))
          (error
           (message "Demo failed: %s" (harness-error-message err))))))))

(defun harness-ui-report--insert-demo (item task number report)
  "Insert ITEM, the NUMBERth demo evidence of TASK, with its actions.
REPORT is the report being drawn, whose walkthrough, when it has one,
is what [Walkthrough] starts.  The actions are [Open demo], [Run demo]
or [Stop demo], and [Walkthrough]; the narration and the command are
shown as what they are."
  (let* ((title (or (plist-get item :title) "demo"))
         (url (plist-get item :url))
         (name (plist-get item :name))
         (command (plist-get item :command))
         (narration (plist-get item :narration))
         (workspace (plist-get item :workspace))
         (run (harness-ui-report--demo-run task number))
         (result (harness-ui-report--demo-result task number))
         (host-running (harness-ui-report--demo-running-p task number))
         (running (or host-running (equal (plist-get run :state) "running")))
         (vnc (and run (plist-get run :vnc))))
    (insert "  " (propertize (or url name title (car command) "demo")
                             'face 'harness-md-code-block)
            "\n  ")
    (when (or url name)
      (insert (harness-ui-report--button
               "[Open demo]"
               (lambda () (harness-ui-report--open-demo item))
               "The demo, in its window")
              " "))
    (if running
        (insert (harness-ui-report--button
                 "[Stop demo]"
                 (lambda ()
                   (if host-running
                       (harness-ui-report--stop-demo task number)
                     (harness-ui-report--stop-demo-run task number)))
                 "The demo, where it runs")
                " ")
      (when (and (harness-method-exists-p 'demo/start)
                 (stringp (plist-get item :id)))
        (insert (harness-ui-report--button
                 "[Start demo]"
                 (lambda () (harness-ui-report--start-demo task number item))
                 (if workspace
                     (format "The demo on the computer of workspace %s, with a presenter" workspace)
                   "The demo, with a presenter that drives and explains it"))
                " "))
      (when command
        (insert (harness-ui-report--button
                 "[Run demo]"
                 (lambda () (harness-ui-report--run-demo task number item))
                 "The demo command, on this machine")
                " ")))
    (when (and running vnc (or (plist-get vnc :url) (plist-get vnc :socket)))
      (insert (harness-ui-report--button
               "[Open VNC]"
               (lambda () (harness-ui-report--open-vnc run))
               "The workspace computer's screen, in this desktop's browser")
              " "))
    (when (plist-get report :walkthrough)
      (insert (harness-ui-report--button
               "[Walkthrough]"
               (lambda () (harness-ui-report--walkthrough task))
               "A review conversation about the design and the demos")))
    (insert "\n")
    (when workspace
      (insert "  " (propertize (format "In workspace %s" workspace)
                               'face 'harness-dim-face)
              "\n"))
    (when running
      (insert "  " (propertize "Demo running" 'face 'success) "\n"))
    (when (and result (not running))
      (insert "  " (propertize (or (plist-get (plist-get result :reason) :text)
                                   (plist-get result :state))
                               'face 'harness-dim-face)
              "\n"))
    (when (and running (plist-get run :commit))
      (insert "  " (propertize (format "Commit %s" (plist-get run :commit))
                               'face 'harness-dim-face)
              "\n"))
    (when command
      (insert "  " (propertize (mapconcat #'shell-quote-argument command " ")
                               'face 'harness-dim-face)
              "\n"))
    (when (and narration (not (harness-string-blank-p narration)))
      (insert "  " (propertize "Narration" 'face 'harness-label-face) "\n")
      (harness-ui-report--insert-markdown narration))
    (insert "\n")))

(defun harness-ui-report--walkthrough (task)
  "Start a conversation that walks the reviewer through TASK's report.
It is a BTW of the task's session, on the task's model, whose first
message is the report's walkthrough brief: a presenter that explains
the design, runs the demo and answers questions without changing the
work.  Voice is turned on where the voice module is loaded, before the
first message, so the first answer is spoken."
  (let* ((report (harness-ui-report--report task))
         (prompt (plist-get report :walkthrough))
         (sid (plist-get task :session))
         (title (harness-ui-report--title task)))
    (unless (and (stringp prompt) (not (harness-string-blank-p prompt)))
      (user-error "No walkthrough here"))
    (unless (and (stringp sid) (not (string-empty-p sid)))
      (user-error "No session for this task"))
    (let* ((session (and (fboundp 'harness-ui-session) (harness-ui-session sid)))
           (model (plist-get session :model))
           (name (harness-truncate-end (format "review: %s" title) 60))
           (over (current-buffer))
           (ask (lambda (id buffer)
                  (when (and buffer (buffer-live-p buffer))
                    (with-current-buffer buffer
                      (when (boundp 'harness-ui-btw--asked)
                        (setq harness-ui-btw--asked t))
                      (when (and harness-ui-report-walkthrough-voice
                                 (fboundp 'harness-voice))
                        (condition-case err
                            (funcall 'harness-voice)
                          (error (message "Voice unavailable: %s"
                                          (harness-error-message err)))))))
                  (harness-ui-call-turn id "session/prompt"
                   (list :sessionId id
                         :prompt (list (list :type "text" :text prompt)))
                   #'ignore))))
      (harness-then
       (harness-ui-request "_harness/session/btw"
                           (append (list :id sid :name name)
                                   (and model (list :model model))))
       (lambda (child)
         (let ((id (plist-get child :id)))
           (unless (stringp id)
             (user-error "No walkthrough session"))
           (if (and (fboundp 'harness-ui-btw--show)
                    (functionp harness-ui-open-session-function))
               (funcall 'harness-ui-btw--show
                        id over "the design and demo" nil
                        (lambda (buffer) (funcall ask id buffer)))
             (progn
               (when (fboundp 'harness-ui-display-session)
                 (harness-ui-display-session id))
               (let ((buffer (and (functionp harness-ui-open-session-function)
                                  (funcall harness-ui-open-session-function id))))
                 (funcall ask id buffer))))))
       (lambda (err)
         (message "Walkthrough failed: %s" (harness-error-message err)))))))

(defun harness-ui-report--image-frame ()
  "Return the frame the report's images are drawn for.
That is its window's frame (`harness-ui-report--window', the window a
report drawn away from its buffer is sized for; else the windows showing
it), or the selected one when it shows nowhere.  Not simply the selected
frame: an image is drawn a moment after the report showed
\(`harness-ui-image-load'), with whatever frame happens to be selected
then, and a screenshot is only drawable where the report shows."
  (let ((window (or harness-ui-report--window (car (get-buffer-window-list nil nil t)))))
    (if (window-live-p window) (window-frame window) (selected-frame))))

(defun harness-ui-report--image-width ()
  "Return the most pixels wide an evidence image is: the popout's width.
Less a column: an image as wide as the window would wrap onto a line of
its own."
  (let ((frame (harness-ui-report--image-frame)))
    (max 1 (- (harness-ui-popout-pixel-width harness-ui-report--window)
              (frame-char-width frame)))))

(defun harness-ui-report--image-max-height ()
  "Return the most pixels high an evidence image is in this popout.
`harness-ui-report-image-max-height', and never more than shows whole
in the popout with its caption under it."
  (let ((max harness-ui-report-image-max-height)
        (frame (harness-ui-report--image-frame)))
    (max 1 (min (if (floatp max) (round (* max (frame-inner-height frame))) max)
                (harness-ui-popout-pixel-height 2)))))

(defun harness-ui-report--view-image (path id title)
  "Show the image PATH larger, in a popout opened from the report of task ID.
TITLE names the task.  Closing it shows the report again."
  (harness-ui-popout-image path :parent (list 'report id)
                           :title (format "%s: %s" title (file-name-nondirectory path))))

(defun harness-ui-report--insert-image (path)
  "Insert the image PATH as large as the popout lets it be.
Drawing it takes a moment, which a screenshot of a whole frame does, so
a line where it goes says it is loading and the image comes as soon as
the popout has shown (`harness-ui-image-load'); `harness-ui-report--draw-image'
is what draws it.

A report drawn into a string for a view that shows it among its own
text, which has nowhere to draw later, draws the image straight away."
  (let* ((label (format "[image %s]" (abbreviate-file-name path)))
         (frame (harness-ui-report--image-frame))
         (readable (and (display-images-p frame) (not (file-remote-p path)) (file-readable-p path)))
         (too-large (and readable (harness-ui-image-too-large path frame))))
    (if (and harness-ui-report--defer-images readable (not too-large))
        (harness-ui-image-load (harness-ui-report--image-loading label path)
                               (lambda () (harness-ui-report--draw-image path label)))
      (harness-ui-report--draw-image path label))))

(defun harness-ui-report--image-loading (label path)
  "Return the line standing in for the image LABEL of PATH while it draws.
It reads where the image goes, says it is loading, and clicking it, or
RET on it, shows the image larger, as the image does
\(`harness-ui-report--view-image')."
  (let* ((task harness-ui-report--task)
         (view (lambda () (interactive) (harness-ui-report--view-image path (plist-get task :id)
                                                                       (harness-ui-report--title task)))))
    (concat (propertize (concat label " loading…") 'face 'harness-dim-face
                        'pointer 'hand 'follow-link t
                        'help-echo (format "%s\nloading… mouse-1 or RET: view it larger"
                                           (abbreviate-file-name path))
                        'keymap (harness-ui-mouse-keymap view))
            "\n")))

(defun harness-ui-report--draw-image (path label)
  "Draw the image PATH, labelled LABEL, as large as the popout lets it be.
It takes the popout's width and up to `harness-ui-report-image-max-height',
and the viewer's keys zoom it where it is; clicking it, or RET on it,
shows it larger still, in a popout of its own, and dragging it drops
the file into another application (`harness-ui-drag-source').  Without
image support, and for a remote file, which reading here would block
on, a button opening the file is inserted instead; so it is for an
image too large for Emacs to draw (`harness-ui-image-too-large'), which
says so."
  (let* ((task harness-ui-report--task)
         (frame (harness-ui-report--image-frame))
         (readable (and (display-images-p frame) (not (file-remote-p path)) (file-readable-p path)))
         (too-large (and readable (harness-ui-image-too-large path frame)))
         (view (let ((id (plist-get task :id))
                     (title (harness-ui-report--title task)))
                 (lambda () (interactive) (harness-ui-report--view-image path id title))))
         (start (point))
         (image (and readable (not too-large)
                     (harness-ui-image-insert
                      path
                      :label label
                      :max-width (harness-ui-report--image-width)
                      :max-height (harness-ui-report--image-max-height)
                      :max-scale 1
                      :frame frame
                      :keymap (harness-ui-mouse-keymap view)
                      :help-echo (harness-ui-one-line
                                  (format "%s; mouse-1 or RET: view it larger; + - zoom, 0 fits"
                                          (abbreviate-file-name path)))))))
    (if image
        (progn
          (harness-ui-drag-region start (point) path)
          (insert "\n"))
      (harness-ui-button (if too-large (harness-ui-image-too-large-label label too-large) label)
                         (lambda () (harness-ui-report--open-file path))
                         :help "Open the image")
      (insert "\n"))))

(defun harness-ui-report--insert-call (item task)
  "Insert ITEM, a reference to an earlier tool call of TASK's session, as a link.
The call's title, status, input and output are shown as the chat shows
them; [Open in the session] goes to the call.  A call that started a
sub-agent (`:child-id') names it in a session line, and the text of the
call opens that session, as the chat's call block does; the buttons
keep their own keys.  A session id in the input or the output is a
session link too (`harness-ui-link-session-ids'), as it is in the
chat, and it keeps its own keys under the call's.  The output is capped,
with a button for the rest, unless the report is drawn in full.  A call
reference without the snapshot the harness copies -- a report rebuilt
from a hand_in call's input -- names the call and links to it, nothing
else."
  (let* ((call-id (plist-get item :call-id))
         (child (let ((c (plist-get item :child-id)))
                  (and (stringp c) (not (string-empty-p c)) c)))
         (failed (plist-get item :is-error))
         (output (or (plist-get item :output) ""))
         (unresolved (and (not (plist-get item :tool))
                          (not (plist-get item :input))
                          (string-empty-p output)))
         (limit harness-ui-report-output-limit)
         (expanded (or harness-ui-report--full (gethash call-id harness-ui-report--expanded)))
         (long (and (not unresolved) (not expanded) (> (length output) limit)))
         (shown (if long (substring output 0 limit) output))
         (indent (propertize "    " 'face 'harness-md-code-block))
         (start (point)))
    ;; The link line: what it is, then the call as the chat names it.
    (insert "  " (propertize "[tool call]" 'face 'harness-dim-face
                            'help-echo "A link to this call in the session's transcript")
            " " (propertize (or (plist-get item :title) (plist-get item :tool)
                                (and call-id (format "call %s" call-id)) "tool call")
                            'face 'harness-tool-title-face)
            (cond (unresolved "")
                  (failed (propertize "  ✗ failed" 'face 'error))
                  (t (propertize "  ✓" 'face 'success)))
            "\n")
    (if unresolved
        (insert (propertize "  (the call itself is in the session)\n" 'face 'harness-dim-face))
      (when-let* ((input (plist-get item :input)))
        (insert (propertize "  input: " 'face 'harness-label-face)
                (harness-ui-link-session-ids
                 (propertize (harness-truncate-end (string-replace "\n" " " input) 400)
                             'face 'harness-dim-face))
                "\n"))
      ;; The sub-agent the call started, as the chat's session line links it.
      (when child
        (insert "  " (propertize "session: " 'face 'harness-dim-face))
        (insert (harness-ui-session-link child))
        (insert "\n"))
      (insert (propertize (if failed "  error\n" "  output\n") 'face 'harness-label-face))
      (cond
       ((string-empty-p output) (insert (propertize "  (no output)\n" 'face 'harness-dim-face)))
       (t
        (insert (harness-ui-link-session-ids
                 (propertize (if (string-suffix-p "\n" shown) shown (concat shown "\n"))
                             'face 'harness-md-code-block 'line-prefix indent 'wrap-prefix indent)))))
      ;; The call's text opens the session it started, as the chat's call
      ;; block does, with the session link's action; the buttons under it
      ;; are inserted after, so each keeps its own action and keys.
      (when child
        (harness-ui-add-session-keys (current-buffer) child (harness-ui-session-name child)
                                     start (point) (harness-ui-session-action child)))
      (when long
        ;; `harness-ui-button' inserts the button itself, at point.
        (insert "  ")
        (harness-ui-button (format "[show all (%d more chars)]" (- (length output) limit))
                           (lambda ()
                             (puthash call-id t harness-ui-report--expanded)
                             (harness-ui-popout-refresh (list 'report (plist-get task :id))))
                           :help "Show the whole output")
        (insert "\n")))
    (insert "  ")
    (harness-ui-button "[Open in the session]"
                       (lambda () (harness-ui-report--open-call item task))
                       :help "Show the session this call ran in, at the call")
    (insert "\n")))

(defun harness-ui-report--call-position (item)
  "Return where ITEM's call is in this chat buffer's transcript, or nil.
That is its block, when the transcript holds it, else the last line
naming the call above the transcript's end: never the report a review
banner shows under the transcript."
  (let ((end (if (and (boundp 'harness-chat--transcript-end) (markerp harness-chat--transcript-end))
                 (marker-position harness-chat--transcript-end)
               (point-max)))
        (node (or (plist-get item :id)
                  (and (plist-get item :call-id)
                       (boundp 'harness-chat--calls)
                       (gethash (plist-get item :call-id) harness-chat--calls))))
        (title (or (plist-get item :title) (plist-get item :tool))))
    (save-excursion
      (or (and (stringp node)
               (progn (goto-char (point-min))
                      (when-let* ((match (text-property-search-forward 'harness-chat-node node #'equal)))
                        (and (< (prop-match-beginning match) end) (prop-match-beginning match)))))
          (and (stringp title) (not (string-empty-p title))
               (progn (goto-char end) (search-backward title nil t)))))))

(defun harness-ui-report--open-call (item task)
  "Show the session of TASK and take point to ITEM's call in it."
  (let ((sid (plist-get task :session))
        (title (or (plist-get item :title) (plist-get item :tool) "")))
    (unless (and (stringp sid) (fboundp 'harness-ui-display-session))
      (user-error "The session of this call is not known here"))
    (let ((buffer (harness-ui-display-session sid)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when-let* ((pos (harness-ui-report--call-position item)))
            (goto-char pos)
            (when (eq (window-buffer) buffer) (recenter)))
          (message "Call %s: %s" (or (plist-get item :call-id) "?") title))))))

(defun harness-ui-report--insert-markdown (text)
  "Insert Markdown TEXT rendered, as whole lines.
The renderer drops the last newline; what follows starts a line of its own.
The id of a session the UI knows, written in the text, is a link to it, as
in the chat; an id in what shows as code stays as it is."
  (insert (harness-ui-link-session-ids (harness-ui-markdown-render text)
                                       #'harness-ui-markdown-code-at-p))
  (unless (bolp) (insert "\n")))

(defun harness-ui-report--ref (text &optional task)
  "Return the reference to TEXT, what TASK's report says, for a quote.
TASK is the report's task by default
\(`harness-ui-report--task'): the reference names it, so its quote links
to the report the task handed in; the session is kept for a view that
has no task."
  (let ((task (or task harness-ui-report--task)))
    (list :kind "report" :who "report" :label "hand-in report" :text text
          :task (plist-get task :id) :session (plist-get task :session))))

(defun harness-ui-report--insert-message (text)
  "Insert TEXT, a message the session wrote in Markdown, rendered.
C-c > on it quotes TEXT whole, as written, with the header and link of
the report; wherever it shows: the popout, or the banner of the task's
session."
  (let ((start (point))
        ;; The text may be read in another buffer, the chat's banner say:
        ;; the reference keeps the task it is of.
        (task harness-ui-report--task))
    (harness-ui-report--insert-markdown text)
    (put-text-property start (point) 'compose-quote text)
    (harness-quote--mark
     start (point)
     (lambda (beg end)
       (let* ((selected (string-trim (buffer-substring-no-properties beg end)))
              ;; The message whole quotes as it was written: what is
              ;; drawn loses the markers of a heading, faces alone.
              (whole (equal (harness-quote--target-run beg) (cons beg end))))
         (list (harness-ui-report--ref (if (or whole (string-empty-p selected))
                                           text selected)
                                       task))))
     "C-c > replies to the report, in a thread")))

(defun harness-ui-report--quote-target (beg end)
  "Return the references C-c > quotes from BEG to END in a report popout.
A region quotes the text it selects, under the name of the report and its
lines; without one the report's summary is quoted, as its box does."
  (cond
   ((and (> end beg) (not (harness-compose-in-p beg)))
    (let ((text (string-trim (buffer-substring-no-properties beg end))))
      (unless (string-blank-p text)
        (list (list :kind "buffer" :name (buffer-name)
                    :line (save-excursion (goto-char beg) (line-number-at-pos))
                    :end (save-excursion (goto-char end) (line-number-at-pos))
                    :text text)))))
   (t
    (when-let* ((summary (harness-ui-report--quote)))
      (list (harness-ui-report--ref summary))))))

(defun harness-ui-report--quote ()
  "Return the message this popout's report shows, to quote, or nil.
The summary, or the last message of a round that handed none in: the
popout's `compose-quote-function', so \\[compose-quote-reply]
quotes it from the box too."
  (let ((summary (plist-get (harness-ui-report--report harness-ui-report--task) :summary)))
    (and (stringp summary) (not (harness-string-blank-p summary)) summary)))

(defun harness-ui-report--item-label (item)
  "Return the short name of a piece of evidence ITEM, for its fold line."
  (let ((kind (format "%s" (plist-get item :kind))))
    (pcase kind
      ((or "image" "video" "file")
       (format "%s %s" kind (file-name-nondirectory (or (plist-get item :path) ""))))
      ("code" (format "code%s" (let ((language (plist-get item :language)))
                                 (if (and (stringp language) (not (string-blank-p language)))
                                     (format " (%s)" language) ""))))
      ("note" (harness-first-line (or (plist-get item :text) "note") 90))
      ("tool-call" (or (plist-get item :title) (plist-get item :tool) "tool call"))
      ("demo" (format "demo %s" (or (plist-get item :title) "interactive")))
      (_ kind))))

(defun harness-ui-report--insert-item (item task number report)
  "Insert evidence ITEM number NUMBER of TASK's report REPORT, with its fold line.
The number's line names what it is and folds it away; the caption under
it, when there is one, says what it shows."
  (let* ((key (list 'evidence number))
         (folded (harness-ui-report--folded-p task key nil))
         (caption (plist-get item :caption))
         (kind (format "%s" (plist-get item :kind))))
    (insert (harness-ui-report--fold-button
             task key folded (format "%d. %s" number (harness-ui-report--item-label item))
             "  ")
            "\n")
    (unless folded
      (pcase kind
        ("image" (harness-ui-report--insert-image (plist-get item :path)))
        ("video" (harness-ui-report--insert-media (plist-get item :path)))
        ("file" (harness-ui-report--insert-media (plist-get item :path)))
        ("code" (harness-ui-report--insert-markdown
                 (format "```%s\n%s\n```\n" (or (plist-get item :language) "text") (plist-get item :code))))
        ("note" (harness-ui-report--insert-markdown (or (plist-get item :text) "")))
        ("tool-call" (harness-ui-report--insert-call item task))
        ("demo" (harness-ui-report--insert-demo item task number report))
        (_ (insert (propertize (format "[%s]\n" kind) 'face 'harness-dim-face))))
      (when (and (stringp caption) (not (harness-string-blank-p caption)))
        (insert (propertize (concat "  " caption "\n") 'face 'harness-dim-face
                            'wrap-prefix "  "))))))

(defun harness-ui-report--input-item (item)
  "Return the report evidence item for ITEM, a hand_in call's evidence item.
ITEM is a string (a note) or an object, as the model wrote it.  A
`:tool_call' comes back without the snapshot the harness copies at
hand-in time; the transcript has the call itself."
  (let ((caption (harness-ui-report--text (plist-get item :caption))))
    (cond
     ((stringp item) (if (harness-string-blank-p item)
                         nil
                       (list :kind "note" :text (string-trim item))))
     ((not (listp item)) nil)
     (t
      (let* ((image (harness-ui-report--text (plist-get item :image)))
             (video (harness-ui-report--text (plist-get item :video)))
             (file (harness-ui-report--text (plist-get item :file)))
             (code (harness-ui-report--text (plist-get item :code)))
             (note (harness-ui-report--text (plist-get item :note)))
             (call (harness-ui-report--text (plist-get item :tool_call)))
             (demo (plist-get item :demo))
             (put-caption (lambda (plist)
                            (if caption (plist-put plist :caption caption) plist))))
        (cond
         (image (funcall put-caption (list :kind "image" :path image)))
         (video (funcall put-caption (list :kind "video" :path video)))
         (file (funcall put-caption (list :kind "file" :path file)))
         (code (funcall put-caption (list :kind "code"
                                          :language (or (harness-ui-report--text (plist-get item :language)) "text")
                                          :code code)))
         (note (funcall put-caption (list :kind "note" :text note)))
         (call (funcall put-caption (list :kind "tool-call" :call-id call)))
         (demo
          (let* ((object (if (stringp demo) (list :path demo) demo))
                 (command (plist-get object :command)))
            (funcall put-caption
                     (list :kind "demo"
                           :title (harness-ui-report--text (plist-get object :title))
                           :path (harness-ui-report--text (plist-get object :path))
                           :name (harness-ui-report--text (plist-get object :path))
                           :url (harness-ui-report--text (plist-get object :url))
                           :command (and command (append command nil))
                           :cwd (harness-ui-report--text (plist-get object :cwd))
                           :cwd-name (harness-ui-report--text (plist-get object :cwd))
                           :narration (harness-ui-report--text (plist-get object :narration))))))
         (t nil)))))))

(defun harness-ui-report--design-from-input (design)
  "Return the design a hand_in call with DESIGN, its input, asked for.
The document's text is read where this Emacs can read it; without it
the title and summary are still the design's."
  (let* ((object (if (stringp design) (list :path design) design))
         (path (harness-ui-report--text (plist-get object :path)))
         (text (when (and path (file-readable-p path))
                 (with-temp-buffer
                   (let ((coding-system-for-read 'utf-8))
                     (insert-file-contents path))
                   (buffer-string))))
         (title (harness-ui-report--text (plist-get object :title))))
    (list :title (or title
                     (harness-ui-report--first-heading text)
                     (and path (file-name-base path)))
          :path path
          :name path
          :summary (harness-ui-report--text (plist-get object :summary))
          :text text)))

(defun harness-ui-report--from-input (input)
  "Return the report a hand_in call with INPUT handed in, rebuilt.
For a call recorded before the report rode its result, or one whose
result is not loaded: the summary, the problem and the evidence the
model wrote, tool references without the snapshot the harness copies."
  (when (and (listp input) (harness-ui-report--text (plist-get input :summary)))
    (append
     (list :summary (plist-get input :summary))
     (when-let* ((design (plist-get input :design)))
       (list :design (harness-ui-report--design-from-input design)))
     (when-let* ((problem (harness-ui-report--text (plist-get input :problem))))
       (list :problem problem))
     (when-let* ((reproduction (harness-ui-report--text (plist-get input :reproduction))))
       (list :reproduction reproduction))
     (list :evidence (delq nil (mapcar #'harness-ui-report--input-item
                                       (append (plist-get input :evidence) nil)))))))

(defun harness-ui-report-missing-p (report)
  "Non-nil when REPORT says its round of work handed no report in.
The harness records one such when a task's turn ends without `hand_in'
\(`harness-tasks--missing-report'): no evidence, and as its summary the
last message the session wrote."
  (harness-json-true-p (plist-get report :missing)))

(defun harness-ui-report--insert-missing (report task)
  "Insert REPORT of TASK, recorded for a round that handed no report in.
It says so first, so nobody verifies the work on the strength of a
report it never wrote, then shows the session's last message, all there
is to read, and a button to the session, where the work is."
  (insert (propertize "Not handed in" 'face 'warning)
          (if-let* ((at (plist-get report :at)))
              (propertize (format "  %s" (format-time-string "%Y-%m-%d %H:%M" at)) 'face 'harness-dim-face)
            "")
          "\n\n"
          (propertize "The turn ended without hand_in." 'face 'harness-dim-face)
          "\n  ")
  ;; `harness-ui-button' inserts the button itself, at point.
  (harness-ui-button "[Open the session]"
                     (lambda () (harness-ui-report--open-session task))
                     :help "Show the session that did the work")
  (insert "\n\n")
  (let ((summary (plist-get report :summary)))
    (if (and (stringp summary) (not (harness-string-blank-p summary)))
        (progn (insert (propertize "Its last message\n" 'face 'harness-label-face) "\n")
               (harness-ui-report--insert-message summary))
      (insert (propertize "No last message.\n" 'face 'harness-dim-face)))))

(defun harness-ui-report--open-session (task)
  "Show the session of TASK."
  (let ((sid (plist-get task :session)))
    (unless (and (stringp sid) (fboundp 'harness-ui-display-session))
      (user-error "The session of this task is not known here"))
    (harness-ui-display-session sid)))

(defun harness-ui-report--insert (task)
  "Insert TASK's report: when it was handed in, the summary, the evidence.
A report recorded for a round that handed none in says so instead
\(`harness-ui-report--insert-missing')."
  (setq harness-ui-report--task task)
  (harness-ui-report--insert-report (harness-ui-report--report task) task))

(defun harness-ui-report--insert-failed (what err)
  "Insert the line that says WHAT could not be drawn, ERR being why.
Short, whatever ERR carries: an error may hold the very structure it
was about, a review with the files of a branch and the task's whole
hand-in in it, and a report that printed that would be one nobody can
read.  The full report of it is the log's."
  (harness-log 'warn "report: %s could not be drawn: %s" what (harness-error-short-message err 600))
  (unless (bolp) (insert "\n"))
  (insert (propertize (format "%s could not be drawn: %s\n" what (harness-error-short-message err 200))
                      'face 'harness-tool-error-face)))

(defun harness-ui-report--insert-report (report task)
  "Insert REPORT, TASK's report, as `harness-ui-report--insert' does.
REPORT is what the task handed in (`:summary', `:problem', `:evidence'),
or one recorded for a round that handed none in (`:missing').  What
cannot be drawn says so in a line and the report goes on: a piece of
evidence that cannot be drawn leaves the others, and a report that
cannot be drawn leaves the panels after it, which hold what is done
with the work -- [Verify] and [Send back]."
  (let ((evidence (append (and report (plist-get report :evidence)) nil)))
    (condition-case err
        (cond
         ((not report)
          (insert (propertize "This task has not handed a report in.\n" 'face 'harness-dim-face)))
         ((harness-ui-report-missing-p report)
          (harness-ui-report--insert-missing report task))
         (t
          ;; The design document first: the whole the reviewer reads and
          ;; comments on, before the code's summary.
          (when-let* ((design (plist-get report :design)))
            (harness-ui-report--insert-design design task))
          ;; What must be fixed, first: with many tasks the title alone does
          ;; not say.  A report from before this field has none and starts
          ;; with the summary as it always did.
          (when-let* ((problem (harness-ui-report--text (plist-get report :problem))))
            (insert (propertize "Problem" 'face 'harness-label-face) "\n\n")
            (harness-ui-report--insert-markdown problem)
            (insert "\n"))
          (when-let* ((reproduction (harness-ui-report--text (plist-get report :reproduction))))
            (insert (propertize "Reproduction" 'face 'harness-label-face) "\n\n")
            (harness-ui-report--insert-markdown reproduction)
            (insert "\n"))
          (insert (propertize "Handed in" 'face 'harness-label-face)
                  (if-let* ((at (plist-get report :at)))
                      (propertize (format "  %s" (format-time-string "%Y-%m-%d %H:%M" at)) 'face 'harness-dim-face)
                    "")
                  "\n\n")
          (let ((summary (plist-get report :summary)))
            (when (and (stringp summary) (not (string-empty-p summary)))
              (harness-ui-report--insert-message summary)))
          (insert "\n")
          (let* ((default (harness-ui-report--default-folded-p task))
                 (folded (harness-ui-report--folded-p task "evidence" default)))
            (insert (harness-ui-report--fold-button
                     task "evidence" folded (format "Evidence (%d)" (length evidence)))
                    (harness-ui-report--evidence-controls task report)
                    "\n")
            (if (null evidence)
                (insert (propertize "  none\n" 'face 'harness-dim-face))
              (unless folded
                ;; A blank line between pieces of evidence, so each reads as
                ;; one with its caption; none after the last.
                (cl-loop for item in evidence for first = t then nil for number from 1
                         do (unless first (insert "\n"))
                         (condition-case item-err
                             (harness-ui-report--insert-item item task number report)
                           (error (harness-ui-report--insert-failed
                                   (format "Evidence %d" number) item-err)))))))))
      (error (harness-ui-report--insert-failed "The report" err)))
    ;; A report drawn among a view's own text -- the review banner shows the
    ;; report in the session -- already has its panel there, so the panels
    ;; are the popout's only.
    (unless harness-ui-report--full
      (harness-ui-report--insert-panels task))))

(defun harness-ui-report--insert-panels (task)
  "Insert what `harness-ui-report-panel-functions' return for TASK, in order.
The popout's panels: the hooks are the popout's host, and a report drawn
as a string among a view's own text (`harness-ui-report-string') leaves
them out, the view drawing what it wants of them itself.  A panel that
fails says so in a line, and the panels after it are drawn all the same:
the review banner's [Verify] and [Send back] must not go because the
changes above them could not be read."
  (run-hook-wrapped 'harness-ui-report-panel-functions
                    (lambda (fn)
                      (condition-case err
                          (when-let* ((text (funcall fn task)))
                            (unless (string-empty-p text)
                              (unless (bolp) (insert "\n"))
                              (insert "\n" text)))
                        (error (insert "\n")
                               (harness-ui-report--insert-failed "A part of this report" err)))
                      nil)))

(defun harness-ui-report--compose (task)
  "Return the SUBMIT function of TASK's popout box, or nil for no box.
Asks `harness-ui-report-compose-functions', and keeps the answer for the
box's placeholder."
  (setq harness-ui-report--box
        (run-hook-with-args-until-success 'harness-ui-report-compose-functions task))
  (car harness-ui-report--box))

(defun harness-ui-report--placeholder ()
  "Return the hint of this popout's empty box."
  (or (cdr harness-ui-report--box) "Message…"))

(defun harness-ui-report--quote-reply (refs)
  "Reply to REFS in a thread, a card in the box of the report popout.
A review comment the report draws is the review's to reply to: the view
that draws its threads answers it before this does
\(`harness-quote-handler-function')."
  (harness-quote-default-handler refs))

(defun harness-ui-report--insert-buffer (task)
  "Insert TASK's report in the current popout, and name it in its header."
  (harness-ui-report--insert task)
  (setq-local compose-quote-function #'harness-ui-report--quote
              harness-quote-target-functions (list #'harness-ui-report--quote-target)
              harness-quote-handler-function #'harness-ui-report--quote-reply)
  (force-mode-line-update))

;;;; In the session

(defun harness-ui-report-string (task &optional window)
  "Return TASK's report drawn in full, as a string; nil when it has none.
The summary and the evidence as the popout draws them, but expanded:
every referenced call shows its whole output, with no [show all].  It
is for a view that shows the report among its own text, as the review
banner of a task's session does.  Images fit WINDOW, by default the
selected one.  The buttons work wherever the string is inserted."
  (harness-ui-report--string-for (harness-ui-report--report task) task window))

(defun harness-ui-report--string-for (report task &optional window redraw)
  "Return REPORT, TASK's report, drawn in full, as a string; nil without one.
Like `harness-ui-report-string', but for a report plist given directly,
as the transcript's hand_in tool call carries.  REDRAW draws the report
again where it is when a fold changes (`harness-ui-report--redraw-function')."
  (when report
    (let ((harness-ui-report--full t)
          ;; A string has nowhere to draw an image later: they are drawn
          ;; into it straight away.
          (harness-ui-report--defer-images nil)
          (harness-ui-report--window (or window (selected-window)))
          (harness-ui-report--task task)
          (harness-ui-report--redraw-function redraw))
      (with-temp-buffer
        (harness-ui-report--insert-report report task)
        (buffer-string)))))

;;;; The popout

(defun harness-ui-report-popout (task)
  "Show a popout of TASK's report, or bring the open one forward.
TASK is a task record as `task/list', `task/get' and `task/changed' give
it, its `:report' included.  The popout grows to
`harness-ui-report-max-height', for its images; the panels and the box
other modules give it follow the evidence (`harness-ui-report-panel-functions',
`harness-ui-report-compose-functions')."
  (interactive (list (harness-ui-report--task-at-point)))
  (let* ((id (plist-get task :id))
         (key (list 'report id))
         (title (format "%s: report" (harness-ui-report--title task)))
         (current (lambda () (gethash key harness-ui-report--reports task))))
    (puthash key task harness-ui-report--reports)
    (harness-ui-popout-show
     key title
     (lambda () (harness-ui-report--insert-buffer (funcall current)))
     :compose (lambda () (harness-ui-report--compose (funcall current)))
     :placeholder #'harness-ui-report--placeholder
     :dir (harness-ui-report--dir task)
     :max-height harness-ui-report-max-height
     :on-close (lambda () (remhash key harness-ui-report--reports)))))

(defun harness-ui-report--dir (task)
  "Return the directory TASK works in, for the box's @ completion, or nil.
Its worktree while it has one, else its project; nil when that is gone
or remote, which is never read here."
  (let ((dir (if (and (plist-get task :worktree) (not (plist-get task :worktree-removed)))
                 (plist-get task :worktree)
               (plist-get task :cwd))))
    (and (stringp dir) (not (string-empty-p dir)) (not (file-remote-p dir))
         (file-directory-p dir) dir)))

(defun harness-ui-report--task-at-point ()
  "Return the task at point of a board, for the popout command."
  (unless (and (fboundp 'harness-ui-tasks--task)
               (derived-mode-p 'harness-ui-tasks-mode))
    (user-error "Open a task board first, or pick a task from it"))
  (harness-ui-tasks--task))

(defun harness-ui-report-at-point ()
  "Pop out the report of the task at point, when it has one.
On `harness-ui-popout-at-point-functions': nil when the task at point
handed no report in, so another function may pop out what else it has."
  (when (and (derived-mode-p 'harness-ui-tasks-mode)
             (fboundp 'harness-ui-tasks--task))
    (when-let* ((task (harness-ui-tasks--task)))
      (when (harness-ui-report--report task)
        (harness-ui-report-popout task)
        t))))

(defun harness-ui-report--on-task-changed (event args)
  "Follow EVENT: on `task/changed' for the task in ARGS, redraw its open report.
Once the review is decided -- the task verified or sent back -- its
popout closes instead, dropping any draft in its box, whoever decided
it.  Only that change closes it, so the report of a task decided before
it opened, a done one say, stays open through later changes."
  (when (equal event "task/changed")
    (when-let* ((task (car args))
                (id (plist-get task :id))
                (key (list 'report id)))
      (when (harness-ui-popout-buffer key)
        (if (harness-ui-report--decided-p (gethash key harness-ui-report--reports) task)
            (harness-ui-popout-close key t)
          (puthash key task harness-ui-report--reports)
          (harness-ui-popout-refresh key))))))

(defun harness-ui-report--chat-hand-in (block result)
  "Return the report BLOCK's hand_in call handed in, drawn in full, or nil.
On `harness-chat-tool-body-functions', so an expanded hand_in call in the
transcript shows what the review shows, after it left review too: the
report, and what `harness-ui-report-hand-in-functions' draw with it --
the review adds the changes and threads of the task's review, so a
previous hand-in call reads as the current one does.  A fold in the call
draws the call again, and the chat's tail with it.
Nil for any other call, for a call still running, and for a hand_in
whose report is not known: the chat then shows the call's input and
output as usual.  So it does for one that cannot be drawn, with the
reason in the log: a block that fails to draw would take the whole
history of the session with it."
  (when result
    (condition-case err
        (let ((node (harness-chat-block-node block)))
          (when (and (equal (harness-chat--str (plist-get node :kind)) "tool-call")
                     (equal (harness-chat--str (plist-get node :tool)) "hand_in"))
            (when-let* ((report (or (plist-get (plist-get result :meta) :report)
                                    (harness-ui-report--from-input (plist-get node :input)))))
              (let* ((task (or (and (fboundp 'harness-ui-review--task)
                                    (harness-ui-review--task
                                     harness-ui-session-id))
                               (list :id (plist-get (plist-get result :meta)
                                                    :task-id)
                                     :session harness-ui-session-id)))
                     (buffer (current-buffer))
                     (window (car (get-buffer-window-list nil nil t)))
                     (redraw (lambda ()
                               (when (buffer-live-p buffer)
                                 (with-current-buffer buffer
                                   (harness-chat--rerender block)
                                   ;; The review banner below shows the
                                   ;; same hand-in; a fold shows in both.
                                   (when (functionp
                                          harness-compose-redraw-function)
                                     (funcall
                                      harness-compose-redraw-function)))))))
                (or (run-hook-with-args-until-success
                     'harness-ui-report-hand-in-functions
                     report task window redraw)
                    (harness-ui-report--string-for
                     report task window redraw))))))
      (error (harness-log 'warn "report: a hand_in call could not be drawn as the report: %s"
                          (harness-error-short-message err 600))
             nil))))

;;;; Module

(defun harness-ui-report--init ()
  "Offer the task at point to the shared popout command, and follow tasks."
  (add-hook 'harness-ui-popout-at-point-functions #'harness-ui-report-at-point)
  (add-hook 'harness-ui-event-functions #'harness-ui-report--on-task-changed)
  (add-hook 'harness-chat-tool-body-functions #'harness-ui-report--chat-hand-in))

(harness-define-module 'ui-report
  :doc "A task's report: its final message and evidence, in a popout and in its session."
  :requires '(ui ui-popout ui-tasks)
  :init #'harness-ui-report--init)

(provide 'harness-ui-report)
;;; harness-ui-report.el ends here
