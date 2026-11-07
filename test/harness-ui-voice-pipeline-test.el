;;; harness-ui-voice-pipeline-test.el --- The voice pipeline's state and words  -*- lexical-binding: t; -*-

;;; Commentary:

;; The pipeline's model and its drawing, driven by scripted events: no
;; microphone, sidecar, speech model or network.  The live module's own
;; suite (harness-ui-voice-live-test) covers the protocol that feeds it.
;; The assertions on words are exact, so a change of copy is a change of
;; test: they are the inventory of what this surface says.

;;; Code:

(require 'ert)
(require 'harness-test-helpers)
(require 'harness-ui-voice-pipeline)

(defconst harness-ui-voice-pipeline-test--now 1000.0
  "The time the tests measure levels against.")

(defun harness-ui-voice-pipeline-test--pipeline (&optional capture)
  "Return a pipeline in CAPTURE, with a level at the tests' time."
  (let ((pipeline (harness-voice-pipeline-create (or capture 'live))))
    (harness-voice-pipeline-set-level pipeline 0.56
                                      harness-ui-voice-pipeline-test--now)
    pipeline))

(defun harness-ui-voice-pipeline-test--block (pipeline &optional width now)
  "Return PIPELINE's block as plain text."
  (string-join (mapcar #'substring-no-properties
                       (harness-voice-pipeline-block
                        pipeline (or width 120)
                        (or now harness-ui-voice-pipeline-test--now)))
               "\n"))

(defun harness-ui-voice-pipeline-test--lines (pipeline &optional width now)
  "Return PIPELINE's wide strip as plain text."
  (string-join
   (mapcar #'substring-no-properties
           (harness-voice-pipeline-lines pipeline (or width 120)
                                          (or now harness-ui-voice-pipeline-test--now)))
   "\n"))

(defun harness-ui-voice-pipeline-test--compact (pipeline &optional room now)
  "Return PIPELINE's compact line as plain text."
  (substring-no-properties
   (harness-voice-pipeline-compact-line pipeline (or room 100)
                                        (or now harness-ui-voice-pipeline-test--now))))

;;;; The capture

(ert-deftest harness-ui-voice-pipeline-capture-and-level-words ()
  "Every capture state and the level have exact words."
  (let ((pipeline (harness-voice-pipeline-create 'off)))
    (dolist (case '((off . "Mic · off") (connecting . "Mic · connecting")
                    (live . "Mic · live") (muted . "Mic · muted")
                    (paused . "Mic · paused") (failed . "Mic · failed")
                    (disconnected . "Mic · disconnected") (ended . "Mic · ended")))
      (harness-voice-pipeline-set-capture pipeline (car case))
      (should (equal (cdr case) (harness-voice-pipeline-capture-label pipeline))))))

(ert-deftest harness-ui-voice-pipeline-level-is-a-measurement ()
  "A level is drawn only when the capture path sent one, and it goes stale."
  (let ((pipeline (harness-voice-pipeline-create 'live))
        (now 100.0))
    ;; No telemetry yet: not a quiet room.
    (should (equal "Level · no data" (harness-voice-pipeline-level-label pipeline now)))
    (should (equal "········" (harness-voice-pipeline-meter pipeline 8 now)))
    (harness-voice-pipeline-set-level pipeline 0.56 now)
    (should (equal "Level · 56%" (harness-voice-pipeline-level-label pipeline now)))
    (should (equal "████▃···" (harness-voice-pipeline-meter pipeline 8 now)))
    ;; An old level is no data, not the last reading forever.
    (should (equal "Level · no data"
                   (harness-voice-pipeline-level-label pipeline (+ now 3))))
    (should (equal "········" (harness-voice-pipeline-meter pipeline 8 (+ now 3))))
    ;; Out of range and non-numeric values change nothing.
    (harness-voice-pipeline-set-level pipeline 1.5 (+ now 4))
    (harness-voice-pipeline-set-level pipeline "loud" (+ now 4))
    (should (equal "Level · 56%" (harness-voice-pipeline-level-label pipeline now)))
    ;; A closed microphone says it has no data, whatever the last level was.
    (harness-voice-pipeline-set-capture pipeline 'muted)
    (should (equal "Level · no data" (harness-voice-pipeline-level-label pipeline now)))))

(ert-deftest harness-ui-voice-pipeline-gate-and-counts ()
  "The gate and the kept and dropped counts have exact words."
  (let ((pipeline (harness-ui-voice-pipeline-test--pipeline)))
    (should-not (harness-voice-pipeline-gate-label pipeline))
    (should-not (harness-voice-pipeline-count-label pipeline))
    (harness-voice-pipeline-set-gate pipeline t)
    (should (equal "Speech · heard" (harness-voice-pipeline-gate-label pipeline)))
    (harness-voice-pipeline-segment pipeline "u-1" 'accepted '(:seconds 1.4))
    (should (equal "1 accepted" (harness-voice-pipeline-count-label pipeline)))
    (harness-voice-pipeline-segment pipeline "u-2" 'dropped '(:seconds 0.08 :reason too-short))
    (should (equal "1 accepted · 1 dropped"
                   (harness-voice-pipeline-count-label pipeline)))
    (harness-voice-pipeline-segment pipeline "u-3" 'accepted '(:seconds 0.4))
    (should (equal "2 accepted · 1 dropped"
                   (harness-voice-pipeline-count-label pipeline)))
    ;; A state that is not live closes the gate: the path is not hearing
    ;; anything it could report.
    (harness-voice-pipeline-set-capture pipeline 'muted)
    (should (equal "Mic · muted" (harness-voice-pipeline-capture-label pipeline)))
    (should-not (harness-voice-pipeline-gate-label pipeline))))

;;;; The bursts

(ert-deftest harness-ui-voice-pipeline-segments-move-forward-only ()
  "A kept burst advances on real events, and a terminal one never moves."
  (let ((pipeline (harness-ui-voice-pipeline-test--pipeline)))
    (harness-voice-pipeline-segment pipeline "u-1" 'accepted '(:seconds 1.4))
    (should (equal 'accepted (plist-get (car (harness-voice-pipeline-segments pipeline)) :stage)))
    ;; A duplicate and a late earlier stage change nothing.
    (harness-voice-pipeline-segment pipeline "u-1" 'accepted '(:seconds 1.4))
    (should (= 1 (harness-voice-pipeline-ignored pipeline)))
    (harness-voice-pipeline-segment pipeline "u-1" 'transcribing)
    (should (equal 'transcribing (plist-get (car (harness-voice-pipeline-segments pipeline)) :stage)))
    (harness-voice-pipeline-segment pipeline "u-1" 'accepted)
    (should (equal 'transcribing (plist-get (car (harness-voice-pipeline-segments pipeline)) :stage)))
    (harness-voice-pipeline-segment pipeline "u-1" 'transcribed '(:text "Add a docstring."))
    (should (equal 'transcribed (plist-get (car (harness-voice-pipeline-segments pipeline)) :stage)))
    (should (equal "Add a docstring."
                   (plist-get (car (harness-voice-pipeline-segments pipeline)) :text)))
    (harness-voice-pipeline-segment pipeline "u-1" 'accepted)
    (should (equal 'transcribed (plist-get (car (harness-voice-pipeline-segments pipeline)) :stage)))
    (harness-voice-pipeline-segment pipeline "u-1" 'in-turn)
    (should (equal 'in-turn (plist-get (car (harness-voice-pipeline-segments pipeline)) :stage)))
    (harness-voice-pipeline-segment pipeline "u-1" 'answered)
    (should (equal 'answered (plist-get (car (harness-voice-pipeline-segments pipeline)) :stage)))
    (let ((ignored (harness-voice-pipeline-ignored pipeline)))
      (harness-voice-pipeline-segment pipeline "u-1" 'in-turn)
      (harness-voice-pipeline-segment pipeline "u-1" 'transcribing)
      (harness-voice-pipeline-segment pipeline "u-1" 'dropped '(:reason cancelled))
      (should (equal 'answered
                     (plist-get (car (harness-voice-pipeline-segments pipeline)) :stage)))
      (should (= (+ ignored 3) (harness-voice-pipeline-ignored pipeline))))))

(ert-deftest harness-ui-voice-pipeline-segment-arriving-late-shows-where-it-is ()
  "A transcription whose acceptance was lost shows the real stage."
  (let ((pipeline (harness-ui-voice-pipeline-test--pipeline)))
    (harness-voice-pipeline-segment pipeline "u-1" 'transcribing)
    (should (equal 'transcribing (plist-get (car (harness-voice-pipeline-segments pipeline)) :stage)))
    ;; It was a kept burst all along, and is counted once.
    (should (= 1 (harness-voice-pipeline-accepted pipeline)))
    (harness-voice-pipeline-segment pipeline "u-1" 'accepted)
    (should (= 1 (harness-voice-pipeline-accepted pipeline)))
    (should (equal 'transcribing (plist-get (car (harness-voice-pipeline-segments pipeline)) :stage)))))

(ert-deftest harness-ui-voice-pipeline-drops-carry-their-reason ()
  "A dropped burst is drawn with the filter's own measurement and reason."
  (let ((pipeline (harness-ui-voice-pipeline-test--pipeline)))
    (harness-voice-pipeline-segment pipeline "u-1" 'accepted '(:seconds 1.4))
    (harness-voice-pipeline-segment pipeline "u-2" 'dropped '(:seconds 0.08 :reason too-short))
    (let ((segment (car (harness-voice-pipeline-segments pipeline))))
      (should (equal 'dropped (plist-get segment :stage)))
      (should (equal 'too-short (plist-get segment :reason))))
    (should (equal "u-2 · dropped · 80ms · too short"
                   (substring-no-properties
                    (harness-voice-pipeline-segment-line
                     (car (harness-voice-pipeline-segments pipeline))))))
    ;; A kept burst whose transcript was empty is dropped afterwards, and
    ;; the totals keep both facts.
    (harness-voice-pipeline-segment pipeline "u-1" 'dropped '(:reason no-words))
    (should (equal 'dropped (plist-get (harness-voice-pipeline--segment pipeline "u-1") :stage)))
    (should (equal "2 dropped" (format "%d dropped" (harness-voice-pipeline-dropped pipeline))))))

(ert-deftest harness-ui-voice-pipeline-failures-are-not-drops ()
  "A failed burst is its own stage and its own word."
  (let ((pipeline (harness-ui-voice-pipeline-test--pipeline)))
    (harness-voice-pipeline-segment pipeline "u-1" 'accepted '(:seconds 1.2))
    (harness-voice-pipeline-segment pipeline "u-1" 'failed '(:reason failed))
    (should (equal 'failed (plist-get (harness-voice-pipeline--segment pipeline "u-1") :stage)))
    (should (= 1 (harness-voice-pipeline-accepted pipeline)))
    (should (= 0 (harness-voice-pipeline-dropped pipeline)))))

(ert-deftest harness-ui-voice-pipeline-keeps-a-bounded-history ()
  "The strip keeps the newest markers; the totals keep counting."
  (let ((pipeline (harness-ui-voice-pipeline-test--pipeline))
        (harness-voice-pipeline-segments 3))
    (dotimes (index 6)
      (harness-voice-pipeline-segment pipeline (format "u-%d" index) 'accepted
                                      (list :seconds 0.5)))
    (should (= 3 (length (harness-voice-pipeline-segments pipeline))))
    (should (= 6 (harness-voice-pipeline-accepted pipeline)))
    (should (equal "u-5" (plist-get (car (harness-voice-pipeline-segments pipeline)) :id)))))

;;;; The turns

(ert-deftest harness-ui-voice-pipeline-turns-move-forward-only ()
  "A turn goes from queued to working to replied to done, never back."
  (let ((pipeline (harness-ui-voice-pipeline-test--pipeline)))
    (harness-voice-pipeline-turn pipeline "d-1" 'queued '(:segment "u-1"))
    (should (equal "Turn · queued" (harness-voice-pipeline-turn-label pipeline)))
    (harness-voice-pipeline-turn pipeline "d-1" 'working)
    (should (equal "Turn · working" (harness-voice-pipeline-turn-label pipeline)))
    (harness-voice-pipeline-turn pipeline "d-1" 'replied '(:reply "n-1"))
    (should (equal "Turn · replied" (harness-voice-pipeline-turn-label pipeline)))
    (harness-voice-pipeline-turn pipeline "d-1" 'done)
    (should (equal "Turn · done" (harness-voice-pipeline-turn-label pipeline)))
    (let ((ignored (harness-voice-pipeline-ignored pipeline)))
      (harness-voice-pipeline-turn pipeline "d-1" 'working)
      (should (equal "Turn · done" (harness-voice-pipeline-turn-label pipeline)))
      (should (= (1+ ignored) (harness-voice-pipeline-ignored pipeline))))
    (should (equal "d-1 · done · 1 utterance · 1 reply"
                   (substring-no-properties
                    (harness-voice-pipeline-turn-line
                     (car (harness-voice-pipeline-turns pipeline))))))))

(ert-deftest harness-ui-voice-pipeline-turn-takes-several-utterances ()
  "Several utterances can feed one turn, and one turn several replies."
  (let ((pipeline (harness-ui-voice-pipeline-test--pipeline)))
    (harness-voice-pipeline-turn pipeline "d-1" 'working '(:segment "u-1"))
    (harness-voice-pipeline-turn pipeline "d-1" 'working '(:segment "u-2"))
    (harness-voice-pipeline-turn pipeline "d-1" 'replied '(:reply "n-1"))
    (harness-voice-pipeline-turn pipeline "d-1" 'replied '(:reply "n-2"))
    (let ((turn (car (harness-voice-pipeline-turns pipeline))))
      (should (equal '("u-1" "u-2") (plist-get turn :segments)))
      (should (equal '("n-1" "n-2") (plist-get turn :replies))))
    (should (equal "d-1 · replied · 2 utterances · 2 replies"
                   (substring-no-properties
                    (harness-voice-pipeline-turn-line
                     (car (harness-voice-pipeline-turns pipeline))))))))

(ert-deftest harness-ui-voice-pipeline-failed-turn-says-so ()
  "A failed turn is a terminal stage with its own word."
  (let ((pipeline (harness-ui-voice-pipeline-test--pipeline)))
    (harness-voice-pipeline-turn pipeline "d-1" 'working '(:segment "u-1"))
    (harness-voice-pipeline-turn pipeline "d-1" 'failed '(:detail "Agent turn failed"))
    (should (equal "Turn · failed" (harness-voice-pipeline-turn-label pipeline)))
    (let ((ignored (harness-voice-pipeline-ignored pipeline)))
      (harness-voice-pipeline-turn pipeline "d-1" 'done)
      (should (= (1+ ignored) (harness-voice-pipeline-ignored pipeline))))
    (should (string-search "Agent turn failed"
                           (substring-no-properties
                            (harness-voice-pipeline-turn-line
                             (car (harness-voice-pipeline-turns pipeline))))))))

;;;; The speaker

(ert-deftest harness-ui-voice-pipeline-speaker-states-are-distinct ()
  "Ready, held, handed, speaking and spoken are five different facts."
  (let ((pipeline (harness-ui-voice-pipeline-test--pipeline)))
    (should (equal "Speaker · silent" (harness-voice-pipeline-speaker-label pipeline)))
    (harness-voice-pipeline-reply pipeline "n-1" 'ready '(:turn "d-1" :text "The docstring."))
    (should (equal "Speaker · ready" (harness-voice-pipeline-speaker-label pipeline)))
    (harness-voice-pipeline-reply pipeline "n-1" 'held)
    (should (equal "Speaker · held" (harness-voice-pipeline-speaker-label pipeline)))
    (harness-voice-pipeline-reply pipeline "n-1" 'handed)
    (should (equal "Speaker · handed" (harness-voice-pipeline-speaker-label pipeline)))
    ;; The provider reported playback: that is speaking, and only that.
    (harness-voice-pipeline-reply pipeline "n-1" 'speaking)
    (should (equal "Speaker · speaking" (harness-voice-pipeline-speaker-label pipeline)))
    (harness-voice-pipeline-reply pipeline "n-1" 'spoken)
    (should (equal "Speaker · silent" (harness-voice-pipeline-speaker-label pipeline)))))

(ert-deftest harness-ui-voice-pipeline-handed-is-not-speaking ()
  "A reply handed to the provider that never played stays handed."
  (let ((pipeline (harness-ui-voice-pipeline-test--pipeline)))
    (harness-voice-pipeline-reply pipeline "n-1" 'handed)
    ;; The playback stopped without ever reporting that it started.
    (harness-voice-pipeline-finish-replies pipeline 'dropped "ended")
    (should (not (string-search "speaking" (harness-voice-pipeline-speaker-label pipeline))))))

(ert-deftest harness-ui-voice-pipeline-stale-playback-cannot-resurrect ()
  "An interrupted reply stays interrupted; a late event changes nothing."
  (let ((pipeline (harness-ui-voice-pipeline-test--pipeline)))
    (harness-voice-pipeline-reply pipeline "n-1" 'handed)
    (harness-voice-pipeline-reply pipeline "n-1" 'speaking)
    (harness-voice-pipeline-finish-replies pipeline 'interrupted "interrupted")
    (should (equal "Speaker · interrupted" (harness-voice-pipeline-speaker-label pipeline)))
    (let ((ignored (harness-voice-pipeline-ignored pipeline)))
      (harness-voice-pipeline-reply pipeline "n-1" 'speaking)
      (harness-voice-pipeline-reply pipeline "n-1" 'spoken)
      (should (equal "Speaker · interrupted"
                     (harness-voice-pipeline-speaker-label pipeline)))
      (should (= (+ ignored 2) (harness-voice-pipeline-ignored pipeline))))))

(ert-deftest harness-ui-voice-pipeline-speaking-wins-over-handed ()
  "One reply playing is speaking, even while a newer one is only handed."
  (let ((pipeline (harness-ui-voice-pipeline-test--pipeline)))
    (harness-voice-pipeline-reply pipeline "n-1" 'handed)
    (harness-voice-pipeline-reply pipeline "n-2" 'handed)
    (harness-voice-pipeline-reply pipeline "n-1" 'speaking)
    (should (equal "Speaker · speaking" (harness-voice-pipeline-speaker-label pipeline)))))

;;;; The generations

(ert-deftest harness-ui-voice-pipeline-stale-generation-changes-nothing ()
  "An event that names an earlier conversation changes nothing here."
  (let ((pipeline (harness-ui-voice-pipeline-test--pipeline)))
    (harness-voice-pipeline-segment pipeline "u-1" 'accepted '(:seconds 1.0))
    (let ((generation (harness-voice-pipeline-generation pipeline)))
      (harness-voice-pipeline-bump pipeline 'connecting)
      (harness-voice-pipeline-segment pipeline "u-2" 'accepted
                                      (list :generation generation))
      (harness-voice-pipeline-turn pipeline "d-1" 'working
                                   (list :generation generation))
      (harness-voice-pipeline-reply pipeline "n-1" 'ready
                                    (list :generation generation))
      (harness-voice-pipeline-set-level pipeline 0.9 nil generation)
      (harness-voice-pipeline-set-gate pipeline t generation)
      (should-not (harness-voice-pipeline-segments pipeline))
      (should-not (harness-voice-pipeline-turns pipeline))
      (should-not (harness-voice-pipeline-replies pipeline))
      (should-not (harness-voice-pipeline-level-seen pipeline))
      (should-not (harness-voice-pipeline-gate pipeline))
      (should (equal "Mic · connecting" (harness-voice-pipeline-capture-label pipeline))))))

(ert-deftest harness-ui-voice-pipeline-nothing-advances-on-a-clock ()
  "Waiting is shown as waiting: time alone moves no marker."
  (let ((pipeline (harness-ui-voice-pipeline-test--pipeline)))
    (harness-voice-pipeline-segment pipeline "u-1" 'accepted '(:seconds 1.2))
    (harness-voice-pipeline-segment pipeline "u-1" 'transcribing)
    (harness-voice-pipeline-turn pipeline "d-1" 'working '(:segment "u-1"))
    (harness-voice-pipeline-reply pipeline "n-1" 'handed)
    ;; A century of waiting changes nothing: no event, no movement.
    (let ((later (+ harness-ui-voice-pipeline-test--now (* 100 365 24 3600))))
      (should (equal 'transcribing (plist-get (car (harness-voice-pipeline-segments pipeline)) :stage)))
      (should (equal "Turn · working" (harness-voice-pipeline-turn-label pipeline)))
      (should (equal "Speaker · handed" (harness-voice-pipeline-speaker-label pipeline)))
      (should (equal "Level · no data"
                     (harness-voice-pipeline-level-label pipeline later))))))

;;;; The words

(ert-deftest harness-ui-voice-pipeline-summary-copy ()
  "The summary line carries every fact, with exact copy."
  (let ((pipeline (harness-ui-voice-pipeline-test--pipeline)))
    (should (equal "Mic · live · Level · 56% · Speaker · silent"
                   (substring-no-properties
                    (harness-voice-pipeline-summary pipeline harness-ui-voice-pipeline-test--now))))
    (harness-voice-pipeline-set-gate pipeline t)
    (harness-voice-pipeline-segment pipeline "u-1" 'accepted '(:seconds 1.4))
    (harness-voice-pipeline-segment pipeline "u-2" 'dropped '(:seconds 0.08 :reason too-short))
    (harness-voice-pipeline-turn pipeline "d-1" 'working '(:segment "u-1"))
    (harness-voice-pipeline-reply pipeline "n-1" 'speaking)
    (should (equal (concat "Mic · live · Level · 56% · Speech · heard · 1 accepted"
                           " · 1 dropped · Turn · working · Speaker · speaking")
                   (substring-no-properties
                    (harness-voice-pipeline-summary pipeline harness-ui-voice-pipeline-test--now))))
    (should (equal (concat "Mic · live · 1 accepted · 1 dropped"
                           " · Turn · working · Speaker · speaking")
                   (substring-no-properties
                    (harness-voice-pipeline-short-summary pipeline))))
    ;; The backend's own words about a failure are data, not new copy.
    (harness-voice-pipeline-set-capture pipeline 'failed "Microphone permission denied")
    (should (string-search "Microphone permission denied"
                           (substring-no-properties
                            (harness-voice-pipeline-summary pipeline))))))

(ert-deftest harness-ui-voice-pipeline-details-copy ()
  "Every marker is a line of words; an empty pipe says so."
  (let ((pipeline (harness-ui-voice-pipeline-test--pipeline)))
    (should (equal '("No segments yet") (harness-voice-pipeline-details pipeline)))
    (harness-voice-pipeline-segment pipeline "u-1" 'accepted '(:seconds 1.4))
    (harness-voice-pipeline-segment pipeline "u-1" 'transcribed '(:text "Add a docstring to parse."))
    (harness-voice-pipeline-segment pipeline "u-2" 'dropped '(:seconds 0.08 :reason too-short))
    (harness-voice-pipeline-turn pipeline "d-1" 'working '(:segment "u-1"))
    (harness-voice-pipeline-reply pipeline "n-1" 'handed '(:turn "d-1"))
    (should (equal '("u-2 · dropped · 80ms · too short"
                     "u-1 · transcribed · 1.4s · \"Add a docstring to parse.\""
                     "d-1 · working · 1 utterance"
                     "n-1 · handed · d-1")
                   (mapcar #'substring-no-properties
                           (harness-voice-pipeline-details pipeline))))))

;;;; The drawing

(ert-deftest harness-ui-voice-pipeline-wide-strip ()
  "The wide strip names its five columns and their facts."
  (let ((pipeline (harness-ui-voice-pipeline-test--pipeline)))
    (harness-voice-pipeline-set-gate pipeline t)
    (harness-voice-pipeline-segment pipeline "u-1" 'accepted '(:seconds 1.4))
    (harness-voice-pipeline-segment pipeline "u-1" 'transcribed '(:text "Add a docstring."))
    (harness-voice-pipeline-turn pipeline "d-1" 'working '(:segment "u-1"))
    (harness-voice-pipeline-reply pipeline "n-1" 'handed)
    (let ((strip (harness-ui-voice-pipeline-test--lines pipeline)))
      (dolist (word '("Input" "Filter" "Words" "Turn" "Speaker"
                      "Level · 56%" "Mic · live" "Speech · heard"
                      "● 1 accepted" "≡ transcribed · 1.4s" "⋯ working"
                      "1 utterance" "→ handed"))
        (should (string-search word strip)))
      ;; The words are in columns, not one line per fact, when they fit.
      (should (= 3 (length (split-string strip "\n"))))
      ;; Every column heading says what its data is.
      (let ((headings (harness-voice-pipeline-columns
                       pipeline harness-ui-voice-pipeline-test--now)))
        (should (equal '("Input" "Filter" "Words" "Turn" "Speaker")
                       (mapcar #'car headings)))
        (should (equal "Microphone level before the speech filter"
                       (nth 1 (nth 0 headings))))
        (should (equal "Speech kept for transcription" (nth 1 (nth 1 headings))))
        (should (equal "Speech to text" (nth 1 (nth 2 headings))))
        (should (equal "Agent work" (nth 1 (nth 3 headings))))
        (should (equal "Playback" (nth 1 (nth 4 headings))))))))

(ert-deftest harness-ui-voice-pipeline-narrow-strip-keeps-every-fact ()
  "A narrow window stacks the columns instead of losing them."
  (let ((pipeline (harness-ui-voice-pipeline-test--pipeline)))
    (harness-voice-pipeline-segment pipeline "u-1" 'accepted '(:seconds 1.4))
    (harness-voice-pipeline-segment pipeline "u-2" 'dropped '(:seconds 0.08 :reason too-short))
    (let ((strip (harness-ui-voice-pipeline-test--lines pipeline 40)))
      (should (= 5 (length (split-string strip "\n"))))
      (dolist (word '("Input · " "Filter · " "Words · " "Turn · " "Speaker · "
                      "1 accepted" "1 dropped"))
        (should (string-search word strip))))))

(ert-deftest harness-ui-voice-pipeline-block-copy ()
  "The block is the title, the strip and the summary, in that order."
  (let ((pipeline (harness-ui-voice-pipeline-test--pipeline)))
    (harness-voice-pipeline-segment pipeline "u-1" 'accepted '(:seconds 1.4))
    (let ((block (harness-ui-voice-pipeline-test--block pipeline)))
      (should (string-prefix-p "Pipeline\n" block))
      (should (string-search "Mic · live · Level · 56% · 1 accepted · Speaker · silent"
                             block)))))

(ert-deftest harness-ui-voice-pipeline-compact-line-copy ()
  "The compact line carries the meter and the facts, and fits its room."
  (let ((pipeline (harness-ui-voice-pipeline-test--pipeline)))
    (harness-voice-pipeline-segment pipeline "u-1" 'accepted '(:seconds 1.4))
    (harness-voice-pipeline-turn pipeline "d-1" 'working '(:segment "u-1"))
    (harness-voice-pipeline-reply pipeline "n-1" 'speaking)
    (should (equal (concat " Pipeline · ██▂· Level · 56% · 1 accepted"
                           " · Turn · working · Speaker · speaking")
                   (harness-ui-voice-pipeline-test--compact pipeline 100)))
    ;; A narrow room drops the least important facts first, and says so
    ;; with the control that shows them.
    (let ((narrow (harness-ui-voice-pipeline-test--compact pipeline 45)))
      (should (string-search "Pipeline" narrow))
      (should (string-search "Speaker · speaking" narrow))
      (should (string-search "…" narrow)))))

(ert-deftest harness-ui-voice-pipeline-every-stage-has-a-word ()
  "Each stage, reply stage and drop reason has its exact word."
  (dolist (case '((accepted . "accepted") (transcribing . "transcribing")
                  (transcribed . "transcribed") (in-turn . "in turn")
                  (answered . "answered") (dropped . "dropped") (failed . "failed")))
    (should (equal (cdr case) (harness-voice-pipeline--stage-label (car case)))))
  (dolist (case '((ready . "ready") (held . "held") (handed . "handed")
                  (speaking . "speaking") (spoken . "spoken")
                  (interrupted . "interrupted") (dropped . "dropped")
                  (failed . "failed")))
    (should (equal (cdr case) (harness-voice-pipeline--reply-label (car case)))))
  (dolist (case '((too-short . "too short") (no-words . "no words")
                  (cancelled . "cancelled") (failed . "failed")))
    (should (equal (cdr case) (harness-voice-pipeline--drop-label (car case)))))
  (dolist (case '((queued . "queued") (working . "working") (replied . "replied")
                  (done . "done") (failed . "failed") (cancelled . "cancelled")))
    (should (equal (cdr case) (harness-voice-pipeline--turn-label (car case))))))

(provide 'harness-ui-voice-pipeline-test)
;;; harness-ui-voice-pipeline-test.el ends here
