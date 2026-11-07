;;; harness-voice-gate-test.el --- The deterministic voice gate suite  -*- lexical-binding: t -*-

;;; Commentary:

;; The gate's unit tests are Python: synthetic PCM fixtures, the detector,
;; the sidecar's held-output queue and its ordering.  They need no
;; microphone, speech model or network.  This ERT suite runs them inside
;; the repository's normal test run, so a failing gate is not hidden
;; outside it.

;;; Code:

(require 'ert)
(require 'harness-test-helpers)

(defconst harness-voice-gate-test--script
  (expand-file-name "test/harness-voice-gate-test.py" harness-test-root))

(ert-deftest harness-voice-gate-test-python-suite ()
  "Run the deterministic Python gate tests."
  (skip-unless (executable-find "python3"))
  (let ((buffer (generate-new-buffer " *voice gate tests*"))
        (default-directory (file-name-as-directory harness-test-root)))
    (unwind-protect
        (let ((status (call-process (executable-find "python3") nil buffer nil
                                    harness-voice-gate-test--script)))
          (with-current-buffer buffer
            (message "%s" (buffer-string))
            (unless (eq status 0)
              (ert-fail (format "voice gate tests exited %s:\n%s"
                                status (buffer-string))))))
      (kill-buffer buffer))))

(provide 'harness-voice-gate-test)
;;; harness-voice-gate-test.el ends here
