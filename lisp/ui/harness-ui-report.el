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
;; The report is drawn from the task record the harness holds: the board
;; and the chat both pass the record they already have, and a popout
;; follows `task/changed' so what it shows is current.  Once the task
;; is verified its popout closes, whatever verified it -- [Verify] on
;; the board or the banner, the Review switch, an agent: the review the
;; report was opened for is over.  The report of a task verified before
;; it opened, a done one, stays open.  A referenced tool
;; call is the link it is, drawn as the chat draws calls: its title and
;; status, the input it ran with, its output (capped, with a button for
;; the rest), and [Open in the session], which shows the session and
;; takes point near the call.

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

(defun harness-ui-report--report (task)
  "Return TASK's report plist, or nil."
  (plist-get task :report))

(defun harness-ui-report--verified-p (task)
  "Non-nil when the user verified TASK's work."
  (harness-json-true-p (plist-get task :verified)))

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
    (insert " " (harness-ui-button (format "[%s]" (file-name-nondirectory path))
                                   (lambda () (harness-ui-report--open-file path))
                                   :help path)
            "\n")))

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
        (let* ((window (car (get-buffer-window-list nil nil t)))
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
      (insert (harness-ui-button label (lambda () (harness-ui-report--open-file path))
                                 :help "Open the image")
              "\n"))))

(defun harness-ui-report--insert-call (item)
  "Insert ITEM, a reference to an earlier tool call of the session, as a link.
The call's title, status, input and output are shown as the chat shows
them; [Open in the session] goes to the call."
  (let* ((call-id (plist-get item :call-id))
         (failed (plist-get item :is-error))
         (output (or (plist-get item :output) ""))
         (limit harness-ui-report-output-limit)
         (expanded (gethash call-id harness-ui-report--expanded))
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
      (insert (propertize (unless (string-suffix-p "\n" shown) (concat shown "\n"))
                          'face 'harness-md-code-block 'line-prefix indent 'wrap-prefix indent))
      (when long
        (insert "  " (harness-ui-button (format "[show all (%d more chars)]" (- (length output) limit))
                                        (lambda ()
                                          (puthash call-id t harness-ui-report--expanded)
                                          (harness-ui-popout-refresh
                                           (list 'report (plist-get harness-ui-report--task :id))))
                                        :help "Show the whole output")
                "\n")))))
  (insert "  " (harness-ui-button "[Open in the session]"
                                 (lambda () (harness-ui-report--open-call item))
                                 :help "Show the session this call ran in")
          "\n"))

(defun harness-ui-report--open-call (item)
  "Show the session of ITEM's call and take point near the call."
  (let* ((task harness-ui-report--task)
         (sid (plist-get task :session))
         (title (or (plist-get item :title) (plist-get item :tool) "")))
    (unless (and (stringp sid) (fboundp 'harness-ui-display-session))
      (user-error "The session of this call is not known here"))
    (let ((buffer (harness-ui-display-session sid)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (goto-char (point-max))
          (when (and (not (string-empty-p title))
                     (search-backward title nil t))
            (recenter))
          (message "Call %s: %s" (or (plist-get item :call-id) "?") title))))))

(defun harness-ui-report--insert-item (item)
  "Insert one piece of evidence, ITEM, with its caption."
  (let ((kind (format "%s" (plist-get item :kind)))
        (caption (plist-get item :caption)))
    (pcase kind
      ("image" (harness-ui-report--insert-image (plist-get item :path)))
      ("video" (harness-ui-report--insert-media (plist-get item :path)))
      ("file" (harness-ui-report--insert-media (plist-get item :path)))
      ("code" (harness-ui-markdown-insert
               (format "```%s\n%s\n```\n" (or (plist-get item :language) "text") (plist-get item :code))))
      ("note" (harness-ui-markdown-insert (concat (or (plist-get item :text) "") "\n")))
      ("tool-call" (harness-ui-report--insert-call item))
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
          (harness-ui-markdown-insert (concat summary "\n"))))
      (insert "\n" (propertize (format "Evidence (%d)\n" (length evidence)) 'face 'harness-label-face) "\n")
      (if evidence
          (dolist (item evidence) (harness-ui-report--insert-item item))
        (insert (propertize "  none\n" 'face 'harness-dim-face))))))

(defun harness-ui-report--insert-buffer (task)
  "Insert TASK's report in the current popout, and name it in its header."
  (harness-ui-report--insert task)
  (force-mode-line-update))

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
  "Follow EVENT: on `task/changed' for the task in ARGS, redraw its open report.
Once the task is verified its popout closes instead, dropping any draft
in its box: whatever verified it, the review is settled.  Only the
change to verified closes it, so the report of a task verified before
it opened stays open through later changes."
  (when (equal event "task/changed")
    (when-let* ((task (car args))
                (id (plist-get task :id))
                (key (list 'report id)))
      (when (harness-ui-popout-buffer key)
        (if (and (harness-ui-report--verified-p task)
                 (not (harness-ui-report--verified-p (gethash key harness-ui-report--reports))))
            (harness-ui-popout-close key t)
          (puthash key task harness-ui-report--reports)
          (harness-ui-popout-refresh key))))))

;;;; Module

(defun harness-ui-report--init ()
  "Offer the task at point to the shared popout command, and follow tasks."
  (add-hook 'harness-ui-popout-at-point-functions #'harness-ui-report-at-point)
  (add-hook 'harness-ui-event-functions #'harness-ui-report--on-task-changed))

(harness-define-module 'ui-report
  :doc "A task's report: its final message and evidence, in a popout."
  :requires '(ui ui-popout ui-tasks)
  :init #'harness-ui-report--init)

(provide 'harness-ui-report)
;;; harness-ui-report.el ends here
