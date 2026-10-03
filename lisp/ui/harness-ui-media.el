;;; harness-ui-media.el --- Audio, video and clipboard media  -*- lexical-binding: t; -*-

;;; Commentary:

;; Media helpers the chat uses when this module is present:
;;
;; - `harness-ui-media-render-attachment' turns a non-image ATTACHMENT
;;   (:path :size :mime :name) into a propertized string: an audio
;;   player line (play/pause button, an SVG progress bar animated by a
;;   timer against the file's duration, a volume indicator), a video
;;   poster (its thumbnail, made asynchronously with ffmpegthumbnailer
;;   or ffmpeg, under a play button, with the duration in a corner and
;;   a Play caption under it) or a file button for anything else.
;;   Rendered strings carry a `harness-ui-media-id' property so every
;;   copy in every buffer is redrawn in place when playback advances or
;;   a thumbnail lands, keeping the properties the host buffer gave the
;;   copy (a chat block's margins and read-only).  The chat module (see
;;   harness-ui-chat.el) is what shows these renderings.
;; - `harness-record-audio' records from the microphone with pw-record,
;;   arecord or ffmpeg into harness-state-directory/recordings/, shows a
;;   live level meter in the mode line (the level is the RMS of the
;;   newest samples of the growing WAV file) and, when stopped, hands
;;   the ATTACHMENT to `harness-ui-media-attach-function'.
;; - `harness-ui-media-clipboard-image' saves the clipboard image to
;;   harness-state-directory/clips/ and returns an ATTACHMENT.
;;
;; Playback prefers an external player (mpv, ffplay, paplay) started
;; as an asynchronous process; `play-sound-file' is the fallback for
;; WAV/AU and runs in a thread, which keeps the command loop alive
;; between chunks but cannot be stopped mid-file.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'svg)
(require 'button)
(require 'mailcap)
(require 'text-property-search)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)

(defvar harness-state-directory)

(defgroup harness-ui-media nil
  "Audio and video in the chat." :group 'harness-ui)

(defcustom harness-ui-media-player-program nil
  "External audio player, or nil to pick the first of mpv, ffplay, paplay.
The symbol `native' forces `play-sound-file'."
  :type '(choice (const :tag "Auto-detect" nil) (const native) string)
  :group 'harness-ui-media)

(defcustom harness-ui-media-recorder-command nil
  "Recorder command as a list of strings with `:file' where the WAV path goes.
Nil auto-detects pw-record, arecord or ffmpeg (PulseAudio input)."
  :type '(choice (const :tag "Auto-detect" nil) (repeat (choice string (const :file))))
  :group 'harness-ui-media)

(defcustom harness-ui-media-volume 80
  "Playback volume in percent for external players."
  :type 'integer :group 'harness-ui-media)

(defconst harness-ui-media--thumbnail-width 320
  "Width in pixels of generated video thumbnails.")

(defvar harness-ui-media-attach-function nil
  "Function called with an ATTACHMENT plist when a recording finishes.
The chat module sets it; when nil the path is only reported.")

(defface harness-media-face '((t :inherit harness-tool-face))
  "Background of media player lines." :group 'harness-ui-media)
(defface harness-media-recording-face '((t :inherit (error bold)))
  "The recording indicator in the mode line." :group 'harness-ui-media)

(harness-ui-define-icon harness-icon-play "play" "►" "play" "Play.")
(harness-ui-define-icon harness-icon-pause "pause" "‖" "pause" "Pause.")
(harness-ui-define-icon harness-icon-stop "stop" "■" "stop" "Stop.")
(harness-ui-define-icon harness-icon-volume "volume" "♪" "vol" "Volume.")
(harness-ui-define-icon harness-icon-video "video" "▣" "video" "Video.")
(harness-ui-define-icon harness-icon-mic "record" "●" "REC" "Recording.")

;;;; Common helpers

(defun harness-ui-media--dir (name)
  "Return harness-state-directory/NAME/, creating it."
  (let ((dir (expand-file-name (concat name "/") harness-state-directory)))
    (harness-ensure-directory dir)
    dir))

(defun harness-ui-media--mime (attachment)
  "Return the MIME type of ATTACHMENT, guessing from the file name."
  (or (plist-get attachment :mime)
      (let ((ext (file-name-extension (or (plist-get attachment :path) (plist-get attachment :name) ""))))
        (and ext (mailcap-extension-to-mime (concat "." ext))))
      "application/octet-stream"))

(defun harness-ui-media--name (attachment)
  "Return the display name of ATTACHMENT."
  (or (plist-get attachment :name)
      (file-name-nondirectory (or (plist-get attachment :path) "attachment"))))

(defun harness-ui-media--clickable (string action help)
  "Return STRING running ACTION (a thunk) on mouse-1, mouse-2 and RET.
HELP is its tooltip; the mouse pointer turns into a hand over it."
  (let ((map (make-sparse-keymap))
        (run (lambda () (interactive) (funcall action))))
    (define-key map [mouse-1] run)
    (define-key map [mouse-2] run)
    (define-key map (kbd "RET") run)
    (propertize string 'help-echo help 'pointer 'hand
                'keymap map 'follow-link t 'harness-ui-media-button t)))

(defun harness-ui-media--button (label action help &optional face)
  "Return LABEL as a text button with HELP running ACTION (a thunk).
FACE overrides the button face."
  (harness-ui-media--clickable (propertize label 'face (or face 'button) 'mouse-face 'highlight)
                               action help))

(defun harness-ui-media--graphic-p ()
  "Non-nil when images can be shown on the selected frame."
  (and (display-graphic-p) (image-type-available-p 'svg)))

(defun harness-ui-media--format-time (seconds)
  "Format SECONDS as m:ss."
  (let ((s (max 0 (floor (or seconds 0)))))
    (format "%d:%02d" (/ s 60) (% s 60))))

(defconst harness-ui-media--own-properties
  '(face display keymap help-echo pointer follow-link mouse-face
         harness-ui-media-button harness-ui-media-id harness-ui-media-attachment harness-ui-media-mime)
  "Text properties a rendering of an attachment sets itself.")

(defvar harness-ui-media-rerender-functions nil
  "Functions called with a media ID (a path) whose rendering changed.
A host view that draws media inside a structure of its own -- the chat,
which folds its tool block around it -- redraws that structure instead
of letting this module edit the buffer in place: an in-place edit makes
a fold overlay collapse onto the media and hide it.  A function returns
non-nil when it handled the ID, and then no copy is edited here.")

(defun harness-ui-media--host-rerender (id)
  "Let a host view redraw its own rendering of media ID.
Return non-nil when one did."
  (let (handled)
    (dolist (fn harness-ui-media-rerender-functions)
      (when (ignore-errors (funcall fn id)) (setq handled t)))
    handled))

(defun harness-ui-media--host-properties (props)
  "Return the properties of PROPS that the buffer holding a rendering added.
Margins, read-only and the like: the rendering does not set them."
  (cl-loop for (k v) on props by #'cddr
           unless (memq k harness-ui-media--own-properties) nconc (list k v)))

(defun harness-ui-media--rerender (id)
  "Redraw every rendered copy of media ID in every buffer, in place.
Each copy keeps the properties its buffer gave it (a chat's margin,
read-only and node), which a fresh rendering does not have.  A view
that renders media in a structure of its own redraws it instead (see
`harness-ui-media-rerender-functions')."
  (unless (harness-ui-media--host-rerender id)
    (dolist (buf (buffer-list))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (save-excursion
            (goto-char (point-min))
            (let ((inhibit-read-only t) (inhibit-modification-hooks t) (buffer-undo-list t) m)
              (while (setq m (text-property-search-forward 'harness-ui-media-id id t))
                (let* ((beg (prop-match-beginning m))
                       (end (prop-match-end m))
                       (attachment (get-text-property beg 'harness-ui-media-attachment))
                       (new (and attachment (harness-ui-media-render-attachment attachment)))
                       (host (harness-ui-media--host-properties (text-properties-at beg))))
                  (when new
                    (when host (add-text-properties 0 (length new) host new))
                    (goto-char beg)
                    (delete-region beg end)
                    (insert new)))))))))))

;;;; Duration

(defvar harness-ui-media--durations (make-hash-table :test 'equal) "Path -> seconds or `unknown'.")

(defun harness-ui-media--wav-duration (path)
  "Return the duration of the WAV file at PATH from its header, or nil."
  (condition-case nil
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally path nil 0 64)
        ;; WAVE too: an AVI is a RIFF file as well.
        (when (and (>= (buffer-size) 44) (string= (buffer-substring 1 5) "RIFF")
                   (string= (buffer-substring 9 13) "WAVE"))
          (let* ((bytes (lambda (pos n)
                          (let ((v 0))
                            (dotimes (i n) (setq v (+ v (ash (char-after (+ pos i)) (* 8 i)))))
                            v)))
                 (rate (funcall bytes 29 4))
                 (size (or (harness-file-size path) 0)))
            (when (> rate 0) (/ (float (max 0 (- size 44))) rate)))))
    (error nil)))

(defun harness-ui-media--duration (path)
  "Return the known duration of PATH in seconds, or nil.
Unknown durations are probed once with ffprobe and cached.  A remote
file is never read: that would block."
  (let ((cached (gethash path harness-ui-media--durations)))
    (cond ((numberp cached) cached)
          ((eq cached 'unknown) nil)
          ((file-remote-p path) nil)
          (t
           (let ((wav (harness-ui-media--wav-duration path)))
             (if wav (puthash path wav harness-ui-media--durations)
               (puthash path 'unknown harness-ui-media--durations)
               (harness-ui-media--probe-duration path (lambda (_) (harness-ui-media--rerender path)))
               nil))))))

(defun harness-ui-media--probe-duration (path callback)
  "Ask ffprobe for the duration of PATH; call CALLBACK with seconds or nil."
  (if (not (executable-find "ffprobe"))
      (funcall callback nil)
    (harness-then
     ;; Run here, not on the host of a remote `default-directory'.
     (harness-run-command (list "ffprobe" "-v" "error" "-show_entries" "format=duration"
                                "-of" "default=nw=1:nk=1" path)
                          :name "harness-ffprobe" :timeout 20 :cwd temporary-file-directory)
     (lambda (r)
       (let ((n (string-to-number (string-trim (or (plist-get r :stdout) "")))))
         (when (> n 0) (puthash path n harness-ui-media--durations))
         (funcall callback (and (> n 0) n))))
     (lambda (_) (funcall callback nil)))))

;;;; Audio playback

(defvar harness-ui-media--players (make-hash-table :test 'equal)
  "Path -> (:process P :thread T :started FLOAT :paused-at FLOAT).")
(defvar harness-ui-media--tick-timer nil)

(defun harness-ui-media--player-program ()
  "Return the external player program to use, or nil for native playback."
  (pcase harness-ui-media-player-program
    ('native nil)
    ((and (pred stringp) p) (and (executable-find p) p))
    (_ (cl-find-if #'executable-find '("mpv" "ffplay" "paplay")))))

(defun harness-ui-media--player-command (program path)
  "Return the command list playing PATH with PROGRAM."
  (pcase (file-name-nondirectory program)
    ("mpv" (list program "--no-video" "--really-quiet" (format "--volume=%d" harness-ui-media-volume) path))
    ("ffplay" (list program "-nodisp" "-autoexit" "-loglevel" "quiet"
                    "-volume" (number-to-string harness-ui-media-volume) path))
    ("paplay" (list program (format "--volume=%d" (round (* 655.36 harness-ui-media-volume))) path))
    (_ (list program path))))

(defun harness-ui-media--playing-p (path)
  "Non-nil when PATH is playing."
  (let ((p (gethash path harness-ui-media--players)))
    (and p (or (process-live-p (plist-get p :process))
               (let ((th (plist-get p :thread))) (and th (thread-live-p th)))))))

(defun harness-ui-media--elapsed (path)
  "Return seconds played of PATH."
  (let ((p (gethash path harness-ui-media--players)))
    (if (and p (harness-ui-media--playing-p path))
        (- (float-time) (plist-get p :started))
      (or (plist-get p :paused-at) 0))))

(defun harness-ui-media--ensure-tick ()
  "Start the progress timer while something plays."
  (unless (and harness-ui-media--tick-timer (memq harness-ui-media--tick-timer timer-list))
    (setq harness-ui-media--tick-timer (run-at-time 0.5 0.5 #'harness-ui-media--tick))))

(defun harness-ui-media--tick ()
  "Redraw players; stop the timer when nothing plays."
  (let ((active nil))
    (maphash (lambda (path _) (when (harness-ui-media--playing-p path) (setq active t))
               (harness-ui-media--rerender path))
             harness-ui-media--players)
    (unless active
      (when harness-ui-media--tick-timer (cancel-timer harness-ui-media--tick-timer))
      (setq harness-ui-media--tick-timer nil))))

(defun harness-ui-media-play (path)
  "Start playing the audio file PATH."
  (interactive "fAudio file: ")
  (harness-ui-media-stop path)
  (let* ((program (harness-ui-media--player-program))
         (entry (list :started (float-time) :paused-at nil)))
    (cond
     (program
      (setq entry (plist-put entry :process
                             (make-process :name "harness-audio" :command (harness-ui-media--player-command program path)
                                           :noquery t :buffer nil
                                           :sentinel (lambda (_p _e) (harness-ui-media--rerender path))))))
     ((member (downcase (or (file-name-extension path) "")) '("wav" "au"))
      (setq entry (plist-put entry :thread
                             (make-thread (lambda () (ignore-errors (play-sound-file path (/ harness-ui-media-volume 100.0))))
                                          "harness-audio"))))
     (t (user-error "No audio player found: install mpv or ffplay")))
    (puthash path entry harness-ui-media--players)
    (harness-ui-media--ensure-tick)
    (harness-ui-media--rerender path)))

(defun harness-ui-media-stop (path)
  "Stop playing PATH."
  (interactive "fAudio file: ")
  (when-let* ((p (gethash path harness-ui-media--players)))
    (let ((elapsed (harness-ui-media--elapsed path)))
      (when (process-live-p (plist-get p :process)) (delete-process (plist-get p :process)))
      (puthash path (list :started nil :paused-at elapsed) harness-ui-media--players))
    (harness-ui-media--rerender path)))

(defun harness-ui-media-toggle (path)
  "Play PATH, or stop it when it is playing."
  (if (harness-ui-media--playing-p path) (harness-ui-media-stop path) (harness-ui-media-play path)))

(defun harness-ui-media--progress-image (fraction width)
  "Return an SVG image of a progress bar WIDTH pixels wide filled to FRACTION."
  (let* ((h 10) (svg (svg-create width h))
         (accent (if (eq (frame-parameter nil 'background-mode) 'dark) "#3987e5" "#2a78d6"))
         (x (max 4 (min (- width 4) (* width (max 0.0 (min 1.0 fraction)))))))
    (svg-rectangle svg 0 3 width 4 :rx 2 :fill accent :fill-opacity 0.25)
    (svg-rectangle svg 0 3 x 4 :rx 2 :fill accent)
    (svg-circle svg x 5 4 :fill accent)
    (svg-image svg :ascent 'center :scale 1)))

(defun harness-ui-media--progress (fraction &optional indeterminate)
  "Return the progress bar string for FRACTION; INDETERMINATE dims it."
  (if (harness-ui-media--graphic-p)
      (propertize (make-string 20 ?\s) 'display (harness-ui-media--progress-image (if indeterminate 0 fraction) 160)
                  'help-echo (if indeterminate "Duration unknown" (format "%.0f%%" (* 100 fraction))))
    (let ((filled (round (* 20 (if indeterminate 0 fraction)))))
      (concat (propertize (make-string filled ?━) 'face 'button)
              (propertize (make-string (- 20 filled) ?─) 'face 'harness-dim-face)))))

(defun harness-ui-media--render-audio (attachment)
  "Return the player line for audio ATTACHMENT."
  (let* ((path (plist-get attachment :path))
         (playing (harness-ui-media--playing-p path))
         (duration (and path (harness-ui-media--duration path)))
         (elapsed (harness-ui-media--elapsed path))
         (fraction (if (and duration (> duration 0)) (/ elapsed duration) 0)))
    (when (and duration (>= elapsed duration) (not playing))
      (puthash path (list :paused-at 0) harness-ui-media--players)
      (setq elapsed 0 fraction 0))
    (concat
     " "
     (harness-ui-media--button (format " %s " (harness-ui-icon (if playing 'harness-icon-pause 'harness-icon-play)))
                               (lambda () (harness-ui-media-toggle path))
                               (if playing "Stop" "Play"))
     " " (propertize (harness-ui-media--name attachment) 'face 'bold)
     "  " (harness-ui-media--progress fraction (null duration))
     "  " (propertize (format "%s / %s" (harness-ui-media--format-time elapsed)
                              (if duration (harness-ui-media--format-time duration) "?:??"))
                      'face 'harness-dim-face)
     "  " (propertize (format "%s %d%%" (harness-ui-icon 'harness-icon-volume) harness-ui-media-volume)
                      'face 'harness-dim-face 'help-echo "Playback volume (harness-ui-media-volume)")
     " ")))

;;;; Video
;;
;; A video shows as a poster: its thumbnail, made in the background by
;; ffmpegthumbnailer or ffmpeg (a dark card until it lands, or for good
;; when none can be made), under a round play button, with its duration
;; in a corner.  A caption follows: a Play button, the name, duration
;; and size.  The poster and the button both play the video, on a
;; click or RET.  While a player the harness started itself (mpv,
;; ffplay) plays it, the poster shows a stop button and both stop it;
;; an opener (xdg-open) hands the video to the desktop's player.  A
;; terminal shows the caption alone.

(defcustom harness-ui-media-video-player nil
  "Program playing videos, or nil for the first one installed of mpv,
the desktop's opener (xdg-open, or open on macOS) and ffplay.
While a player the harness started plays a video, its poster shows a
stop button, which stops it; an opener hands the video to the
desktop's player and is done."
  :type '(choice (const :tag "Auto-detect" nil) string)
  :group 'harness-ui-media)

(defvar harness-ui-media--thumbnailing (make-hash-table :test 'equal) "Paths whose thumbnail is being made.")

(defvar harness-ui-media--thumbnail-failed (make-hash-table :test 'equal)
  "Paths no thumbnail could be made of; they are not tried again.")

(defvar harness-ui-media--video-players (make-hash-table :test 'equal)
  "Video path -> the player process the harness started for it.")

(defun harness-ui-media-thumbnail-path (path)
  "Return the thumbnail file for the video PATH under the state directory."
  (let ((stamp (format "%s|%s" (expand-file-name path)
                       (or (ignore-errors (float-time (file-attribute-modification-time (file-attributes path)))) 0))))
    (expand-file-name (concat (sha1 stamp) ".png") (harness-ui-media--dir "thumbs"))))

(defun harness-ui-media--thumbnail-commands (path out)
  "Return the commands to try in turn for the thumbnail OUT of video PATH.
ffmpeg takes the frame a second in, then the first one, for a clip
shorter than that.  Nil when neither ffmpegthumbnailer nor ffmpeg is
installed."
  (let ((width (number-to-string harness-ui-media--thumbnail-width)))
    (cond ((executable-find "ffmpegthumbnailer")
           (list (list "ffmpegthumbnailer" "-i" path "-o" out "-s" width "-q" "8")))
          ((executable-find "ffmpeg")
           (let ((output (list "-frames:v" "1" "-vf" (format "scale=%s:-1" width) "-update" "1" out)))
             (list (append (list "ffmpeg" "-loglevel" "error" "-y" "-ss" "1" "-i" path) output)
                   (append (list "ffmpeg" "-loglevel" "error" "-y" "-i" path) output)))))))

(defun harness-ui-media--thumbnail-ready-p (file)
  "Non-nil when the thumbnail FILE exists and is not empty."
  (let ((size (harness-file-size file)))
    (and size (> size 0))))

(defun harness-ui-media--make-thumbnail (path)
  "Make the thumbnail of the video PATH in the background, then redraw it.
Return non-nil while it is being made.  A video none could be made of
is remembered, and not tried again."
  (let ((out (harness-ui-media-thumbnail-path path)))
    (unless (or (harness-ui-media--thumbnail-ready-p out)
                (gethash path harness-ui-media--thumbnailing)
                (gethash path harness-ui-media--thumbnail-failed))
      (when-let* ((commands (harness-ui-media--thumbnail-commands path out)))
        (puthash path t harness-ui-media--thumbnailing)
        (harness-ui-media--try-thumbnail path out commands)))
    (gethash path harness-ui-media--thumbnailing)))

(defun harness-ui-media--try-thumbnail (path out commands)
  "Run the first of COMMANDS to make the thumbnail OUT of video PATH.
When it made none, the next one runs; after the last, PATH has failed."
  (let ((after (lambda (_)
                 (if (and (cdr commands) (not (harness-ui-media--thumbnail-ready-p out)))
                     (harness-ui-media--try-thumbnail path out (cdr commands))
                   (unless (harness-ui-media--thumbnail-ready-p out)
                     (puthash path t harness-ui-media--thumbnail-failed))
                   (remhash path harness-ui-media--thumbnailing)
                   (harness-ui-media--rerender path)))))
    ;; Run here, not on the host of a remote `default-directory'.
    (harness-then (harness-run-command (car commands) :name "harness-thumbnail" :timeout 60
                                       :cwd temporary-file-directory)
                  after after)))

(defun harness-ui-media-open (path)
  "Open PATH with the desktop's default application or mpv."
  (interactive "fFile: ")
  (let ((program (cl-find-if #'executable-find '("xdg-open" "mpv" "open"))))
    (unless program (user-error "No opener found (xdg-open or mpv)"))
    (make-process :name "harness-open" :command (list program (expand-file-name path)) :noquery t :buffer nil)
    (message "Opening %s…" (file-name-nondirectory path))))

;;;;; Playing

(defun harness-ui-media--video-player-program ()
  "Return the program to play videos with, or nil when none is installed."
  (if (stringp harness-ui-media-video-player)
      (and (executable-find harness-ui-media-video-player) harness-ui-media-video-player)
    (cl-find-if #'executable-find
                (list "mpv" (if (eq system-type 'darwin) "open" "xdg-open") "ffplay"))))

(defun harness-ui-media--opener-p (program)
  "Non-nil when PROGRAM hands a file to the desktop rather than playing it."
  (member (file-name-nondirectory program) '("xdg-open" "open")))

(defun harness-ui-media--video-command (program file)
  "Return the command playing the video FILE with PROGRAM."
  (pcase (file-name-nondirectory program)
    ("mpv" (list program "--no-terminal" "--force-window=immediate"
                 (format "--volume=%d" harness-ui-media-volume) file))
    ("ffplay" (list program "-autoexit" "-loglevel" "quiet"
                    "-volume" (number-to-string harness-ui-media-volume)
                    "-window_title" (file-name-nondirectory file) file))
    (_ (list program file))))

(defun harness-ui-media--video-process (path)
  "Return the live player process the harness started for video PATH, or nil."
  (let ((proc (gethash path harness-ui-media--video-players)))
    (and (process-live-p proc) proc)))

(defun harness-ui-media-play-video (path)
  "Play the video PATH with `harness-ui-media-video-player'."
  (interactive "fVideo file: ")
  (let ((program (harness-ui-media--video-player-program))
        (file (expand-file-name path)))
    (unless program (user-error "No video player found: install mpv, or ffmpeg for ffplay"))
    (harness-ui-media-stop-video path)
    (if (harness-ui-media--opener-p program)
        (progn
          (make-process :name "harness-open" :command (list program file)
                        :noquery t :buffer nil :connection-type 'pipe)
          (message "Opening %s in the desktop's video player…" (file-name-nondirectory file)))
      (puthash path
               (make-process :name "harness-video" :command (harness-ui-media--video-command program file)
                             :noquery t :buffer nil :connection-type 'pipe
                             :sentinel (lambda (proc _event)
                                         (unless (process-live-p proc)
                                           (when (eq proc (gethash path harness-ui-media--video-players))
                                             (remhash path harness-ui-media--video-players))
                                           (harness-ui-media--rerender path))))
               harness-ui-media--video-players)
      (message "Playing %s in %s…" (file-name-nondirectory file) (file-name-nondirectory program))
      (harness-ui-media--rerender path))))

(defun harness-ui-media-stop-video (path)
  "Stop the player the harness started for the video PATH."
  (interactive "fVideo file: ")
  (when-let* ((proc (gethash path harness-ui-media--video-players)))
    (remhash path harness-ui-media--video-players)
    (when (process-live-p proc) (delete-process proc))
    (harness-ui-media--rerender path)))

(defun harness-ui-media-toggle-video (path)
  "Play the video PATH, or stop it while a player the harness started plays it."
  (if (harness-ui-media--video-process path)
      (harness-ui-media-stop-video path)
    (harness-ui-media-play-video path)))

;;;;; Poster

(defun harness-ui-media--png-size (file)
  "Return (WIDTH . HEIGHT) of the PNG FILE, read from its header, or nil."
  (condition-case nil
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally file nil 0 24)
        (when (and (= (buffer-size) 24)
                   (string= (buffer-substring 1 9) "\211PNG\r\n\032\n")
                   (string= (buffer-substring 13 17) "IHDR"))
          (cl-flet ((u32 (pos)
                      (let ((v 0))
                        (dotimes (i 4) (setq v (+ (* v 256) (char-after (+ pos i)))))
                        v)))
            (let ((w (u32 17)) (h (u32 21)))
              (and (> w 0) (> h 0) (cons w h))))))
    (error nil)))

(defun harness-ui-media--poster-size (thumb)
  "Return (WIDTH . HEIGHT), in pixels, of the poster showing THUMB.
THUMB, a PNG file or nil, keeps its shape and fits in
`harness-ui-media--thumbnail-width' by three quarters of that; without
one the poster is 16:9."
  (let* ((max-w harness-ui-media--thumbnail-width)
         (max-h (round (* 0.75 max-w)))
         (size (and thumb (harness-ui-media--png-size thumb))))
    (if (null size)
        (cons max-w (round (* 9 max-w) 16))
      (let ((scale (min (/ (float max-w) (car size)) (/ (float max-h) (cdr size)))))
        (cons (max 1 (round (* scale (car size)))) (max 1 (round (* scale (cdr size)))))))))

(defun harness-ui-media--poster-image (thumb width height playing duration)
  "Return the poster of a video, an SVG image WIDTH by HEIGHT pixels.
THUMB, a PNG file, fills it; without one it is a dark card.  Over it a
round play button, a stop button while PLAYING, and DURATION, in
seconds or nil, in the bottom right corner."
  (let* ((svg (svg-create width height))
         (clip (svg-clip-path svg :id "harness-poster"))
         (r (max 14 (round (* 0.14 (min width height)))))
         (cx (/ width 2.0))
         (cy (/ height 2.0)))
    (svg-rectangle clip 0 0 width height :rx 8)
    (svg-rectangle svg 0 0 width height :rx 8 :fill "#16181d")
    (when thumb
      (svg-embed svg thumb "image/png" nil :x 0 :y 0 :width width :height height
                 :preserveAspectRatio "xMidYMid slice" :clip-path "url(#harness-poster)"))
    (svg-circle svg cx cy r :fill "#000000" :fill-opacity 0.55
                :stroke "#ffffff" :stroke-opacity 0.9 :stroke-width 2)
    (if playing
        (let ((side (* 0.7 r)))
          (svg-rectangle svg (- cx (/ side 2)) (- cy (/ side 2)) side side :rx 2 :fill "#ffffff"))
      ;; The triangle's centroid sits on the centre: it looks centred.
      (svg-polygon svg (list (cons (- cx (* 0.32 r)) (- cy (* 0.5 r)))
                             (cons (- cx (* 0.32 r)) (+ cy (* 0.5 r)))
                             (cons (+ cx (* 0.56 r)) cy))
                   :fill "#ffffff"))
    (when duration
      (let* ((label (harness-ui-media--format-time duration))
             (w (+ 12 (* 7 (length label))))
             (h 18)
             (x (- width w 8))
             (y (- height h 8)))
        (svg-rectangle svg x y w h :rx 4 :fill "#000000" :fill-opacity 0.65)
        (svg-text svg label :x (+ x (/ w 2.0)) :y (+ y 13) :text-anchor "middle"
                  :font-family "sans-serif" :font-size 12 :fill "#ffffff")))
    (svg-image svg :ascent 'center :margin '(0 . 3))))

(defun harness-ui-media--render-video (attachment)
  "Return the poster and the caption of the video ATTACHMENT.
The poster, its thumbnail under a play button, and the Play button of
the caption both play the video on mouse-1, mouse-2 or RET; while a
player the harness started plays it, they stop it.  A terminal shows no
poster: the caption starts with a video icon.  A remote file is never
read, which would block: it has no thumbnail and no duration."
  (let* ((path (plist-get attachment :path))
         (name (harness-ui-media--name attachment))
         (local (and path (not (file-remote-p path))))
         (proc (and path (harness-ui-media--video-process path)))
         (thumb (and local (harness-ui-media-thumbnail-path path)))
         (ready (and thumb (harness-ui-media--thumbnail-ready-p thumb) thumb))
         (making (and local (not ready) (harness-ui-media--make-thumbnail path)))
         (duration (and local (harness-ui-media--duration path)))
         (size (plist-get attachment :size))
         (action (and path (lambda () (harness-ui-media-toggle-video path))))
         (help (format "%s %s: mouse-1 or RET" (if proc "Stop" "Play") name))
         (poster (and action (harness-ui-media--graphic-p)
                      (let ((dims (harness-ui-media--poster-size ready)))
                        (harness-ui-media--poster-image ready (car dims) (cdr dims) proc duration)))))
    (concat
     (if poster
         (concat (harness-ui-media--clickable (propertize (format "[video %s]" name) 'display poster)
                                              action help)
                 "\n")
       (propertize (format " %s " (harness-ui-icon 'harness-icon-video)) 'face 'harness-dim-face))
     (if action
         (concat (harness-ui-media--button (format " %s %s " (harness-ui-icon (if proc 'harness-icon-stop 'harness-icon-play))
                                                   (if proc "Stop" "Play"))
                                           action help)
                 " ")
       "")
     (propertize name 'face 'bold)
     (propertize (concat (if duration (concat " · " (harness-ui-media--format-time duration)) "")
                         (if size (concat " · " (harness-format-bytes size)) "")
                         (cond (proc (format " · playing in %s" (file-name-nondirectory (car (process-command proc)))))
                               (making " · making a thumbnail…")
                               (t "")))
                 'face 'harness-dim-face)
     " ")))

;;;; Other files

(defun harness-ui-media--render-file (attachment)
  "Return a file button line for ATTACHMENT."
  (let ((path (plist-get attachment :path)))
    (concat " "
            (harness-ui-media--button (harness-ui-media--name attachment)
                                      (lambda () (if (and path (file-exists-p path)) (find-file path)
                                                   (user-error "File not found: %s" path)))
                                      (or path "Open the file"))
            (propertize (format "  %s%s" (harness-ui-media--mime attachment)
                                (if-let* ((size (plist-get attachment :size))) (format " · %s" (harness-format-bytes size)) ""))
                        'face 'harness-dim-face)
            " ")))

;;;###autoload
(defun harness-ui-media-render-attachment (attachment)
  "Return a propertized string showing the non-image ATTACHMENT.
ATTACHMENT is (:path :size :mime :name).  Audio gets a player, video a
thumbnail with an [open] button, anything else a file button."
  (let* ((mime (harness-ui-media--mime attachment))
         (s (cond ((string-prefix-p "audio/" mime) (harness-ui-media--render-audio attachment))
                  ((string-prefix-p "video/" mime) (harness-ui-media--render-video attachment))
                  (t (harness-ui-media--render-file attachment)))))
    (add-face-text-property 0 (length s) 'harness-media-face t s)
    (add-text-properties 0 (length s) (list 'harness-ui-media-id (or (plist-get attachment :path) (harness-ui-media--name attachment))
                                            'harness-ui-media-attachment attachment
                                            'harness-ui-media-mime mime)
                         s)
    s))

;;;; Recording

(defvar harness-ui-media--recorder nil "The recorder process while recording.")
(defvar harness-ui-media--recording-file nil "Path of the WAV being recorded.")
(defvar harness-ui-media--recording-started nil "Float time the recording began.")
(defvar harness-ui-media--level 0.0 "Current microphone level, 0..1.")
(defvar harness-ui-media--level-timer nil)
(defvar harness-ui-media--rec-string "" "Mode line text while recording.")
(defconst harness-ui-media--rec-construct '(:eval harness-ui-media--rec-string))

(defun harness-ui-media--recorder-command (file)
  "Return the command list recording into FILE, or nil when no recorder exists."
  (let ((template
         (or harness-ui-media-recorder-command
             (cond ((executable-find "pw-record") '("pw-record" "--rate" "16000" "--channels" "1" "--format" "s16" :file))
                   ((executable-find "arecord") '("arecord" "-q" "-f" "S16_LE" "-r" "16000" "-c" "1" :file))
                   ((executable-find "ffmpeg") '("ffmpeg" "-loglevel" "error" "-y" "-f" "pulse" "-i" "default"
                                                 "-ac" "1" "-ar" "16000" :file))))))
    (when (and template (executable-find (car template)))
      (mapcar (lambda (x) (if (eq x :file) file x)) template))))

(defun harness-ui-media--rms-level (bytes)
  "Return the level 0..1 of little-endian 16-bit samples in unibyte string BYTES.
The RMS is mapped from -60 dBFS..0 dBFS onto 0..1."
  (let ((n (/ (length bytes) 2)) (sum 0.0))
    (if (zerop n) 0.0
      (dotimes (i n)
        (let* ((lo (aref bytes (* 2 i))) (hi (aref bytes (1+ (* 2 i))))
               (v (+ lo (ash hi 8)))
               (v (if (>= v 32768) (- v 65536) v)))
          (setq sum (+ sum (* v v)))))
      (let* ((rms (sqrt (/ sum n)))
             (db (if (> rms 0) (* 20 (log (/ rms 32768.0) 10)) -60.0)))
        (max 0.0 (min 1.0 (/ (+ db 60.0) 60.0)))))))

(defun harness-ui-media--sample-level ()
  "Update `harness-ui-media--level' from the tail of the recording file."
  (let* ((file harness-ui-media--recording-file)
         (size (and file (harness-file-size file))))
    (when (and size (> size 44))
      (let ((from (max 44 (- size 6400))))
        (setq harness-ui-media--level
              (condition-case nil
                  (with-temp-buffer
                    (set-buffer-multibyte nil)
                    (insert-file-contents-literally file nil from size)
                    (harness-ui-media--rms-level (buffer-string)))
                (error harness-ui-media--level)))))
    (harness-ui-media--update-rec-string)))

(defun harness-ui-media--meter-image (level)
  "Return an SVG level meter image for LEVEL 0..1."
  (let* ((w 60) (h 10) (svg (svg-create w h))
         (color (cond ((> level 0.85) "#e34948") ((> level 0.6) "#eda100") (t "#1baf7a"))))
    (svg-rectangle svg 0 2 w 6 :rx 2 :fill color :fill-opacity 0.25)
    (svg-rectangle svg 0 2 (max 2 (* w level)) 6 :rx 2 :fill color)
    (svg-image svg :ascent 'center :scale 1)))

(defun harness-ui-media--meter (level)
  "Return the mode line meter string for LEVEL."
  (if (harness-ui-media--graphic-p)
      (propertize "        " 'display (harness-ui-media--meter-image level) 'help-echo "Microphone level")
    (propertize (string (aref "▁▂▃▄▅▆▇█" (min 7 (floor (* level 8)))))
                'face (if (> level 0.85) 'error 'success) 'help-echo "Microphone level")))

(defun harness-ui-media--update-rec-string ()
  "Rebuild the mode line recording segment."
  (setq harness-ui-media--rec-string
        (if (not (process-live-p harness-ui-media--recorder)) ""
          (concat
           (propertize (format " %s REC" (harness-ui-icon 'harness-icon-mic)) 'face 'harness-media-recording-face
                       'help-echo "Recording audio")
           (propertize (format " %s " (harness-ui-media--format-time (- (float-time) harness-ui-media--recording-started)))
                       'face 'harness-dim-face)
           (harness-ui-media--meter harness-ui-media--level)
           " "
           (propertize (format "[%s stop]" (harness-ui-icon 'harness-icon-stop))
                       'face 'button 'mouse-face 'mode-line-highlight
                       'help-echo "Stop recording and attach it (C-c C-r)"
                       'local-map (harness-ui-mouse-keymap #'harness-record-audio))
           " ")))
  (force-mode-line-update t))

(defvar harness-ui-media-recording-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-r") #'harness-record-audio)
    map)
  "Keymap active while recording.")

(define-minor-mode harness-ui-media-recording-mode
  "Global minor mode active while a recording runs.
\\<harness-ui-media-recording-mode-map>\\[harness-record-audio] stops it."
  :global t :group 'harness-ui-media :keymap harness-ui-media-recording-mode-map
  (if harness-ui-media-recording-mode
      (unless (member harness-ui-media--rec-construct global-mode-string)
        (setq global-mode-string
              (append (if (stringp global-mode-string) (list global-mode-string) global-mode-string)
                      (list harness-ui-media--rec-construct))))
    (setq global-mode-string (delete harness-ui-media--rec-construct global-mode-string))
    (setq harness-ui-media--rec-string "")
    (force-mode-line-update t)))

;; While a recording runs its key works in every buffer, so the harness
;; menu offers it wherever it is opened.
(put 'harness-ui-media-recording-mode 'harness-menu-group
     '("Audio"
       ["Recording"
        ("C-c C-r" "Stop recording" harness-record-audio)]))

(defun harness-ui-media--recording-finished (proc event)
  "Sentinel of the recorder PROC: hand the file over when it exits with EVENT."
  (unless (process-live-p proc)
    (when harness-ui-media--level-timer (cancel-timer harness-ui-media--level-timer))
    (setq harness-ui-media--level-timer nil)
    (harness-ui-media-recording-mode -1)
    (let* ((file harness-ui-media--recording-file)
           (size (and file (harness-file-size file))))
      (setq harness-ui-media--recorder nil)
      (if (and size (> size 44))
          (let ((attachment (list :path file :size size :mime "audio/wav" :name (file-name-nondirectory file))))
            (remhash file harness-ui-media--durations)
            (if harness-ui-media-attach-function
                (funcall harness-ui-media-attach-function attachment)
              (message "Recorded %s (%s)" (abbreviate-file-name file) (harness-format-bytes size))))
        (message "Recording produced no audio (%s)" (string-trim (format "%s" event)))))))

;;;###autoload
(defun harness-record-audio ()
  "Start recording from the microphone, or stop the running recording.
The finished WAV is handed to `harness-ui-media-attach-function'."
  (interactive)
  (if (process-live-p harness-ui-media--recorder)
      (progn (message "Stopping recording…")
             (interrupt-process harness-ui-media--recorder))
    (let* ((file (expand-file-name (format-time-string "rec-%Y%m%d-%H%M%S.wav") (harness-ui-media--dir "recordings")))
           (cmd (harness-ui-media--recorder-command file)))
      (unless cmd (user-error "No recorder found: install pipewire (pw-record), alsa-utils (arecord) or ffmpeg"))
      (setq harness-ui-media--recording-file file
            harness-ui-media--recording-started (float-time)
            harness-ui-media--level 0.0
            harness-ui-media--recorder
            (make-process :name "harness-record" :command cmd :noquery t :buffer nil
                          :sentinel #'harness-ui-media--recording-finished))
      (harness-ui-media-recording-mode 1)
      (setq harness-ui-media--level-timer (run-at-time 0.2 0.15 #'harness-ui-media--sample-level))
      (harness-ui-media--update-rec-string)
      (message "Recording… C-c C-r or the [stop] button in the mode line stops it"))))

;;;; Clipboard

;;;###autoload
(defun harness-ui-media-clipboard-image ()
  "Save the image on the clipboard under the state directory.
Return an ATTACHMENT plist, or nil when the clipboard holds no image."
  (let ((data (and (display-graphic-p)
                   (or (ignore-errors (gui-get-selection 'CLIPBOARD 'image/png))
                       (ignore-errors (gui-get-selection 'CLIPBOARD 'image/jpeg))))))
    (when (and (stringp data) (> (length data) 0))
      (let* ((png (string-prefix-p "\211PNG" data))
             (file (expand-file-name (format-time-string (if png "clip-%Y%m%d-%H%M%S.png" "clip-%Y%m%d-%H%M%S.jpg"))
                                     (harness-ui-media--dir "clips")))
             (coding-system-for-write 'binary))
        (with-temp-file file (set-buffer-multibyte nil) (insert data))
        (list :path file :size (harness-file-size file) :mime (if png "image/png" "image/jpeg")
              :name (file-name-nondirectory file))))))

;;;; Module

(defun harness-ui-media--init ()
  "Wire the media commands into the UI."
  (define-key harness-ui-map (kbd "r") #'harness-record-audio))

(harness-define-module 'ui-media
  :doc "Audio playback and recording, video thumbnails, clipboard images."
  :requires '(ui)
  :init #'harness-ui-media--init)

(provide 'harness-ui-media)
;;; harness-ui-media.el ends here
