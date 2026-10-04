;;; harness-ui-media-ring.el --- An opt-in kill ring for clipboard media  -*- lexical-binding: t; -*-

;;; Commentary:

;; The kill ring holds text, and every mode yanks from it.  Images and
;; other media copied to the system clipboard go into a ring of their
;; own instead, the media ring, which only the buffers that opt in
;; read: the compose boxes of the harness (see
;; `harness-compose-yank-media').  Nothing here touches `kill-ring', so
;; no other mode ever yanks a picture as raw bytes.
;;
;; Each capture is saved under harness-state-directory/clips/, with the
;; start of the SHA-1 of its bytes in its name: the same image copied
;; twice is one entry, and the ring is read back from that directory
;; after a restart.  Entries are attachments, (:path :size :mime :name
;; :sha1), newest first.
;;
;; The clipboard is read with `gui-get-selection', as `yank' reads it:
;; its TARGETS first, which are small, and the data only when it holds
;; what the caller wants.  Files copied in a file manager are offered
;; as their paths (`harness-media-ring-clipboard-files').

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'mailcap)
(require 'dnd)
(require 'harness-core)
(require 'harness-util)

(defvar harness-state-directory)

(defgroup harness-media-ring nil
  "The media ring: images and other media copied to the clipboard."
  :group 'harness :prefix "harness-media-ring-")

(defcustom harness-media-ring-max 30
  "Most captures the media ring offers.  Older ones stay on disk."
  :type 'integer :group 'harness-media-ring)

(defcustom harness-media-ring-image-types '(image/png image/jpeg image/webp image/gif)
  "Image types taken from the clipboard, best first."
  :type '(repeat symbol) :group 'harness-media-ring)

(defcustom harness-media-ring-text-types '(application/x-libreoffice-tsvc)
  "Clipboard types that mean the clipboard holds text, images or not.
LibreOffice puts a picture of the copied cells beside their text, which
is what pasting them should give."
  :type '(repeat symbol) :group 'harness-media-ring)

(defvar harness-media-ring nil
  "The media ring: attachments captured from the clipboard, newest first.")

(defvar harness-media-ring--loaded nil
  "Non-nil once the ring was read from the clips directory.")

;;;; Storage

(defun harness-media-ring-directory ()
  "Return the directory clipboard captures are saved in, creating it."
  (harness-ensure-directory
   (expand-file-name "clips/" (if (boundp 'harness-state-directory) harness-state-directory
                                (locate-user-emacs-file "harness/")))))

(defun harness-media-ring-extension (mime)
  "Return the file extension, without a dot, for the MIME type MIME."
  (let ((mime (downcase (string-trim (car (split-string (or mime "") ";"))))))
    (or (cdr (assoc mime '(("image/jpeg" . "jpg") ("image/svg+xml" . "svg") ("text/plain" . "txt")
                           ("text/html" . "html") ("video/quicktime" . "mov") ("video/x-matroska" . "mkv")
                           ("audio/mpeg" . "mp3") ("audio/x-wav" . "wav") ("audio/wav" . "wav")
                           ("application/octet-stream" . "bin"))))
        (when-let* ((ext (car (rassoc mime mailcap-mime-extensions))))
          (string-remove-prefix "." ext))
        (let ((sub (cadr (split-string mime "/"))))
          (and sub (let ((clean (replace-regexp-in-string "[^a-z0-9]+" "" (car (split-string sub "+")))))
                     (and (not (string-empty-p clean)) (substring clean 0 (min 8 (length clean)))))))
        "bin")))

(defun harness-media-ring-mime (file)
  "Return the MIME type of FILE, from its extension."
  (or (mailcap-extension-to-mime (or (file-name-extension file t) "")) "application/octet-stream"))

(defun harness-media-ring--sha-of-name (file)
  "Return the start of the SHA-1 encoded in the name of capture FILE, or nil."
  (let ((name (file-name-nondirectory file)))
    (and (string-match "-\\([0-9a-f]\\{12\\}\\)\\.[^.]+\\'" name) (match-string 1 name))))

(defun harness-media-ring--entry (file &optional mime sha)
  "Return the ring entry, an attachment, for the capture FILE.
Its name leaves the SHA-1 out: clip-20261002-163000.png."
  (let ((sha (or sha (harness-media-ring--sha-of-name file)))
        (name (file-name-nondirectory file)))
    (list :path file :size (or (harness-file-size file) 0)
          :mime (or mime (harness-media-ring-mime file))
          :name (if sha (string-replace (concat "-" sha ".") "." name) name)
          :sha1 sha)))

(defun harness-media-ring--load ()
  "Read the ring from the clips directory, once.
Captures made before the ring was read stay in front."
  (unless harness-media-ring--loaded
    (setq harness-media-ring--loaded t)
    (let* ((files (directory-files (harness-media-ring-directory) t "\\`clip-" t))
           (dated (delq nil (mapcar (lambda (f)
                                     (when-let* ((time (ignore-errors
                                                         (file-attribute-modification-time (file-attributes f)))))
                                       (cons f time)))
                                   files)))
           (newest (seq-take (mapcar #'car (sort dated (lambda (a b) (time-less-p (cdr b) (cdr a)))))
                             harness-media-ring-max)))
      (setq harness-media-ring
            (seq-take (cl-remove-duplicates
                       (append harness-media-ring (mapcar #'harness-media-ring--entry newest))
                       :test (lambda (a b) (equal (plist-get a :path) (plist-get b :path)))
                       :from-end t)
                      harness-media-ring-max)))))

(defun harness-media-ring-entries ()
  "Return the media ring, newest first, without captures deleted since."
  (harness-media-ring--load)
  (setq harness-media-ring
        (cl-remove-if-not (lambda (e) (file-exists-p (plist-get e :path))) harness-media-ring)))

(defun harness-media-ring-push (attachment)
  "Put ATTACHMENT at the front of the media ring and return it.
An entry of the same bytes or the same file is moved there instead."
  (harness-media-ring--load)
  (let ((sha (plist-get attachment :sha1))
        (path (plist-get attachment :path)))
    (setq harness-media-ring
          (seq-take (cons attachment
                          (cl-remove-if (lambda (e) (or (equal (plist-get e :path) path)
                                                        (and sha (equal (plist-get e :sha1) sha))))
                                        harness-media-ring))
                    harness-media-ring-max)))
  attachment)

(defun harness-media-ring-save (data mime)
  "Save DATA, of the MIME type MIME, as a capture and push it on the ring.
DATA is a string of bytes; text is saved as UTF-8.  The same bytes
saved again reuse their file.  Return the attachment."
  (let* ((bytes (if (multibyte-string-p data) (encode-coding-string data 'utf-8 t) data))
         (sha (substring (secure-hash 'sha1 bytes) 0 12))
         (dir (harness-media-ring-directory))
         (known (or (plist-get (cl-find sha (harness-media-ring-entries)
                                        :key (lambda (e) (plist-get e :sha1)) :test #'equal)
                               :path)
                    (car (directory-files dir t (concat "\\`clip-.*-" sha "\\.") t)))))
    (if known
        (set-file-times known)
      (setq known (expand-file-name (format "clip-%s-%s.%s" (format-time-string "%Y%m%d-%H%M%S") sha
                                            (harness-media-ring-extension mime))
                                    dir))
      (let ((coding-system-for-write 'binary))
        (with-temp-file known (set-buffer-multibyte nil) (insert bytes))))
    (harness-media-ring-push (harness-media-ring--entry known mime sha))))

(defun harness-media-ring-describe (entry)
  "Return a line describing ring ENTRY: its name, size and age."
  (let ((time (file-attribute-modification-time (file-attributes (plist-get entry :path)))))
    (format "%s  %s  %s" (plist-get entry :name) (harness-format-bytes (plist-get entry :size))
            (if time (harness-relative-time (float-time time)) ""))))

;;;; The clipboard

(defun harness-media-ring-clipboard-targets ()
  "Return the types the clipboard offers, as symbols, or nil.
Nil too when this Emacs owns the clipboard: what it holds is then the
newest kill, text the kill ring has already."
  (when (display-graphic-p)
    (unless (ignore-errors (gui-backend-selection-owner-p 'CLIPBOARD))
      (let ((targets (ignore-errors (gui-get-selection 'CLIPBOARD 'TARGETS))))
        (and (vectorp targets)
             (cl-remove-if-not #'symbolp (append targets nil)))))))

(defun harness-media-ring-clipboard-image-type (targets)
  "Return the best image type among TARGETS, or nil.
Nil when TARGETS also hold one of `harness-media-ring-text-types'."
  (and (not (cl-intersection targets harness-media-ring-text-types))
       (cl-find-if (lambda (type) (memq type targets)) harness-media-ring-image-types)))

(defun harness-media-ring-selection-text (data)
  "Return the selection DATA as text, or nil when it is no string.
UTF-16, which Firefox gives some types in, is told by its byte order
mark or its NUL bytes; anything else is read as UTF-8."
  (cond ((not (stringp data)) nil)
        ((multibyte-string-p data) (substring-no-properties data))
        ((string-prefix-p "\377\376" data) (decode-coding-string (substring data 2) 'utf-16le))
        ((string-prefix-p "\376\377" data) (decode-coding-string (substring data 2) 'utf-16be))
        ((string-search "\0" (substring data 0 (min 64 (length data))))
         (decode-coding-string data (if (eq (byteorder) ?B) 'utf-16be 'utf-16le)))
        (t (decode-coding-string data 'utf-8))))

(defun harness-media-ring-clipboard-files (targets)
  "Return the files copied in a file manager, when TARGETS say so, or nil.
They come as file: URIs in text/uri-list (or GNOME's and KDE's lists of
copied files); only a list of existing local files counts, so a copied
web link stays text."
  (when-let* ((type (cl-find-if (lambda (type) (memq type targets))
                                '(text/uri-list x-special/gnome-copied-files x-special/KDE-copied-files)))
              (text (harness-media-ring-selection-text (ignore-errors (gui-get-selection 'CLIPBOARD type)))))
    (let ((uris (cl-remove-if (lambda (l) (or (string-prefix-p "#" l) (member l '("copy" "cut"))))
                              (split-string text "[\r\n\0]+" t "[ \t]+"))))
      (when uris
        (let ((files (mapcar (lambda (uri) (dnd-get-local-file-name uri t)) uris)))
          (and (not (memq nil files)) files))))))

(defun harness-media-ring-capture (type)
  "Save what the clipboard holds as TYPE, a MIME type symbol, as a capture.
Return the attachment, pushed on the ring, or nil when the clipboard
gives nothing of TYPE."
  (let ((data (ignore-errors (gui-get-selection 'CLIPBOARD type))))
    (when (and (stringp data) (> (length data) 0))
      (harness-media-ring-save data (symbol-name type)))))

(defun harness-media-ring-capture-image (&optional targets)
  "Save the image on the clipboard as a capture and return its attachment.
TARGETS are the clipboard's types, when already known.  Nil when the
clipboard holds no image."
  (when-let* ((type (harness-media-ring-clipboard-image-type
                     (or targets (harness-media-ring-clipboard-targets)))))
    (harness-media-ring-capture type)))

(provide 'harness-ui-media-ring)
;;; harness-ui-media-ring.el ends here
