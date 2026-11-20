;;; harness-ui-voice-ribbon.el --- The voice pipe as one continuous ribbon  -*- lexical-binding: t; -*-

;;; Commentary:

;; The pipeline drawn as one continuous ribbon of bars rather than five
;; labelled columns.  Horizontal position (in the linear ribbon) or the
;; angle (in the compact ring) is the pipeline stage, never elapsed time:
;; a burst appears where the pipe first kept it, moves when the stage it
;; waits on reports, and clears its old position when it moves.  One
;; segment is one blip, so a single "hello" is never drawn in two stages
;; at once; two bursts that are really in different stages are two blips
;; and may be on the ribbon together.
;;
;; The blips are derived, not stored: `harness-voice-ribbon-blips' reads a
;; `harness-voice-pipeline' and returns one blip per real id -- a segment,
;; a reply, the microphone's own level -- in the band its stage belongs
;; to.  Nothing here advances; a waiting blip's warble is a decoration that
;; stays inside its stage, and with `harness-voice-ribbon-motion' nil it
;; stops there with every word unchanged.
;;
;; Two forms of the same blips are drawn:
;;
;; - `harness-voice-ribbon-linear-lines' for a normal, full-size surface:
;;   a labels row, three lanes of character-cell bars, the summary line.
;; - `harness-voice-ribbon-ring-lines' for a compact surface (a narrow
;;   window, a collapsed buddy, a mini view): the same bars around a
;;   circle, the first stage at twelve o'clock and the rest clockwise.
;;   The ring says the same things in the same words; it is not a second
;;   model and it does not replace the linear ribbon.
;;
;; Dropped, failed and cancelled segments take a hollow broken-bar form in
;; the stage that lost them and then clear after
;; `harness-voice-ribbon-linger', without advancing.  A reply the provider
;; was handed but never played stays `handed' and never becomes
;; `speaking': the words and the shape are the provider's own report.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-ui)
(require 'harness-ui-voice-pipeline)

(defgroup harness-voice-ribbon nil
  "The voice pipeline as one continuous ribbon."
  :group 'harness-ui)

(defcustom harness-voice-ribbon-motion t
  "Whether a waiting blip warbles in place.
nil keeps every blip still: the stage's glyph, its band and the summary
line stay exactly as they are, so reduced motion loses no fact.  The
warble never leaves the stage it is drawn in and never advances a blip."
  :type 'boolean
  :group 'harness-voice-ribbon)

(defcustom harness-voice-ribbon-linger 2.5
  "Seconds a dropped, failed or answered blip stays before it clears.
The blip is a real measurement of what the pipe lost; it stays long
enough to be seen, then goes without moving anywhere.  Nil keeps it no
time at all."
  :type 'number
  :group 'harness-voice-ribbon)

(defcustom harness-voice-ribbon-warble-rate 5
  "Times a second a waiting blip is redrawn.
This is the host's refresh of the breath, not the breath itself: the
breath takes `harness-voice-ribbon-warble-breath' seconds, so the
redraws sample it at this many points.  Redrawing at the breath's own
rate would sample the same phase every time and the swell would stand
still."
  :type 'natnum
  :group 'harness-voice-ribbon)

(defcustom harness-voice-ribbon-warble-breath 1.6
  "Seconds one full breath of a waiting blip takes.
A breath is the swell out and back: slow enough to read as waiting
rather than as a pulse, and short enough that a glance sees it move.
It is longer than the redraw interval on purpose, so the redraws
sample different points of it."
  :type 'number
  :group 'harness-voice-ribbon)

(defcustom harness-voice-ribbon-lanes 3
  "How many blips one stage may show side by side.
Independent bursts can really be in one stage together; past this many
the band reuses its lanes rather than growing the surface."
  :type 'natnum
  :group 'harness-voice-ribbon)

(defconst harness-voice-ribbon--band-centres
  '((input . 0.075) (speech . 0.27) (words . 0.465) (turn . 0.66)
    (speaker . 0.865))
  "Where each stage's run is centred, as a fraction of the ribbon.
The stage's place in the pipe, never how long anything waited.")

(defconst harness-voice-ribbon--band-order
  '(input speech words turn speaker)
  "The stages in pipe order, which is also the ribbon's left-to-right order.")

(defconst harness-voice-ribbon--band-titles
  '((input . "Audio") (speech . "Speech") (words . "Words")
    (turn . "Processing") (speaker . "Audio out"))
  "The short word of each stage, in a microphone session.
A camera session reads the pipe's own words instead, so a camera is
never named with a microphone's.")

(defconst harness-voice-ribbon--band-help
  '((input . "Microphone level before the speech filter")
    (speech . "Speech kept for transcription")
    (words . "Speech to text")
    (turn . "Agent work")
    (speaker . "Playback"))
  "The one-line tooltip of each stage, in a microphone session.")

;;;; Blips

(defun harness-voice-ribbon--band-centre (band)
  "Return BAND's fraction of the ribbon."
  (or (alist-get band harness-voice-ribbon--band-centres) 0.0))

(defun harness-voice-ribbon--band-title (band)
  "Return BAND's word."
  (or (alist-get band harness-voice-ribbon--band-titles) (symbol-name band)))

(defun harness-voice-ribbon--band-help (band)
  "Return BAND's one-line tooltip."
  (or (alist-get band harness-voice-ribbon--band-help) (symbol-name band)))
(defun harness-voice-ribbon--reply-form (stage)
  "Return the shape word for reply STAGE."
  (pcase stage
    ('ready 'ready) ('held 'held) ('handed 'handed) ('speaking 'speaking)
    ('spoken 'spoken) ('interrupted 'interrupted) ('dropped 'dropped)
    ('failed 'failed) (_ 'ready)))

(defun harness-voice-ribbon--segment-form (segment)
  "Return the shape SEGMENT's stage and reason make."
  (pcase (plist-get segment :stage)
    ('accepted 'accepted)
    ('transcribing 'transcribing)
    ('transcribed 'transcribed)
    ('in-turn 'in-turn)
    ('answered 'answered)
    ('dropped (if (eq (plist-get segment :reason) 'failed) 'failed 'dropped))
    ('failed 'failed)
    (_ 'accepted)))

(defconst harness-voice-ribbon--waiting-forms
  '(transcribing in-turn ready held handed)
  "The shapes that mean the pipe is waiting on a stage to report.
Only these warble, and only in place.")

(defun harness-voice-ribbon--waiting-p (form)
  "Return non-nil when FORM is a shape that waits in place."
  (memq form harness-voice-ribbon--waiting-forms))

(defconst harness-voice-ribbon--terminal-forms
  '(answered dropped failed spoken interrupted)
  "The shapes whose blip clears after `harness-voice-ribbon-linger'.")

(defun harness-voice-ribbon--blip (id band form &rest args)
  "Return a blip for ID in BAND with FORM.
ARGS is a plist of :stage, :label, :level, :waiting, :terminal, :at and
`:ended'."
  (let ((blip (list :id id
                    :band band
                    :form form
                    :stage (or (plist-get args :stage) form)
                    :label (plist-get args :label)
                    :level (plist-get args :level)
                    :waiting (if (plist-member args :waiting)
                                 (plist-get args :waiting)
                               (harness-voice-ribbon--waiting-p form))
                    :terminal (if (plist-member args :terminal)
                                  (plist-get args :terminal)
                                (memq form harness-voice-ribbon--terminal-forms))
                    :at (plist-get args :at)
                    :ended (plist-get args :ended))))
    blip))

(defun harness-voice-ribbon--segment-label (segment)
  "Return SEGMENT's blip label: its id, stage, length and reason.
The id is the backend's own, so a reader can match a blip to its event."
  (harness-voice-pipeline--line
   (list (plist-get segment :id)
         (harness-voice-pipeline--stage-label (plist-get segment :stage))
         (and (plist-get segment :seconds)
              (harness-voice-pipeline--duration (plist-get segment :seconds)))
         (and (memq (plist-get segment :stage) '(dropped failed))
              (harness-voice-pipeline--drop-label (or (plist-get segment :reason)
                                                      'failed))))))

(defun harness-voice-ribbon--reply-label (reply)
  "Return REPLY's blip label: its id and reply stage."
  (harness-voice-pipeline--line
   (list (plist-get reply :id)
         (harness-voice-pipeline--reply-label (plist-get reply :stage))
         (and (memq (plist-get reply :stage) '(dropped interrupted failed))
              (plist-get reply :detail)))))

(defun harness-voice-ribbon--turn-label (turn)
  "Return TURN's blip label: its id and state."
  (harness-voice-pipeline--line
   (list (plist-get turn :id)
         (harness-voice-pipeline--turn-label (plist-get turn :state)))))

(defun harness-voice-ribbon--input-blip (p now)
  "Return P's microphone blip, or nil when the microphone is closed.
The input bar is the microphone's own measurement before the speech
filter.  Without telemetry it is drawn hollow with `Level · no data'
rather than as silence."
  (when (memq (harness-voice-pipeline-capture p) '(live connecting))
    (harness-voice-ribbon--blip
     "input" 'input 'level
     :stage (harness-voice-pipeline-capture p)
     :label (harness-voice-pipeline-level-label p now)
     :level (unless (harness-voice-pipeline-level-stale-p p now)
              (harness-voice-pipeline-level p))
     :waiting nil :terminal nil)))

(defun harness-voice-ribbon-blips (p &optional now)
  "Return P's blips, oldest first, for the ribbon at NOW.
One blip per real id: each kept or lost burst, each reply the speaker
was given, and the microphone.  A turn is not a blip of its own: the
segments that fed it are already bars in the turn's stage, and drawing the
turn as well would put one utterance in two places and claim a one-to-one
causality the events do not show.  A segment's band is its stage's place
in the pipe; a dropped or failed one keeps the band it had reached, so a
loss is drawn where it happened."
  (let* ((now (or now (float-time)))
         (blips nil))
    (when-let* ((input (harness-voice-ribbon--input-blip p now)))
      (push input blips))
    (dolist (segment (reverse (harness-voice-pipeline-segments p)))
      (let* ((stage (plist-get segment :stage))
             (form (harness-voice-ribbon--segment-form segment))
             (band (harness-voice-pipeline-stage-band stage (plist-get segment :from))))
        (push (harness-voice-ribbon--blip
               (plist-get segment :id) band form
               :stage stage
               :label (harness-voice-ribbon--segment-label segment)
               :at (plist-get segment :at)
               :ended (plist-get segment :ended))
              blips)))
    (dolist (reply (reverse (harness-voice-pipeline-replies p)))
      (push (harness-voice-ribbon--blip
             (plist-get reply :id) 'speaker (harness-voice-ribbon--reply-form
                                            (plist-get reply :stage))
             :stage (plist-get reply :stage)
             :label (harness-voice-ribbon--reply-label reply)
             :at (plist-get reply :at)
             :ended (plist-get reply :ended))
            blips))
    (setq blips (nreverse blips))
    (harness-voice-ribbon--expire blips now)))

(defun harness-voice-ribbon--expire (blips now)
  "Return BLIPS whose terminal linger has not run out at NOW."
  (if (not (numberp harness-voice-ribbon-linger))
      (cl-remove-if (lambda (blip) (plist-get blip :terminal)) blips)
    (cl-remove-if
     (lambda (blip)
       (let ((ended (plist-get blip :ended)))
         (and (plist-get blip :terminal)
              (numberp ended)
              (> (- now ended) harness-voice-ribbon-linger))))
     blips)))

(defun harness-voice-ribbon-visible-p (blip now)
  "Return non-nil when BLIP is drawn at NOW.
A terminal blip is drawn for `harness-voice-ribbon-linger' seconds after
it ended and then clears."
  (or (not (plist-get blip :terminal))
      (let ((ended (plist-get blip :ended)))
        (or (not (numberp ended))
            (not (numberp harness-voice-ribbon-linger))
            (<= (- now ended) harness-voice-ribbon-linger)))))

(defun harness-voice-ribbon-lane (blips blip)
  "Return BLIP's lane among BLIPS: its order within its own stage.
Blips are oldest first, so the oldest burst of a stage takes the first
lane and a newer one sits beside it instead of covering it."
  (let ((lane 0))
    (catch 'done
      (dolist (other blips)
        (when (eq other blip) (throw 'done lane))
        (when (eq (plist-get other :band) (plist-get blip :band))
          (cl-incf lane)))
      lane)))

(defun harness-voice-ribbon--lanes (blips now)
  "Return BLIPS as (BLIP . LANE) pairs at NOW, bounded per stage.
The pairs come back in the ribbon's own band order, then in the order the
pipe reported them within a band.  Placement depends on that order -- a
run's columns are counted from the stages before it -- so it must not
depend on the order events happened to arrive in, which would move a mark
that did not change."
  (let ((lanes (make-hash-table :test #'eq))
        (pairs nil))
    (dolist (blip blips)
      (when (harness-voice-ribbon-visible-p blip now)
        (let* ((band (plist-get blip :band))
               (next (gethash band lanes 0))
               (lane (if (> harness-voice-ribbon-lanes 0)
                         (mod next (max 1 harness-voice-ribbon-lanes))
                       0)))
          (puthash band (1+ next) lanes)
          (push (cons blip lane) pairs))))
    ;; `sort' is stable in Emacs, so two bursts of one stage keep the order
    ;; the pipe reported them in while the stages come out in band order.
    (sort (nreverse pairs)
          (lambda (a b)
            (< (or (cl-position (plist-get (car a) :band)
                                harness-voice-ribbon--band-order)
                   99)
               (or (cl-position (plist-get (car b) :band)
                                harness-voice-ribbon--band-order)
                   99))))))

(defun harness-voice-ribbon-animated-p (p &optional now)
  "Return non-nil when P's ribbon has something to animate at NOW.
Only a waiting blip warbles, and only while `harness-voice-ribbon-motion'
is on; a terminal blip needs one redraw when its linger runs out."
  (and harness-voice-ribbon-motion
       (cl-find-if (lambda (blip)
                     (and (harness-voice-ribbon-visible-p blip now)
                          (plist-get blip :waiting)))
                   (harness-voice-ribbon-blips p now))))

(defun harness-voice-ribbon-lingering-p (p &optional now)
  "Return non-nil when a terminal blip of P still has to clear at NOW."
  (cl-find-if (lambda (blip) (plist-get blip :terminal))
              (harness-voice-ribbon-blips p now)))

(defun harness-voice-ribbon-next-change (p &optional now)
  "Return when P's ribbon next changes by itself, or nil.
A warble changes it at the next redraw; a terminal blip changes it when
its linger runs out.  A host can redraw then instead of running a clock.
The redraw interval is the refresh of the breath, not the breath itself,
which is why it is shorter than `harness-voice-ribbon-warble-breath'."
  (let ((now (or now (float-time)))
        (deadline nil))
    (when (harness-voice-ribbon-animated-p p now)
      (setq deadline (+ now (/ 1.0 (max 1 harness-voice-ribbon-warble-rate)))))
    (when (numberp harness-voice-ribbon-linger)
      (dolist (blip (harness-voice-ribbon-blips p now))
        (when (and (plist-get blip :terminal)
                   (numberp (plist-get blip :ended)))
          (let ((at (+ (plist-get blip :ended) harness-voice-ribbon-linger)))
            (when (and (> at now) (or (null deadline) (< at deadline)))
              (setq deadline at))))))
    deadline))

;;;; Shapes
;;;; Shapes

(defconst harness-voice-ribbon--blocks
  ["▁" "▂" "▃" "▄" "▅" "▆" "▇" "█"]
  "The height scale of a character-cell bar, shortest first.
A run of these is the character-cell picture of a waveform: the height is
the level, and the face is the stage.")

(defun harness-voice-ribbon--block (fraction)
  "Return the block glyph for FRACTION of a cell's height, 0..1."
  (aref harness-voice-ribbon--blocks
        (max 0 (min 7 (round (* 7.0 (max 0.0 (min 1.0 fraction))))))))

(defun harness-voice-ribbon--hump (index count top)
  "Return a height for INDEX of COUNT, tallest in the middle, at most TOP."
  (let* ((middle (/ (float (1- (max 2 count))) 2.0))
         (distance (if (> middle 0) (/ (abs (- index middle)) middle) 0.0)))
    (* top (- 1.0 (* 0.55 distance)))))

(defun harness-voice-ribbon--frame (now)
  "Return the warble frame at NOW: 0 or 1.
A one-row form has no height to swell, so it shows the breath as two
glyphs instead.  The frame follows the breath rather than the redraw:
crossing at the breath's own pace reads as a swell, while flipping at
the redraw rate is a blink.  With motion off it is 0, which puts every
glyph at rest."
  (if (and harness-voice-ribbon-motion (numberp now))
      (if (>= (harness-voice-ribbon--wobble now) 0.5) 1 0)
    0))

(defun harness-voice-ribbon--wobble (now)
  "Return the warble's own phase at NOW, in 0..1.
0 is the trough of the breath and 0.5 its crest, so a shape that waits
scales by this and swells instead of stepping between two heights.  With
motion off it is 0, which puts every shape at rest.

The breath is its own period, not the redraw interval: sampling a sine
once per period would give the same phase every time and the swell would
stand still, which is a blink dressed up as a breath."
  (if (and harness-voice-ribbon-motion (numberp now))
      (/ (+ 1.0 (sin (/ (* now 2 float-pi)
                        (max 0.05 harness-voice-ribbon-warble-breath))))
         2.0)
    0.0))

(defun harness-voice-ribbon--run-heights (blip width &optional now)
  "Return WIDTH height fractions, 0..1, for BLIP's run of bars at NOW.
Every stage draws its own silhouette, and the silhouette is the approved
one: the microphone and the kept speech a rounded hump of bars, a
transcription a flat row of square-cut bars, the agent's work a row of
segmented bars, the audio out fine paired bars, and a confirmed drop an
outline of dots.  A height is the stage's own proportion of the ribbon's
full height, so a run is not one flat row: the humps rise and fall, the
words sit flat, and the audio out steps."
  (let* ((form (plist-get blip :form))
         (second (eq 1 (harness-voice-ribbon--frame (or now (float-time)))))
         (swell (harness-voice-ribbon--wobble (or now (float-time))))
         (width (max 1 width)))
    (pcase form
      ('level
       ;; The microphone's own measurement: the approved audio hump, 0.10 to
       ;; 0.31 of the ribbon's full height, scaled by the level.  With no
       ;; level it is drawn at its quietest, never as silence.
       (let ((peak (let ((level (plist-get blip :level)))
                     (if (numberp level) (+ 0.10 (* 0.21 level)) 0.18))))
         (cl-loop for index below width
                  collect (harness-voice-ribbon--hump index width peak))))
      ('accepted
       ;; Speech the filter kept: the approved speech hump, 0.23 to 0.62,
       ;; round-ended and mint.
       (cl-loop for index below width
                collect (harness-voice-ribbon--hump index width 0.62)))
      ('transcribing
       ;; Square-cut blue bars that warble in place while the words come.
       (cl-loop for index below width
                collect (+ 0.35
                           (* (if (eq 0 (mod (+ index (if second 1 0)) 2)) 1 -1)
                              (+ 0.02 (* 0.03 swell))))))
      ('transcribed
       ;; The words have arrived: the approved flat row, every bar 0.35.
       (cl-loop repeat width collect 0.35))
      ((or 'in-turn 'answered 'handed 'ready)
       ;; The agent's work: the approved segmented row, 0.30 high.
       (cl-loop repeat width collect 0.30))
      ((or 'held 'speaking 'spoken)
       ;; The audio out: the approved paired run, stepping 0.12 to 0.58 --
       ;; the tallest run in the ribbon.
       (let ((steps [0.12 0.26 0.47 0.58 0.34 0.18]))
         (cl-loop for index below width
                  for base = (aref steps (mod index (length steps)))
                  collect (* base (+ 0.82 (* 0.18 swell))))))
      ((or 'dropped 'interrupted)
       ;; A confirmed loss: the approved drop row, 0.50 high, in the drop
       ;; tone as an outline of dots.
       (cl-loop repeat width collect 0.50))
      ('failed (cl-loop repeat width collect 0.50))
      (_ (cl-loop repeat width collect 0.30)))))

(defun harness-voice-ribbon--form-glyph (form &optional second)
  "Return FORM's own one-cell glyph, or nil when its height is its glyph.
The microphone and the kept speech are block bars whose height is the level
they measured, so they carry no glyph of their own.  The agent's work is
segmented, the audio out a hairline, a confirmed drop an outline of dots and
a failure a cross, and those are one cell each whatever the run's height.

A waiting form draws its second glyph on the breath's crest: the agent's
work loses a segment, and the audio out thickens its hairline.  A run whose
only motion is inside a constant glyph shows no breath at all, which is
what left a waiting turn looking frozen; SECOND follows the breath rather
than the redraw, so the change reads as a swell and not a blink."
  (pcase form
    ;; A waiting turn: three segments at the trough, two at the crest.
    ((or 'in-turn 'ready 'handed) (if second "=" "≡"))
    ('answered "≡")
    ((or 'held 'speaking 'spoken) (if second "▎" "▏"))
    ((or 'dropped 'interrupted) "╌")
    ('failed "✕")
    (_ nil)))

(defun harness-voice-ribbon--run-glyphs (blip width &optional now)
  "Return WIDTH glyphs for BLIP's run of bars at NOW, one row of cells.
This is the one-row form the compact badge draws, where there is no room
for a bar's own height: a block form shows the bar's height as a block
glyph, and a form with a glyph of its own shows that instead.  The linear
ribbon draws the same run with `harness-voice-ribbon--run-bars'."
  (let* ((form (plist-get blip :form))
         (second (eq 1 (harness-voice-ribbon--frame (or now (float-time)))))
         (width (max 1 width))
         (own (harness-voice-ribbon--form-glyph form second))
         (heights (harness-voice-ribbon--run-heights blip width now)))
    (apply #'concat
           (cl-loop for height in heights
                    collect (or own (harness-voice-ribbon--block height))))))

(defun harness-voice-ribbon--run-bars (blip width &optional now)
  "Return WIDTH bars for BLIP's run at NOW, as (HEIGHT . GLYPH) pairs.
HEIGHT is the bar's own fraction of the ribbon's full height and GLYPH is
the cell a form with its own shape draws, or nil when the bar's height is
what draws it.  Both the linear ribbon and the badge read this, so the two
forms cannot disagree about a run."
  (let* ((form (plist-get blip :form))
         (second (eq 1 (harness-voice-ribbon--frame (or now (float-time)))))
         (own (harness-voice-ribbon--form-glyph form second))
         (heights (harness-voice-ribbon--run-heights blip (max 1 width) now)))
    (mapcar (lambda (height) (cons height own)) heights)))

(defconst harness-voice-ribbon--faces
  '((accepted . harness-voice-ribbon-speech-face)
    (transcribing . harness-voice-ribbon-words-face)
    (transcribed . harness-voice-ribbon-words-face)
    (in-turn . harness-voice-ribbon-work-face)
    (answered . harness-voice-ribbon-work-face)
    (ready . harness-voice-ribbon-work-face)
    (held . harness-voice-ribbon-work-face)
    (handed . harness-voice-ribbon-work-face)
    (speaking . harness-voice-ribbon-work-face)
    (spoken . harness-voice-ribbon-work-face)
    (interrupted . harness-voice-ribbon-dropped-face)
    (dropped . harness-voice-ribbon-dropped-face)
    (failed . harness-voice-ribbon-failed-face))
  "The face of each stage's run of bars.
Four colours carry the pipe -- grey, mint, blue and white -- and a loss is
drawn in the drop tone as an outline of dots.  Colour is never the only cue:
the shape and the tooltip say the same thing.")

(defun harness-voice-ribbon-face (blip)
  "Return BLIP's face."
  (or (alist-get (plist-get blip :form) harness-voice-ribbon--faces)
      'harness-voice-ribbon-audio-face))

(defun harness-voice-ribbon-shape (blip &optional now)
  "Return BLIP's first glyph at NOW.
The run is what a person sees; this is the one glyph that stands for it, for
a host that has room for a single mark."
  (substring (harness-voice-ribbon--run-glyphs blip 1 now) 0 1))

(defun harness-voice-ribbon-glyph (blip &optional now)
  "Return BLIP's run as a propertized string at NOW."
  (let ((glyphs (harness-voice-ribbon--run-glyphs blip 3 now)))
    (propertize glyphs
                'face (harness-voice-ribbon-face blip)
                'help-echo (harness-ui-one-line (plist-get blip :label)))))

(defface harness-voice-ribbon-face
  '((((background light)) :background "#f2f1ec" :extend t)
    (((background dark)) :background "#23262a" :extend t))
  "Background of the ribbon: one continuous bar, not five boxes."
  :group 'harness-voice-ribbon)

(defface harness-voice-ribbon-edge-face
  '((((background light)) :background "#dcdad2" :extend t)
    (((background dark)) :background "#3a3f45" :extend t))
  "The hairline of the compact badge, and nothing else."
  :group 'harness-voice-ribbon)

(defface harness-voice-ribbon-audio-face
  '((((background light)) :foreground "#7d8388" :background "#f2f1ec")
    (((background dark)) :foreground "#9aa0a6" :background "#23262a"))
  "The microphone's own level: grey, and the first stage."
  :group 'harness-voice-ribbon)

(defface harness-voice-ribbon-speech-face
  '((t :inherit (harness-success-face harness-voice-ribbon-face)))
  "Speech the filter kept: mint."
  :group 'harness-voice-ribbon)

(defface harness-voice-ribbon-words-face
  '((t :inherit (harness-agent-label-face harness-voice-ribbon-face)))
  "The words: blue, square cut."
  :group 'harness-voice-ribbon)

(defface harness-voice-ribbon-work-face
  '((t :inherit (harness-agent-face harness-voice-ribbon-face)))
  "The agent's work and the audio out: white, segmented and fine."
  :group 'harness-voice-ribbon)

(defface harness-voice-ribbon-dropped-face
  '((t :inherit (harness-dim-face harness-voice-ribbon-face)))
  "A confirmed drop: the drop tone, as an outline of dots."
  :group 'harness-voice-ribbon)

(defface harness-voice-ribbon-failed-face
  '((t :inherit (harness-failure-face harness-voice-ribbon-face)))
  "A failure: the failure colour, as a cross."
  :group 'harness-voice-ribbon)

(defun harness-voice-ribbon--column (band width)
  "Return the ribbon column of BAND's centre in a ribbon WIDTH wide."
  (let ((width (max 1 width)))
    (min (1- width)
         (max 0 (round (* (harness-voice-ribbon--band-centre band)
                          (1- width)))))))

(defun harness-voice-ribbon--run-width (width)
  "Return the columns one run of bars takes in a ribbon WIDTH wide.
A run fills its own fifth of the ribbon, less a gutter at each side, so
the five runs together read as one continuous bar rather than as five
marks with holes between them."
  (max 3 (min 13 (1- (floor width (length harness-voice-ribbon--band-order))))))

(defconst harness-voice-ribbon--approved-bars
  '((level . 4) (accepted . 5) (transcribing . 5) (transcribed . 5)
    (in-turn . 3) (answered . 3) (ready . 3) (held . 3) (handed . 3)
    (speaking . 7) (spoken . 7) (interrupted . 4) (dropped . 4) (failed . 4))
  "The bars each approved stage draws, measured from the original ribbon.
voice-pipeline-all-bars.png's Option A ribbon is 690 px wide and carries 28
marks: the microphone four, kept speech five, the words five, the agent's
work three, a confirmed drop four and the audio out seven paired hairlines.
Those counts are what make a populated ribbon come out at the original's
own density instead of as five equal clusters.")

(defconst harness-voice-ribbon--bar-width 1
  "Columns one character-cell bar takes.
The approved bar is 0.122 of the pill's height, and a cell's height is
about twice its width, so one cell across is the closest a character grid
comes to the original's proportion.")

(defconst harness-voice-ribbon--bar-pitch 2
  "Columns from one bar's start to the next: one bar and one gap.
The approved pitch is 0.222 of the pill's height, which is two cells at
this grid: a bar and the gap beside it.  The pitch is the same in every
stage, so neighbouring runs read as one ribbon rather than as five
clusters with gutters between them.")

(defun harness-voice-ribbon--run-columns (width &optional form)
  "Return how many bars one stage's run holds in a WIDTH-wide ribbon.
The approved ribbon gives each stage the number of bars its own shape has
-- four for the microphone, five for kept speech and for the words, three
for the agent's work, four for a drop and seven for the audio out -- so a
run is its own fixed length rather than a share of the bar filled to the
brim.

The room cap only bites when the whole sequence would not fit at all, and
then every stage shrinks together: the cap is the share of the ribbon one
stage may take, so a run and the slot reserved for it are always the same
number of columns.  A slot wider than its run is what left dead columns
between two stages and made the bar read as broken."
  (let* ((room (harness-voice-ribbon--run-width width))
         (wanted (or (alist-get form harness-voice-ribbon--approved-bars)
                     (/ room harness-voice-ribbon--bar-pitch))))
    (max 1 (min wanted room))))

(defun harness-voice-ribbon-cells (width)
  "Return WIDTH blank cells as a fresh vector.
The ribbon is built in a vector of characters and made a string at the
end: a glyph laid into the bar is a character, not a byte."
  (vconcat (make-string (max 1 width) ?\s)))

(defun harness-voice-ribbon--paint (cells start glyph)
  "Put GLYPH into CELLS at START, and return START after it.
Only the first column of GLYPH's width carries its face and tooltip, so a
two-cell mark keeps the bar's own length."
  (let ((column start)
        (index 0))
    (while (and (< column (length cells)) (< index (length glyph)))
      (aset cells column (aref glyph index))
      (cl-incf column)
      (cl-incf index))
    column))

(defun harness-voice-ribbon--plain-row-string (cells marks)
  "Return CELLS as a string with MARKS laid into it, and no bar behind it.
The compact ring is a shape in the buffer, not a bar: only its marks and
its quiet track carry faces."
  (let ((string (apply #'concat (mapcar #'char-to-string (append cells nil)))))
    (dolist (mark marks)
      (let* ((start (nth 0 mark))
             (glyph (nth 1 mark))
             (face (nth 2 mark))
             (help (nth 3 mark))
             (end (min (length string) (+ start (length glyph)))))
        (when (< start end)
          (add-text-properties start end
                               (list 'face face 'help-echo help)
                               string))))
    string))

(defun harness-voice-ribbon--row-string (cells marks)
  "Return CELLS as a string on the ribbon's bar, with MARKS laid into it.
A mark is (START GLYPH FACE HELP).  Every cell carries the bar's
background, and a mark keeps its own foreground over it, so the ribbon
reads as one continuous bar with marks in it rather than five boxes."
  (let ((string (apply #'concat (mapcar #'char-to-string (append cells nil)))))
    (add-text-properties 0 (length string) (list 'face 'harness-voice-ribbon-face) string)
    (dolist (mark marks)
      (let* ((start (nth 0 mark))
             (glyph (nth 1 mark))
             (face (nth 2 mark))
             (help (nth 3 mark))
             (end (min (length string) (+ start (length glyph)))))
        (when (< start end)
          (add-text-properties start end
                               (list 'face (list face 'harness-voice-ribbon-face)
                                     'help-echo help)
                               string))))
    string))

(defcustom harness-voice-ribbon-max-width 60
  "The widest the linear ribbon grows, in columns.
The ribbon is a compact bar, not a band stretched across the window: past
this width the five stages drift apart and the bar reads as five separate
marks rather than one pipe.  A wider window keeps the ribbon this wide."
  :type 'natnum
  :group 'harness-voice-ribbon)

(defconst harness-voice-ribbon--rows 3
  "The rows a run of bars is drawn in.
The approved Emacs mockup draws its ribbon in three text rows: the tallest
bar is three rows high, and the short ones fill the bottom row only.  Three
rows is also the least a character grid needs to show a level at all --
with one row every bar would be the same height and the silhouette would
carry nothing.")

(defun harness-voice-ribbon--bar-cells (fraction)
  "Return FRACTION of a run's full height as one glyph a row, top first.
A bar fills from its own bottom row up: the rows it fully covers are the
full block, and its topmost row is the block that is as tall as the part it
reaches.  The rows above it are nil, which is the empty cell -- so a run of
different heights is a silhouette and not a row of equal marks."
  (let* ((rows harness-voice-ribbon--rows)
         (height (* rows (max 0.0 (min 1.0 fraction))))
         (whole (min rows (floor height)))
         (part (- height whole))
         (cells (make-list rows nil))
         (index (1- rows)))
    ;; The fully covered rows, bottom up.
    (dotimes (_ whole)
      (when (>= index 0)
        (setcar (nthcdr index cells) (aref harness-voice-ribbon--blocks 7))
        (cl-decf index)))
    ;; The partial row above them.
    (when (and (> part 0.0) (>= index 0))
      (setcar (nthcdr index cells)
              (aref harness-voice-ribbon--blocks
                    (max 1 (min 7 (round (* 7.0 part)))))))
    cells))

(defun harness-voice-ribbon--band-weight (band)
  "Return the bars BAND's own approved shape draws.
voice-pipeline-all-bars.png's Option A ribbon carries 28 marks: the
microphone four, kept speech five, the words five, the agent's work three, a
confirmed drop four and the audio out seven paired hairlines."
  (or (nth (cl-position band harness-voice-ribbon--band-order)
           '(4 5 5 3 7))
      4))

(defun harness-voice-ribbon--slots (pairs width)
  "Return each stage's slot in a WIDTH-wide ribbon, as an alist.
A slot is exactly as wide as the bars its own run draws -- never the
approved weight on its own, and never wider than the run, because a slot
wider than its run is dead columns between two stages and the bar reads as
broken.  An idle stage still keeps its approved slot, so a handoff moves a
mark into the next stage rather than sliding the ribbon up, and a stage
with a second real burst takes another run's worth of columns."
  (let ((bars-in (make-hash-table :test 'eq)))
    (dolist (pair pairs)
      (let ((band (plist-get (car pair) :band)))
        (puthash band (+ (gethash band bars-in 0)
                         (harness-voice-ribbon--run-columns
                          width (plist-get (car pair) :form)))
                 bars-in)))
    (cl-loop for band in harness-voice-ribbon--band-order
             collect (cons band (or (gethash band bars-in)
                                    ;; An idle stage keeps its place in the
                                    ;; order, so the next mark moves into it.
                                    (harness-voice-ribbon--band-idle-columns
                                     band width))))))

(defun harness-voice-ribbon--band-idle-columns (band width)
  "Return the columns BAND keeps in a WIDTH-wide ribbon while it is empty.
The stage's own approved shape is what reserves its place: the microphone
four, kept speech five, the words five, the agent's work three and the
audio out seven, scaled to the room the ribbon has."
  (let* ((form (or (alist-get band harness-voice-ribbon--band-forms)
                   'accepted))
         (room (harness-voice-ribbon--run-width width))
         (wanted (or (alist-get form harness-voice-ribbon--approved-bars)
                     (/ room harness-voice-ribbon--bar-pitch))))
    (max 1 (min wanted room))))

(defconst harness-voice-ribbon--band-forms
  '((input . level) (speech . accepted) (words . transcribed)
    (turn . in-turn) (speaker . speaking))
  "The form whose shape reserves each stage's place while the stage is idle.")

(defun harness-voice-ribbon-linear-rows (p width &optional now)
  "Return P's ribbon rows at NOW, without its words.
WIDTH is the room the ribbon has; the bar itself is at most
`harness-voice-ribbon-max-width' wide.  Each row is a vector of characters
and the marks laid into it, as `harness-voice-ribbon-linear-lines' keeps
them apart until it makes the strings.

The stages are laid end to end on one pitch, the approved one: a bar, a gap,
a bar.  A stage boundary is therefore the next bar rather than a gutter, so
the whole pipe reads as one waveform.  A stage with nothing in it draws
nothing -- the approved ribbon leaves an idle stage empty, and a quiet bar
there would be a measurement the pipe never made."
  (let* ((now (or now (float-time)))
         (width (max 12 (min width harness-voice-ribbon-max-width)))
         (pairs (harness-voice-ribbon--lanes (harness-voice-ribbon-blips p now) now))
         (lanes (max 1 harness-voice-ribbon-lanes))
         (slots (harness-voice-ribbon--slots pairs width))
         (total (cl-loop for (_band . slot) in slots sum slot))
         ;; The pitch is the approved two columns when the ribbon has room for
         ;; them, and grows evenly to fill the width when it has more.  A run
         ;; of bars that stops short of its own pill reads as a bar with a
         ;; piece missing, which is what an un-filled ribbon looked like.  The
         ;; bars are placed at one float pitch and rounded to their columns, so
         ;; the gap stays even from the first stage to the last.
         (pitch (if (<= (* total harness-voice-ribbon--bar-pitch) width)
                    (/ (float width) total)
                  (float harness-voice-ribbon--bar-pitch)))
         ;; Every lane is a block of `harness-voice-ribbon--rows' rows, one
         ;; row per lane stacked under the last: two bursts of a stage take
         ;; two blocks, so neither is drawn over the other.
         (rows (cl-loop repeat (* lanes harness-voice-ribbon--rows)
                        collect (harness-voice-ribbon-cells width)))
         (marks (cl-loop repeat (* lanes harness-voice-ribbon--rows)
                         collect nil))
         (used (make-hash-table :test 'eq)))
    (dolist (pair pairs)
      (let* ((blip (car pair))
             (band (plist-get blip :band))
             (lane (min (1- lanes) (cdr pair)))
             (count (harness-voice-ribbon--run-columns
                     width (plist-get blip :form)))
             (bars (harness-voice-ribbon--run-bars blip count now))
             (before (cl-loop for cell in slots
                              until (eq (car cell) band)
                              sum (cdr cell)))
             ;; The run's first bar sits on the pitch grid, rounded to the
             ;; column it lands on; the last one may not reach the width's
             ;; last column, which is what keeps every gap the same.
             (first (round (* pitch (+ before (gethash band used 0)))))
             (start (min (max 0 (- width (round (* count pitch))))
                         first))
             (face (harness-voice-ribbon-face blip))
             (help (harness-ui-one-line (plist-get blip :label)))
             (base (* lane harness-voice-ribbon--rows)))
        (puthash band (+ (gethash band used 0) count) used)
        (cl-loop for bar in bars
                 for index from 0
                 for at = (min (1- width)
                               (round (+ start (* index pitch))))
                 for own = (cdr bar)
                 ;; A form with a glyph of its own fills the whole block: the
                 ;; segmented work, the fine audio out, the dotted drop and
                 ;; the cross are shapes in themselves, and their height says
                 ;; nothing.  A level or a word is a bar, and fills from its
                 ;; own bottom row up, so the run is a silhouette.
                 for cells = (if own
                                 (make-list harness-voice-ribbon--rows own)
                               (harness-voice-ribbon--bar-cells (car bar)))
                 do (cl-loop for glyph in cells
                             for row from 0
                             when glyph
                             do (let ((cell (+ base row)))
                                  (aset (nth cell rows) at (aref glyph 0))
                                  (setf (nth cell marks)
                                        (append (nth cell marks)
                                                (list (list at glyph face help)))))))))
    ;; Only the lanes that really carry a run are drawn: one burst is one
    ;; block, and two bursts of a stage take two.
    (let ((seen (cl-loop for lane-marks in marks
                         for index from 1
                         when lane-marks maximize index)))
      (cl-loop for row in (seq-take rows (or seen harness-voice-ribbon--rows))
               for lane-marks in (seq-take marks (or seen harness-voice-ribbon--rows))
               collect (cons row lane-marks)))))

(defun harness-voice-ribbon-linear-lines (p width &optional now)
  "Return P as the linear ribbon, WIDTH columns wide, at NOW.
One continuous bar with a run of bars at each stage's place, and no words
under it: the stages are told apart by their shapes and faces, and the words
of the pipe are read from the ribbon's own label and its runs' tooltips."
  (let* ((now (or now (float-time)))
         (width (max 12 width))
         (ribbon (harness-voice-ribbon-linear-rows p width now)))
    (mapcar (lambda (row)
              (harness-voice-ribbon--row-string (car row) (cdr row)))
            ribbon)))


(defconst harness-voice-ribbon--ring-rows 17
  "Rows the compact badge is drawn in.
A character cell is about twice as tall as it is wide, so a round badge
needs about half as many rows as columns.  Seventeen rows against
thirty-three columns is the closest a cell grid comes to a circle, and it
is large enough for the rim to carry the same density of bars the linear
ribbon draws.")

(defconst harness-voice-ribbon--ring-columns 33
  "Columns the compact badge is drawn in.")

(defconst harness-voice-ribbon--ring-rx 14.6
  "The badge's horizontal radius, in columns.")

(defconst harness-voice-ribbon--ring-ry 7.3
  "The badge's vertical radius, in rows.")

(defconst harness-voice-ribbon--ring-centre-row 8.0
  "The badge's centre row.")

(defconst harness-voice-ribbon--ring-centre-column 16.0
  "The badge's centre column.")



(defun harness-voice-ribbon-ring-angle (band)
  "Return BAND's fraction around the compact badge.
The first stage sits at twelve o'clock and the pipe runs clockwise, so
the angle is the stage, never how long anything waited."
  (let* ((order harness-voice-ribbon--band-order)
         (index (or (cl-position band order) 0)))
    (/ (float index) (length order))))

(defun harness-voice-ribbon-ring-point (fraction lane)
  "Return the (ROW . COLUMN) of FRACTION around the badge in LANE.
Twelve o'clock is FRACTION 0 and the badge runs clockwise; LANE draws a
second run of one stage further in, so two real bursts in one stage are two
runs, not one."
  (let* ((radius (max 0.55 (- 1.0 (* 0.2 lane))))
         (angle (* 2.0 float-pi fraction)))
    (cons (round (+ harness-voice-ribbon--ring-centre-row
                    (* -1.0 harness-voice-ribbon--ring-ry radius (cos angle))))
          (round (+ harness-voice-ribbon--ring-centre-column
                    (* harness-voice-ribbon--ring-rx radius (sin angle)))))))

(defconst harness-voice-ribbon--ring-samples 180
  "How finely the badge's rim is measured, for spacing bars along it.")

(defun harness-voice-ribbon--ring-arc-length (fraction lane)
  "Return the distance round the badge from twelve o'clock to FRACTION.
Measured on the ellipse the badge is drawn on, in the cells the badge uses,
so a run of bars spaced by this is evenly spaced on the screen rather than
evenly spaced in angle -- which bunches bars at the top of a wide ellipse."
  (let* ((radius (max 0.55 (- 1.0 (* 0.2 lane))))
         (rx (* harness-voice-ribbon--ring-rx radius))
         (ry (* harness-voice-ribbon--ring-ry radius))
         (steps (max 2 (round (* fraction harness-voice-ribbon--ring-samples))))
         (total 0.0))
    (cl-loop for step below steps
             for from = (* 2.0 float-pi (/ (float step)
                                          harness-voice-ribbon--ring-samples))
             for to = (* 2.0 float-pi (/ (float (1+ step))
                                         harness-voice-ribbon--ring-samples))
             do (cl-incf total
                         (sqrt (+ (expt (* rx (- (sin to) (sin from))) 2)
                                  (expt (* ry (- (cos to) (cos from))) 2)))))
    total))

(defun harness-voice-ribbon--ring-fraction (distance lane)
  "Return the fraction round the badge at DISTANCE cells past twelve o'clock.
The inverse of `harness-voice-ribbon--ring-arc-length', found by halving
the interval, so bars laid out by distance are evenly spaced on the rim."
  (let ((low 0.0) (high 1.0))
    (cl-loop repeat 24
             do (let ((middle (/ (+ low high) 2.0)))
                  (if (< (harness-voice-ribbon--ring-arc-length middle lane)
                         distance)
                      (setq low middle)
                    (setq high middle))))
    (/ (+ low high) 2.0)))

(defun harness-voice-ribbon--ring-distance (row column)
  "Return ROW and COLUMN's distance from the badge's centre, 1 at the rim."
  (let* ((dy (/ (- row harness-voice-ribbon--ring-centre-row)
                harness-voice-ribbon--ring-ry))
         (dx (/ (- column harness-voice-ribbon--ring-centre-column)
                harness-voice-ribbon--ring-rx)))
    (sqrt (+ (* dx dx) (* dy dy)))))

(defun harness-voice-ribbon-labels (p &optional now)
  "Return the words of every blip of P at NOW, oldest first.
A screen reader and a tooltip get the same list, so no blip is carried
by its shape or colour alone."
  (mapcar (lambda (blip) (harness-ui-one-line (plist-get blip :label)))
          (harness-voice-ribbon-blips p now)))

(defun harness-voice-ribbon-stage-labels (&optional p)
  "Return the ribbon's stage words with where each sits, in words.
With P, the words are the pipe's own: the same five headings and
tooltips the voice settings draw, so a camera session reads `Motion' and
`Mouth' rather than a microphone's words.  Without P they are the
microphone's."
  (if p
      (mapcar (lambda (column)
                (concat (nth 0 column) " · " (nth 1 column)))
              (harness-voice-pipeline-columns p))
    (mapcar (lambda (band)
              (concat (harness-voice-ribbon--band-title band)
                      " · " (harness-voice-ribbon--band-help band)))
            harness-voice-ribbon--band-order)))

(defun harness-voice-ribbon-ring-rows (p &optional now _room)
  "Return P's compact badge rows at NOW, without its words.
The same runs as the linear ribbon, drawn as a filled disc with the stages
on its rim: the first at twelve o'clock, the rest clockwise.  There is no
dotted scaffold and no key; the bars on the rim are the whole picture.
The badge is a fixed, compact block of cells, so a host centres it by
placing the rows; ROOM is accepted for a host that passes it and ignored."
  (let* ((now (or now (float-time)))
         (columns harness-voice-ribbon--ring-columns)
         (pairs (harness-voice-ribbon--lanes (harness-voice-ribbon-blips p now) now))
         (rows (cl-loop repeat harness-voice-ribbon--ring-rows
                        collect (vconcat
                                 (cl-loop repeat columns
                                          collect (cons ?\s
                                                        'harness-voice-ribbon-face)))))
         (marks (make-vector harness-voice-ribbon--ring-rows nil)))
    (cl-loop for row below harness-voice-ribbon--ring-rows
             do (cl-loop for column below columns
                         do (let ((distance
                                   (harness-voice-ribbon--ring-distance row column)))
                              (when (<= distance 1.08)
                                (aset (nth row rows) column
                                      (cons ?\s
                                            (if (>= distance 0.97)
                                                'harness-voice-ribbon-edge-face
                                              'harness-voice-ribbon-face)))))))
    ;; The rim carries no bed and no scaffold: the approved compact badge is
    ;; a bare disc until the pipe has something to say, and a dim ring of
    ;; short bars round it would be a measurement the pipe never made.
    (dolist (pair pairs)
      (let* ((blip (car pair))
             (band (plist-get blip :band))
             (lane (cdr pair))
             ;; A run reaches across its stage's own fifth of the rim,
             ;; less a gutter at each end, so the five runs together read as
             ;; one waveform round the circle rather than five lone marks.
             ;; The bars are spaced along the rim's own length, not along the
             ;; angle: on a wide ellipse an even angle bunches them at the
             ;; top and leaves the sides bare.
             ;; A stage owns a fifth of the rim, and its dashes fill that arc
             ;; at a pitch of their own, so the ring reads as a broken rim
             ;; rather than as five lone marks.  The count follows the arc's
             ;; own length in cells, which is what keeps the dashes as short
             ;; on the screen as the approved badge's.
             (stage-arc (/ (* (harness-voice-ribbon--ring-arc-length 1.0 lane) 0.94)
                           (length harness-voice-ribbon--band-order)))
             ;; One cell a mark: a character grid's rim is already coarse,
             ;; so the marks sit in consecutive cells and read as dashes
             ;; rather than as isolated dots.
             (dashes (max 5 (round (/ stage-arc 1.0))))
             (span (* dashes 1.0))
             (glyphs (harness-voice-ribbon--run-glyphs blip dashes now))
             (start (- (harness-voice-ribbon--ring-arc-length
                        (harness-voice-ribbon-ring-angle band) lane)
                       (/ span 2.0)))
             (face (harness-voice-ribbon-face blip))
             (help (harness-ui-one-line (plist-get blip :label))))
        (cl-loop for glyph across glyphs
                 for offset from 0
                 do (let* ((point (harness-voice-ribbon-ring-point
                                   (harness-voice-ribbon--ring-fraction
                                    (max 0.0 (+ start (float offset)))
                                    lane)
                                   lane))
                           (row (car point))
                           (column (cdr point)))
                      (when (and (>= row 0) (< row (length rows))
                                 (>= column 0) (< column columns))
                        (aset (nth row rows) column (cons glyph face))
                        (aset marks row
                              (append (aref marks row)
                                      (list (list column face help)))))))))
    (cl-loop for row in rows
             for index from 0
             collect (let* ((string (apply #'concat
                                           (cl-loop for cell across row
                                                    collect (propertize
                                                             (char-to-string
                                                              (car cell))
                                                             'face (cdr cell))))))
                       (dolist (mark (aref marks index))
                         (add-text-properties (nth 0 mark)
                                              (min (length string)
                                                   (1+ (nth 0 mark)))
                                              (list 'help-echo (nth 2 mark))
                                              string))
                       string))))

(defun harness-voice-ribbon-ring-lines (p &optional now room)
  "Return P as the compact badge at NOW.
ROOM is the width the badge has, when the host knows it: the badge is
centred in it.  It carries no words of its own."
  (harness-voice-ribbon-ring-rows p now (or room 40)))

(defun harness-voice-ribbon-summary (p width &optional now)
  "Return P's summary at NOW as one string, wrapped to WIDTH columns.
Every fact stays, and the breaks fall between words, so a narrow surface
reads a list of facts rather than words cut at the window's edge.  It is a
screen reader's label and the settings' line, never drawn in the control."
  (let* ((summary (harness-voice-pipeline-summary p now))
         (plain (substring-no-properties summary)))
    (if (<= (string-width plain) width)
        summary
      (string-join (harness-voice-ribbon-wrap-text plain width) "\n"))))

(defun harness-voice-ribbon-wrap-text (text width)
  "Return TEXT as lines of at most WIDTH columns, broken at spaces.
Every character of TEXT stays in the lines, in order, so a wrapped
summary says exactly what the one line said."
  (let* ((width (max 8 width))
         (text (substring-no-properties text))
         (lines nil)
         (start 0)
         (length (length text)))
    (while (< start length)
      (let ((end (min length (+ start width))))
        (when (< end length)
          (let ((space (cl-loop for index downfrom (1- end) to start
                                when (eq ?\s (aref text index))
                                return index)))
            (when space (setq end (1+ space)))))
        (push (string-trim-right (substring text start end)) lines)
        (setq start end)
        (while (and (< start length) (eq ?\s (aref text start)))
          (cl-incf start))))
    (or (nreverse lines) (list ""))))

(defcustom harness-voice-ribbon-linear-minimum 46
  "The narrowest window that gets the linear ribbon.
Below it the same runs are drawn on the compact badge, where the five
stages fit without a word and without a key."
  :type 'natnum
  :group 'harness-voice-ribbon)

(defun harness-voice-ribbon-line (p &optional width now)
  "Return P's ribbon in a form that fits WIDTH at NOW.
A full-size surface gets the linear ribbon; a narrow one gets the ring,
which is the same blips in the same order around a circle."
  (let ((width (or width harness-voice-pipeline-width)))
    (if (>= width harness-voice-ribbon-linear-minimum)
        (harness-voice-ribbon-linear-lines p width now)
      (harness-voice-ribbon-ring-lines p now width))))

;;;; The block a transcript draws

(defun harness-voice-ribbon-block (p width &optional now)
  "Return P's ribbon block for a buffer WIDTH columns wide, at NOW.
The ribbon in the form that fits WIDTH, and nothing else: no heading,
no stage key, no legend and no status line.  The stages are told apart
by the shapes and faces of their bars; the words of the pipe are the
control's screen-reader label, and its measurements are in the voice
settings."
  (harness-voice-ribbon-line p width now))

(defun harness-voice-ribbon-details (p width &optional now)
  "Return P's pipe lines: the stage table and every marker at NOW.
The ribbon shows where each thing is; this says each thing in full.  It
is what the voice settings show, and a screen reader and a copied buffer
have every id and measurement from it."
  (append
   (harness-voice-pipeline-lines p width now)
   (harness-voice-pipeline-details p)))

(provide 'harness-ui-voice-ribbon)
;;; harness-ui-voice-ribbon.el ends here
