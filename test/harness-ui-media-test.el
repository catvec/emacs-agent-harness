;;; harness-ui-media-test.el --- Tests for audio, video and clipboard media  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)

(defmacro harness-ui-media-test-with (&rest body)
  "Load the state layer, ACP, the UI foundation and the media module, then run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent acp ui ui-media))
         (harness-test-load-module m)))
     (clrhash harness-ui-media--players)
     (clrhash harness-ui-media--durations)
     (let ((harness-acp-token nil)
           (default-directory dir))
       (unwind-protect
           (progn ,@body)
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))))))

(defun harness-ui-media-test--le (n bytes)
  "Return N as a little-endian string of BYTES bytes."
  (let ((s (make-string bytes 0)))
    (dotimes (i bytes s) (aset s i (logand (ash n (* -8 i)) 255)))))

(defun harness-ui-media-test--be (n bytes)
  "Return N as a big-endian string of BYTES bytes."
  (let ((s (make-string bytes 0)))
    (dotimes (i bytes s) (aset s i (logand (ash n (* -8 (- bytes 1 i))) 255)))))

(defun harness-ui-media-test--png (path width height)
  "Write a PNG of WIDTH by HEIGHT pixels to PATH.
Only the header, which is all the poster needs to size it."
  (let ((coding-system-for-write 'binary))
    (with-temp-file path
      (set-buffer-multibyte nil)
      (insert "\211PNG\r\n\032\n" (make-string 4 0) "IHDR"
              (harness-ui-media-test--be width 4) (harness-ui-media-test--be height 4))))
  path)

(defun harness-ui-media-test--fake-video (path)
  "Write a few bytes that look like a video to PATH."
  (let ((coding-system-for-write 'binary))
    (with-temp-file path
      (set-buffer-multibyte nil)
      (insert "\0\0\0\030ftypmp42" (make-string 64 0))))
  path)

(defun harness-ui-media-test--poster-svg (image)
  "Return the SVG text of the poster IMAGE."
  (plist-get (cdr image) :data))

(defun harness-ui-media-test-wav (path seconds &optional amplitude)
  "Write a 16 kHz mono 16-bit WAV of SECONDS at PATH with a square wave of AMPLITUDE."
  (let* ((rate 16000) (samples (round (* rate seconds))) (data-size (* 2 samples))
         (coding-system-for-write 'binary))
    (with-temp-file path
      (set-buffer-multibyte nil)
      (insert "RIFF" (harness-ui-media-test--le (+ 36 data-size) 4) "WAVE"
              "fmt " (harness-ui-media-test--le 16 4) (harness-ui-media-test--le 1 2) (harness-ui-media-test--le 1 2)
              (harness-ui-media-test--le rate 4) (harness-ui-media-test--le (* rate 2) 4)
              (harness-ui-media-test--le 2 2) (harness-ui-media-test--le 16 2)
              "data" (harness-ui-media-test--le data-size 4))
      (let ((a (or amplitude 0)))
        (dotimes (i samples)
          (insert (harness-ui-media-test--le (logand (if (zerop (mod (/ i 40) 2)) a (- a)) 65535) 2)))))
    path))

(defun harness-ui-media-test-has-p (string predicate)
  "Non-nil when some character of STRING satisfies PREDICATE on its properties."
  (let ((i 0) (found nil))
    (while (and (not found) (< i (length string)))
      (when (funcall predicate (text-properties-at i string)) (setq found t))
      (setq i (1+ i)))
    found))

(ert-deftest harness-ui-media-audio-player-line ()
  (harness-ui-media-test-with
    (let* ((wav (harness-ui-media-test-wav (expand-file-name "clip.wav" dir) 2.0))
           (s (harness-ui-media-render-attachment (list :path wav :mime "audio/wav" :size (harness-file-size wav) :name "clip.wav")))
           (plain (substring-no-properties s)))
      ;; Play button, name, progress, times and volume.
      (should (string-match-p "►" plain))
      (should (string-match-p "clip.wav" plain))
      (should (string-match-p "0:00 / 0:02" plain))
      (should (string-match-p "80%" plain))
      (should (harness-ui-media-test-has-p s (lambda (p) (plist-get p 'harness-ui-media-button))))
      (should (harness-ui-media-test-has-p s (lambda (p) (keymapp (plist-get p 'keymap)))))
      (should (equal wav (get-text-property 0 'harness-ui-media-id s)))
      (should (equal "audio/wav" (get-text-property 0 'harness-ui-media-mime s)))
      ;; The duration came from the WAV header, no ffprobe needed.
      (should (= 2.0 (harness-ui-media--wav-duration wav)))
      (should (= 2.0 (harness-ui-media--duration wav)))
      ;; A MIME type is guessed from the extension when missing.
      (should (string-match-p "►" (substring-no-properties (harness-ui-media-render-attachment (list :path wav)))))
      ;; Terminal fallback draws a text bar; on a graphic display an SVG.
      (if (and (display-graphic-p) (image-type-available-p 'svg))
          (should (harness-ui-media-test-has-p s (lambda (p) (let ((d (plist-get p 'display))) (and (consp d) (eq (plist-get (cdr d) :type) 'svg))))))
        (should (string-match-p "─" plain))))))

(ert-deftest harness-ui-media-rerender-in-place ()
  (harness-ui-media-test-with
    (let* ((wav (harness-ui-media-test-wav (expand-file-name "clip.wav" dir) 3.0))
           (att (list :path wav :mime "audio/wav" :name "clip.wav")))
      (with-temp-buffer
        (insert "before " (harness-ui-media-render-attachment att) " after\n")
        (insert (harness-ui-media-render-attachment att) "\n")
        ;; Pretend a player started 1.5 seconds ago; both copies redraw with the new time.
        (let ((proc (start-process "harness-test-sleep" nil "sleep" "30")))
          (unwind-protect
              (progn
                (puthash wav (list :started (- (float-time) 1.5) :process proc) harness-ui-media--players)
                (harness-ui-media--rerender wav)
                (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                  (should (string-prefix-p "before " text))
                  (should (string-match-p " after\n" text))
                  (should (= 2 (cl-count-if (lambda (l) (string-match-p "‖.*0:01 / 0:03" l)) (split-string text "\n")))))
                ;; Stopping keeps the position and shows the play button again.
                (harness-ui-media-stop wav)
                (should-not (process-live-p proc))
                (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                  (should (= 2 (cl-count-if (lambda (l) (string-match-p "►.*0:01 / 0:03" l)) (split-string text "\n"))))))
            (when (process-live-p proc) (delete-process proc))))))))

(ert-deftest harness-ui-media-video-thumbnail-path-and-file ()
  (harness-ui-media-test-with
    (let* ((video (harness-ui-media-test--fake-video (expand-file-name "movie.mp4" dir)))
           (thumb (harness-ui-media-thumbnail-path video)))
      (should (string-prefix-p (expand-file-name "thumbs/" harness-state-directory) thumb))
      (should (string-suffix-p ".png" thumb))
      (should (equal thumb (harness-ui-media-thumbnail-path video)))
      (should-not (equal thumb (harness-ui-media-thumbnail-path (expand-file-name "other.mp4" dir))))
      ;; Any other file is a button with its type and size.
      (let* ((s (harness-ui-media-render-attachment (list :path (expand-file-name "notes.txt" dir) :mime "text/plain" :size 2048)))
             (plain (substring-no-properties s)))
        (should (string-match-p "notes.txt" plain))
        (should (string-match-p "text/plain" plain))
        (should (string-match-p "2 KiB" plain))
        (should (harness-ui-media-test-has-p s (lambda (p) (plist-get p 'harness-ui-media-button))))))))

(ert-deftest harness-ui-media-video-poster ()
  "A video shows a poster with its thumbnail, a play button and its
duration, and a caption that plays it.  Without a thumbnail there is a
plain card, and a terminal shows the caption alone."
  (harness-ui-media-test-with
    (let* ((video (harness-ui-media-test--fake-video (expand-file-name "movie.mp4" dir)))
           (thumb (harness-ui-media-thumbnail-path video)))
      (clrhash harness-ui-media--thumbnail-failed)
      (clrhash harness-ui-media--video-players)
      (puthash video 42 harness-ui-media--durations)
      (harness-ui-media-test--png thumb 640 360)
      ;; The poster is an SVG: the thumbnail embedded, a play triangle,
      ;; the duration, sized from the thumbnail's shape.
      (should (equal '(320 . 180) (harness-ui-media--poster-size thumb)))
      (should (equal '(320 . 180) (harness-ui-media--poster-size nil)))
      (let ((svg (harness-ui-media-test--poster-svg (harness-ui-media--poster-image thumb 320 180 nil 42))))
        (should (string-match-p "data:image/png;base64" svg))
        (should (string-match-p "<polygon" svg))
        (should (string-match-p ">0:42<" svg)))
      ;; While it plays the play triangle is a stop square.
      (let ((svg (harness-ui-media-test--poster-svg (harness-ui-media--poster-image nil 320 180 t nil))))
        (should-not (string-match-p "<polygon" svg))
        (should-not (string-match-p "<text" svg)))
      (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil)))
        (let* ((s (harness-ui-media-render-attachment (list :path video :mime "video/mp4" :size 1024 :name "movie.mp4")))
               (plain (substring-no-properties s)))
          ;; In batch there is no graphic display: the caption alone, with
          ;; the name, its duration, its size and the Play button.
          (should (string-match-p "movie.mp4" plain))
          (should (string-match-p "Play" plain))
          (should (string-match-p "0:42" plain))
          (should (string-match-p "1 KiB" plain))
          (should (harness-ui-media-test-has-p s (lambda (p) (plist-get p 'harness-ui-media-button))))
          (should (harness-ui-media-test-has-p s (lambda (p) (eq (plist-get p 'pointer) 'hand)))))
      ;; A remote file is never read, and still gets a Play button.
      (let* ((s (harness-ui-media-render-attachment (list :path "/ssh:far:/srv/movie.mp4" :mime "video/mp4")))
             (plain (substring-no-properties s)))
          (should (string-match-p "movie.mp4" plain))
          (should (string-match-p "Play" plain))
          (should-not (string-match-p "making a thumbnail" plain)))))))

(ert-deftest harness-ui-media-video-play-and-stop ()
  "Playing a video runs the player with it; while it runs the poster
shows Stop, and stopping it kills the player."
  (harness-ui-media-test-with
    (skip-unless (executable-find "sh"))
    (let* ((video (harness-ui-media-test--fake-video (expand-file-name "movie.mp4" dir)))
           (script (expand-file-name "fake-player.sh" dir))
           (log (expand-file-name "player.log" dir))
           (harness-ui-media-video-player script)
           (harness-ui-media--video-players (make-hash-table :test 'equal)))
      (with-temp-file script
        (insert "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"" log "\"\nsleep 30\n"))
      (set-file-modes script #o755)
      (harness-ui-media-play-video video)
      (should (harness-ui-media--video-process video))
      ;; The shell creates the log before it writes it, so wait for the
      ;; content, not the file: under load an empty file is a real race.
      (harness-test-wait (lambda ()
                           (and (file-exists-p log)
                                (with-temp-buffer
                                  (insert-file-contents log)
                                  (string-match-p "movie.mp4" (buffer-string)))))
                         5 "the player logged its arguments")
      (should (string-match-p "movie.mp4" (with-temp-buffer (insert-file-contents log) (buffer-string))))
      (let ((plain (substring-no-properties (harness-ui-media-render-attachment (list :path video :mime "video/mp4")))))
        (should (string-match-p "Stop" plain))
        (should (string-match-p "playing in fake-player.sh" plain)))
      (harness-ui-media-stop-video video)
      (should-not (harness-ui-media--video-process video))
      (should (string-match-p "Play" (substring-no-properties (harness-ui-media-render-attachment (list :path video :mime "video/mp4"))))))))

(ert-deftest harness-ui-media-thumbnail-failure-is-remembered ()
  "A video no thumbnail can be made of is not tried again: ffmpeg
runs twice at most (a second in, then the first frame)."
  (harness-ui-media-test-with
    (let* ((video (harness-ui-media-test--fake-video (expand-file-name "movie.mp4" dir)))
           (calls nil))
      (clrhash harness-ui-media--thumbnailing)
      (clrhash harness-ui-media--thumbnail-failed)
      (cl-letf (((symbol-function 'executable-find) (lambda (p) (and (equal p "ffmpeg") p)))
                ((symbol-function 'harness-run-command)
                 (lambda (command &rest _)
                   (push command calls)
                   ;; Nothing comes out of it.
                   (harness-resolved (list :exit 1 :stdout "" :stderr "")))))
        (harness-ui-media-render-attachment (list :path video :mime "video/mp4"))
        (should (= 2 (length calls)))
        (should (string-match-p " -ss 1 " (concat " " (mapconcat #'identity (car (last calls)) " ") " ")))
        (should (gethash video harness-ui-media--thumbnail-failed))
        ;; A later rendering does not try again.
        (harness-ui-media-render-attachment (list :path video :mime "video/mp4"))
        (should (= 2 (length calls))))
      ;; While one is being made the caption says so.
      (clrhash harness-ui-media--thumbnailing)
      (clrhash harness-ui-media--thumbnail-failed)
      (cl-letf (((symbol-function 'executable-find) (lambda (p) (and (equal p "ffmpeg") p)))
                ((symbol-function 'harness-run-command) (lambda (&rest _) (harness-make-promise))))
        (should (string-match-p "making a thumbnail"
                                (substring-no-properties (harness-ui-media-render-attachment (list :path video :mime "video/mp4")))))
        (clrhash harness-ui-media--thumbnailing)))))

(ert-deftest harness-ui-media-png-size-and-wav-header ()
  "The poster measures a PNG, a video is not taken for a WAV, and a
rendering keeps the properties its buffer gave it."
  (harness-ui-media-test-with
    (let ((png (harness-ui-media-test--png (expand-file-name "wide.png" dir) 640 360)))
      (should (equal '(640 . 360) (harness-ui-media--png-size png)))
      ;; A tall one keeps its shape: 500 pixels high, 100 wide, scales by
      ;; 0.48 to the poster's 240-pixel height.
      (should (equal '(48 . 240) (harness-ui-media--poster-size
                                  (harness-ui-media-test--png (expand-file-name "tall.png" dir) 100 500))))
      (should-not (harness-ui-media--png-size (expand-file-name "nope.png" dir))))
    ;; An AVI is a RIFF file too, but not a WAV header.
    (let ((avi (expand-file-name "clip.avi" dir)))
      (let ((coding-system-for-write 'binary))
        (with-temp-file avi (set-buffer-multibyte nil) (insert "RIFF" (make-string 4 0) "AVI " (make-string 100 0))))
      (should-not (harness-ui-media--wav-duration avi)))
    ;; Rerendering in place keeps what the host buffer put on the copy:
    ;; a chat's margin and read-only, which the rendering does not have.
    (let* ((video (harness-ui-media-test--fake-video (expand-file-name "movie.mp4" dir)))
           (att (list :path video :mime "video/mp4" :size 76 :name "movie.mp4")))
      (with-temp-buffer
        (insert "x" (harness-ui-media-render-attachment att))
        (let ((beg (1+ (point-min))))
          (add-text-properties beg (point-max) '(read-only t line-prefix "  "))
          (harness-ui-media--rerender video)
          (should (get-text-property beg 'read-only))
          (should (equal "  " (get-text-property beg 'line-prefix)))
          (should (equal video (get-text-property beg 'harness-ui-media-id)))
          (should (string-match-p "Play" (substring-no-properties (buffer-string)))))))))

(ert-deftest harness-ui-media-recorder-detection-and-level ()
  (harness-ui-media-test-with
    (let ((harness-ui-media-recorder-command nil))
      (cl-letf (((symbol-function 'executable-find) (lambda (p) (and (member p '("pw-record")) p))))
        (should (equal "pw-record" (car (harness-ui-media--recorder-command "/tmp/x.wav"))))
        (should (member "/tmp/x.wav" (harness-ui-media--recorder-command "/tmp/x.wav"))))
      (cl-letf (((symbol-function 'executable-find) (lambda (p) (and (member p '("arecord")) p))))
        (should (equal "arecord" (car (harness-ui-media--recorder-command "/tmp/x.wav")))))
      (cl-letf (((symbol-function 'executable-find) (lambda (p) (and (member p '("ffmpeg")) p))))
        (should (equal '("-f" "pulse") (seq-take (member "-f" (harness-ui-media--recorder-command "/tmp/x.wav")) 2))))
      (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil)))
        (should-not (harness-ui-media--recorder-command "/tmp/x.wav"))
        (should-error (harness-record-audio) :type 'user-error)))
    (let ((harness-ui-media-recorder-command '("myrec" "-o" :file)))
      (cl-letf (((symbol-function 'executable-find) (lambda (p) (and (equal p "myrec") p))))
        (should (equal '("myrec" "-o" "/tmp/y.wav") (harness-ui-media--recorder-command "/tmp/y.wav")))))
    ;; Level: silence is 0, full scale is 1, a quiet signal in between.
    (should (= 0.0 (harness-ui-media--rms-level (make-string 200 0))))
    (should (< 0.99 (harness-ui-media--rms-level (apply #'concat (make-list 100 (harness-ui-media-test--le 32767 2))))))
    (let ((quiet (harness-ui-media--rms-level (apply #'concat (make-list 100 (harness-ui-media-test--le 1000 2))))))
      (should (< 0.3 quiet 0.7)))
    ;; The meter is a string with a display image or a block character.
    (let ((m (harness-ui-media--meter 0.5)))
      (should (or (get-text-property 0 'display m) (string-match-p "[▁▂▃▄▅▆▇█]" m))))))

(ert-deftest harness-ui-media-recording-round-trip ()
  "Record with a fake recorder that writes a WAV, stop it, receive the attachment."
  (harness-ui-media-test-with
    (skip-unless (executable-find "sh"))
    (let* ((received nil)
           (harness-ui-media-attach-function (lambda (a) (setq received a)))
           (fake (expand-file-name "fakerec.sh" dir)))
      (with-temp-file fake
        (insert "#!/bin/sh\ntrap 'exit 0' INT TERM\nprintf 'RIFF' > \"$1\"; head -c 400 /dev/zero >> \"$1\"\nwhile true; do sleep 0.1; done\n"))
      (set-file-modes fake #o755)
      (let ((harness-ui-media-recorder-command (list fake :file)))
        (harness-record-audio)
        (should (process-live-p harness-ui-media--recorder))
        (should harness-ui-media-recording-mode)
        (harness-test-wait (lambda () (string-match-p "REC" harness-ui-media--rec-string)) 5 "mode line")
        (harness-test-wait (lambda () (> (or (harness-file-size harness-ui-media--recording-file) 0) 44)) 5 "file grows")
        (harness-record-audio)
        (harness-test-wait (lambda () received) 5 "attachment")
        (should (equal "audio/wav" (plist-get received :mime)))
        (should (string-prefix-p (expand-file-name "recordings/" harness-state-directory) (plist-get received :path)))
        (should (> (plist-get received :size) 44))
        (should-not harness-ui-media-recording-mode)
        (should (equal "" harness-ui-media--rec-string))))))

(ert-deftest harness-ui-media-ffprobe-duration ()
  "ffprobe reads the duration of a generated WAV (skipped without ffprobe)."
  (harness-ui-media-test-with
    (skip-unless (executable-find "ffprobe"))
    (let* ((wav (harness-ui-media-test-wav (expand-file-name "probe.wav" dir) 1.5))
           (result 'pending))
      (harness-ui-media--probe-duration wav (lambda (d) (setq result d)))
      (harness-test-wait (lambda () (not (eq result 'pending))) 20 "ffprobe")
      (should (numberp result))
      (should (< (abs (- 1.5 result)) 0.1)))))

(ert-deftest harness-ui-media-playback-external ()
  "Playing through an external player starts a process (skipped without a player)."
  (harness-ui-media-test-with
    (skip-unless (harness-ui-media--player-program))
    (let* ((wav (harness-ui-media-test-wav (expand-file-name "play.wav" dir) 0.3))
           (harness-ui-media-volume 0))
      (harness-ui-media-play wav)
      (should (harness-ui-media--playing-p wav))
      (should (string-match-p "‖" (substring-no-properties (harness-ui-media-render-attachment (list :path wav :mime "audio/wav")))))
      (harness-ui-media-stop wav)
      (should-not (harness-ui-media--playing-p wav)))))

(ert-deftest harness-ui-media-thumbnail-callback-and-no-retry ()
  "A chip asking for a thumbnail is told when the attempt is over.
One that could not be made is not tried again."
  (harness-ui-media-test-with
    (let* ((video (harness-ui-media-test--fake-video (expand-file-name "cb.mp4" dir)))
           (runs 0) (called 0))
      (cl-letf (((symbol-function 'executable-find) (lambda (p) (equal p "ffmpeg")))
                ((symbol-function 'harness-run-command)
                 (lambda (&rest _) (cl-incf runs) (harness-resolved '(:exit 1)))))
        (should-not (harness-ui-media-video-thumbnail video (lambda () (cl-incf called))))
        (should (>= runs 1))
        (should (= 1 called))
        ;; Tried once, however many commands that took, and never again.
        (let ((tried runs))
          (should-not (harness-ui-media-video-thumbnail video))
          (should (= tried runs)))))))

(provide 'harness-ui-media-test)
;;; harness-ui-media-test.el ends here
