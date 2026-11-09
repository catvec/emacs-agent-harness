;;; harness-ui-voice-conversation-test.el --- The voice conversation's rules  -*- lexical-binding: t; -*-

;;; Commentary:

;; The distillation rules and the message they produce, with no
;; microphone, sidecar, model or network: the voice conversation's own
;; suite.  The live transport's use of it is covered by
;; harness-ui-voice-live-test.  The copy assertions are exact so a change
;; of wording is a change of test.

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

;;;; Distillation

(ert-deftest harness-ui-voice-conversation-distils-mumbles ()
  "Hesitations, comma-set markers, stutters and repeats go; words stay."
  (dolist (case
           '(("Uh, add a docstring, um, to the the parser."
              . "add a docstring to the parser.")
             ("so, um, what I want is, uh, a queue."
              . "so what I want is a queue.")
             ("I want to I want to add a test."
              . "I want to add a test.")
             ("You know, the parser is slow." . "the parser is slow.")
             ("It's like, really slow." . "It's like, really slow.")
             ("It's like really slow." . "It's like really slow.")
             ("Er, the, er, test is broken." . "the test is broken.")
             ("[BLANK_AUDIO] um [laughter]."
              . nil)
             ("Um, uh, hmm." . nil)))
    (should (equal (cdr case) (harness-voice-distilled-text (car case))))))

(ert-deftest harness-ui-voice-conversation-keeps-content-and-meaning ()
  "Nothing but noise is removed, and real doubles are not stutters."
  (dolist (text '("Add a comment to TokenBucket.take about its refill and retry behavior."
                  "I mean it."
                  "I mean the parser, not the tokenizer."
                  "had had enough"
                  "that that is wrong"
                  "what it is is a bug"
                  "Read parsers.py:12 and fix it."
                  "Yes."
                  "Right."
                  "Uh-huh."))
    (should (equal text (harness-voice-distilled-text text))))
  (let* ((raw "Uh, add a docstring, um, to the the parser.")
         (distilled (harness-voice-distilled-text raw)))
    (dolist (word '("add" "docstring" "parser"))
      (should (member word
                      (harness-ui-voice-conversation-test--words distilled))))
    (should-not (string-match-p "\\bum\\b\\|\\buh\\b" distilled))))

(ert-deftest harness-ui-voice-conversation-keeps-the-correction ()
  "An explicit retraction keeps only what the speaker corrected to."
  (dolist (case '(("add a test, no wait, add a docstring" . "add a docstring")
                  ("add a test, I mean, add a docstring" . "add a docstring")
                  ("use a queue, actually, use the timer" . "use the timer")
                  ("Actually, add a test." . "add a test.")
                  ("add a test, no wait" . "add a test, no wait")))
    (should (equal (cdr case) (harness-voice-distilled-text (car case))))))

(ert-deftest harness-ui-voice-conversation-distillation-is-idempotent ()
  "Distilling a distilled request changes nothing more."
  (dolist (text '("Uh, add a docstring, um, to the the parser."
                  "so, um, what I want is, uh, a queue."
                  "add a test, no wait, add a docstring"
                  "I want to I want to add a test."
                  "You know, the parser is slow."))
    (let ((once (harness-voice-distilled-text text)))
      (should (equal once (harness-voice-distilled-text once))))))

(ert-deftest harness-ui-voice-conversation-distillation-starts-no-process-or-timer ()
  "The hot path starts nothing and stays fast on a long utterance.
This is the latency guard: the distiller is a few regexp passes, not a
process, a timer or a model call."
  (let* ((words (mapcan (lambda (word) (list word "um" "uh" "the"))
                        (make-list 400 "parser")))
         (text (concat "Uh, " (string-join words " ") ", no wait, fix it."))
         (timers (length timer-list))
         (start (float-time))
         (result (harness-voice-distilled-text text)))
    (should (stringp result))
    (should (= timers (length timer-list)))
    (should (< (- (float-time) start) 1.0))))

;;;; The conversation

