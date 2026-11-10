;;; harness-ui-voice-conversation-test.el --- The voice conversation's rules  -*- lexical-binding: t; -*-

;;; Commentary:

;; The voice conversation's own record and the words it sends, with no
;; microphone, sidecar, model or network: its suite.  The live
;; transport's use of it is covered by harness-ui-voice-live-test.  The
;; copy assertions are exact so a change of wording is a change of test.

;;; Code:

(require 'ert)
(require 'harness-test-helpers)
(require 'harness-ui-voice-conversation)

(defun harness-ui-voice-conversation-test--occurrences (needle haystack)
  "Return how many times NEEDLE appears in HAYSTACK."
  (let ((start 0) (count 0))
    (while (string-match (regexp-quote needle) haystack start)
      (setq count (1+ count)
            start (match-end 0)))
    count))

(defun harness-ui-voice-conversation-test--words (text)
  "Return the lowercased words of TEXT."
  (split-string (downcase text) "[^[:alpha:]']+" t))

;;;; The record

(ert-deftest harness-ui-voice-conversation-keeps-the-words-as-heard ()
  "The record keeps the transcript exactly, mumbles and all.
There is no distillation: what the speech model returned is what the
target receives, and what the record keeps."
  (dolist (text '("Uh, add a docstring, um, to the the parser."
                  "add a test, no wait, add a docstring"
                  "I want to I want to add a test."
                  "You know, the parser is slow."
                  "Yes."
                  "Uh-huh."))
    (let ((conversation (harness-voice-conversation-create)))
      (harness-voice-conversation-hear conversation text)
      (let ((turn (car (harness-voice-conversation-turns conversation))))
        (should (equal text (plist-get turn :raw)))
        (should (equal text (plist-get turn :text)))
        (should (equal text (plist-get turn :sent)))))))

(ert-deftest harness-ui-voice-conversation-adds-nothing-to-a-message ()
  "A message is the transcript: no envelope, no context, no prefix.
This is the latency and fidelity guard: the words reach the target in
the event that carried them, and nothing is asked about them first."
  (let ((conversation (harness-voice-conversation-create)))
    (harness-voice-conversation-say conversation "The timer wakes it every 200 ms."
                                    'commentary)
    (harness-voice-conversation-hear conversation "do that")
    (let ((turn (car (harness-voice-conversation-turns conversation))))
      (should (equal "do that" (plist-get turn :sent)))
      (should-not (string-search "Voice conversation" (plist-get turn :sent)))
      (should-not (string-search "<voice-turn-context>" (plist-get turn :sent)))
      (should-not (string-search "The timer wakes it" (plist-get turn :sent))))))

;;;; The conversation

(ert-deftest harness-ui-voice-conversation-records-both-sides ()
  "A user turn keeps its raw words; a voice turn keeps what was spoken."
  (let ((conversation (harness-voice-conversation-create)))
    (harness-voice-conversation-hear
     conversation "Uh, use a queue, no wait, use the timer.")
    (harness-voice-conversation-say
     conversation "The timer is replaced." 'result)
    (let ((turns (harness-voice-conversation-turns conversation)))
      (should (= 2 (length turns)))
      (should (eq 'voice (plist-get (car turns) :speaker)))
      (should (equal "The timer is replaced." (plist-get (car turns) :text)))
      (let ((user (cadr turns)))
        (should (eq 'user (plist-get user :speaker)))
        (should (equal "Uh, use a queue, no wait, use the timer."
                       (plist-get user :raw)))
        (should (equal "Uh, use a queue, no wait, use the timer."
                       (plist-get user :text)))
        (should (equal "Uh, use a queue, no wait, use the timer."
                       (plist-get user :sent)))))))

(ert-deftest harness-ui-voice-conversation-voice-result-absorbs-its-pieces ()
  "A full result that repeats streamed pieces is recorded once."
  (let ((conversation (harness-voice-conversation-create)))
    (harness-voice-conversation-say conversation "The parser is ready." 'commentary)
    (harness-voice-conversation-say conversation "The tests pass." 'commentary)
    (harness-voice-conversation-say
     conversation "The parser is ready. The tests pass." 'result)
    (let ((turns (harness-voice-conversation-turns conversation)))
      (should (= 1 (length turns)))
      (should (equal "The parser is ready. The tests pass."
                     (plist-get (car turns) :text)))
      ;; The same line twice is not a new turn.
      (harness-voice-conversation-say
       conversation "The parser is ready. The tests pass." 'result)
      (should (= 1 (length (harness-voice-conversation-turns conversation)))))))

(ert-deftest harness-ui-voice-conversation-stream-grows-one-turn ()
  "Provider caption fragments are one voice turn, not one per fragment."
  (let ((conversation (harness-voice-conversation-create)))
    (harness-voice-conversation-say conversation "I can" 'provider nil t)
    (harness-voice-conversation-say conversation "do that." 'provider nil t)
    (let ((turns (harness-voice-conversation-turns conversation)))
      (should (= 1 (length turns)))
      (should (equal "I can do that." (plist-get (car turns) :text))))))

(ert-deftest harness-ui-voice-conversation-is-bounded ()
  "A long call keeps the newest turns only."
  (let ((conversation (harness-voice-conversation-create))
        (harness-voice-conversation-turns 3))
    (dotimes (index 5)
      (harness-voice-conversation-hear
       conversation (format "request %d" index)))
    (should (= 3 (length (harness-voice-conversation-turns conversation))))
    (should (equal "request 4"
                   (plist-get (car (harness-voice-conversation-turns conversation))
                              :raw)))
    (harness-voice-conversation-clear conversation)
    (should-not (harness-voice-conversation-turns conversation))))

(provide 'harness-ui-voice-conversation-test)
;;; harness-ui-voice-conversation-test.el ends here
