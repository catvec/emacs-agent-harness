;;; harness-ui-drag-test.el --- Tests for dragging images out of Emacs  -*- lexical-binding: t; -*-

;;; Commentary:

;; The images the harness shows drag out of Emacs as files: a press on
;; one followed by enough motion calls `dnd-begin-file-drag', while a
;; press and release is still the click it was.  Batch Emacs has no
;; display, so the drag itself is stubbed and the mouse events are made
;; by hand; they go through `execute-kbd-macro', so the keymaps a press
;; finds are those a real press finds.  An image held in memory is
;; written to its session's temporary directory first.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)
(require 'harness-ui-drag)

(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent--turns)
(defvar harness-acp--server-enabled)
(defvar harness-acp--clients)
(defvar harness-acp-token)
(defvar harness-ui--sessions)
(defvar harness-ui-session-id)
(defvar harness-provider-demo--delay)
(defvar harness-chat--buffers)
(defvar harness-chat--loading)
(defvar harness-compose-end)
(defvar harness-compose-attachments)
(declare-function harness-chat-buffer "harness-ui-chat")
(declare-function harness-compose--attach "harness-ui-compose")
(declare-function harness-compose--file-attachment "harness-ui-compose")
(declare-function harness-compose-insert-attachments "harness-ui-compose")
(declare-function harness-ui-image-string "harness-ui")
(declare-function harness-ui-image-load-flush "harness-ui")
(declare-function harness-ui-popout--insert-image "harness-ui-popout")
(declare-function harness-ui-connection "harness-ui")

(defvar harness-ui-drag-test--drags nil
  "The calls of the stubbed `dnd-begin-file-drag', newest first.")

(defmacro harness-ui-drag-test-with-display (&rest body)
  "Run BODY as on a display that drags files; drags are recorded, not made."
  (declare (indent 0))
  `(let ((harness-ui-drag-test--drags nil))
     (cl-letf (((symbol-function 'harness-ui-drag-available-p) (lambda () t))
               ((symbol-function 'harness-ui-drag--frame-p) (lambda (_frame) t))
               ((symbol-function 'dnd-begin-file-drag)
                (lambda (&rest args) (push args harness-ui-drag-test--drags) 'copy)))
       ,@body)))

(defun harness-ui-drag-test--posn (pos &optional x y window)
  "Return a mouse position on POS, at pixel X Y of WINDOW (the selected one)."
  (list (or window (selected-window)) pos (cons (or x 20) (or y 20)) 0 nil pos '(0 . 0) nil '(0 . 0) '(1 . 1)))

(defun harness-ui-drag-test--press (pos &rest events)
  "Press mouse-1 on POS in the selected window, then EVENTS, as a user would.
Each of EVENTS is (DX DY) for the mouse moving there, relative to the
press, `release' for letting go where it was pressed, or (release DX DY)
for letting go there.  The command loop reads them all."
  (let ((start (harness-ui-drag-test--posn pos)))
    (execute-kbd-macro
     (vconcat (list (list 'down-mouse-1 start))
              (mapcar (lambda (e)
                        (pcase e
                          ('release (list 'mouse-1 start 1))
                          (`(release ,dx ,dy)
                           (list 'drag-mouse-1 start (harness-ui-drag-test--posn pos (+ 20 dx) (+ 20 dy))))
                          (`(,dx ,dy) (list 'mouse-movement (harness-ui-drag-test--posn pos (+ 20 dx) (+ 20 dy))))))
                      events)))))

(defmacro harness-ui-drag-test-in-buffer (string &rest body)
  "Run BODY in a buffer showing STRING between two lines, in the selected window.
`pos' is where STRING starts."
  (declare (indent 1))
  `(let ((buf (generate-new-buffer "*drag test*")))
     (unwind-protect
         (save-window-excursion
           (set-window-buffer (selected-window) buf)
           (with-current-buffer buf
             (insert "Before the image.\n")
             (let ((pos (point)))
               (insert ,string "\nAfter the image.\n")
               (goto-char (point-min))
               ,@body)))
       (kill-buffer buf))))

(defun harness-ui-drag-test--bytes (file)
  "Return the bytes of FILE."
  (with-temp-buffer (set-buffer-multibyte nil) (insert-file-contents-literally file) (buffer-string)))

(defun harness-ui-drag-test--png ()
  "Return a new PNG file holding `harness-test-png'."
  (let ((coding-system-for-write 'no-conversion))
    (make-temp-file "harness-drag-test-" nil ".png" harness-test-png)))

;;;; Making text draggable

(ert-deftest harness-ui-drag-source-lays-the-drag-over-the-keymap ()
  "A draggable string keeps its bindings and hover text, the drag on top."
  (cl-letf (((symbol-function 'harness-ui-drag-available-p) (lambda () t)))
    (let* ((map (let ((m (make-sparse-keymap))) (define-key m [mouse-1] #'ignore) m))
           (given (propertize "[image]" 'keymap map 'help-echo "mouse-1: open"))
           (s (harness-ui-drag-source given "/tmp/cat.png"))
           (keymap (get-text-property 0 'keymap s)))
      (should (eq 'harness-ui-drag-start (lookup-key keymap [down-mouse-1])))
      (should (eq 'ignore (lookup-key keymap [mouse-1])))
      (should (equal "/tmp/cat.png" (get-text-property 3 'harness-ui-drag s)))
      (should (equal (concat "mouse-1: open; " harness-ui-drag-hint) (get-text-property 0 'help-echo s)))
      ;; The string it was given is left as it was.
      (should (eq map (get-text-property 0 'keymap given)))
      (should-not (get-text-property 0 'harness-ui-drag given))
      ;; Made draggable again, it is the same: one drag map, one hint.
      (let ((again (harness-ui-drag-source s "/tmp/cat.png")))
        (should (eq keymap (get-text-property 0 'keymap again)))
        (should (equal (get-text-property 0 'help-echo s) (get-text-property 0 'help-echo again))))
      ;; Text with no keymap or hover text gets the drag's own; without a
      ;; file it drags the image it shows.
      (let ((plain (harness-ui-drag-source "[image]")))
        (should (eq harness-ui-drag-map (get-text-property 0 'keymap plain)))
        (should (equal harness-ui-drag-hint (get-text-property 0 'help-echo plain)))
        (should (eq t (get-text-property 0 'harness-ui-drag plain)))))))

(ert-deftest harness-ui-drag-source-leaves-what-cannot-drag ()
  "A file on another host is not draggable, nor is anything where Emacs cannot drag."
  (let ((s (propertize "[image]" 'help-echo "mouse-1: open"))
        (props (list 'help-echo "mouse-1: open")))
    (cl-letf (((symbol-function 'harness-ui-drag-available-p) (lambda () t)))
      (should (eq s (harness-ui-drag-source s "/ssh:far:/srv/cat.png")))
      (should (eq props (harness-ui-drag-props props "/ssh:far:/srv/cat.png"))))
    (cl-letf (((symbol-function 'harness-ui-drag-available-p) (lambda () nil)))
      (should (eq s (harness-ui-drag-source s "/tmp/cat.png")))
      (should (eq props (harness-ui-drag-props props "/tmp/cat.png")))
      (should (eq props (harness-ui-drag-props props)))
      (with-temp-buffer
        (insert s)
        (harness-ui-drag-region (point-min) (point-max) "/tmp/cat.png")
        (should-not (get-text-property 1 'harness-ui-drag))))))

;;;; Pressing: a click or a drag

(ert-deftest harness-ui-drag-click-is-still-a-click ()
  "Released where it was pressed, or a few pixels off, a press is the click it was.
Point goes where it was pressed, as a press anywhere else puts it."
  (harness-ui-drag-test-with-display
    (let* ((file (harness-ui-drag-test--png))
           (opened nil)
           (map (let ((m (make-sparse-keymap)))
                  (define-key m [mouse-1] (lambda () (interactive) (push (point) opened)))
                  m)))
      (unwind-protect
          (harness-ui-drag-test-in-buffer (harness-ui-drag-source (propertize "[image]" 'keymap map) file)
            (harness-ui-drag-test--press (1+ pos) 'release)
            (should (equal (list (1+ pos)) opened))
            (should (= (1+ pos) (point)))
            ;; A hand that shook a little: Emacs makes the release a drag
            ;; event, which still opens it.
            (goto-char (point-min))
            (harness-ui-drag-test--press (1+ pos) '(2 1) '(release 3 2))
            (should (equal (list (1+ pos) (1+ pos)) opened))
            (should-not harness-ui-drag-test--drags))
        (delete-file file)))))

(ert-deftest harness-ui-drag-follows-links-and-buttons ()
  "A draggable button still presses on a click: mouse-1 follows its link."
  (harness-ui-drag-test-with-display
    (let ((pressed 0)
          (file (harness-ui-drag-test--png)))
      (unwind-protect
          (harness-ui-drag-test-in-buffer
              (harness-ui-drag-source (buttonize "cat.png (68 B)" (lambda (_) (cl-incf pressed))) file)
            (harness-ui-drag-test--press (+ pos 2) 'release)
            (should (= 1 pressed))
            (harness-ui-drag-test--press (+ pos 2) '(1 1) '(40 3))
            (should (= 1 pressed))
            (should (equal (list (list file (selected-frame) 'copy nil)) harness-ui-drag-test--drags)))
        (delete-file file)))))

(ert-deftest harness-ui-drag-moving-drags-the-file ()
  "Moved `harness-ui-drag-threshold' pixels, or out of the window, it drags the file.
A drop back on this frame does nothing: the drag is not allowed one."
  (harness-ui-drag-test-with-display
    (let ((file (harness-ui-drag-test--png))
          (opened 0))
      (unwind-protect
          (harness-ui-drag-test-in-buffer
              (harness-ui-drag-source
               (propertize "[image]" 'keymap (let ((m (make-sparse-keymap)))
                                               (define-key m [mouse-1] (lambda () (interactive) (cl-incf opened)))
                                               m))
               file)
            (harness-ui-drag-test--press (1+ pos) '(1 0) '(0 2) (list 0 harness-ui-drag-threshold))
            (should (equal (list (list file (selected-frame) 'copy nil)) harness-ui-drag-test--drags))
            (should (= 0 opened))
            ;; Into the window under it, however near.
            (let* ((other (split-window))
                   (start (harness-ui-drag-test--posn (1+ pos))))
              (execute-kbd-macro
               (vector (list 'down-mouse-1 start)
                       (list 'mouse-movement (harness-ui-drag-test--posn 1 20 20 other))))
              (should (= 2 (length harness-ui-drag-test--drags)))
              (should (= 0 opened))))
        (delete-file file)))))

(ert-deftest harness-ui-drag-not-on-a-text-terminal ()
  "On a frame that cannot drag, a press is a plain press."
  (let ((drags nil)
        (opened 0)
        (file (harness-ui-drag-test--png)))
    (unwind-protect
        (cl-letf (((symbol-function 'harness-ui-drag-available-p) (lambda () t))
                  ((symbol-function 'dnd-begin-file-drag) (lambda (&rest args) (push args drags))))
          (harness-ui-drag-test-in-buffer
              (harness-ui-drag-source
               (propertize "[image]" 'keymap (let ((m (make-sparse-keymap)))
                                               (define-key m [mouse-1] (lambda () (interactive) (cl-incf opened)))
                                               m))
               file)
            ;; Batch Emacs's frame is no graphical one: the press is not
            ;; followed, and the motion and the release come as they are.
            (harness-ui-drag-test--press (1+ pos) 'release)
            (should (= 1 opened))
            (should-not drags)))
      (delete-file file))))

;;;; Images held in memory

(ert-deftest harness-ui-drag-writes-an-image-held-in-memory ()
  "An image of data, not of a file, is written to a file to drag, once."
  (harness-ui-drag-test-with-display
    (let ((harness-ui-drag--own-dir nil)
          (image (list 'image :type 'png :data harness-test-png)))
      (unwind-protect
          (harness-ui-drag-test-in-buffer (harness-ui-drag-source (propertize "[image]" 'display image))
            (harness-ui-drag-test--press (1+ pos) (list harness-ui-drag-threshold 0))
            (let ((file (car (car harness-ui-drag-test--drags))))
              ;; In this Emacs's own directory: the buffer has no session.
              (should (equal harness-ui-drag--own-dir (file-name-directory file)))
              (should (equal (format "image-%s.png" (substring (secure-hash 'sha1 harness-test-png) 0 12))
                             (file-name-nondirectory file)))
              (should (equal harness-test-png (harness-ui-drag-test--bytes file)))
              (should (= #o700 (file-modes harness-ui-drag--own-dir)))
              ;; Dragged again, it is the same file.
              (harness-ui-drag-test--press (1+ pos) (list harness-ui-drag-threshold 0))
              (should (equal file (car (car harness-ui-drag-test--drags))))
              (should (= 1 (length (directory-files harness-ui-drag--own-dir nil "\\`[^.]"))))))
        (harness-ui-drag--delete-own-dir)))))

(ert-deftest harness-ui-drag-write-keeps-every-byte ()
  "Bytes are written as they are, whatever they are; a JPEG is a .jpg."
  (let ((dir (make-temp-file "harness-drag-test-" t))
        (bytes (apply #'unibyte-string (number-sequence 0 255))))
    (unwind-protect
        (let ((file (harness-ui-drag-write bytes "bin" dir)))
          (should (equal bytes (harness-ui-drag-test--bytes file)))
          (should (equal "jpg" (harness-ui-drag--extension (list 'image :type 'jpeg :data "x"))))
          (should (equal "png" (harness-ui-drag--extension (list 'image :data harness-test-png))))
          (should (equal file (harness-ui-drag-image-file (list 'image :type 'png :file file))))
          (should-not (harness-ui-drag-image-file (list 'image :type 'png :file "/ssh:far:/x.png"))))
      (delete-directory dir t))))

(ert-deftest harness-ui-drag-image-of-a-display-spec ()
  "The image is found in a display spec of slices and vectors too."
  (let ((image (list 'image :type 'png :file "/tmp/cat.png")))
    (should (eq image (harness-ui-drag--image-in image)))
    (should (eq image (harness-ui-drag--image-in (list '(slice 0 0 10 10) image))))
    (should (eq image (harness-ui-drag--image-in (vector '(space :width 3) image))))
    (should-not (harness-ui-drag--image-in '(margin . left-margin)))
    (should-not (harness-ui-drag--image-in "text"))))

(ert-deftest harness-ui-drag-props-on-every-strip ()
  "Click properties made draggable drag a tall image from any of its strips.
A tall image is drawn as line-high slices of it, each of them with the
properties and the newlines between them without; a drag from the
second hands over the whole image, and a click there still clicks."
  (harness-ui-drag-test-with-display
    (let* ((harness-ui-drag--own-dir nil)
           (image (list 'image :type 'png :data harness-test-png))
           (opened 0)
           (map (let ((m (make-sparse-keymap)))
                  (define-key m [mouse-1] (lambda () (interactive) (cl-incf opened)))
                  m))
           (given (list 'pointer 'hand 'help-echo "image/png" 'keymap map))
           (props (harness-ui-drag-props given)))
      (should (eq t (plist-get props 'harness-ui-drag)))
      (should (eq 'hand (plist-get props 'pointer)))
      (should (equal (concat "image/png; " harness-ui-drag-hint) (plist-get props 'help-echo)))
      (should (eq 'harness-ui-drag-start (lookup-key (plist-get props 'keymap) [down-mouse-1])))
      ;; The properties it was given are left as they were.
      (should (equal (list 'pointer 'hand 'help-echo "image/png" 'keymap map) given))
      ;; Made draggable again, they are the same: one drag map, one hint.
      (let ((again (harness-ui-drag-props props)))
        (should (eq (plist-get props 'keymap) (plist-get again 'keymap)))
        (should (equal (plist-get props 'help-echo) (plist-get again 'help-echo))))
      (unwind-protect
          (harness-ui-drag-test-in-buffer
              (concat (apply #'propertize "[image]" 'display (list '(slice 0 0.0 1.0 0.5) image) props)
                      (propertize "\n" 'line-height t)
                      (apply #'propertize " " 'display (list '(slice 0 0.5 1.0 0.5) image) props))
            (let ((second (+ pos (length "[image]\n"))))
              (harness-ui-drag-test--press second 'release)
              (should (= 1 opened))
              (harness-ui-drag-test--press second (list 0 harness-ui-drag-threshold))
              (should (= 1 opened))
              (let ((file (car (car harness-ui-drag-test--drags))))
                (should (equal harness-ui-drag--own-dir (file-name-directory file)))
                (should (equal harness-test-png (harness-ui-drag-test--bytes file))))))
        (harness-ui-drag--delete-own-dir)))))

;;;; In the harness: the session's directory, the views

(defmacro harness-ui-drag-test-with-harness (&rest body)
  "Load the state layer, ACP and the UI with its views, then run BODY.
`dir' is the state directory and the project."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent acp))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (setq harness-acp--clients nil)
     (clrhash harness-ui-drag--session-dirs)
     (let ((harness-provider-demo--delay 0.005)
           (harness-acp-token nil)
           (harness-ui-drag--own-dir nil)
           (default-directory dir))
       (dolist (m '(ui ui-media ui-compose ui-chat ui-popout))
         (harness-test-load-module m))
       (clrhash harness-ui--sessions)
       (unwind-protect
           (progn ,@body)
         (maphash (lambda (_ b) (when (buffer-live-p b) (kill-buffer b))) harness-chat--buffers)
         (clrhash harness-chat--buffers)
         (clrhash harness-ui-drag--session-dirs)
         (harness-ui-drag--delete-own-dir)
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))))))

(ert-deftest harness-ui-drag-transcript-image-goes-to-the-session-directory ()
  "A pasted image drags out of the transcript from the session's directory.
That is its temporary directory, which the chat asked for as it drew
the image, and the image is a file there."
  (harness-ui-drag-test-with-harness
    (harness-ui-drag-test-with-display
      (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t)))
        (let* ((sid (plist-get (harness-call 'session/create :cwd dir :model "demo:scripted" :name "Drag") :id))
               (tmp (harness-call 'session/tmp-dir sid)))
          (harness-call 'session/append sid
                        (list :kind 'user :content "What is in this picture?"
                              :blocks (list (list :type "image" :mime "image/png"
                                                  :data (base64-encode-string harness-test-png t)))))
          (let ((buf (harness-chat-buffer sid)))
            (harness-test-wait (lambda () (with-current-buffer buf
                                            (and (not harness-chat--loading) harness-compose-end)))
                               5 "the chat")
            (save-window-excursion
              (set-window-buffer (selected-window) buf)
              (with-current-buffer buf
                (let ((pos (text-property-any (point-min) (point-max) 'harness-ui-drag t)))
                  (should pos)
                  (should (eq 'image (car-safe (get-text-property pos 'display))))
                  (should (equal (concat "image/png; " harness-ui-drag-hint) (get-text-property pos 'help-echo)))
                  ;; Drawing it asked the harness where such images go.
                  (harness-test-wait (lambda () (stringp (gethash sid harness-ui-drag--session-dirs)))
                                     5 "the session's directory")
                  (should (equal (file-name-as-directory tmp) (gethash sid harness-ui-drag--session-dirs)))
                  (harness-ui-drag-test--press pos (list 0 harness-ui-drag-threshold))
                  (let ((file (car (car harness-ui-drag-test--drags))))
                    (should (equal (file-name-as-directory tmp) (file-name-directory file)))
                    (should (equal harness-test-png (harness-ui-drag-test--bytes file))))
                  ;; Not this Emacs's own directory: it was never needed.
                  (should-not harness-ui-drag--own-dir))))))))))

(ert-deftest harness-ui-drag-session-directory-not-known-yet ()
  "Before the harness answers, an image goes to this Emacs's own directory.
The next one, once it has answered, goes to the session's."
  (harness-ui-drag-test-with-harness
    (let* ((sid (plist-get (harness-call 'session/create :cwd dir :name "Drag") :id))
           (image (list 'image :type 'png :data harness-test-png)))
      (should (harness-ui-connection))
      (let ((first (harness-ui-drag-image-file image sid)))
        (should (equal harness-ui-drag--own-dir (file-name-directory first))))
      (harness-test-wait (lambda () (stringp (gethash sid harness-ui-drag--session-dirs))) 5 "the answer")
      (should (equal (file-name-as-directory (harness-call 'session/tmp-dir sid))
                     (file-name-directory (harness-ui-drag-image-file image sid))))
      ;; Its directory gone (the system emptied /tmp), the harness makes
      ;; it again when asked, and meanwhile this Emacs's own does.
      (delete-directory (gethash sid harness-ui-drag--session-dirs) t)
      (should (equal harness-ui-drag--own-dir (file-name-directory (harness-ui-drag-image-file image sid))))
      (harness-test-wait (lambda () (stringp (gethash sid harness-ui-drag--session-dirs))) 5 "asked again")
      (should (file-directory-p (gethash sid harness-ui-drag--session-dirs))))))

(ert-deftest harness-ui-drag-compose-chip ()
  "An attachment's thumbnail and name drag its file; its × does not.
A click on the name still opens it."
  (harness-ui-drag-test-with-harness
    (harness-ui-drag-test-with-display
      (let ((file (expand-file-name "cat.png" dir))
            (opened nil))
        (let ((coding-system-for-write 'no-conversion))
          (write-region harness-test-png nil file nil 'silent))
        (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t))
                  ((symbol-function 'harness-compose-open-attachment)
                   (lambda (att) (push (plist-get att :path) opened))))
          (harness-ui-drag-test-in-buffer ""
            (harness-compose--attach (harness-compose--file-attachment file))
            (goto-char pos)
            (harness-compose-insert-attachments)
            (let* ((name (save-excursion (goto-char pos) (search-forward "cat.png (") (match-beginning 0)))
                   (remove (save-excursion (goto-char pos) (search-forward "×") (match-beginning 0))))
              (should (equal file (get-text-property name 'harness-ui-drag)))
              (should (string-suffix-p harness-ui-drag-hint (get-text-property name 'help-echo)))
              (should-not (get-text-property remove 'harness-ui-drag))
              ;; So does the thumbnail, the image before the name (the
              ;; first is the chips' paperclip icon, which does not).
              (let ((thumb (cl-find-if (lambda (p) (eq 'image (car-safe (get-text-property p 'display))))
                                       (number-sequence pos name) :from-end t)))
                (should thumb)
                (should (equal file (get-text-property thumb 'harness-ui-drag)))
                (harness-ui-drag-test--press thumb (list 0 (- harness-ui-drag-threshold)))
                (should (equal (list (list file (selected-frame) 'copy nil)) harness-ui-drag-test--drags))
                (setq harness-ui-drag-test--drags nil))
              (harness-ui-drag-test--press (1+ name) 'release)
              (should (equal (list file) opened))
              (harness-ui-drag-test--press (1+ name) (list (- harness-ui-drag-threshold) 0))
              (should (equal (list (list file (selected-frame) 'copy nil)) harness-ui-drag-test--drags)))))))))

(ert-deftest harness-ui-drag-image-popout ()
  "The image of an image popout drags its file and keeps Emacs's image keys."
  (harness-ui-drag-test-with-harness
    (harness-ui-drag-test-with-display
      (let ((file (expand-file-name "cat.png" dir)))
        (let ((coding-system-for-write 'no-conversion))
          (write-region harness-test-png nil file nil 'silent))
        (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t))
                  ((symbol-function 'harness-ui-popout--image-size) (lambda (_) '(2 . 2)))
                  ((symbol-function 'image-size) (lambda (&rest _) '(200 . 200))))
          (harness-ui-drag-test-in-buffer ""
            (goto-char pos)
            (harness-ui-popout--insert-image file)
            ;; The image is drawn a moment after the popout shows, for a
            ;; display: here, now.
            (harness-ui-image-load-flush)
            (let* ((at (text-property-any (point-min) (point-max) 'harness-ui-drag file))
                   (keymap (get-text-property at 'keymap)))
              (should at)
              (should (eq 'image (car-safe (get-text-property at 'display))))
              (should (eq 'harness-ui-drag-start (lookup-key keymap [down-mouse-1])))
              (should (eq 'image-increase-size (lookup-key keymap (kbd "i +"))))
              (should (string-search "drag it into another application" (buffer-string)))
              (harness-ui-drag-test--press at (list harness-ui-drag-threshold harness-ui-drag-threshold))
              (should (equal file (car (car harness-ui-drag-test--drags)))))))))))

(ert-deftest harness-ui-drag-image-string-of-a-question ()
  "The image of a question's option drags its file, and clicking still opens it."
  (harness-ui-drag-test-with-harness
    (harness-ui-drag-test-with-display
      (let ((file (expand-file-name "diagram.png" dir)))
        (let ((coding-system-for-write 'no-conversion))
          (write-region harness-test-png nil file nil 'silent))
        (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t)))
          (let ((s (harness-ui-image-string file "image/png")))
            (should (equal file (get-text-property 0 'harness-ui-drag s)))
            (should (equal (format "mouse-1 or RET: open %s; %s" file harness-ui-drag-hint)
                           (get-text-property 0 'help-echo s)))
            (should (lookup-key (get-text-property 0 'keymap s) (kbd "RET")))))))))

(provide 'harness-ui-drag-test)
;;; harness-ui-drag-test.el ends here