(ert-deftest harness-ui-voice-conversation-records-both-sides ()
  "A user turn keeps its raw words; a voice turn keeps what was spoken."
  (let ((conversation (harness-voice-conversation-create)))
    (harness-voice-conversation-hear
     conversation "Uh, use a queue, no wait, use the timer."
     "use the timer" "use the timer")
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
        (should (equal "use the timer" (plist-get user :text)))
        (should (equal "use the timer" (plist-get user :sent)))))))

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
       conversation (format "request %d" index) (format "request %d" index)))
    (should (= 3 (length (harness-voice-conversation-turns conversation))))
    (should (equal "request 4"
                   (plist-get (car (harness-voice-conversation-turns conversation))
                              :raw)))
    (harness-voice-conversation-clear conversation)
    (should-not (harness-voice-conversation-turns conversation))))

;;;; What the session sees

(ert-deftest harness-ui-voice-conversation-request-alone-when-self-contained ()
  "A request that names what it is about travels without a wrapper."
  (let ((conversation (harness-voice-conversation-create)))
    (harness-voice-conversation-say conversation "The timer wakes it every 200 ms."
                                    'commentary)
    (dolist (text '("Fix the failing parser test."
                    "Use a queue instead of polling."
                    "Make the parser faster so it handles big files."))
      (should (equal text (harness-voice-conversation-request conversation text))))
    (should-not (string-search "Voice conversation"
                               (harness-voice-conversation-request
                                conversation "Add a docstring to parse.")))))

(ert-deftest harness-ui-voice-conversation-request-carries-what-it-points-at ()
  "A dependent request carries the bounded exchange in plain text."
  (let ((conversation (harness-voice-conversation-create)))
    (harness-voice-conversation-say
     conversation "the timer wakes it every 200 ms" 'commentary)
    (harness-voice-conversation-say
     conversation "that would keep the old poll alive" 'result)
    (harness-voice-conversation-hear
     conversation "use a queue instead" "use a queue instead" "use a queue instead")
    (let ((request (harness-voice-conversation-request conversation "do that")))
      (should (string-prefix-p "do that\n\n" request))
      (should (string-search "Voice conversation before this request:\n" request))
      (should (string-search "Person: use a queue instead" request))
      (should (string-search "Voice: that would keep the old poll alive" request))
      (should (string-suffix-p "\n" request))
      ;; The block is the last turns, not every turn of the call.
      (should (= 1 (harness-ui-voice-conversation-test--occurrences
                    "Voice conversation before this request:" request))))
    ;; A yes/no answer needs the question it answers.
    (should (string-search "Voice conversation before this request:"
                           (harness-voice-conversation-request conversation "yes")))))

(ert-deftest harness-ui-voice-conversation-context-is-bounded ()
  "The block keeps its turn and character budgets."
  (let ((conversation (harness-voice-conversation-create))
        (harness-voice-conversation-context-turns 10)
        (harness-voice-conversation-context-chars 200)
        (harness-voice-conversation-turn-chars 40))
    (dotimes (index 10)
      (harness-voice-conversation-say
       conversation
       (format "voice turn %d %s" index (make-string 80 ?x))
       'commentary))
    (let ((block (harness-voice-conversation-context conversation)))
      (should block)
      (should (<= (length block) 200))
      (should (= 4 (length (split-string block "\n" t))))
      (should (= 3 (harness-ui-voice-conversation-test--occurrences
                    "Voice: voice turn" block)))
      (should (string-search "voice turn 9" block))
      (should-not (string-search "voice turn 6 " block))
      (should (string-search "…" block)))))

(ert-deftest harness-ui-voice-conversation-context-skips-backchannels ()
  "A listening sound is in the record but not in a request's context."
  (let ((conversation (harness-voice-conversation-create)))
    (harness-voice-conversation-say conversation "mm-hmm" 'backchannel)
    (harness-voice-conversation-say conversation "The parser has two entry points."
                                    'commentary)
    (let ((block (harness-voice-conversation-context conversation)))
      (should (string-search "The parser has two entry points." block))
      (should-not (string-search "mm-hmm" block)))
    (should (= 2 (length (harness-voice-conversation-turns conversation))))))

(ert-deftest harness-ui-voice-conversation-context-can-be-turned-off ()
  "The option keeps a dependent request alone."
  (let ((conversation (harness-voice-conversation-create))
        (harness-voice-conversation-carry-context nil))
    (harness-voice-conversation-say conversation "The timer wakes it every 200 ms."
                                    'commentary)
    (should (equal "do that"
                   (harness-voice-conversation-request conversation "do that")))))

(provide 'harness-ui-voice-conversation-test)
;;; harness-ui-voice-conversation-test.el ends here
