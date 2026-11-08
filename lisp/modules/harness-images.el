;;; harness-images.el --- The pictures tools return, kept as they were  -*- lexical-binding: t; -*-

;;; Commentary:

;; A tool may hand the model a picture: read_file on an image returns
;; its file as the result's `:images'.  The transcript keeps those
;; paths, never the bytes, and a request reads the files when it makes
;; the result ready for its provider (harness-agent--prepare-result).
;;
;; But a file can change between the call that returned it and the
;; request that sends it -- a screenshot written over the same path
;; every time, a picture edited -- and then the request sends
;; something the tool never returned: the model sees a picture it was
;; not shown, and every token after that result in the provider's
;; prompt cache is paid for again, though the conversation itself did
;; not change.  A long task that takes screenshots as it works pays
;; that miss for every screenshot.
;;
;; So a picture a result hands the model is copied once, when the
;; result is recorded, to the session's own directory under the state
;; directory: sessions/ID.images/HASH.EXT, named by the digest of its
;; bytes, so that two results of the same picture share one copy.  The
;; node keeps the path the tool named, `:path' (the user's file, and
;; the UI's), and the copy, `:snapshot', which the request sends: it
;; holds the bytes the tool returned however the file changes later.
;; The transcript still holds paths only.
;;
;; A picture that cannot be copied -- its file gone, unreadable, or
;; larger than `harness-images-max-bytes' -- is left without a copy,
;; and the request reads its file as it always did.  The copies go with
;; the session (`session/deleted').  A fork copies the nodes that name
;; its parent's copies and reads them until the parent goes.

;;; Code:

(require 'cl-lib)
(require 'harness-core)
(require 'harness-util)

(defvar harness-state-directory)

(defcustom harness-images-max-bytes (* 16 1024 1024)
  "Largest picture, in bytes, whose bytes are kept with its result.
A larger picture is not copied: the requests that carry it read its
file, as they always did, and a file that changes under them costs the
prompt cache.  A provider takes no image nearly this large."
  :type 'integer :group 'harness)

(defconst harness-images--extensions
  '(("image/png" . "png") ("image/jpeg" . "jpg")
    ("image/gif" . "gif") ("image/webp" . "webp"))
  "The file name extension of each picture type a model can be sent.")

(defconst harness-images--name-regexp "\\`[a-f0-9]\\{40\\}\\.[a-z0-9]\\{1,5\\}\\'"
  "What the name of a kept copy is: a SHA-1 digest, a dot, an extension.")

(defun harness-images-directory (session-id)
  "Return the directory that keeps the pictures of session SESSION-ID."
  (expand-file-name (format "sessions/%s.images/" session-id) harness-state-directory))

(defun harness-images-copy-p (path)
  "Non-nil when PATH names a copy this module keeps.
Only a copy is one: a name of a digest and an extension in a
`.images' directory, never a file of the session's own."
  (and (stringp path)
       (string-match-p harness-images--name-regexp (file-name-nondirectory path))
       (string-match-p "/[^/]+\\.images/\\'" (file-name-directory path))))

(defun harness-images--extension (mime path)
  "Return the file name extension of a picture of MIME whose file is PATH."
  (or (cdr (assoc mime harness-images--extensions))
      (let ((extension (and (stringp path) (file-name-extension path))))
        (and extension (string-match-p "\\`[a-zA-Z0-9]\\{1,5\\}\\'" extension)
             (downcase extension)))
      "img"))

(defun harness-images--bytes (path)
  "Return the bytes of the picture at PATH as a unibyte string, or nil.
Nil when PATH is not a file there is to read, when it is empty, or when
it cannot be read."
  (when (and (stringp path) (file-regular-p path) (file-readable-p path))
    (let ((size (let ((attributes (file-attributes path)))
                  (and attributes (file-attribute-size attributes)))))
      (when (and (numberp size) (> size 0) (<= size harness-images-max-bytes))
        (condition-case nil
            (with-temp-buffer
              (set-buffer-multibyte nil)
              (insert-file-contents-literally path)
              (buffer-string))
          (error nil))))))

(defun harness-images--write (path bytes)
  "Write BYTES, a unibyte string, to PATH, atomically."
  (harness-ensure-directory (file-name-directory path))
  (let ((tmp (concat path ".tmp" (harness-short-id 4)))
        (coding-system-for-write 'binary))
    (with-temp-file tmp
      (set-buffer-multibyte nil)
      (insert bytes))
    (rename-file tmp path t)
    path))

(defun harness-images--keep (session-id path mime)
  "Return a copy of the picture at PATH, of type MIME, kept for SESSION-ID.
The copy is named by the digest of its bytes, so it is made once
however many results return the same picture, and it holds what the
file held when the result was recorded, whatever the file holds later.
Nil when PATH is not a readable picture of a type a model is sent, when
it is larger than `harness-images-max-bytes', or when the copy cannot
be written."
  (when-let* ((extension (and (assoc mime harness-images--extensions)
                              (harness-images--extension mime path)))
              (bytes (harness-images--bytes path)))
    (let* ((dir (harness-images-directory session-id))
           (copy (expand-file-name (format "%s.%s" (secure-hash 'sha1 bytes) extension)
                                   dir)))
      (cond ((file-regular-p copy) copy)
            ((condition-case err
                 (progn (harness-images--write copy bytes)
                        (harness-log 'debug "images: kept %d bytes of %s for %s as %s"
                                     (length bytes) path session-id copy)
                        t)
               (error
                (harness-log 'warn "images: cannot keep %s for %s: %s"
                             path session-id (harness-error-short-message err))
                nil))
             copy)))))

(defun harness-images-resolve (image)
  "Return the file of IMAGE, a tool result's image, that a request sends.
That is its kept copy, `:snapshot', when there is one that still
reads, else the file the tool named, `:path'."
  (let* ((snapshot (plist-get image :snapshot))
         (path (plist-get image :path)))
    (cond ((and (harness-images-copy-p snapshot) (file-readable-p snapshot)) snapshot)
          ((stringp path) path))))

(harness-defmethod images/file (image)
  "Return the file of IMAGE, a tool result's image, that a request reads.
The copy kept when the result was recorded (`images/keep'), which holds
the bytes the tool returned, else the file the tool named."
  (harness-images-resolve image))

(harness-defmethod images/keep (session-id path mime)
  "Keep a copy of the picture at PATH, of type MIME, for SESSION-ID, and return it.
The copy is made when the tool result that names the picture is
recorded, so that a request sends the bytes the tool returned however
the file changes later, and the provider's prompt cache is not broken
by a change of a file the conversation does not mention (see
harness-images.el).  Nil when there is nothing to copy: PATH is gone,
unreadable, empty, no type a model is sent, or larger than
`harness-images-max-bytes', or the copy cannot be written."
  (harness-images--keep session-id path mime))

(defun harness-images--on-deleted (session-id &rest _)
  "Take the pictures kept for SESSION-ID away.  On `session/deleted'."
  (ignore-errors
    (let ((dir (harness-images-directory session-id)))
      (when (file-directory-p dir)
        (delete-directory dir t)
        (harness-log 'debug "images: took %s away with its session" dir)))))

(defun harness-images--init ()
  "Take a deleted session's pictures with it."
  (harness-on 'session/deleted #'harness-images--on-deleted))

(harness-define-module 'images
  :doc "The pictures tools return: a copy of each kept with the result that returned it, so that a request sends what the tool saw however the file changes, and the prompt cache lasts."
  :requires '(session)
  :init #'harness-images--init)

(provide 'harness-images)
;;; harness-images.el ends here
