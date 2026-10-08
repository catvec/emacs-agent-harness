;;; harness-ui-report.el --- A task's report: its final message and evidence  -*- lexical-binding: t; -*-

;;; Commentary:

;; What a task's session hands in with `hand_in': the final message, in
;; markdown, and the evidence for it -- images, videos, files, code,
;; notes, and references to earlier tool calls of the session.  It shows
;; in a popout (`harness-ui-popout'), so it can be read without opening
;; the session, from
;;
;;   the board  [Review] on a card that has one; the board's item at
;;              point (`SPC', through the shared
;;              `harness-ui-popout-at-point-functions') too;
;;   the chat   the review banner's [Review] button.
;;
;; The button reads [Review], to look the work over, not [Report],
;; which reads as reporting the agent for something bad.
;;
;; Inside the task's session the report is not behind a button: while
;; the task waits for review, the review banner shows it in full,
;; expanded, between its heading and its buttons (`harness-ui-report-string').
;;
;; The report is drawn from the task record the harness holds: the board
;; and the chat both pass the record they already have, and a popout
;; follows `task/changed' so what it shows is current.  Once the task
;; is verified or sent back its popout closes, wherever that was done --
;; the board, the session's banner, the Review switch, an agent: the
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
;; Images are the evidence most worth seeing, so they show large: the
;; popout's width and much of the frame's height, the popout growing
;; taller than others for them (`harness-ui-report-max-height').
;; Clicking one, or RET on it, shows it larger still in a popout of its
;; own (`harness-ui-popout-image'), which q closes, back to the report.
;; Dragging one, from either, drops its file into another application,
;; a chat app or a browser, to pass the evidence on (harness-ui-drag.el).
;;
;; Other modules add to the popout as they add to a chat:
;; `harness-ui-report-panel-functions' draws a panel at the end of the
;; report and `harness-ui-report-compose-functions' gives it a compose
;; box.  The review module puts the banner a task's session shows there,
;; [Verify] and [Send back], with the box taking the feedback, so work
;; can be accepted from its report.

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

(defvar harness-ui-report--reports (make-hash-table :test 'equal)
  "Popout key -> the task record its popout shows, kept current.")

(defvar-local harness-ui-report--task nil
  "The task record this popout shows.")

(defvar-local harness-ui-report--box nil
  "What `harness-ui-report-compose-functions' gave this popout at its last draw.
That is (SUBMIT . PLACEHOLDER), or nil for no box.")

(defvar-local harness-ui-report--expanded (make-hash-table :test 'equal)
  "Referenced tool calls whose full output this popout shows.")

(defvar harness-ui-report--full nil
  "Non-nil while a report is drawn in full: every call's whole output.")

(defvar harness-ui-report--window nil
  "The window a report drawn away from its buffer is sized for.
`harness-ui-report-string' draws in a scratch buffer no window shows;
its images fit this one instead.")

(defvar harness-chat--transcript-end)

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

(defun harness-ui-report--image-width ()
  "Return the most pixels wide an evidence image is: the popout's width.
Less a column: an image as wide as the window would wrap onto a line of
its own."
  (max 1 (- (harness-ui-popout-pixel-width harness-ui-report--window)
            (frame-char-width))))

(defun harness-ui-report--image-max-height ()
  "Return the most pixels high an evidence image is in this popout.
`harness-ui-report-image-max-height', and never more than shows whole
in the popout with its caption under it."
  (let ((max harness-ui-report-image-max-height))
    (max 1 (min (if (floatp max) (round (* max (frame-inner-height))) max)
                (harness-ui-popout-pixel-height 2)))))

(defun harness-ui-report--view-image (path id title)
  "Show the image PATH larger, in a popout opened from the report of task ID.
TITLE names the task.  Closing it shows the report again."
  (harness-ui-popout-image path :parent (list 'report id)
                           :title (format "%s: %s" title (file-name-nondirectory path))))

(defun harness-ui-report--insert-image (path)
  "Insert the image PATH as large as the popout lets it be.
It takes the popout's width and up to `harness-ui-report-image-max-height';
clicking it, or RET on it, shows it larger still, in a popout of its
own, and dragging it drops the file into another application
\(`harness-ui-drag-source').  Without image support, and for a remote
file, which reading here would block on, a button opening the file is
inserted instead."
  (let* ((label (format "[image %s]" (abbreviate-file-name path)))
         (task harness-ui-report--task)
         (image (and (display-images-p) (not (file-remote-p path)) (file-readable-p path)
                     (ignore-errors
                       (create-image path nil nil
                                     :max-width (harness-ui-report--image-width)
                                     :max-height (harness-ui-report--image-max-height))))))
    (if image
        (let ((view (let ((id (plist-get task :id))
                          (title (harness-ui-report--title task)))
                      (lambda () (interactive) (harness-ui-report--view-image path id title)))))
          (insert (harness-ui-drag-source
                   (propertize label 'display image 'pointer 'hand
                               'help-echo (format "%s\nmouse-1 or RET: view it larger" (abbreviate-file-name path))
                               'keymap (harness-ui-mouse-keymap view))
                   path)
                  "\n"))
      (harness-ui-button label (lambda () (harness-ui-report--open-file path))
                         :help "Open the image")
      (insert "\n"))))

(defun harness-ui-report--insert-call (item task)
  "Insert ITEM, a reference to an earlier tool call of TASK's session, as a link.
The call's title, status, input and output are shown as the chat shows
them; [Open in the session] goes to the call.  The output is capped,
with a button for the rest, unless the report is drawn in full."
  (let* ((call-id (plist-get item :call-id))
         (failed (plist-get item :is-error))
         (output (or (plist-get item :output) ""))
         (limit harness-ui-report-output-limit)
         (expanded (or harness-ui-report--full (gethash call-id harness-ui-report--expanded)))
         (long (and (not expanded) (> (length output) limit)))
         (shown (if long (substring output 0 limit) output))
         (indent (propertize "    " 'face 'harness-md-code-block)))
    ;; The link line: what it is, then the call as the chat names it.
    (insert "  " (propertize "[tool call]" 'face 'harness-dim-face
                            'help-echo "A link to this call in the session's transcript")
            " " (propertize (or (plist-get item :title) (plist-get item :tool) "tool call")
                            'face 'harness-tool-title-face)
            (if failed (propertize "  ✗ failed" 'face 'error) (propertize "  ✓" 'face 'success))
            "\n")
    (when-let* ((input (plist-get item :input)))
      (insert (propertize "  input: " 'face 'harness-label-face)
              (propertize (harness-truncate-end (string-replace "\n" " " input) 400) 'face 'harness-dim-face)
              "\n"))
    (insert (propertize (if failed "  error\n" "  output\n") 'face 'harness-label-face))
    (cond
     ((string-empty-p output) (insert (propertize "  (no output)\n" 'face 'harness-dim-face)))
     (t
      (insert (propertize (if (string-suffix-p "\n" shown) shown (concat shown "\n"))
                          'face 'harness-md-code-block 'line-prefix indent 'wrap-prefix indent))
      (when long
        ;; `harness-ui-button' inserts the button itself, at point.
        (insert "  ")
        (harness-ui-button (format "[show all (%d more chars)]" (- (length output) limit))
                           (lambda ()
                             (puthash call-id t harness-ui-report--expanded)
                             (harness-ui-popout-refresh (list 'report (plist-get task :id))))
                           :help "Show the whole output")
        (insert "\n")))))
  (insert "  ")
  (harness-ui-button "[Open in the session]"
                     (lambda () (harness-ui-report--open-call item task))
                     :help "Show the session this call ran in, at the call")
  (insert "\n"))

(defun harness-ui-report--call-position (item)
  "Return where ITEM's call is in this chat buffer's transcript, or nil.
That is its block, when the transcript holds it, else the last line
naming the call above the transcript's end: never the report a review
banner shows under the transcript."
  (let ((end (if (and (boundp 'harness-chat--transcript-end) (markerp harness-chat--transcript-end))
                 (marker-position harness-chat--transcript-end)
               (point-max)))
        (node (plist-get item :id))
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
The renderer drops the last newline; what follows starts a line of its own."
  (harness-ui-markdown-insert text)
  (unless (bolp) (insert "\n")))

(defun harness-ui-report--insert-message (text)
  "Insert TEXT, a message the session wrote in Markdown, rendered.
\\[harness-compose-quote-reply] on it quotes TEXT whole, as written,
wherever it shows: the popout, or the banner of the task's session."
  (let ((start (point)))
    (harness-ui-report--insert-markdown text)
    (put-text-property start (point) 'harness-compose-quote text)))

(defun harness-ui-report--quote ()
  "Return the message this popout's report shows, to quote, or nil.
The summary, or the last message of a round that handed none in: the
popout's `harness-compose-quote-function', so \\[harness-compose-quote-reply]
quotes it from the box too."
  (let ((summary (plist-get (harness-ui-report--report harness-ui-report--task) :summary)))
    (and (stringp summary) (not (harness-string-blank-p summary)) summary)))

(defun harness-ui-report--insert-item (item task)
  "Insert one piece of evidence, ITEM, of TASK's report, with its caption."
  (let ((kind (format "%s" (plist-get item :kind)))
        (caption (plist-get item :caption)))
    (pcase kind
      ("image" (harness-ui-report--insert-image (plist-get item :path)))
      ("video" (harness-ui-report--insert-media (plist-get item :path)))
      ("file" (harness-ui-report--insert-media (plist-get item :path)))
      ("code" (harness-ui-report--insert-markdown
               (format "```%s\n%s\n```\n" (or (plist-get item :language) "text") (plist-get item :code))))
      ("note" (harness-ui-report--insert-markdown (or (plist-get item :text) "")))
      ("tool-call" (harness-ui-report--insert-call item task))
      (_ (insert (propertize (format "[%s]\n" kind) 'face 'harness-dim-face))))
    (when (and (stringp caption) (not (harness-string-blank-p caption)))
      (insert (propertize (concat "  " caption "\n") 'face 'harness-dim-face
                          'wrap-prefix "  ")))))

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
          (propertize (concat "Its turn ended without hand_in, so there is no summary and no evidence. "
                              "Check the work in its session before you verify it.")
                      'face 'harness-dim-face)
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
      (insert (propertize "It wrote no message either.\n" 'face 'harness-dim-face)))))

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
  (let* ((report (harness-ui-report--report task))
         (evidence (append (and report (plist-get report :evidence)) nil)))
    (cond
     ((not report)
      (insert (propertize "This task has not handed a report in.\n" 'face 'harness-dim-face)))
     ((harness-ui-report-missing-p report)
      (harness-ui-report--insert-missing report task))
     (t
      (insert (propertize "Handed in" 'face 'harness-label-face)
              (if-let* ((at (plist-get report :at)))
                  (propertize (format "  %s" (format-time-string "%Y-%m-%d %H:%M" at)) 'face 'harness-dim-face)
                "")
              "\n\n")
      (let ((summary (plist-get report :summary)))
        (when (and (stringp summary) (not (string-empty-p summary)))
          (harness-ui-report--insert-message summary)))
      (insert "\n" (propertize (format "Evidence (%d)\n" (length evidence)) 'face 'harness-label-face) "\n")
      (if evidence
          ;; A blank line between pieces of evidence, so each reads as one
          ;; with its caption; none after the last.
          (cl-loop for item in evidence for first = t then nil
                   do (unless first (insert "\n"))
                   (harness-ui-report--insert-item item task))
        (insert (propertize "  none\n" 'face 'harness-dim-face)))))
    ;; A report drawn among a view's own text -- the review banner shows the
    ;; report in the session -- already has its panel there, so the panels
    ;; are the popout's only.
    (unless harness-ui-report--full
      (harness-ui-report--insert-panels task))))

(defun harness-ui-report--insert-panels (task)
  "Insert what `harness-ui-report-panel-functions' return for TASK, in order.
The popout's panels: the hooks are the popout's host, and a report drawn
as a string among a view's own text (`harness-ui-report-string') leaves
them out, the view drawing what it wants of them itself."
  (run-hook-wrapped 'harness-ui-report-panel-functions
                    (lambda (fn)
                      (when-let* ((text (funcall fn task)))
                        (unless (string-empty-p text)
                          (unless (bolp) (insert "\n"))
                          (insert "\n" text)))
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

(defun harness-ui-report--insert-buffer (task)
  "Insert TASK's report in the current popout, and name it in its header."
  (harness-ui-report--insert task)
  (setq-local harness-compose-quote-function #'harness-ui-report--quote)
  (force-mode-line-update))

;;;; In the session

(defun harness-ui-report-string (task &optional window)
  "Return TASK's report drawn in full, as a string; nil when it has none.
The summary and the evidence as the popout draws them, but expanded:
every referenced call shows its whole output, with no [show all].  It
is for a view that shows the report among its own text, as the review
banner of a task's session does.  Images fit WINDOW, by default the
selected one.  The buttons work wherever the string is inserted."
  (when (harness-ui-report--report task)
    (let ((harness-ui-report--full t)
          (harness-ui-report--window (or window (selected-window))))
      (with-temp-buffer
        (harness-ui-report--insert task)
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

;;;; Module

(defun harness-ui-report--init ()
  "Offer the task at point to the shared popout command, and follow tasks."
  (add-hook 'harness-ui-popout-at-point-functions #'harness-ui-report-at-point)
  (add-hook 'harness-ui-event-functions #'harness-ui-report--on-task-changed))

(harness-define-module 'ui-report
  :doc "A task's report: its final message and evidence, in a popout and in its session."
  :requires '(ui ui-popout ui-tasks)
  :init #'harness-ui-report--init)

(provide 'harness-ui-report)
;;; harness-ui-report.el ends here
