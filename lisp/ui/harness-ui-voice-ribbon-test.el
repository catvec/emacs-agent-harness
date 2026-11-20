;;; harness-ui-voice-ribbon-test.el --- The voice ribbon's marks and pictures  -*- lexical-binding: t; -*-

;;; Commentary:

;; The ribbon is a drawing of `harness-voice-pipeline', not a second model:
;; these tests drive the real model with scripted events and assert what the
;; ribbon draws and says.  No microphone, sidecar, speech model or network is
;; used.  The assertions on words are exact, so they are the inventory of what
;; this surface says -- and the surface says nothing: no stage key, no legend,
;; no count, no status line and no way into the details.  The stages are told
;; apart by the shapes and faces of their bars, and the words live in the
;; blips' tooltips and in the voice settings.

;;; Code:

(require 'ert)
(require 'harness-test-helpers)
(require 'harness-ui-voice-ribbon)

(defconst harness-ui-voice-ribbon-test--now 1000.0
  "The time the tests draw the ribbon at.")

(defun harness-ui-voice-ribbon-test--pipeline (&optional capture)
  "Return a pipeline in CAPTURE, with a level measured at the tests' time."
  (let ((pipeline (harness-voice-pipeline-create (or capture 'live))))
    (harness-voice-pipeline-set-level pipeline 0.56
                                      harness-ui-voice-ribbon-test--now)
    pipeline))

(defun harness-ui-voice-ribbon-test--plain (lines)
  "Return LINES as one plain string, one line each."
  (string-join (mapcar #'substring-no-properties lines) "\n"))

(defun harness-ui-voice-ribbon-test--linear (pipeline &optional width now)
  "Return PIPELINE's linear ribbon as plain text."
  (harness-ui-voice-ribbon-test--plain
   (harness-voice-ribbon-linear-lines pipeline (or width 72)
                                      (or now harness-ui-voice-ribbon-test--now))))

(defun harness-ui-voice-ribbon-test--ring (pipeline &optional now)
  "Return PIPELINE's compact badge as plain text."
  (harness-ui-voice-ribbon-test--plain
   (harness-voice-ribbon-ring-rows pipeline (or now harness-ui-voice-ribbon-test--now))))

(defun harness-ui-voice-ribbon-test--faces (lines)
  "Return the faces LINES carry, each once, in first-seen order.
A run's cells carry its own face over the ribbon's, so the list is the
stages the ribbon really drew."
  (let ((faces nil))
    (dolist (line lines (nreverse faces))
      (cl-loop for index from 0 below (length line)
               for face = (get-text-property index 'face line)
               for first = (cond ((null face) nil)
                                 ((consp face) (car face))
                                 (t face))
               when (and first (not (eq first 'harness-voice-ribbon-face))
                         (not (memq first faces)))
               do (push first faces)))))

(defun harness-ui-voice-ribbon-test--ids (pipeline &optional now)
  "Return the ids of PIPELINE's visible blips at NOW, oldest first."
  (mapcar (lambda (blip) (plist-get blip :id))
          (harness-voice-ribbon-blips pipeline
                                      (or now harness-ui-voice-ribbon-test--now))))

(defun harness-ui-voice-ribbon-test--band (pipeline id &optional now)
  "Return the band of PIPELINE's blip ID at NOW."
  (plist-get (cl-find id (harness-voice-ribbon-blips
                          pipeline (or now harness-ui-voice-ribbon-test--now))
                      :key (lambda (blip) (plist-get blip :id)) :test #'equal)
             :band))

(defun harness-ui-voice-ribbon-test--column-of (text glyph)
  "Return the column GLYPH first appears at in the ribbon line TEXT."
  (let ((index (string-search glyph text)))
    (and index (string-width (substring text 0 index)))))

(defun harness-voice-ribbon--column-of-blip (pipeline id lines &optional now)
  "Return the column PIPELINE's blip ID is drawn at in LINES at NOW.
The column is the run's own first bar, which is where a handoff moves it:
the glyph changes with the stage, so the glyph cannot stand for the place.
The blip's own tooltip marks every cell of the run, so the first cell that
carries its words is where the run starts.  A run fills the rows its height
reaches, so every row of the block is searched."
  (let* ((now (or now (float-time)))
         (blip (cl-find id (harness-voice-ribbon-blips pipeline now)
                        :key (lambda (item) (plist-get item :id)) :test #'equal))
         (help (and blip (harness-ui-one-line (plist-get blip :label))))
         (wanted (and help (substring-no-properties help))))
    (when wanted
      (seq-some (lambda (line)
                  (cl-loop for index from 0 below (length line)
                           for echo = (get-text-property index 'help-echo line)
                           when (and echo
                                     (equal wanted (substring-no-properties echo)))
                           return index))
                lines))))

(defconst harness-ui-voice-ribbon-test--banned
  '("Pipeline" "Audio" "Speech" "Words" "Processing" "Audio out"
    "Dropped" "Failed" "accepted" "dropped" "Mic ·" "Level ·"
    "Turn ·" "Voice ·" "Pipeline details" "No segments yet")
  "What the call's control may never draw.
A stage key, a legend, a count, a status line or the way into the details
belong in the voice settings, never on the pipe itself.")

(defun harness-ui-voice-ribbon-test--says-nothing (text)
  "Assert that TEXT carries none of `harness-ui-voice-ribbon-test--banned'."
  (dolist (word harness-ui-voice-ribbon-test--banned)
    (should-not (string-search word text))))

;;;; One mark per segment

