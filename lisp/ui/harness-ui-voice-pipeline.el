;;; harness-ui-voice-pipeline.el --- The voice pipeline in the Emacs UI  -*- lexical-binding: t; -*-

;;; Commentary:

;; The voice pipeline from microphone to speaker, as Emacs sees it: the
;; level before the speech filter, the bursts the filter kept and did not
;; keep with the reason, their transcript, the agent turn they were sent
;; in, and what the speaker is doing -- silent, ready, held, handed to the
;; voice provider, or really playing.
;;
;; `harness-voice-pipeline' is the state model.  It is fed only by events
;; the live voice sidecar and this UI really produce.  Nothing advances on
;; a clock: a marker moves when the stage it waits on reports, and a stage
;; that has not reported says it is waiting.  The model starts no process
;; and reads no audio, so the tests drive it with scripted events and a
;; scripted sidecar.
;;
;; `harness-voice-live' (harness-ui-voice-live) owns one of these for its
;; session and feeds it from the sidecar protocol: `level' and `segment'
;; carry the capture path's own measurements and decisions, `speech' the
;; gate, `hearing' / `transcribing' / `user_delta' the words, `speaking' /
;; `listening' / `interrupted' the speaker, and a `delegation', the
;; assistant text and `agent/turn-ended' the turn.  The model draws the
;; wide strip in the `*harness voice*' transcript, the same facts as a
;; summary line, and the compact line under the compose box.
;;
;; The words match the Flutter client's strip
;; (docs/voice-pipeline-visualization.md): the same stages, the same drop
;; reasons, the same distinction between a reply handed to a provider and
;; a reply that is playing.  Only the speaker's label differs --
;; `Speaker · speaking' rather than `Voice · speaking' -- because the
;; voice transcript already names the provider with `Voice · ...'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-ui)

(defgroup harness-voice-pipeline nil
  "The voice pipeline's state and its drawing."
  :group 'harness-ui)

(defcustom harness-voice-pipeline-level-timeout 2.0
  "Seconds after which a level that stopped arriving is no data.
A level is the microphone's own measurement.  A meter that kept the
last value would show a room that went quiet as if it still had sound,
so a level older than this is drawn as `Level · no data' and never as
silence."
  :type 'number
  :group 'harness-voice-pipeline)

