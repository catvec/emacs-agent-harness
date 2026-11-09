;;; client.el --- Ask a harness for speech over ACP  -*- lexical-binding: t; -*-

;;; Commentary:

;; The client half of the voice pipeline demo.  It connects over TCP to
;; the harness the demo started, authenticates with the token the harness
;; wrote, and then uses the pipeline the way any client does: status,
;; transcription and synthesis.  It has no whisper.cpp, Kokoro or
;; container runtime of its own -- nothing here runs speech at all.

;;; Code:

(require 'cl-lib)
(require 'harness-core)
(require 'harness-acp)

(defun harness-voice-pipeline-demo--wav ()
  "Return a base64 WAV of a tenth of a second of silence."
  (let* ((samples 3200)
         (size (+ 36 (* 2 samples)))
         (le (lambda (n)
               (unibyte-string (logand n 255) (logand (ash n -8) 255)
                               (logand (ash n -16) 255) (logand (ash n -24) 255)))))
    (base64-encode-string
     (concat "RIFF" (funcall le size)
             "WAVEfmt " (unibyte-string 16 0 0 0 1 0 1 0 128 62 0 0 0 125 0 0 2 0 16 0)
             "data" (funcall le (* 2 samples))
             (make-string (* 2 samples) 0))
     t)))

(defun harness-voice-pipeline-demo--connect (token-file port)
  "Return a connection to the harness at PORT, authenticated with TOKEN-FILE."
  (let* ((harness-acp-token (with-temp-buffer
                              (insert-file-contents token-file)
                              (string-trim (buffer-string))))
         (conn (harness-acp-connect (format "127.0.0.1:%d" port))))
    (harness-await (harness-acp-initialize conn) 20)
    (harness-await (harness-acp-authenticate conn harness-acp-token) 20)
    conn))

(defun harness-voice-pipeline-demo--call (conn method params)
  "Call METHOD with PARAMS over CONN and return its result."
  (harness-await (harness-acp-request conn method params) 60))

(defun harness-voice-pipeline-demo-client (token-file port)
  "Use the harness's pipeline at PORT: TOKEN-FILE authenticates the client."
  (let ((conn (harness-voice-pipeline-demo--connect token-file port)))
    (unwind-protect
        (progn
          (let ((status (harness-voice-pipeline-demo--call conn "_harness/speech/status" nil)))
            (princ (format "RESULT status      : %s · %s (%s)\n"
                           (plist-get status :state) (plist-get status :detail)
                           (plist-get status :backend))))
          (let ((answer (harness-voice-pipeline-demo--call
                         conn "_harness/speech/transcribe"
                         (list :audio (harness-voice-pipeline-demo--wav)))))
            (princ (format "RESULT transcribe  : %s\n" (plist-get answer :text))))
          (let ((answer (harness-voice-pipeline-demo--call
                         conn "_harness/speech/synthesize"
                         (list :text "The pipeline is the harness server's"))))
            (princ (format "RESULT synthesize  : %d bytes of %s\n"
                           (length (base64-decode-string (plist-get answer :audio)))
                           (plist-get answer :mime)))))
      (harness-acp-close conn))))

(defun harness-voice-pipeline-demo-stop (token-file port)
  "Stop the harness's pipeline at PORT, over ACP."
  (let ((conn (harness-voice-pipeline-demo--connect token-file port)))
    (unwind-protect
        (let ((status (harness-voice-pipeline-demo--call conn "_harness/speech/stop" nil)))
          (princ (format "RESULT stop        : %s\n" (plist-get status :state))))
      (harness-acp-close conn))))

(provide 'client)
;;; client.el ends here
