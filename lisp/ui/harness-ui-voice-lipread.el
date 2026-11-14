;;; harness-ui-voice-lipread.el --- Webcam lip reading as a voice provider  -*- lexical-binding: t; -*-

;;; Commentary:

;; A third voice path beside the microphone ones: a local camera reads
;; lips, a local model turns the mouth into words, and the words enter
;; the ordinary live-voice session.  It is the `lipread' provider, a
;; `live' capability with a sidecar of its own
;; (`scripts/harness-voice-live-lipread'), so the chat, the tools, the
;; permission panels and the transcript are the ones every live provider
;; uses.
;;
;;   camera -> face + mouth crop -> local ONNX lip-read model
;;          -> caption with a certainty -> the ordinary delegation
;;
;; Nothing leaves this machine and nothing is kept: frames live in the
;; sidecar's memory and are dropped when an utterance ends.
;;
;; The model is Auto-AVSR's LRS3 visual-only recognizer, exported to
;; ONNX and quantized to int8 by a community project.  Its weights are
;; research and non-commercial only because LRS3 is; the setup list says
;; so, and `harness-voice-lipread-setup' is the one place the files are
;; fetched.  See docs/voice-lip-reading.md for the research and
;; docs/design/webcam-lip-reading-voice.md for the decisions.
;;
;; Camera permission is explicit and per session.  The grant is asked for
;; when a session starts, held in `harness-voice-lipread--granted', and
;; dropped when the session ends, on a reload and on a kill; the sidecar
;; is told through `--camera-consent' and opens no device without it.  A
;; refused grant ends the start with a user error and no process.
;;
;; Every transcript carries the model's own certainty.  `sure' and
;; `likely' read like speech, `unsure' is shown as uncertain and never
;; becomes a request, and a reading below the floor is not shown as
;; speech at all.  The words of an uncertain reading are visible, marked,
;; and nothing downstream treats them as something the person said.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)

(declare-function harness-voice-live-stop "harness-ui-voice-live")
(declare-function harness-voice-setup--refresh "harness-ui-voice-providers")
(declare-function harness-voice-provider-camera-p "harness-ui-voice-providers")
(declare-function harness-voice--script "harness-ui-voice-providers")
(declare-function harness-voice-live--transcript-section "harness-ui-voice-live")
(declare-function harness-voice-live--transcript-insert "harness-ui-voice-live")
(declare-function harness-voice-provider-camera-p "harness-ui-voice-providers")
(defvar harness-voice-live--camera)
(declare-function harness-voice-setup--refresh "harness-ui-voice-providers")
(declare-function harness-voice--audio-need "harness-ui-voice-providers")
(declare-function harness-voice-unmute--tts-url "harness-ui-voice-providers")

(defvar harness-directory)

