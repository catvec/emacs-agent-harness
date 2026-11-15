;;; promo-rec.el --- Record the real harness for the promo film, frame by frame  -*- lexical-binding: t; -*-

;;; Commentary:

;; `capture.sh' loads this file, and a story (promo-story.el), into a fresh
;; `emacs -Q' on a graphical display.  It records the harness of this
;; checkout as the film's footage: a real Emacs, a real chat, a real task
;; board, driven by keys a person would press.  Nothing is drawn or faked:
;; every frame of the footage is `x-export-frames' of the live Emacs frame.
;;
;; A CLOCK OF OUR OWN.  A frame of footage is one tick of a virtual clock
;; (30 a second): the actions scheduled for that frame run, the scripted
;; agents take one step, the world gets a moment to settle, and the frame is
;; exported.  So the footage does not depend on how long an export takes, and
;; an agent "streams" at exactly the pace the story gives it.  Between two
;; segments the clock stops, and anything may happen off camera: modules
;; load, a world is built, the layout is arranged.
;;
;; THE AGENTS ARE SCRIPTED, THE REST IS NOT.  As in the README pictures
;; (scripts/harness-media.el, whose helpers and demo project this reuses), a
;; stand-in for the model provider replays a script, one event a tick; the
;; tools it calls are the harness's own, run on the demo project, and every
;; word of the UI -- the chat, the board, the tool output, the buttons --
;; is the harness's.  Nothing talks to a network.
;;
;; WHAT THE FILM LEARNS.  The recorder logs, per segment, the marks the story
;; sets, the keys it presses (for the film's keycaps), the places it clicks
;; (for the pointer), and the rectangles worth zooming to, all in frame
;; pixels, in a JSON file next to the frames, so the film never guesses a
;; coordinate.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)

(defvar promo-rec-root
  (file-name-as-directory
   (expand-file-name "../.." (file-name-directory (or load-file-name buffer-file-name))))
  "The checkout whose harness is recorded.")

;; The README pictures' driver: its helpers, the demo project and the scripts.
(load (expand-file-name "scripts/harness-media.el" promo-rec-root) nil 'nomessage)

;;;; Settings

(defconst promo-rec-fps 30 "Frames of footage a second.")
(defconst promo-rec-width 2400 "Width of every frame, in pixels.")
(defconst promo-rec-height 1350 "Height of every frame, in pixels.")
(defconst promo-rec-font-height 200
  "Height of the default face, in 1/10 pt: Hack at 20 pt.
The README pictures use 12 pt on 1816x1026 pixels, 180 columns by 54 lines, to
show a lot.  A film shows less, bigger: at 20 pt the 2400x1350 frame is 149
columns by 40 lines, 74 to a half.  The film shows it at 0.72, so a column of
text is 11.5 pixels wide on screen, and a zoom stays sharp.")

(defvar promo-rec-out nil "Directory the segments' frames and the log are written to.")
(defvar promo-rec-settle 0.06
  "Seconds of real time the world gets between two frames, to run what a tick
started.")

;; Harness variables and functions used here.
(defvar harness-state-directory)
(defvar harness-policy-file)
(defvar harness-process)
(defvar harness-enabled-modules)
(defvar harness-disabled-modules)
(defvar harness-ui-positions)
(defvar harness-cache-ttl)
(defvar harness-supervisor)
(defvar harness-supervisor-tasks)
(declare-function harness-start "harness")
(declare-function harness-enable-module "harness")
(declare-function harness-call "harness-core")
(declare-function harness-await "harness-core")
(declare-function harness-as-promise "harness-core")
(declare-function harness-resolved "harness-core")
(declare-function harness-define-provider "harness-provider")
(declare-function harness-ui-refresh-models "harness-ui")
(declare-function harness-ui-refresh-quotas "harness-ui")

(defun promo-rec--log (format-string &rest args)
  "Print FORMAT-STRING with ARGS on standard error."
  (princ (concat "rec: " (apply #'format format-string args) "\n") #'external-debugging-output))

;;;; The harness's clock

;; The harness reads the time with `(float-time)' everywhere: "Writing... 8s" under a streaming reply,
;; "running 11.9s" in the mode line, how long a task has been at work.  An export takes a quarter of a
;; second, so on the real clock those would run several times too fast against 30 frames a second.
;; While a segment is recorded the clock the harness reads stands still between frames and moves
;; 1/30 s on each; off camera it follows the real one, from where the recording left it.  Only
;; `float-time' without an argument is changed: the recorder itself, and the timers Emacs runs, keep
;; real time.

(defvar promo-rec--clock 0.0 "What the harness's clock read when it was last set.")
(defvar promo-rec--clock-real 0.0 "The real time at which `promo-rec--clock' was set.")
(defvar promo-rec--clock-frozen nil "Non-nil while a segment is recorded: the clock moves by ticks only.")

