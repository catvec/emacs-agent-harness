;;; harness-ui-media.el --- Audio, video and clipboard media  -*- lexical-binding: t; -*-

;;; Commentary:

;; Media helpers the chat uses when this module is present:
;;
;; - `harness-ui-media-render-attachment' turns a non-image ATTACHMENT
;;   (:path :size :mime :name) into a propertized string: an audio
;;   player line (play/pause button, an SVG progress bar animated by a
;;   timer against the file's duration, a volume indicator), a video
;;   thumbnail (made asynchronously with ffmpegthumbnailer or ffmpeg,
;;   a placeholder until it is ready) with an [open] button, or a file
;;   button for anything else.  Rendered strings carry a
;;   `harness-ui-media-id' property so every copy in every buffer is
;;   redrawn in place when playback advances or a thumbnail lands.
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

(defcustom harness-ui-media-thumbnail-width 320
  "Width in pixels of generated video thumbnails."
  :type 'integer :group 'harness-ui-media)

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

(defun harness-ui-media--button (label action help &optional face)
  "Return LABEL as a text button with HELP running ACTION (a thunk).
FACE overrides the button face."
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] (lambda () (interactive) (funcall action)))
    (define-key map (kbd "RET") (lambda () (interactive) (funcall action)))
    (propertize label 'face (or face 'button) 'mouse-face 'highlight 'help-echo help
                'keymap map 'follow-link t 'harness-ui-media-button t)))

(defun harness-ui-media--graphic-p ()
  "Non-nil when images can be shown on the selected frame."
  (and (display-graphic-p) (image-type-available-p 'svg)))

(defun harness-ui-media--format-time (seconds)
  "Format SECONDS as m:ss."
  (let ((s (max 0 (floor (or seconds 0)))))
    (format "%d:%02d" (/ s 60) (% s 60))))

(defun harness-ui-media--rerender (id)
  "Redraw every rendered copy of media ID in every buffer, in place."
  (dolist (buf (buffer-list))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (save-excursion
          (goto-char (point-min))
          (let ((inhibit-read-only t) (inhibit-modification-hooks t) m)
            (while (setq m (text-property-search-forward 'harness-ui-media-id id t))
              (let* ((beg (prop-match-beginning m))
                     (end (prop-match-end m))
                     (attachment (get-text-property beg 'harness-ui-media-attachment))
                     (new (and attachment (harness-ui-media-render-attachment attachment))))
                (when new
                  (goto-char beg)
                  (delete-region beg end)
                  (insert new))))))))))

;;;; Duration

(defvar harness-ui-media--durations (make-hash-table :test 'equal) "Path -> seconds or `unknown'.")

(defun harness-ui-media--wav-duration (path)
  "Return the duration of the WAV file at PATH from its header, or nil."
  (condition-case nil
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally path nil 0 64)
        (when (and (>= (buffer-size) 44) (string= (buffer-substring 1 5) "RIFF"))
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
Unknown durations are probed once with ffprobe and cached."
  (let ((cached (gethash path harness-ui-media--durations)))
    (cond ((numberp cached) cached)
          ((eq cached 'unknown) nil)
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
     (harness-run-command (list "ffprobe" "-v" "error" "-show_entries" "format=duration"
                                "-of" "default=nw=1:nk=1" path)
                          :name "harness-ffprobe" :timeout 20)
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

(defvar harness-ui-media--thumbnailing (make-hash-table :test 'equal) "Paths whose thumbnail is being made.")

(defun harness-ui-media-thumbnail-path (path)
  "Return the thumbnail file for the video PATH under the state directory."
  (let ((stamp (format "%s|%s" (expand-file-name path)
                       (or (ignore-errors (float-time (file-attribute-modification-time (file-attributes path)))) 0))))
    (expand-file-name (concat (sha1 stamp) ".png") (harness-ui-media--dir "thumbs"))))

(defun harness-ui-media--thumbnail-command (path out)
  "Return the command producing thumbnail OUT of video PATH, or nil."
  (cond ((executable-find "ffmpegthumbnailer")
         (list "ffmpegthumbnailer" "-i" path "-o" out "-s" (number-to-string harness-ui-media-thumbnail-width) "-q" "8"))
        ((executable-find "ffmpeg")
         (list "ffmpeg" "-loglevel" "error" "-y" "-ss" "1" "-i" path "-frames:v" "1"
               "-vf" (format "scale=%d:-1" harness-ui-media-thumbnail-width) out))))

(defun harness-ui-media--make-thumbnail (path)
  "Generate the thumbnail of PATH in the background, then redraw its renderings."
  (let ((out (harness-ui-media-thumbnail-path path)))
    (unless (or (file-exists-p out) (gethash path harness-ui-media--thumbnailing))
      (when-let* ((cmd (harness-ui-media--thumbnail-command path out)))
        (puthash path t harness-ui-media--thumbnailing)
        (harness-then (harness-run-command cmd :name "harness-thumbnail" :timeout 60)
                      (lambda (_) (remhash path harness-ui-media--thumbnailing) (harness-ui-media--rerender path))
                      (lambda (_) (remhash path harness-ui-media--thumbnailing) (harness-ui-media--rerender path)))))))

(defun harness-ui-media-open (path)
  "Open PATH with the desktop's default application or mpv."
  (interactive "fFile: ")
  (let ((program (cl-find-if #'executable-find '("xdg-open" "mpv" "open"))))
    (unless program (user-error "No opener found (xdg-open or mpv)"))
    (make-process :name "harness-open" :command (list program (expand-file-name path)) :noquery t :buffer nil)
    (message "Opening %s…" (file-name-nondirectory path))))

(defun harness-ui-media--render-video (attachment)
  "Return the thumbnail line for video ATTACHMENT."
  (let* ((path (plist-get attachment :path))
         (thumb (and path (harness-ui-media-thumbnail-path path)))
         (ready (and thumb (file-exists-p thumb)))
         (open (harness-ui-media--button "[open]" (lambda () (harness-ui-media-open path)) "Open in the video player")))
    (unless ready (when path (harness-ui-media--make-thumbnail path)))
    (concat
     (cond
      ((and ready (display-graphic-p) (image-type-available-p 'png))
       (propertize " " 'display (create-image thumb 'png nil :max-width harness-ui-media-thumbnail-width
                                              :max-height (/ (* 9 harness-ui-media-thumbnail-width) 16))
                   'help-echo "Video thumbnail (mouse-1: open)"
                   'keymap (let ((m (make-sparse-keymap)))
                             (define-key m [mouse-1] (lambda () (interactive) (harness-ui-media-open path)))
                             m)))
      (ready (propertize (format " %s " (harness-ui-icon 'harness-icon-video)) 'face 'harness-dim-face))
      ((harness-ui-media--thumbnail-command (or path "") "")
       (propertize (format " %s thumbnail… " (harness-ui-icon 'harness-icon-video)) 'face 'harness-dim-face))
      (t (propertize (format " %s " (harness-ui-icon 'harness-icon-video)) 'face 'harness-dim-face)))
     " " (propertize (harness-ui-media--name attachment) 'face 'bold)
     (if-let* ((size (plist-get attachment :size)))
         (propertize (format " %s" (harness-format-bytes size)) 'face 'harness-dim-face)
       "")
     "  " open " ")))

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
