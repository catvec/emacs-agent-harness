;;; harness-tools-fs-test.el --- Tests for the file tools  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defun harness-tools-fs-test--allow (_decision next &rest _)
  "Permissive permission filter for tests."
  (funcall next (list :behavior 'allow)))

(defun harness-tools-fs-test--setup ()
  "Load the tools modules and allow everything."
  (harness-test-load-module 'tools)
  (harness-test-load-module 'tools-fs)
  (harness-test-connect-ui-client)
  (harness-add-filter 'permission/decide #'harness-tools-fs-test--allow 10))

(defun harness-tools-fs-test--call (name &rest input)
  "Execute tool NAME with INPUT through tools/execute and wait."
  (harness-await (harness-call 'tools/execute nil (list :id "c1" :name name :input input))))

(defmacro harness-tools-fs-test-in-dir (&rest body)
  "Run BODY with `default-directory' bound to a fresh temp dir named ROOT."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (let* ((root (harness-test-temp-dir))
            (default-directory root))
       (unwind-protect (progn ,@body)
         (delete-directory root t)))))

(defun harness-tools-fs-test--write (name content)
  "Write CONTENT to NAME under `default-directory'."
  (let ((f (expand-file-name name default-directory)))
    (make-directory (file-name-directory f) t)
    (with-temp-file f (insert content))
    f))

;;;; read_file

(ert-deftest harness-tools-fs-read-file-numbers-lines-and-ranges ()
  (harness-tools-fs-test--setup)
  (harness-tools-fs-test-in-dir
    (harness-tools-fs-test--write "a.txt" "one\ntwo\nthree\nfour\nfive\n")
    (let ((r (harness-tools-fs-test--call "read_file" :path "a.txt")))
      (should-not (plist-get r :is-error))
      (should (equal "     1\tone\n     2\ttwo\n     3\tthree\n     4\tfour\n     5\tfive"
                     (plist-get r :content))))
    (let ((r (harness-tools-fs-test--call "read_file" :path "a.txt" :offset 2 :limit 2)))
      (should (string-prefix-p "     2\ttwo\n     3\tthree" (plist-get r :content)))
      (should (string-search "[a.txt: lines 2-3 of 5]" (plist-get r :content))))
    ;; A limit past the end is clamped, an offset past the end is an error.
    (let ((r (harness-tools-fs-test--call "read_file" :path "a.txt" :offset 5 :limit 100)))
      (should-not (plist-get r :is-error))
      (should (string-search "lines 5-5 of 5" (plist-get r :content))))
    (let ((r (harness-tools-fs-test--call "read_file" :path "a.txt" :offset 9)))
      (should (plist-get r :is-error))
      (should (string-search "past the end" (plist-get r :content))))
    ;; Absolute paths work too, and the title shows the range.
    (should-not (plist-get (harness-tools-fs-test--call "read_file" :path (expand-file-name "a.txt" root)) :is-error))
    (should (equal "Read file: src/x.el:10-40" (harness-tool-title "read_file" '(:path "src/x.el" :offset 10 :limit 31))))
    (should (equal "Read file: src/x.el" (harness-tool-title "read_file" '(:path "src/x.el"))))
    ;; Without a path the call is about nothing yet: the label alone.
    (should (equal "Read file" (harness-tool-title "read_file" nil)))))

(ert-deftest harness-tools-fs-read-file-refusals-and-images ()
  (harness-tools-fs-test--setup)
  (harness-tools-fs-test-in-dir
    (make-directory (expand-file-name "d" root))
    (let ((r (harness-tools-fs-test--call "read_file" :path "d")))
      (should (plist-get r :is-error))
      (should (string-search "list_dir" (plist-get r :content))))
    (let ((r (harness-tools-fs-test--call "read_file" :path "nope.txt")))
      (should (plist-get r :is-error))
      (should (string-search "not found" (plist-get r :content))))
    (let ((coding-system-for-write 'binary))
      (harness-tools-fs-test--write "blob.bin" (concat "ELF\0\0\1\2" (make-string 100 0))))
    (let ((r (harness-tools-fs-test--call "read_file" :path "blob.bin")))
      (should (plist-get r :is-error))
      (should (string-search "binary" (plist-get r :content))))
    (let ((coding-system-for-write 'binary))
      (harness-tools-fs-test--write "pic.png" "\211PNG\r\n\032\n....."))
    (let ((r (harness-tools-fs-test--call "read_file" :path "pic.png")))
      (should-not (plist-get r :is-error))
      (should (equal "image/png" (plist-get (car (plist-get r :attachments)) :mime)))
      (should (equal (expand-file-name "pic.png" root) (plist-get (car (plist-get r :attachments)) :path)))
      ;; The model gets the image too: the file, whose size is not in a header.
      (should (equal (list (list :path (expand-file-name "pic.png" root) :mime "image/png"))
                     (plist-get r :images)))
      (should (equal "Image pic.png (image/png, 13 B)." (plist-get r :content))))
    (harness-tools-fs-test--write "empty.txt" "")
    (should (string-search "empty" (plist-get (harness-tools-fs-test--call "read_file" :path "empty.txt") :content)))))

(ert-deftest harness-tools-fs-read-file-videos-and-svg ()
  "A video comes back as an attachment the chat shows, with a text for
the model; text behind a video's extension is read as text; an SVG read
from its top is its text plus its picture."
  (harness-tools-fs-test--setup)
  (harness-tools-fs-test-in-dir
    (let ((coding-system-for-write 'binary))
      (harness-tools-fs-test--write "clip.mp4" (concat "\0\0\0\030ftypmp42" (make-string 64 0))))
    (let* ((r (harness-tools-fs-test--call "read_file" :path "clip.mp4"))
           (att (car (plist-get r :attachments))))
      (should-not (plist-get r :is-error))
      (should (string-match-p "\\`Video clip.mp4 (video/mp4, 76 B) is shown to the user" (plist-get r :content)))
      (should (string-search "ffprobe" (plist-get r :content)))
      (should (equal (list :path (expand-file-name "clip.mp4" root) :mime "video/mp4" :size 76 :name "clip.mp4")
                     att))
      ;; Only the user sees a video: the model has no frames of it.
      (should-not (plist-member r :images)))
    ;; Text behind a video's extension stays text.
    (harness-tools-fs-test--write "notes.webm" "not a video\n")
    (let ((r (harness-tools-fs-test--call "read_file" :path "notes.webm")))
      (should (equal "     1\tnot a video" (plist-get r :content)))
      (should-not (plist-get r :attachments)))
    ;; An SVG: the text for the model, the picture for the user, from its top only.
    (harness-tools-fs-test--write "icon.svg" "<svg xmlns=\"http://www.w3.org/2000/svg\">\n<rect/>\n</svg>\n")
    (let ((r (harness-tools-fs-test--call "read_file" :path "icon.svg")))
      (should (string-prefix-p "     1\t<svg" (plist-get r :content)))
      (should (equal '("image/svg+xml") (mapcar (lambda (a) (plist-get a :mime)) (plist-get r :attachments))))
      ;; The model reads its text; there is no image to show it.
      (should-not (plist-member r :images)))
    (let ((r (harness-tools-fs-test--call "read_file" :path "icon.svg" :limit 1)))
      (should (string-search "lines 1-1 of 3" (plist-get r :content)))
      (should (plist-get r :attachments)))
    (should-not (plist-get (harness-tools-fs-test--call "read_file" :path "icon.svg" :offset 2) :attachments))
    ;; Plain text carries none.
    (harness-tools-fs-test--write "a.txt" "one\n")
    (should-not (plist-member (harness-tools-fs-test--call "read_file" :path "a.txt") :attachments))))

;;;; read_file: images for the model

(defun harness-tools-fs-test--bytes (&rest parts)
  "Return PARTS as one unibyte string.
A string is its bytes, a number a byte and a list of numbers bytes."
  (apply #'unibyte-string
         (apply #'append (mapcar (lambda (p)
                                   (cond ((stringp p) (append (string-to-unibyte p) nil))
                                         ((listp p) p)
                                         (t (list p))))
                                 parts))))

(defconst harness-tools-fs-test--png-bytes (length harness-test-png)
  "The size in bytes of the 2x2 PNG that tests write.")

(defun harness-tools-fs-test--write-bytes (name bytes)
  "Write the unibyte string BYTES to NAME under `default-directory'; return its path."
  (let ((coding-system-for-write 'binary))
    (harness-tools-fs-test--write name bytes)))

(defun harness-tools-fs-test--jpeg-bytes (width height)
  "Return the start of a JPEG WIDTH by HEIGHT pixels: its APP0 segment and frame header."
  (harness-tools-fs-test--bytes 255 216 255 224 0 16 "JFIF" 0 1 1 0 0 1 0 1 0 0
                                255 192 0 17 8 (list (ash height -8) (logand height 255))
                                (list (ash width -8) (logand width 255))
                                3 1 17 0 2 17 1 3 17 1))

(defun harness-tools-fs-test--ffmpeg-image (name size &rest options)
  "Make the image NAME, SIZE pixels (\"64x32\"), with the real ffmpeg; return its path.
OPTIONS go before the output file."
  (let ((file (expand-file-name name default-directory)))
    (should (zerop (apply #'call-process "ffmpeg" nil nil nil
                          "-nostdin" "-loglevel" "error" "-y" "-f" "lavfi"
                          "-i" (format "color=c=red:s=%s:d=1" size) "-frames:v" "1"
                          (append options (list file)))))
    file))

(defun harness-tools-fs-test--fake-ffmpeg (name body)
  "Write a program NAME that stands in for ffmpeg and return its path.
It runs the shell commands BODY, which see the output file as $out, and
appends the arguments of every call to the file calls.log, which
`harness-tools-fs-test--calls' reads."
  (let ((script (expand-file-name name default-directory)))
    (with-temp-file script
      (insert "#!/bin/sh\nfor a; do out=\"$a\"; done\n"
              (format "echo \"$*\" >> '%s'\n" (expand-file-name "calls.log" default-directory))
              body "\n"))
    (set-file-modes script #o755)
    script))

(defun harness-tools-fs-test--calls ()
  "Return the arguments of the calls the fake ffmpeg had, one string for each."
  (split-string (or (harness-read-file (expand-file-name "calls.log" default-directory)) "") "\n" t))

(defun harness-tools-fs-test--copies ()
  "Return the files in the directory read_file keeps its copies of images in."
  (directory-files (harness-tools-fs--copy-dir) nil directory-files-no-dot-files-regexp))

(ert-deftest harness-tools-fs-image-size-reads-headers ()
  "The pixel size of PNG, GIF, JPEG and WebP is read from their headers."
  (harness-tools-fs-test--setup)
  (harness-tools-fs-test-in-dir
    (let ((u24le (lambda (n) (list (logand n 255) (logand (ash n -8) 255) (ash n -16))))
          (u16le (lambda (n) (list (logand n 255) (ash n -8)))))
      (cl-flet ((size (name &rest parts)
                  (harness-tools-fs--image-size
                   (harness-tools-fs-test--write-bytes name (apply #'harness-tools-fs-test--bytes parts)))))
        (should (equal '(2 . 2) (size "a.png" harness-test-png)))
        (should (equal '(320 . 200) (size "a.gif" "GIF89a" (funcall u16le 320) (funcall u16le 200) 0 0 0)))
        (should (equal '(640 . 480) (size "a.jpg" (harness-tools-fs-test--jpeg-bytes 640 480))))
        (should (equal '(4000 . 3000)
                       (size "a.webp" "RIFF" 0 0 0 0 "WEBPVP8X" 0 0 0 0 0 0 0 0
                             (funcall u24le 3999) (funcall u24le 2999) 0 0)))
        (should (equal '(100 . 50)
                       (size "b.webp" "RIFF" 0 0 0 0 "WEBPVP8L" 0 0 0 0 47 #x63 #x40 #x0c 0 0 0)))
        (should (equal '(800 . 600)
                       (size "c.webp" "RIFF" 0 0 0 0 "WEBPVP8 " 0 0 0 0 0 0 0 157 1 42
                             (funcall u16le 800) (funcall u16le 600) 0 0)))
        ;; Not an image, or not a file: unknown.
        (should-not (size "text.png" "not an image at all"))
        (should-not (harness-tools-fs--image-size (expand-file-name "missing.png" root)))))))

(ert-deftest harness-tools-fs-image-kind-is-what-the-bytes-say ()
  "A provider checks the type it is told against the bytes, so the bytes decide."
  (harness-tools-fs-test--setup)
  (harness-tools-fs-test-in-dir
    (cl-flet ((kind (name &rest parts)
                (harness-tools-fs--image-kind
                 (harness-tools-fs-test--write-bytes name (apply #'harness-tools-fs-test--bytes parts)))))
      (should (equal "image/png" (kind "x.jpg" harness-test-png)))
      (should (equal "image/jpeg" (kind "x.png" (harness-tools-fs-test--jpeg-bytes 4 4))))
      (should (equal "image/gif" (kind "x.gif" "GIF87a" 1 0 1 0 0 0 0)))
      (should (equal "image/webp" (kind "x.webp" "RIFF" 0 0 0 0 "WEBPVP8 " 0 0 0 0)))
      ;; Types models do not read, text, and a RIFF file of another kind.
      (should-not (kind "x.bmp" "BM" (make-list 40 0)))
      (should-not (kind "x.png" "<html>not a picture</html>"))
      (should-not (kind "x.webp" "RIFF" 0 0 0 0 "WAVEfmt "))
      (should-not (kind "x.png" ""))
      (should-not (harness-tools-fs--image-kind (expand-file-name "missing.png" root))))))

(ert-deftest harness-tools-fs-read-image-within-the-limits-is-shown-as-it-is ()
  "An image of a type models read, within the limits, is the model's view too."
  (harness-tools-fs-test--setup)
  (harness-tools-fs-test-in-dir
    (harness-tools-fs-test--write-bytes "dir/pic.png" harness-test-png)
    (let ((r (harness-tools-fs-test--call "read_file" :path "dir/pic.png")))
      (should-not (plist-get r :is-error))
      (should (equal (format "Image dir/pic.png (image/png, %d B, 2x2 px)." harness-tools-fs-test--png-bytes)
                     (plist-get r :content)))
      (should (equal (list (list :path (expand-file-name "dir/pic.png" root) :mime "image/png"))
                     (plist-get r :images)))
      ;; What the user sees is unchanged: the file, with its size and name.
      (should (equal (list (list :path (expand-file-name "dir/pic.png" root) :mime "image/png"
                                 :size harness-tools-fs-test--png-bytes :name "pic.png"))
                     (plist-get r :attachments))))
    ;; The bytes decide the type: a JPEG named .png is sent as a JPEG, the
    ;; chat keeps what the name says.
    (harness-tools-fs-test--write-bytes "photo.png" (harness-tools-fs-test--jpeg-bytes 64 48))
    (let ((r (harness-tools-fs-test--call "read_file" :path "photo.png")))
      (should (string-prefix-p "Image photo.png (image/jpeg, " (plist-get r :content)))
      (should (string-suffix-p ", 64x48 px)." (plist-get r :content)))
      (should (equal "image/jpeg" (plist-get (car (plist-get r :images)) :mime)))
      (should (equal "image/png" (plist-get (car (plist-get r :attachments)) :mime))))))

(ert-deftest harness-tools-fs-read-image-shrinks-with-ffmpeg ()
  "An image over the pixel limit is shown as a copy fitted into it, made once."
  (skip-unless (executable-find "ffmpeg"))
  (harness-tools-fs-test--setup)
  (harness-tools-fs-test-in-dir
    (harness-tools-fs-test--ffmpeg-image "wide.png" "64x32")
    (let* ((harness-tools-fs-image-max-side 16)
           (r (harness-tools-fs-test--call "read_file" :path "wide.png"))
           (image (car (plist-get r :images)))
           (copy (plist-get image :path)))
      (should-not (plist-get r :is-error))
      (should (equal (format "Image wide.png (image/png, %s, 64x32 px), downscaled to 16x8 px to show you."
                             (harness-format-bytes (harness-file-size (expand-file-name "wide.png" root))))
                     (plist-get r :content)))
      ;; The model's view is a copy of its own, the user's the file.
      (should (equal "image/png" (plist-get image :mime)))
      (should (string-prefix-p (harness-tools-fs--copy-dir) copy))
      (should (equal '(16 . 8) (harness-tools-fs--image-size copy)))
      (should (equal (list (expand-file-name "wide.png" root))
                     (mapcar (lambda (a) (plist-get a :path)) (plist-get r :attachments))))
      (should (equal 1 (length (harness-tools-fs-test--copies))))
      ;; A second read makes no second copy, nor needs ffmpeg for it.
      (let ((mtime (file-attribute-modification-time (file-attributes copy)))
            (harness-tools-fs-ffmpeg nil))
        (sleep-for 0.05)
        (should (equal copy (plist-get (car (plist-get (harness-tools-fs-test--call "read_file" :path "wide.png") :images)) :path)))
        (should (equal mtime (file-attribute-modification-time (file-attributes copy)))))
      ;; Another size asked for, or another file in its place, is another copy.
      (let ((harness-tools-fs-image-max-side 8))
        (should-not (equal copy (plist-get (car (plist-get (harness-tools-fs-test--call "read_file" :path "wide.png") :images)) :path))))
      (harness-tools-fs-test--ffmpeg-image "wide.png" "48x24")
      (let ((again (plist-get (car (plist-get (harness-tools-fs-test--call "read_file" :path "wide.png") :images)) :path)))
        (should-not (equal copy again))
        (should (equal '(16 . 8) (harness-tools-fs--image-size again)))))))

(ert-deftest harness-tools-fs-read-image-copy-keeps-a-jpeg-a-jpeg-and-converts-the-rest ()
  "A JPEG is shrunk to a JPEG; a type models do not read becomes a PNG."
  (skip-unless (executable-find "ffmpeg"))
  (harness-tools-fs-test--setup)
  (harness-tools-fs-test-in-dir
    (harness-tools-fs-test--ffmpeg-image "wide.jpg" "64x32" "-q:v" "2")
    (harness-tools-fs-test--ffmpeg-image "wide.bmp" "64x32")
    (harness-tools-fs-test--ffmpeg-image "wide.tiff" "64x32")
    (let* ((harness-tools-fs-image-max-side 16)
           (r (harness-tools-fs-test--call "read_file" :path "wide.jpg"))
           (image (car (plist-get r :images))))
      (should (equal "image/jpeg" (plist-get image :mime)))
      (should (string-suffix-p ".jpg" (plist-get image :path)))
      (should (equal '(16 . 8) (harness-tools-fs--image-size (plist-get image :path))))
      (should (string-suffix-p ", 64x32 px), downscaled to 16x8 px to show you." (plist-get r :content))))
    ;; A BMP fits the limits, but models do not read it: converted.
    (let* ((r (harness-tools-fs-test--call "read_file" :path "wide.bmp"))
           (image (car (plist-get r :images))))
      (should (string-match-p "\\`Image wide.bmp (image/bmp, .*, 64x32 px), converted to PNG to show you\\.\\'"
                              (plist-get r :content)))
      (should (equal "image/png" (plist-get image :mime)))
      (should (equal '(64 . 32) (harness-tools-fs--image-size (plist-get image :path))))
      (should (equal "image/bmp" (plist-get (car (plist-get r :attachments)) :mime))))
    ;; Converted and too large at once.
    (let* ((harness-tools-fs-image-max-side 16)
           (r (harness-tools-fs-test--call "read_file" :path "wide.bmp")))
      (should (string-suffix-p ", converted to PNG and downscaled to 16x8 px to show you." (plist-get r :content))))
    ;; A TIFF has no size in a header read here; it is converted all the same.
    (let ((r (harness-tools-fs-test--call "read_file" :path "wide.tiff")))
      (should (string-match-p "\\`Image wide.tiff (image/tiff, [^,]*), converted to PNG to show you\\.\\'"
                              (plist-get r :content)))
      (should (equal "image/png" (plist-get (car (plist-get r :images)) :mime))))))

(ert-deftest harness-tools-fs-read-image-makes-one-copy-for-two-reads-at-once ()
  "Two reads of one large image at once leave one copy, and no half of one."
  (skip-unless (executable-find "ffmpeg"))
  (harness-tools-fs-test--setup)
  (harness-tools-fs-test-in-dir
    (harness-tools-fs-test--ffmpeg-image "wide.png" "64x32")
    (let* ((harness-tools-fs-image-max-side 16)
           (call (lambda ()
                   (harness-call 'tools/execute nil (list :id (harness-short-id) :name "read_file"
                                                          :input (list :path "wide.png")))))
           (p1 (funcall call))
           (p2 (funcall call))
           (r1 (harness-await p1))
           (r2 (harness-await p2)))
      (should (equal (plist-get r1 :images) (plist-get r2 :images)))
      (should (equal 1 (length (harness-tools-fs-test--copies))))
      (should-not (cl-find-if (lambda (f) (string-search ".part" f)) (harness-tools-fs-test--copies))))))

(ert-deftest harness-tools-fs-read-image-tries-smaller-copies ()
  "A copy still over the byte limit is made again smaller; the tries are kept."
  (harness-tools-fs-test--setup)
  (harness-tools-fs-test-in-dir
    (harness-tools-fs-test--write-bytes "ok.png" harness-test-png)
    ;; An image of 3000 bytes more, within the pixel limit but over the byte one.
    (harness-tools-fs-test--write-bytes "big.png" (concat harness-test-png (make-string 3000 0)))
    (let* ((ok (expand-file-name "ok.png" root))
           ;; Fitted into 1000 pixels it comes out too big; into 700 it is fine.
           (harness-tools-fs-ffmpeg
            (harness-tools-fs-test--fake-ffmpeg
             "ffmpeg-by-size.sh"
             (format "case \"$*\" in\n *'min(1000,iw)'*) cp '%s' \"$out\"; head -c 5000 /dev/zero >> \"$out\" ;;\n *) cp '%s' \"$out\" ;;\nesac" ok ok)))
           (harness-tools-fs-image-max-side 1000)
           (harness-tools-fs-image-max-bytes 2000)
           (r (harness-tools-fs-test--call "read_file" :path "big.png"))
           (copy (plist-get (car (plist-get r :images)) :path)))
      (should (equal (format "Image big.png (image/png, %s, 2x2 px), recompressed to show you."
                             (harness-format-bytes (+ 3000 harness-tools-fs-test--png-bytes)))
                     (plist-get r :content)))
      (should (equal "image/png" (plist-get (car (plist-get r :images)) :mime)))
      (should (= harness-tools-fs-test--png-bytes (harness-file-size copy)))
      (should (= 2 (length (harness-tools-fs-test--calls))))
      (should (string-match-p "min(1000,iw)" (nth 0 (harness-tools-fs-test--calls))))
      (should (string-match-p "min(700,iw)" (nth 1 (harness-tools-fs-test--calls))))
      ;; Read again: the two tries are in the cache, ffmpeg is not run.
      (should (equal copy (plist-get (car (plist-get (harness-tools-fs-test--call "read_file" :path "big.png") :images)) :path)))
      (should (= 2 (length (harness-tools-fs-test--calls)))))))

(ert-deftest harness-tools-fs-read-image-says-when-it-cannot-be-shown ()
  "An image no copy could be made of is shown to the user, and the model is told why not."
  (harness-tools-fs-test--setup)
  (harness-tools-fs-test-in-dir
    (harness-tools-fs-test--write-bytes "pic.png" harness-test-png)
    (let* ((file (expand-file-name "pic.png" root))
           (att (list (list :path file :mime "image/png" :size harness-tools-fs-test--png-bytes :name "pic.png")))
           (failing (harness-tools-fs-test--fake-ffmpeg "ffmpeg-failing.sh" "echo partial > \"$out\"; echo '[png @ 0x55d0c8a3e0c0] boom: no good' >&2; echo second line >&2; exit 1"))
           (name (format "Image pic.png (image/png, %d B, 2x2 px)" harness-tools-fs-test--png-bytes)))
      ;; Too many pixels for the limit, a copy impossible: within what a provider takes, as it is.
      (let ((harness-tools-fs-image-max-side 1)
            (harness-tools-fs-ffmpeg failing))
        (let ((r (harness-tools-fs-test--call "read_file" :path "pic.png")))
          (should (equal (concat name ".") (plist-get r :content)))
          (should (equal (list (list :path file :mime "image/png")) (plist-get r :images))))
        ;; ffmpeg left nothing half made behind.
        (should-not (harness-tools-fs-test--copies)))
      ;; Over the byte limit too: nothing to show.  The first line of what ffmpeg said, without its address.
      (let ((harness-tools-fs-image-max-side 1)
            (harness-tools-fs-image-max-bytes 10)
            (harness-tools-fs-ffmpeg failing))
        (let ((r (harness-tools-fs-test--call "read_file" :path "pic.png")))
          (should-not (plist-get r :is-error))
          (should-not (plist-member r :images))
          (should (equal att (plist-get r :attachments)))
          (should (equal (concat name " is shown to the user, but it is too large to show you (at most 10 B and 8000 px a side) and could not be made smaller: ffmpeg failed: [png] boom: no good. Make a smaller copy with bash (ffmpeg -i IN -vf \"scale=1:1:force_original_aspect_ratio=decrease\" OUT.png) and read that.")
                         (plist-get r :content)))
          (should-not (harness-tools-fs-test--copies))))
      ;; ffmpeg off, missing, or taking too long.
      (let ((harness-tools-fs-image-max-bytes 10))
        (let ((harness-tools-fs-ffmpeg nil))
          (should (string-search "could not be made smaller: ffmpeg is turned off (harness-tools-fs-ffmpeg is nil). Make a smaller copy"
                                 (plist-get (harness-tools-fs-test--call "read_file" :path "pic.png") :content))))
        (let ((harness-tools-fs-ffmpeg "harness-test-no-such-ffmpeg"))
          (should (string-search "could not be made smaller: harness-test-no-such-ffmpeg is not installed. Make"
                                 (plist-get (harness-tools-fs-test--call "read_file" :path "pic.png") :content))))
        (let ((harness-tools-fs-ffmpeg (harness-tools-fs-test--fake-ffmpeg "ffmpeg-slow.sh" "sleep 5"))
              (harness-tools-fs--ffmpeg-timeout 0.3))
          (should (string-search "could not be made smaller: ffmpeg took more than 0.3 seconds. Make"
                                 (plist-get (harness-tools-fs-test--call "read_file" :path "pic.png") :content)))))
      ;; The hard pixel limit applies to the image itself, whatever ffmpeg does.
      (let ((harness-tools-fs-ffmpeg nil)
            (harness-tools-fs--image-hard-max-side 1)
            (harness-tools-fs-image-max-side 1))
        (let ((r (harness-tools-fs-test--call "read_file" :path "pic.png")))
          (should-not (plist-member r :images))
          (should (string-search "(at most 3.75 MiB and 1 px a side)" (plist-get r :content)))))
      ;; A type models do not read, which nothing could convert.
      (harness-tools-fs-test--write-bytes "pic.bmp" (harness-tools-fs-test--bytes "BM" (make-list 40 0)))
      (let ((harness-tools-fs-ffmpeg nil))
        (let ((r (harness-tools-fs-test--call "read_file" :path "pic.bmp")))
          (should-not (plist-member r :images))
          (should (equal "image/bmp" (plist-get (car (plist-get r :attachments)) :mime)))
          (should (equal "Image pic.bmp (image/bmp, 42 B) is shown to the user, but you can read only PNG, JPEG, GIF and WebP images, and it could not be converted: ffmpeg is turned off (harness-tools-fs-ffmpeg is nil). Convert it with bash (ffmpeg -i IN OUT.png) and read that."
                         (plist-get r :content)))))
      ;; The same for bytes that are no image at all behind an image's name.
      (harness-tools-fs-test--write "fake.png" "<html>not found</html>\n")
      (let ((harness-tools-fs-ffmpeg failing))
        (let ((r (harness-tools-fs-test--call "read_file" :path "fake.png")))
          (should-not (plist-member r :images))
          (should (string-search "you can read only PNG, JPEG, GIF and WebP images, and it could not be converted: ffmpeg failed: [png] boom: no good. Convert it"
                                 (plist-get r :content)))
          (should (plist-get r :attachments)))))))

(ert-deftest harness-tools-fs-read-image-limits-follow-links-and-providers ()
  "A link to a large image is a large image, and no setting lifts what providers refuse."
  (harness-tools-fs-test--setup)
  (harness-tools-fs-test-in-dir
    (harness-tools-fs-test--write-bytes "real.png" harness-test-png)
    (make-symbolic-link "real.png" (expand-file-name "link.png" root))
    (let ((harness-tools-fs-ffmpeg nil))
      ;; A link is a few bytes long itself; the image it names is not.
      (let ((harness-tools-fs-image-max-bytes (- harness-tools-fs-test--png-bytes 1)))
        (should (< (harness-file-size (expand-file-name "link.png" root)) harness-tools-fs-test--png-bytes))
        (dolist (name '("real.png" "link.png"))
          (let ((r (harness-tools-fs-test--call "read_file" :path name)))
            (should-not (plist-member r :images))
            (should (string-search "too large to show you" (plist-get r :content))))))
      (should (plist-get (harness-tools-fs-test--call "read_file" :path "link.png") :images))
      ;; A pixel limit above the providers' is theirs.
      (let ((harness-tools-fs-image-max-side 100000)
            (harness-tools-fs--image-hard-max-side 1))
        (let ((r (harness-tools-fs-test--call "read_file" :path "real.png")))
          (should-not (plist-member r :images))
          (should (string-search "(at most 3.75 MiB and 1 px a side)" (plist-get r :content))))))))

(ert-deftest harness-tools-fs-read-image-on-another-host-cannot-be-copied ()
  "A copy is made here, so an image on another host is not shrunk."
  (harness-tools-fs-test--setup)
  (should (equal '(:error "it is on another host, where read_file cannot run ffmpeg")
                 (harness-await (harness-tools-fs--shrink "/ssh:harness-no-such-host:/tmp/x.png" nil)))))

(ert-deftest harness-tools-fs-image-options-and-description ()
  "The limits are those decided, and the tool description promises what is done."
  (harness-tools-fs-test--setup)
  (should (= 3932160 (default-value 'harness-tools-fs-image-max-bytes)))
  (should (= 2000 (default-value 'harness-tools-fs-image-max-side)))
  (should (equal "ffmpeg" (default-value 'harness-tools-fs-ffmpeg)))
  (should (= 8000 harness-tools-fs--image-hard-max-side))
  (should (equal "3.75 MiB" (harness-tools-fs--limit-text 3932160)))
  (should (equal "5 MiB" (harness-tools-fs--limit-text (* 5 1024 1024))))
  (should (equal "900 KiB" (harness-tools-fs--limit-text (* 900 1024))))
  (should (equal '(2000 1400 1000) (harness-tools-fs--shrink-sides)))
  (let ((description (plist-get (harness-call 'tools/get "read_file") :description)))
    (should (string-search "An image (PNG, JPEG, GIF, WebP; other types and oversized images are converted when ffmpeg is installed) comes back as an image you see, when your model reads images, and is shown to the user; a video is shown to the user" description))
    (should-not (string-search "Images are attached as images" description))))

(ert-deftest harness-tools-fs-read-file-context-bomb ()
  (harness-tools-fs-test--setup)
  (harness-tools-fs-test-in-dir
    (harness-tools-fs-test--write "big.txt"
                                  (mapconcat (lambda (i) (format "line number %d with some padding text" i))
                                             (number-sequence 1 2000) "\n"))
    (let* ((harness-tools-max-output-chars 2000)
           (r (harness-tools-fs-test--call "read_file" :path "big.txt")))
      (should-not (plist-get r :is-error))
      (should (plist-get r :truncated))
      (should (<= (length (plist-get r :content)) 2000))
      (should (string-search "Continue with offset" (plist-get r :content)))
      (should (= 2000 (plist-get (plist-get r :truncated) :total)))
      (should (= 1 (car (plist-get (plist-get r :truncated) :lines))))
      ;; Continuing from the suggested offset works and is not truncated when small.
      (let* ((next (1+ (cdr (plist-get (plist-get r :truncated) :lines))))
             (r2 (harness-tools-fs-test--call "read_file" :path "big.txt" :offset next :limit 5)))
        (should-not (plist-get r2 :truncated))
        (should (string-search (format "%6d\tline number %d" next next) (plist-get r2 :content)))))
    ;; The generic guard still protects other tools.
    (let* ((harness-tools-max-output-chars 300)
           (r (harness-tools-fs-test--call "grep" :pattern "line" :path "big.txt" :max_results 100)))
      (should (plist-get r :truncated))
      (should (string-search "Output truncated" (plist-get r :content)))
      (should (file-exists-p (plist-get (plist-get r :truncated) :path))))))

;;;; write_file / edit_file

(ert-deftest harness-tools-fs-write-file-creates-parents-and-reverts-buffers ()
  (harness-tools-fs-test--setup)
  (harness-tools-fs-test-in-dir
    (let ((r (harness-tools-fs-test--call "write_file" :path "sub/dir/new.txt" :content "hello\nworld\n")))
      (should-not (plist-get r :is-error))
      (should (string-search "Created sub/dir/new.txt (12 bytes, 2 lines)" (plist-get r :content)))
      (should (equal "hello\nworld\n" (harness-read-file (expand-file-name "sub/dir/new.txt" root)))))
    ;; An unmodified buffer visiting the file is reverted by the UI, once
    ;; the `tools/file-written' notification reaches it.
    (let ((buf (find-file-noselect (expand-file-name "sub/dir/new.txt" root))))
      (unwind-protect
          (progn
            (harness-tools-fs-test--call "write_file" :path "sub/dir/new.txt" :content "changed\n")
            (harness-test-wait (lambda () (equal "changed\n" (with-current-buffer buf (buffer-string)))) 5 "revert")
            (should-not (buffer-modified-p buf))
            ;; A modified buffer is left alone.
            (with-current-buffer buf (goto-char (point-max)) (insert "local edit"))
            (harness-tools-fs-test--call "write_file" :path "sub/dir/new.txt" :content "again\n")
            (sit-for 0.1)
            (should (string-search "local edit" (with-current-buffer buf (buffer-string)))))
        (with-current-buffer buf (set-buffer-modified-p nil))
        (kill-buffer buf)))
    (should (string-search "Overwrote" (plist-get (harness-tools-fs-test--call "write_file" :path "sub/dir/new.txt" :content "x") :content)))
    (should (plist-get (harness-tools-fs-test--call "write_file" :path "sub") :is-error))
    (should (equal "Write file: a.txt (3 bytes)" (harness-tool-title "write_file" '(:path "a.txt" :content "abc"))))))

(ert-deftest harness-tools-fs-edit-file-success-and-failure-modes ()
  (harness-tools-fs-test--setup)
  (harness-tools-fs-test-in-dir
    (harness-tools-fs-test--write "e.el" "(defun foo ()\n  (bar 1))\n(defun baz ()\n  (bar 1))\n")
    ;; Ambiguous without replace_all.
    (let ((r (harness-tools-fs-test--call "edit_file" :path "e.el" :old_string "(bar 1)" :new_string "(bar 2)")))
      (should (plist-get r :is-error))
      (should (string-search "matches 2 places" (plist-get r :content)))
      (should (string-search "(bar 1)" (harness-read-file (expand-file-name "e.el" root)))))
    ;; Unique with context.
    (let ((r (harness-tools-fs-test--call "edit_file" :path "e.el" :old_string "foo ()\n  (bar 1)" :new_string "foo ()\n  (bar 2)")))
      (should-not (plist-get r :is-error))
      (should (string-search "replaced 1 occurrence at line 1" (plist-get r :content)))
      (should (equal "(defun foo ()\n  (bar 2))\n(defun baz ()\n  (bar 1))\n" (harness-read-file (expand-file-name "e.el" root)))))
    ;; Missing, with a whitespace hint when that is the problem.
    (let ((r (harness-tools-fs-test--call "edit_file" :path "e.el" :old_string "nothing here" :new_string "x")))
      (should (plist-get r :is-error))
      (should (string-search "not found" (plist-get r :content))))
    (let ((r (harness-tools-fs-test--call "edit_file" :path "e.el" :old_string "(defun baz ()\n    (bar 1))" :new_string "x")))
      (should (plist-get r :is-error))
      (should (string-search "whitespace" (plist-get r :content))))
    ;; replace_all.
    (let ((r (harness-tools-fs-test--call "edit_file" :path "e.el" :old_string "bar" :new_string "qux" :replace_all t)))
      (should-not (plist-get r :is-error))
      (should (string-search "replaced 2 occurrences" (plist-get r :content)))
      (should-not (string-search "bar" (harness-read-file (expand-file-name "e.el" root)))))
    ;; Bad inputs.
    (should (plist-get (harness-tools-fs-test--call "edit_file" :path "e.el" :old_string "" :new_string "x") :is-error))
    (should (plist-get (harness-tools-fs-test--call "edit_file" :path "e.el" :old_string "qux" :new_string "qux") :is-error))
    (should (string-search "write_file" (plist-get (harness-tools-fs-test--call "edit_file" :path "missing.el" :old_string "a" :new_string "b") :content)))
    ;; Case-sensitive literal match, no regexp interpretation.
    (harness-tools-fs-test--write "r.txt" "a.b A.B axb\n")
    (harness-tools-fs-test--call "edit_file" :path "r.txt" :old_string "a.b" :new_string "Z")
    (should (equal "Z A.B axb\n" (harness-read-file (expand-file-name "r.txt" root))))))

;;;; list_dir / glob / file_info

(ert-deftest harness-tools-fs-list-dir ()
  (harness-tools-fs-test--setup)
  (harness-tools-fs-test-in-dir
    (harness-tools-fs-test--write "a.txt" "12345")
    (harness-tools-fs-test--write "sub/b.txt" "x")
    (harness-tools-fs-test--write ".git/config" "hidden")
    (let* ((r (harness-tools-fs-test--call "list_dir"))
           (c (plist-get r :content)))
      (should-not (plist-get r :is-error))
      (should (string-search "a.txt  5 B" c))
      (should (string-search "sub/\n" c))
      (should-not (string-search "b.txt" c))
      (should-not (string-search ".git" c))
      (should (string-search "(2 entries in ., depth 1)" c)))
    (let ((c (plist-get (harness-tools-fs-test--call "list_dir" :path "." :depth 2) :content)))
      (should (string-search "sub/b.txt  1 B" c)))
    (should (string-search "is empty" (plist-get (harness-tools-fs-test--call "list_dir" :path (progn (make-directory "e") "e")) :content)))
    (should (plist-get (harness-tools-fs-test--call "list_dir" :path "a.txt") :is-error))
    (should (plist-get (harness-tools-fs-test--call "list_dir" :path "nope") :is-error))
    (let ((harness-tools-fs--list-limit 1))
      (should (string-search "Listing stopped" (plist-get (harness-tools-fs-test--call "list_dir") :content))))))

(ert-deftest harness-tools-fs-glob ()
  (harness-tools-fs-test--setup)
  (harness-tools-fs-test-in-dir
    (harness-tools-fs-test--write "a.el" "")
    (harness-tools-fs-test--write "b.txt" "")
    (harness-tools-fs-test--write "src/c.el" "")
    (harness-tools-fs-test--write "src/deep/d.el" "")
    (harness-tools-fs-test--write ".git/e.el" "")
    (let ((c (plist-get (harness-tools-fs-test--call "glob" :pattern "*.el") :content)))
      (should (string-search "a.el" c))
      (should-not (string-search "c.el" c))
      (should (string-search "(1 match" c)))
    (let ((c (plist-get (harness-tools-fs-test--call "glob" :pattern "**/*.el") :content)))
      (should (string-search "a.el" c))
      (should (string-search "src/c.el" c))
      (should (string-search "src/deep/d.el" c))
      (should-not (string-search ".git" c))
      (should (string-search "(3 matches" c)))
    (let ((c (plist-get (harness-tools-fs-test--call "glob" :pattern "**/*.el" :path "src") :content)))
      (should (string-search "c.el\n" c))
      (should-not (string-search "a.el" c)))
    (let ((c (plist-get (harness-tools-fs-test--call "glob" :pattern "src/*/*.el") :content)))
      (should (string-search "src/deep/d.el" c))
      (should (string-search "(1 match" c)))
    (should (string-search "No files match" (plist-get (harness-tools-fs-test--call "glob" :pattern "*.zip") :content)))
    (let ((harness-tools-fs--glob-limit 2))
      (should (string-search "showing 2" (plist-get (harness-tools-fs-test--call "glob" :pattern "**/*.el") :content))))
    (should (plist-get (harness-tools-fs-test--call "glob" :pattern "*" :path "nope") :is-error))
    (should (equal "Find files: **/*.el in src" (harness-tool-title "glob" '(:pattern "**/*.el" :path "src"))))))

(ert-deftest harness-tools-fs-glob-regexp ()
  (harness-tools-fs-test--setup)
  (let ((rx (harness-tools-fs--glob-regexp "src/**/*.el")))
    (should (string-match-p rx "src/a.el"))
    (should (string-match-p rx "src/x/y/a.el"))
    (should-not (string-match-p rx "lib/a.el"))
    (should-not (string-match-p rx "src/a.elc")))
  (should (string-match-p (harness-tools-fs--glob-regexp "*.el") "a.el"))
  (should-not (string-match-p (harness-tools-fs--glob-regexp "*.el") "d/a.el"))
  (should (string-match-p (harness-tools-fs--glob-regexp "a?c.[ch]") "abc.h")))

(ert-deftest harness-tools-fs-file-info ()
  (harness-tools-fs-test--setup)
  (harness-tools-fs-test-in-dir
    (harness-tools-fs-test--write "f.txt" "a\nb\nc\n")
    (let* ((r (harness-tools-fs-test--call "file_info" :path "f.txt"))
           (c (plist-get r :content)))
      (should-not (plist-get r :is-error))
      (should (string-search "type: file" c))
      (should (string-search "size: 6 bytes" c))
      (should (string-search "lines: 3" c))
      (should (string-search "content: text" c))
      (should (string-search "mime: text/plain" c))
      (should (string-match-p "modified: [0-9]\\{4\\}-" c))
      (should (= 3 (plist-get (plist-get r :meta) :lines))))
    (make-directory "d")
    (harness-tools-fs-test--write "d/x" "")
    (let ((c (plist-get (harness-tools-fs-test--call "file_info" :path "d") :content)))
      (should (string-search "type: directory" c))
      (should (string-search "entries: 1" c)))
    (should (plist-get (harness-tools-fs-test--call "file_info" :path "missing") :is-error))))

;;;; grep

(defun harness-tools-fs-test--grep-fixture ()
  "Create files for the grep tests."
  (harness-tools-fs-test--write "a.txt" "Hello world\nsecond line\nhello again\n")
  (harness-tools-fs-test--write "sub/b.el" "(defun hello () nil)\n")
  (harness-tools-fs-test--write "sub/c.txt" "nothing\n")
  (harness-tools-fs-test--write ".git/HEAD" "hello ref\n"))

(defun harness-tools-fs-test--grep-checks (program)
  "Run the grep assertions expecting PROGRAM to be used."
  (let* ((r (harness-tools-fs-test--call "grep" :pattern "hello"))
         (c (plist-get r :content)))
    (should-not (plist-get r :is-error))
    (should (string-search "a.txt:1: Hello world" c))
    (should (string-search "a.txt:3: hello again" c))
    (should (string-search "sub/b.el:1: (defun hello () nil)" c))
    (should-not (string-search ".git" c))
    (should (string-search "(3 matches)" c)))
  ;; Case sensitive.
  (let ((c (plist-get (harness-tools-fs-test--call "grep" :pattern "hello" :case_sensitive t) :content)))
    (should-not (string-search "Hello world" c))
    (should (string-search "(2 matches)" c)))
  ;; Glob filter and a subdirectory path.
  (let ((c (plist-get (harness-tools-fs-test--call "grep" :pattern "hello" :glob "*.el") :content)))
    (should (string-search "sub/b.el:1:" c))
    (should-not (string-search "a.txt" c)))
  (let ((c (plist-get (harness-tools-fs-test--call "grep" :pattern "hello" :path "sub") :content)))
    (should (string-search "sub/b.el:1:" c))
    (should-not (string-search "a.txt" c)))
  ;; A single file target.
  (should (string-search "a.txt:2: second line" (plist-get (harness-tools-fs-test--call "grep" :pattern "second" :path "a.txt") :content)))
  ;; max_results caps and says so.
  (let ((c (plist-get (harness-tools-fs-test--call "grep" :pattern "hello" :max_results 1) :content)))
    (should (string-search "3 matches, showing the first 1" c)))
  ;; No matches is not an error.
  (let ((r (harness-tools-fs-test--call "grep" :pattern "zzzzqqq")))
    (should-not (plist-get r :is-error))
    (should (string-search "No matches" (plist-get r :content))))
  ;; A bad regexp is a tool error naming the program.
  (let ((r (harness-tools-fs-test--call "grep" :pattern "(unclosed")))
    (should (plist-get r :is-error))
    (should (string-search program (plist-get r :content))))
  (should (plist-get (harness-tools-fs-test--call "grep" :pattern "x" :path "nope") :is-error)))

(ert-deftest harness-tools-fs-grep-with-rg ()
  (harness-tools-fs-test--setup)
  (skip-unless (executable-find "rg"))
  (harness-tools-fs-test-in-dir
    (harness-tools-fs-test--grep-fixture)
    (should (equal "rg" (car (harness-tools-fs--grep-command "x" "." nil nil root))))
    (harness-tools-fs-test--grep-checks "rg")))

(ert-deftest harness-tools-fs-grep-with-grep-fallback ()
  (harness-tools-fs-test--setup)
  (harness-tools-fs-test-in-dir
    (harness-tools-fs-test--grep-fixture)
    (let ((real (symbol-function 'executable-find)))
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (name &optional remote) (unless (equal name "rg") (funcall real name remote)))))
        (should (equal "grep" (car (harness-tools-fs--grep-command "x" "." nil nil root))))
        (harness-tools-fs-test--grep-checks "grep")))))

(ert-deftest harness-tools-fs-grep-is-async ()
  "grep returns a promise and the handler does not block."
  (harness-tools-fs-test--setup)
  (harness-tools-fs-test-in-dir
    (harness-tools-fs-test--write "a.txt" "needle\n")
    (let ((p (harness-call 'tools/execute nil (list :id "c2" :name "grep" :input (list :pattern "needle")))))
      (should (harness-promise-p p))
      (should-not (harness-promise-settled-p p))
      (should (string-search "a.txt:1: needle" (plist-get (harness-await p) :content))))))

;;;; paths and remote resolution

(ert-deftest harness-tools-fs-paths-and-kinds ()
  (harness-tools-fs-test--setup)
  (dolist (spec '(("read_file" read t) ("write_file" write nil) ("edit_file" write nil)
                  ("list_dir" read t) ("glob" read t) ("grep" read t) ("file_info" read t)))
    (let ((tool (harness-tool-get (car spec))))
      (should tool)
      (should (eq (cadr spec) (harness-tool-kind tool)))
      (should (eq (caddr spec) (and (harness-tool-coalescable tool) t)))
      (should (functionp (harness-tool-paths-fn tool)))))
  (should (equal '("x.el") (funcall (harness-tool-paths-fn (harness-tool-get "read_file")) '(:path "x.el"))))
  (should (equal '(".") (funcall (harness-tool-paths-fn (harness-tool-get "grep")) '(:pattern "p"))))
  ;; Relative paths resolve against the session cwd and keep the TRAMP host.
  (should (equal "/ssh:host:/srv/app/src/x.el"
                 (harness-tools-resolve-path "src/x.el" '(:cwd "/srv/app/" :host "/ssh:host:")))))

(provide 'harness-tools-fs-test)
;;; harness-tools-fs-test.el ends here