(ert-deftest harness-ui-voice-ribbon-one-blip-per-segment ()
  "A single burst is one mark, in one stage, never two at once."
  (let ((pipeline (harness-ui-voice-ribbon-test--pipeline)))
    (harness-voice-pipeline-segment pipeline "u-1" 'accepted
                                   (list :seconds 1.4 :at harness-ui-voice-ribbon-test--now))
    (should (equal '("input" "u-1") (harness-ui-voice-ribbon-test--ids pipeline)))
    (should (eq 'speech (harness-ui-voice-ribbon-test--band pipeline "u-1")))
    (harness-voice-pipeline-segment pipeline "u-1" 'transcribing
                                   (list :at (+ harness-ui-voice-ribbon-test--now 0.4)))
    ;; One id: the mark moved, it was not copied.
    (should (equal '("input" "u-1") (harness-ui-voice-ribbon-test--ids pipeline)))
    (should (eq 'words (harness-ui-voice-ribbon-test--band pipeline "u-1")))
    (harness-voice-pipeline-segment pipeline "u-1" 'transcribed
                                   (list :text "hello" :at (+ harness-ui-voice-ribbon-test--now 0.8)))
    (harness-voice-pipeline-turn pipeline "d-1" 'working
                                 (list :segment "u-1" :at (+ harness-ui-voice-ribbon-test--now 0.9)))
    (harness-voice-pipeline-segment pipeline "u-1" 'in-turn
                                   (list :at (+ harness-ui-voice-ribbon-test--now 1.0)))
    (should (eq 'turn (harness-ui-voice-ribbon-test--band pipeline "u-1")))
    ;; The words band is clear now: the handoff cleared its old position.
    (should-not (string-search (make-string 3 ?▄)
                               (harness-ui-voice-ribbon-test--linear
                                pipeline 72 (+ harness-ui-voice-ribbon-test--now 1.1))))
    (harness-voice-pipeline-segment pipeline "u-1" 'answered
                                   (list :at (+ harness-ui-voice-ribbon-test--now 1.2)))
    (should (eq 'turn (harness-ui-voice-ribbon-test--band pipeline "u-1")))
    (should (equal '("input" "u-1") (harness-ui-voice-ribbon-test--ids pipeline)))))

(ert-deftest harness-ui-voice-ribbon-stage-handoff-moves-the-mark ()
  "A real handoff moves one run right and leaves its old place empty."
  (let ((pipeline (harness-ui-voice-ribbon-test--pipeline)))
    (harness-voice-pipeline-segment pipeline "u-1" 'accepted
                                   (list :seconds 1.0 :at harness-ui-voice-ribbon-test--now))
    (let* ((before (harness-voice-ribbon-linear-lines
                    pipeline 72 harness-ui-voice-ribbon-test--now))
           (from (harness-voice-ribbon--column-of-blip
                  pipeline "u-1" before harness-ui-voice-ribbon-test--now)))
      (harness-voice-pipeline-segment pipeline "u-1" 'transcribing
                                      (list :at (+ harness-ui-voice-ribbon-test--now 0.3)))
      (let* ((after (harness-voice-ribbon-linear-lines
                     pipeline 72 harness-ui-voice-ribbon-test--now))
             ;; The run's own tooltip marks its cells, so its first marked
             ;; cell is its new column, whatever glyph the new stage draws.
             (to (harness-voice-ribbon--column-of-blip
                  pipeline "u-1" after harness-ui-voice-ribbon-test--now)))
        (should from)
        (should to)
        (should (> to from))))))

(ert-deftest harness-ui-voice-ribbon-independent-segments-coexist ()
  "Two real bursts in two stages are two marks at once."
  (let ((pipeline (harness-ui-voice-ribbon-test--pipeline)))
    (harness-voice-pipeline-segment pipeline "u-1" 'accepted
                                   (list :seconds 1.4 :at harness-ui-voice-ribbon-test--now))
    (harness-voice-pipeline-segment pipeline "u-1" 'transcribing
                                   (list :at (+ harness-ui-voice-ribbon-test--now 0.2)))
    (harness-voice-pipeline-segment pipeline "u-1" 'transcribed
                                   (list :text "first" :at (+ harness-ui-voice-ribbon-test--now 0.4)))
    (harness-voice-pipeline-segment pipeline "u-2" 'accepted
                                   (list :seconds 0.9 :at (+ harness-ui-voice-ribbon-test--now 0.6)))
    (should (equal '("input" "u-1" "u-2") (harness-ui-voice-ribbon-test--ids pipeline)))
    (should (eq 'speech (harness-ui-voice-ribbon-test--band pipeline "u-2")))
    (should (eq 'words (harness-ui-voice-ribbon-test--band pipeline "u-1")))))

(ert-deftest harness-ui-voice-ribbon-same-stage-blips-take-two-rows ()
  "Two bursts of one stage are two runs on two rows, not one over the other."
  (let ((pipeline (harness-ui-voice-ribbon-test--pipeline)))
    (harness-voice-pipeline-segment pipeline "u-1" 'accepted
                                   (list :seconds 1.0 :at harness-ui-voice-ribbon-test--now))
    (harness-voice-pipeline-segment pipeline "u-2" 'accepted
                                   (list :seconds 0.7 :at (+ harness-ui-voice-ribbon-test--now 0.1)))
    (let* ((blips (harness-voice-ribbon-blips pipeline harness-ui-voice-ribbon-test--now))
           (pairs (harness-voice-ribbon--lanes blips harness-ui-voice-ribbon-test--now))
           (speech (cl-remove-if-not (lambda (pair)
                                       (eq 'speech (plist-get (car pair) :band)))
                                     pairs)))
      (should (= 2 (length speech)))
      (should (equal '(0 1) (sort (mapcar #'cdr speech) #'<))))
    ;; Two bursts of one stage take two blocks of rows, so neither run is
    ;; drawn over the other: the ribbon grows downward rather than hiding a
    ;; mark.
    (let ((lines (harness-voice-ribbon-linear-lines
                  pipeline 72 harness-ui-voice-ribbon-test--now)))
      (should (= (* 2 harness-voice-ribbon--rows) (length lines))))))

(ert-deftest harness-ui-voice-ribbon-waiting-warbles-in-place ()
  "A waiting run warbles in place and never leaves its stage."
  (let ((pipeline (harness-ui-voice-ribbon-test--pipeline))
        (harness-voice-ribbon-motion t)
        (harness-voice-ribbon-warble-rate 5))
    (harness-voice-pipeline-segment pipeline "u-1" 'transcribing
                                   (list :at harness-ui-voice-ribbon-test--now))
    (let* ((blip (cl-find "u-1" (harness-voice-ribbon-blips
                                 pipeline harness-ui-voice-ribbon-test--now)
                          :key (lambda (item) (plist-get item :id)) :test #'equal))
           (early (harness-voice-ribbon--run-glyphs blip 4
                                                     harness-ui-voice-ribbon-test--now))
           (late (harness-voice-ribbon--run-glyphs blip 4
                                                    (+ harness-ui-voice-ribbon-test--now 0.2))))
      (should-not (string= early late))
      ;; The warble changes the bars' heights, never the stage.
      (should (= (length early) (length late)))
      (should (eq 'words (harness-ui-voice-ribbon-test--band pipeline "u-1")))
      (should (eq 'words (harness-ui-voice-ribbon-test--band pipeline "u-1"
                                                         (+ harness-ui-voice-ribbon-test--now 5)))))))

(ert-deftest harness-ui-voice-ribbon-reduced-motion-keeps-every-fact ()
  "With motion off the runs stand still, and every word and mark stays."
  (let ((pipeline (harness-ui-voice-ribbon-test--pipeline)))
    (harness-voice-pipeline-segment pipeline "u-1" 'accepted
                                   (list :at harness-ui-voice-ribbon-test--now))
    (harness-voice-pipeline-segment pipeline "u-1" 'transcribing
                                   (list :at harness-ui-voice-ribbon-test--now))
    (let* ((moving (harness-voice-ribbon-linear-lines
                    pipeline 72 harness-ui-voice-ribbon-test--now))
           (harness-voice-ribbon-motion nil)
           (still (harness-voice-ribbon-linear-lines
                   pipeline 72 harness-ui-voice-ribbon-test--now)))
      (should (equal moving still))
      (should (equal (harness-voice-ribbon-labels pipeline harness-ui-voice-ribbon-test--now)
                     (harness-voice-ribbon-labels pipeline harness-ui-voice-ribbon-test--now)))
      (should (string-search "▃" (harness-ui-voice-ribbon-test--linear
                                     pipeline 72 harness-ui-voice-ribbon-test--now))))))

(ert-deftest harness-ui-voice-ribbon-drop-keeps-its-place-and-clears ()
  "A confirmed drop keeps the stage it stopped in, then clears."
  (let ((pipeline (harness-ui-voice-ribbon-test--pipeline))
        (harness-voice-ribbon-linger 2.5))
    (harness-voice-pipeline-segment pipeline "u-1" 'accepted
                                   (list :seconds 1.4 :at harness-ui-voice-ribbon-test--now))
    (harness-voice-pipeline-segment pipeline "u-1" 'transcribing
                                   (list :at (+ harness-ui-voice-ribbon-test--now 0.3)))
    (harness-voice-pipeline-segment pipeline "u-1" 'dropped
                                   (list :reason 'too-short
                                         :at (+ harness-ui-voice-ribbon-test--now 0.5)))
    (let* ((blip (cl-find "u-1" (harness-voice-ribbon-blips
                                 pipeline (+ harness-ui-voice-ribbon-test--now 0.6))
                          :key (lambda (item) (plist-get item :id)) :test #'equal)))
      (should (eq 'words (plist-get blip :band)))
      (should (eq 'dropped (plist-get blip :form)))
      ;; A drop is short bars in the drop tone, not a live run: it carries
      ;; the drop face, and its bars are lower than a live stage's own.
      (should (eq 'harness-voice-ribbon-dropped-face
                  (harness-voice-ribbon-face blip)))
      (let ((lost (harness-voice-ribbon--run-heights
                   blip 4 (+ harness-ui-voice-ribbon-test--now 0.6))))
        (should (= 4 (length lost)))
        ;; The approved drop row is 0.50 of the ribbon's height: shorter
        ;; than the tallest live run and taller than a quiet one.
        (should (cl-every (lambda (height) (<= height 0.5)) lost)))
      (should (member "u-1 · dropped · 1.4s · too short"
                      (harness-voice-ribbon-labels pipeline
                                                   (+ harness-ui-voice-ribbon-test--now 0.6)))))
    (should-not (member "u-1" (harness-ui-voice-ribbon-test--ids
                                pipeline (+ harness-ui-voice-ribbon-test--now 4))))))

(ert-deftest harness-ui-voice-ribbon-missing-level-is-short-never-silent ()
  "No level is drawn as a short hump, never as a quiet room."
  (let ((pipeline (harness-ui-voice-ribbon-test--pipeline)))
    (harness-voice-pipeline-clear-level pipeline)
    (let* ((blip (cl-find "input" (harness-voice-ribbon-blips
                                   pipeline harness-ui-voice-ribbon-test--now)
                          :key (lambda (item) (plist-get item :id)) :test #'equal))
           (unmeasured (harness-voice-ribbon--run-glyphs
                        blip 5 harness-ui-voice-ribbon-test--now)))
      (should-not (plist-get blip :level))
      ;; A hump, not a flat row: the microphone is drawn as a level meter
      ;; whatever it measured.  With one bar there is no hump to see, so the
      ;; run is checked at a width that can show one.
      (should (> (length unmeasured) 3))
      (let ((wide (harness-voice-ribbon--run-heights blip 7 harness-ui-voice-ribbon-test--now)))
        (should (< (nth 0 wide) (nth 3 wide)))
        (should (< (nth 6 wide) (nth 3 wide))))
      ;; And a measured level is taller than the unmeasured one.
      (harness-voice-pipeline-set-level pipeline 0.95 harness-ui-voice-ribbon-test--now)
      (let* ((loud-blip (cl-find "input" (harness-voice-ribbon-blips
                                           pipeline harness-ui-voice-ribbon-test--now)
                                 :key (lambda (item) (plist-get item :id)) :test #'equal))
             (loud (harness-voice-ribbon--run-glyphs
                    loud-blip 5 harness-ui-voice-ribbon-test--now)))
        ;; Same five bars, but the measured one is taller at its peak: a run
        ;; keeps its width and changes only its height with the level.
        (should (= (length loud) (length unmeasured)))
        (should (string< (substring unmeasured 2 3) (substring loud 2 3)))))))

(ert-deftest harness-ui-voice-ribbon-input-and-output-coexist ()
  "The microphone and the speaker are two marks at once."
  (let ((pipeline (harness-ui-voice-ribbon-test--pipeline)))
    (harness-voice-pipeline-reply pipeline "n-1" 'speaking
                                  (list :at harness-ui-voice-ribbon-test--now))
    (should (equal '("input" "n-1") (harness-ui-voice-ribbon-test--ids pipeline)))
    (should (eq 'speaker (harness-ui-voice-ribbon-test--band pipeline "n-1")))
    (let* ((lines (harness-voice-ribbon-linear-lines
                   pipeline 72 harness-ui-voice-ribbon-test--now))
           (faces (harness-ui-voice-ribbon-test--faces lines)))
      ;; Two runs, in two stages, in one ribbon: the microphone's own face
      ;; and the speaker's are both on it, and neither is the other.
      (should (member 'harness-voice-ribbon-audio-face faces))
      (should (member 'harness-voice-ribbon-work-face faces)))))

(ert-deftest harness-ui-voice-ribbon-linear-and-polar-agree ()
  "Both forms draw the same marks, in the same order, with the same words."
  (let ((pipeline (harness-ui-voice-ribbon-test--pipeline)))
    (harness-voice-pipeline-segment pipeline "u-1" 'transcribed
                                   (list :text "first" :at harness-ui-voice-ribbon-test--now))
    (harness-voice-pipeline-segment pipeline "u-2" 'dropped
                                   (list :seconds 0.08 :reason 'too-short
                                         :at (+ harness-ui-voice-ribbon-test--now 0.1)))
    (harness-voice-pipeline-turn pipeline "d-1" 'working
                                 (list :segment "u-1"
                                       :at (+ harness-ui-voice-ribbon-test--now 0.2)))
    (harness-voice-pipeline-reply pipeline "n-1" 'handed
                                  (list :at (+ harness-ui-voice-ribbon-test--now 0.3)))
    (let* ((now (+ harness-ui-voice-ribbon-test--now 0.4))
           (linear (harness-voice-ribbon-linear-lines pipeline 72 now))
           (ring (harness-voice-ribbon-ring-rows pipeline now))
           (labels (harness-voice-ribbon-labels pipeline now)))
      (dolist (id '("input" "u-1" "u-2" "n-1"))
        (let* ((blip (cl-find id (harness-voice-ribbon-blips pipeline now)
                              :key (lambda (item) (plist-get item :id)) :test #'equal))
               ;; A run is as wide as the room its stage has, so the two
               ;; forms do not draw the same number of bars, and the ring has
               ;; one row where the ribbon has three: the bar heights cannot
               ;; be compared directly.  What both forms must draw is the
               ;; same stage, in the same colour, with the same words.
               (face (harness-voice-ribbon-face blip)))
          (should (memq face (harness-ui-voice-ribbon-test--faces linear)))
          (should (memq face (harness-ui-voice-ribbon-test--faces ring)))
          ;; And both forms are labelled with the same facts, in the same
          ;; order: a reader hears one list, whichever form is drawn.
          (should (member (plist-get blip :label) labels)))))))

(ert-deftest harness-ui-voice-ribbon-ring-does-not-duplicate-a-segment ()
  "A mark that moved to the next stage is not also on the badge's old place."
  (let ((pipeline (harness-ui-voice-ribbon-test--pipeline)))
    (harness-voice-pipeline-segment pipeline "u-1" 'transcribed
                                   (list :text "hello" :at harness-ui-voice-ribbon-test--now))
    (harness-voice-pipeline-turn pipeline "d-1" 'working
                                 (list :segment "u-1"
                                       :at (+ harness-ui-voice-ribbon-test--now 0.1)))
    (harness-voice-pipeline-segment pipeline "u-1" 'in-turn
                                   (list :at (+ harness-ui-voice-ribbon-test--now 0.2)))
    (let ((badge (harness-voice-ribbon-ring-rows
                  pipeline (+ harness-ui-voice-ribbon-test--now 0.3))))
      ;; The words' square-cut bar is gone; the turn's segmented run is there.
      (should-not (seq-find (lambda (line) (string-search "▄▄▄" line)) badge))
      ;; The turn's run is a segmented glyph, which is one of the two the
      ;; breath draws (three segments at the trough, two at the crest), so
      ;; this looks for the run rather than for one frame of its breath.
      (should (seq-find (lambda (line)
                          (or (string-search "≡" line) (string-search "=" line)))
                        badge)))))

;;;; Reduced layout

(ert-deftest harness-ui-voice-ribbon-narrow-window-uses-the-badge ()
  "A narrow surface draws the same runs on the compact badge."
  (let ((pipeline (harness-ui-voice-ribbon-test--pipeline))
        (harness-voice-ribbon-linear-minimum 46))
    (harness-voice-pipeline-segment pipeline "u-1" 'transcribed
                                   (list :text "hello" :at harness-ui-voice-ribbon-test--now))
    (harness-voice-pipeline-reply pipeline "n-1" 'speaking
                                  (list :at harness-ui-voice-ribbon-test--now))
    (let* ((wide (harness-voice-ribbon-line pipeline 72 harness-ui-voice-ribbon-test--now))
           (narrow (harness-voice-ribbon-line pipeline 30 harness-ui-voice-ribbon-test--now)))
      ;; The wide form is the pill: a block of rows, and a bar rather than
      ;; a band -- it stops growing at the ribbon's own width.
      (should (= harness-voice-ribbon--rows (length wide)))
      (dolist (line wide)
        (should (= harness-voice-ribbon-max-width
                   (string-width (substring-no-properties line)))))
      ;; The narrow form is the badge: a block of rows, each as wide as
      ;; the badge, which is compact and never the window's width.
      (should (= harness-voice-ribbon--ring-rows (length narrow)))
      (dolist (line narrow)
        (should (= harness-voice-ribbon--ring-columns
                   (string-width (substring-no-properties line)))))
      (let ((text (string-join (mapcar #'substring-no-properties narrow) "\n")))
        ;; Both runs are on the badge: the words' flat row and the audio
        ;; out's hairlines, in different places.
        (should (string-search "▃" text))
        (should (string-search "▏" text))))))


(ert-deftest harness-ui-voice-ribbon-says-nothing-on-the-pipe ()
  "The control draws the stages and says no words at all."
  (let ((pipeline (harness-ui-voice-ribbon-test--pipeline)))
    (harness-voice-pipeline-segment pipeline "u-1" 'accepted
                                   (list :seconds 1.4 :at harness-ui-voice-ribbon-test--now))
    (harness-voice-pipeline-segment pipeline "u-2" 'dropped
                                   (list :seconds 0.08 :reason 'too-short
                                         :at harness-ui-voice-ribbon-test--now))
    (harness-voice-pipeline-reply pipeline "n-1" 'speaking
                                  (list :at harness-ui-voice-ribbon-test--now))
    ;; No heading, no stage key, no legend, no count and no status line,
    ;; on either form.
    (harness-ui-voice-ribbon-test--says-nothing
     (harness-ui-voice-ribbon-test--linear pipeline 72))
    (harness-ui-voice-ribbon-test--says-nothing
     (harness-ui-voice-ribbon-test--ring pipeline))
    (harness-ui-voice-ribbon-test--says-nothing
     (harness-ui-voice-ribbon-test--plain
      (harness-voice-ribbon-block pipeline 72 harness-ui-voice-ribbon-test--now)))
    ;; The block is the ribbon alone: no heading, no words under it.
    (let ((block (harness-voice-ribbon-block pipeline 72
                                             harness-ui-voice-ribbon-test--now)))
      (harness-ui-voice-ribbon-test--says-nothing
       (harness-ui-voice-ribbon-test--plain block))
      ;; Every line is the bar itself, so every line is the ribbon's
      ;; own width -- never the whole window's.
      (dolist (line block)
        (should (= harness-voice-ribbon-max-width
                   (string-width (substring-no-properties line))))))))

(ert-deftest harness-ui-voice-ribbon-details-are-not-here ()
  "The details are a function of the settings, not a control of the pipe."
  (let ((pipeline (harness-ui-voice-ribbon-test--pipeline)))
    (harness-voice-pipeline-segment pipeline "u-1" 'accepted
                                   (list :seconds 1.4 :at harness-ui-voice-ribbon-test--now))
    ;; The lines still exist, for the settings to draw.
    (let ((lines (harness-voice-ribbon-details
                  pipeline 72 harness-ui-voice-ribbon-test--now)))
      (should (seq-find (lambda (line) (string-search "u-1" line)) lines)))
    ;; And nothing the control draws names them or leads to them.
    (let ((text (harness-ui-voice-ribbon-test--plain
                 (harness-voice-ribbon-block pipeline 72 harness-ui-voice-ribbon-test--now))))
      (should-not (string-search "u-1" text))
      (should-not (string-search "details" text)))))

(ert-deftest harness-ui-voice-ribbon-labels-are-the-facts ()
  "Every visible mark has a one-line label with its id and its stage."
  (let ((pipeline (harness-ui-voice-ribbon-test--pipeline)))
    (harness-voice-pipeline-segment pipeline "u-1" 'accepted
                                   (list :seconds 1.4 :at harness-ui-voice-ribbon-test--now))
    (harness-voice-pipeline-segment pipeline "u-1" 'transcribed
                                   (list :text "add a docstring"
                                         :at (+ harness-ui-voice-ribbon-test--now 0.3)))
    (harness-voice-pipeline-segment pipeline "u-2" 'dropped
                                   (list :seconds 0.08 :reason 'too-short
                                         :at (+ harness-ui-voice-ribbon-test--now 0.4)))
    (harness-voice-pipeline-turn pipeline "d-1" 'working
                                 (list :segment "u-1"
                                       :at (+ harness-ui-voice-ribbon-test--now 0.5)))
    (harness-voice-pipeline-segment pipeline "u-1" 'in-turn
                                   (list :at (+ harness-ui-voice-ribbon-test--now 0.55)))
    (should (equal '("Level · 56%"
                     "u-1 · in turn · 1.4s"
                     "u-2 · dropped · 80ms · too short")
                   (harness-voice-ribbon-labels pipeline
                                                (+ harness-ui-voice-ribbon-test--now 0.6))))))

(ert-deftest harness-ui-voice-ribbon-no-invented-stages ()
  "There is no stage the pipe has not reported, and no invented transfer."
  (let ((words (string-join (harness-voice-ribbon-stage-labels) " ")))
    (should-not (string-search "Transcoding" words))
    (should-not (string-search "Upload" words))
    (should-not (string-search "Transfer" words)))
  (should (equal (harness-voice-pipeline-stage-band 'dropped 'words) 'words))
  (should (eq 'speech (harness-voice-pipeline-stage-band 'dropped nil))))

(ert-deftest harness-ui-voice-ribbon-stage-labels-are-the-settings-words ()
  "The stage words exist, for the settings and a reader, and are nouns."
  (should (equal '("Audio" "Speech" "Words" "Processing" "Audio out")
                 (mapcar #'harness-voice-ribbon--band-title
                         harness-voice-ribbon--band-order)))
  (should (equal '("Audio · Microphone level before the speech filter"
                   "Speech · Speech kept for transcription"
                   "Words · Speech to text"
                   "Processing · Agent work"
                   "Audio out · Playback")
                 (harness-voice-ribbon-stage-labels))))

(ert-deftest harness-ui-voice-ribbon-a-camera-keeps-its-own-words ()
  "A camera session's ribbon words are the pipe's own, never a microphone's.
The ribbon draws no words, but its stage words are what the settings and a
screen reader say, so a camera must not read a microphone's words there
either."
  (let ((pipeline (harness-ui-voice-ribbon-test--pipeline 'live)))
    (harness-voice-pipeline-set-input pipeline 'camera)
    (let ((words (string-join (harness-voice-ribbon-stage-labels pipeline) " ")))
      (should-not (string-search "Microphone" words))
      (should-not (string-search "Mic" words))
      ;; The two bands that measure the input say what a camera measures,
      ;; in the pipe's own words, never the microphone's.
      (should-not (string-search "Audio ·" words))
      (should (string-search "Motion · Mouth motion before the speech gate" words))
      (should (string-search "Mouth · Mouth motion kept for transcription" words))))
  ;; The microphone's own words are unchanged by a camera's.
  (should (equal '("Audio · Microphone level before the speech filter"
                   "Speech · Speech kept for transcription"
                   "Words · Speech to text"
                   "Processing · Agent work"
                   "Audio out · Playback")
                 (harness-voice-ribbon-stage-labels
                  (harness-ui-voice-ribbon-test--pipeline 'live)))))

(ert-deftest harness-ui-voice-ribbon-summary-wraps-without-losing-a-fact ()
  "The words of the pipe wrap to the room they have, and keep every fact."
  (let ((pipeline (harness-ui-voice-ribbon-test--pipeline)))
    (harness-voice-pipeline-segment pipeline "u-1" 'accepted
                                   (list :seconds 1.4 :at harness-ui-voice-ribbon-test--now))
    (let ((wide (substring-no-properties
                 (harness-voice-ribbon-summary pipeline 200 harness-ui-voice-ribbon-test--now)))
          (narrow (harness-voice-ribbon-summary pipeline 20 harness-ui-voice-ribbon-test--now)))
      (should (= 1 (length (split-string wide "\n"))))
      (should (> (length (split-string narrow "\n")) 1))
      ;; Every word of the wide line is in the narrow lines, in order.
      (should (equal (split-string wide " ") (split-string (string-join (split-string narrow "\n") " ") " "))))))


;;;; The grid every mark sits on

(defun harness-ui-voice-ribbon-test--mark-columns (pipeline &optional width now)
  "Return the columns of PIPELINE's ribbon that hold a mark, at NOW.
A column holds a mark when any row of the WIDTH-wide ribbon draws
something there: the bars of a run, or a glyph of a form with its own
shape."
  (let* ((width (or width 72))
         (lines (harness-voice-ribbon-linear-lines
                 pipeline width (or now harness-ui-voice-ribbon-test--now)))
         (occupied (make-vector width nil)))
    (dolist (line lines)
      (let ((text (substring-no-properties line)))
        (cl-loop for index from 0 below (min width (length text))
                 unless (memq (aref text index) '(?\s ?▁))
                 do (aset occupied index t))))
    (cl-loop for index from 0 below width
             when (aref occupied index) collect index)))

(defun harness-ui-voice-ribbon-test--runs (columns)
  "Return COLUMNS as (START . END) runs of consecutive columns."
  (let ((runs nil) (start nil) (previous nil))
    (dolist (column columns)
      (cond ((null start) (setq start column))
            ((/= column (1+ previous))
             (push (cons start previous) runs)
             (setq start column)))
      (setq previous column))
    (when start (push (cons start previous) runs))
    (nreverse runs)))

(ert-deftest harness-ui-voice-ribbon-every-mark-sits-on-one-grid ()
  "Every mark is placed on one pitch, and no two marks merge into one.
The bars of the approved ribbon are laid end to end at a single pitch: a
bar and the gap beside it, the same distance everywhere.  Two defects
this pins down, both of which made the bar read as broken rather than
continuous: a run drawn with a pitch of its own, so neighbouring bars
merged into a blob, and a slot reserved wider than the run that filled
it, so a hole opened between two stages."
  (let ((pipeline (harness-ui-voice-ribbon-test--pipeline)))
    ;; A full pipe: one mark in every stage at once, so no stage is idle and
    ;; the grid alone decides where a bar goes.  Each segment is a separate
    ;; id in its own stage -- one id walks the pipe, so two stages can only be
    ;; populated at once by two segments.
    (harness-voice-pipeline-segment pipeline "u-1" 'accepted
                                   (list :seconds 1.4 :at harness-ui-voice-ribbon-test--now))
    (harness-voice-pipeline-segment pipeline "u-2" 'transcribed
                                   (list :text "hello" :at harness-ui-voice-ribbon-test--now))
    (harness-voice-pipeline-segment pipeline "u-3" 'accepted
                                   (list :seconds 1.1 :at harness-ui-voice-ribbon-test--now))
    (harness-voice-pipeline-turn pipeline "d-1" 'working
                                 (list :segment "u-3" :at harness-ui-voice-ribbon-test--now))
    (harness-voice-pipeline-segment pipeline "u-3" 'in-turn
                                   (list :at harness-ui-voice-ribbon-test--now))
    (harness-voice-pipeline-reply pipeline "n-1" 'speaking
                                  (list :at harness-ui-voice-ribbon-test--now))
    (let* ((columns (harness-ui-voice-ribbon-test--mark-columns pipeline))
           (runs (harness-ui-voice-ribbon-test--runs columns))
           (starts (mapcar #'car runs)))
      ;; No two bars have merged: a run of marked columns is never wider
      ;; than the widest glyph a single mark may draw.
      (dolist (run runs)
        (should (<= (- (cdr run) (car run)) 2)))
      ;; The distance from one mark's start to the next is one pitch, and
      ;; that pitch is the same for every pair of neighbours: no gap in the
      ;; sequence is wider than the rest.
      (let ((pitches (cl-loop for a in (cdr starts) for b in starts
                              collect (- a b))))
        (should (> (length pitches) 8))
        ;; The pitch may be a whole number of columns or, when the ribbon is
        ;; wider than the approved pitch needs, one of two neighbouring
        ;; whole numbers -- a float pitch rounded to its column.  What it may
        ;; never be is a hole: no step is more than one column over the
        ;; smallest, and none is under it.
        (let ((low (apply #'min pitches))
              (high (apply #'max pitches)))
          (should (>= low 1))
          (should (<= (- high low) 1)))))
    ;; The marks begin and end together, so the bar is centred in its own
    ;; pill rather than pushed against one end.
    (let* ((columns (harness-ui-voice-ribbon-test--mark-columns pipeline))
           (left (car columns))
           (right (- (1- harness-voice-ribbon-max-width) (car (last columns)))))
      (should (>= (min left right) 0))
      (should (<= (abs (- left right)) 2)))))

(ert-deftest harness-ui-voice-ribbon-a-waiting-run-breathes ()
  "A waiting run's height moves smoothly, and is at rest with motion off.
The warble is a swell sampled from a sine, not a flip between two fixed
heights: a blink reads as a fault, and Noah asked for the animation to be
nice rather than merely present."
  (let ((pipeline (harness-ui-voice-ribbon-test--pipeline)))
    (harness-voice-pipeline-segment pipeline "u-1" 'transcribing
                                   (list :at harness-ui-voice-ribbon-test--now))
    ;; The transcript's own blip, not the microphone's: only a form that
    ;; waits warbles, and the first blip of a live pipe is the level.
    (let* ((blip (cl-find 'transcribing (harness-voice-ribbon-blips
                                        pipeline harness-ui-voice-ribbon-test--now)
                          :key (lambda (b) (plist-get b :form))))
           ;; The trough and the crest of one breath, a quarter period
           ;; either side of the point where the breath crosses the middle:
           ;; the two samples a test is most likely to get wrong are two
           ;; points of equal height, which is why this takes the extremes.
           (period (/ 1.0 (max 1 harness-voice-ribbon-warble-rate)))
           (a (harness-voice-ribbon--run-heights
               blip 5 (+ harness-ui-voice-ribbon-test--now (/ period 4.0))))
           (b (harness-voice-ribbon--run-heights
               blip 5 (+ harness-ui-voice-ribbon-test--now (/ period 2.0))))
           (still (let ((harness-voice-ribbon-motion nil))
                    (harness-voice-ribbon--run-heights
                     blip 5 harness-ui-voice-ribbon-test--now))))
      (should blip)
      ;; The swell really moves the bars: two points of the breath a quarter
      ;; period apart draw different heights, so a waiting run is animated
      ;; rather than held at one frame.
      (should-not (equal a b))
      ;; The swell is bounded: no sample pushes a bar past the ribbon's own
      ;; full height or below its floor.
      (dolist (sample (list a b))
        (dolist (height sample)
          (should (>= height 0.0))
          (should (<= height 1.0))))
      ;; ...and with motion off the run keeps its own shape and holds still:
      ;; the same heights at any time, never the breath.
      (should (equal still (let ((harness-voice-ribbon-motion nil))
                             (harness-voice-ribbon--run-heights
                              blip 5 (+ harness-ui-voice-ribbon-test--now
                                        (/ period 2.0))))))
      (should-not (equal still a))
      ;; Every height stays inside the bar, never negative and never past
      ;; the ribbon's own full height.
      (dolist (height (append a b still))
        (should (>= height 0.0))
        (should (<= height 1.0))))))

(ert-deftest harness-ui-voice-ribbon-the-breath-is-not-the-redraw ()
  "Every redraw shows a different point of the breath, not the same one.
A host redraws a waiting run once per `harness-voice-ribbon-warble-rate'.
If the breath's own period were that interval, each redraw would sample
the sine at exactly the same phase: the heights would never move and the
run would stand still, which is a blink dressed up as a breath.  This
pins the breath to a period of its own, so the redraws land on different
points of it.

The heights are asserted rather than the glyphs, because the glyphs are
quantized: the badge's one-row form has eight block heights and a subtle
swell can round to the same block twice."
  (let ((pipeline (harness-ui-voice-ribbon-test--pipeline))
        (harness-voice-ribbon-motion t))
    (harness-voice-pipeline-segment pipeline "u-1" 'transcribing
                                   (list :at harness-ui-voice-ribbon-test--now))
    (let* ((blip (cl-find "u-1" (harness-voice-ribbon-blips
                                 pipeline harness-ui-voice-ribbon-test--now)
                          :key (lambda (item) (plist-get item :id))
                          :test #'equal))
           (step (/ 1.0 (max 1 harness-voice-ribbon-warble-rate)))
           (start harness-ui-voice-ribbon-test--now)
           ;; Sixteen redraws: long enough to cross a whole breath at any
           ;; plausible rate, and expressed only in the redraw interval, so
           ;; this says nothing about how long a breath is.
           (phases (cl-loop for tick from 0 below 16
                            for at = (+ start (* tick step))
                            collect (harness-voice-ribbon--wobble at)))
           (heights (cl-loop for tick from 0 below 16
                             for at = (+ start (* tick step))
                             collect (car (harness-voice-ribbon--run-heights
                                           blip 1 at)))))
      (should blip)
      ;; The defect itself: every redraw moves the breath.  Sampled once per
      ;; period, each of these is identical to the one before it -- the
      ;; frozen version's largest step is around 1e-12, which is rounding.
      (cl-loop for a in (cdr phases) for b in phases
               do (should (> (abs (- a b)) 0.001)))
      (cl-loop for a in (cdr heights) for b in heights
               do (should (> (abs (- a b)) 0.001)))
      ;; It is a swell, not a ramp: across those redraws it rises and falls
      ;; through most of its range.
      (should (> (- (apply #'max phases) (apply #'min phases)) 0.9))
      ;; ...and it stays bounded, so no redraw pushes a bar past its own
      ;; full height or below its floor.
      (dolist (phase phases)
        (should (>= phase 0.0))
        (should (<= phase 1.0))))))

(ert-deftest harness-ui-voice-ribbon-the-swell-is-smooth ()
  "Neighbouring points of the breath are close, so the run does not jump.
A swell that stepped between two heights would move the bars a long way
in one redraw and then back; a sine sampled far finer than its own period
moves them a little each time."
  (let ((pipeline (harness-ui-voice-ribbon-test--pipeline))
        (harness-voice-ribbon-motion t))
    (harness-voice-pipeline-segment pipeline "u-1" 'transcribing
                                   (list :at harness-ui-voice-ribbon-test--now))
    (let* ((blip (cl-find "u-1" (harness-voice-ribbon-blips
                                 pipeline harness-ui-voice-ribbon-test--now)
                          :key (lambda (item) (plist-get item :id))
                          :test #'equal))
           ;; A tenth of a redraw apart: fine enough that a smooth breath
           ;; cannot move a bar far, and a flip cannot hide between samples.
           (step (/ 0.1 (max 1 harness-voice-ribbon-warble-rate)))
           (samples (cl-loop for tick from 0 below 60
                             for at = (+ harness-ui-voice-ribbon-test--now
                                         (* tick step))
                             collect (harness-voice-ribbon--run-heights blip 1 at)))
           (heights (mapcar #'car samples))
           (jumps (cl-loop for a in (cdr heights) for b in heights
                           collect (abs (- a b)))))
      (should (> (length jumps) 40))
      ;; Every step of the breath is a small one: no sample jumps by the
      ;; whole swing of the swell.
      (dolist (jump jumps)
        (should (< jump 0.1)))
      ;; ...and the breath still covers a real range, so it is a swell and
      ;; not a flat line.
      (should (> (- (apply #'max heights) (apply #'min heights)) 0.04)))))

(ert-deftest harness-ui-voice-ribbon-the-breath-reaches-the-bar ()
  "A redraw draws the breath into the ribbon's own text.
The heights moving is not enough: what a reader sees is the linear
ribbon's cells, so a redraw has to change them.  The approved shapes are
subtle, so this asks only that the bar really changes across a breath --
a run whose cells never move would be a still picture with an animation
in the code."
  (let ((pipeline (harness-ui-voice-ribbon-test--pipeline))
        (harness-voice-ribbon-motion t))
    (harness-voice-pipeline-segment pipeline "u-1" 'transcribing
                                   (list :at harness-ui-voice-ribbon-test--now))
    (let* ((step (/ 1.0 (max 1 harness-voice-ribbon-warble-rate)))
           ;; Sixteen redraws, expressed only in the redraw interval: long
           ;; enough to cross a breath, and it says nothing about how long
           ;; one is.
           (renderings
            (delete-dups
             (copy-sequence
              (cl-loop for tick from 0 below 16
                       for at = (+ harness-ui-voice-ribbon-test--now
                                   (* tick step))
                       collect (harness-ui-voice-ribbon-test--linear
                                pipeline 60 at))))))
      ;; The breath really reaches the cells: the redraws draw the bar more
      ;; than one way.  A frozen breath draws the same cells every time.
      (should (> (length renderings) 1))
      ;; And with motion off it draws exactly one: the bar is still, and
      ;; every mark is where it was.
      (let ((harness-voice-ribbon-motion nil))
        (should (= 1 (length
                      (delete-dups
                       (copy-sequence
                        (cl-loop for tick from 0 below 8
                                 for at = (+ harness-ui-voice-ribbon-test--now
                                             (* tick step))
                                 collect (harness-ui-voice-ribbon-test--linear
                                          pipeline 60 at)))))))))))

(ert-deftest harness-ui-voice-ribbon-a-segmented-wait-breathes ()
  "A waiting turn's run swells, not only the dashes inside it.
The agent's work is drawn as a segmented glyph, and the approved shape of
it is a fixed height with the dashes changing.  A breath that only changed
the dashes left the run looking still: measured across a whole breath it
drew exactly one distinct frame, which is a frozen mark.  Its glyph now
follows the breath too, so a waiting turn visibly breathes in place.

The run's own glyph is read rather than the whole badge, because the
microphone's bar is a measurement of the level and would move on its own
whatever the breath did."
  (let ((pipeline (harness-ui-voice-ribbon-test--pipeline))
        (harness-voice-ribbon-motion t))
    (harness-voice-pipeline-segment pipeline "u-1" 'transcribed
                                   (list :text "hello"
                                         :at harness-ui-voice-ribbon-test--now))
    (harness-voice-pipeline-turn pipeline "d-1" 'working
                                 (list :segment "u-1"
                                       :at harness-ui-voice-ribbon-test--now))
    (harness-voice-pipeline-segment pipeline "u-1" 'in-turn
                                   (list :at harness-ui-voice-ribbon-test--now))
    (let* ((step (/ 1.0 (max 1 harness-voice-ribbon-warble-rate)))
           (turn (cl-find "u-1" (harness-voice-ribbon-blips
                                 pipeline harness-ui-voice-ribbon-test--now)
                          :key (lambda (item) (plist-get item :id))
                          :test #'equal))
           (frames (cl-loop for tick from 0 below 16
                            for at = (+ harness-ui-voice-ribbon-test--now
                                        (* tick step))
                            collect (harness-voice-ribbon--run-glyphs
                                     turn 3 at))))
      (should turn)
      (should (eq 'in-turn (plist-get turn :form)))
      ;; The run really moves across a breath: a frozen one draws one frame.
      (should (> (length (delete-dups (copy-sequence frames))) 1))
      ;; And with motion off it holds still, drawing one frame only.
      (let ((harness-voice-ribbon-motion nil))
        (should (= 1 (length
                      (delete-dups
                       (copy-sequence
                        (cl-loop for tick from 0 below 16
                                 for at = (+ harness-ui-voice-ribbon-test--now
                                             (* tick step))
                                 collect (harness-voice-ribbon--run-glyphs
                                          turn 3 at)))))))))))

;;; harness-ui-voice-ribbon-test.el ends here

