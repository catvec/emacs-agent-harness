;;; harness-ui-voice-turn-test.el --- Shared turn-ending examples  -*- lexical-binding: t; -*-

;;; Code:

(require 'harness-test-helpers)
(require 'harness-ui-voice-turn)
(require 'json)

(defun harness-ui-voice-turn-test--fixtures ()
  "Read the same canonical classification examples as the Flutter client."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "test/fixtures/voice-turn-completion.json"
                                            harness-test-root))
    (json-parse-buffer :object-type 'plist :array-type 'list
                       :null-object nil :false-object nil)))

(ert-deftest harness-ui-voice-turn-shared-classification ()
  (dolist (example (plist-get (harness-ui-voice-turn-test--fixtures) :classification))
    (ert-info ((plist-get example :text))
      (should (eq (pcase (plist-get example :reason)
                    ("cutOff" 'cut-off) (reason (intern reason)))
                  (harness-voice-turn-reason (plist-get example :text)
                                             (plist-get example :truncated)))))))

(ert-deftest harness-ui-voice-turn-shared-recovery ()
  (dolist (example (plist-get (harness-ui-voice-turn-test--fixtures) :recovery))
    (ert-info ((plist-get example :text))
      (should (eq (plist-get example :matches)
                  (harness-voice-turn-recovery-p (plist-get example :text)))))))

(ert-deftest harness-ui-voice-turn-question-punctuation-not-proof-of-completion ()
  (dolist (text '("What should I change because?" "Which branch should I use if?"
                   "What should I put in the?"))
    (should (eq 'cut-off (harness-voice-turn-reason text)))))

(provide 'harness-ui-voice-turn-test)
;;; harness-ui-voice-turn-test.el ends here
