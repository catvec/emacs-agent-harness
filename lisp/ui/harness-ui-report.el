;;; harness-ui-report.el --- A task's report: its final message and evidence  -*- lexical-binding: t; -*-

;;; Commentary:

;; What a task's session hands in with `hand_in': the final message, in
;; markdown, and the evidence for it -- images, videos, files, code,
;; notes, and references to earlier tool calls of the session.  It shows
;; in a popout (`harness-ui-popout'), so it can be read without opening
;; the session, from
;;
;;   the board  [Report] on a card that has one; the board's item at
;;              point (`SPC', through the shared
;;              `harness-ui-popout-at-point-functions') too;
;;   the chat   the review banner's [Report] button.
;;
;; Inside the task's session the report is not behind a button: while
;; the task waits for review, the review banner shows it in full,
;; expanded, between its heading and its buttons (`harness-ui-report-string').
;;
;; The report is drawn from the task record the harness holds: the board
;; and the chat both pass the record they already have, and a popout
;; follows `task/changed' so what it shows is current.  A referenced tool
;; call is the link it is, drawn as the chat draws calls: its title and
;; status, the input it ran with, its output (capped in the popout, with
;; a button for the rest; whole in the session), and [Open in the
;; session], which shows the session and takes point to the call.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'button)
(require 'mailcap)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)
(require 'harness-ui-markdown)
(require 'harness-ui-popout)
(require 'harness-ui-tasks)

(defgroup harness-ui-report nil
  "A task's report: its final message and evidence." :group 'harness-ui)

(defcustom harness-ui-report-output-limit 1200
  "Characters of a referenced tool call's output shown before [show all]."
  :type 'integer :group 'harness-ui-report)

(defcustom harness-ui-report-image-max-height 400
  "Maximum pixel height of an evidence image."
  :type 'integer :group 'harness-ui-report)

(defvar harness-ui-report--reports (make-hash-table :test 'equal)
  "Popout key -> the task record its popout shows, kept current.")

(defvar-local harness-ui-report--task nil
  "The task record this popout shows.")

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
         (size (nth 1 (file-attributes path))))
    (list :path path :mime mime :size size :name (file-name-nondirectory path))))

(defun harness-ui-report--insert-media (path)
  "Insert the media line for PATH, with ui-media when it is loaded."
  (if (and (fboundp 'harness-ui-media-render-attachment) (file-exists-p path))
      (insert (harness-ui-media-render-attachment (harness-ui-report--file-attachment path)))
    ;; `harness-ui-button' inserts the button itself, at point.
    (insert " ")
    (harness-ui-button (format "[%s]" (file-name-nondirectory path))
                       (lambda () (harness-ui-report--open-file path))
                       :help path)
    (insert "\n")))

(defun harness-ui-report--open-file (path)
  "Open PATH with the desktop's opener, or in Emacs."
  (if (and (fboundp 'harness-ui-media-open)
           (cl-find-if #'executable-find '("xdg-open" "mpv" "open")))
      (harness-ui-media-open path)
    (find-file-other-window path)))

(defun harness-ui-report--insert-image (path)
  "Insert the image PATH; clicking it opens the file.
Without image support a button is inserted instead."
  (let ((label (format "[image %s]" (abbreviate-file-name path))))
    (if (and (display-images-p) (file-readable-p path))
        (let* ((window (or harness-ui-report--window (car (get-buffer-window-list nil nil t))))
               (width (floor (* 0.6 (if window (window-body-width window t) 800))))
               (image (condition-case nil
                          (create-image path nil nil :max-width width
                                        :max-height harness-ui-report-image-max-height)
                        (error nil))))
          (if image
              (insert (propertize label 'display image 'help-echo path
                                  'keymap (let ((map (make-sparse-keymap)))
                                            (define-key map [mouse-1]
                                              (lambda () (interactive) (harness-ui-report--open-file path)))
                                            map))
                      "\n")
            (insert label "\n")))
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

(defun harness-ui-report--insert (task)
  "Insert TASK's report: when it was handed in, the summary, the evidence."
  (setq harness-ui-report--task task)
  (let* ((report (harness-ui-report--report task))
         (evidence (append (and report (plist-get report :evidence)) nil)))
    (if (not report)
        (insert (propertize "This task has not handed a report in.\n" 'face 'harness-dim-face))
      (insert (propertize "Handed in" 'face 'harness-label-face)
              (if-let* ((at (plist-get report :at)))
                  (propertize (format "  %s" (format-time-string "%Y-%m-%d %H:%M" at)) 'face 'harness-dim-face)
                "")
              "\n\n")
      (let ((summary (plist-get report :summary)))
        (when (and (stringp summary) (not (string-empty-p summary)))
          (harness-ui-report--insert-markdown summary)))
      (insert "\n" (propertize (format "Evidence (%d)\n" (length evidence)) 'face 'harness-label-face) "\n")
      (if evidence
          (dolist (item evidence) (harness-ui-report--insert-item item task))
        (insert (propertize "  none\n" 'face 'harness-dim-face))))))

(defun harness-ui-report--insert-buffer (task)
  "Insert TASK's report in the current popout, and name it in its header."
  (harness-ui-report--insert task)
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
it, its `:report' included."
  (interactive (list (harness-ui-report--task-at-point)))
  (let* ((id (plist-get task :id))
         (key (list 'report id))
         (title (format "%s: report" (harness-ui-report--title task))))
    (puthash key task harness-ui-report--reports)
    (harness-ui-popout-show
     key title
     (lambda ()
       (let ((current (gethash key harness-ui-report--reports task)))
         (harness-ui-report--insert-buffer current)))
     :on-close (lambda () (remhash key harness-ui-report--reports)))))

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
  "Follow `task/changed': an open report popout of that task draws again."
  (when (equal event "task/changed")
    (when-let* ((task (car args))
                (id (plist-get task :id))
                (key (list 'report id)))
      (when (harness-ui-popout-buffer key)
        (puthash key task harness-ui-report--reports)
        (harness-ui-popout-refresh key)))))

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