(defun promo-rec-real-time ()
  "The real time, a float, whatever the harness's clock says."
  (let ((time (current-time)))
    (+ (* 65536.0 (nth 0 time)) (nth 1 time) (/ (nth 2 time) 1e6))))

(defun promo-rec--float-time (original &optional time)
  "Advice on `float-time': the harness's clock, or ORIGINAL's answer for an
explicit TIME."
  (cond (time (funcall original time))
        ;; Strictly increasing, so that no two readings are equal and a rate is never a division by zero.
        (promo-rec--clock-frozen (setq promo-rec--clock (+ promo-rec--clock 1e-6)))
        (t (+ promo-rec--clock (- (promo-rec-real-time) promo-rec--clock-real)))))

(defun promo-rec--clock-install ()
  "Make the harness's clock follow the real one, until a segment freezes it."
  (setq promo-rec--clock (promo-rec-real-time)
        promo-rec--clock-real promo-rec--clock
        promo-rec--clock-frozen nil)
  (advice-add 'float-time :around #'promo-rec--float-time))

(defun promo-rec--clock-freeze ()
  "Stop the harness's clock where it is: a segment begins."
  (setq promo-rec--clock (+ promo-rec--clock (- (promo-rec-real-time) promo-rec--clock-real))
        promo-rec--clock-frozen t))

(defun promo-rec--clock-thaw ()
  "Let the harness's clock follow the real one again, from where it stopped: a
segment ended."
  (setq promo-rec--clock-real (promo-rec-real-time)
        promo-rec--clock-frozen nil))

;;;; Segments and the log

(cl-defstruct promo-rec-seg
  name dir (frame 0)
  ;; Events of the segment, newest first: plists with :f (the frame), :type and the rest.
  events
  ;; Marks the story set, as (NAME . FRAME), newest first.
  marks)

(defvar promo-rec--seg nil "The segment being recorded, or nil.")
(defvar promo-rec--waited-out 0
  "How many frames waited `promo-rec-settle-max' seconds and went on regardless.")
(defvar promo-rec--done nil "Finished segments, newest first.")
(defvar promo-rec--plan nil "Hash table: frame -> thunks to run at it, oldest first.")
(defvar promo-rec--watchers nil "Things waited for: (FROM PREDICATE THUNK DESCRIPTION), oldest first.")