(defgroup harness-voice-lipread nil
  "Local webcam lip reading as a live voice provider."
  :group 'harness-voice)

;;;; Where the model and the camera are

(defun harness-voice-lipread-default-model-dir ()
  "Return the model directory `harness-voice-lipread-setup' installs into."
  (expand-file-name "harness/lipread"
                    (or (getenv "XDG_DATA_HOME")
                        (expand-file-name ".local/share" "~"))))

(defcustom harness-voice-lipread-model-dir (harness-voice-lipread-default-model-dir)
  "Directory holding the lip-reading model files.
`scripts/harness-voice-lipread-setup --model' downloads them here and
checks each against its published SHA-256; nothing downloads them by
itself.  The directory needs `lipread_ctc.int8.onnx', `tokens.json' and
`face_detection_yunet_2023mar.onnx'.
This is client configuration, not a safe directory-local option."
  :type 'directory
  :group 'harness-voice-lipread)

(defcustom harness-voice-lipread-python "python3"
  "The Python interpreter that runs the lip-reading sidecar.
The runtime needs `onnxruntime`, `numpy` and `opencv-python-headless`,
which a system Python often does not have: point this at a virtualenv's
interpreter when `scripts/harness-voice-lipread-setup --runtime
--python PATH' installed them there."
  :type 'string
  :group 'harness-voice-lipread)

(defcustom harness-voice-lipread-source nil
  "A video file to read instead of the camera, or nil.
It replays a recording at 25 fps through the same face, mouth and model
path, which is how the pipeline is tried and shown without opening a
camera.  A file source needs no camera grant; it is a recording the
person chose.  Nil reads the camera named by
`harness-voice-lipread-device'."
  :type '(choice (const :tag "Camera" nil) file)
  :group 'harness-voice-lipread)

(defcustom harness-voice-lipread-device "0"
  "Camera the lip-reading provider opens: an index or a device path.
`0' is the first camera OpenCV finds.  The device is opened only after
the person granted the session the camera, and released when the session
ends."
  :type 'string
  :group 'harness-voice-lipread)

(defcustom harness-voice-lipread-min-confidence 0.80
  "Mean top-1 probability below which a lip reading is not shown.
Measured on the LRS3 test set, the readings above this floor carry about
14% word error and the ones below it about 58%, so a reading under it is
dropped rather than guessed at.  Lower it to keep more, at the cost of
presenting worse readings."
  :type 'number
  :group 'harness-voice-lipread)

(defcustom harness-voice-lipread-motion-floor 0.004
  "Mouth movement, per frame, that counts as speaking.
The mean absolute change of the mouth patch between frames, on a 0..1
scale.  The gate also follows the still frames before each utterance, so
this is the floor under a quiet camera rather than the level a speaking
mouth must reach."
  :type 'number
  :group 'harness-voice-lipread)

(defvar harness-voice-lipread--granted nil
  "Non-nil while this Emacs granted the camera for the running session.
It is never saved and never made persistent: each session asks again,
and the grant is dropped when the session ends.")

(defconst harness-voice-lipread--model-files
  '("lipread_ctc.int8.onnx" "tokens.json" "face_detection_yunet_2023mar.onnx")
  "The files a model directory needs, in the order a reason names them.")

(defun harness-voice-lipread-model-path (name)
  "Return the full path of model file NAME."
  (expand-file-name name harness-voice-lipread-model-dir))

(defun harness-voice-lipread-missing-files ()
  "Return the model files that are not installed."
  (cl-remove-if #'file-exists-p
                (mapcar #'harness-voice-lipread-model-path
                        harness-voice-lipread--model-files)))

(defun harness-voice-lipread-need ()
  "Return why the lip-reading provider cannot run, or nil.
The reason names the first thing missing, as one line for the setup
list: the model file, the camera, or the Python runtime."
  (when-let* ((missing (car (harness-voice-lipread-missing-files))))
    (format "Model unavailable · %s" (file-name-nondirectory missing))))

(defun harness-voice-lipread-camera-state ()
  "Return the camera's state for the setup list: a symbol.
`granted' while this Emacs holds a grant for a running session,
`running' while the session's sidecar reported the camera live, and
`off' otherwise."
  (cond ((not harness-voice-lipread--granted) 'off)
        ((equal (plist-get harness-voice-live--camera :state) "live") 'live)
        (t 'granted)))

;;;; The grant

(defun harness-voice-lipread-grant ()
  "Grant the camera to the next live session, after a confirmation.
The grant is per session: it is not saved, it is never written to a
configuration file, and it ends with the session, a reload or a kill."
  (interactive)
  (when (y-or-n-p "Camera · this session? ")
    (setq harness-voice-lipread--granted t)
    (harness-voice-setup--refresh)
    (message "Camera · granted")
    t))

(defun harness-voice-lipread-revoke ()
  "Drop the camera grant and end a running lip-reading session."
  (interactive)
  (when (and harness-voice-lipread--granted
             (fboundp 'harness-voice-live--active-p)
             (harness-voice-live--active-p))
    (harness-voice-live-stop))
  (setq harness-voice-lipread--granted nil
        harness-voice-live--camera nil)
  (harness-voice-setup--refresh)
  (message "Camera · revoked"))

(defun harness-voice-lipread--prepare ()
  "Ask for the camera, or refuse, before a lip-reading session starts.
Called by `harness-voice-live-start' through the provider's `:prepare'.
A refusal is a user error, so no process starts and no device opens."
  (when-let* ((missing (car (harness-voice-lipread-missing-files))))
    (user-error "Lip-reading model unavailable · %s"
                (file-name-nondirectory missing)))
  (when (and harness-voice-lipread-source
             (not (file-readable-p (expand-file-name harness-voice-lipread-source))))
    (user-error "Lip-reading source unavailable · %s"
                (file-name-nondirectory harness-voice-lipread-source)))
  ;; A recording needs no camera, so it needs no camera permission.
  (unless (or harness-voice-lipread-source harness-voice-lipread--granted)
    (unless (harness-voice-lipread-grant)
      (user-error "Camera permission · declined")))
  t)

(defun harness-voice-lipread--stopped ()
  "Drop the grant when the live session ends.
Called from the provider's `:stopped' on every way a session can end:
a stop, a failure, a closed pipe, a reload or a killed buffer."
  (setq harness-voice-lipread--granted nil
        harness-voice-live--camera nil)
  (harness-voice-setup--refresh))

;;;; The command

(defun harness-voice-lipread--tts-url ()
  "Return the local speech endpoint for replies, or nil.
Replies are spoken only by the harness's own local speech pipeline; a
provider with no local speech is caption-only, never a hosted voice."
  (ignore-errors (harness-voice-unmute--tts-url)))

(defun harness-voice-lipread-command ()
  "Return the argv list running the bundled lip-reading sidecar.
The camera is named only with `--camera-consent' once the person granted
the session, so a sidecar started any other way opens no device."
  (append
   (list harness-voice-lipread-python
         (harness-voice--script "harness-voice-live-lipread")
         "--model-dir" harness-voice-lipread-model-dir
         "--device" harness-voice-lipread-device
         "--min-confidence" (number-to-string harness-voice-lipread-min-confidence)
         "--motion-floor" (number-to-string harness-voice-lipread-motion-floor))
   (when harness-voice-lipread-source
     (list "--source" (expand-file-name harness-voice-lipread-source)))
   (when harness-voice-lipread--granted (list "--camera-consent"))
   (when-let* ((url (harness-voice-lipread--tts-url)))
     (list "--tts-url" url))))

;;;; The setup line

(defconst harness-voice-lipread--camera-labels
  '((off . "off") (granted . "granted") (live . "live"))
  "The words for the camera's state in the setup list.")

(defun harness-voice-lipread-camera-label ()
  "Return the setup list's camera words, a noun phrase.
The row's heading is already `Camera', so this is the state and, while a
session runs, the face count: a person whose face is not in view needs
to know that, and it is the difference between a camera that is on and
one that can read."
  (let ((state (harness-voice-lipread-camera-state))
        (camera harness-voice-live--camera))
    (concat (or (alist-get state harness-voice-lipread--camera-labels) "off")
            (when (eq state 'live)
              (concat " · " (harness-voice-lipread-face-label camera))))))

(defun harness-voice-lipread-face-label (camera)
  "Return the face words for CAMERA's last reported state."
  (let ((faces (plist-get camera :faces)))
    (cond ((null faces) "no frame")
          ((zerop faces) "no face")
          ((= faces 1) "1 face")
          (t (format "%d faces" faces)))))

(defun harness-voice--insert-camera ()
  "Insert the camera line for a provider that has one, and nothing otherwise.
The line names the device, where the model is, and the grant, so a
person knows what the next session will open and where the reading comes
from."
  (when (harness-voice-provider-camera-p)
    (let* ((state (harness-voice-lipread-camera-state))
           (face (pcase state
                   ('off 'harness-dim-face)
                   ('granted 'harness-caution-face)
                   (_ 'harness-success-face)))
           (control (if harness-voice-lipread--granted
                        (harness-ui-string-action
                         (propertize "[Revoke]" 'face 'button
                                     'help-echo "Camera · revocation")
                         #'harness-voice-lipread-revoke)
                      (harness-ui-string-action
                       (propertize "[Grant]" 'face 'button
                                   'help-echo "Camera · permission")
                       #'harness-voice-lipread-grant))))
      (insert "\n"
              (propertize "Camera" 'face 'harness-label-face)
              "  "
              (propertize (concat harness-voice-lipread-device " · "
                                  (harness-voice-lipread-camera-label))
                          'face face
                          'help-echo "Camera · webcam lip reading")
              "  " control
              (if harness-voice-lipread--granted
                  ;; The model was checked before the grant; a running
                  ;; session needs no second word for it.
                  ""
                (concat "  "
                        (propertize (or (harness-voice-lipread-model-state)
                                        "Model · ready")
                                    'face (if (harness-voice-lipread-model-state)
                                              'harness-failure-face
                                            'harness-dim-face)
                                    'help-echo harness-voice-lipread-model-dir)))
              "\n"))))

(defun harness-voice-lipread-model-state ()
  "Return the setup list's words for the model, or nil when installed."
  (when-let* ((missing (car (harness-voice-lipread-missing-files))))
    (format "Model · missing %s" (file-name-nondirectory missing))))

;;;; The transcript and the status

(provide 'harness-ui-voice-lipread)
;;; harness-ui-voice-lipread.el ends here