(defcustom harness-voice-pipeline-segments 6
  "How many bursts the strip keeps, newest first.
The totals keep counting what the strip no longer shows."
  :type 'natnum
  :group 'harness-voice-pipeline)

(defcustom harness-voice-pipeline-turns 3
  "How many turns the strip keeps, newest first."
  :type 'natnum
  :group 'harness-voice-pipeline)

(defcustom harness-voice-pipeline-replies 3
  "How many replies the strip keeps, newest first."
  :type 'natnum
  :group 'harness-voice-pipeline)

(defcustom harness-voice-pipeline-width 80
  "Columns assumed when the pipeline is drawn without a window.
The transcript's own window width is used whenever it shows the strip;
this is the fallback for a buffer drawn while no window shows it, and
for the tests."
  :type 'natnum
  :group 'harness-voice-pipeline)

;;;; Stages and their words

(defconst harness-voice-pipeline--stage-rank
  '((accepted . 1) (transcribing . 2) (transcribed . 3) (in-turn . 4) (answered . 5))
  "How far a kept burst has moved through the pipe.")

(defconst harness-voice-pipeline--terminal-stages '(dropped failed answered)
  "Stages a kept burst never leaves.
A late event cannot resurrect a burst the path ended, a model failed,
or a turn already answered.")

(defconst harness-voice-pipeline--turn-rank
  '((queued . 0) (working . 1) (replied . 2) (done . 3))
  "How far a turn has moved.")

(defconst harness-voice-pipeline--turn-terminal '(done failed cancelled)
  "Turn states a turn never leaves.")

(defconst harness-voice-pipeline--reply-terminal
  '(spoken interrupted dropped failed)
  "Reply states a reply never leaves.")

(defconst harness-voice-pipeline--drop-labels
  '((too-short . "too short") (no-words . "no words")
    (cancelled . "cancelled") (failed . "failed"))
  "The words for why a burst did not reach a model.")

(defconst harness-voice-pipeline--capture-labels
  '((off . "off") (connecting . "connecting") (live . "live")
    (muted . "muted") (paused . "paused") (failed . "failed")
    (disconnected . "disconnected") (ended . "ended"))
  "The words for where the microphone is.")

(defconst harness-voice-pipeline--levels
  ["▁" "▂" "▃" "▄" "▅" "▆" "▇"]
  "The partial blocks a VU bar is made of, shortest first.")

(defun harness-voice-pipeline--stage-label (stage)
  "Return the word for segment STAGE."
  (pcase stage
    ('accepted "accepted")
    ('transcribing "transcribing")
    ('transcribed "transcribed")
    ('in-turn "in turn")
    ('answered "answered")
    ('dropped "dropped")
    ('failed "failed")
    (_ (symbol-name stage))))

(defun harness-voice-pipeline--reply-label (stage)
  "Return the word for reply STAGE."
  (pcase stage
    ('ready "ready")
    ('held "held")
    ('handed "handed")
    ('speaking "speaking")
    ('spoken "spoken")
    ('interrupted "interrupted")
    ('dropped "dropped")
    ('failed "failed")
    (_ (symbol-name stage))))

(defun harness-voice-pipeline--drop-label (reason)
  "Return the words for drop REASON."
  (or (alist-get reason harness-voice-pipeline--drop-labels)
      (and reason (symbol-name reason))))

(defun harness-voice-pipeline--capture-label (capture)
  "Return the words for microphone state CAPTURE."
  (or (alist-get capture harness-voice-pipeline--capture-labels) "off"))

(defun harness-voice-pipeline--turn-label (state)
  "Return the word for turn STATE."
  (pcase state
    ('queued "queued")
    ('working "working")
    ('replied "replied")
    ('done "done")
    ('failed "failed")
    ('cancelled "cancelled")
    (_ (symbol-name state))))

(defun harness-voice-pipeline--duration (seconds)
  "Return SECONDS as a short duration: 640ms, 1.4s, 12s."
  (let ((seconds (or seconds 0)))
    (cond
     ((< seconds 1) (format "%dms" (round (* 1000 seconds))))
     ((< seconds 10) (format "%.1fs" seconds))
     (t (format "%ds" (round seconds))))))

(defun harness-voice-pipeline--excerpt (text &optional max)
  "Return the first MAX characters of TEXT on one line."
  (let* ((max (or max 48))
         (line (string-trim (replace-regexp-in-string "[ \t\n]+" " " text))))
    (if (<= (length line) max)
        line
      (concat (substring line 0 (1- max)) "…"))))

(defun harness-voice-pipeline--line (parts)
  "Join the non-empty PARTS with the app's dim dot."
  (string-join
   (delq nil (mapcar (lambda (part)
                       (and (stringp part) (not (string-empty-p part)) part))
                     parts))
   (propertize " · " 'face 'harness-dim-face)))

;;;; The model

(cl-defstruct (harness-voice-pipeline (:constructor harness-voice-pipeline--make))
  (generation 1)
  (capture 'off)
  (problem nil)
  (level 0.0)
  (level-seen nil)
  (level-at nil)
  (gate nil)
  (segments nil)
  (accepted 0)
  (dropped 0)
  (turns nil)
  (replies nil)
  (ignored 0)
  (dirty nil))

(defun harness-voice-pipeline-create (&optional capture)
  "Return a new pipeline with microphone state CAPTURE."
  (harness-voice-pipeline--make :capture (or capture 'off)))

(defun harness-voice-pipeline--changed (p)
  "Mark P as changed and return it."
  (setf (harness-voice-pipeline-dirty p) t)
  p)

(defun harness-voice-pipeline--current (p generation)
  "Return non-nil when GENERATION is nil or is P's generation."
  (or (null generation) (eql generation (harness-voice-pipeline-generation p))))

(defun harness-voice-pipeline-bump (p &optional capture)
  "Begin a new conversation in P, with microphone state CAPTURE.
The generation is raised, so an event that names the last conversation
changes nothing here.  The stored state is cleared first; CAPTURE is
the new session's own state."
  (cl-incf (harness-voice-pipeline-generation p))
  (setf (harness-voice-pipeline-capture p) (or capture 'connecting)
        (harness-voice-pipeline-problem p) nil
        (harness-voice-pipeline-level p) 0.0
        (harness-voice-pipeline-level-seen p) nil
        (harness-voice-pipeline-level-at p) nil
        (harness-voice-pipeline-gate p) nil
        (harness-voice-pipeline-segments p) nil
        (harness-voice-pipeline-accepted p) 0
        (harness-voice-pipeline-dropped p) 0
        (harness-voice-pipeline-turns p) nil
        (harness-voice-pipeline-replies p) nil
        (harness-voice-pipeline-ignored p) 0)
  (harness-voice-pipeline--changed p))

(defun harness-voice-pipeline-set-capture (p capture &optional problem generation)
  "Record that the microphone is in CAPTURE state.
PROBLEM is the backend's own words about a failure, or nil.  A state
that is not `live' closes the gate: the capture path is not hearing
anything it could report, and the strip must not keep showing speech."
  (when (harness-voice-pipeline--current p generation)
    (let ((changed (or (not (eq capture (harness-voice-pipeline-capture p)))
                       (not (equal problem (harness-voice-pipeline-problem p))))))
      (setf (harness-voice-pipeline-capture p) capture
            (harness-voice-pipeline-problem p) problem)
      (unless (eq capture 'live)
        (setf (harness-voice-pipeline-gate p) nil))
      (when changed (harness-voice-pipeline--changed p))))
  p)

(defun harness-voice-pipeline-set-level (p level &optional at generation)
  "Record that the capture path measured LEVEL, 0..1, at AT.
LEVEL is the microphone's own measurement before the speech filter.
Out-of-range and non-numeric values are dropped rather than drawn: a
meter is a measurement, not a decoration."
  (when (and (harness-voice-pipeline--current p generation)
             (numberp level)
             (>= level 0.0)
             (<= level 1.0))
    (setf (harness-voice-pipeline-level p) (float level)
          (harness-voice-pipeline-level-seen p) t
          (harness-voice-pipeline-level-at p) (or at (float-time)))
    (harness-voice-pipeline--changed p))
  p)

(defun harness-voice-pipeline-clear-level (p &optional generation)
  "Forget the level in P: the microphone closed, or the session ended."
  (when (harness-voice-pipeline--current p generation)
    (setf (harness-voice-pipeline-level p) 0.0
          (harness-voice-pipeline-level-seen p) nil
          (harness-voice-pipeline-level-at p) nil)
    (harness-voice-pipeline--changed p))
  p)

(defun harness-voice-pipeline-level-stale-p (p &optional now)
  "Return non-nil when P's last level is too old to stand for the present."
  (let ((at (harness-voice-pipeline-level-at p)))
    (or (not (harness-voice-pipeline-level-seen p))
        (null at)
        (> (- (or now (float-time)) at) harness-voice-pipeline-level-timeout))))

(defun harness-voice-pipeline-set-gate (p active &optional generation)
  "Record whether the speech gate hears speech now, ACTIVE."
  (when (harness-voice-pipeline--current p generation)
    (unless (eq (and active t) (harness-voice-pipeline-gate p))
      (setf (harness-voice-pipeline-gate p) (and active t))
      (harness-voice-pipeline--changed p)))
  p)

;;;; Segments

(defun harness-voice-pipeline--segment (p id)
  "Return P's segment with ID, or nil."
  (cl-find id (harness-voice-pipeline-segments p)
           :key (lambda (segment) (plist-get segment :id)) :test #'equal))

(defun harness-voice-pipeline--put-segment (p id segment)
  "Store SEGMENT under ID in P, newest first, and bound the list."
  (setf (harness-voice-pipeline-segments p)
        (cons segment
              (cl-remove id (harness-voice-pipeline-segments p)
                         :key (lambda (item) (plist-get item :id)) :test #'equal)))
  (when (> (length (harness-voice-pipeline-segments p)) harness-voice-pipeline-segments)
    (setf (harness-voice-pipeline-segments p)
          (seq-take (harness-voice-pipeline-segments p) harness-voice-pipeline-segments)))
  p)

(defun harness-voice-pipeline-segment (p id stage &optional args)
  "Record that segment ID is at STAGE in P.
ARGS is a plist of :seconds, :reason, :text, :at and :generation.  A
kept burst moves forward only: a late or duplicate event changes
nothing and is counted in `harness-voice-pipeline-ignored'.  A terminal
stage is never left."
  (when (and (stringp id) (not (string-empty-p id))
             (harness-voice-pipeline--current p (plist-get args :generation)))
    (let* ((now (or (plist-get args :at) (float-time)))
           (seconds (plist-get args :seconds))
           (reason (plist-get args :reason))
           (text (and (plist-get args :text)
                      (not (string-empty-p (plist-get args :text)))
                      (plist-get args :text)))
           (existing (harness-voice-pipeline--segment p id)))
      (if (null existing)
          (progn
            (harness-voice-pipeline--put-segment
             p id (list :id id :stage stage :seconds seconds :reason reason
                        :text text :at now))
            ;; A burst first seen past the filter was kept by it: the
            ;; accept event is only missing, not untrue.  A failed one was
            ;; not counted as kept, and a dropped one is its own count.
            (when (memq stage '(accepted transcribing transcribed in-turn answered))
              (cl-incf (harness-voice-pipeline-accepted p)))
            (when (eq stage 'dropped)
              (cl-incf (harness-voice-pipeline-dropped p)))
            (harness-voice-pipeline--changed p))
        (let ((current (plist-get existing :stage)))
          (cond
           ((memq current harness-voice-pipeline--terminal-stages)
            (cl-incf (harness-voice-pipeline-ignored p)))
           ((eq stage 'dropped)
            ;; The path ended a burst it had kept: it stays a real
            ;; measurement of what was lost, with its own reason.
            (setf (plist-get existing :stage) 'dropped
                  (plist-get existing :reason) (or reason 'cancelled)
                  (plist-get existing :seconds) (or seconds (plist-get existing :seconds)))
            (cl-incf (harness-voice-pipeline-dropped p))
            (harness-voice-pipeline--changed p))
           ((eq stage 'failed)
            (setf (plist-get existing :stage) 'failed
                  (plist-get existing :reason) (or reason 'failed))
            (harness-voice-pipeline--changed p))
           ((<= (or (alist-get stage harness-voice-pipeline--stage-rank) 0)
                (or (alist-get current harness-voice-pipeline--stage-rank) 0))
            ;; A duplicate or a late earlier stage: the marker is already
            ;; where it really is, and stays there.
            (cl-incf (harness-voice-pipeline-ignored p)))
           (t
            (setf (plist-get existing :stage) stage)
            (when seconds (setf (plist-get existing :seconds) seconds))
            (when text (setf (plist-get existing :text) text))
            (harness-voice-pipeline--changed p)))
          ;; The text of a partial replaces the marker's words without
          ;; moving it, and a final that arrives after a partial writes
          ;; the same segment, never a second one.
          (when (and text (not (memq current harness-voice-pipeline--terminal-stages))
                     (not (equal text (plist-get existing :text))))
            (setf (plist-get existing :text) text)
            (harness-voice-pipeline--changed p)))))
    p))

;;;; Turns

(defun harness-voice-pipeline--turn (p id)
  "Return P's turn with ID, or nil."
  (cl-find id (harness-voice-pipeline-turns p)
           :key (lambda (turn) (plist-get turn :id)) :test #'equal))

(defun harness-voice-pipeline--put-turn (p id turn)
  "Store TURN under ID in P, newest first."
  (setf (harness-voice-pipeline-turns p)
        (cons turn (cl-remove id (harness-voice-pipeline-turns p)
                              :key (lambda (item) (plist-get item :id)) :test #'equal)))
  (when (> (length (harness-voice-pipeline-turns p)) harness-voice-pipeline-turns)
    (setf (harness-voice-pipeline-turns p)
          (seq-take (harness-voice-pipeline-turns p) harness-voice-pipeline-turns)))
  p)

(defun harness-voice-pipeline-turn (p id state &optional args)
  "Record that turn ID is in STATE in P.
ARGS is a plist of :segment, :reply, :detail, :at and :generation.  A
turn moves forward only; a finished turn is never reopened, so a stale
event cannot send it back to working."
  (when (and (stringp id) (not (string-empty-p id))
             (harness-voice-pipeline--current p (plist-get args :generation)))
    (let* ((now (or (plist-get args :at) (float-time)))
           (segment (plist-get args :segment))
           (reply (plist-get args :reply))
           (detail (plist-get args :detail))
           (existing (harness-voice-pipeline--turn p id)))
      (if (null existing)
          (progn
            (harness-voice-pipeline--put-turn
             p id (list :id id :state state :segments (and segment (list segment))
                        :replies (and reply (list reply)) :detail detail :at now))
            (harness-voice-pipeline--changed p))
        (let ((current (plist-get existing :state)))
          (cond
           ((memq current harness-voice-pipeline--turn-terminal)
            (cl-incf (harness-voice-pipeline-ignored p)))
           ((and (memq state '(working replied done))
                 (<= (or (alist-get state harness-voice-pipeline--turn-rank) 0)
                     (or (alist-get current harness-voice-pipeline--turn-rank) 0)))
            (cl-incf (harness-voice-pipeline-ignored p)))
           (t
            (setf (plist-get existing :state) state)
            (when detail (setf (plist-get existing :detail) detail))
            (harness-voice-pipeline--changed p)))
          (when (and segment (not (member segment (plist-get existing :segments))))
            (setf (plist-get existing :segments)
                  (append (plist-get existing :segments) (list segment)))
            (harness-voice-pipeline--changed p))
          (when (and reply (not (member reply (plist-get existing :replies))))
            (setf (plist-get existing :replies)
                  (append (plist-get existing :replies) (list reply)))
            (harness-voice-pipeline--changed p)))))
    p))

;;;; Replies

(defun harness-voice-pipeline--reply (p id)
  "Return P's reply with ID, or nil."
  (cl-find id (harness-voice-pipeline-replies p)
           :key (lambda (reply) (plist-get reply :id)) :test #'equal))

(defun harness-voice-pipeline--put-reply (p id reply)
  "Store REPLY under ID in P, newest first."
  (setf (harness-voice-pipeline-replies p)
        (cons reply (cl-remove id (harness-voice-pipeline-replies p)
                               :key (lambda (item) (plist-get item :id)) :test #'equal)))
  (when (> (length (harness-voice-pipeline-replies p)) harness-voice-pipeline-replies)
    (setf (harness-voice-pipeline-replies p)
          (seq-take (harness-voice-pipeline-replies p) harness-voice-pipeline-replies)))
  p)

(defun harness-voice-pipeline--reply-audible-p (reply)
  "Return non-nil when REPLY may still be heard."
  (not (memq (plist-get reply :stage) harness-voice-pipeline--reply-terminal)))

(defun harness-voice-pipeline-reply (p id stage &optional args)
  "Record that reply ID is in STAGE in P.
ARGS is a plist of :turn, :text, :detail, :at and :generation.  Ready,
held, handed and speaking are distinct facts, and a terminal stage is
never left: a late playback event cannot resurrect a reply."
  (when (and (stringp id) (not (string-empty-p id))
             (harness-voice-pipeline--current p (plist-get args :generation)))
    (let* ((now (or (plist-get args :at) (float-time)))
           (turn (plist-get args :turn))
           (text (plist-get args :text))
           (detail (plist-get args :detail))
           (existing (harness-voice-pipeline--reply p id)))
      (if (null existing)
          (progn
            (harness-voice-pipeline--put-reply
             p id (list :id id :stage stage :turn turn :text text
                        :detail detail :at now))
            (harness-voice-pipeline--changed p))
        (let ((current (plist-get existing :stage)))
          (cond
           ((memq current harness-voice-pipeline--reply-terminal)
            (cl-incf (harness-voice-pipeline-ignored p)))
           ;; Handed is not speaking: the provider was given the text and
           ;; may start its own audio later, or never.  A reply already
           ;; speaking is not sent back to handed.
           ((and (eq current 'speaking) (memq stage '(ready held handed)))
            (cl-incf (harness-voice-pipeline-ignored p)))
           ((eq stage current)
            (cl-incf (harness-voice-pipeline-ignored p)))
           (t
            (setf (plist-get existing :stage) stage)
            (when turn (setf (plist-get existing :turn) turn))
            (when text (setf (plist-get existing :text) text))
            (when detail (setf (plist-get existing :detail) detail))
            (harness-voice-pipeline--changed p)))))
    p)))

(defun harness-voice-pipeline--finish (p stage detail &optional generation)
  "Move every audible reply in P to STAGE with DETAIL."
  (dolist (reply (harness-voice-pipeline-replies p))
    (when (harness-voice-pipeline--reply-audible-p reply)
      (harness-voice-pipeline-reply
       p (plist-get reply :id) stage (list :detail detail :generation generation))))
  p)

;;;; Derived facts

(defun harness-voice-pipeline-finish-replies (p stage detail &optional generation)
  "Move every reply of P that could still be heard to STAGE with DETAIL."
  (harness-voice-pipeline--finish p stage detail generation))

(defun harness-voice-pipeline-capture-label (p)
  "Return P's microphone label, a noun phrase such as `Mic · live'."
  (concat "Mic · " (harness-voice-pipeline--capture-label
                    (harness-voice-pipeline-capture p))))

(defun harness-voice-pipeline-level-label (p &optional now)
  "Return P's level label: the measurement, or `Level · no data'.
A closed microphone and a stale measurement both say they have no data,
never 0%: an absent level must not read as a quiet room."
  (if (or (not (eq (harness-voice-pipeline-capture p) 'live))
          (harness-voice-pipeline-level-stale-p p now))
      "Level · no data"
    (format "Level · %d%%" (round (* 100.0 (harness-voice-pipeline-level p))))))

(defun harness-voice-pipeline-meter (p &optional cells now)
  "Return P's VU bars, CELLS wide, as block characters.
An absent level leaves the bars unlit: a meter is drawn only from a
measurement the capture path sent."
  (let* ((cells (or cells 8))
         (time (or now (float-time)))
         (lit (if (or (not (eq (harness-voice-pipeline-capture p) 'live))
                      (harness-voice-pipeline-level-stale-p p time))
                  0.0
                (* cells (harness-voice-pipeline-level p)))))
    (cl-loop for index below cells
             concat (let ((fill (- lit index)))
                      (cond
                       ((>= fill 1.0) "█")
                       ((<= fill 0.0) "·")
                       (t (aref harness-voice-pipeline--levels
                                (max 0 (1- (round (* 7 fill)))))))))))

(defun harness-voice-pipeline-gate-label (p)
  "Return P's speech gate label, or nil while the gate is quiet."
  (when (harness-voice-pipeline-gate p) "Speech · heard"))

(defun harness-voice-pipeline-count-label (p)
  "Return P's counts as `2 accepted · 1 dropped', or nil."
  (let ((parts nil))
    (when (> (harness-voice-pipeline-accepted p) 0)
      (push (format "%d accepted" (harness-voice-pipeline-accepted p)) parts))
    (when (> (harness-voice-pipeline-dropped p) 0)
      (push (format "%d dropped" (harness-voice-pipeline-dropped p)) parts))
    (when parts (string-join (nreverse parts) " · "))))

(defun harness-voice-pipeline-current-turn (p)
  "Return P's turn in flight, or its last turn, or nil."
  (let ((turns (harness-voice-pipeline-turns p)))
    (or (cl-find-if (lambda (turn) (memq (plist-get turn :state) '(working replied)))
                    turns)
        (car turns))))

(defun harness-voice-pipeline-turn-label (p)
  "Return P's turn label, or nil before anything was sent."
  (when-let* ((turn (harness-voice-pipeline-current-turn p)))
    (concat "Turn · " (harness-voice-pipeline--turn-label (plist-get turn :state)))))

(defun harness-voice-pipeline-output (p)
  "Return what P's speaker endpoint is doing now.
`speaking' is only the provider's own playback; `handed' means the text
was given to it, which is not the same fact."
  (let* ((replies (harness-voice-pipeline-replies p))
         (audible (cl-remove-if-not #'harness-voice-pipeline--reply-audible-p replies))
         (stages (mapcar (lambda (reply) (plist-get reply :stage)) audible))
         (interrupted (cl-find-if (lambda (reply)
                                    (eq (plist-get reply :stage) 'interrupted))
                                  replies)))
    (cond ((memq 'speaking stages) 'speaking)
          ((memq 'failed stages) 'failed)
          ((memq 'handed stages) 'handed)
          ((memq 'held stages) 'held)
          ((memq 'ready stages) 'ready)
          (interrupted 'interrupted)
          (t 'silent))))

(defun harness-voice-pipeline-speaker-label (p)
  "Return P's speaker label, a noun phrase such as `Speaker · speaking'."
  (concat "Speaker · " (harness-voice-pipeline--reply-label
                        (harness-voice-pipeline-output p))))

;;;; The words

(defun harness-voice-pipeline-summary (p &optional now)
  "Return every fact of P's pipe on one line.
A screen reader reads it and the compact presentation shows it, so no
fact of the pipe is carried by colour or motion alone."
  (harness-voice-pipeline--line
   (list (harness-voice-pipeline-capture-label p)
         (harness-voice-pipeline-level-label p now)
         (harness-voice-pipeline-gate-label p)
         (harness-voice-pipeline-count-label p)
         (harness-voice-pipeline-turn-label p)
         (harness-voice-pipeline-speaker-label p)
         (harness-voice-pipeline-problem p))))

(defun harness-voice-pipeline-short-summary (p)
  "Return P's facts without the meter, for a narrow surface."
  (harness-voice-pipeline--line
   (list (harness-voice-pipeline-capture-label p)
         (harness-voice-pipeline-count-label p)
         (harness-voice-pipeline-turn-label p)
         (harness-voice-pipeline-speaker-label p)
         (harness-voice-pipeline-problem p))))

(defun harness-voice-pipeline-segment-line (segment)
  "Return SEGMENT as one line of words, for the details."
  (harness-voice-pipeline--line
   (list (plist-get segment :id)
         (harness-voice-pipeline--stage-label (plist-get segment :stage))
         (and (plist-get segment :seconds)
              (harness-voice-pipeline--duration (plist-get segment :seconds)))
         (and (eq (plist-get segment :stage) 'dropped)
              (harness-voice-pipeline--drop-label (plist-get segment :reason)))
         (and (plist-get segment :text)
              (format "\"%s\"" (harness-voice-pipeline--excerpt (plist-get segment :text)))))))

(defun harness-voice-pipeline-turn-line (turn)
  "Return TURN as one line of words, for the details."
  (let ((segments (plist-get turn :segments))
        (replies (plist-get turn :replies)))
    (harness-voice-pipeline--line
     (list (plist-get turn :id)
           (harness-voice-pipeline--turn-label (plist-get turn :state))
           (and segments (format "%d %s" (length segments)
                                 (if (= 1 (length segments)) "utterance" "utterances")))
           (and replies (format "%d %s" (length replies)
                                (if (= 1 (length replies)) "reply" "replies")))
           (plist-get turn :detail)))))

(defun harness-voice-pipeline-reply-line (reply)
  "Return REPLY as one line of words, for the details."
  (harness-voice-pipeline--line
   (list (plist-get reply :id)
         (harness-voice-pipeline--reply-label (plist-get reply :stage))
         (plist-get reply :turn)
         (plist-get reply :detail)
         (and (plist-get reply :text)
              (format "\"%s\"" (harness-voice-pipeline--excerpt (plist-get reply :text)))))))

(defun harness-voice-pipeline-details (p)
  "Return every marker of P as a line of words, newest first."
  (let ((lines (append (mapcar #'harness-voice-pipeline-segment-line
                               (harness-voice-pipeline-segments p))
                       (mapcar #'harness-voice-pipeline-turn-line
                               (harness-voice-pipeline-turns p))
                       (mapcar #'harness-voice-pipeline-reply-line
                               (harness-voice-pipeline-replies p)))))
    (or lines (list "No segments yet"))))

;;;; The drawing

(defun harness-voice-pipeline--word (text face)
  "Return TEXT in FACE, or nil for an empty TEXT."
  (and text (not (string-empty-p text)) (propertize text 'face face)))

(defun harness-voice-pipeline--column-heading (heading tooltip)
  "Return the propertized column HEADING with TOOLTIP."
  (propertize heading 'face 'harness-label-face 'help-echo tooltip
              'harness-voice-pipeline-column heading))

(defun harness-voice-pipeline--words-column (segment)
  "Return the Words column lines for SEGMENT, the newest kept burst."
  (when segment
    (let ((stage (plist-get segment :stage))
          (seconds (plist-get segment :seconds)))
      (list
       (pcase stage
         ('transcribing (harness-voice-pipeline--word
                         (concat "⋯ transcribing"
                                 (when seconds
                                   (concat " · " (harness-voice-pipeline--duration seconds))))
                         'harness-thinking-face))
         ('transcribed (harness-voice-pipeline--word
                        (concat "≡ transcribed"
                                (when seconds
                                  (concat " · " (harness-voice-pipeline--duration seconds))))
                        'harness-agent-face))
         ('in-turn (harness-voice-pipeline--word "≡ in turn" 'harness-agent-face))
         ('answered (harness-voice-pipeline--word "✓ answered" 'harness-success-face))
         ('accepted (harness-voice-pipeline--word "◌ accepted" 'harness-dim-face)))))))

(defun harness-voice-pipeline-columns (p &optional now)
  "Return P's five columns as (HEADING TOOLTIP LINES) lists.
LINES are the words under HEADING, most important first.  Every fact is
a word; the glyph is a mark, never the only signal."
  (let* ((segment (cl-find-if
                   (lambda (item) (not (memq (plist-get item :stage) '(dropped failed))))
                   (harness-voice-pipeline-segments p)))
         (turn (harness-voice-pipeline-current-turn p))
         (turn-state (plist-get turn :state))
         (output (harness-voice-pipeline-output p))
         (gate (harness-voice-pipeline-gate-label p))
         (accepted (harness-voice-pipeline-accepted p))
         (dropped (harness-voice-pipeline-dropped p))
         (utterances (length (plist-get turn :segments)))
         (replies (length (plist-get turn :replies)))
         (columns
          (list
           (list "Input" "Microphone level before the speech filter"
                 (list (concat (propertize (harness-voice-pipeline-meter p 8 now)
                                           'face 'harness-success-face)
                               " " (harness-voice-pipeline--word
                                    (harness-voice-pipeline-level-label p now)
                                    'harness-label-face))
                       (harness-voice-pipeline--word
                        (harness-voice-pipeline-capture-label p) 'harness-dim-face)))
           (list "Filter" "Speech kept for transcription"
                 (delq nil
                       (list (and gate (harness-voice-pipeline--word
                                        (concat "● " gate) 'harness-caution-face))
                             (and (> accepted 0)
                                  (harness-voice-pipeline--word
                                   (format "● %d accepted" accepted) 'harness-agent-face))
                             (and (> dropped 0)
                                  (harness-voice-pipeline--word
                                   (format "× %d dropped" dropped) 'harness-dim-face)))))
           (list "Words" "Speech to text"
                 (harness-voice-pipeline--words-column segment))
           (list "Turn" "Agent work"
                 (delq nil
                       (list (when turn
                               (harness-voice-pipeline--word
                                (pcase turn-state
                                  ('queued "◌ queued") ('working "⋯ working")
                                  ('replied "✓ replied") ('done "✓ done")
                                  ('failed "✕ failed") ('cancelled "× cancelled")
                                  (_ "·"))
                                (pcase turn-state
                                  ('working 'harness-thinking-face)
                                  ('failed 'harness-failure-face)
                                  ('done 'harness-success-face)
                                  (_ 'harness-agent-face))))
                             (and (> utterances 0)
                                  (harness-voice-pipeline--word
                                   (format "%d %s" utterances
                                           (if (= 1 utterances) "utterance" "utterances"))
                                   'harness-dim-face))
                             (and (> replies 0)
                                  (harness-voice-pipeline--word
                                   (format "%d %s" replies
                                           (if (= 1 replies) "reply" "replies"))
                                   'harness-dim-face)))))
           (list "Speaker" "Playback"
                 (list (harness-voice-pipeline--word
                        (pcase output
                          ('speaking "▷ speaking") ('held "‖ held")
                          ('handed "→ handed") ('ready "◌ ready")
                          ('interrupted "× interrupted") ('failed "✕ failed")
                          (_ "· silent"))
                        (pcase output
                          ('speaking 'harness-caution-face)
                          ('held 'harness-thinking-face)
                          ('failed 'harness-failure-face)
                          ('silent 'harness-dim-face)
                          (_ 'harness-agent-face))))))))
    ;; A column with nothing to report yet says so with one dim mark
    ;; rather than an empty space that could read as missing data.
    (mapcar (lambda (column)
              (if (nth 2 column)
                  column
                (list (nth 0 column) (nth 1 column)
                      (list (harness-voice-pipeline--word "·" 'harness-dim-face)))))
            columns)))

(defun harness-voice-pipeline--pad (text width)
  "Return TEXT padded with spaces to WIDTH columns."
  (let ((text (or text "")))
    (concat text (make-string (max 0 (- width (string-width text))) ?\s))))

(defun harness-voice-pipeline-lines (p &optional width now)
  "Return P as the wide strip: a heading and up to three rows.
WIDTH is the room the strip has; when five columns do not fit, it is
drawn as one line per column instead, so a narrow window still says
every fact.  NOW is the time the level's age is measured against."
  (let* ((width (or width harness-voice-pipeline-width))
         (columns (harness-voice-pipeline-columns p now))
         (widths (mapcar (lambda (column)
                           (cl-loop for line in (nth 2 column)
                                    maximize (string-width line) into widest
                                    finally return (max widest (string-width (nth 0 column)))))
                         columns))
         (total (+ (cl-loop for cell-width in widths sum cell-width)
                   (* 2 (1- (length columns))))))
    (if (> total width)
        ;; A narrow window: one line per column, heading and facts.
        (mapcar (lambda (column)
                  (concat (harness-voice-pipeline--column-heading (nth 0 column) (nth 1 column))
                          " · "
                          (string-join (nth 2 column) " · ")))
                columns)
      (let* ((rows nil)
             (depth (cl-loop for column in columns
                             maximize (length (nth 2 column)))))
        (push (cl-loop for column in columns
                       for cell-width in widths
                       concat (harness-voice-pipeline--pad
                               (harness-voice-pipeline--column-heading (nth 0 column)
                                                                       (nth 1 column))
                               cell-width)
                       concat "  ")
              rows)
        (dotimes (index depth)
          (push (cl-loop for column in columns
                         for cell-width in widths
                         concat (harness-voice-pipeline--pad
                                 (or (nth index (nth 2 column)) "") cell-width)
                         concat "  ")
                rows))
        (mapcar #'string-trim-right (nreverse rows))))))

(defun harness-voice-pipeline-block (p &optional width now)
  "Return the pipeline block for a buffer: title, strip and summary.
WIDTH is the room the block has, NOW the time levels are measured
against."
  (append
   (list (propertize "Pipeline" 'face 'harness-label-face))
   (harness-voice-pipeline-lines p width now)
   (list (harness-voice-pipeline-summary p now))))

(defun harness-voice-pipeline-compact-line (p &optional room now)
  "Return the compact pipeline line, for under a compose box.
ROOM is the columns it may take: the least important facts go first in
a narrow window, and the line ends in a control that shows them.  The
level and the counts are the first facts to go, never the capture state
or the speaker."
  (let* ((meter (concat (propertize (harness-voice-pipeline-meter p 4 now)
                                    'face 'harness-success-face)
                        " "
                        (harness-voice-pipeline-level-label p now)))
         (items (list (list (propertize "Pipeline" 'face 'harness-label-face
                                        'help-echo "Voice pipeline")
                            100 nil)
                      ;; The speaker and the turn are what the line is for;
                      ;; the meter goes first in a narrow window, where the
                      ;; strip in the transcript still draws it in full.
                      (list meter 80 nil)
                      (list (or (harness-voice-pipeline-count-label p) "") 85 nil)
                      (list (or (harness-voice-pipeline-turn-label p) "") 90 nil)
                      (list (harness-voice-pipeline-speaker-label p) 95 nil)
                      (and (harness-voice-pipeline-problem p)
                           (list (propertize (harness-voice-pipeline-problem p)
                                             'face 'harness-failure-face
                                             'help-echo (harness-voice-pipeline-problem p))
                                 45 nil)))))
    (harness-ui-settings-line (list items) room)))

(provide 'harness-ui-voice-pipeline)
;;; harness-ui-voice-pipeline.el ends here