(defun promo-rec-begin (name)
  "Start the segment NAME: its frames go to a directory of that name."
  (when promo-rec--seg (error "Segment %s is not ended" (promo-rec-seg-name promo-rec--seg)))
  (let ((dir (file-name-as-directory (expand-file-name name promo-rec-out))))
    (when (file-exists-p dir) (delete-directory dir t))
    (make-directory dir t)
    (setq promo-rec--plan (make-hash-table :test 'eql)
          promo-rec--watchers nil
          promo-rec--seg (make-promo-rec-seg :name name :dir dir))
    (promo-rec--clock-freeze)
    (promo-rec--log "segment %s begins" name)))

(defun promo-rec-end ()
  "End the segment being recorded."
  (when promo-rec--watchers
    (error "Never happened, in segment %s: %s" (promo-rec-seg-name promo-rec--seg)
           (mapconcat #'cadddr promo-rec--watchers "; ")))
  (let ((seg promo-rec--seg))
    (push seg promo-rec--done)
    (setq promo-rec--seg nil promo-rec--plan nil)
    (promo-rec--clock-thaw)
    (promo-rec--log "segment %s ends after %d frames" (promo-rec-seg-name seg)
                    (promo-rec-seg-frame seg))
    (when (> promo-rec--waited-out 0)
      (promo-rec--log "  %d frame(s) gave up waiting for the world"
                      promo-rec--waited-out))))

(defun promo-rec-frame ()
  "The number of the frame about to be recorded."
  (promo-rec-seg-frame promo-rec--seg))

(defun promo-rec-event (type &rest props)
  "Log an event of TYPE with PROPS at the frame about to be recorded."
  (push (append (list :f (promo-rec-frame) :type (symbol-name type)) props)
        (promo-rec-seg-events promo-rec--seg)))

(defun promo-rec-mark (name)
  "Mark the frame about to be recorded as NAME."
  (push (cons name (promo-rec-frame)) (promo-rec-seg-marks promo-rec--seg)))

(defun promo-rec-mark-at (frame name)
  "Mark FRAME as NAME, when it comes."
  (promo-rec-at frame (lambda () (promo-rec-mark name))))

(defun promo-rec--seg-json (seg)
  "SEG as a JSON-ready plist."
  (list :name (promo-rec-seg-name seg)
        :frames (promo-rec-seg-frame seg)
        :marks (let ((h (make-hash-table :test 'equal)))
                 (dolist (m (reverse (promo-rec-seg-marks seg))) (puthash (car m) (cdr m) h))
                 h)
        :events (vconcat (reverse (promo-rec-seg-events seg)))))

(defvar promo-rec--rects nil
  "Rectangles the story noted: a plist of [X Y WIDTH HEIGHT] vectors.")

(defvar promo-rec--extra nil "Plist of what the story wants in the log besides the segments.")

(defun promo-rec-note (key value)
  "Put VALUE under KEY (a keyword) in the log's top level."
  (setq promo-rec--extra (plist-put promo-rec--extra key value)))

(defun promo-rec--write-log ()
  "Write footage.json, next to the segments."
  (let ((json (json-serialize
               (append (list :fps promo-rec-fps :width promo-rec-width :height promo-rec-height
                             :rects (or promo-rec--rects (make-hash-table))
                             :segments (vconcat (mapcar #'promo-rec--seg-json (reverse promo-rec--done))))
                       promo-rec--extra)
               :null-object nil :false-object :json-false)))
    (let ((coding-system-for-write 'utf-8-unix))
      (write-region (concat json "\n") nil (expand-file-name "footage.json" promo-rec-out) nil 'silent))))

;;;; The clock

(defvar promo-rec--queue nil "Steps of the scripted agents waiting for the next tick, newest first.")

(defvar promo-rec-settle-max 6.0
  "Most seconds of real time a frame waits for the world, whatever it is doing.")

(defun promo-rec--busy-p ()
  "Non-nil while a process this Emacs started is running: a tool, git."
  (cl-some (lambda (p) (and (eq (process-type p) 'real) (process-live-p p)))
           (process-list)))

(defun promo-rec--settle ()
  "Let the world run until what a tick started has finished.
That is `promo-rec-settle' seconds at least, and then for as long as a process
the harness started is running (a tool, git), and a moment more for what it
did to be taken up, but no more than `promo-rec-settle-max' seconds.  So a
machine that is busy makes a frame take longer, and never makes a task take
more frames: the footage is the same on a slow machine as on a fast one."
  (let ((start (promo-rec-real-time)) (quiet nil))
    (while (let ((now (promo-rec-real-time)))
             (cond ((< (- now start) promo-rec-settle) t)
                   ((>= (- now start) promo-rec-settle-max)
                    (cl-incf promo-rec--waited-out)
                    nil)
                   ((promo-rec--busy-p) (setq quiet nil) t)
                   (t (unless quiet (setq quiet now))
                      (< (- now quiet) 0.04))))
      (accept-process-output nil 0.005)
      (sit-for 0))))

(defun promo-rec--tick ()
  "Advance the world one frame: the clock moves, each agent takes a step, then
everything settles."
  (when promo-rec--clock-frozen (setq promo-rec--clock (+ promo-rec--clock (/ 1.0 promo-rec-fps))))
  (let ((steps (nreverse promo-rec--queue)))
    (setq promo-rec--queue nil)
    (dolist (step steps) (funcall step)))
  (promo-rec--settle))

(defun promo-rec--grab ()
  "Write the frame as the next picture of the segment."
  (let* ((seg promo-rec--seg)
         (n (promo-rec-seg-frame seg))
         (file (expand-file-name (format "f%05d.png" n) (promo-rec-seg-dir seg))))
    (message nil)
    (redisplay t)
    (let ((data (x-export-frames nil 'png))
          (coding-system-for-write 'binary))
      (with-temp-file file
        (set-buffer-multibyte nil)
        (insert data)))
    (setf (promo-rec-seg-frame seg) (1+ n))))

(defun promo-rec-at (frame thunk)
  "Run THUNK at FRAME of the segment, before that frame is recorded."
  (puthash frame (append (gethash frame promo-rec--plan) (list thunk)) promo-rec--plan))

(defun promo-rec-after (frames thunk)
  "Run THUNK FRAMES frames from now (from the frame about to be recorded)."
  (promo-rec-at (+ (promo-rec-frame) frames) thunk))

(defun promo-rec-when-at (frame predicate thunk description)
  "From FRAME on, run THUNK at the first frame PREDICATE holds. What the world
does at its own pace -- a task finishing -- is waited for, not guessed at.  The
segment may not end with it unmet; DESCRIPTION says what it was."
  (setq promo-rec--watchers (append promo-rec--watchers (list (list frame predicate thunk description)))))

(defun promo-rec-play (frames)
  "Record FRAMES frames of the segment: run what is scheduled, tick, export."
  (let ((started (promo-rec-real-time)))
    (dotimes (f frames)
      (dolist (w (copy-sequence promo-rec--watchers))
        (when (and (>= f (nth 0 w)) (funcall (nth 1 w)))
          (setq promo-rec--watchers (delq w promo-rec--watchers))
          (funcall (nth 2 w))))
      (dolist (thunk (gethash f promo-rec--plan)) (funcall thunk))
      (promo-rec--tick)
      (promo-rec--grab)
      (when (zerop (mod (1+ f) 60))
        (promo-rec--log "  frame %d/%d, %.2f s a frame" (1+ f) frames (/ (- (promo-rec-real-time) started) (1+ f)))))))

(defun promo-rec-advance-until (predicate max-ticks what)
  "Tick, without recording, until PREDICATE holds: off camera, for what must
finish before the next segment. Signal an error naming WHAT after MAX-TICKS
ticks."
  (let ((n 0))
    (while (and (not (funcall predicate)) (< n max-ticks))
      (promo-rec--tick)
      (cl-incf n))
    (unless (funcall predicate) (error "Waited %d ticks for %s" max-ticks what))
    n))

(defun promo-rec-idle-until (predicate max-frames what)
  "Record frames until PREDICATE holds, at most MAX-FRAMES of them; return how
many. Signal an error naming WHAT when it never holds."
  (let ((n 0))
    (while (and (not (funcall predicate)) (< n max-frames))
      (promo-rec--tick)
      (promo-rec--grab)
      (cl-incf n))
    (unless (funcall predicate) (error "Waited %d frames for %s" max-frames what))
    n))

;;;; A person's hands

(defvar promo-rec--seed 12345 "State of the typing jitter's generator.")

(defun promo-rec--rand ()
  "A number in [0, 1), the same on every run."
  (setq promo-rec--seed (mod (+ (* promo-rec--seed 1103515245) 12345) 2147483648))
  (/ (float promo-rec--seed) 2147483648.0))

(defun promo-rec--press (keys)
  "Press KEYS, a string `kbd' reads, as the user would."
  (execute-kbd-macro (kbd keys)))

(defun promo-rec--type-char (char)
  "Type CHAR."
  (execute-kbd-macro (vector char)))

(cl-defun promo-rec-type-at (frame text &key (cps 13.0) label)
  "Schedule TEXT typed a character at a time from FRAME, CPS characters a second.
The rhythm is a person's: a little uneven, a longer beat between words,
now and then a hesitation, and the same on every run.  The selected window
and its point are where the characters go.  Return the frame after the
last one.  The log gets the text and the frame of each character (the film
makes the sound of a key of it).  LABEL names the typing in the log."
  (let ((f (float frame)) (base (/ promo-rec-fps cps)) (first frame) (frames nil))
    (dolist (char (string-to-list text))
      (let ((c char))
        (promo-rec-at (round f) (lambda () (promo-rec--type-char c))))
      (push (round f) frames)
      (setq f (+ f (* base (+ 0.62 (* 0.76 (promo-rec--rand)))
                      (if (eq char ?\s) 1.45 1.0)
                      (if (< (promo-rec--rand) 0.05) 2.4 1.0)))))
    (let ((last (max (1+ first) (round f))) (frames (vconcat (nreverse frames))))
      (promo-rec-at first (lambda () (promo-rec-event 'typing :text text :label (or label "")
                                                      :frames frames :to last)))
      last)))

(cl-defun promo-rec-key-at (frame keys &key label caption)
  "Schedule the press of KEYS at FRAME. The film shows LABEL (KEYS by default)
as a keycap, with CAPTION, a word for what the keys do."
  (promo-rec-at frame (lambda ()
                        (promo-rec-event 'key :keys keys :label (or label keys) :caption (or caption ""))
                        (promo-rec--press keys))))

(defun promo-rec-call-at (frame function &optional label)
  "Schedule a call of FUNCTION at FRAME, as what a key did: keycap LABEL when
given."
  (promo-rec-at frame (lambda ()
                        (when label (promo-rec-event 'key :keys "" :label label))
                        (funcall function))))

;;;; Where things are, in frame pixels

(defun promo-rec-window-rect (window)
  "WINDOW's rectangle in the frame, as [X Y WIDTH HEIGHT] in pixels."
  (let ((e (window-pixel-edges window)))
    (vector (nth 0 e) (nth 1 e) (- (nth 2 e) (nth 0 e)) (- (nth 3 e) (nth 1 e)))))


(defun promo-rec-rect (key rect)
  "Note RECT, [X Y WIDTH HEIGHT] in frame pixels, under KEY (a keyword) for the
film."
  (setq promo-rec--rects (plist-put promo-rec--rects key rect)))

(defun promo-rec-lines-rect (window start end)
  "The lines of WINDOW's buffer from START to END, as [X Y WIDTH HEIGHT] frame
pixels. It spans the window's width, and runs from the top of START's line to
the bottom of END's. Nil when START is not on screen."
  (when-let* ((top (pos-visible-in-window-p start window t))
              (bottom (or (pos-visible-in-window-p end window t) (list 0 (window-body-height window t))))
              (edges (window-pixel-edges window)))
    (let ((y0 (+ (nth 1 edges) (nth 1 top)))
          (y1 (+ (nth 1 edges) (nth 1 bottom) (frame-char-height))))
      (vector (nth 0 edges) y0 (- (nth 2 edges) (nth 0 edges)) (- y1 y0)))))

(defun promo-rec-highlight-at (frame rect-fn label)
  "At FRAME, say the film should draw attention to the rectangle RECT-FN
returns. RECT-FN is called then, so it can ask where something is now.  LABEL
says what it is."
  (promo-rec-at frame (lambda ()
                        (when-let* ((rect (funcall rect-fn)))
                          (promo-rec-event 'highlight :rect rect :label label)))))

(cl-defun promo-rec-callout-at (frame rect-fn text &key (side "below") (frames 70))
  "At FRAME, say the film should label the rectangle RECT-FN returns with TEXT.
SIDE is where the label sits, \"below\", \"above\", \"left\" or \"right\" of the
rectangle, and FRAMES how long it stays."
  (promo-rec-at frame (lambda ()
                        (when-let* ((rect (funcall rect-fn)))
                          (promo-rec-event 'callout :rect rect :text text :side side :frames frames)))))

(defun promo-rec-point-xy (window pos)
  "The place of buffer position POS in WINDOW, as [X Y] frame pixels, glyph centre.
Nil when POS is not on screen."
  (when-let* ((xy (pos-visible-in-window-p pos window t))
              (edges (window-pixel-edges window)))
    (vector (+ (nth 0 edges) (nth 0 xy) (/ (frame-char-width) 2))
            (+ (nth 1 edges) (nth 1 xy) (/ (frame-char-height) 2)))))

(defun promo-rec-focus-at (frame rect-fn &optional zoom)
  "At FRAME, say the film should look at the rectangle RECT-FN returns.
RECT-FN is called then, so it can ask where something is now.  ZOOM caps
how far the film may zoom in (it never zooms past what fits the rectangle)."
  (promo-rec-at frame (lambda ()
                        (promo-rec-event 'focus :rect (funcall rect-fn) :zoom (or zoom 0)))))

(defun promo-rec-click-at (frame xy-fn label action)
  "At FRAME the user clicks where XY-FN says, [X Y]; ACTION is what the click does.
The film moves a pointer there and shows the press; LABEL says what was clicked."
  (promo-rec-at frame (lambda ()
                        (promo-rec-event 'click :xy (funcall xy-fn) :label label)
                        (funcall action))))

;;;; The harness, core only, with a scripted model

(defvar promo-rec--waits (make-hash-table :test 'equal) "Session id -> ticks the stream still waits.")

(defun promo-rec-say (text &optional chars-per-tick)
  "Events that say TEXT a few characters at a tick, as a model streams it.
CHARS-PER-TICK defaults to 6, which is 180 characters a second."
  (let ((n (or chars-per-tick 6)) (events nil) (i 0))
    (while (< i (length text))
      (let ((end (min (length text) (+ i n))))
        (push (harness-media--say (substring text i end)) events)
        (setq i end)))
    (nreverse events)))

(defun promo-rec-wait (ticks)
  "An event that holds the stream for TICKS frames."
  (list :type 'wait :ticks ticks))

(defvar promo-rec-scripts nil
  "Scripts as (REGEXP . FUNCTION), tried against the newest user message before
the README's.")

(defconst promo-rec--side-systems
  '("You are the permission judge" "You explain one blocked tool call"
    "You write short titles" "You are the search box"
    "You write the Insights report")
  "Starts of the system prompts of the harness's own model calls.
They are made beside a session's turn.")

(defun promo-rec--side-p (request)
  "Non-nil when REQUEST is a call the harness makes beside a session's turn.
Naming a session, judging a call, a task's write-up: the stand-in answers them
at once, from the README pictures' scripts."
  (let ((system (or (plist-get request :system) "")))
    (or (plist-get request :ephemeral)
        (cl-some (lambda (p) (string-prefix-p p system)) promo-rec--side-systems)
        (string-match-p "^## Task refinement" system))))

(defun promo-rec--script (request)
  "The events that answer REQUEST: the story's scripts first, then the README
pictures'."
  (let* ((newest (or (car (last (harness-media--user-texts request))) ""))
         (entry (and (not (promo-rec--side-p request))
                     (cl-find-if (lambda (e) (string-match-p (car e) newest)) promo-rec-scripts))))
    (if entry
        (funcall (cdr entry) request)
      (harness-media--script request))))

(defun promo-rec--complete (request)
  "Answer REQUEST with its script, one event a tick.
The same as `harness-media--complete', except that a stream does not run on a
timer: each step waits for the recorder's next tick, so the story sets the pace.
A request made beside a session's turn (naming it, judging a call) is answered
at once."
  (let* ((on-event (plist-get request :on-event))
         (sid (or (plist-get (plist-get request :session) :id) "none"))
         (side (promo-rec--side-p request))
         (rest (if (and (not side) (harness-media--continuing-p request))
                   (gethash sid harness-media--rest 'none)
                 'none))
         (script (if (eq rest 'none) (promo-rec--script request) rest))
         (written 0) (reported nil) (cancelled nil) (waiting 0))
    (unless side (remhash sid harness-media--rest))
    (cl-labels ((emit (event) (funcall on-event event))
                (finish (reason)
                  (unless reported (emit (harness-media--usage request written)))
                  (emit (list :type 'done :stop-reason reason)))
                (later ()
                  (if side
                      (run-at-time 0.005 nil #'step)
                    (push #'step promo-rec--queue)))
                (step ()
                  (unless cancelled
                    (if (> waiting 0)
                        (progn (cl-decf waiting) (later))
                      (let ((event (pop script)))
                        (pcase (plist-get event :type)
                          ('nil (finish 'end-turn))
                          ('wait (setq waiting (1- (plist-get event :ticks))) (later))
                          ('tool-call (puthash sid script harness-media--rest) (emit event) (finish 'tool-use))
                          ('hold nil)
                          ('usage (setq reported t) (emit event) (later))
                          (_ (setq written (+ written (length (or (plist-get event :delta) ""))))
                             (emit event)
                             (later))))))))
      (emit '(:type start))
      (later))
    (list :cancel (lambda ()
                    (setq cancelled t)
                    (unless side (remhash sid harness-media--rest))
                    (funcall on-event '(:type done :stop-reason cancelled))))))

(defun promo-rec--define-provider ()
  "Register the scripted stand-in for Claude Code, and nothing else.
The real provider, `provider-claude', is a core module; the stand-in takes its
place so that the run needs no CLI, no network and no login."
  (harness-define-provider 'claude
    :label "Claude Code"
    :doc "Scripted stand-in for the Claude Code CLI, for the promo film."
    :models (let ((models (harness-media--claude-models))) (lambda () (harness-resolved models)))
    :complete #'promo-rec--complete
    :quota #'harness-media--claude-quota
    :capabilities '(:vision t :thinking t :quota t :billing t))
  (harness-await (harness-as-promise (harness-call 'provider/models t)) 30)
  (harness-ui-refresh-models)
  (harness-ui-refresh-quotas))

(defun promo-rec-size-frame ()
  "Make the frame exactly `promo-rec-width' x `promo-rec-height' pixels.
`set-frame-size' with PIXELWISE sizes the text area; the fringes come on top of
it."
  (dotimes (_ 2)
    (set-frame-size nil
                    (- promo-rec-width (- (frame-pixel-width) (frame-text-width)))
                    (- promo-rec-height (- (frame-pixel-height) (frame-text-height)))
                    t)
    (harness-media--settle 0.3))
  (unless (and (= (frame-pixel-width) promo-rec-width) (= (frame-pixel-height) promo-rec-height))
    (error "The frame is %dx%d pixels, not %dx%d" (frame-pixel-width) (frame-pixel-height)
           promo-rec-width promo-rec-height)))

(defun promo-rec--setup-look ()
  "Dress the frame as the README pictures do, at the film's size."
  (setq harness-media-font-height promo-rec-font-height
        frame-resize-pixelwise t
        window-resize-pixelwise t
        mouse-highlight nil)
  (harness-media--setup-look)
  (promo-rec-size-frame)
  (promo-rec--log "frame: %dx%d pixels, %dx%d characters of %dx%d pixels" (frame-pixel-width) (frame-pixel-height)
                  (frame-width) (frame-height) (frame-char-width) (frame-char-height)))

(defun promo-rec--setup-harness ()
  "Start the harness of this checkout with its core and no other module."
  (promo-rec--clock-install)
  (dolist (pair harness-media-identity)
    (setenv (car pair) (cdr pair)))
  (add-to-list 'load-path harness-media-root)
  (setq harness-state-directory (expand-file-name "~/.emacs.d/harness/")
        ;; No policy of this machine's (/etc/harness/policy.el) reaches the footage.
        harness-policy-file nil
        ;; The harness runs in this Emacs, so the footage is of one process.
        harness-process nil
        ;; The point of the first segment: the core, and nothing else.
        harness-enabled-modules nil
        ;; Only the real Claude Code provider is left out, for the stand-in.
        harness-disabled-modules '(provider-claude))
  (require 'harness)
  (unless (harness-start) (error "The harness did not start cleanly"))
  ;; The scripted turns read and write the prompt cache; a cache that lapsed puts a panel above the box.
  (setq harness-cache-ttl 86400)
  ;; Chats take half the frame.
  (setf (alist-get 'right harness-ui-positions) '((side . right) (slot . 0) (window-width . 0.5)))
  (promo-rec--define-provider)
  (harness-media--settle 1))

;;;; Running a story

(defun promo-rec--encode-log ()
  "Write the log; say what was recorded."
  (promo-rec--write-log)
  (dolist (seg (reverse promo-rec--done))
    (promo-rec--log "recorded %s: %d frames (%.1f s)" (promo-rec-seg-name seg) (promo-rec-seg-frame seg)
                    (/ (promo-rec-seg-frame seg) (float promo-rec-fps)))))

(defvar promo-rec-story-function nil "Function that records the story; set by the story file.")

(defun promo-rec-run ()
  "Set the world up, record the story, write the log and exit."
  (let ((status 0))
    (condition-case err
        (progn
          (promo-rec--setup-look)
          (promo-rec--setup-harness)
          (funcall promo-rec-story-function)
          (promo-rec--encode-log))
      (error (promo-rec--log "failed: %s" (error-message-string err))
             (when promo-rec--seg (promo-rec--log "while recording %s, frame %d" (promo-rec-seg-name promo-rec--seg) (promo-rec-frame)))
             (setq status 1)))
    (kill-emacs status)))

(defun promo-rec-main ()
  "Record the story, as `capture.sh' asks; then exit Emacs."
  (condition-case err
      (progn
        (setq promo-rec-out (file-name-as-directory (or (getenv "PROMO_REC_OUT") (error "PROMO_REC_OUT is not set")))
              harness-media-project (expand-file-name "~/src/acme-api/"))
        (unless (display-graphic-p) (error "The footage needs a graphical display"))
        (make-directory promo-rec-out t)
        (random "promo-rec")
        (run-with-timer 0.5 nil #'promo-rec-run))
    (error (promo-rec--log "%s" (error-message-string err))
           (kill-emacs 1))))

(provide 'promo-rec)
;;; promo-rec.el ends here
