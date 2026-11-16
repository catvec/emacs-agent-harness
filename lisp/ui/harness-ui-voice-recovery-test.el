;;; harness-ui-voice-recovery-test.el --- Taking back a cut-short voice turn  -*- lexical-binding: t; -*-

;;; Commentary:

;; The decision half of voice-turn recovery, with no sidecar, session or
;; clock: a record is armed, the resumed speech's onset and the first
;; words it produced are reported, and the history the turn left is
;; planned over.  The transport's use of it -- cancellation, rewinding,
;; resubmission -- is covered by harness-ui-voice-live-test.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-ui-voice-recovery)

(defun harness-ui-voice-recovery-test--record (&rest plist)
  "Return an armed recovery record for the voice message PLIST describes.
A key of PLIST replaces the default's value."
  (harness-voice-recovery-arm
   (append plist
           (list :session "s-1" :generation 0 :turn "u-1"
                 :text "Please document the parser"
                 :items (list (list :segment "u-1" :text "Please document the parser"))
                 :segments '("u-1") :submitted 100.0))))

(defun harness-ui-voice-recovery-test--node (id kind ts &rest plist)
  "Return transcript node ID of KIND at TS, with PLIST."
  (append (list :id id :kind kind :ts ts) plist))

(defun harness-ui-voice-recovery-test--conversation (&optional tool after)
  "Return a transcript of a voice message at 100.5, answered at 101.
With TOOL the turn ran a tool call after the message; with AFTER another
user message followed the answer."
  (append
   (list (harness-ui-voice-recovery-test--node "u-0" 'user 90.0 :content "earlier")
         (harness-ui-voice-recovery-test--node "a-0" 'assistant 91.0 :content "earlier answer")
         (harness-ui-voice-recovery-test--node "u-1" 'user 100.5
                                              :content "Please document the parser"
                                              :parent "a-0"))
   (when tool
     (list (harness-ui-voice-recovery-test--node "c-1" 'tool-call 100.6 :call-id "call-1")
           (harness-ui-voice-recovery-test--node "r-1" 'tool-result 100.7 :call-id "call-1")))
   (list (harness-ui-voice-recovery-test--node "a-1" 'assistant 101.0
                                           :content "Which parser?" :parent "u-1"))
   (when after
     (list (harness-ui-voice-recovery-test--node "u-2" 'user 101.5 :content "the JSON one")))))

;;;; The window

(ert-deftest harness-ui-voice-recovery-continuation-inside-the-window-recovers ()
  "Words whose speech began inside the window take the turn back.
The window is measured from the submission to the speech's onset: half
a second, as Noah asked, is inside a 0.6 s window, and so is a speech
that began at the edge of it."
  (let* ((record (harness-ui-voice-recovery-test--record))
         (onset (harness-voice-recovery-onset record "u-2" 100.5)))
    (should (eq 'trigger (car (harness-voice-recovery-trigger
                               onset "in file.py" '(:source "u-2" :now 100.5 :window 0.6)))))
    (should (eq 'trigger (car (harness-voice-recovery-trigger
                               (harness-voice-recovery-onset record "u-2" 100.6)
                               "in file.py" '(:source "u-2" :now 100.9 :window 0.6)))))
    (should (eq 'recovering (harness-voice-recovery-state
                             (cdr (harness-voice-recovery-trigger
                                   onset "in file.py" '(:source "u-2" :window 0.6))))))))

(ert-deftest harness-ui-voice-recovery-continuation-outside-the-window-is-ignored ()
  "Speech that began after the window is a new thought, not a continuation.
It gets its own turn, and the turn already answered stays answered."
  (let* ((record (harness-ui-voice-recovery-test--record))
         (onset (harness-voice-recovery-onset record "u-2" 101.0)))
    (should (equal '(ignore . outside-window)
                   (harness-voice-recovery-trigger
                    onset "in file.py" '(:source "u-2" :now 101.0 :window 0.6))))
    (should (harness-voice-recovery-armed-p onset))))

(ert-deftest harness-ui-voice-recovery-late-transcript-of-early-speech-still-recovers ()
  "Speech to text may take longer than the window; the onset is what counts.
Words spoken 0.2 s after the submission and transcribed 3 s later still
recover the turn, which is why the window is not measured at arrival."
  (let* ((record (harness-ui-voice-recovery-test--record))
         (onset (harness-voice-recovery-onset record "u-2" 100.2)))
    (should (eq 'trigger (car (harness-voice-recovery-trigger
                               onset "in file.py" '(:source "u-2" :now 103.0 :window 0.6)))))
    (should (eq 'onset (plist-get (cdr (harness-voice-recovery-trigger
                                        onset "in file.py" '(:source "u-2" :now 103.0 :window 0.6)))
                                  :measured)))))

(ert-deftest harness-ui-voice-recovery-arrival-is-the-fallback-measure ()
  "Without an onset the words' arrival is the only evidence there is.
A provider that reports no speech gate cannot be told from a slow
transcription, so its late words are treated as a new thought; the
record says which measure it used."
  (let* ((record (harness-ui-voice-recovery-test--record))
         (late (harness-voice-recovery-trigger
                record "in file.py" '(:source "u-2" :now 103.0 :window 0.6)))
         (soon (harness-voice-recovery-trigger
                record "in file.py" '(:source "u-2" :now 100.3 :window 0.6))))
    (should (equal '(ignore . outside-window) late))
    (should (eq 'trigger (car soon)))
    (should (eq 'arrival (plist-get (cdr soon) :measured)))))

(ert-deftest harness-ui-voice-recovery-the-first-onset-is-what-is-measured ()
  "A later onset cannot move the window, and an earlier one is not taken.
The first speech after the submission is the continuation's beginning."
  (let* ((record (harness-ui-voice-recovery-test--record))
         (first (harness-voice-recovery-onset record "u-2" 100.4))
         (second (harness-voice-recovery-onset first "u-3" 100.9)))
    (should (= 100.4 (plist-get second :onset)))
    (should (equal "u-2" (plist-get second :onset-source)))
    ;; Speech reported before the submission is not resumed speech.
    (should-not (plist-get (harness-voice-recovery-onset record "u-2" 99.0) :onset))))

(ert-deftest harness-ui-voice-recovery-the-messages-own-capture-is-not-resumed-speech ()
  "The captions of the submitted utterance never trigger a recovery.
The sidecar reports onset and captions for the burst being transcribed;
those are the message itself, not the person going on."
  (let ((record (harness-ui-voice-recovery-test--record)))
    (should-not (plist-get (harness-voice-recovery-onset record "u-1" 100.2) :onset))
    (should (equal '(ignore . same-capture)
                   (harness-voice-recovery-trigger
                    record "Please document the parser" '(:source "u-1" :now 100.2 :window 0.6))))))

;;;; Accepted words only

(ert-deftest harness-ui-voice-recovery-empty-and-noise-never-trigger ()
  "No words, no recovery: an empty transcription, spaces, punctuation and
a tick of the microphone are not speech, and neither is a reading the
provider is unsure of.  None of them cancels anything."
  (let* ((record (harness-ui-voice-recovery-test--record))
         (onset (harness-voice-recovery-onset record "u-2" 100.2)))
    (dolist (text '("" "   " "\n\t" "." "…" "?!," "♪" "—" "-" "🙂"))
      (should (equal '(ignore . empty)
                     (harness-voice-recovery-trigger
                      onset text '(:source "u-2" :now 100.2 :window 0.6)))))
    (should (equal '(ignore . unsure)
                   (harness-voice-recovery-trigger
                    onset "in file.py" '(:source "u-2" :now 100.2 :window 0.6
                                                 :certainty "unsure"))))
    ;; The record is still armed, and the turn is untouched.
    (should (harness-voice-recovery-armed-p onset))
    ;; A real word is accepted at once -- no complete sentence is needed.
    (dolist (text '("in" "and" "the" "file.py" "its"))
      (should (eq 'trigger (car (harness-voice-recovery-trigger
                                 onset text '(:source "u-2" :now 100.2 :window 0.6))))))))

(ert-deftest harness-ui-voice-recovery-finished-and-recovering-records-ignore-words ()
  "A record already taken back, or finished, cannot be taken back again.
Out-of-order captions of the same thought are not a second recovery."
  (let* ((record (harness-ui-voice-recovery-test--record))
         (recovering (cdr (harness-voice-recovery-trigger
                           record "in file.py" '(:source "u-2" :now 100.2 :window 0.6))))
         (done (harness-voice-recovery-finish recovering 'done)))
    (should (equal '(ignore . already-recovering)
                   (harness-voice-recovery-trigger
                    recovering "and its errors" '(:source "u-3" :now 100.3 :window 0.6))))
    (should (equal '(ignore . finished)
                   (harness-voice-recovery-trigger
                    done "and its errors" '(:source "u-3" :now 100.3 :window 0.6))))
    (should (equal '(ignore . already-recovering)
                   (harness-voice-recovery-trigger
                    (harness-voice-recovery-abandon record "retargeted")
                    "and its errors" '(:source "u-3" :now 100.3 :window 0.6))))))

;;;; The combined thought

(ert-deftest harness-ui-voice-recovery-combines-original-and-continuation ()
  "The thought is the original words and the continuations, in order, once.
Successive premature endpoints add their own words without a repeat, and
the original is never dropped."
  (let ((record (harness-ui-voice-recovery-test--record)))
    (should (equal "Please document the parser in file.py"
                   (harness-voice-recovery-combined record '(("u-2" . "in file.py")))))
    (should (equal "Please document the parser in file.py and its error cases"
                   (harness-voice-recovery-combined
                    record '(("u-2" . "in file.py") ("u-3" . "and its error cases")))))
    (should (equal "Please document the parser"
                   (harness-voice-recovery-combined
                    record '(("u-2" . "") ("u-3" . " ") ("u-4" . "…")))))))

(ert-deftest harness-ui-voice-recovery-revises-a-partial-without-reordering ()
  "A revised transcript replaces its own words where they were said.
A partial that arrives again with more words is one utterance, not two,
and an out-of-order pair keeps the order the speech had."
  (let ((record (harness-ui-voice-recovery-test--record)))
    (should (equal "Please document the parser in file.py now"
                   (harness-voice-recovery-combined
                    record '(("u-2" . "in file") ("u-3" . "now")
                             ("u-2" . "in file.py")))))
    ;; The transport hands the continuations in onset order; a source's
    ;; revision does not move it, and a repeat is not a second phrase.
    (should (equal "Please document the parser in file.py and its errors"
                   (harness-voice-recovery-combined
                    record '(("u-2" . "in file") ("u-3" . "and its errors")
                             ("u-2" . "in file.py")))))))

(ert-deftest harness-ui-voice-recovery-draft-restores-only-what-the-history-lacks ()
  "A rewind puts the original words back in the draft; a kept history does not.
A history that kept the message already holds the thought, so the next
message is the continuation alone, and the person's words are never said
twice."
  (let ((record (harness-ui-voice-recovery-test--record)))
    (should (equal (plist-get record :items)
                   (harness-voice-recovery-draft record '(:action rewind :draft t))))
    (should (equal (plist-get record :items)
                   (harness-voice-recovery-draft record '(:action intact :draft t))))
    (should-not (harness-voice-recovery-draft record '(:action append :draft nil)))))

;;;; The history

(ert-deftest harness-ui-voice-recovery-plans-a-rewind-to-before-the-message ()
  "A message the turn left unanswered and tool-free is rewound away.
The head goes to the node before the voice message; the answer the
cancelled turn wrote stays on its own branch of the tree."
  (let* ((record (harness-ui-voice-recovery-test--record))
         (plan (harness-voice-recovery-plan
                record (harness-ui-voice-recovery-test--conversation))))
    (should (equal 'rewind (plist-get plan :action)))
    (should (equal "u-1" (plist-get plan :node)))
    (should (equal "a-0" (plist-get plan :head)))
    (should (equal "History · rewound" (harness-voice-recovery-plan-line plan)))))

(ert-deftest harness-ui-voice-recovery-keeps-a-history-with-tool-calls ()
  "A rewind cannot undo a tool's side effects, so a turn that ran one keeps its history.
Only the continuation is added; the transcript says why the history was
kept, and the answer stays where it is."
  (let* ((record (harness-ui-voice-recovery-test--record))
         (plan (harness-voice-recovery-plan
                record (harness-ui-voice-recovery-test--conversation t))))
    (should (equal 'append (plist-get plan :action)))
    (should (equal "tool calls" (plist-get plan :why)))
    (should (equal "History · kept · tool calls" (harness-voice-recovery-plan-line plan)))
    (should-not (plist-get plan :head))))

(ert-deftest harness-ui-voice-recovery-keeps-a-history-a-later-message-followed ()
  "A message typed after the voice turn is never rewound away.
Rewinding would drop something the person wrote and meant."
  (let* ((record (harness-ui-voice-recovery-test--record))
         (plan (harness-voice-recovery-plan
                record (harness-ui-voice-recovery-test--conversation nil t))))
    (should (equal 'append (plist-get plan :action)))
    (should (equal "later message" (plist-get plan :why)))))

(ert-deftest harness-ui-voice-recovery-an-unrecorded-message-needs-no-rewind ()
  "A message the transcript does not hold left the head where it was.
Nothing is rewound and the original words go back in the draft, so the
next turn is the whole thought."
  (let* ((record (harness-ui-voice-recovery-test--record :submitted 200.0))
         (plan (harness-voice-recovery-plan
                record (harness-ui-voice-recovery-test--conversation))))
    (should (equal 'intact (plist-get plan :action)))
    (should (equal "no message" (plist-get plan :why)))
    (should (equal "History · unchanged" (harness-voice-recovery-plan-line plan)))
    (should (equal (plist-get record :items)
                   (harness-voice-recovery-draft record plan)))))

(ert-deftest harness-ui-voice-recovery-an-unreadable-transcript-keeps-the-words ()
  "Without the transcript there is nothing to rewind, and no guessing.
The history stays untouched, and the original words stay in the draft:
a thought lost is worse than a request made twice."
  (let* ((record (harness-ui-voice-recovery-test--record))
         (plan (harness-voice-recovery-plan record nil)))
    (should (equal 'intact (plist-get plan :action)))
    (should (equal "no transcript" (plist-get plan :why)))
    (should (equal (plist-get record :items)
                   (harness-voice-recovery-draft record plan)))))

(ert-deftest harness-ui-voice-recovery-a-first-message-has-nothing-to-rewind-to ()
  "The very first message of a conversation has no earlier node.
The history is kept, since moving the head to nothing is not a rewind."
  (let* ((record (harness-ui-voice-recovery-test--record))
         (plan (harness-voice-recovery-plan
                record (list (harness-ui-voice-recovery-test--node
                              "u-1" 'user 100.5 :content "Please document the parser")))))
    (should (equal 'append (plist-get plan :action)))
    (should (equal "no earlier message" (plist-get plan :why)))))

;;;; Evidence

(ert-deftest harness-ui-voice-recovery-keeps-what-it-decided-as-evidence ()
  "The recovery keeps its timing and its decision, in order, for the transcript.
The evidence is how a recovery is audited after the fact: which measure
was used, how long it was, and what the history allowed."
  (let* ((record (harness-ui-voice-recovery-test--record))
         (onset (harness-voice-recovery-onset record "u-2" 100.15))
         (taken (cdr (harness-voice-recovery-trigger
                      onset "in file.py" '(:source "u-2" :now 100.9 :window 0.6))))
         (plan (harness-voice-recovery-plan
                taken (harness-ui-voice-recovery-test--conversation)))
         (noted (harness-voice-recovery-note taken (harness-voice-recovery-plan-line plan))))
    (should (equal '("Resumed speech · 150ms · onset" "History · rewound")
                   (harness-voice-recovery-evidence noted)))
    (should (equal "Not recovered · retargeted"
                   (car (harness-voice-recovery-evidence
                         (harness-voice-recovery-abandon record "retargeted")))))))

(provide 'harness-ui-voice-recovery-test)
;;; harness-ui-voice-recovery-test.el ends here
