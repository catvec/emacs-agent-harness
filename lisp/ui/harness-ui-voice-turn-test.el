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

(ert-deftest harness-ui-voice-turn-standalone-recovery-controls ()
  (dolist (text '("Oh, continue." "Well, go on."
                  "Okay, continue, please." "OK, please go on!"
                  "All right, continue." "Alright, go on."
                  "Actually, continue."
                  "send it" "send that" "submit it" "submit that"
                  "send it now" "send that now" "submit it now" "submit that now"
                  "Please send it." "Oh, actually send it."
                  "Okay, actually, please submit that now, please!"
                  "Oh, well, all right, actually, please send it now, please."
                  " \tOH,\nACTUALLY\tSEND IT!! \n"))
    (ert-info (text)
      (let ((case-fold-search nil))
        (should (eq t (harness-voice-turn-recovery-p text)))
        (should (eq 'grace (harness-voice-turn-reason text)))
        (should-not (harness-voice-turn-continuation-p text))))))

(ert-deftest harness-ui-voice-turn-recovery-controls-exclude-literal-content ()
  (dolist (text '("" " \t " "..."
                  "send" "submit" "send this" "send the report"
                  "send it later" "Actually send it tomorrow."
                  "send that message" "Oh, actually send it to Alice."
                  "submit it after the tests" "send it and add more tests"
                  "Don't send it." "Do not continue." "Please don't go on."
                  "Not yet, send it." "I want to send it."
                  "\"send it\"" "'send it'" "“send it”" "‘submit that’"
                  "`continue`" "```send it```" "Actually, \"send it\"."
                  "The label is send it." "Add a button called send it."
                  "Rename it to submit that." "The phrase go on."
                  "I said continue." "Tell them please go on."
                  "Please say send it." "This should continue."
                  "Continue with the refactor." "go online"
                  "Oh, actually, send it is the label."
                  "Oh actually send it, not submit it."
                  "Oh. Actually send it."))
    (ert-info (text)
      (should-not (harness-voice-turn-recovery-p text)))))

(ert-deftest harness-ui-voice-turn-standalone-continuation-controls ()
  (dolist (text '("one second" "one sec" "one moment"
                  "hold on" "hold on a second" "hold on one moment"
                  "let me think" "give me a moment" "give me one second"
                  "wait a sec" "wait one moment"
                  "catch my breath" "I need to catch my breath"
                  "um" "uh" "erm" "hmm"
                  "Oh, please hold on." "Well, one second, please."
                  "Okay, actually let me think." "Please, give me a moment!"
                  "Oh, well, all right, actually, please wait one second, please."
                  " \tOH,\nACTUALLY\tHOLD ON!! \n"))
    (ert-info (text)
      (let ((case-fold-search nil))
        (should (eq t (harness-voice-turn-continuation-p text)))
        (should (eq 'continuation (harness-voice-turn-reason text)))
        (should-not (harness-voice-turn-recovery-p text))))))

(ert-deftest harness-ui-voice-turn-continuation-controls-exclude-literal-content ()
  (dolist (text '("" " \t " "..." "wait" "umlaut" "hold online"
                  "hold on to the draft" "Fix the test, hold on."
                  "Add a button called hold on." "The message says one second."
                  "Please write let me think." "Please wait for the tests."
                  "One second, actually run the tests."
                  "Hold on and run the tests." "Don't hold on."
                  "\"hold on\"" "'one second'" "“let me think”" "‘hmm’"
                  "`hold on`" "```let me think```" "Actually, \"hold on\"."
                  "Oh. Actually hold on."))
    (ert-info (text)
      (should-not (harness-voice-turn-continuation-p text))))
  ;; A trailing cue may hold content, but never makes the whole chunk disposable.
  (should (eq 'continuation (harness-voice-turn-reason "Fix the test, hold on."))))

(ert-deftest harness-ui-voice-turn-control-classification-preserves-input ()
  (dolist (input '("Oh, actually send it." "Please, hold on."
                   "Fix the test, hold on." "Oh, actually send it to Alice."
                   "Add a button called send it." "“let me think”"))
    (let* ((text (propertize input 'voice-source 'original))
           (original (copy-sequence text)))
      (harness-voice-turn-recovery-p text)
      (harness-voice-turn-continuation-p text)
      (harness-voice-turn-reason text)
      (should (equal-including-properties original text)))))

(provide 'harness-ui-voice-turn-test)
;;; harness-ui-voice-turn-test.el ends here
