;;; harness-ui-compose-test.el --- Tests for the compose box's attachments  -*- lexical-binding: t; -*-

;;; Commentary:

;; The compose box in a host of its own (a read-only line, the chips,
;; the box): links dropped on it download in the background behind a
;; chip with their progress, web pages go in as text, data: links and
;; dropped text land in the box, images and videos show thumbnails, and
;; yanking takes images and copied files off the clipboard into the
;; media ring, and C-c C-v is no longer the box's, so a chat's [Verify]
;; keeps it.  The clipboard and the display are stubbed; downloads go
;; to a web server in this Emacs.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)

(defvar harness-media-ring)
(defvar harness-media-ring--loaded)
(defvar harness-media-ring-max)
(defvar-local harness-ui-compose-test--draws 0 "How many times the test host drew.")

(defun harness-ui-compose-test--draw ()
  "Draw the test host: a read-only line, the attachment chips and the box."
  (cl-incf harness-ui-compose-test--draws)
  (harness-compose-capture)
  (let ((inhibit-read-only t)
        (offset (and (harness-compose-in-p) (- (point) harness-compose-start))))
    (erase-buffer)
    (insert (propertize "The transcript.\n" 'read-only t))
    (let ((start (point)))
      (harness-compose-insert-attachments)
      (put-text-property start (point) 'read-only t))
    (harness-compose-insert)
    (when offset (goto-char (min (+ harness-compose-start offset) harness-compose-end)))))

(defmacro harness-ui-compose-test-with (&rest body)
  "Run BODY in a buffer hosting a compose box, shown in the selected window.
`dir' is the project and the state directory."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp-server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent acp ui ui-media ui-compose))
         (harness-test-load-module m)))
     (setq harness-media-ring nil harness-media-ring--loaded nil)
     (let ((harness-acp-token nil)
           (default-directory dir)
           (buf (generate-new-buffer "*compose test*")))
       (unwind-protect
           (save-window-excursion
             (set-window-buffer (selected-window) buf)
             (with-current-buffer buf
               (use-local-map (make-composed-keymap nil harness-compose-map))
               (harness-compose-setup :project (lambda () dir) :redraw #'harness-ui-compose-test--draw)
               (harness-ui-compose-test--draw)
               ,@body))
         (when (buffer-live-p buf) (kill-buffer buf))
         (setq harness-media-ring nil harness-media-ring--loaded nil)
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))))))

(defmacro harness-ui-compose-test-messages (&rest body)
  "Run BODY and return the messages it showed, oldest first."
  (declare (indent 0))
  `(let ((messages nil))
     (cl-letf (((symbol-function 'message)
                (lambda (format &rest args)
                  (when format (push (apply #'format-message format args) messages)))))
       ,@body)
     (nreverse messages)))

(defun harness-ui-compose-test--bytes (file)
  "Return the bytes of FILE."
  (with-temp-buffer (set-buffer-multibyte nil) (insert-file-contents-literally file) (buffer-string)))

(defun harness-ui-compose-test--pending ()
  "Return the first pending download of the box, or nil."
  (cl-find-if (lambda (a) (plist-get a :pending)) harness-compose-attachments))

(defun harness-ui-compose-test--settled ()
  "Non-nil once no download of the box is pending."
  (not (harness-ui-compose-test--pending)))

;;;; Links dropped on the box

(ert-deftest harness-ui-compose-dropped-link-downloads-behind-a-chip ()
  (skip-unless (executable-find "curl"))
  (harness-ui-compose-test-with
    (let* ((body (concat harness-test-png (make-string 30000 ?p)))
           (server (harness-test-http-serve
                    `(("/images/cat.png" 200 (("Content-Type" . "image/png")) ,body :chunks 5 :delay 0.2)
                      ("/again/cat.png" 200 (("Content-Type" . "image/png")) ,body))))
           (url (harness-test-http-url server "/images/cat.png")))
      (unwind-protect
          (let ((start (float-time)))
            ;; The drop returns at once: curl downloads in the background.
            (should (eq 'private (dnd-handle-multiple-urls (selected-window) (list url) 'private)))
            (should (< (- (float-time) start) 0.5))
            (let* ((pending (harness-ui-compose-test--pending))
                   (ov (cdr (assoc (plist-get pending :id) harness-compose--progress))))
              (should (equal "cat.png" (plist-get pending :name)))
              (should (equal url (plist-get pending :url)))
              ;; The chip is an overlay over one character of the tail.
              (should (overlayp ov))
              (should (eq (current-buffer) (overlay-buffer ov)))
              (should (string-match-p "cat\\.png" (overlay-get ov 'display)))
              ;; The message waits for the download.
              (should-error (harness-compose-take) :type 'user-error)
              ;; The progress ticks redraw the overlay, never the text.
              (let ((tick (buffer-chars-modified-tick)))
                (harness-test-wait (lambda () (string-match-p "[0-9]+% of" (overlay-get ov 'display))) 5 "progress")
                (should (= tick (buffer-chars-modified-tick)))))
            (harness-test-wait #'harness-ui-compose-test--settled 10 "the download")
            (let ((att (car harness-compose-attachments)))
              (should (= 1 (length harness-compose-attachments)))
              (should (equal "image/png" (plist-get att :mime)))
              (should (equal url (plist-get att :url)))
              (should (equal (expand-file-name "downloads/cat.png" harness-state-directory) (plist-get att :path)))
              (should (equal body (harness-ui-compose-test--bytes (plist-get att :path))))
              (should (= (length body) (plist-get att :size)))
              (should (equal "image" (plist-get (harness-compose-attachment-block att) :type))))
            (should-not harness-compose--progress)
            (should-not (directory-files (expand-file-name "downloads/" harness-state-directory) nil "\\`\\.partial"))
            (goto-char (point-min))
            (should (search-forward "cat.png (" nil t))
            ;; The same link again is attached already; another file of that
            ;; name gets a name of its own.
            (dnd-handle-multiple-urls (selected-window) (list url) 'private)
            (should (= 1 (length harness-compose-attachments)))
            (dnd-handle-multiple-urls (selected-window) (list (harness-test-http-url server "/again/cat.png")) 'private)
            (harness-test-wait #'harness-ui-compose-test--settled 10 "the second download")
            (should (equal (expand-file-name "downloads/cat-1.png" harness-state-directory)
                           (plist-get (cadr harness-compose-attachments) :path)))
            (should (equal "cat-1.png" (plist-get (cadr harness-compose-attachments) :name))))
        (delete-process server)))))

(ert-deftest harness-ui-compose-dropped-link-to-a-page-goes-in-as-text ()
  (skip-unless (executable-find "curl"))
  (harness-ui-compose-test-with
    (let* ((server (harness-test-http-serve
                    '(("/article" 200 (("Content-Type" . "text/html; charset=utf-8")) "<html>an article</html>"))))
           (url (harness-test-http-url server "/article")))
      (unwind-protect
          (progn
            (goto-char harness-compose-end)
            (insert "see")
            (let ((messages (harness-ui-compose-test-messages
                              (dnd-handle-multiple-urls (selected-window) (list url) 'private)
                              (harness-test-wait #'harness-ui-compose-test--settled 10 "the page"))))
              (should (cl-some (lambda (m) (string-match-p "is a web page" m)) messages)))
            (should-not harness-compose-attachments)
            (should (equal (concat "see " url) (harness-compose-text)))
            (should-not (directory-files (expand-file-name "downloads/" harness-state-directory) nil "\\`[^.]")))
        (delete-process server)))))

(ert-deftest harness-ui-compose-failed-download-says-why ()
  (skip-unless (executable-find "curl"))
  (harness-ui-compose-test-with
    (let* ((server (harness-test-http-serve '()))
           (url (harness-test-http-url server "/gone.png")))
      (unwind-protect
          (let ((messages (harness-ui-compose-test-messages
                            (dnd-handle-multiple-urls (selected-window) (list url) 'private)
                            (harness-test-wait #'harness-ui-compose-test--settled 10 "the failure"))))
            (should-not harness-compose-attachments)
            (should (cl-some (lambda (m) (string-match-p "Could not download .*gone\\.png: the server answered HTTP 404" m))
                             messages))
            (should-not harness-compose--progress))
        (delete-process server)))))

(ert-deftest harness-ui-compose-download-stops-when-removed-cleared-or-killed ()
  (skip-unless (executable-find "curl"))
  (harness-ui-compose-test-with
    (let* ((server (harness-test-http-serve
                    `(("/slow.webm" 200 (("Content-Type" . "video/webm")) ,(make-string 40000 ?w) :chunks 40 :delay 0.2))))
           (url (harness-test-http-url server "/slow.webm"))
           (started (lambda ()
                      (harness-compose-download url)
                      (let ((dl (plist-get (harness-ui-compose-test--pending) :download)))
                        (harness-test-wait (lambda () (> (harness-http-download-received dl) 0)) 10 "the first bytes")
                        dl))))
      (unwind-protect
          (progn
            ;; ×
            (let ((dl (funcall started)))
              (harness-compose-cancel-download (plist-get (harness-ui-compose-test--pending) :id))
              (should-not harness-compose-attachments)
              (should (harness-download-cancelled dl))
              (should-not (file-exists-p (harness-download-file dl)))
              (harness-test-wait (lambda () (not (process-live-p (harness-download-process dl)))) 5 "curl gone"))
            ;; Clearing the box.
            (let ((dl (funcall started)))
              (harness-compose-clear)
              (should-not harness-compose-attachments)
              (should (harness-download-cancelled dl)))
            ;; Killing the buffer.
            (let ((dl (funcall started)))
              (kill-buffer (current-buffer))
              (should (harness-download-cancelled dl))
              (should-not (file-exists-p (harness-download-file dl)))))
        (delete-process server)))))

(ert-deftest harness-ui-compose-dropped-data-links-attach ()
  (harness-ui-compose-test-with
    (dnd-handle-multiple-urls (selected-window)
                              (list (concat "data:image/png;base64," (base64-encode-string harness-test-png t))
                                    "data:,hello%20world")
                              'private)
    (should (equal '("dropped.png" "dropped.txt") (mapcar (lambda (a) (plist-get a :name)) harness-compose-attachments)))
    (should (equal '("image/png" "text/plain") (mapcar (lambda (a) (plist-get a :mime)) harness-compose-attachments)))
    (should (equal harness-test-png (harness-ui-compose-test--bytes (plist-get (car harness-compose-attachments) :path))))
    (should (equal "hello world" (harness-ui-compose-test--bytes (plist-get (cadr harness-compose-attachments) :path))))))

(ert-deftest harness-ui-compose-drop-takes-the-image-the-browser-drags ()
  ;; A browser dragging an image inside a link drops the link; the image
  ;; is the only one in the drop's HTML, or Firefox's file promise.
  (harness-ui-compose-test-with
    (let ((offered nil))
      (cl-letf (((symbol-function 'harness-compose--drop-text) (lambda (type) (cdr (assoc type offered)))))
        (should (equal '("https://site.example/a/cat.jpg") (harness-compose--dropped-media "https://site.example/a/cat.jpg")))
        (should (equal '("https://site.example/page") (harness-compose--dropped-media "https://site.example/page")))
        (setq offered '(("text/html" . "<a href=\"https://site.example/page\"><img alt=\"a cat\" src=\"/img/cat.jpg?w=200&amp;h=100\"></a>")))
        (should (equal '("https://site.example/img/cat.jpg?w=200&h=100") (harness-compose--dropped-media "https://site.example/page")))
        ;; A link to an image file is taken as it is, the full-size one.
        (should (equal '("https://site.example/full.png") (harness-compose--dropped-media "https://site.example/full.png")))
        (setq offered '(("text/html" . "<img src='data:image/gif;base64,R0lGOD'>")))
        (should (equal '("data:image/gif;base64,R0lGOD") (harness-compose--dropped-media "https://site.example/page")))
        ;; Two images: the drop says nothing of which.
        (setq offered '(("text/html" . "<img src=\"/1.png\"><img src=\"/2.png\">")))
        (should (equal '("https://site.example/page") (harness-compose--dropped-media "https://site.example/page")))
        (setq offered '(("application/x-moz-file-promise-url" . "https://cdn.example/x/9f8e")
                        ("application/x-moz-file-promise-dest-filename" . "sunset.webp")
                        ("text/html" . "<img src=\"/other.png\">")))
        (should (equal '("https://cdn.example/x/9f8e" . "sunset.webp") (harness-compose--dropped-media "https://site.example/page")))))))

(ert-deftest harness-ui-compose-dropped-text-goes-in-the-box ()
  (harness-ui-compose-test-with
    (goto-char (point-min))
    (harness-compose--drop-utf8 (selected-window) 'copy (encode-coding-string "héllo" 'utf-8))
    (should (equal "héllo" (harness-compose-text)))
    ;; Dropped inside the box, it goes where it was dropped.
    (goto-char (+ harness-compose-start 1))
    (harness-compose--drop-utf16 (selected-window) 'copy (encode-coding-string "XY" (if (eq (byteorder) ?B) 'utf-16be 'utf-16le)))
    (should (equal "hXYéllo" (harness-compose-text)))
    (goto-char (point-min))
    (should (eq 'copy (harness-compose--drop-plain (selected-window) 'copy "a\r\nb")))
    (should (equal "hXYélloa\nb" (harness-compose-text)))))

(ert-deftest harness-ui-compose-drop-handlers-stay-in-the-buffer ()
  (harness-ui-compose-test-with
    (should (eq 'harness-compose-dnd-download (cdr (assoc "^\\(?:https?\\|ftps?\\)://" dnd-protocol-alist))))
    (should-not (rassq 'harness-compose-dnd-download (default-value 'dnd-protocol-alist)))
    (when (boundp 'x-dnd-types-alist)
      (should (eq 'harness-compose--drop-image (cdr (assoc "image/png" x-dnd-types-alist))))
      (should (eq 'harness-compose--drop-utf8 (cdr (assoc "UTF8_STRING" x-dnd-types-alist))))
      (should-not (assoc "image/png" (default-value 'x-dnd-types-alist)))
      ;; Links first, then images, then text.
      (let ((known x-dnd-known-types))
        (should (< (cl-position "text/uri-list" known :test #'equal) (cl-position "image/png" known :test #'equal)))
        (should (< (cl-position "image/png" known :test #'equal) (cl-position "UTF8_STRING" known :test #'equal))))
      (should-not (member "image/png" (default-value 'x-dnd-known-types)))
      (should (eq 'harness-compose--drop-direct-save x-dnd-direct-save-function))
      ;; An image dropped as data is saved and attached.
      (cl-letf (((symbol-function 'x-dnd-current-type) (lambda (_w) "image/png")))
        (harness-compose--drop-image (selected-window) 'copy harness-test-png))
      (should (equal "image/png" (plist-get (car harness-compose-attachments) :mime)))
      (should (equal harness-test-png (harness-ui-compose-test--bytes (plist-get (car harness-compose-attachments) :path))))
      ;; X direct save: the file goes among the downloads, then attaches.
      (let ((path (harness-compose--drop-direct-save t "../a picture.png")))
        (should (equal (expand-file-name "downloads/_a picture.png" harness-state-directory) path))
        (with-temp-file path (insert "x"))
        (harness-compose--drop-direct-save nil path)
        (should (equal path (plist-get (cadr harness-compose-attachments) :path)))))))

(ert-deftest harness-ui-compose-dropped-link-with-junk-still-downloads ()
  ;; A drop can carry a BOM, a newline, a tab or a NUL around the link
  ;; (the class of \"URL rejected: No host present\": curl reads what the
  ;; message does not show).  The box scrubs it, so the file arrives all
  ;; the same and the attachment keeps the clean address.
  (skip-unless (executable-find "curl"))
  (harness-ui-compose-test-with
    (let* ((server (harness-test-http-serve
                    `(("/junk.png" 200 (("Content-Type" . "image/png")) ,harness-test-png))))
           (url (harness-test-http-url server "/junk.png")))
      (unwind-protect
          (progn
            (harness-compose-download (concat "\ufeff\t" url "\r\n\0") "junk.png")
            (should (harness-ui-compose-test--pending))
            (harness-test-wait #'harness-ui-compose-test--settled 10 "the download")
            (let ((att (car harness-compose-attachments)))
              (should (equal url (plist-get att :url)))
              (should (equal "image/png" (plist-get att :mime)))
              (should (equal harness-test-png (harness-ui-compose-test--bytes (plist-get att :path))))))
        (delete-process server)))))

(ert-deftest harness-ui-compose-link-with-no-host-is-refused-clearly ()
  ;; No curl error for a link the box cannot fetch: it says so itself,
  ;; with the link shown as it is, escapes and all.
  (harness-ui-compose-test-with
    (let ((message (error-message-string
                    (should-error (harness-compose-download "https://") :type 'user-error))))
      (should (string-match-p "not a link I can fetch" message))
      (should (string-match-p "\"https://\"" message)))
    (should-not harness-compose-attachments)
    (should-not (harness-ui-compose-test--pending))))

;;;; Chips

(ert-deftest harness-ui-compose-chips-show-thumbnails ()
  (harness-ui-compose-test-with
    (let* ((clip (harness-media-ring-save harness-test-png "image/png"))
           (notes (expand-file-name "notes.txt" dir))
           (video (expand-file-name "clip.mp4" dir))
           (callback nil)
           (thumb (expand-file-name "thumb.png" dir)))
      (with-temp-file notes (insert "notes"))
      (with-temp-file video (insert "not a video"))
      (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t))
                ((symbol-function 'harness-ui-media-video-thumbnail)
                 (lambda (_path &optional cb) (if (file-exists-p thumb) thumb (setq callback cb) nil))))
        (let ((image-chip (harness-compose--chip clip))
              (notes-chip (harness-compose--chip (harness-compose--file-attachment notes))))
          ;; An image shows itself, scaled to the thumbnail height.
          (should (eq 'image (car-safe (get-text-property 0 'display image-chip))))
          (should (equal (plist-get clip :path) (plist-get (cdr (get-text-property 0 'display image-chip)) :file)))
          (should (plist-get (cdr (get-text-property 0 'display image-chip)) :max-height))
          ;; A capture goes by its name, a project file by its path in the project.
          (should (string-match-p (regexp-quote (plist-get clip :name)) image-chip))
          (should-not (string-match-p "clips/" image-chip))
          (should-not (get-text-property 0 'display notes-chip))
          (should (string-prefix-p "notes.txt (" notes-chip)))
        ;; A video shows its thumbnail once the media module made it.
        (let ((att (harness-compose--file-attachment video)))
          (should (equal "video/mp4" (plist-get att :mime)))
          (harness-compose--attach att)
          (harness-compose-redraw)
          (should-not (get-text-property 0 'display (harness-compose--chip att)))
          (should (functionp callback))
          (copy-file (plist-get clip :path) thumb)
          (let ((draws harness-ui-compose-test--draws))
            (funcall callback)
            (should (> harness-ui-compose-test--draws draws)))
          (should (equal thumb (plist-get (cdr (get-text-property 0 'display (harness-compose--chip att))) :file))))
        ;; No thumbnails asked for, or none possible.
        (let ((harness-compose-thumbnail-lines 0))
          (should-not (get-text-property 0 'display (harness-compose--chip clip))))
        ;; A narrow chip keeps a third of its room for the thumbnail at most.
        (should (<= (plist-get (cdr (get-text-property 0 'display (harness-compose--chip clip 6))) :max-width) 2)))
      (should-not (get-text-property 0 'display (harness-compose--chip clip))))))

;;;; Laying the attachments out

(defconst harness-ui-compose-test--deep
  "src/components/a-long-directory-name/another-directory/the-file.tsx"
  "A file deep in the project: its path fits 80 columns, not 40.")

(defun harness-ui-compose-test--shown (start end)
  "Return the text from START to END as it shows.
An overlay's display string, a download's progress, stands in for the
text under it."
  (let ((parts nil) (pos start))
    (while (< pos end)
      (let* ((ov (cl-find-if (lambda (o) (overlay-get o 'display)) (overlays-at pos)))
             (next (min end (if ov (overlay-end ov) (next-overlay-change pos)))))
        (push (if ov (overlay-get ov 'display) (buffer-substring-no-properties pos next)) parts)
        (setq pos next)))
    (substring-no-properties (apply #'concat (nreverse parts)))))

(defun harness-ui-compose-test--attachment-lines (window)
  "Return the attachment lines of the test host as (TEXT COLUMNS INDENT).
TEXT is a line as it shows, COLUMNS how wide it is in WINDOW and
INDENT how far in WINDOW its chip starts."
  (save-excursion
    (goto-char (point-min))
    (forward-line 1)
    (let ((inhibit-field-text-motion t)   ; The box's prompt is a field.
          (end (save-excursion (goto-char harness-compose-start) (pos-bol)))
          (lines nil))
      (while (< (point) end)
        (let ((chip (cl-loop for pos from (point) below (line-end-position)
                             when (or (get-text-property pos 'button)
                                      (get-text-property pos 'harness-compose-pending))
                             return pos)))
          (push (list (harness-ui-compose-test--shown (point) (line-end-position))
                      (car (window-text-pixel-size window (point) (line-end-position)))
                      (car (window-text-pixel-size window (point) chip)))
                lines))
        (forward-line 1))
      (nreverse lines))))

(defun harness-ui-compose-test--attach-all-kinds (dir)
  "Attach one of each kind and return the path of the file deep in DIR.
That file, a short one, an image and a page pasted and a download under
way.  `harness-state-directory' must be outside DIR, the project, so
that the files go by their paths in it."
  (let ((deep (expand-file-name harness-ui-compose-test--deep dir))
        (notes (expand-file-name "notes.txt" dir)))
    (make-directory (file-name-directory deep) t)
    (with-temp-file deep (insert "deep"))
    (with-temp-file notes (insert "notes"))
    (harness-compose--attach (harness-compose--file-attachment deep))
    (harness-compose--attach (harness-compose--file-attachment notes))
    (harness-compose--attach (harness-media-ring-save harness-test-png "image/png"))
    (harness-compose--attach (harness-media-ring-save "<p>pasted</p>" "text/html"))
    ;; A download that never ends: no curl behind it.
    (setq harness-compose-attachments
          (append harness-compose-attachments
                  (list (list :pending t :id "dl" :name "a-download-1.2.3.tar.gz"
                              :url "https://example.com/releases/a-download-1.2.3.tar.gz"))))
    (harness-compose-redraw)
    deep))

(ert-deftest harness-ui-compose-attachments-go-one-a-line ()
  "Every attachment has a line of its own, fitted to the window.
Files, captures and downloads alike: the names line up under the
paperclip's, a name too long is shortened in the middle, keeping its
start and its file's name, and a wide window shows every name whole."
  (harness-ui-compose-test-with
    (let* ((harness-state-directory (file-name-as-directory (expand-file-name "state" dir)))
           (window (selected-window))
           (side (split-window window 40 'right))
           (deep (harness-ui-compose-test--attach-all-kinds dir))
           (names (mapcar #'harness-compose--chip-name harness-compose-attachments)))
      (should (equal harness-ui-compose-test--deep (car names)))
      ;; Shown in the narrow window alone.
      (set-window-buffer side (current-buffer))
      (set-window-buffer window (get-buffer-create "*scratch*"))
      (harness-compose-redraw)
      (let ((lines (harness-ui-compose-test--attachment-lines side)))
        (should (= 5 (length lines)))
        (pcase-dolist (`(,text ,columns ,indent) lines)
          (should (= 1 (cl-count ?× text)))
          (should (< columns (window-body-width side)))
          (should (= indent (nth 2 (car lines)))))
        ;; The paperclip leads the first line.
        (should (string-match-p (regexp-quote (harness-ui-icon 'harness-icon-attach)) (car (car lines))))
        ;; The deep file keeps where it starts and what it is called.
        (should (string-match-p "src/comp.*…/the-file\\.tsx (4 B) ×\\'" (car (nth 0 lines))))
        (should (string-match-p "notes\\.txt (5 B) ×\\'" (car (nth 1 lines))))
        (should (string-match-p "a-dow.*…" (car (nth 4 lines))))
        (should (string-match-p "connecting" (car (nth 4 lines)))))
      ;; The tooltips tell the whole path and the whole link.
      (save-excursion
        (goto-char (point-min))
        (search-forward "src/comp")
        (should (string-match-p (regexp-quote (abbreviate-file-name deep)) (get-text-property (point) 'help-echo)))
        (should-not (string-match-p "\n" (get-text-property (point) 'help-echo))))
      (should (string-match-p "https://example\\.com/releases/a-download-1\\.2\\.3\\.tar\\.gz\\'"
                              (overlay-get (cdr (assoc "dl" harness-compose--progress)) 'help-echo)))
      ;; In the wide window, every name is whole.
      (set-window-buffer window (current-buffer))
      (delete-window side)
      (harness-compose-redraw)
      (let ((lines (harness-ui-compose-test--attachment-lines window)))
        (should (= 5 (length lines)))
        (cl-loop for (text columns) in lines
                 for name in names
                 do (should (string-search name text))
                 (should-not (string-search "…" (string-replace "connecting…" "" text)))
                 (should (< columns (window-body-width window))))))))

(ert-deftest harness-ui-compose-attachments-fit-again-when-a-window-narrows ()
  "A window showing the box changing size has the host fit the lines again."
  (harness-ui-compose-test-with
    (should (memq #'harness-compose--on-resize window-size-change-functions))
    (let* ((harness-state-directory (file-name-as-directory (expand-file-name "state" dir)))
           (window (selected-window))
           (deep (harness-ui-compose-test--attach-all-kinds dir)))
      (should (string-search harness-ui-compose-test--deep (car (car (harness-ui-compose-test--attachment-lines window)))))
      (let ((draws harness-ui-compose-test--draws)
            (side (split-window window 40 'right)))
        (set-window-buffer side (current-buffer))
        ;; A batch Emacs never redisplays, which would run the hook.
        (harness-compose--on-resize side)
        (harness-test-wait (lambda () (> harness-ui-compose-test--draws draws)) 2 "the lines fitted again")
        ;; Both windows show them: they fit the narrower.
        (dolist (line (harness-ui-compose-test--attachment-lines side))
          (should (< (nth 1 line) (min (window-body-width side) (window-body-width window)))))
        (should-not (string-search harness-ui-compose-test--deep
                                   (car (car (harness-ui-compose-test--attachment-lines side)))))
        (should (string-search (file-name-nondirectory deep)
                               (car (car (harness-ui-compose-test--attachment-lines side)))))
        ;; Fitting them again for the same windows would change nothing:
        ;; the host is left alone.
        (setq draws harness-ui-compose-test--draws)
        (harness-compose--on-resize side)
        (sleep-for 0.4)
        (should (= draws harness-ui-compose-test--draws))))))

(ert-deftest harness-ui-compose-long-names-shorten-in-the-middle ()
  "A name too long keeps its start and its end, a path its file's name."
  (should (equal "notes.txt" (harness-compose--shorten "notes.txt" 9)))
  (should (equal "Screens…-11.png" (harness-compose--shorten "Screenshot from 2026-10-05 14-32-11.png" 15)))
  (should (equal "src/comp…/the-file.tsx" (harness-compose--shorten harness-ui-compose-test--deep 22)))
  ;; A file's name too long to keep whole: its path's start and its end.
  (let ((short (harness-compose--shorten "src/a-name-far-too-long-to-keep-whole.tsx" 20)))
    (should (= 20 (string-width short)))
    (should (string-prefix-p "src/a-na" short))
    (should (string-suffix-p "whole.tsx" short)))
  ;; Wide characters take two columns each.
  (let ((short (harness-compose--shorten "日本語のとても長いファイルの名前.txt" 15)))
    (should (<= (string-width short) 15))
    (should (string-prefix-p "日本語" short))
    (should (string-suffix-p "前.txt" short)))
  ;; Fitted to a width, as long as fits, and never shorter than the least.
  (let ((name "Screenshot from 2026-10-05 14-32-11 with a long name.png"))
    (should (equal name (harness-compose--fit name 80 #'identity)))
    (should (= 30 (string-width (harness-compose--fit name 30 #'identity))))
    (should (= 26 (string-width (harness-compose--fit name 30 (lambda (n) (concat n " ×  "))))))
    (should (= harness-compose--min-name (string-width (harness-compose--fit name 3 #'identity))))))

;;;; The media ring

(ert-deftest harness-ui-compose-media-ring-keeps-captures ()
  (harness-ui-compose-test-with
    (let* ((a (harness-media-ring-save harness-test-png "image/png"))
           (b (harness-media-ring-save (concat harness-test-png "b") "image/png"))
           (clips (expand-file-name "clips/" harness-state-directory)))
      (should (equal (list (plist-get b :path) (plist-get a :path))
                     (mapcar (lambda (e) (plist-get e :path)) (harness-media-ring-entries))))
      (should (string-match-p "\\`clip-[0-9]\\{8\\}-[0-9]\\{6\\}-[0-9a-f]\\{12\\}\\.png\\'" (file-name-nondirectory (plist-get a :path))))
      (should (string-match-p "\\`clip-[0-9]\\{8\\}-[0-9]\\{6\\}\\.png\\'" (plist-get a :name)))
      ;; The same bytes again: the same file, moved to the front.
      (set-file-times (plist-get a :path) (time-subtract nil 100))
      (set-file-times (plist-get b :path) (time-subtract nil 50))
      (should (equal (plist-get a :path) (plist-get (harness-media-ring-save harness-test-png "image/png") :path)))
      (should (= 2 (length (directory-files clips nil "\\`clip-"))))
      (should (equal (plist-get a :path) (plist-get (car (harness-media-ring-entries)) :path)))
      ;; Read back from the directory after a restart, newest first.
      (setq harness-media-ring nil harness-media-ring--loaded nil)
      (let ((entries (harness-media-ring-entries)))
        (should (equal (list (plist-get a :path) (plist-get b :path)) (mapcar (lambda (e) (plist-get e :path)) entries)))
        (should (equal (plist-get a :sha1) (plist-get (car entries) :sha1)))
        (should (equal "image/png" (plist-get (car entries) :mime))))
      ;; It keeps `harness-media-ring-max' entries; the files stay.
      (let ((harness-media-ring-max 2))
        (harness-media-ring-save "<p>hi</p>" "text/html")
        (should (= 2 (length (harness-media-ring-entries))))
        (should (equal "text/html" (plist-get (car (harness-media-ring-entries)) :mime)))
        (should (string-suffix-p ".html" (plist-get (car (harness-media-ring-entries)) :path))))
      (should (= 3 (length (directory-files clips nil "\\`clip-")))))))

(defmacro harness-ui-compose-test-clipboard (selection &rest body)
  "Run BODY on a graphical display whose clipboard holds SELECTION.
SELECTION is an alist of TYPE, a symbol, and its data; the clipboard's
TARGETS are those types.  `kill-ring' holds \"killed text\" and the
clipboard gives no text to the kill ring."
  (declare (indent 1))
  `(let ((selection ,selection)
         (kill-ring (list "killed text"))
         (kill-ring-yank-pointer nil)
         (interprogram-paste-function nil))
     (setq kill-ring-yank-pointer kill-ring)
     (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
               ((symbol-function 'gui-backend-selection-owner-p) (lambda (&rest _) nil))
               ((symbol-function 'gui-get-selection)
                (lambda (_which type)
                  (if (eq type 'TARGETS)
                      (vconcat (cons 'TARGETS (mapcar #'car selection)))
                    (cdr (assq type selection))))))
       ,@body)))

(defun harness-ui-compose-test--command (command &optional arg)
  "Run COMMAND with ARG as the command loop would, after `last-command'.
Point starts after the box, where a command loop's hooks move it from."
  (goto-char (point-max))
  (let ((this-command command)
        (current-prefix-arg arg))
    (call-interactively command)
    (setq last-command this-command)))

(ert-deftest harness-ui-compose-yank-attaches-the-clipboard-image ()
  (harness-ui-compose-test-with
    (let ((last-command nil)
          (older (harness-media-ring-save (concat harness-test-png "older") "image/png")))
      (harness-ui-compose-test-clipboard `((image/png . ,harness-test-png) (text/html . "<img src=x>"))
        (should (eq 'harness-compose-yank (key-binding (kbd "C-y"))))
        (harness-ui-compose-test--command 'harness-compose-yank)
        (should (eq 'harness-compose-yank last-command))
        (let ((att (car harness-compose-attachments)))
          (should (= 1 (length harness-compose-attachments)))
          (should (equal "image/png" (plist-get att :mime)))
          (should (equal harness-test-png (harness-ui-compose-test--bytes (plist-get att :path))))
          (should (equal (plist-get att :path) (plist-get (car (harness-media-ring-entries)) :path))))
        (should (equal "" (harness-compose-text)))
        ;; M-y right after goes back through the ring, and around.
        (harness-ui-compose-test--command 'harness-compose-yank-pop)
        (should (equal (list (plist-get older :path)) (mapcar (lambda (a) (plist-get a :path)) harness-compose-attachments)))
        (harness-ui-compose-test--command 'harness-compose-yank-pop)
        (should (equal "image/png" (plist-get (car harness-compose-attachments) :mime)))
        (should (equal harness-test-png (harness-ui-compose-test--bytes (plist-get (car harness-compose-attachments) :path))))
        (should (= 1 (length harness-compose-attachments)))
        ;; Yanking again, the image attached already, yanks text.
        (harness-ui-compose-test--command 'harness-compose-yank)
        (should (equal "killed text" (harness-compose-text)))
        (should (eq 'yank last-command))
        (should (= 1 (length harness-compose-attachments)))
        ;; `kill-ring' never saw the image.
        (should (equal '("killed text") kill-ring))
        ;; So does C-u C-y, whatever the clipboard holds.
        (harness-compose-set "")
        (setq harness-compose-attachments nil)
        (harness-ui-compose-test--command 'harness-compose-yank '(4))
        (should (equal "killed text" (harness-compose-text)))
        (should-not harness-compose-attachments)))))

(ert-deftest harness-ui-compose-yank-yanks-text-when-the-clipboard-is-text ()
  (harness-ui-compose-test-with
    (let ((last-command nil))
      ;; LibreOffice cells come with a picture of them: they are text.
      (harness-ui-compose-test-clipboard `((application/x-libreoffice-tsvc . "a\tb") (image/png . ,harness-test-png)
                                           (UTF8_STRING . "a\tb"))
        (harness-ui-compose-test--command 'harness-compose-yank)
        (should-not harness-compose-attachments)
        (should (equal "killed text" (harness-compose-text))))
      ;; What this Emacs put on the clipboard is the newest kill.
      (harness-compose-set "")
      (harness-ui-compose-test-clipboard `((image/png . ,harness-test-png))
        (cl-letf (((symbol-function 'gui-backend-selection-owner-p) (lambda (&rest _) t)))
          (harness-ui-compose-test--command 'harness-compose-yank))
        (should-not harness-compose-attachments)
        (should (equal "killed text" (harness-compose-text))))
      ;; Off, the box leaves C-y and M-y alone, remapping included.
      (let ((harness-compose-yank-media nil))
        (should (eq 'yank (key-binding (kbd "C-y"))))
        (should (eq 'yank-pop (key-binding (kbd "M-y")))))
      ;; M-y after a yank of text runs what M-y runs elsewhere, a remap
      ;; (`consult-yank-pop' in Doom, say) included.
      (let ((ran nil))
        (defalias 'harness-ui-compose-test--other-yank-pop (lambda () (interactive) (setq ran t)))
        (unwind-protect
            (progn
              (define-key global-map [remap yank-pop] #'harness-ui-compose-test--other-yank-pop)
              (should (eq 'harness-compose-yank-pop (key-binding (kbd "M-y"))))
              (harness-ui-compose-test--command 'harness-compose-yank-pop)
              (should ran))
          (define-key global-map [remap yank-pop] nil))))))

(ert-deftest harness-ui-compose-yank-attaches-copied-files ()
  (harness-ui-compose-test-with
    (let ((last-command nil)
          (one (expand-file-name "one pic.png" dir))
          (two (expand-file-name "two.txt" dir)))
      (with-temp-file one (insert "1"))
      (with-temp-file two (insert "2"))
      (harness-ui-compose-test-clipboard `((text/uri-list . ,(concat "file://" (string-replace " " "%20" one) "\r\nfile://" two "\r\n"))
                                           (UTF8_STRING . ,(concat one "\n" two)))
        (harness-ui-compose-test--command 'harness-compose-yank)
        (should (equal (list one two) (mapcar (lambda (a) (plist-get a :path)) harness-compose-attachments)))
        (should (equal '("image/png" "text/plain") (mapcar (lambda (a) (plist-get a :mime)) harness-compose-attachments)))
        ;; Files copied are no captures: the ring stays empty.
        (should-not (harness-media-ring-entries))
        (harness-ui-compose-test--command 'harness-compose-yank)
        (should (equal "killed text" (harness-compose-text))))
      ;; A copied web link is text.
      (harness-compose-set "")
      (setq harness-compose-attachments nil)
      (harness-ui-compose-test-clipboard '((text/uri-list . "https://example.com/a.png\r\n"))
        (harness-ui-compose-test--command 'harness-compose-yank)
        (should-not harness-compose-attachments)
        (should (equal "killed text" (harness-compose-text)))))))

(ert-deftest harness-ui-compose-attach-clipboard-and-the-ring ()
  (harness-ui-compose-test-with
    (harness-ui-compose-test-clipboard `((image/png . ,harness-test-png))
      (harness-ui-compose-test--command 'harness-compose-attach-clipboard)
      (should (equal "image/png" (plist-get (car harness-compose-attachments) :mime)))
      (should (= 1 (length (harness-media-ring-entries)))))
    ;; Other types are chosen from, then captured.
    (setq harness-compose-attachments nil)
    (harness-ui-compose-test-clipboard '((text/html . "<b>bold</b>") (UTF8_STRING . "bold"))
      (cl-letf (((symbol-function 'completing-read) (lambda (_prompt choices &rest _) (car (all-completions "" choices)))))
        (harness-ui-compose-test--command 'harness-compose-attach-clipboard)))
    (let ((att (car harness-compose-attachments)))
      (should (equal "text/html" (plist-get att :mime)))
      (should (string-suffix-p ".html" (plist-get att :path)))
      (should (equal "<b>bold</b>" (harness-ui-compose-test--bytes (plist-get att :path)))))
    (should (= 2 (length (harness-media-ring-entries))))
    ;; C-u M-x harness-compose-attach-clipboard attaches an earlier capture.
    (setq harness-compose-attachments nil)
    (let ((png (cl-find "image/png" (harness-media-ring-entries) :key (lambda (e) (plist-get e :mime)) :test #'equal)))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt table &rest _)
                   (cl-find-if (lambda (c) (string-prefix-p (plist-get png :name) c)) (all-completions "" table)))))
        (harness-ui-compose-test--command 'harness-compose-attach-clipboard '(4)))
      (should (equal (list (plist-get png :path)) (mapcar (lambda (a) (plist-get a :path)) harness-compose-attachments))))
    ;; `yank-media' finds the box's handler.
    (setq harness-compose-attachments nil)
    (harness-compose--yank-media-image 'image/png harness-test-png)
    (should (equal "image/png" (plist-get (car harness-compose-attachments) :mime)))))

(ert-deftest harness-ui-compose-c-c-c-v-is-not-the-boxes ()
  "C-c C-v is not the box's key: pasting is C-y, and Verify keeps C-c C-v.
The box leaves C-c C-v unbound, so in a chat the review banner's
[Verify] owns it and nothing shadows it."
  (harness-ui-compose-test-with
    (should-not (lookup-key harness-compose-map (kbd "C-c C-v")))
    (should-not (key-binding (kbd "C-c C-v")))
    ;; Every key that yanks pastes into the box.
    (should (eq 'harness-compose-yank (key-binding (kbd "C-y"))))
    (should (eq 'harness-compose-yank-pop (key-binding (kbd "M-y"))))))

;;;; Finding files

(defmacro harness-ui-compose-test--files (&rest body)
  "Run BODY in a project with files, a directory next to it and a home.
`proj' is the box's project, listing notes.txt and lisp/notes-util.el;
`other' is the directory next to it, with notes.md and deep/x.txt;
`home' is $HOME, with doc.txt.  All three are directory names."
  (declare (indent 0))
  `(let* ((proj (file-name-as-directory (expand-file-name "proj" dir)))
          (other (file-name-as-directory (expand-file-name "other" dir)))
          (home (file-name-as-directory (expand-file-name "home" dir)))
          (process-environment (cons (concat "HOME=" (directory-file-name home)) process-environment)))
     (dolist (file (list (expand-file-name "notes.txt" proj) (expand-file-name "lisp/notes-util.el" proj)
                         (expand-file-name "notes.md" other) (expand-file-name "deep/x.txt" other)
                         (expand-file-name "doc.txt" home)))
       (make-directory (file-name-directory file) t)
       (with-temp-file file (insert "x")))
     (setq harness-compose-project-function (lambda () proj)
           harness-compose--files '("notes.txt" "lisp/notes-util.el"))
     (cl-letf (((symbol-function 'harness-files-list-limited)
                (lambda (&rest _) (harness-resolved '("notes.txt" "lisp/notes-util.el")))))
       ,@body)))

(defmacro harness-ui-compose-test--never-remote (&rest body)
  "Run BODY, failing if it hands a remote file name to a file name handler.
A handler for /ssh: names records each operation; BODY's value is
returned once none was."
  (declare (indent 0))
  `(let* ((asked nil)
          (file-name-handler-alist
           (cons (cons "\\`/ssh:" (lambda (operation &rest _) (push operation asked) (error "Remote file reached")))
                 file-name-handler-alist)))
     (prog1 (progn ,@body)
       (should-not asked))))

(defun harness-ui-compose-test--matches (input table)
  "Return the candidates of TABLE that INPUT completes to, sorted, without properties."
  (let ((all (completion-all-completions input table nil (length input))))
    (when (consp all) (setcdr (last all) nil))
    (sort (mapcar #'substring-no-properties all) #'string<)))

(defun harness-ui-compose-test--category (input table)
  "Return the completion category TABLE gives INPUT."
  (completion-metadata-get (completion-metadata input table nil) 'category))

(defun harness-ui-compose-test--paths ()
  "Return the paths of the box's attachments."
  (mapcar (lambda (a) (plist-get a :path)) harness-compose-attachments))

(defun harness-ui-compose-test--complete (capf string status)
  "Complete the token of CAPF to STRING, as a completion UI does, and exit with STATUS."
  (delete-region (nth 0 capf) (nth 1 capf))
  (goto-char (nth 0 capf))
  (insert string)
  (funcall (plist-get (nthcdr 3 capf) :exit-function) string status))

(ert-deftest harness-ui-compose-finds-files-by-name-or-by-path ()
  ;; Part of a name finds a project file; a path finds any file:
  ;; absolute, under ~, or relative to the project with ./ or ../,
  ;; reaching out of it.  Paths complete a directory at a time, in the
  ;; file category.  A remote name completes to nothing, without its
  ;; handler (TRAMP's) ever being asked.
  (harness-ui-compose-test-with
    (harness-ui-compose-test--files
      (dolist (name '("notes" ".gitignore" "lisp/notes-util.el" "skill:review" ".x"))
        (should-not (harness-compose--path-p name)))
      (dolist (path '("/etc/hosts" "~" "~/doc.txt" "./notes.txt" "../other/" ".."))
        (should (harness-compose--path-p path)))
      (let ((table (harness-compose--file-table)))
        (should (eq 'harness-compose-file (harness-ui-compose-test--category "" table)))
        (should (equal '("lisp/notes-util.el" "notes.txt") (harness-ui-compose-test--matches "nots" table)))
        (dolist (path '("../" "~/" "/" "./"))
          (should (eq 'file (harness-ui-compose-test--category path table))))
        (should (equal '("other/") (harness-ui-compose-test--matches "../oth" table)))
        (should (equal '("deep/" "notes.md") (harness-ui-compose-test--matches "../other/" table)))
        (should (equal '(9 . 0) (completion-boundaries "../other/n" table nil "")))
        (should (equal '("doc.txt") (harness-ui-compose-test--matches "~/do" table)))
        (should (equal '("notes.md") (harness-ui-compose-test--matches (concat other "no") table)))
        (should (equal '("notes.txt") (harness-ui-compose-test--matches "./notes" table)))
        (should (member "../" (all-completions ".." table)))
        (should (test-completion "../other/notes.md" table))
        (should-not (test-completion "../other/nope.md" table))
        (harness-ui-compose-test--never-remote
          (should-not (all-completions "/ssh:nohost:/" table))
          (should-not (try-completion "/ssh:nohost:/et" table))
          (should-not (test-completion "/ssh:nohost:/etc/hosts" table)))))))

(ert-deftest harness-ui-compose-at-completes-paths-out-of-the-project ()
  ;; @ completes a path as well as part of a project file's name, and
  ;; the file chosen becomes an attachment as a project file does.  A
  ;; directory stays in the box, for its files to complete next, and so
  ;; does a completion that may go on.
  (harness-ui-compose-test-with
    (harness-ui-compose-test--files
      (goto-char harness-compose-end)
      (insert "compare @../other/")
      (let ((capf (harness-compose-completion-at-point)))
        (should (equal "../other/" (buffer-substring (nth 0 capf) (nth 1 capf))))
        (should (equal '("deep/" "notes.md") (harness-ui-compose-test--matches "../other/" (nth 2 capf))))
        (should (eq 'folder (funcall (plist-get (nthcdr 3 capf) :company-kind) "deep/")))
        (should (eq 'file (funcall (plist-get (nthcdr 3 capf) :company-kind) "notes.md")))
        (harness-ui-compose-test--complete capf "../other/deep/" 'finished))
      (should (equal "compare @../other/deep/" (harness-compose-text)))
      (should-not harness-compose-attachments)
      (let ((capf (harness-compose-completion-at-point)))
        (should (equal '("x.txt") (harness-ui-compose-test--matches "../other/deep/" (nth 2 capf))))
        (harness-ui-compose-test--complete capf "../other/deep/x.txt" 'finished))
      (should (equal "compare " (harness-compose-text)))
      (should (equal (list (expand-file-name "deep/x.txt" other)) (harness-ui-compose-test--paths)))
      ;; Under ~: exact, it could go on, so it waits; sole, it attaches.
      (insert "with @~/do")
      (let ((capf (harness-compose-completion-at-point)))
        (should (equal '("doc.txt") (harness-ui-compose-test--matches "~/do" (nth 2 capf))))
        (harness-ui-compose-test--complete capf "~/doc.txt" 'exact))
      (should (equal "compare with @~/doc.txt" (harness-compose-text)))
      (funcall (plist-get (nthcdr 3 (harness-compose-completion-at-point)) :exit-function) "~/doc.txt" 'sole)
      (should (equal "compare with " (harness-compose-text)))
      ;; Absolute, and a project file as before.
      (insert (concat "@" other "no"))
      (harness-ui-compose-test--complete (harness-compose-completion-at-point) (concat other "notes.md") 'finished)
      (insert "@nots")
      (let ((capf (harness-compose-completion-at-point)))
        (should (equal '("lisp/notes-util.el" "notes.txt") (harness-ui-compose-test--matches "nots" (nth 2 capf))))
        (harness-ui-compose-test--complete capf "notes.txt" 'finished))
      (should (equal "compare with " (harness-compose-text)))
      (should (equal (list (expand-file-name "deep/x.txt" other) (expand-file-name "doc.txt" home)
                           (expand-file-name "notes.md" other) (expand-file-name "notes.txt" proj))
                     (harness-ui-compose-test--paths))))))

(ert-deftest harness-ui-compose-attach-command-takes-paths ()
  ;; C-c C-a reads a path as well as part of a project file's name,
  ;; with no C-u: out of the project, under ~ or absolute.  A leading @,
  ;; typed out of the box's habit, is ignored.
  (harness-ui-compose-test-with
    (harness-ui-compose-test--files
      (let ((table nil) (answer nil))
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_prompt collection &rest _) (setq table collection) answer))
                  ((symbol-function 'read-file-name) (lambda (&rest _) (error "Browsed"))))
          (pcase-dolist (`(,typed . ,file)
                         `(("../other/notes.md" . ,(expand-file-name "notes.md" other))
                           ("~/doc.txt" . ,(expand-file-name "doc.txt" home))
                           (,(expand-file-name "deep/x.txt" other) . ,(expand-file-name "deep/x.txt" other))
                           ("lisp/notes-util.el" . ,(expand-file-name "lisp/notes-util.el" proj))
                           ("@notes.txt" . ,(expand-file-name "notes.txt" proj))
                           ("@../other/notes.md" . ,(expand-file-name "notes.md" other))))
            (setq harness-compose-attachments nil answer typed)
            (harness-ui-compose-test--command 'harness-compose-add-attachment)
            (should (equal (list file) (harness-ui-compose-test--paths)))))
        ;; The prompt's table: past a leading @, names and paths complete as in the box.
        (should (eq 'harness-compose-file (harness-ui-compose-test--category "@" table)))
        (should (eq 'file (harness-ui-compose-test--category "@../" table)))
        (should (equal '("lisp/notes-util.el" "notes.txt") (harness-ui-compose-test--matches "@nots" table)))
        (should (equal '("other/") (harness-ui-compose-test--matches "@../oth" table)))
        (should (equal '(4 . 0) (completion-boundaries "@../oth" table nil "")))
        (should (equal '(1 . 0) (completion-boundaries "@nots" table nil "")))
        (should (equal "@../other/notes.md" (try-completion "@../other/no" table)))
        (should (test-completion "@../other/notes.md" table))
        (should (test-completion "@notes.txt" table))
        (should-not (test-completion "@nope.txt" table))))))

(ert-deftest harness-ui-compose-attach-command-opens-directories ()
  ;; A directory is no file to attach, and neither is nothing: the
  ;; prompt comes back, from inside the directory chosen.
  (harness-ui-compose-test-with
    (harness-ui-compose-test--files
      (let ((answers '("" "@../other/" "../other/deep" "../other/deep/x.txt"))
            (initials nil))
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_prompt _collection _pred _require initial &rest _)
                     (push initial initials)
                     (pop answers))))
          (harness-ui-compose-test--command 'harness-compose-add-attachment))
        (should (equal '(nil nil "../other/" "../other/deep/") (nreverse initials)))
        (should (equal (list (expand-file-name "deep/x.txt" other)) (harness-ui-compose-test--paths)))))))

(ert-deftest harness-ui-compose-typed-references-attach-when-taken ()
  ;; An @ reference typed out in full, or pasted, attaches its file when
  ;; the message is taken, as one completed does, and stays in the text:
  ;; a project file, a path out of the project, under ~ or absolute.
  ;; Punctuation after it is no part of it.  @skill: references, a
  ;; missing file, a directory, an @ inside a word and a remote name
  ;; attach nothing, and a file is attached once.
  (harness-ui-compose-test-with
    (harness-ui-compose-test--files
      (harness-compose-add-attachment (expand-file-name "notes.txt" proj))
      (let ((text (format "compare @notes.txt with @../other/notes.md, @~/doc.txt and (see @%s).
@skill:review @missing.txt @../other/deep/ @/ssh:nohost:/etc/hosts mail@example.com
@lisp/notes-util.el @../other/notes.md"
                          (expand-file-name "deep/x.txt" other))))
        (harness-compose-set text)
        (pcase-let ((`(,sent . ,atts) (harness-ui-compose-test--never-remote (harness-compose-take))))
          (should (equal text sent))
          (should (equal (list (expand-file-name "notes.txt" proj) (expand-file-name "notes.md" other)
                               (expand-file-name "doc.txt" home) (expand-file-name "deep/x.txt" other)
                               (expand-file-name "lisp/notes-util.el" proj))
                         (mapcar (lambda (a) (plist-get a :path)) atts)))
          (should (equal '("notes.txt" "notes.md" "doc.txt" "x.txt" "notes-util.el")
                         (mapcar (lambda (a) (plist-get a :name)) atts)))
          (should (equal "text/plain" (plist-get (nth 2 atts) :mime))))
        ;; The box is left as it was: its host clears it once sent.
        (should (equal (list (expand-file-name "notes.txt" proj)) (harness-ui-compose-test--paths)))
        (should (equal text (harness-compose-text))))
      ;; References alone are a message.
      (harness-compose-clear)
      (harness-compose-set "@~/doc.txt")
      (should (equal (list "@~/doc.txt" (expand-file-name "doc.txt" home))
                     (pcase (harness-compose-take) (`(,sent ,att) (list sent (plist-get att :path)))))))))

(provide 'harness-ui-compose-test)
;;; harness-ui-compose-test.el ends here
