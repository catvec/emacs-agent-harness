;;; harness-tools-fs.el --- File system tools  -*- lexical-binding: t; -*-

;;; Commentary:

;; The file tools a model uses most: read_file, write_file, edit_file,
;; list_dir, glob, grep and file_info.  Everything runs on Emacs file
;; primitives (`insert-file-contents', `write-region',
;; `directory-files-recursively', `file-expand-wildcards'), so a
;; session whose cwd carries a TRAMP prefix works on the remote host
;; without any tool knowing about it, and any session reaches a host
;; through a TRAMP path such as /ssh:host:/etc/hosts (see the ssh tool,
;; tools-ssh).  Only grep spawns a process, and it does so
;; asynchronously through `harness-run-command' on the host its path
;; is on: in the session cwd when that is the same host, else in the
;; path's own directory there.
;;
;; Every path is resolved with `harness-tools-resolve-path' against
;; the session cwd and host, and every tool declares the paths it
;; touches so the permission jail can judge them.
;;
;; Where they run.  The jail compares paths, once, in the harness
;; process, which can reach everything; the use that follows can differ
;; from what was compared.  So where the sandbox applies, the tools do
;; not run in the harness at all: a call on a local path goes to a
;; worker (lisp/harness-mcp-fs.el), an Emacs the harness starts in the
;; session's sandbox through its MCP host, with the mounts a bash
;; command of the session gets, and the handlers below run there,
;; unchanged.  A path outside the mounts does not exist for the worker,
;; whatever the permission chain decided.  A call on a path of another
;; host (TRAMP), one where no sandbox applies (the policy is `off', or
;; `preferred' with no backend, as for bash), and one with
;; `harness-tools-fs-jail' off run here, as they always did.  Where a
;; call has to reach beyond the session's directories on purpose -- the
;; harness's own files, a skills directory, a file the user's Emacs
;; showed a definition in, a directory the user allowed for this call
;; alone, a call the user approved after it was denied -- the worker is
;; started with exactly those mounts added (see "Running in the
;; sandbox"), and only for that call.
;;
;; Reads are guarded against context bombs: read_file trims the
;; requested range to `harness-tools-max-output-chars' at a line
;; boundary and says where to continue, other tools rely on the
;; generic guard in `tools/execute'.
;;
;; read_file also returns media as `:attachments', which the chat
;; shows the user: an image, a video (as a poster the user can play;
;; the model is told what it is and how to look inside), and the
;; picture of an SVG read from its top, whose text the model reads.
;;
;; An image is also returned as `:images', which the model sees when its
;; model reads images: a list of (:path PATH :mime MIME), MIME one of
;; image/png, image/jpeg, image/gif and image/webp, the types every
;; provider takes.  `:attachments' stays what the user sees, the file
;; as it is; `:images' is the model's view of it.  PATH is the file
;; itself when it is within `harness-tools-fs-image-max-bytes' and
;; `harness-tools-fs-image-max-side'.  Otherwise ffmpeg makes a copy
;; that is (`harness-tools-fs-ffmpeg'): fitted into that many pixels,
;; its first frame only, a JPEG for a JPEG and else a PNG, so that a
;; BMP or a TIFF is converted too.  The copy is kept under
;; `harness-state-directory', named after the file it comes from, its
;; size and time, and the size it was fitted into, so a second read
;; makes none.  Without a copy the file itself is shown when it is no
;; larger than a provider takes (8000 pixels on a side), and otherwise
;; the model is told that the image is too large and how to make a
;; smaller one.  The text says which: the model must not believe it
;; saw an image it did not, and a model that reads no images is told so
;; by the agent, which owns that knowledge.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'mailcap)
(require 'harness-core)
(require 'harness-util)
(require 'harness-tools)

(defvar harness-state-directory)
(defvar harness-directory)
(defvar harness-elisp-emacs)
(defvar harness-tools-fs--copy-root nil
  "Directory the copies of images for a model are made in, or nil.
The worker sets it from the session's own temporary directory, which
the harness can read; without it copies go under `harness-state-directory'.")

(declare-function harness-mcp-define-server "harness-mcp" (name &rest keys))
(declare-function harness-mcp-call-tool "harness-mcp" (server tool input ctx &optional timeout meta key))
(declare-function harness-mcp-server-declared-p "harness-mcp" (name))
(declare-function harness-tools-shell-sandbox-profile "harness-tools-shell" (ctx cwd &rest options))
(declare-function harness-tools-shell-child-dirs "harness-tools-shell" ())
(declare-function harness-tools-shell--tmp-dir "harness-tools-shell" (ctx))
(declare-function harness-tools-shell--sandbox-required-p "harness-tools-shell" (cwd))
(declare-function harness--compile-directory "harness" ())

(defconst harness-tools-fs--glob-limit 500
  "Maximum number of paths returned by the glob tool.")

(defconst harness-tools-fs--list-limit 2000
  "Maximum number of entries listed by list_dir before it stops.")

(defconst harness-tools-fs--grep-timeout 60
  "Seconds a grep may run before it is killed.")

(defconst harness-tools-fs--binary-probe-bytes 8000
  "How many leading bytes are inspected to decide whether a file is binary.")

(defconst harness-tools-fs--line-count-limit (* 20 1024 1024)
  "Byte size above which file_info stops counting lines.")

(defcustom harness-tools-fs-image-max-bytes 3932160
  "Largest image file, in bytes, that read_file shows a model as it is.
A larger one is made smaller first, by `harness-tools-fs-ffmpeg'.  The
default, 3.75 MiB, is the most Bedrock takes of an image; as base64 it
is 5 MiB, the most Anthropic takes."
  :type 'integer :group 'harness)

(defcustom harness-tools-fs-image-max-side 2000
  "Most pixels on a side of an image that read_file shows a model as it is.
A larger one is fitted into a square of this many pixels first, by
`harness-tools-fs-ffmpeg'.  Anthropic rejects an image of more than 2000
pixels on a side in a request with more than 20 images, and any of
more than 8000 (`harness-tools-fs--image-hard-max-side')."
  :type 'integer :group 'harness)

(defcustom harness-tools-fs-ffmpeg "ffmpeg"
  "Program that read_file runs to make an image fit for a model to see.
It fits an image over `harness-tools-fs-image-max-side' pixels on a
side or `harness-tools-fs-image-max-bytes' bytes into those limits,
and converts one of a type models do not read (BMP, TIFF ...) to PNG,
keeping the first frame of either.  Nil never runs it: an image is then
shown to a model only when it is within the byte limit and 8000 pixels
on a side, and the model is told so when it is not."
  :type '(choice (const :tag "Never" nil) (string :tag "Program"))
  :group 'harness)

(defconst harness-tools-fs--image-hard-max-side 8000
  "Most pixels on a side of an image read_file shows a model, at any rate.
Providers reject an image larger than this.  One over
`harness-tools-fs-image-max-side' is shown as it is, up to this size,
only when ffmpeg cannot make it smaller.")

(defconst harness-tools-fs--ffmpeg-timeout 60
  "Seconds ffmpeg may take to make one copy of an image before it is killed.")

;;;; Helpers

(defun harness-tools-fs--path (input ctx &optional key)
  "Return the absolute path for KEY (default :path) of INPUT under CTX."
  (let ((p (plist-get input (or key :path))))
    (when (or (null p) (not (stringp p)) (string-empty-p p))
      (error "Missing %s" (substring (symbol-name (or key :path)) 1)))
    (harness-tools-resolve-path p ctx)))

(defun harness-tools-fs--display (path ctx)
  "Return PATH relative to CTX's cwd when inside it, for messages."
  (let ((cwd (plist-get ctx :cwd)))
    (if (and cwd (harness-path-within-p cwd path))
        (let ((rel (file-relative-name path cwd)))
          (if (string= rel ".") "." rel))
      (abbreviate-file-name path))))

(defun harness-tools-fs--int (input key default)
  "Return the integer for KEY in INPUT, or DEFAULT."
  (let ((v (plist-get input key)))
    (cond ((integerp v) v)
          ((numberp v) (truncate v))
          ((and (stringp v) (string-match-p "\\`-?[0-9]+\\'" v)) (string-to-number v))
          (t default))))

(defun harness-tools-fs--mime (path)
  "Return the MIME type guessed from PATH's extension, or nil."
  (let ((ext (file-name-extension path)))
    (and ext (mailcap-extension-to-mime (concat "." (downcase ext))))))

(defun harness-tools-fs--image-p (path)
  "Non-nil when PATH looks like a raster image by extension."
  (let ((mime (harness-tools-fs--mime path)))
    (and mime (string-prefix-p "image/" mime)
         (not (string= mime "image/svg+xml")))))

(defun harness-tools-fs--svg-p (path)
  "Non-nil when PATH is an SVG image by extension (a text file)."
  (equal (harness-tools-fs--mime path) "image/svg+xml"))

(defun harness-tools-fs--binary-p (path)
  "Non-nil when the first bytes of PATH contain a NUL character."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (condition-case nil
        (insert-file-contents-literally path nil 0 harness-tools-fs--binary-probe-bytes)
      (error nil))
    (goto-char (point-min))
    (and (search-forward "\0" nil t) t)))

(defun harness-tools-fs--video-p (path)
  "Non-nil when PATH is a video: a video type by extension, binary inside.
The content counts too, so a text file whose extension some MIME table
gives to video (TypeScript's .ts, an MPEG transport stream elsewhere)
stays a text file."
  (let ((mime (harness-tools-fs--mime path)))
    (and mime (string-prefix-p "video/" mime)
         (harness-tools-fs--binary-p path))))

(defun harness-tools-fs--attachment (path mime)
  "Return the attachment of PATH, of type MIME, that a UI shows."
  (list :path path :mime mime :size (harness-file-size path)
        :name (file-name-nondirectory path)))

(defun harness-tools-fs--insert-text (path)
  "Insert the contents of text file PATH into the current buffer."
  (let ((coding-system-for-read 'utf-8-auto))
    (insert-file-contents path)))

(defun harness-tools-fs--number-lines (lines start)
  "Return LINES prefixed with line numbers counting from START, like `cat -n'."
  (let ((n start))
    (mapconcat (lambda (l) (prog1 (format "%6d\t%s" n l) (cl-incf n)))
               lines "\n")))

(defun harness-tools-fs--write (path content)
  "Write CONTENT to PATH creating parents, then announce it.
The UI reverts unmodified buffers visiting PATH on `tools/file-written'."
  (let ((dir (file-name-directory path)))
    (when (and dir (not (file-directory-p dir)))
      (make-directory dir t)))
  (let ((coding-system-for-write 'utf-8-unix))
    (with-temp-buffer
      (insert content)
      (write-region (point-min) (point-max) path nil 'silent)))
  (harness-emit 'tools/file-written path))

;;;; Images

(defun harness-tools-fs--head (path n)
  "Return the first N bytes of PATH as a unibyte string, empty when unreadable."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (condition-case nil
        (insert-file-contents-literally path nil 0 n)
      (error nil))
    (buffer-string)))

(defun harness-tools-fs--image-size (path)
  "Return (WIDTH . HEIGHT), in pixels, of the image PATH, or nil when unknown.
It is read from the header of the file, without decoding it or running
anything, so it costs the same for any size and needs no display (see
`harness-image-pixel-size'): PNG, GIF, JPEG, WebP and BMP are known."
  (harness-image-pixel-size path))

(defun harness-tools-fs--image-kind (path)
  "Return the MIME type of the image PATH by its first bytes, or nil.
Only the types models read are known: image/png, image/jpeg, image/gif
and image/webp.  A file named for one type that holds another is the
type its bytes say, as a provider checks it and refuses an image whose
type is wrong; other bytes (a BMP, a TIFF, text) have none."
  (let ((head (harness-tools-fs--head path 12)))
    (cond ((string-prefix-p "\211PNG\r\n\032\n" head) "image/png")
          ((string-prefix-p "\377\330\377" head) "image/jpeg")
          ((or (string-prefix-p "GIF87a" head) (string-prefix-p "GIF89a" head)) "image/gif")
          ((and (>= (length head) 12) (string-prefix-p "RIFF" head)
                (equal (substring head 8 12) "WEBP"))
           "image/webp"))))

(defun harness-tools-fs--file-bytes (path)
  "Return the size in bytes of the file PATH names, following a symbolic link.
`file-attributes' gives a link's own size, the length of its target's
name, which would let a large image through as a small one."
  (harness-file-size (file-truename path)))

(defun harness-tools-fs--image-side ()
  "Return the most pixels on a side that an image is shown to a model as it is.
That is `harness-tools-fs-image-max-side', but no more than providers
take (`harness-tools-fs--image-hard-max-side')."
  (max 1 (min harness-tools-fs-image-max-side harness-tools-fs--image-hard-max-side)))

(defun harness-tools-fs--image-info (path)
  "Return what read_file needs to know of the image PATH, as a plist.
`:kind' is its MIME type by its bytes when models read that type, else
nil.  `:mime' is the type to name it by: `:kind', else the one its
extension gives.  `:bytes' is the size of the file and `:size' its
\(WIDTH . HEIGHT) in pixels, nil when unknown."
  (let ((kind (harness-tools-fs--image-kind path)))
    (list :kind kind
          :mime (or kind (harness-tools-fs--mime path))
          :bytes (harness-tools-fs--file-bytes path)
          :size (harness-tools-fs--image-size path))))

(defun harness-tools-fs--image-fits-p (info side)
  "Non-nil when the image INFO describes can be shown to a model as it is.
That is, it is of a type models read, no larger than
`harness-tools-fs-image-max-bytes', and, when its size is known, no more
than SIDE pixels on a side."
  (let ((bytes (plist-get info :bytes))
        (size (plist-get info :size)))
    (and (plist-get info :kind) bytes
         (<= bytes harness-tools-fs-image-max-bytes)
         (or (null size) (<= (max (car size) (cdr size)) side)))))

(defun harness-tools-fs--copy-dir ()
  "Return the directory the copies of images for models are kept in.
It is made when missing, under `harness-state-directory', where the
harness keeps what it makes (video thumbnails, saved outputs), or where
`harness-tools-fs--copy-root' says when the tool runs in the sandbox."
  (harness-ensure-directory
   (or harness-tools-fs--copy-root
       (expand-file-name "model-images/" (if (bound-and-true-p harness-state-directory)
                                             harness-state-directory
                                           temporary-file-directory)))))

(defun harness-tools-fs--copy-name (path side jpeg)
  "Return the file that holds the copy of the image PATH fitted into SIDE pixels.
A JPEG if JPEG, else a PNG.  The name is a hash of the true name of
PATH, its size and its time, and SIDE, so that a copy is made once for
each state of the file, and a file that changed gets a new one."
  (let* ((true (file-truename path))
         (attrs (file-attributes true))
         (key (format "%s|%s|%s|%d" true (file-attribute-size attrs)
                      (float-time (file-attribute-modification-time attrs)) side)))
    (expand-file-name (concat (sha1 (encode-coding-string key 'utf-8)) (if jpeg ".jpg" ".png"))
                      (harness-tools-fs--copy-dir))))

(defun harness-tools-fs--ffmpeg-command (program src dest side jpeg)
  "Return the command that makes the image DEST of SRC with ffmpeg PROGRAM.
DEST is the first frame of SRC fitted into SIDE pixels on a side and
never enlarged; a JPEG (quality 3) if JPEG, else a PNG."
  (append (list program "-nostdin" "-loglevel" "error" "-y" "-i" src "-frames:v" "1"
                "-vf" (format "scale='min(%d,iw)':'min(%d,ih)':force_original_aspect_ratio=decrease"
                              side side))
          (and jpeg (list "-q:v" "3"))
          (list dest)))

(defun harness-tools-fs--ffmpeg-failure (result)
  "Return why the ffmpeg run that came to RESULT made no image.
RESULT is what `harness-run-command' resolves to."
  (let* ((exit (plist-get result :exit))
         (line (car (split-string (or (plist-get result :stderr) "") "\n" t "[ \t\r]+"))))
    (cond ((eq exit 'timeout)
           (format "ffmpeg took more than %s seconds" harness-tools-fs--ffmpeg-timeout))
          (line
           ;; "[png @ 0x5570d1d4a880] Invalid PNG signature": the address is noise.
           (format "ffmpeg failed: %s"
                   (harness-truncate-end (replace-regexp-in-string " @ 0x[0-9a-f]+\\]" "]" line) 200)))
          ((eql exit 0) "ffmpeg wrote no image")
          (t (format "ffmpeg failed (exit %s)" exit)))))

(defun harness-tools-fs--ffmpeg (src dest side jpeg)
  "Make the image DEST of SRC with `harness-tools-fs-ffmpeg'; return a promise.
DEST is SRC fitted into SIDE pixels, a JPEG if JPEG (see
`harness-tools-fs--ffmpeg-command').  The promise resolves to (:path
DEST), or to (:error WHY) when nothing was made.  ffmpeg writes a file
of its own first, which is renamed once it is whole, so that no read
sees half an image.  It runs asynchronously, and is killed after
`harness-tools-fs--ffmpeg-timeout' seconds, so it never holds the
harness up."
  (let ((program (and harness-tools-fs-ffmpeg (executable-find harness-tools-fs-ffmpeg))))
    (cond
     ((null harness-tools-fs-ffmpeg)
      (harness-resolved (list :error "ffmpeg is turned off (harness-tools-fs-ffmpeg is nil)")))
     ((null program)
      (harness-resolved (list :error (format "%s is not installed" harness-tools-fs-ffmpeg))))
     (t
      (let ((part (concat (file-name-sans-extension dest) "-" (harness-short-id 6) ".part"
                          (file-name-extension dest t))))
        (harness-then
         (harness-run-command (harness-tools-fs--ffmpeg-command program src part side jpeg)
                              :cwd (file-name-directory dest)
                              :timeout harness-tools-fs--ffmpeg-timeout :name "harness-ffmpeg")
         (lambda (r)
           (cond ((and (eql (plist-get r :exit) 0) (> (or (harness-file-size part) 0) 0))
                  (rename-file part dest t)
                  (list :path dest))
                 (t (ignore-errors (delete-file part))
                    ;; A process killed for taking too long may leave
                    ;; what it was writing after this, as it dies.
                    (when (eq (plist-get r :exit) 'timeout)
                      (run-at-time 5 nil (lambda () (ignore-errors (delete-file part)))))
                    (list :error (harness-tools-fs--ffmpeg-failure r)))))
         (lambda (err)
           (ignore-errors (delete-file part))
           (list :error (format "ffmpeg could not run: %s" (harness-error-message err))))))))))

(defun harness-tools-fs--shrink-sides ()
  "Return the sides, in pixels, to try fitting a too large image into.
The first, the largest, is `harness-tools-fs-image-max-side' (see
`harness-tools-fs--image-side').  A copy that is still over
`harness-tools-fs-image-max-bytes' (a PNG of noise is) is made again
at 70 % of it, and at 50 %."
  (let ((side (harness-tools-fs--image-side)))
    (delete-dups (list side (max 1 (floor (* side 0.7))) (max 1 (floor (* side 0.5)))))))

(defun harness-tools-fs--shrink-step (path info sides)
  "Return a promise of a copy of the image PATH fitted into the first of SIDES.
INFO describes PATH.  A copy made before is used, and one that is over
`harness-tools-fs-image-max-bytes' is made again with the next of
SIDES, if any.  The promise resolves like `harness-tools-fs--shrink'."
  (let* ((jpeg (equal (plist-get info :kind) "image/jpeg"))
         (side (car sides))
         (dest (harness-tools-fs--copy-name path side jpeg)))
    (harness-then
     (if (> (or (harness-file-size dest) 0) 0)
         (harness-resolved (list :path dest))
       (harness-tools-fs--ffmpeg path dest side jpeg))
     (lambda (made)
       (let ((bytes (and (plist-get made :path) (harness-file-size dest))))
         (cond
          ((null bytes) made)
          ((<= bytes harness-tools-fs-image-max-bytes)
           (list :path dest :mime (if jpeg "image/jpeg" "image/png")
                 :size (harness-tools-fs--image-size dest)))
          ((cdr sides) (harness-tools-fs--shrink-step path info (cdr sides)))
          (t (list :error (format "its smallest copy, fitted into %d px, is still %s"
                                  side (harness-format-bytes bytes))))))))))

(defun harness-tools-fs--shrink (path info)
  "Return a promise of a copy of the image PATH that a model can be shown.
INFO describes PATH (`harness-tools-fs--image-info').  The promise
resolves to (:path COPY :mime MIME :size SIZE), the copy being no
larger than the limits (`harness-tools-fs-image-max-bytes',
`harness-tools-fs-image-max-side'), or to (:error WHY) when none could
be made: the file is on another host, ffmpeg is off or missing or
failed."
  (if (file-remote-p path)
      (harness-resolved (list :error "it is on another host, where read_file cannot run ffmpeg"))
    (harness-tools-fs--shrink-step path info (harness-tools-fs--shrink-sides))))

(defun harness-tools-fs--limit-text (bytes)
  "Return the limit BYTES as a short size: 3932160 is \"3.75 MiB\"."
  (if (< bytes 1048576)
      (harness-format-bytes bytes)
    (format "%s MiB" (string-trim-right
                      (string-trim-right (format "%.2f" (/ bytes 1048576.0)) "0+")
                      "\\."))))

(defun harness-tools-fs--image-name (shown info)
  "Return how the text names the image that INFO describes and SHOWN names.
Its type, its size in bytes and, when known, in pixels."
  (let ((size (plist-get info :size)))
    (format "Image %s (%s, %s%s)" shown (plist-get info :mime)
            (harness-format-bytes (plist-get info :bytes))
            (if size (format ", %dx%d px" (car size) (cdr size)) ""))))

(defun harness-tools-fs--image-reply (text attachment image)
  "Return the RESULT of read_file saying TEXT about an image.
ATTACHMENT is what the user is shown, IMAGE, if any, what the model is:
\(:path PATH :mime MIME)."
  (apply #'harness-tool-ok text :attachments (list attachment)
         (and image (list :images (list image)))))

(defun harness-tools-fs--image-result (shown path attachment info copy)
  "Return the RESULT of read_file on the image PATH once ffmpeg had its say.
SHOWN names PATH, ATTACHMENT is what the user is shown and INFO describes
PATH.  COPY is what `harness-tools-fs--shrink' came to.  The text says
what the model gets: the copy, else PATH itself when providers take it,
else nothing; and never that it sees an image it does not."
  (let ((name (harness-tools-fs--image-name shown info)))
    (cond
     ((plist-get copy :path)
      (let* ((size (plist-get info :size))
             (new (plist-get copy :size))
             (changes (delq nil (list (and (not (plist-get info :kind)) "converted to PNG")
                                      (and size new (not (equal size new))
                                           (format "downscaled to %dx%d px" (car new) (cdr new)))))))
        (harness-tools-fs--image-reply
         (format "%s, %s to show you." name (if changes (string-join changes " and ") "recompressed"))
         attachment (list :path (plist-get copy :path) :mime (plist-get copy :mime)))))
     ((harness-tools-fs--image-fits-p info harness-tools-fs--image-hard-max-side)
      (harness-tools-fs--image-reply (concat name ".") attachment
                                     (list :path path :mime (plist-get info :mime))))
     (t
      (let ((why (string-remove-suffix "." (or (plist-get copy :error) "no copy was made"))))
        (harness-tools-fs--image-reply
         (if (plist-get info :kind)
             (format "%s is shown to the user, but it is too large to show you (at most %s and %d px a side) and could not be made smaller: %s. Make a smaller copy with bash (ffmpeg -i IN -vf \"scale=%d:%d:force_original_aspect_ratio=decrease\" OUT.png) and read that."
                     name (harness-tools-fs--limit-text harness-tools-fs-image-max-bytes)
                     harness-tools-fs--image-hard-max-side why
                     (harness-tools-fs--image-side) (harness-tools-fs--image-side))
           (format "%s is shown to the user, but you can read only PNG, JPEG, GIF and WebP images, and it could not be converted: %s. Convert it with bash (ffmpeg -i IN OUT.png) and read that."
                   name why))
         attachment nil))))))

(defun harness-tools-fs--read-image (path shown)
  "Return the RESULT of read_file on the raster image PATH, which SHOWN names.
The user is shown the image as it is (`:attachments'); the model is
given `:images' (see the commentary at the top): the image itself when
it is within the limits, else the copy ffmpeg makes of it, else the
image itself when providers still take it, else none.  Making a copy
takes ffmpeg a moment, so then a promise of the result is returned."
  (let ((attachment (harness-tools-fs--attachment path (harness-tools-fs--mime path)))
        (info (harness-tools-fs--image-info path)))
    (if (harness-tools-fs--image-fits-p info (harness-tools-fs--image-side))
        (harness-tools-fs--image-reply (concat (harness-tools-fs--image-name shown info) ".")
                                       attachment (list :path path :mime (plist-get info :mime)))
      (harness-then (harness-tools-fs--shrink path info)
                    (lambda (copy)
                      (harness-tools-fs--image-result shown path attachment info copy))))))

;;;; Running in the sandbox
;;
;; Each tool below is registered with a broker (`harness-tools-fs--broker')
;; for its handler, which decides where a call runs.  The handlers are
;; the same wherever: the worker (lisp/harness-mcp-fs.el) loads this file
;; and calls them by name (`harness-tools-fs--handlers').
;;
;; What the worker is shown is the session's profile, the mounts a bash
;; command of it gets (`harness-tools-shell-sandbox-profile'), and the
;; harness's own Lisp and compiled files, read-only, to start from.  The
;; mounts are fixed when it starts, so a directory granted to the session
;; starts a new worker, once the one running is idle (the MCP host does
;; that).  A call that has to reach further than the session's profile,
;; on purpose, is given a worker of its own with exactly those mounts
;; added, found by a key that says which (`harness-mcp-call-tool'):
;;
;; - a read of the harness itself, of a skills directory or of a file the
;;   user's Emacs showed a definition in, which the permission jail lets
;;   every call that only reads make (`permission/exempt-reads'): the
;;   path, read-only;
;; - a directory the user allowed for this call alone (`permission/once-grants'):
;;   the directory, as the call's kind says;
;; - a call the user approved by hand after it was denied (the context's
;;   `:approved'): the paths it names, as its kind says.
;;
;; The extra mounts come from those, each decided by the permission
;; module's own predicates, never from "whatever the call named": a
;; path the jail passed by mistake gets no mount, and the kernel then
;; says it is not there.

(defcustom harness-tools-fs-jail t
  "Whether the file tools run in the session's sandbox where one applies.
On, a call on a local path goes to a worker the harness starts in the
sandbox, the one a bash command of the session runs in, so the kernel,
not a comparison of paths, keeps the call inside the session's
directories.  Off, they run in the harness process as they used to,
behind the permission jail alone.  Where no sandbox applies -- the
sandbox policy is `off', or `preferred' and no backend exists -- they run
there either way, as bash runs unconfined then; with the policy
`required' and no backend a call is refused.  Calls on another host
\(TRAMP) always run here."
  :type 'boolean :group 'harness)

(defconst harness-tools-fs-options-key :harness/fs
  "Where in the `_meta' of a call the options for the worker go.")

(defconst harness-tools-fs--handlers
  '(("read_file" . harness-tools-fs--read-file)
    ("write_file" . harness-tools-fs--write-file)
    ("edit_file" . harness-tools-fs--edit-file)
    ("list_dir" . harness-tools-fs--list-dir)
    ("glob" . harness-tools-fs--glob)
    ("grep" . harness-tools-fs--grep)
    ("file_info" . harness-tools-fs--file-info))
  "File tool name -> the function that does its work, called with (INPUT CTX).")

(defconst harness-tools-fs--writing '("write_file" "edit_file")
  "The file tools that change files: extra mounts they need are writable.")

(defun harness-tools-fs--sandbox-applies-p (cwd)
  "Non-nil when a process for a session working in CWD is confined, or must be.
That is the case when the sandbox confines a command there
\(`sandbox/confined-p'), and when the policy is `required', which a
process with no backend fails: it is never run unconfined."
  (or (and (harness-method-exists-p 'sandbox/confined-p)
           (condition-case nil (harness-call 'sandbox/confined-p cwd) (error nil))
           t)
      (and (fboundp 'harness-tools-shell--sandbox-required-p)
           (harness-tools-shell--sandbox-required-p cwd))))

(defun harness-tools-fs--elc-dir ()
  "Return the directory of the harness's compiled files, or nil.
The worker loads them from there, which is quick, and the sandbox shows
it read-only.  It holds the compiled Lisp of the harness and nothing else."
  (when (fboundp 'harness--compile-directory)
    (let ((dir (ignore-errors (harness--compile-directory))))
      (and (stringp dir) (file-directory-p dir) (file-name-as-directory dir)))))

(defun harness-tools-fs--worker-command (_ctx)
  "Return the program and arguments of the worker, an Emacs that serves the tools."
  (let* ((root (file-name-as-directory (expand-file-name harness-directory)))
         (elc (harness-tools-fs--elc-dir)))
    (append (list (if (boundp 'harness-elisp-emacs)
                      harness-elisp-emacs
                    (expand-file-name invocation-name invocation-directory))
                  "--batch" "-Q")
            (and elc (list "-L" (directory-file-name elc)))
            (list "-L" (expand-file-name "lisp" root)
                  "-L" (expand-file-name "lisp/modules" root)
                  "-l" (expand-file-name "lisp/harness-mcp-fs.el" root)
                  "-f" "harness-mcp-fs-main"))))

(defun harness-tools-fs--profile (ctx)
  "Return the sandbox profile of the worker that serves a call under CTX.
It is the session's (see `harness-tools-shell-sandbox-profile'), with
what the worker starts from shown read-only -- the harness's Lisp and
the Emacs it runs, and the harness's compiled files -- and the mounts
the call has to have besides: CTX's `:fs-extras', a list of (PATH .
MODE), MODE `ro' or `rw'."
  (let ((extras (plist-get ctx :fs-extras))
        (elc (harness-tools-fs--elc-dir)))
    ;; Where a tool's long output is saved, and the file tools read it back
    ;; from: made on the first long output, which can be after the worker
    ;; started, and the worker is shown only what exists when it does.
    (when (bound-and-true-p harness-state-directory)
      (ignore-errors
        (make-directory (expand-file-name "outputs" harness-state-directory) t)))
    (harness-tools-shell-sandbox-profile
     ctx (or (plist-get ctx :cwd) default-directory)
     :readable (append (harness-tools-shell-child-dirs)
                       (and elc (list elc))
                       (cl-loop for (path . mode) in extras when (eq mode 'ro) collect path))
     :writable (cl-loop for (path . mode) in extras when (eq mode 'rw) collect path))))

(defun harness-tools-fs--shown-p (path profile)
  "Non-nil when PATH lies in a directory, or is a file, that PROFILE shows."
  (cl-some (lambda (dir) (and (stringp dir) (harness-path-within-p dir path)))
           (append (plist-get profile :writable) (plist-get profile :readable))))

(defun harness-tools-fs--grant-dir (grant)
  "Return the directory a one-time GRANT names, or nil when it names none.
A grant is a directory or a pattern `DIR/**'; a pattern with anything
else in it cannot be mounted."
  (let ((dir (replace-regexp-in-string "/\\*\\*\\'" "/" grant)))
    (and (stringp dir)
         (not (string-match-p "[*?[]" dir))
         (not (file-remote-p dir))
         (file-directory-p dir)
         (file-name-as-directory dir))))

(defun harness-tools-fs--extra-mount (path write)
  "Return the (MOUNT . MODE) that shows PATH to a call, or nil.
An existing file or directory is shown itself, read-only, or writable
when WRITE; a file a writing call would make, by the directory it
would be made in."
  (let ((target (cond ((file-exists-p path) path)
                      ((and write (file-directory-p (file-name-directory path)))
                       (file-name-directory path)))))
    (and target (cons target (if write 'rw 'ro)))))

(defun harness-tools-fs--once-grants (ctx)
  "Return the directories the user allowed the call of CTX alone to reach."
  (let ((id (plist-get ctx :call-id)))
    (and (stringp id) (harness-method-exists-p 'permission/once-grants)
         (delq nil (mapcar #'harness-tools-fs--grant-dir
                           (harness-call 'permission/once-grants id))))))

(defun harness-tools-fs--exempt-reads (name paths ctx)
  "Return those of PATHS that a call of NAME under CTX may read outside the roots.
They are the harness's own files, skills and the files the user's Emacs
showed a definition in (`permission/exempt-reads')."
  (let ((sid (plist-get ctx :session-id)))
    (and sid paths (harness-method-exists-p 'permission/exempt-reads)
         (harness-call 'permission/exempt-reads sid name paths))))

(defun harness-tools-fs--extras (name paths ctx)
  "Return the (MOUNT . MODE) pairs the call of NAME on PATHS under CTX needs.
Those are the mounts that the permission module's own reasons for
letting a call reach outside the session's profile call for (see the
comment above `harness-tools-fs-jail'), sorted, so that equal needs
give equal keys."
  (let* ((write (and (member name harness-tools-fs--writing) t))
         (profile (harness-tools-fs--profile ctx))
         (outside (cl-remove-if (lambda (p) (harness-tools-fs--shown-p p profile)) paths)))
    (when outside
      (let ((once (harness-tools-fs--once-grants ctx))
            (exempt (and (not write) (harness-tools-fs--exempt-reads name outside ctx)))
            extras)
        (dolist (path outside)
          (let* ((grant (cl-find-if (lambda (dir) (harness-path-within-p dir path)) once))
                 (mount (cond ((plist-get ctx :approved) (harness-tools-fs--extra-mount path write))
                              (grant (cons grant (if write 'rw 'ro)))
                              ((member path exempt) (harness-tools-fs--extra-mount path nil)))))
            (when mount (cl-pushnew mount extras :test #'equal))))
        (sort extras (lambda (a b) (string< (car a) (car b))))))))

(defun harness-tools-fs--jail-plan (name input ctx)
  "Say where the call of the file tool NAME with INPUT under CTX runs.
Return nil to run it here, `(:extras MOUNTS)' to run it in the sandbox
with those mounts besides the session's (nil for none), or `(:error
MESSAGE)' for a call whose paths cannot be told, which is refused."
  (let ((cwd (plist-get ctx :cwd)))
    (when (and harness-tools-fs-jail
               (fboundp 'harness-mcp-server-declared-p)
               (harness-mcp-server-declared-p 'fs)
               (not (plist-get ctx :host))
               (stringp cwd) (not (file-remote-p cwd))
               (harness-tools-fs--sandbox-applies-p cwd))
      (condition-case err
          (let ((paths (harness-tools--call-paths (harness-tool-get name) input ctx)))
            ;; A path on another host is that host's to confine.
            (unless (cl-some #'harness-file-remote-p paths)
              (list :extras (harness-tools-fs--extras name paths ctx))))
        (error (list :error (format "Which files this call touches could not be worked out (%s), so it cannot run in the sandbox"
                                    (harness-error-message err))))))))

(defun harness-tools-fs--forwarded-options (ctx)
  "Return the options of the harness's own that the worker's tools read, for CTX.
A copy of an image is made in the session's own temporary directory,
which the harness can read: the worker's /tmp is its own.  The writable
mounts go too (`:writable')."
  (let ((tmp (harness-tools-shell--tmp-dir ctx)))
    (list :maxOutputChars harness-tools-max-output-chars
          :imageMaxBytes harness-tools-fs-image-max-bytes
          :imageMaxSide harness-tools-fs-image-max-side
          :ffmpeg (or harness-tools-fs-ffmpeg :false)
          :copyRoot (if tmp (expand-file-name "model-images/" tmp) :false)
          ;; Where the worker can really write, so that it can say no to a
          ;; write anywhere else: the sandbox's /tmp and home are its own,
          ;; and a file written there is gone, but for the worker's own
          ;; eyes, once it stops.
          :writable (cons (or (plist-get ctx :cwd) default-directory)
                          (plist-get (harness-tools-fs--profile ctx) :writable)))))

(defun harness-tools-fs--run-jailed (name input ctx extras)
  "Run the file tool NAME with INPUT under CTX in the sandbox; return a promise.
EXTRAS are the mounts beyond the session's.  They give the call a worker
of its own, found by a key made from them, so that the session's own
worker is not restarted for a call that is not the usual one."
  (let* ((ctx (plist-put (copy-sequence ctx) :fs-extras extras))
         (key (and extras (cons (plist-get ctx :session-id)
                                (secure-hash 'sha1 (prin1-to-string extras))))))
    (harness-mcp-call-tool
     'fs name input ctx 600
     (list harness-tools-fs-options-key (harness-tools-fs--forwarded-options ctx))
     key)))

(defun harness-tools-fs--broker (name)
  "Return the handler of the file tool NAME.
It runs the call in the sandbox where one applies, and here otherwise
\(see `harness-tools-fs--jail-plan')."
  (lambda (input ctx)
    (let ((plan (harness-tools-fs--jail-plan name input ctx))
          (handler (cdr (assoc name harness-tools-fs--handlers))))
      (cond ((null plan) (funcall handler input ctx))
            ((plist-get plan :error) (harness-tool-error (plist-get plan :error)))
            (t (harness-tools-fs--run-jailed name input ctx (plist-get plan :extras)))))))

;;;; read_file

(defun harness-tools-fs--read-range (path offset limit)
  "Return (TEXT FIRST LAST TOTAL) for PATH from line OFFSET, at most LIMIT lines.
TEXT is numbered and already trimmed to the output budget."
  (with-temp-buffer
    (harness-tools-fs--insert-text path)
    (let* ((total (count-lines (point-min) (point-max)))
           (first (max 1 offset))
           (last (if limit (min total (+ first limit -1)) total))
           (budget (max 200 (- harness-tools-max-output-chars 200)))
           (lines nil) (chars 0) (n first))
      (goto-char (point-min))
      (forward-line (1- first))
      (while (and (<= n last) (not (eobp)))
        (let ((line (buffer-substring-no-properties (line-beginning-position) (line-end-position))))
          (cl-incf chars (+ 8 (length line)))
          (if (and lines (> chars budget))
              (setq n (1+ last))       ; stop: over budget
            (push line lines)
            (cl-incf n)
            (forward-line 1))))
      (let ((shown-last (+ first (length lines) -1)))
        (list (harness-tools-fs--number-lines (nreverse lines) first)
              first shown-last last total)))))

(defun harness-tools-fs--read-file (input ctx)
  "Handler for read_file with INPUT under CTX."
  (let* ((path (harness-tools-fs--path input ctx))
         (shown (harness-tools-fs--display path ctx))
         (offset (harness-tools-fs--int input :offset 1))
         (limit (harness-tools-fs--int input :limit nil)))
    (cond
     ((file-directory-p path)
      (harness-tool-error (format "%s is a directory; use list_dir to see its contents" shown)))
     ((not (file-exists-p path))
      (harness-tool-error (format "File not found: %s (cwd %s). Check the path with list_dir or glob"
                                  shown (plist-get ctx :cwd))))
     ((not (file-readable-p path))
      (harness-tool-error (format "File not readable: %s" shown)))
     ;; The user is shown the image; the model gets it too when its
     ;; model reads images (`:images').
     ((harness-tools-fs--image-p path)
      (harness-tools-fs--read-image path shown))
     ;; The chat shows a video to the user, who can play it; the model
     ;; gets what it is and how to look inside.
     ((harness-tools-fs--video-p path)
      (let ((mime (harness-tools-fs--mime path)))
        (harness-tool-ok (format "Video %s (%s, %s) is shown to the user in the chat, who can play it there; read_file cannot show you its frames. To inspect it, use bash: ffprobe for its streams and duration, ffmpeg to extract frames."
                                 shown mime (harness-format-bytes (harness-file-size path)))
                         :attachments (list (harness-tools-fs--attachment path mime)))))
     ((harness-tools-fs--binary-p path)
      (harness-tool-error (format "%s is a binary file (%s); read_file only shows text. Use file_info for metadata or bash with `file`, `xxd` or `strings` to inspect it"
                                  shown (harness-format-bytes (harness-file-size path)))))
     ((and limit (< limit 1))
      (harness-tool-error "The limit must be at least 1"))
     (t
      (pcase-let* ((`(,text ,first ,shown-last ,wanted-last ,total)
                    (harness-tools-fs--read-range path offset limit))
                   ;; An SVG is text to the model and a picture to the
                   ;; user: a read from its top shows the user the image.
                   (shows (and (= first 1) (harness-tools-fs--svg-p path)
                               (list :attachments (list (harness-tools-fs--attachment path "image/svg+xml"))))))
        (cond
         ((and (zerop total) (= first 1))
          (harness-tool-ok (format "%s is empty (0 lines)" shown)))
         ((> first total)
          (harness-tool-error (format "offset %d is past the end of %s (%d lines)" first shown total)))
         ((< shown-last wanted-last)
          (apply #'harness-tool-ok
                 (format "%s\n\n[%s: showing lines %d-%d of %d; the requested range was too large for one read. Continue with offset %d, or use a smaller limit.]"
                         text shown first shown-last total (1+ shown-last))
                 :truncated (list :path path :lines (cons first shown-last) :total total)
                 shows))
         (t
          (apply #'harness-tool-ok
                 (if (and (= first 1) (= shown-last total))
                     text
                   (format "%s\n\n[%s: lines %d-%d of %d]" text shown first shown-last total))
                 shows))))))))

(defun harness-tools-fs--read-subject (input)
  "What a read_file call with INPUT reads: the path and the lines asked for."
  (when-let* ((path (plist-get input :path)))
    (let ((offset (harness-tools-fs--int input :offset nil))
          (limit (harness-tools-fs--int input :limit nil)))
      (format "%s%s" path
              (cond ((and offset limit) (format ":%d-%d" offset (+ offset limit -1)))
                    (offset (format ":%d-" offset))
                    (limit (format ":1-%d" limit))
                    (t ""))))))

(harness-define-tool "read_file"
  :label "Read file"
  :description "Read a text file. Output lines are prefixed with their line number. Use offset (1-based line) and limit (number of lines) to read a range of a large file; a read that would be too big is trimmed and tells you where to continue. An image (PNG, JPEG, GIF, WebP; other types and oversized images are converted when ffmpeg is installed) comes back as an image you see, when your model reads images, and is shown to the user; a video is shown to the user, who can play it; other binary files are refused."
  :schema '(:type "object"
            :properties (:path (:type "string" :description "File path, absolute or relative to the working directory")
                         :offset (:type "integer" :description "First line to read (1-based). Default 1")
                         :limit (:type "integer" :description "Maximum number of lines to read. Default: the whole file, within the output budget"))
            :required ("path"))
  :kind 'read
  :coalescable t
  :paths (lambda (input) (list (plist-get input :path)))
  :subject #'harness-tools-fs--read-subject
  :handler (harness-tools-fs--broker "read_file"))

;;;; write_file

(defun harness-tools-fs--write-file (input ctx)
  "Handler for write_file with INPUT under CTX."
  (let* ((path (harness-tools-fs--path input ctx))
         (content (plist-get input :content))
         (shown (harness-tools-fs--display path ctx)))
    (unless (stringp content) (error "Missing content"))
    (when (file-directory-p path)
      (error "%s is a directory" shown))
    (let ((existed (file-exists-p path)))
      (harness-tools-fs--write path content)
      (harness-tool-ok (format "%s %s (%d bytes, %d lines)"
                               (if existed "Overwrote" "Created") shown
                               (string-bytes content)
                               (if (string-empty-p content) 0
                                 (1+ (cl-count ?\n (string-remove-suffix "\n" content)))))
                       :meta (list :bytes (string-bytes content) :created (not existed))))))

(harness-define-tool "write_file"
  :label "Write file"
  :description "Write a whole file, creating it and any missing parent directories. Overwrites existing content; prefer edit_file for small changes to an existing file."
  :schema '(:type "object"
            :properties (:path (:type "string" :description "File path, absolute or relative to the working directory")
                         :content (:type "string" :description "The complete new contents of the file"))
            :required ("path" "content"))
  :kind 'write
  :paths (lambda (input) (list (plist-get input :path)))
  :subject (lambda (input) (when-let* ((path (plist-get input :path)))
                             (format "%s (%d bytes)" path (string-bytes (or (plist-get input :content) "")))))
  :handler (harness-tools-fs--broker "write_file"))

;;;; edit_file

(defun harness-tools-fs--count-occurrences (needle)
  "Count literal occurrences of NEEDLE in the current buffer.
Return (COUNT . FIRST-POS)."
  (let ((count 0) (first nil) (case-fold-search nil))
    (save-excursion
      (goto-char (point-min))
      (while (search-forward needle nil t)
        (cl-incf count)
        (unless first (setq first (match-beginning 0)))))
    (cons count first)))

(defun harness-tools-fs--whitespace-fuzzy-p (needle)
  "Non-nil when NEEDLE matches the buffer once whitespace is normalised.
Used only to give a better error message."
  (let ((rx (mapconcat #'regexp-quote (split-string needle "[ \t\n]+" t) "[ \t\n]+"))
        (case-fold-search nil))
    (and (not (string-empty-p rx))
         (save-excursion (goto-char (point-min)) (re-search-forward rx nil t)))))

(defun harness-tools-fs--edit-file (input ctx)
  "Handler for edit_file with INPUT under CTX."
  (let* ((path (harness-tools-fs--path input ctx))
         (shown (harness-tools-fs--display path ctx))
         (old (plist-get input :old_string))
         (new (plist-get input :new_string))
         (all (harness-json-true-p (plist-get input :replace_all))))
    (cond
     ((not (stringp old)) (harness-tool-error "Missing old_string"))
     ((not (stringp new)) (harness-tool-error "Missing new_string"))
     ((string-empty-p old) (harness-tool-error "An empty old_string is not allowed; use write_file to create or replace a whole file"))
     ((string= old new) (harness-tool-error "Identical old_string and new_string; nothing to do"))
     ((file-directory-p path) (harness-tool-error (format "%s is a directory" shown)))
     ((not (file-exists-p path))
      (harness-tool-error (format "File not found: %s. Use write_file to create a new file" shown)))
     (t
      (with-temp-buffer
        (harness-tools-fs--insert-text path)
        (pcase-let ((`(,count . ,first) (harness-tools-fs--count-occurrences old)))
          (cond
           ((zerop count)
            (harness-tool-error
             (if (harness-tools-fs--whitespace-fuzzy-p old)
                 (format "old_string not found in %s exactly, but a match exists with different whitespace or indentation. Read the file and copy the text verbatim, including leading spaces and tabs" shown)
               (format "old_string not found in %s. Read the file (read_file) and copy the exact current text; it may have changed since you last saw it" shown))))
           ((and (> count 1) (not all))
            (harness-tool-error
             (format "old_string matches %d places in %s. Include more surrounding context so it is unique, or set replace_all to true to change every occurrence" count shown)))
           (t
            (let ((line (line-number-at-pos first)))
              (goto-char (point-min))
              (let ((case-fold-search nil))
                (while (search-forward old nil t)
                  (replace-match new t t)))
              (harness-tools-fs--write path (buffer-string))
              (harness-tool-ok
               (format "Edited %s: replaced %d occurrence%s%s"
                       shown count (if (= count 1) "" "s")
                       (if (= count 1) (format " at line %d" line) ""))
               :meta (list :replacements count :line line)))))))))))

(harness-define-tool "edit_file"
  :label "Edit file"
  :description "Replace an exact string in a file. old_string must match the current file text exactly (including whitespace) and, unless replace_all is true, must occur exactly once; include enough surrounding lines to make it unique."
  :schema '(:type "object"
            :properties (:path (:type "string" :description "File path, absolute or relative to the working directory")
                         :old_string (:type "string" :description "The exact text to replace")
                         :new_string (:type "string" :description "The replacement text")
                         :replace_all (:type "boolean" :description "Replace every occurrence instead of requiring a unique match. Default false"))
            :required ("path" "old_string" "new_string"))
  :kind 'write
  :paths (lambda (input) (list (plist-get input :path)))
  :subject (lambda (input) (plist-get input :path))
  :handler (harness-tools-fs--broker "edit_file"))

;;;; list_dir

(defun harness-tools-fs--list-entries (dir depth prefix acc limit)
  "Collect entries of DIR down to DEPTH levels into ACC (a cons cell holder).
PREFIX is the relative path shown for entries; LIMIT caps the total."
  (let ((entries (condition-case nil
                     ;; Names and attributes in one call: one round trip
                     ;; for a directory on a remote host, not two an entry.
                     (directory-files-and-attributes dir t directory-files-no-dot-files-regexp t)
                   (error nil))))
    (dolist (entry (sort entries (lambda (a b) (string< (car a) (car b)))))
      (let* ((full (car entry))
             (name (file-name-nondirectory full)))
        (unless (string= name ".git")
          (when (< (length (car acc)) limit)
            (let* ((attrs (cdr entry))
                   (type (and attrs (file-attribute-type attrs)))
                   (dirp (eq t type))
                   (link (and (stringp type) type)))
              (push (list :name (concat prefix name (if (or dirp (and link (file-directory-p full))) "/" ""))
                          :size (and (not dirp) attrs (file-attribute-size attrs))
                          :link link)
                    (car acc))
              (when (and dirp (> depth 1))
                (harness-tools-fs--list-entries full (1- depth) (concat prefix name "/") acc limit)))))))))

(defun harness-tools-fs--list-dir (input ctx)
  "Handler for list_dir with INPUT under CTX."
  (let* ((path (harness-tools-resolve-path (or (plist-get input :path) ".") ctx))
         (shown (harness-tools-fs--display path ctx))
         (depth (max 1 (harness-tools-fs--int input :depth 1))))
    (cond
     ((not (file-exists-p path)) (harness-tool-error (format "Directory not found: %s" shown)))
     ((not (file-directory-p path))
      (harness-tool-error (format "%s is a file, not a directory; use read_file or file_info" shown)))
     (t
      (let ((acc (list nil)))
        (harness-tools-fs--list-entries path depth "" acc harness-tools-fs--list-limit)
        (let* ((entries (nreverse (car acc)))
               (n (length entries))
               (lines (mapcar (lambda (e)
                                (let ((name (plist-get e :name)))
                                  (cond ((plist-get e :link) (format "%s -> %s" name (plist-get e :link)))
                                        ((plist-get e :size) (format "%s  %s" name (harness-format-bytes (plist-get e :size))))
                                        (t name))))
                              entries)))
          (harness-tool-ok
           (if (zerop n)
               (format "%s is empty" shown)
             (format "%s%s\n%s" (string-join lines "\n")
                     (if (>= n harness-tools-fs--list-limit)
                         (format "\n\n[Listing stopped at %d entries; narrow the path or lower depth]" n)
                       "")
                     (format "(%d entr%s in %s, depth %d)" n (if (= n 1) "y" "ies") shown depth))))))))))

(harness-define-tool "list_dir"
  :label "List directory"
  :description "List a directory: files with sizes, directories with a trailing slash, .git skipped. depth > 1 recurses."
  :schema '(:type "object"
            :properties (:path (:type "string" :description "Directory, absolute or relative to the working directory. Default: the working directory")
                         :depth (:type "integer" :description "How many levels to descend. Default 1")))
  :kind 'read
  :coalescable t
  :paths (lambda (input) (list (or (plist-get input :path) ".")))
  :subject (lambda (input) (or (plist-get input :path) "."))
  :handler (harness-tools-fs--broker "list_dir"))

;;;; glob

(defun harness-tools-fs--glob-regexp (pattern)
  "Translate glob PATTERN (with ** support) into an anchored regexp.
See `harness-glob-regexp', which the permission patterns share."
  (harness-glob-regexp pattern))

(defun harness-tools-fs--not-git-p (dir)
  "Non-nil unless DIR is a .git directory.
A predicate for `directory-files-recursively'."
  (not (string= (file-name-nondirectory (directory-file-name dir)) ".git")))

(defun harness-tools-fs--glob-pattern (pattern base)
  "Return PATTERN as a pattern to match below directory BASE, or nil.
The permission jail judges the `path' a glob call names, which is BASE;
the pattern is matched below it.  So a pattern is only one when it
stays there: an absolute pattern (a leading `/' or `~') is taken as the
relative one when it begins with BASE, and is refused otherwise, and so
is one with a `..' segment.  Otherwise the pattern would list names in a
directory the jail never saw.  Only the text of PATTERN is looked at;
a name that TRAMP could take for a host is not looked up."
  (let* ((local (file-local-name base))
         (rel (cond ((string-prefix-p base pattern) (substring pattern (length base)))
                    ((and (string-prefix-p "/" pattern) (not (equal local base))
                          (string-prefix-p local pattern))
                     (substring pattern (length local)))
                    (t pattern))))
    (unless (or (string-prefix-p "/" rel) (string-prefix-p "~" rel)
                (member ".." (split-string rel "/")))
      rel)))

(defun harness-tools-fs--below-p (base files)
  "Return those of FILES that lie below directory BASE, links resolved.
A file is below BASE when the directory that holds it, with the
symbolic links on its way resolved, is BASE or lies in it.  A link in
the tree that leads out of it is listed by its own name, and what lies
beyond it is not, so a pattern cannot walk through one to a directory
the jail did not judge."
  (let ((seen (make-hash-table :test 'equal)))
    (cl-remove-if-not
     (lambda (f)
       (let* ((dir (file-name-directory (directory-file-name f)))
              (known (gethash dir seen :unknown)))
         (if (eq known :unknown)
             (puthash dir (and (harness-path-within-p base dir) t) seen)
           known)))
     files)))

(defun harness-tools-fs--glob-matches (pattern base)
  "Return absolute paths under BASE matching glob PATTERN.
PATTERN is relative to BASE (see `harness-tools-fs--glob-pattern'), and
nothing is returned that lies behind a symbolic link out of BASE."
  (harness-tools-fs--below-p
   base
   (if (string-search "**" pattern)
       (let* ((rx (harness-tools-fs--glob-regexp pattern))
              (leaf (file-name-nondirectory pattern))
              (leaf-rx (if (or (string-empty-p leaf) (string-search "**" leaf))
                           "" (wildcard-to-regexp leaf)))
              (files (directory-files-recursively base leaf-rx nil #'harness-tools-fs--not-git-p)))
         (cl-remove-if-not (lambda (f) (string-match-p rx (file-relative-name f base))) files))
     (cl-remove-if (lambda (f) (string-match-p "\\(\\`\\|/\\)\\.git\\(/\\|\\'\\)" f))
                   (file-expand-wildcards (expand-file-name pattern base) t)))))

(defun harness-tools-fs--mtime (path)
  "Modification time of PATH as a float, or 0."
  (let ((attrs (file-attributes path)))
    (if attrs (float-time (file-attribute-modification-time attrs)) 0)))

(defun harness-tools-fs--glob (input ctx)
  "Handler for glob with INPUT under CTX."
  (let* ((pattern (plist-get input :pattern))
         (base (file-name-as-directory (harness-tools-resolve-path (or (plist-get input :path) ".") ctx)))
         (shown (harness-tools-fs--display base ctx)))
    (cond
     ((or (not (stringp pattern)) (string-empty-p pattern)) (harness-tool-error "Missing pattern"))
     ((not (file-directory-p base)) (harness-tool-error (format "Directory not found: %s" shown)))
     ((null (harness-tools-fs--glob-pattern pattern base))
      (harness-tool-error
       (format "The pattern %s does not stay inside %s. A pattern is matched below path: name the directory as path, and keep the pattern relative to it, with no `..' and no leading `/' or `~'"
               pattern shown)))
     (t
      (let* ((matches (harness-tools-fs--glob-matches
                       (harness-tools-fs--glob-pattern pattern base) base))
             (total (length matches))
             (sorted (sort matches (lambda (a b) (> (harness-tools-fs--mtime a) (harness-tools-fs--mtime b)))))
             (kept (seq-take sorted harness-tools-fs--glob-limit))
             (rel (mapcar (lambda (f) (concat (file-relative-name f base) (if (file-directory-p f) "/" ""))) kept)))
        (harness-tool-ok
         (if (zerop total)
             (format "No files match %s in %s" pattern shown)
           (format "%s\n(%d match%s%s, newest first)" (string-join rel "\n") total
                   (if (= total 1) "" "es")
                   (if (> total harness-tools-fs--glob-limit)
                       (format ", showing %d" harness-tools-fs--glob-limit) "")))))))))

(harness-define-tool "glob"
  :label "Find files"
  :description "Find files by name pattern (e.g. \"*.el\", \"src/**/*.ts\"). Results are relative to path, newest first, capped at 500."
  :schema '(:type "object"
            :properties (:pattern (:type "string" :description "Glob pattern; ** matches across directories")
                         :path (:type "string" :description "Directory to search from. Default: the working directory"))
            :required ("pattern"))
  :kind 'read
  :coalescable t
  :paths (lambda (input) (list (or (plist-get input :path) ".")))
  :subject (lambda (input) (format "%s%s" (or (plist-get input :pattern) "")
                                   (if (plist-get input :path) (format " in %s" (plist-get input :path)) "")))
  :handler (harness-tools-fs--broker "glob"))

;;;; grep

(defun harness-tools-fs--grep-command (pattern target glob case-sensitive cwd)
  "Return (PROGRAM . ARGS) for searching PATTERN in TARGET.
GLOB filters file names; CASE-SENSITIVE nil searches case-insensitively.
TARGET is a path local to the host CWD lives on."
  (let ((default-directory cwd))
    (if (executable-find "rg" t)
        (append (list "rg" "--no-heading" "--with-filename" "--line-number" "--no-messages"
                      "--color" "never" "--max-columns" "500" "--max-columns-preview"
                      (if case-sensitive "--case-sensitive" "--ignore-case"))
                (when glob (list "--glob" glob))
                (list "-e" pattern "--" target))
      (append (list "grep" "-rn" "-I" "-H" "-E")
              (unless case-sensitive (list "-i"))
              (when glob (list (concat "--include=" glob)))
              (list "--exclude-dir=.git" "-e" pattern "--" target)))))

(defun harness-tools-fs--grep-format (stdout cwd max-results &optional host)
  "Format grep STDOUT lines relative to CWD, keeping at most MAX-RESULTS.
HOST, the TRAMP prefix of their host (\"\" for this machine), says the
files are on another host than the session's: then every file name is
written in full, with HOST before it, as the other tools take it."
  (let* ((lines (split-string stdout "\n" t))
         (total (length lines))
         (kept (seq-take lines max-results))
         (local-cwd (file-name-as-directory (file-local-name cwd)))
         (out (mapcar (lambda (l)
                        (if (string-match "\\`\\(.*?\\):\\([0-9]+\\):\\(.*\\)\\'" l)
                            (let ((file (match-string 1 l)))
                              (format "%s:%s: %s"
                                      (cond
                                       (host (concat host (if (string-prefix-p "/" file)
                                                              file
                                                            (concat local-cwd (string-remove-prefix "./" file)))))
                                       ((string-prefix-p local-cwd file)
                                        (substring file (length local-cwd)))
                                       (t (string-remove-prefix "./" file)))
                                      (match-string 2 l) (match-string 3 l)))
                          l))
                      kept)))
    (cons (string-join out "\n") total)))

(defun harness-tools-fs--grep (input ctx)
  "Handler for grep with INPUT under CTX; returns a promise.
The search runs on the host PATH is on: in the session's cwd when that
is the same host, else in the directory holding PATH, and then the
hits are named in full, TRAMP prefix and all."
  (let* ((pattern (plist-get input :pattern))
         (session-cwd (file-name-as-directory (or (plist-get ctx :cwd) default-directory)))
         (path (harness-tools-resolve-path (or (plist-get input :path) ".") ctx))
         (elsewhere (not (equal (file-remote-p path) (file-remote-p session-cwd))))
         (cwd (if elsewhere (file-name-directory (directory-file-name path)) session-cwd))
         (shown (harness-tools-fs--display path ctx))
         (glob (plist-get input :glob))
         (case-sensitive (harness-json-true-p (plist-get input :case_sensitive)))
         (max-results (max 1 (harness-tools-fs--int input :max_results 200))))
    (cond
     ((or (not (stringp pattern)) (string-empty-p pattern)) (harness-tool-error "Missing pattern"))
     ((not (file-exists-p path)) (harness-tool-error (format "Path not found: %s" shown)))
     (t
      (let* ((target (file-local-name path))
             (cmd (harness-tools-fs--grep-command pattern target (and (stringp glob) (not (string-empty-p glob)) glob)
                                                  case-sensitive cwd)))
        (harness-then
         (harness-run-command cmd :cwd cwd :timeout harness-tools-fs--grep-timeout :name "harness-grep"
                              :merge-remote-stderr t)
         (lambda (r)
           (let ((exit (plist-get r :exit)))
             (cond
              ((eq exit 'timeout)
               (harness-tool-error (format "grep timed out after %ss; narrow the pattern or path" harness-tools-fs--grep-timeout)))
              ((and (integerp exit) (> exit 1))
               ;; On another host what it said is in the output.
               (harness-tool-error (format "%s failed (exit %d): %s" (car cmd) exit
                                           (string-trim (if (string-blank-p (plist-get r :stderr))
                                                            (truncate-string-to-width (plist-get r :stdout) 2000 nil nil "…")
                                                          (plist-get r :stderr))))))
              ((string-empty-p (plist-get r :stdout))
               (harness-tool-ok (format "No matches for %s in %s%s" pattern shown
                                        (if glob (format " (glob %s)" glob) ""))))
              (t
               (pcase-let ((`(,text . ,total) (harness-tools-fs--grep-format
                                               (plist-get r :stdout) cwd max-results
                                               (and elsewhere (or (file-remote-p path) "")))))
                 (harness-tool-ok
                  (if (> total max-results)
                      (format "%s\n\n[%d matches, showing the first %d. Narrow the pattern, add a glob, or raise max_results]"
                              text total max-results)
                    (format "%s\n(%d match%s)" text total (if (= total 1) "" "es")))))))))))))))

(harness-define-tool "grep"
  :label "Search files"
  :description "Search file contents with a regular expression (ripgrep when available). Output lines are path:line: text. Use glob to restrict file names (e.g. \"*.el\"). Case-insensitive unless case_sensitive is true."
  :schema '(:type "object"
            :properties (:pattern (:type "string" :description "Regular expression to search for")
                         :path (:type "string" :description "File or directory to search. Default: the working directory")
                         :glob (:type "string" :description "Only search files whose name matches this glob")
                         :case_sensitive (:type "boolean" :description "Match case exactly. Default false")
                         :max_results (:type "integer" :description "Maximum matching lines to return. Default 200"))
            :required ("pattern"))
  :kind 'read
  :coalescable t
  :paths (lambda (input) (list (or (plist-get input :path) ".")))
  :subject (lambda (input) (format "%s in %s" (harness-truncate-end (or (plist-get input :pattern) "") 40)
                                   (or (plist-get input :path) ".")))
  :handler (harness-tools-fs--broker "grep"))

;;;; file_info

(defun harness-tools-fs--count-lines (path)
  "Return the number of lines in text file PATH."
  (with-temp-buffer
    (harness-tools-fs--insert-text path)
    (count-lines (point-min) (point-max))))

(defun harness-tools-fs--file-info (input ctx)
  "Handler for file_info with INPUT under CTX."
  (let* ((path (harness-tools-fs--path input ctx))
         (shown (harness-tools-fs--display path ctx))
         (attrs (file-attributes path 'string)))
    (if (null attrs)
        (harness-tool-error (format "Not found: %s" shown))
      (let* ((type (file-attribute-type attrs))
             (kind (cond ((eq type t) "directory") ((stringp type) "symlink") (t "file")))
             (size (file-attribute-size attrs))
             (mtime (file-attribute-modification-time attrs))
             (binary (and (string= kind "file") (harness-tools-fs--binary-p path)))
             (lines (and (string= kind "file") (not binary)
                         (<= size harness-tools-fs--line-count-limit)
                         (harness-tools-fs--count-lines path)))
             (mime (and (string= kind "file") (harness-tools-fs--mime path))))
        (harness-tool-ok
         (string-join
          (delq nil
                (list (format "path: %s" path)
                      (format "type: %s%s" kind (if (stringp type) (format " -> %s" type) ""))
                      (when (string= kind "file") (format "size: %d bytes (%s)" size (harness-format-bytes size)))
                      (format "modified: %s (%s)" (format-time-string "%Y-%m-%d %H:%M:%S" mtime)
                              (harness-relative-time (float-time mtime)))
                      (format "mode: %s" (file-attribute-modes attrs))
                      (format "owner: %s" (file-attribute-user-id attrs))
                      (when mime (format "mime: %s" mime))
                      (when (string= kind "file") (format "content: %s" (if binary "binary" "text")))
                      (when lines (format "lines: %d" lines))
                      (when (string= kind "directory")
                        (format "entries: %d"
                                (length (directory-files path nil directory-files-no-dot-files-regexp t))))))
          "\n")
         :meta (list :size size :type kind :lines lines))))))

(harness-define-tool "file_info"
  :label "File info"
  :description "Metadata for a path: type, size, modification time, mode, mime type and line count for text files."
  :schema '(:type "object"
            :properties (:path (:type "string" :description "File or directory, absolute or relative to the working directory"))
            :required ("path"))
  :kind 'read
  :coalescable t
  :paths (lambda (input) (list (plist-get input :path)))
  :subject (lambda (input) (plist-get input :path))
  :handler (harness-tools-fs--broker "file_info"))

;; The worker, declared to the MCP host when there is one.  At top level, so
;; a reload declares it again.  The host is not required: without it the
;; tools run here, as they do in a harness that has no host.
(with-eval-after-load 'harness-mcp
  (harness-mcp-define-server
   'fs
   :title "File tools"
   :doc "The file tools, run in the session's sandbox (lisp/harness-mcp-fs.el)."
   :command #'harness-tools-fs--worker-command
   :profile #'harness-tools-fs--profile
   :events '(tools/file-written)))

(harness-define-module 'tools-fs
  :doc "Read file, Write file, Edit file, List directory, Find files, Search files and File info."
  :requires '(tools))

(provide 'harness-tools-fs)
;;; harness-tools-fs.el ends here
