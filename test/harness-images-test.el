;;; harness-images-test.el --- The pictures tools return, kept as they were  -*- lexical-binding: t; -*-

;;; Commentary:

;; A result's picture is copied when the result is recorded, so that the
;; request that sends it holds the bytes the tool returned however the
;; file changes later, and the provider's prompt cache is not broken by
;; a change of a file the conversation does not mention.  These tests
;; follow the copy: made once for a picture, named by its bytes, kept
;; with its session, and preferred by the request over the file the tool
;; named.

;;; Code:

(require 'harness-test-helpers)

(defvar harness-images-max-bytes)
(declare-function harness-images-directory "harness-images" (session-id))
(declare-function harness-images-copy-p "harness-images" (path))
(declare-function harness-images-resolve "harness-images" (image))

(defvar harness-images-test--png
  (base64-decode-string
   "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEUlEQVR4nGP4z8DA8B+MgBgAHfAD/dPQfSYAAAAASUVORK5CYII=")
  "The bytes of a picture the tests keep.")

(defmacro harness-images-test-with (&rest body)
  "Run BODY with the store started on a fresh bus and a fresh state."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider session images))
       (harness-test-load-module m))
     (let ((default-directory dir))
       ,@body)))

(defun harness-images-test-file (dir name &optional bytes)
  "Write BYTES, the test picture by default, as NAME in DIR, and return its name."
  (let ((file (expand-file-name name dir))
        (coding-system-for-write 'binary))
    (write-region (or bytes harness-images-test--png) nil file nil 'silent)
    file))

(defun harness-images-test-bytes (path)
  "Return the bytes of the file PATH, as a unibyte string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally path)
    (buffer-string)))

(defun harness-images-test-files (session-id)
  "Return the names of the pictures kept for SESSION-ID."
  (let ((dir (harness-images-directory session-id)))
    (and (file-directory-p dir)
         (directory-files dir nil directory-files-no-dot-files-regexp))))

;;;; Keeping a picture

(ert-deftest harness-images-keep-keeps-one-copy-of-a-picture ()
  "The same picture returned twice is one copy, named by the digest of its bytes.
It sits in the session's own images directory, with the type's extension,
and holds what the file held when it was kept."
  (harness-images-test-with
    (let* ((session "s1")
           (file (harness-images-test-file dir "shot.png"))
           (copy1 (harness-call 'images/keep session file "image/png"))
           (copy2 (harness-call 'images/keep session file "image/png")))
      (should (stringp copy1))
      (should (equal copy1 copy2))
      (should (file-regular-p copy1))
      (should (equal (harness-images-directory session) (file-name-directory copy1)))
      (should (string-match-p "\\`[a-f0-9]\\{40\\}\\.png\\'"
                              (file-name-nondirectory copy1)))
      (should (equal harness-images-test--png (harness-images-test-bytes copy1)))
      (should (= 1 (length (harness-images-test-files session))))
      (should (harness-images-copy-p copy1))
      (should-not (harness-images-copy-p file)))))

(ert-deftest harness-images-keep-names-the-type-it-is-given ()
  "A copy takes its extension from the picture's type.
The same bytes kept as another type are another copy."
  (harness-images-test-with
    (let* ((session "s2")
           (file (harness-images-test-file dir "shot.png"))
           (png (harness-call 'images/keep session file "image/png"))
           (jpeg (harness-call 'images/keep session file "image/jpeg")))
      (should (string-suffix-p ".png" png))
      (should (string-suffix-p ".jpg" jpeg))
      (should-not (equal png jpeg))
      (should (equal (harness-images-test-bytes png) (harness-images-test-bytes jpeg)))
      (should (= 2 (length (harness-images-test-files session)))))))

(ert-deftest harness-images-keep-leaves-what-it-cannot-keep ()
  "Nothing is copied that cannot be: a file gone, empty, too large, or no image.
The result keeps no snapshot then, and the request reads the file as it
always did."
  (harness-images-test-with
    (let* ((session "s3")
           (file (harness-images-test-file dir "shot.png"))
           (empty (harness-images-test-file dir "empty.png" ""))
           (gone (expand-file-name "gone.png" dir)))
      (should-not (harness-call 'images/keep session gone "image/png"))
      (should-not (harness-call 'images/keep session empty "image/png"))
      (should-not (harness-call 'images/keep session dir "image/png"))
      (should-not (harness-call 'images/keep session file "text/plain"))
      (should-not (harness-call 'images/keep session file nil))
      (let ((harness-images-max-bytes 10))
        (should-not (harness-call 'images/keep session file "image/png")))
      (should-not (harness-images-test-files session)))))

;;;; Sending a picture

(ert-deftest harness-images-file-prefers-the-kept-copy ()
  "A result's picture is read from its copy; the file the tool named is the fallback.
A copy that is gone, or names something that is no copy of this store,
leaves the file to be read."
  (harness-images-test-with
    (let* ((file (harness-images-test-file dir "shot.png"))
           (copy (harness-call 'images/keep "s4" file "image/png"))
           (block (list :type "image" :mime "image/png" :path file :snapshot copy)))
      (should (equal copy (harness-call 'images/file block)))
      (should (equal file (harness-call 'images/file
                                        (list :type "image" :mime "image/png" :path file))))
      (should (equal file (harness-call 'images/file
                                        (list :type "image" :mime "image/png" :path file
                                              :snapshot (expand-file-name "elsewhere.png" dir)))))
      (delete-file copy)
      (should (equal file (harness-call 'images/file block))))))

(ert-deftest harness-images-a-changed-file-is-not-the-copy ()
  "The copy holds the bytes of the result, whatever the file holds later."
  (harness-images-test-with
    (let* ((session "s5")
           (file (harness-images-test-file dir "shot.png"))
           (copy (harness-call 'images/keep session file "image/png")))
      (harness-images-test-file dir "shot.png" "another picture entirely")
      (should-not (equal (harness-images-test-bytes file)
                         (harness-images-test-bytes copy)))
      (should (equal harness-images-test--png (harness-images-test-bytes copy)))
      (should (equal copy (harness-call 'images/file
                                        (list :type "image" :mime "image/png"
                                              :path file :snapshot copy)))))))

;;;; Going away with the session

(ert-deftest harness-images-a-deleted-session-takes-its-copies ()
  "A session's copies go when it does; another session's stay."
  (harness-images-test-with
    (let* ((file (harness-images-test-file dir "shot.png"))
           (mine (harness-call 'images/keep "s6" file "image/png"))
           (theirs (harness-call 'images/keep "s7" file "image/png")))
      (should (file-regular-p mine))
      (should (file-regular-p theirs))
      (harness-emit 'session/deleted "s6" nil)
      (should-not (file-directory-p (harness-images-directory "s6")))
      (should (file-regular-p theirs)))))

(provide 'harness-images-test)
;;; harness-images-test.el ends here
