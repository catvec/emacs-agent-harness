;;; harness-ui-voice-live.el --- Live voice sidecar transport  -*- lexical-binding: t; -*-

;;; Commentary:

;; The live half of `ui-voice': a sidecar process owns the microphone,
;; the speaker and the speech model, while Emacs owns the conversation
;; state, the agent session and every permission decision.  The sidecar
;; speaks newline-delimited JSON on stdin and stdout: one object per
;; line, UTF-8, diagnostics on stderr.  Nothing but control text crosses
;; the pipe.  Audio stays in the sidecar.
;;
;; Sidecar to Emacs: ready, listening, speaking, user_delta,
;; assistant_delta, backchannel, delegation, interrupted, error, closed.
;; Emacs to sidecar: start, context, mute, interrupt, stop, commentary,
;; thinking, delegate_result, turn_hold.
;;
;; A delegation goes to the route as it stands, through the normal
;; `session/prompt' path for a session and `_harness/workspace/prompt'
;; for a workspace thread: the transcript is the message, with no
;; distillation, no context envelope and no interpretation step.  The
;; route is captured with the burst's onset and carries a generation, so
;; a transcript, a turn or a reply that outlives a switch stays with the
;; thread it was spoken in.  The sidecar and the microphone are shared:
;; selecting another session or workspace retargets the call instead of
;; restarting it.  Assistant text streams back as speakable commentary;
;; the turn's full text is the delegate result.  Permissions and
;; questions stay on screen: the sidecar may say that approval is
;; needed, never approve anything.  Interruption stops playback only;
;; cancelling the agent turn is a separate command.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)
(require 'harness-ui-compose)
(require 'harness-ui-voice-conversation)
(require 'harness-ui-voice-pipeline)
(require 'harness-ui-voice-turn)
(require 'harness-ui-voice-recovery)

(declare-function harness-voice--adopt "harness-ui-voice")
(declare-function harness-voice--button "harness-ui-voice")
(declare-function harness-voice--refresh "harness-ui-voice")
(declare-function harness-voice "harness-ui-voice")
(declare-function harness-voice-mode "harness-ui-voice")
(declare-function harness-voice-setup "harness-ui-voice-providers")
(declare-function harness-voice--speech-text "harness-ui-voice")
(defvar harness-voice-mode)
(defvar harness-voice--controls)
(defvar harness-voice--enabled)
(defvar harness-voice--owner)
(defvar harness-voice-live-command)
(declare-function harness-voice-live-p "harness-ui-voice-providers")
(declare-function harness-voice-pipeline-start "harness-ui-voice-providers")
(declare-function harness-voice-pipeline-state "harness-ui-voice-providers")
(declare-function harness-voice-pipeline-reason "harness-ui-voice-providers")
(declare-function harness-voice-unmute-need "harness-ui-voice-providers")
(declare-function harness-ui-workspace--selected-thread "harness-ui-workspace")
(declare-function harness-ui-workspace--live-session "harness-ui-workspace")
(declare-function harness-ui-workspace--current-thread "harness-ui-workspace")
(defvar harness-ui-workspace--id)
(declare-function harness-voice-provider-command "harness-ui-voice-providers")
(declare-function harness-voice-provider-label "harness-ui-voice-providers")
(declare-function harness-voice-dictate "harness-ui-voice")
(declare-function harness-voice-interrupt "harness-ui-voice")
(defvar harness-voice-provider)
(defvar harness-voice-live-startup-timeout)
;; The receipt settings are defined in `harness-ui-voice', which requires
;; this file; they are read here, never set.
(defvar harness-voice-acknowledgment)
(defvar harness-voice-live-acknowledgment)

(defconst harness-voice-live--protocol 1
  "Protocol version this client speaks.")

(defconst harness-voice-live--stop-timeout 3
  "Seconds to wait for a sidecar to close before killing it.")

(defvar harness-voice-live--process nil "The sidecar process, or nil.")
(defvar harness-voice-live--buffer nil
  "The compose buffer voice was started in, or nil.
It is where the controls are drawn and where a failure is shown; it is
not the target.  The target is the route below, which moves when the
person selects another session or workspace.")
(defvar harness-voice-live--session nil
  "The session id delegations go to now, or nil.
For a workspace target this is the thread's live episode, once it has
one; the prompt itself goes through the workspace.")
(defvar harness-voice-live--route-kind 'session
  "What the route names: `session' or `workspace'.")
(defvar harness-voice-live--route-workspace nil
  "The workspace id the route names, or nil.")
(defvar harness-voice-live--route-thread nil
  "The workspace thread the route names, or nil.")
(defvar harness-voice-live--route-resolved-thread nil
  "First thread learned from an episode event before the workspace cache.")
(defvar harness-voice-live--route-name nil
  "What the UI calls the route's target, or nil.")
(defvar harness-voice-live--route-generation 0
  "Raised every time the route moves.
A transcript, a turn or a reply carries the generation it was captured
under, so a late one is delivered to the target it was spoken to and
never to a thread selected after it.")
(defvar harness-voice-live--utterance-routes nil
  "Utterance id -> the route the words were spoken under.
The sidecar starts a burst with an id of its own, so the person can
select another thread while the speech is still being transcribed; the
route is captured at the burst's onset and its transcript goes there.")
(defvar harness-voice-live--stderr nil "Buffer holding the sidecar's stderr.")
(defvar harness-voice-live--tail "" "Unparsed stdout after the last newline.")
(defvar harness-voice-live--timer nil "Startup or stop timer, or nil.")
(defvar harness-voice-live--camera nil
  "The camera state the sidecar last reported, or nil.
A provider that captures from a camera -- the webcam lip reader -- sends
`camera' events with its device, the faces in view and its frame rate;
every other provider leaves this nil and shows no camera at all.")
(defvar harness-voice-live--pipeline-timer nil
  "Timer following the shared local pipeline while it initializes, or nil.")
(defvar harness-voice-live--state nil
  "Session state.
One of nil, `starting', `listening', `speaking', `interrupted',
`ending' or `failed'.")
(defvar harness-voice-live--error nil "Failure text shown in the controls.")
(defvar harness-voice-live--notice nil
  "The last problem the sidecar survived, or nil.
It names what one reply or one utterance could not do -- a speech server
with no audio for the text, one failed transcription -- and is shown
under the controls.  The session goes on: the microphone stays open and
the next turn is tried as usual.")
(defvar harness-voice-live--muted nil "Non-nil while the sidecar microphone is muted.")
(defvar harness-voice-live--working nil "Non-nil while an agent turn runs.")
(defvar harness-voice-live--output-suppressed nil
  "Non-nil after interruption, until a newer agent turn owns output.")
(defvar harness-voice-live--interrupt-seq 0 "Monotonic explicit playback control id.")
(defvar harness-voice-live--control-status nil "Last control outcome, never dictation.")
(defvar harness-voice-live--control-seq 0 "Invalidates late control responses.")
(defvar harness-voice-live--agent-turn nil "Opaque backend identity of the watched turn.")
(defvar harness-voice-live--agent-watch 0 "Invalidates late agent activity snapshots.")
(defvar harness-voice-live--turn-active nil "Non-nil while assistant text is followed.")
(defvar harness-voice-live--closing nil "Non-nil when this client ended the session.")
(defvar harness-voice-live--delegation nil "The running delegation, a plist, or nil.")
(defvar harness-voice-live--delegations nil "Delegations waiting for the running turn.")
(defvar harness-voice-live--nodes nil "Node id -> text and streamed offset.")
(defvar harness-voice-live--order nil "Node ids in the order their text arrived.")
(defvar harness-voice-live--heard ""
  "User transcript since the last delegation, for a delegation without text.")
(defvar harness-voice-live--conversation (harness-voice-conversation-create)
  "The voice conversation of the current call.
It keeps the words of every user utterance as they were heard and sent,
and what the voice actually spoke.  It is cleared when the call ends, so
a new call starts empty while the chat keeps its own history.")
(defvar harness-voice-live--speech-active nil
  "Non-nil while the sidecar hears a person speaking right now.")
(defvar harness-voice-live--held nil
  "Assistant text held while speech owns the floor.
Each item is a plist of :id, :text and :turn, newest first.  It is
reported with the next transcript and never spoken after a real
utterance ends.")
(defvar harness-voice-live--held-timer nil
  "Timer that releases held text after a false trigger, or nil.")
(defvar harness-voice-live--held-token 0
  "Invalidates false-trigger callbacks across newer speech and lifecycles.")
(defvar harness-voice-live--turn-id nil
  "Id of the delegation whose output is arriving now.")
(defvar harness-voice-live--seen (make-hash-table :test 'equal)
  "Utterance keys already delivered to the session.")
(defvar harness-voice-live--held-seq 0
  "Counter for held pieces that came without an id.")

(defcustom harness-voice-live-turn-grace 1.2
  "Seconds of grace after a complete-looking final transcript.
Speech or unresolved input cancels the deadline.  Continuation intent
and possible cut-offs never expire; `harness-voice-live-send-now' or a
standalone recovery cue can release them once input has resolved."
  :type 'number
  :group 'harness-voice)

(defcustom harness-voice-live-pending-limit 100000
  "Maximum characters of unsent speech retained in an automatic live turn.
Exceeding this limit ends capture visibly rather than truncating or
submitting the draft.  The complete unsent words remain in the transcript."
  :type 'natnum
  :group 'harness-voice)

(defvar harness-voice-live-submit-functions nil
  "Functions arbitrating a committed voice job before agent queueing.
Each receives (JOB CONTINUE COMPLETE).  Return non-nil to own JOB,
possibly asynchronously.  CONTINUE delivers its unchanged transcript;
COMPLETE acknowledges its sources without starting an agent turn.
Both callbacks are once-only and invalid after a route/lifecycle reset.
JOB carries :id, :ids, :text, :route, :segments and :playback-overlap.
This hook runs before queueing, so a pending question can be answered
while the existing agent turn is blocked.")
(defvar harness-voice-live-reset-functions nil
  "Functions called without arguments when voice input ownership resets.
Route changes, mute, end, failure and connection replacement invalidate
outstanding submit callbacks before these functions run.")
(defvar harness-voice-live--submissions nil
  "Committed jobs awaiting asynchronous input arbitration.")
(defvar harness-voice-live--input-overlap nil
  "Whether unnumbered speech began during assistant playback.")

(defvar harness-voice-live--pending nil
  "Unsent conversational turn: :route, ordered :items and :recovery.
Each item retains its original :text, delegation :id and source :segment.
Nothing is recorded as sent until the entire turn is committed.")
(defvar harness-voice-live--pending-timer nil "Ordinary turn grace timer.")
(defvar harness-voice-live--pending-token 0
  "Invalidates grace callbacks after input, route or lifecycle changes.")
(defvar harness-voice-live--input-chunks nil
  "Source id -> input record, independent of the bounded pipeline display.
Records retain onset order, route, truncation and unresolved transcription.")
(defvar harness-voice-live--input-seq 0 "Monotonic source onset order.")
(defvar harness-voice-live--input-anonymous nil
  "Non-nil while unnumbered input is awaiting its delegation.")
(defvar harness-voice-live--turn-held nil
  "Whether this client has asked the sidecar to hold provider output.")
(defvar harness-voice-live--caption-hold nil
  "Continuation or cut-off hold from a caption without a delegation.
It holds output and older pending words; captions never invent a request.")
(defvar harness-voice-live--caption-text "" "Current unnumbered caption's partial words.")
(defvar harness-voice-live--caption-hold-order 0 "Onset order of the latest finalized caption.")
(defvar harness-voice-live--caption-recovery nil "Latest caption-only recovery awaiting input resolution.")

(defcustom harness-voice-live-motion t
  "Whether the voice controls animate.
Waiting for speech, a transcript or a turn is drawn as a spinner while
this is non-nil.  nil keeps the stage's glyph still; the stage's word
and every fact of the pipeline stay the same, in the header line, the
strip and its summary, so nothing is lost without the motion."
  :type 'boolean
  :group 'harness-voice)

(defcustom harness-voice-live-pending-release-delay 1.5
  "Seconds to keep held output after a speech trigger with no utterance.

A tap on the microphone can cross the onset threshold without becoming
words.  Cancellation of such a trigger is reported as listening, and the
held reply is released after this delay.  A real utterance sends
transcribing instead, which cancels the timer; its reply becomes pending
context and is never replayed blindly."
  :type 'number
  :group 'harness-voice)
(defcustom harness-voice-live-recovery-window 0.6
  "Seconds after a voice submission in which resumed speech takes it back.
The window runs from the moment the voice message was submitted to the
moment the person's resumed speech *began*, as the sidecar's own speech
gate reports it -- never to the moment its transcript arrived.  Speech
to text takes as long as it takes, and a continuation begun inside the
window is recovered when its words come back late.  A provider that
reports no onset leaves the transcript's arrival as the only evidence,
and the window then applies to that.  nil turns the recovery off."
  :type '(choice (const :tag "Off" nil) number)
  :group 'harness-voice)

(defcustom harness-voice-live-recovery-cancel-timeout 5.0
  "Seconds to wait for a cancelled turn to acknowledge the cancellation.
The history is rewound only once the turn is over: a head that moved
under a running turn would go on being written after.  A turn that has
not ended by then is left as it is, and the continuation is submitted
on its own -- the safe fallback, never a rewind over a turn still
writing."
  :type 'number
  :group 'harness-voice)

(defvar harness-voice-live--recovery nil
  "The armed voice-turn recovery, or nil.
See `harness-ui-voice-recovery'; it holds the voice message that was
submitted, when, the resumed speech's onset and the words that went on.
The transport cancels, rewinds and resubmits on its decision.")
(defvar harness-voice-live--recovery-timer nil
  "Timer waiting for a cancelled turn to acknowledge, or nil.")
(defvar harness-voice-live--recovery-token 0
  "Invalidates cancel-wait callbacks across newer recoveries and lifecycles.")
(defvar harness-voice-live--recovery-seq 0
  "Counter naming each recovery, so a late callback knows its own.
The record is a value that evidence notes replace with a copy, so a
callback compares this id, never the record itself.")

(defvar harness-voice-live--transcript nil "The live caption buffer, or nil.")
(defvar harness-voice-live--speaker nil "Speaker of the caption line being written.")
(defvar harness-voice-live--section nil "Section of the transcript being written.")
(defvar harness-voice-live--stage nil
  "What the session is doing now.
One of nil, `listening', `hearing', `transcribing', `holding', `thinking',
`finishing', `continuation', `cut-off', `speaking', `muted' or `failed'.
The stage is what the controls, the stage line and the timer read; the
state is what the sidecar reported.")
(defvar harness-voice-live--stage-since nil "Time the current stage began.")
(defvar harness-voice-live--stage-timer nil "Timer animating an active stage.")
(defvar harness-voice-live--stage-frame 0 "Frame of the busy indicator.")
(defvar harness-voice-live--pipeline (harness-voice-pipeline-create 'off)
  "The pipeline this session draws: the level, the bursts, the turn, the speaker.")
(defvar harness-voice-live--pipeline-timer nil
  "Timer coalescing the pipeline's redraws, or nil.")
(defvar harness-voice-live--pipeline-stale-timer nil
  "Timer that redraws the meter when its last level goes stale, or nil.")
(defvar harness-voice-live--pipeline-controls-at nil
  "Time the compose line was last redrawn for a level, or nil.")
(defvar harness-voice-live--utterance nil
  "The segment id the captions now arriving belong to, or nil.")
(defvar harness-voice-live--utterance-done nil
  "The segment id whose captions are final and wait for their turn, or nil.")
(defvar harness-voice-live--caption-seq 0
  "Counter for captions that arrive without an utterance id.")
(defvar harness-voice-live--reply-seq 0
  "Counter for playback that arrives without a reply id.")
(defconst harness-voice-live--spinner
  ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"]
  "Braille frames of the busy indicator.
A frame every fifth of a second is the oldest trick there is to make a
wait look alive, and it costs one character.")

;;;; The route

(defun harness-voice-live--active-p ()
  "Non-nil while a sidecar session runs."
  (and (processp harness-voice-live--process)
       (process-live-p harness-voice-live--process)))

;; One live call has one target, and the target is a value, not a
;; captured buffer: the person selects another session or workspace and
;; the next utterance goes there, with the same sidecar, the same
;; microphone and the same speech services.  Every delegation, turn and
;; reply carries the generation it was captured under, so a transcript
;; that arrives after the switch is delivered to the target it was
;; spoken to -- or dropped with a reason -- and never to the thread that
;; happens to be selected when it lands.

(defun harness-voice-live--route ()
  "Return the current route as a plist.
`:kind' is `session' or `workspace'; `:buffer' is the compose buffer
the controls are drawn in; `:session' the session a prompt goes to;
`:workspace' and `:thread' the workspace target; `:name' what the UI
calls it; `:generation' the route's generation."
  (list :kind harness-voice-live--route-kind
        :buffer harness-voice-live--buffer
        :session harness-voice-live--session
        :workspace harness-voice-live--route-workspace
        :thread harness-voice-live--route-thread
        :resolved-thread harness-voice-live--route-resolved-thread
        :name harness-voice-live--route-name
        :generation harness-voice-live--route-generation))

(defun harness-voice-live--route-label (&optional route)
  "Return what the UI calls ROUTE's target, or nil.
A session is named as the session list names it; a workspace thread as
its workspace and thread.  The label is what the controls show, so the
indicator and the target cannot disagree."
  (let* ((route (or route (harness-voice-live--route)))
         (name (plist-get route :name)))
    (or (and (stringp name) (not (string-empty-p name)) name)
        (pcase (plist-get route :kind)
          ('workspace (or (plist-get route :workspace) "Workspace"))
          (_ (let ((session (plist-get route :session)))
               (and (stringp session)
                    (if (fboundp 'harness-ui-session-name)
                        (harness-ui-session-name session)
                      (substring session 0 (min 8 (length session)))))))))))

(defcustom harness-voice-live-follow-selection t
  "Whether a live call follows the compose box the person is looking at.
Non-nil sends the next utterance to the session or workspace thread of
the selected window's compose box, when that is a different target from
the last one.  The sidecar, the microphone and the speech services keep
running: only the words' destination moves, and what was in flight for
the old target is dropped with the reason `retargeted'.  nil keeps the
target where it was until `harness-voice-live-retarget' or the `Use
here' control moves it."
  :type 'boolean
  :group 'harness-voice)

(defun harness-voice-live--selected-route ()
  "Return the route of the compose box the person is looking at, or nil.
A selected window that shows no compose box is no target: looking at a
source file does not move the call."
  (let ((buffer (window-buffer (selected-window))))
    (when (and (buffer-live-p buffer)
               (with-current-buffer buffer (harness-compose-live-p)))
      (harness-voice-live--route-of-buffer buffer))))

(defun harness-voice-live--follow-selection ()
  "Move the route to the selected compose box, when the option says so.
Return non-nil when the target moved.  This runs when an utterance
arrives, not on a redisplay hook: the words go where the person is
looking at the moment they speak, and nothing is retargeted while they
are merely reading."
  (when harness-voice-live-follow-selection
    (let ((route (harness-voice-live--selected-route)))
      (when (and route
                 (not (harness-voice-live--route-same-p
                       route (harness-voice-live--route))))
        (let ((moved (harness-voice-live--route-set route)))
          (when moved
            (harness-voice-live--transcript-route)
            (harness-voice-live--refresh))
          moved)))))

(defun harness-voice-live--route-of-buffer (buffer)
  "Return the route BUFFER's compose box would be, or nil.
A chat names its session; a workspace names its selected thread and the
episode that thread runs in.  A buffer that names neither is no target.
The workspace's own buffer-locals are read, so the transport needs no
call into that module to know where a workspace's words go."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (cond
       ((bound-and-true-p harness-ui-workspace--id)
        (let* ((workspace harness-ui-workspace--id)
               (thread (or (and (boundp 'harness-ui-workspace--thread)
                                harness-ui-workspace--thread)
                           (and (fboundp 'harness-ui-workspace--selected-thread)
                                (harness-ui-workspace--selected-thread))))
               (session (and (fboundp 'harness-ui-workspace--live-session)
                             (harness-ui-workspace--live-session))))
          (list :kind 'workspace
                :buffer buffer
                :workspace workspace
                :thread thread
                :session session
                :name (harness-voice-live--workspace-label workspace thread))))
       ((and (bound-and-true-p harness-ui-session-id)
             (stringp harness-ui-session-id)
             (not (string-empty-p harness-ui-session-id)))
        (list :kind 'session
              :buffer buffer
              :session harness-ui-session-id
              :name (if (fboundp 'harness-ui-session-name)
                        (harness-ui-session-name harness-ui-session-id)
                      harness-ui-session-id)))))))

(defun harness-voice-live--workspace-label (workspace thread)
  "Return a one-line name for WORKSPACE's THREAD, or nil."
  (let ((title (and (fboundp 'harness-ui-workspace--current-thread)
                    (buffer-live-p harness-voice-live--buffer)
                    (with-current-buffer harness-voice-live--buffer
                      (when (and (bound-and-true-p harness-ui-workspace--id)
                                 (equal harness-ui-workspace--id workspace))
                        (plist-get (harness-ui-workspace--current-thread) :title))))))
    (cond ((and title (not (string-empty-p title))) title)
          (thread thread)
          (workspace workspace))))

(defun harness-voice-live--route-same-p (a b)
  "Return non-nil when routes A and B name the same target.
A workspace episode is derived metadata, not a target switch.  Its first
thread can resolve while the workspace buffer still has the empty cache."
  (and (eq (plist-get a :kind) (plist-get b :kind))
       (if (eq (plist-get a :kind) 'workspace)
           (and (equal (plist-get a :workspace) (plist-get b :workspace))
                (or (equal (plist-get a :thread) (plist-get b :thread))
                    (equal (or (plist-get a :thread) (plist-get a :resolved-thread))
                           (or (plist-get b :thread) (plist-get b :resolved-thread)))))
         (equal (plist-get a :session) (plist-get b :session)))))

(defun harness-voice-live--route-set (route)
  "Make ROUTE the target, raising the generation when it moved.
The sidecar, the microphone and the speech services are untouched: a
switch retargets the words, it does not restart the call.  What was in
flight for the old target is dropped with the reason `retargeted', so
the transcript says where it went instead of leaking into the new
thread."
  (let ((moved (not (harness-voice-live--route-same-p
                     route (harness-voice-live--route)))))
    (setq harness-voice-live--route-kind (or (plist-get route :kind) 'session)
          harness-voice-live--route-workspace (plist-get route :workspace)
          harness-voice-live--route-thread (plist-get route :thread)
          harness-voice-live--route-name (plist-get route :name)
          harness-voice-live--session (or (plist-get route :session)
                                         (and (not moved) harness-voice-live--session)))
    (when (plist-get route :buffer)
      (setq harness-voice-live--buffer (plist-get route :buffer)))
    (when moved
      (setq harness-voice-live--route-resolved-thread nil)
      (cl-incf harness-voice-live--route-generation)
      (harness-voice-live--route-drop-in-flight))
    moved))

(defun harness-voice-live--route-drop-in-flight ()
  "Drop what was captured for the previous target, with its reason.
A queued delegation is answered so its sidecar does not wait for a turn
that will never come; a turn already running is left to finish, and its
reply is not spoken into the new thread."
  (harness-voice-live--recovery-drop "retargeted")
  (harness-voice-live--pending-cancel "retargeted")
  (let ((queued harness-voice-live--delegations))
    (setq harness-voice-live--delegations nil)
    (dolist (job queued)
      (harness-voice-live--pipeline-turn
       (plist-get job :id) 'cancelled "retargeted")
      (harness-voice-live--delegate-result job "" "retargeted"))
    (when harness-voice-live--delegation
      (harness-voice-live--pipeline-turn
       (plist-get harness-voice-live--delegation :id) 'cancelled "retargeted"))
    (setq harness-voice-live--held nil
          harness-voice-live--utterance nil
          harness-voice-live--utterance-done nil)
    (harness-voice-live--cancel-held-timer)))

(defun harness-voice-live--pipeline-turn (id state detail)
  "Record turn ID's STATE and DETAIL, including every source's terminal state."
  (when (and (stringp id) harness-voice-live--pipeline)
    (let ((turn (harness-voice-pipeline--turn harness-voice-live--pipeline id)))
      (dolist (source (plist-get turn :segments))
        (harness-voice-pipeline-segment
         harness-voice-live--pipeline source
         (pcase state ('done 'answered) ('failed 'failed) (_ 'dropped))
         (list :reason (harness-voice-live--pipeline-reason detail)))))
    (harness-voice-pipeline-turn
     harness-voice-live--pipeline id state
     (list :detail detail :generation (harness-voice-live--pipeline-generation)))
    (harness-voice-live--pipeline-touch t)))

(defun harness-voice-live--utterance-route (utterance)
  "Return the route UTTERANCE was spoken under, or the current one.
The sidecar's utterance id names a burst from its onset, so the route
recorded then is where its words belong, whatever is selected when the
transcript arrives."
  (or (and utterance
           (cdr (assoc (format "%s" utterance) harness-voice-live--utterance-routes)))
      (harness-voice-live--route)))

(defun harness-voice-live--utterance-route-set (utterance route)
  "Record that ROUTE is where UTTERANCE's words go.
Only a new id is recorded: a burst keeps the target it started under."
  (when utterance
    (let ((key (format "%s" utterance)))
      (unless (assoc key harness-voice-live--utterance-routes)
        (setq harness-voice-live--utterance-routes
              (cons (cons key route) harness-voice-live--utterance-routes))
        (when (> (length harness-voice-live--utterance-routes) 32)
          (setq harness-voice-live--utterance-routes
                (seq-take harness-voice-live--utterance-routes 32)))))))

(defun harness-voice-live--route-current-p (generation)
  "Return non-nil when GENERATION is the route's generation now."
  (or (null generation) (eql generation harness-voice-live--route-generation)))

(defun harness-voice-live--watched-session-p (session)
  "Return non-nil when SESSION is one this call follows.
That is the route's session now, or the session the running turn was
sent to: a turn that outlives a switch still finishes where it went."
  (and (stringp session)
       (or (equal session harness-voice-live--session)
           (equal session (plist-get harness-voice-live--delegation :session)))))

(defun harness-voice-live--turn-session-p (session)
  "Return non-nil when SESSION is the session this call follows now.
That is the running delegation's own session, so a turn that outlives a
switch still finishes where it was sent; with no delegation, it is the
route's session, so a reply to something typed there is still spoken.
A turn of any other session is somebody else's work."
  (let ((delegation harness-voice-live--delegation))
    (if delegation
        (and (stringp (plist-get delegation :session))
             (equal session (plist-get delegation :session)))
      (equal session harness-voice-live--session))))

;;;###autoload
(defun harness-voice-live-retarget (&optional buffer)
  "Point the running live call at BUFFER's session or workspace thread.
The sidecar, the microphone and the speech services keep running: only
the words' destination moves.  A call that is not running does nothing.
Return non-nil when the target moved."
  (interactive)
  (let* ((buffer (or buffer (current-buffer)))
         (route (harness-voice-live--route-of-buffer buffer)))
    (when (and route (harness-voice-live--active-p))
      (let ((moved (harness-voice-live--route-set route)))
        (when moved
          (harness-voice-live--transcript-route)
          (harness-voice-live--refresh))
        moved))))

(defun harness-voice-live--transcript-route ()
  "Write the route into the transcript, so the record says where it went."
  (when (buffer-live-p harness-voice-live--transcript)
    (let ((label (harness-voice-live--route-label)))
      (when label
        (harness-voice-live--transcript-section 'route "Target")
        (harness-voice-live--transcript-insert
         (concat "  " label "\n") 'harness-dim-face)))))

(defun harness-voice-live--microphone-on-p ()
  "Non-nil while the sidecar microphone is open."
  (and (harness-voice-live--active-p)
       (not harness-voice-live--muted)
       (memq harness-voice-live--state '(listening speaking))))

(defun harness-voice-live--elapsed ()
  "Return the seconds the current stage has taken, or nil.
A stage under a third of a second reports nothing: an elapsed time that
flickers in and out is noise, and a wait that short needs no clock."
  (when (and harness-voice-live--stage-since
             (memq harness-voice-live--stage
                   '(initializing hearing transcribing thinking)))
    (let ((seconds (- (float-time) harness-voice-live--stage-since)))
      (and (>= seconds 0.3) seconds))))

(defun harness-voice-live--stage-name ()
  "Return the word for the current stage, or nil."
  (pcase harness-voice-live--stage
    ('initializing "Initializing")
    ('listening "Listening")
    ('hearing "Hearing you")
    ('transcribing "Transcribing")
    ('holding "Holding reply")
    ('finishing "Finishing thought")
    ('recovering "Recovering thought")
    ('continuation "Waiting for continuation")
    ('cut-off "Possible cut-off")
    ('thinking "Working")
    ('speaking "Speaking")
    ('muted (harness-voice-live--paused-word))
    ('failed "Failed")))

(defun harness-voice-live--busy-p ()
  "Non-nil while the current stage should animate.
Speaking has its own mark: the reply is arriving, not waited for."
  (memq harness-voice-live--stage '(initializing hearing transcribing thinking)))

(defun harness-voice-live--stage-glyph ()
  "Return the indicator of the current stage: a spinner or a dot."
  (cond
   ((and (harness-voice-live--busy-p) harness-voice-live--stage-timer
         harness-voice-live-motion)
    (aref harness-voice-live--spinner
          (mod harness-voice-live--stage-frame (length harness-voice-live--spinner))))
   ((eq harness-voice-live--stage 'speaking) "▷")
   ((eq harness-voice-live--stage 'holding) "‖")
   ((eq harness-voice-live--stage 'recovering) "↺")
   ((eq harness-voice-live--stage 'muted) "⊘")
   ((eq harness-voice-live--stage 'failed) "✕")
   (t "●")))

(defun harness-voice-live--stage-text ()
  "Return the stage line: indicator, word and elapsed time."
  (let ((name (harness-voice-live--stage-name))
        (elapsed (harness-voice-live--elapsed)))
    (when name
      (concat (harness-voice-live--stage-glyph) " " name
              (when elapsed (format " · %.1fs" elapsed))))))

(defun harness-voice-live--tick ()
  "Advance the busy indicator and redraw the stage line and controls."
  (when (harness-voice-live--busy-p)
    (setq harness-voice-live--stage-frame (1+ harness-voice-live--stage-frame))
    (harness-voice-live--stage-redraw)
    (harness-voice-live--refresh)))

(defun harness-voice-live--stage-set (stage)
  "Make STAGE the current one, animating it while it is active."
  (unless (eq stage harness-voice-live--stage)
    (setq harness-voice-live--stage stage
          harness-voice-live--stage-since (and stage (float-time))
          harness-voice-live--stage-frame 0)
    (when (timerp harness-voice-live--stage-timer)
      (cancel-timer harness-voice-live--stage-timer)
      (setq harness-voice-live--stage-timer nil))
    (when (harness-voice-live--busy-p)
      (setq harness-voice-live--stage-timer
            (run-at-time 0.2 0.2 #'harness-voice-live--tick)))
    (harness-voice-live--stage-redraw)
    (harness-voice-live--refresh)))

(defun harness-voice-live--paused-word ()
  "Return the word for a session whose capture path is closed.
A camera session is paused: the device is closed and nothing is read.  A
microphone session is muted, which is what that word means."
  (if (harness-voice-provider-camera-p) "Paused" "Muted"))

(defun harness-voice-live--pause-button ()
  "Return the control that closes the capture path, for this provider."
  (if (harness-voice-provider-camera-p) "Pause C-c v" "Mute C-c v"))

(defun harness-voice-live--resume-button ()
  "Return the control that opens the capture path again, for this provider."
  (if (harness-voice-provider-camera-p) "Resume C-c v" "Unmute C-c v"))

(defvar harness-voice-live--status-names-target nil
  "Non-nil makes the status name the target even in the target's box.
The mode line is one indicator for the whole frame, so it always names
where the words go; a compose box names the target only when it is not
the target, where the name is the fact the person needs.")

(defun harness-voice-live--status ()
  "Return the exact live status copy.
A running call names its target after the state, so the indicator and
the destination cannot disagree: a box that is not the target says so
by naming the one that is."
  (concat
   "Live"
   (cond
    ((eq harness-voice-live--state 'failed) " · Failed")
    ((eq harness-voice-live--state 'initializing) " · Initializing")
    ((eq harness-voice-live--state 'starting) " · Starting")
    ((eq harness-voice-live--state 'ending) " · Ending")
    ((eq harness-voice-live--state 'interrupted) " · Interrupted")
    ((memq harness-voice-live--stage '(initializing hearing transcribing thinking))
     (concat " · " (harness-voice-live--stage-name)
             (let ((elapsed (harness-voice-live--elapsed)))
               (when elapsed (format " · %.1fs" elapsed)))))
    ((memq harness-voice-live--stage '(finishing continuation cut-off recovering))
     (concat " · " (harness-voice-live--stage-name)))
    ((eq harness-voice-live--state 'speaking) " · Speaking")
    ((eq harness-voice-live--stage 'speaking) " · Speaking")
    ((eq harness-voice-live--stage 'holding) " · Holding reply")
    (harness-voice-live--working " · Working")
    ((and harness-voice-live--muted (harness-voice-live--active-p))
     (concat " · " (harness-voice-live--paused-word)))
    ((or (eq harness-voice-live--state 'listening)
         (eq harness-voice-live--stage 'listening)) " · Listening")
    ((null harness-voice-live--state) " · Off")
    (t ""))
   (when (and (harness-voice-live--active-p)
              (not (memq harness-voice-live--state '(ending failed)))
              (or harness-voice-live--status-names-target
                  (not (harness-voice-live--here-p))))
     (let ((label (harness-voice-live--route-label)))
       (when label (concat " · " label))))))

(defun harness-voice-live--refresh ()
  "Refresh the owner's controls and the mode line."
  (if (buffer-live-p harness-voice-live--buffer)
      (with-current-buffer harness-voice-live--buffer
        (harness-voice--refresh))
    (force-mode-line-update t)))

(defun harness-voice-live--release-others ()
  "Point a running live call at this compose box, instead of ending it.
The sidecar owns the microphone and the speech services; a person who
selects another session wants the next words to go there, not a call
that stops and starts again.  A call that is not running is left to
`harness-voice-live-start'."
  (when (and (harness-voice-live--active-p)
             (not (eq harness-voice-live--buffer (current-buffer))))
    (harness-voice-live-retarget (current-buffer))))

(defun harness-voice-live--adopt-other-box ()
  "Move the call to another compose box that can take it, or return nil.
The box the call started in can be closed while the person is still
talking; the call belongs to the microphone, not to that buffer.  A
visible compose box of a session or workspace is a target; with none,
the call has nowhere to go and ends."
  (let ((candidates
         (cl-remove-if-not
          (lambda (buffer)
            (and (buffer-live-p buffer)
                 (not (eq buffer harness-voice-live--buffer))
                 (with-current-buffer buffer
                   (and (harness-compose-live-p)
                        (harness-voice-live--route-of-buffer buffer)))))
          (buffer-list))))
    (when candidates
      (let* ((buffer (car candidates))
             (route (harness-voice-live--route-of-buffer buffer)))
        (harness-voice-live--route-set route)
        (harness-voice-live--transcript-route)
        (harness-voice-live--refresh)
        t))))

(defun harness-voice-live--here-p ()
  "Non-nil when this compose box is the live call's target."
  (and (harness-voice-live--active-p)
       (eq harness-voice-live--buffer (current-buffer))))

(defun harness-voice-live--target-p (&optional buffer)
  "Non-nil when BUFFER, this buffer by default, names a live target.
A compose box that names no session and no workspace thread has nowhere
to send its words, so it is not a target and must not offer to start a
call: the task board's box and a popout's box are such hosts.  This asks
what the start asks (`harness-voice-live--route-of-buffer'), so a box
that draws Start is exactly a box whose Start works.  A control line
runs before the box's markers are placed, so it asks
`harness-compose-host-p', never `harness-compose-live-p'."
  (let ((buffer (or buffer (current-buffer))))
    (and (buffer-live-p buffer)
         (with-current-buffer buffer
           (and (harness-compose-host-p)
                (harness-voice-live--route-of-buffer buffer)
                t)))))

(defun harness-voice-live--face ()
  "Return the face for the live status."
  (cond ((eq harness-voice-live--state 'failed) 'harness-failure-face)
        ((harness-voice-live--microphone-on-p) 'harness-caution-face)
        (t 'harness-label-face)))

(defconst harness-voice-live--camera-states
  '(("opening" . "opening") ("live" . "live") ("paused" . "paused")
    ("denied" . "denied") ("failed" . "failed"))
  "The words for a camera provider's state in the controls.")

(defun harness-voice-live--camera-label ()
  "Return the controls' camera words: the state and the face count.
A camera that is on but sees no face says so, which is the difference
between capturing and reading."
  (let* ((camera harness-voice-live--camera)
         (state (or (plist-get camera :state) "closed"))
         (word (or (cdr (assoc state harness-voice-live--camera-states)) state))
         (faces (plist-get camera :faces)))
    (concat "Camera · " word
            (when (and (equal state "live") faces)
              (concat " · " (if (zerop faces) "no face"
                              (format "%d %s" faces (if (= faces 1) "face" "faces"))))))))

(defun harness-voice-live--camera-face ()
  "Return the face for the camera state in the controls."
  (pcase (plist-get harness-voice-live--camera :state)
    ("live" (if (zerop (or (plist-get harness-voice-live--camera :faces) 0))
                'harness-caution-face
              'harness-success-face))
    ((or "failed" "denied") 'harness-failure-face)
    (_ 'harness-caution-face)))

(defun harness-voice-live--controls ()
  "Return fitted live voice controls for a compose box, or nil.
A box that is not the call's target still shows the call, with the
target's name and a control that moves the words here: the indicator
never says `Listening' in a box the words do not go to.

A box that names no session and no workspace thread has nowhere to send
its words, so it offers no start and no target: it says `Voice · no
session' instead.  The task board and a popout are such hosts, and a
Start control there could only fail (`harness-voice-live--target-p')."
  (when (and harness-voice--enabled (harness-voice-live-p))
    (let ((active (harness-voice-live--active-p))
          (here (harness-voice-live--here-p))
          (target (harness-voice-live--target-p))
          (items nil))
      (if (not harness-voice--controls)
          (setq items (list (list (harness-voice--button
                                   "Voice" #'harness-voice "Voice controls · C-c h V v"))))
        (if (not target)
            (setq items
                  (list
                   (list (propertize "Voice · no session" 'face 'harness-dim-face
                                     'help-echo "Live voice · no session target")
                         100 nil)
                   (and active
                        (list (harness-voice--button "Transcript" #'harness-voice-live-transcript
                                                     "Live transcript") 60 nil))
                   (list (harness-voice--button "Setup" #'harness-voice-setup
                                                "Voice settings") 50 nil)))
          (setq items
                (list
                 (list (propertize (harness-voice-live--status)
                                   'face (harness-voice-live--face)
                                   'help-echo (or harness-voice-live--error "Live voice status"))
                       100 nil)
                 (list (cond
                        ((and active here)
                         (harness-voice--button "End" #'harness-voice-live-stop
                                                "Live session · end"))
                        (active
                         (harness-voice--button "Use here" #'harness-voice-live-use-here
                                                "Live voice · target"))
                        (t
                         (harness-voice--button "Start" #'harness-voice-live--start-here
                                                "Live voice · sidecar session")))
                       95 nil)
                 (and active here harness-voice-live--pending
                      (not (harness-voice-live--input-busy-p))
                      (list (harness-voice--button "Submission" #'harness-voice-live-send-now
                                                   "Pending speech submission") 94 nil))
                 (and active here
                      (list (harness-voice--button "Interrupt C-c V" #'harness-voice-live-interrupt
                                                   "Playback · interruption") 90 nil))
                 (and harness-voice-live--error
                      (list (propertize harness-voice-live--error 'face 'harness-failure-face
                                        'help-echo harness-voice-live--error) 85 nil))
                 (and active harness-voice-live--camera
                      (list (propertize (harness-voice-live--camera-label)
                                        'face (harness-voice-live--camera-face)
                                        'help-echo "Camera · live capture")
                            84 nil))
                 (and active harness-voice-live--notice
                      (list (propertize harness-voice-live--notice 'face 'harness-caution-face
                                        'help-echo harness-voice-live--notice) 83 nil))
                 (and active here harness-voice-live--control-status
                      (list (propertize harness-voice-live--control-status
                                      'face 'harness-caution-face
                                      'help-echo harness-voice-live--control-status) 82 nil))
                 (and active here harness-voice-live--working
                      (list (harness-voice--button "Cancel work" #'harness-voice-live-cancel
                                                   "Agent turn · cancellation") 80 nil))
                 (and active here
                      (list (harness-voice--button
                             (if harness-voice-live--muted
                                 (harness-voice-live--resume-button)
                               (harness-voice-live--pause-button))
                             #'harness-voice-live-mute
                             (if (harness-voice-provider-camera-p)
                                 "Camera · live capture"
                               "Microphone · live session")) 70 nil))
                 (list (harness-voice--button "Transcript" #'harness-voice-live-transcript
                                              "Live transcript") 60 nil)
                 (list (harness-voice--button "Setup" #'harness-voice-setup
                                              "Voice settings") 50 nil)))))
      (let ((room (max 1 (- (/ (harness-compose--room) (frame-char-width)) 3))))
        (concat (harness-ui-settings-line (list items) room)
                ;; The pipeline is a line of its own under the controls:
                ;; one settings line cannot fit both, and the strip must
                ;; stay readable at a narrow width.
                (when (and active here (> room 20))
                  (concat "\n" (harness-voice-pipeline-compact-line
                                harness-voice-live--pipeline room)))
                (when (and active here harness-voice-live--pending)
                  (concat "\n" (harness-voice-live--pending-line room))))))))

(defun harness-voice-live--pending-line (width)
  "Return the unsent draft, fitted to WIDTH without changing its words."
  (truncate-string-to-width
   (concat (propertize "Unsent speech" 'face 'harness-label-face)
           " · " (harness-ui-one-line (harness-voice-live--pending-text)))
   width nil nil "…"))

;; The rule closes the pipeline block, above the transcript it belongs to.
(defconst harness-voice-live--transcript-rule
  (propertize (make-string 58 ?─) 'face 'harness-dim-face)
  "The rule under the transcript's stage line.")

;;;; The pipeline

(defvar-local harness-voice-live--pipeline-end nil
  "Marker at the end of the pipeline block in the transcript buffer.")
(defvar-local harness-voice-live--pipeline-details nil
  "Non-nil when the transcript shows every marker of the pipeline.")

(defun harness-voice-live--input ()
  "Return the input the selected provider reads: `mic' or `camera'."
  (if (harness-voice-provider-camera-p) 'camera 'mic))

(defun harness-voice-live--pipeline-generation ()
  "Return the generation of the pipeline this session feeds."
  (harness-voice-pipeline-generation harness-voice-live--pipeline))

(defun harness-voice-live--pipeline-bump (capture)
  "Begin a new pipeline, with the capture path in CAPTURE state.
The pipeline is told which input the provider reads, so a camera session
is never described with a microphone's words."
  (harness-voice-pipeline-bump harness-voice-live--pipeline capture
                               (harness-voice-live--input))
  (setq harness-voice-live--utterance nil
        harness-voice-live--utterance-done nil
        harness-voice-live--caption-seq 0
        harness-voice-live--reply-seq 0
        harness-voice-live--pipeline-controls-at nil)
  (harness-voice-live--pipeline-touch t))

(defun harness-voice-live--pipeline-touch (&optional controls)
  "Note that the pipeline changed.
The strip is redrawn once the current events are handled, and only
while a window shows it.  CONTROLS also refreshes the compose box's
line, at most four times a second: levels arrive ten times a second,
which is the meter's rate, not the transcript's."
  (when (buffer-live-p harness-voice-live--transcript)
    (unless (timerp harness-voice-live--pipeline-timer)
      (setq harness-voice-live--pipeline-timer
            (run-at-time 0.1 nil #'harness-voice-live--pipeline-redraw))))
  (when controls
    (let ((now (float-time)))
      (when (or (null harness-voice-live--pipeline-controls-at)
                (>= (- now harness-voice-live--pipeline-controls-at) 0.25))
        (setq harness-voice-live--pipeline-controls-at now)
        (harness-voice-live--refresh)))))

(defun harness-voice-live--pipeline-redraw ()
  "Redraw the pipeline strip now, when a window shows it."
  (setq harness-voice-live--pipeline-timer nil)
  (when (buffer-live-p harness-voice-live--transcript)
    (with-current-buffer harness-voice-live--transcript
      (when (get-buffer-window (current-buffer) t)
        (harness-voice-live--pipeline-draw)))))

(defun harness-voice-live-pipeline-details ()
  "Show or hide every marker of the voice pipeline."
  (interactive)
  (let ((buffer (if (buffer-live-p harness-voice-live--transcript)
                    harness-voice-live--transcript
                  (current-buffer))))
    (with-current-buffer buffer
      (setq harness-voice-live--pipeline-details
            (not harness-voice-live--pipeline-details))
      (harness-voice-live--pipeline-draw))))

(defun harness-voice-live--pipeline-block (width)
  "Return the pipeline block's lines for a window WIDTH wide."
  (append
   (harness-voice-pipeline-block harness-voice-live--pipeline width)
   (when harness-voice-live--pending
     (list (harness-voice-live--pending-line width)))
   (list (harness-ui-action-button
          (if harness-voice-live--pipeline-details "[Hide details]" "[Show details]")
          #'harness-voice-live-pipeline-details
          :help "show the pipeline details"))
   (when harness-voice-live--pipeline-details
     (append (list "")
             (list (propertize "Pipeline details" 'face 'harness-label-face))
             (harness-voice-pipeline-details harness-voice-live--pipeline)))
   (list harness-voice-live--transcript-rule)))

(defun harness-voice-live--pipeline-draw ()
  "Draw the pipeline block at the top of the transcript buffer."
  (when (buffer-live-p harness-voice-live--transcript)
    (with-current-buffer harness-voice-live--transcript
      (let* ((inhibit-read-only t)
             (buffer-undo-list t)
             (window (get-buffer-window (current-buffer) t))
             (width (if window (window-width window) harness-voice-pipeline-width))
             (end (and (markerp harness-voice-live--pipeline-end)
                       (marker-position harness-voice-live--pipeline-end))))
        (save-excursion
          (goto-char (point-min))
          (delete-region (point-min) (or end (point-min)))
          (insert (string-join (harness-voice-live--pipeline-block width) "\n") "\n")
          (unless (markerp harness-voice-live--pipeline-end)
            (setq-local harness-voice-live--pipeline-end (copy-marker (point))))
          (set-marker harness-voice-live--pipeline-end (point))
          (force-mode-line-update t))))))

(defun harness-voice-live--pipeline-level (level &optional peak dbfs)
  "Record the capture path's LEVEL, PEAK and DBFS, and let it go stale.
LEVEL is the mean absolute sample the gate itself uses; PEAK and DBFS
are the same chunk's loudest sample and its decibel reading, when the
sidecar measured them.  Nothing here changes a sample or a threshold:
the meter draws a scale, and the details keep the numbers."
  (when (numberp level)
    (harness-voice-pipeline-set-level harness-voice-live--pipeline level nil
                                      (harness-voice-live--pipeline-generation)
                                      peak dbfs)
    (harness-voice-live--pipeline-touch t)
    (when (timerp harness-voice-live--pipeline-stale-timer)
      (cancel-timer harness-voice-live--pipeline-stale-timer))
    (setq harness-voice-live--pipeline-stale-timer
          (run-at-time (+ harness-voice-pipeline-level-timeout 0.05) nil
                       #'harness-voice-live--pipeline-stale))))

(defun harness-voice-live--pipeline-stale ()
  "Redraw after a level stopped arriving: the meter says it has no data."
  (setq harness-voice-live--pipeline-stale-timer nil)
  (harness-voice-live--pipeline-touch t))

(defun harness-voice-live--pipeline-speech (active)
  "Record whether the speech gate hears speech now, ACTIVE."
  (harness-voice-pipeline-set-gate harness-voice-live--pipeline (and active t)
                                   (harness-voice-live--pipeline-generation))
  (harness-voice-live--pipeline-touch t))

(defun harness-voice-live--pipeline-reason (reason)
  "Return REASON as the symbol the pipeline names."
  (and (stringp reason)
       (not (string-empty-p reason))
       (intern (replace-regexp-in-string "[ \t]+" "-" (string-trim reason)))))

(defun harness-voice-live--pipeline-segment (event)
  "Record one sidecar `segment' EVENT: a burst's own decision."
  (let ((id (plist-get event :id))
        (state (plist-get event :state)))
    (when (stringp id)
      (let ((stage (pcase state
                     ("accepted" 'accepted)
                     ("transcribing" 'transcribing)
                     ("transcribed" 'transcribed)
                     ("in-turn" 'in-turn)
                     ("answered" 'answered)
                     ("dropped" 'dropped)
                     ("failed" 'failed))))
        (when stage
          (harness-voice-pipeline-segment
           harness-voice-live--pipeline id stage
           (list :seconds (plist-get event :seconds)
                 :reason (harness-voice-live--pipeline-reason (plist-get event :reason))
                 :text (plist-get event :text)
                 :generation (harness-voice-live--pipeline-generation)))
          (cond
           ((eq stage 'transcribing)
            (setq harness-voice-live--utterance id
                  harness-voice-live--utterance-done nil))
           ;; A final caption waits for its turn; a stale one names a
           ;; segment the next delegation is not about, so it is ignored.
           ((memq stage '(transcribed dropped failed))
            (when (equal id harness-voice-live--utterance)
              (setq harness-voice-live--utterance nil)
              (when (eq stage 'transcribed)
                (setq harness-voice-live--utterance-done id)))))
          (harness-voice-live--pipeline-touch t))))))

(defun harness-voice-live--pipeline-caption (text final)
  "Record the provider's caption TEXT, FINAL when it is the last.
The provider's transcript is its own segment (`v-N') when the sidecar
sent no utterance id: it is the unit a caption arrived in, not a claim
that one burst of the gate became one transcript."
  (when (and (stringp text) (not (string-empty-p text)))
    (unless harness-voice-live--utterance
      (cl-incf harness-voice-live--caption-seq)
      (setq harness-voice-live--utterance
            (format "v-%d" harness-voice-live--caption-seq)
            harness-voice-live--utterance-done nil))
    (harness-voice-pipeline-segment
     harness-voice-live--pipeline harness-voice-live--utterance
     (if final 'transcribed 'transcribing)
     (list :text text :generation (harness-voice-live--pipeline-generation)))
    (when final
      (setq harness-voice-live--utterance-done harness-voice-live--utterance
            harness-voice-live--utterance nil))
    (harness-voice-live--pipeline-touch t)))

(defun harness-voice-live--pipeline-turn-sent (id &optional segments)
  "Record turn ID's delivery with all source SEGMENTS, in onset order."
  (let ((generation (harness-voice-live--pipeline-generation)))
    (dolist (segment (or segments (list (or harness-voice-live--utterance
                                            harness-voice-live--utterance-done))))
      (harness-voice-pipeline-turn harness-voice-live--pipeline id 'working
                                   (list :segment segment :generation generation))
      (when segment
        (harness-voice-pipeline-segment harness-voice-live--pipeline segment 'in-turn
                                        (list :generation generation))
        (when (equal segment harness-voice-live--utterance-done)
          (setq harness-voice-live--utterance-done nil))))
    (harness-voice-live--pipeline-touch t)))

(defun harness-voice-live--pipeline-turn-queued (id &optional segments)
  "Record that turn ID and its source SEGMENTS wait behind the running turn."
  (dolist (segment (or segments (list (or harness-voice-live--utterance
                                          harness-voice-live--utterance-done))))
    (harness-voice-pipeline-turn
     harness-voice-live--pipeline id 'queued
     (list :segment segment :generation (harness-voice-live--pipeline-generation))))
  (harness-voice-live--pipeline-touch t))

(defun harness-voice-live--pipeline-turn-ended (state &optional detail)
  "Record that the turn in flight ended in STATE, with DETAIL."
  (when harness-voice-live--turn-id
    (harness-voice-live--pipeline-turn harness-voice-live--turn-id state detail)))

(defun harness-voice-live--pipeline-reply-id (piece)
  "Return the reply id a speakable PIECE belongs to.
A streamed answer is named by its node, `n-3:120' by its node and
offset; a whole held result is one piece of its own."
  (let ((piece (or piece "")))
    (if (string-prefix-p "result:" piece)
        piece
      (car (split-string piece ":")))))

(defun harness-voice-live--pipeline-reply-ready (id text)
  "Record that reply ID is ready to be spoken, with TEXT as its words."
  (when (and (stringp id) (not (string-empty-p id)))
    (let ((generation (harness-voice-live--pipeline-generation)))
      (harness-voice-pipeline-reply harness-voice-live--pipeline id 'ready
                                    (list :text (and text (string-trim text))
                                          :turn harness-voice-live--turn-id
                                          :generation generation))
      (when harness-voice-live--turn-id
        (harness-voice-pipeline-turn
         harness-voice-live--pipeline harness-voice-live--turn-id 'replied
         (list :reply id :generation generation)))
      (harness-voice-live--pipeline-touch t))))

(defun harness-voice-live--pipeline-reply-held (piece)
  "Record that the reply of speakable PIECE is held for turn-taking."
  (harness-voice-pipeline-reply
   harness-voice-live--pipeline (harness-voice-live--pipeline-reply-id piece) 'held
   (list :generation (harness-voice-live--pipeline-generation)))
  (harness-voice-live--pipeline-touch t))

(defun harness-voice-live--pipeline-reply-handed (piece)
  "Record that the reply of speakable PIECE was handed to the provider."
  (harness-voice-pipeline-reply
   harness-voice-live--pipeline (harness-voice-live--pipeline-reply-id piece) 'handed
   (list :generation (harness-voice-live--pipeline-generation)))
  (harness-voice-live--pipeline-touch t))

(defun harness-voice-live--pipeline-playback (state)
  "Record the provider's playback STATE: speaking, listening or interrupted."
  (let* ((pipeline harness-voice-live--pipeline)
         (generation (harness-voice-live--pipeline-generation))
         (replies (harness-voice-pipeline-replies pipeline)))
    (pcase state
      ('speaking
       (let ((reply (cl-find-if (lambda (reply)
                                  (memq (plist-get reply :stage) '(handed ready)))
                                replies)))
         (unless reply
           ;; The provider reported playback the UI did not hand it a piece
           ;; of: a reply of its own, named so it is not mistaken for one.
           (cl-incf harness-voice-live--reply-seq)
           (let ((id (format "voice-%d" harness-voice-live--reply-seq)))
             (harness-voice-pipeline-reply pipeline id 'ready (list :generation generation))
             (setq reply (cl-find id (harness-voice-pipeline-replies pipeline)
                                  :key (lambda (item) (plist-get item :id)) :test #'equal))))
         (when reply
           (harness-voice-pipeline-reply pipeline (plist-get reply :id) 'speaking
                                         (list :generation generation)))))
      ('listening
       (dolist (reply replies)
         (when (eq (plist-get reply :stage) 'speaking)
           (harness-voice-pipeline-reply pipeline (plist-get reply :id) 'spoken
                                         (list :generation generation)))))
      ('interrupted
       (harness-voice-pipeline-finish-replies pipeline 'interrupted "interrupted"
                                             generation)))
    (harness-voice-live--pipeline-touch t)))

(defun harness-voice-live--pipeline-muted (muted)
  "Record that the capture path is closed, MUTED, or open again.
A camera that is closed is paused, not muted: it has no microphone, and
its own word is the one the strip says."
  (harness-voice-pipeline-set-capture harness-voice-live--pipeline
                                      (cond ((not muted) 'live)
                                            ((eq (harness-voice-live--input) 'camera)
                                             'paused)
                                            (t 'muted))
                                      nil (harness-voice-live--pipeline-generation))
  (when muted
    (harness-voice-pipeline-finish-replies harness-voice-live--pipeline 'dropped "muted"
                                           (harness-voice-live--pipeline-generation)))
  (harness-voice-live--pipeline-touch t))

(defun harness-voice-live--pipeline-end (capture &optional problem)
  "Record that the session stopped with the microphone in CAPTURE.
PROBLEM is the sidecar's own words about a failure.  The markers stay as
the last true picture; what could still be heard is dropped with the
reason it ended."
  (let ((generation (harness-voice-live--pipeline-generation)))
    (harness-voice-pipeline-set-capture harness-voice-live--pipeline capture problem
                                        generation)
    (harness-voice-pipeline-clear-level harness-voice-live--pipeline generation)
    (harness-voice-pipeline-finish-replies harness-voice-live--pipeline 'dropped "ended"
                                           generation)
    (harness-voice-live--pipeline-touch t)))

;;;; Sidecar process

(defun harness-voice-live--command ()
  "Return the validated sidecar argv list, or signal.
The command belongs to the selected provider: the GPT-Live adapter, the
local pipeline, the fixture or a custom sidecar."
  (harness-voice-provider-command))

(defun harness-voice-live--json (object)
  "Return OBJECT as one JSON line."
  (concat (json-serialize object :false-object :false :null-object :null)
          "\n"))

(defun harness-voice-live--send (object)
  "Send OBJECT to the sidecar, when its process still runs."
  (when (harness-voice-live--active-p)
    (condition-case err
        (progn
          (process-send-string harness-voice-live--process
                               (harness-voice-live--json object))
          t)
      (error
       (harness-voice-live--fail (format "Live voice send failure · %s"
                                         (error-message-string err)))
       nil))))

(defun harness-voice-live--stderr-tail ()
  "Return the last line or two of sidecar stderr on one line."
  (when (buffer-live-p harness-voice-live--stderr)
    (with-current-buffer harness-voice-live--stderr
      (let ((text (string-trim (buffer-substring-no-properties
                                (point-min) (point-max)))))
        (unless (string-empty-p text)
          (let ((start (max 0 (- (length text) 300))))
            (harness-ui-one-line (substring text start))))))))

(defun harness-voice-live--dispose ()
  "Kill the sidecar and its buffers without reporting a failure."
  (harness-voice-conversation-clear harness-voice-live--conversation)
  (when (timerp harness-voice-live--timer)
    (cancel-timer harness-voice-live--timer))
  (when (timerp harness-voice-live--stage-timer)
    (cancel-timer harness-voice-live--stage-timer))
  (when (timerp harness-voice-live--pipeline-timer)
    (cancel-timer harness-voice-live--pipeline-timer))
  (when (timerp harness-voice-live--pipeline-stale-timer)
    (cancel-timer harness-voice-live--pipeline-stale-timer))
  (setq harness-voice-live--pipeline-timer nil
        harness-voice-live--timer nil
        harness-voice-live--pipeline-timer nil
        harness-voice-live--pipeline-stale-timer nil
        harness-voice-live--stage-timer nil
        harness-voice-live--stage nil
        harness-voice-live--stage-since nil)
  (harness-voice-live--clear-gate)
  (let ((process harness-voice-live--process))
    (setq harness-voice-live--process nil
          harness-voice-live--tail "")
    (when (processp process)
      (ignore-errors (set-process-sentinel process #'ignore))
      (when (process-live-p process) (delete-process process))))
  (when (buffer-live-p harness-voice-live--stderr)
    (kill-buffer harness-voice-live--stderr))
  (setq harness-voice-live--stderr nil)
  (setq harness-voice-live--camera nil)
  ;; Every way a session ends passes here: the provider drops what the
  ;; session was allowed -- a camera grant, a device -- before the next
  ;; one starts.
  (harness-voice-live--stopped))

(defun harness-voice-live--clear-turn ()
  "Forget the turn in flight and every delegation."
  (cl-incf harness-voice-live--agent-watch)
  (cl-incf harness-voice-live--control-seq)
  (setq harness-voice-live--agent-turn nil
        harness-voice-live--control-status nil
        harness-voice-live--output-suppressed nil
        harness-voice-live--working nil
        harness-voice-live--turn-active nil
        harness-voice-live--delegation nil
        harness-voice-live--delegations nil
        harness-voice-live--nodes nil
        harness-voice-live--order nil
        harness-voice-live--heard ""))

(defun harness-voice-live--clear-gate ()
  "Forget speech, pending input, held output, a recovery and their timers."
  (harness-voice-live--recovery-cancel)
  (harness-voice-live--pending-cancel "cancelled")
  (harness-voice-live--cancel-held-timer)
  (setq harness-voice-live--held-timer nil
        harness-voice-live--speech-active nil
        harness-voice-live--held nil
        harness-voice-live--turn-id nil))

(defun harness-voice-live--holding-output-p ()
  "Non-nil while assistant text must not be sent to the sidecar."
  (or harness-voice-live--pending harness-voice-live--caption-hold
      (harness-voice-live--input-busy-p)
      harness-voice-live--held
      (memq harness-voice-live--stage '(hearing transcribing holding recovering))
      (eq (harness-voice-recovery-state harness-voice-live--recovery) 'recovering)))

(defun harness-voice-live--cancel-held-timer ()
  "Cancel a pending false-trigger release, including an already queued callback."
  (cl-incf harness-voice-live--held-token)
  (when (timerp harness-voice-live--held-timer)
    (cancel-timer harness-voice-live--held-timer))
  (setq harness-voice-live--held-timer nil))

(defun harness-voice-live--schedule-held-release ()
  "Release held text after `harness-voice-live-pending-release-delay'.
Only a trigger that produced no utterance schedules this; a real
utterance sends transcribing first, which cancels it."
  (harness-voice-live--cancel-held-timer)
  (when (and harness-voice-live--held
             (not harness-voice-live--pending)
             (not harness-voice-live--caption-hold)
             (not (harness-voice-live--input-busy-p)))
    (setq harness-voice-live--held-timer
          (run-at-time harness-voice-live-pending-release-delay nil
                       #'harness-voice-live--held-expired harness-voice-live--held-token
                       harness-voice-live--route-generation))))

(defun harness-voice-live--held-expired (token generation)
  "Release only the false trigger whose TOKEN and route GENERATION still match."
  (when (and (= token harness-voice-live--held-token)
             (harness-voice-live--route-current-p generation))
    (harness-voice-live--release-held)))

(defun harness-voice-live--hold (id text)
  "Hold assistant TEXT with ID until a transcript decides what to do."
  (when (and (stringp text) (not (string-empty-p text)))
    (unless (and id (cl-find id harness-voice-live--held
                             :key (lambda (item) (plist-get item :id))
                             :test #'equal))
      (setq harness-voice-live--held-seq (1+ harness-voice-live--held-seq))
      (harness-voice-live--pipeline-reply-held (or id (format "held-%d" harness-voice-live--held-seq)))
      (push (list :id (or id (format "held-%d" harness-voice-live--held-seq))
                  :text text
                  :turn harness-voice-live--turn-id)
            harness-voice-live--held)
      (when (> (length harness-voice-live--held) 40)
        (setq harness-voice-live--held (seq-take harness-voice-live--held 40))))
    (harness-voice-live--stage-set
     (cond (harness-voice-live--pending (harness-voice-live--pending-stage))
           (harness-voice-live--caption-hold harness-voice-live--caption-hold)
           (t 'holding)))))

(defun harness-voice-live--release-held ()
  "Send held output now; only a false trigger or an explicit resume does."
  (harness-voice-live--cancel-held-timer)
  (unless (or harness-voice-live--pending harness-voice-live--caption-hold
              (harness-voice-live--input-busy-p))
    (let ((items (reverse harness-voice-live--held)))
      (setq harness-voice-live--held nil)
      (dolist (item items)
        (when (harness-voice-live--active-p)
          (harness-voice-live--pipeline-reply-handed (plist-get item :id))
          (harness-voice-live--send
           (list :event "commentary"
                 :id (plist-get item :id)
                 :text (plist-get item :text)))
          (harness-voice-conversation-say
           harness-voice-live--conversation (plist-get item :text) 'commentary)))
      (harness-voice-live--settle-stage))))

(defun harness-voice-live--delegate-key (event)
  "Return the exact-once key of delegation EVENT."
  (or (plist-get event :utterance)
      (plist-get event :id)))

(defun harness-voice-live--delegate-seen-p (event)
  "Return non-nil when EVENT's utterance already reached the session."
  (let ((key (harness-voice-live--delegate-key event)))
    (when key
      (if (gethash key harness-voice-live--seen)
          t
        (puthash key t harness-voice-live--seen)
        nil))))

(defun harness-voice-live--fail (detail)
  "Fail the live session visibly with DETAIL."
  (let ((text (harness-ui-one-line detail)))
    (harness-voice-live--pipeline-end 'failed text)
    (harness-voice-live--dispose)
    (setq harness-voice-live--state 'failed
          harness-voice-live--error text
          harness-voice-live--closing nil)
    (harness-voice-live--stage-set 'failed)
    (harness-voice-live--clear-gate)
    (harness-voice-live--clear-turn)
    (harness-voice-live--refresh)))

(defun harness-voice-live--startup-timeout ()
  "Fail a sidecar that never became ready."
  (when (and (harness-voice-live--active-p)
             (eq harness-voice-live--state 'starting))
    (harness-voice-live--fail "Live voice startup timeout")))

(defun harness-voice-live--stop-timeout ()
  "Kill a sidecar that did not close when asked."
  (when (harness-voice-live--active-p)
    (harness-voice-live--dispose)
    (setq harness-voice-live--state nil
          harness-voice-live--closing nil)
    (harness-voice-live--clear-gate)
    (harness-voice-live--refresh)))

(defun harness-voice-live--finished (process _status)
  "Handle sidecar PROCESS exiting on its own or after a stop."
  (when (eq process harness-voice-live--process)
    (let ((tail (harness-voice-live--stderr-tail))
          (closing harness-voice-live--closing)
          (state harness-voice-live--state))
      (when (timerp harness-voice-live--timer)
        (cancel-timer harness-voice-live--timer))
      (setq harness-voice-live--timer nil
            harness-voice-live--process nil
            harness-voice-live--tail "")
      (when (buffer-live-p harness-voice-live--stderr)
        (kill-buffer harness-voice-live--stderr))
      (setq harness-voice-live--stderr nil
            harness-voice-live--closing nil
            harness-voice-live--camera nil)
      (harness-voice-live--clear-gate)
      (harness-voice-live--clear-turn)
      (harness-voice-live--stopped)
      (cond
       (closing
        (setq harness-voice-live--state nil))
       ((eq state 'failed) nil)
       (t
        (setq harness-voice-live--state 'failed
              harness-voice-live--error
              (if tail (format "Live voice ended · %s" tail)
                "Live voice ended"))
        (harness-voice-live--pipeline-end
         'disconnected (if tail (format "Live voice ended · %s" tail)
                         "Live voice ended"))))
      (harness-voice-live--refresh))))

(defun harness-voice-live--filter (process chunk)
  "Read JSON lines from sidecar PROCESS out of CHUNK."
  (when (eq process harness-voice-live--process)
    (setq harness-voice-live--tail (concat harness-voice-live--tail chunk))
    (let ((tail harness-voice-live--tail)
          (start 0))
      (while (and (eq process harness-voice-live--process)
                  (string-match "\n" tail start))
        (let ((line (substring tail start (match-beginning 0))))
          (setq start (match-end 0))
          (unless (string-blank-p line)
            (condition-case _err
                (let ((event (json-parse-string line :object-type 'plist
                                                :null-object nil :false-object nil)))
                  (when (listp event)
                    (harness-voice-live--handle event)))
              (error
               (harness-voice-live--fail "Live voice protocol error"))))))
      (when (eq process harness-voice-live--process)
        (setq harness-voice-live--tail (substring tail start))))))

(defun harness-voice-live--start-timer (seconds function)
  "Run FUNCTION once after SECONDS, replacing the current timer."
  (when (timerp harness-voice-live--timer)
    (cancel-timer harness-voice-live--timer))
  (setq harness-voice-live--timer (run-at-time seconds nil function)))

;;;; Live transcript

(defvar harness-voice-live--transcript-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "C-c v") #'harness-voice-dictate)
    (define-key map (kbd "C-c V") #'harness-voice-interrupt)
    (define-key map (kbd "d") #'harness-voice-live-pipeline-details)
    map)
  "Key map of the live voice transcript.")

(define-derived-mode harness-voice-live-transcript-mode special-mode "Voice transcript"
  "Mode of the live voice transcript.
The stage line at the top says what the session is doing now, and the
pipeline under it says what reached the microphone, what the speech
filter kept and dropped, what was transcribed, and what the speaker is
doing.  The sections below say what you said, what crossed into the
session (`Sent`, or `Not sent` when no words came back), what the coding
agent did and what the voice said back.  `d' shows every pipeline marker,
`C-c v' dictates or mutes, `C-c V' interrupts and `q' closes the
buffer."
  (setq-local mode-line-format '(" Voice transcript")))

(defun harness-voice-live--transcript-buffer ()
  "Return the live transcript buffer, making it when needed."
  (unless (buffer-live-p harness-voice-live--transcript)
    (let ((buffer (get-buffer-create "*harness voice*")))
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (erase-buffer)
          (harness-voice-live-transcript-mode)
          (setq-local header-line-format
                      '(:eval (concat " " (or (harness-voice-live--stage-text) "○ Off")
                                      "   Voice · "
                                      (if (fboundp 'harness-voice-provider-label)
                                          (harness-voice-provider-label harness-voice-provider)
                                        "live")))))
        (setq buffer-read-only t))
      (setq harness-voice-live--section nil
            harness-voice-live--transcript buffer)
      (harness-voice-live--pipeline-draw))
    (harness-voice-live--stage-redraw))
  harness-voice-live--transcript)

(defun harness-voice-live--stage-redraw ()
  "Redraw the transcript's stage line, when the buffer shows one."
  (when (buffer-live-p harness-voice-live--transcript)
    (with-current-buffer harness-voice-live--transcript
      (force-mode-line-update t))))

(defun harness-voice-live--transcript-insert (text &optional face)
  "Insert TEXT at the end of the live transcript, in FACE."
  (when (and (stringp text) (not (string-empty-p text)))
    (let ((buffer (harness-voice-live--transcript-buffer)))
      (with-current-buffer buffer
        (let ((inhibit-read-only t)
              (start (point-max)))
          (goto-char (point-max))
          (insert (if face (propertize text 'face face) text))
          (goto-char (point-max))
          (dolist (window (get-buffer-window-list buffer t))
            (set-window-point window (point-max)))
          start)))))

(defun harness-voice-live--transcript-section (section title)
  "Begin SECTION of the transcript, headed TITLE, when it is a new one.
Return non-nil when a heading was written."
  (prog1 (not (eq section harness-voice-live--section))
    (unless (eq section harness-voice-live--section)
      (let ((buffer (harness-voice-live--transcript-buffer)))
        (with-current-buffer buffer
          (let ((inhibit-read-only t))
            (goto-char (point-max))
            (unless (bolp) (insert "\n"))
            (insert "\n"
                    (propertize title
                                'face (pcase section
                                        ('user 'harness-user-label-face)
                                        ('work 'harness-label-face)
                                        ('sent 'harness-label-face)
                                        ('not-sent 'harness-caution-face)
                                        (_ 'harness-agent-label-face)))
                    (propertize (format " · %s" (format-time-string "%H:%M"))
                                'face 'harness-dim-face)
                    "\n")
            (dolist (window (get-buffer-window-list buffer t))
              (set-window-point window (point-max)))))))
    (setq harness-voice-live--section section)))

(defun harness-voice-live--transcript-text (section title text &optional face)
  "Write TEXT into SECTION, headed TITLE, in FACE."
  (harness-voice-live--transcript-section section title)
  (let ((buffer (harness-voice-live--transcript-buffer))
        (start nil))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (when (bolp) (insert "  "))
        (setq start (point))
        (insert (if face (propertize text 'face face) text))))
    start))

(defun harness-voice-live--caption (speaker text &optional final certain)
  "Show SPEAKER's TEXT, ending the caption line with FINAL.
CERTAIN, when given, is a word the provider added to what it heard --
`likely' for a reading it is less sure of -- and the heading says it, so
a hedged reading is never drawn as certain speech."
  (unless (string-empty-p text)
    (unless (equal harness-voice-live--speaker speaker)
      (when harness-voice-live--speaker
        (harness-voice-live--transcript-insert "\n"))
      (setq harness-voice-live--speaker speaker))
    (if (equal speaker "You")
        (harness-voice-live--transcript-text
         'user (if certain (format "You · %s" certain) "You") text)
      (harness-voice-live--transcript-text 'agent "Voice" text 'harness-agent-face)))
  (when final
    (when harness-voice-live--speaker
      (harness-voice-live--transcript-insert "\n"))
    (setq harness-voice-live--speaker nil
          harness-voice-live--section nil)))

(defun harness-voice-live--uncertain-caption (text &optional final)
  "Show TEXT, a reading the provider is not sure of, as uncertain words.
The words stay visible and are marked; they never enter the voice
conversation as something the person said, and no request is made from
them.  FINAL ends the caption line, as for any caption."
  (harness-voice-live--transcript-section 'uncertain "Uncertain")
  (harness-voice-live--transcript-insert
   (concat "  " text " · not sent" (if final "\n" ""))
   'harness-caution-face)
  (when final
    (setq harness-voice-live--section nil)))

(defun harness-voice-live--backchannel (text)
  "Show a backchannel TEXT in the transcript."
  (harness-voice-live--transcript-section 'agent "Voice")
  (harness-voice-live--transcript-insert
   (concat "  " (if (string-empty-p text) "mm-hmm" text) "\n")
   'harness-thinking-face))

(defun harness-voice-live--show-notice (message)
  "Show MESSAGE, a problem the sidecar survived, without ending the call.
It is kept for the controls, and written into the transcript under a
`Live' heading so the reply that went unspoken is visible where it
happened.  The transcript is made if it was not open yet: a notice is
part of the call's record."
  (let ((text (harness-ui-one-line message)))
    (setq harness-voice-live--notice (concat "Live voice · " text))
    (let ((buffer (harness-voice-live--transcript-buffer)))
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (unless (bolp) (insert "\n"))
          (insert "\n"
                  (propertize "Live" 'face 'harness-caution-face)
                  "\n"
                  (propertize (concat "  " text "\n")
                              'face 'harness-caution-face))
          (dolist (window (get-buffer-window-list buffer t))
            (set-window-point window (point-max))))))
    (setq harness-voice-live--section nil)
    (harness-voice-live--refresh)))

(defun harness-voice-live--transcript-tool (title)
  "Show a coding-agent tool call TITLE in the transcript.
A long subject is clipped: the point is what kind of work is happening,
not the whole path."
  (when (> (length title) 72)
    (setq title (concat (substring title 0 71) "…")))
  (harness-voice-live--transcript-section 'work "Coding agent")
  (harness-voice-live--transcript-insert
   (concat "  ▸ " title "\n")
   'harness-tool-title-face))

(defun harness-voice-live--transcript-sent (text &optional caption)
  "Show what crossed into the target: TEXT, or that nothing did.
TEXT is what the target received.  When it is the words the caption above
already shows, CAPTION, nothing is written: repeating the same sentence
under a second heading is not a record of a crossing.  A text that differs
is written under `Sent', so a rewrite -- from a provider of the future, or
from this client -- is visible as one."
  (cond
   ((null text)
    (harness-voice-live--transcript-section 'not-sent "Not sent")
    (harness-voice-live--transcript-insert
     "  no words\n" 'harness-dim-face))
   ((and caption (equal (string-trim caption) (string-trim text)))
    nil)
   (t
    (harness-voice-live--transcript-section 'sent "Sent")
    (harness-voice-live--transcript-insert
     (concat "  " text "\n") 'harness-dim-face))))

;;;###autoload
(defun harness-voice-live-transcript ()
  "Show the live transcript."
  (interactive)
  (unless (buffer-live-p harness-voice-live--transcript)
    (user-error "Live transcript unavailable"))
  (pop-to-buffer harness-voice-live--transcript)
  (harness-voice-live--pipeline-draw)
  (goto-char (point-max)))

;;;; Speaking the agent's reply

(defun harness-voice-live--speakable-p (text)
  "Non-nil when TEXT holds something a voice can say.
A piece of nothing but markup, emoji or punctuation -- the \"🙂\" that
follows a sentence, a dash, a stray backtick -- is left unsent: a speech
server answers it with an empty body, which used to fail the whole call
for a reply that was merely done being said."
  (and (stringp text) (string-match-p "[[:alnum:]]" text)))

(defun harness-voice-live--turn-stale-p ()
  "Non-nil when the running turn was sent to a route that moved.
Its reply belongs to the thread it was asked in: it is neither spoken
into the thread the person selected nor shown as if it answered it."
  (let ((route (plist-get harness-voice-live--delegation :route)))
    (and route
         (not (harness-voice-live--route-current-p (plist-get route :generation))))))

(defun harness-voice-live--speak (text &optional id)
  "Send speakable TEXT to the sidecar as commentary, or hold it.

ID names the piece so a held one is not reported twice.  While speech is
active, or until a transcript has decided what the held reply means, the
text stays on this side of the pipe: the sidecar never gets a stale
commentary to speak later.  A piece with nothing to say in it is not
sent at all."
  (let ((speech (harness-voice--speech-text text))
        (part 0))
    (while (and (not (string-empty-p speech))
                (not harness-voice-live--output-suppressed)
                (not (harness-voice-live--turn-stale-p))
                (harness-voice-live--active-p))
      (let* ((piece (if (> (length speech) 1200)
                        (substring speech 0 1200)
                      speech))
             (piece-id (and id (format "%s:%d" id part))))
        (setq part (1+ part))
        (when (harness-voice-live--speakable-p piece)
          (if (harness-voice-live--holding-output-p)
              (harness-voice-live--hold piece-id piece)
            (harness-voice-live--pipeline-reply-handed piece-id)
            (harness-voice-live--send
             (list :event "commentary" :id piece-id :text piece))
            (harness-voice-conversation-say
             harness-voice-live--conversation piece 'commentary)))
        (setq speech (if (> (length speech) 1200) (substring speech 1200) ""))))))

(defun harness-voice-live--open-fence (text)
  "Return the position of an unclosed code fence in TEXT, or nil."
  (let ((position 0) (open nil))
    (while (string-match "```\\|~~~" text position)
      (setq position (match-end 0)
            open (if open nil (match-beginning 0))))
    open))

(defun harness-voice-live--drain-node (id final)
  "Send new sentences of node ID, flushing the rest with FINAL."
  (let* ((entry (gethash id harness-voice-live--nodes))
         (text (or (plist-get entry :text) ""))
         (offset (or (plist-get entry :sent) 0))
         (fence (harness-voice-live--open-fence text))
         (limit (or fence (length text)))
         (scan offset)
         end)
    (while (and (< scan limit)
                (setq end (and (string-match "[.!?][ \t\n]+\\|\n\n" text scan)
                               (match-end 0)))
                (<= end limit))
      (harness-voice-live--speak (substring text scan end)
                                 (format "%s:%d" id scan))
      (setq scan end))
    (when final
      (when (> (length text) scan)
        (harness-voice-live--speak (substring text scan)
                                   (format "%s:%d" id scan)))
      (setq scan (length text)))
    (puthash id (plist-put entry :sent scan) harness-voice-live--nodes)))

(defun harness-voice-live--add-chunk (id text)
  "Add streamed TEXT to node ID and speak its new sentences."
  (let ((entry (gethash id harness-voice-live--nodes)))
    (unless entry
      (push id harness-voice-live--order)
      (setq entry (list :text "" :sent 0)))
    ;; A live node announcement can already hold the first delta.  The
    ;; chunks accumulate instead, so never count the announcement twice.
    (unless (plist-get entry :chunked)
      (setq entry (list :text "" :sent 0)))
    (puthash id (plist-put (plist-put entry :text (concat (plist-get entry :text) text))
                           :chunked t)
             harness-voice-live--nodes)
    (harness-voice-live--pipeline-reply-ready id text))
  (harness-voice-live--drain-node id nil))

(defun harness-voice-live--add-node (id text)
  "Remember TEXT of an announced node ID that streamed no chunks."
  (let ((entry (gethash id harness-voice-live--nodes)))
    (cond
     ((and entry (plist-get entry :chunked)) nil)
     (t
      (unless entry (push id harness-voice-live--order))
      (puthash id (list :text (or text "") :sent 0 :announced t)
               harness-voice-live--nodes)
      (harness-voice-live--pipeline-reply-ready id text)))))

(defun harness-voice-live--reply-text ()
  "Return this turn's assistant text in arrival order."
  (mapconcat (lambda (id) (or (plist-get (gethash id harness-voice-live--nodes) :text) ""))
             (reverse harness-voice-live--order) ""))

;;;; Pending conversational input

(defun harness-voice-live--input-source (event)
  "Return EVENT's source segment id, when one is known."
  (cond ((equal (plist-get event :event) "segment") (plist-get event :id))
        ((plist-get event :utterance) (format "u-%s" (plist-get event :utterance)))
        (t (or harness-voice-live--utterance-done harness-voice-live--utterance))))

(defun harness-voice-live--input-record (source)
  "Return SOURCE's input record, capturing its onset order and route."
  (or (cdr (assoc source harness-voice-live--input-chunks))
      (let* ((utterance (and (string-prefix-p "u-" source) (substring source 2)))
             (record (list :segment source :order (cl-incf harness-voice-live--input-seq)
                           :route (harness-voice-live--utterance-route utterance)
                           :state 'speech :open nil :await-delegate nil :truncated nil
                           :playback-overlap (or harness-voice-live--input-overlap
                                                 (eq harness-voice-live--state 'speaking))
                           :caption-text "" :accounted nil)))
        (push (cons source record) harness-voice-live--input-chunks)
        record)))

(defun harness-voice-live--input-busy-p ()
  "Whether speech or accepted input still awaits resolution."
  (or harness-voice-live--speech-active harness-voice-live--input-anonymous
      (cl-some (lambda (entry)
                 (and (plist-get (cdr entry) :open)
                      (harness-voice-live--route-current-p
                       (plist-get (plist-get (cdr entry) :route) :generation))))
               harness-voice-live--input-chunks)))

(defun harness-voice-live--pending-cancel-timer ()
  "Invalidate the pending turn's deadline, including callbacks already queued."
  (cl-incf harness-voice-live--pending-token)
  (when (timerp harness-voice-live--pending-timer)
    (cancel-timer harness-voice-live--pending-timer))
  (setq harness-voice-live--pending-timer nil))

(defun harness-voice-live--turn-hold (held)
  "Ask the provider to keep output HELD, without muting capture."
  (unless (eq (and held t) harness-voice-live--turn-held)
    (setq harness-voice-live--turn-held (and held t))
    (harness-voice-live--send (list :event "turn_hold" :active (if held t :false)))))

(defun harness-voice-live--pending-add (item)
  "Add ITEM once, retaining source onset order rather than completion order."
  (let* ((items (plist-get harness-voice-live--pending :items))
         (old (cl-find (plist-get item :segment) items
                       :key (lambda (old) (plist-get old :segment)) :test #'equal)))
    (when (or (not old)
              (and (plist-get old :failed) (not (plist-get item :failed)))
              (and (not (plist-get old :id)) (plist-get item :id)))
      (setf (plist-get harness-voice-live--pending :items)
            (sort (cons item (remq old items))
                  (lambda (a b) (< (plist-get a :order) (plist-get b :order)))))
      ;; Controls are an ordered property, not an arrival-time decision:
      ;; a cue can finish transcribing before the earlier words it controls.
      ;; Only standalone controls following content are omitted.  Never strip
      ;; a content-bearing ending such as "Fix the test, hold on."
      (let ((words nil))
        (setf (plist-get harness-voice-live--pending :items)
              (mapcar (lambda (part)
                        (let* ((raw (plist-get part :raw-text))
                               (recovery (and words (plist-get part :cue)))
                               (pause (and words (plist-get part :pause))))
                          (setq part (plist-put part :text (unless (or recovery pause) raw))
                                part (plist-put part :recovery recovery)
                                part (plist-put part :continuation pause))
                          (when raw (setq words t))
                          part))
                      (plist-get harness-voice-live--pending :items))))
      (setf (plist-get harness-voice-live--pending :recovery)
            (plist-get (car (last (plist-get harness-voice-live--pending :items))) :recovery)))))

(defun harness-voice-live--pending-text ()
  "Return unsent words in their original order, joined by a single space."
  (string-join (delq nil (mapcar (lambda (item) (plist-get item :text))
                                 (plist-get harness-voice-live--pending :items))) " "))

(defun harness-voice-live--pending-reason ()
  "Return the current draft's ending classification."
  (let* ((items (plist-get harness-voice-live--pending :items))
         (last (car (last (cl-remove-if (lambda (item) (plist-get item :recovery)) items)))))
    (cond
     ((cl-some (lambda (item) (plist-get item :failed)) items) 'cut-off)
     ((plist-get last :continuation) 'continuation)
     ((and harness-voice-live--caption-hold
           (> harness-voice-live--caption-hold-order (or (plist-get last :order) 0)))
      harness-voice-live--caption-hold)
     (t (harness-voice-turn-reason (harness-voice-live--pending-text)
                                   (plist-get last :truncated))))))

(defun harness-voice-live--pending-stage ()
  "Return the stage naming the unsent draft's reason."
  (pcase (harness-voice-live--pending-reason)
    ('continuation 'continuation)
    ('cut-off 'cut-off)
    (_ 'finishing)))

(defun harness-voice-live--pending-expired (token generation)
  "Commit only the draft whose TOKEN and route GENERATION own this deadline."
  (when (and (= token harness-voice-live--pending-token)
             (harness-voice-live--route-current-p generation))
    (setq harness-voice-live--pending-timer nil)
    (when (and harness-voice-live--pending
               (eq (harness-voice-live--pending-reason) 'grace))
      (harness-voice-live--pending-commit))))

(defun harness-voice-live--pending-update ()
  "Keep output held and arm ordinary grace only after all input resolves."
  (when (and harness-voice-live--pending harness-voice-live--caption-recovery
             (> (plist-get harness-voice-live--caption-recovery :order)
                (or (plist-get (car (last (plist-get harness-voice-live--pending :items))) :order) 0)))
    (harness-voice-live--pending-add harness-voice-live--caption-recovery)
    (setq harness-voice-live--caption-recovery nil))
  (when (and harness-voice-live--pending
             (> (length (harness-voice-live--pending-text)) harness-voice-live-pending-limit))
    (harness-voice-live--transcript-text
     'unsent "Unsent speech" (concat (harness-voice-live--pending-text) "\n"))
    (harness-voice-live--fail "Unsent speech limit"))
  (when harness-voice-live--pending
    (harness-voice-live--cancel-held-timer)
    (harness-voice-live--turn-hold t)
    (cond
     ((harness-voice-live--input-busy-p) (harness-voice-live--pending-cancel-timer))
     ((plist-get harness-voice-live--pending :recovery)
      (harness-voice-live--pending-commit))
     ((and (eq (harness-voice-live--pending-reason) 'grace)
           (not harness-voice-live--pending-timer))
      (let ((token harness-voice-live--pending-token))
        (setq harness-voice-live--pending-timer
              (run-at-time harness-voice-live-turn-grace nil
                           #'harness-voice-live--pending-expired token
                           harness-voice-live--route-generation)))))
    (when harness-voice-live--pending
      (unless (harness-voice-live--input-busy-p)
        (harness-voice-live--stage-set (harness-voice-live--pending-stage)))
      (harness-voice-live--pipeline-touch t)
      (harness-voice-live--refresh))))

(defun harness-voice-live--input-event (event)
  "Track capture and unresolved chunks in EVENT independently of playback.
A transcribed segment still waits for its delegation.  Listening is not
transcription completion, and the bounded pipeline is not an activity store."
  (let ((kind (plist-get event :event)))
    (when (and (member kind '("speech" "hearing" "transcribing" "user_delta" "segment"))
               (not harness-voice-live--muted)
               (not (memq harness-voice-live--state '(ending failed))))
      (when (or (equal kind "hearing")
                (and (equal kind "speech") (eq (plist-get event :active) t)))
        (harness-voice-live--follow-selection)
        (when (eq harness-voice-live--state 'speaking)
          (setq harness-voice-live--input-overlap t)))
      (let* ((source (if (equal kind "segment") (plist-get event :id)
                       (and (plist-get event :utterance)
                            (format "u-%s" (plist-get event :utterance)))))
             (record (and source (harness-voice-live--input-record source)))
             (state (and (equal kind "segment") (plist-get event :state))))
        (when (and record (eq (plist-get event :truncated) t))
          (setf (plist-get record :truncated) t)
          (when-let* ((item (cl-find source (plist-get harness-voice-live--pending :items)
                                     :key (lambda (item) (plist-get item :segment)) :test #'equal)))
            (setf (plist-get item :truncated) t)
            (harness-voice-live--pending-cancel-timer)))
        (unless (memq (plist-get record :state) '(resolved cancelled dropped failed))
          (cond
           ((and (equal kind "segment") (member state '("dropped" "failed")))
            (setf (plist-get record :open) nil
                  (plist-get record :state) (intern state))
            (when (and (equal state "failed") harness-voice-live--pending)
              (harness-voice-live--pending-cancel-timer)
              (harness-voice-live--pending-add
               (list :segment source :order (plist-get record :order) :failed t))))
           ((or (member kind '("transcribing" "user_delta"))
                (and (equal kind "segment")
                     (member state '("accepted" "transcribing" "transcribed"))))
            (harness-voice-live--pending-cancel-timer)
            (harness-voice-live--cancel-held-timer)
            (if record
                (progn
                  (when (or (equal kind "transcribing") (equal kind "segment"))
                    (setf (plist-get record :await-delegate) t))
                  (setf (plist-get record :open)
                        (or (plist-get record :await-delegate)
                            (not (and (equal kind "user_delta") (plist-get event :final))))
                        (plist-get record :state)
                        (if (plist-get record :open) 'transcribing 'caption-final)))
              (setq harness-voice-live--input-anonymous
                    (cond ((equal kind "transcribing") 'transcribing)
                          ((eq harness-voice-live--input-anonymous 'transcribing) 'transcribing)
                          ((plist-get event :final) nil)
                          (t 'caption)))))
           ((equal kind "hearing")
            (harness-voice-live--pending-cancel-timer)
            (if record (setf (plist-get record :open) t)
              (setq harness-voice-live--input-anonymous 'hearing)))
           ((and (equal kind "speech") (plist-get event :active))
            (harness-voice-live--pending-cancel-timer))))))
    (when (equal kind "listening")
      (when (eq harness-voice-live--input-anonymous 'hearing)
        (setq harness-voice-live--input-anonymous nil))
      (when-let* ((source (and (plist-get event :utterance)
                               (format "u-%s" (plist-get event :utterance))))
                  (record (cdr (assoc source harness-voice-live--input-chunks))))
        (when (eq (plist-get record :state) 'speech)
          (setf (plist-get record :open) nil))))))

(defun harness-voice-live--caption-hold-update (text final truncated source)
  "Hold autonomous output for SOURCE's caption, never inventing a request.
Finals are classified in onset order, not transcription completion order."
  (let* ((record (and source (harness-voice-live--input-record source)))
         (previous (if record (plist-get record :caption-text) harness-voice-live--caption-text))
         (caption (if (and final (string-prefix-p previous text)) text (concat previous text))))
    (if record (setf (plist-get record :caption-text) (if final "" caption))
      (setq harness-voice-live--caption-text (if final "" caption)))
    (when (and final (>= (or (plist-get record :order) harness-voice-live--input-seq)
                          harness-voice-live--caption-hold-order))
      (let ((reason (harness-voice-turn-reason caption truncated)))
        (setq harness-voice-live--caption-hold-order
              (or (plist-get record :order) harness-voice-live--input-seq)
              harness-voice-live--caption-hold
              (pcase reason ('continuation 'continuation) ('cut-off 'cut-off))
              harness-voice-live--caption-recovery
              (and (harness-voice-turn-recovery-p caption)
                   (list :segment source :order harness-voice-live--caption-hold-order
                         :raw-text caption :cue t)))
        (harness-voice-live--cancel-held-timer)
        (harness-voice-live--turn-hold
         (or harness-voice-live--pending harness-voice-live--caption-hold
             (harness-voice-live--input-busy-p)))
        (cond (harness-voice-live--caption-hold
               (harness-voice-live--stage-set harness-voice-live--caption-hold))
              ((not harness-voice-live--pending)
               (harness-voice-live--settle-stage)))))))

(defun harness-voice-live--reset-submissions (reason)
  "Invalidate asynchronous input arbitration, acknowledging jobs with REASON."
  (let ((jobs harness-voice-live--submissions))
    (setq harness-voice-live--submissions nil
          harness-voice-live--input-overlap nil)
    (dolist (job jobs)
      (harness-voice-live--delegate-result job "" reason)))
  (run-hooks 'harness-voice-live-reset-functions))

(defun harness-voice-live--pending-cancel (reason)
  "Discard the unsent turn and unresolved input with cancellation REASON."
  (harness-voice-live--reset-submissions reason)
  (harness-voice-live--pending-cancel-timer)
  (let ((pending harness-voice-live--pending))
    (setq harness-voice-live--pending nil
          harness-voice-live--input-anonymous nil
          harness-voice-live--speech-active nil
          harness-voice-live--utterance nil
          harness-voice-live--utterance-done nil
          harness-voice-live--caption-hold nil
          harness-voice-live--caption-hold-order 0
          harness-voice-live--caption-recovery nil
          harness-voice-live--caption-text ""
          harness-voice-live--heard "")
    (dolist (item (plist-get pending :items))
      (when (plist-get item :id)
        (harness-voice-live--send
         (list :event "delegate_result" :id (plist-get item :id) :text ""
               :error t :message reason))))
    (dolist (entry harness-voice-live--input-chunks)
      (let ((record (cdr entry)))
        (unless (memq (plist-get record :state) '(cancelled dropped))
          (when (or (not (eq (plist-get record :state) 'resolved))
                    (cl-find (car entry) (plist-get pending :items)
                             :key (lambda (item) (plist-get item :segment)) :test #'equal))
            (harness-voice-pipeline-segment
             harness-voice-live--pipeline (car entry) 'dropped
             (list :reason (harness-voice-live--pipeline-reason reason)))
            (setf (plist-get record :state) 'cancelled
                  (plist-get record :open) nil)))))
    (harness-voice-live--cancel-held-timer)
    (setq harness-voice-live--held nil)
    (harness-voice-live--turn-hold nil)))

(defun harness-voice-live--pending-commit ()
  "Submit the whole draft exactly once, never over unresolved input."
  (let ((pending harness-voice-live--pending))
    (when pending
      (harness-voice-live--follow-selection)
      (when (and (eq pending harness-voice-live--pending)
                 (harness-voice-live--active-p)
                 (not harness-voice-live--muted)
                 (not (memq harness-voice-live--state '(ending failed)))
                 (not (harness-voice-live--input-busy-p))
                 (harness-voice-live--route-current-p
                  (plist-get (plist-get pending :route) :generation)))
        (let* ((items (plist-get pending :items))
               (text (harness-voice-live--pending-text))
               (ids (delq nil (mapcar (lambda (item) (plist-get item :id)) items)))
               (job (list :id (car ids) :ids ids :text text :route (plist-get pending :route)
                          :caption (and (= (length items) 1) (plist-get (car items) :caption))
                          :items (mapcar (lambda (item)
                                           (list :segment (plist-get item :segment)
                                                 :order (plist-get item :order)
                                                 :text (plist-get item :raw-text)
                                                 :caption (plist-get item :caption)
                                                 :truncated (plist-get item :truncated)))
                                         items)
                          :playback-overlap
                          (cl-some (lambda (item)
                                     (plist-get (cdr (assoc (plist-get item :segment)
                                                           harness-voice-live--input-chunks))
                                                :playback-overlap))
                                   items)
                          :segments (mapcar (lambda (item) (plist-get item :segment)) items))))
          (harness-voice-live--pending-cancel-timer)
          (dolist (item items)
            (when-let* ((record (cdr (assoc (plist-get item :segment)
                                            harness-voice-live--input-chunks))))
              (setf (plist-get record :accounted) t
                    (plist-get record :state) 'resolved)))
          (setq harness-voice-live--pending nil
                harness-voice-live--caption-hold nil
                harness-voice-live--caption-recovery nil
                harness-voice-live--held nil)
          (harness-voice-live--turn-hold nil)
          (setq harness-voice-live--input-overlap nil)
          (harness-voice-live--submit job))))))

(defun harness-voice-live--submit (job)
  "Arbitrate JOB before queueing, with once-only lifecycle-guarded callbacks."
  (push job harness-voice-live--submissions)
  (let* ((route (plist-get job :route))
         (claim (lambda ()
                  (when (memq job harness-voice-live--submissions)
                    (setq harness-voice-live--submissions
                          (delq job harness-voice-live--submissions))
                    (and (harness-voice-live--active-p)
                         (not harness-voice-live--muted)
                         (not (memq harness-voice-live--state '(ending failed)))
                         (harness-voice-live--route-current-p (plist-get route :generation))))))
         (continue
          (lambda ()
            (when (funcall claim)
              ;; The thought the recovery put together has crossed: the record
              ;; has nothing left to take back.
              (when (eq (harness-voice-recovery-state harness-voice-live--recovery) 'done)
                (harness-voice-live--recovery-cancel))
              (let ((text (plist-get job :text)))
                (harness-voice-live--transcript-sent text (plist-get job :caption))
                (harness-voice-conversation-hear harness-voice-live--conversation text text))
              (setq harness-voice-live--delegations
                    (nconc harness-voice-live--delegations (list job)))
              ;; Armed where the words actually cross, so the window is
              ;; measured from the submission an input owner let through.
              (harness-voice-live--recovery-arm job)
              (when harness-voice-live--delegation
                (harness-voice-live--pipeline-turn-queued (plist-get job :id)
                                                        (plist-get job :segments)))
              (harness-voice-live--delegate-next))))
         (complete
          (lambda ()
            (when (funcall claim)
              (harness-voice-live--delegate-result job "")
              (dolist (segment (plist-get job :segments))
                (harness-voice-pipeline-segment harness-voice-live--pipeline segment 'answered))
              (harness-voice-live--settle-stage)
              (harness-voice-live--pipeline-touch t)
              (harness-voice-live--refresh)))))
    (unless (run-hook-with-args-until-success
             'harness-voice-live-submit-functions job continue complete)
      (funcall continue))))

;;;###autoload
(defun harness-voice-live-send-now ()
  "Submit pending speech, only when no speech or transcription is active.
An ineligible action is a no-op, not a deferred override."
  (interactive)
  (harness-voice-live--pending-commit))

;;;; Taking back a premature voice turn

;; The speech endpoint is not the person's.  A transcript that arrives
;; after a short silence is submitted at once, and the agent answers it;
;; when the person was only pausing, that answer answers half a thought.
;; The recovery is armed with every voice submission and disarmed when
;; its window closes, the call ends or the target moves.  When resumed
;; speech begins inside the window, the first words it produces -- not
;; the onset, not a complete sentence -- take the turn back: playback
;; stops, the turn is cancelled, the history is rewound to before the
;; voice message when that is provably safe, and the original words go
;; back in the draft.  The continuations join them there, and the
;; ordinary turn-completion grace submits the whole thought once, when
;; the person finally stops talking.  The timing and the safety rules
;; are in `harness-ui-voice-recovery'.

(defun harness-voice-live--recovery-arm (job)
  "Arm a recovery for JOB, the voice turn just submitted.
Nothing is armed when the feature is off: a voice message submitted with
no window is answered as it always was.  The record keeps the route the
words were spoken under, so a target that moved abandons the recovery
rather than rewinding another thread."
  (harness-voice-live--recovery-cancel)
  (setq harness-voice-live--recovery
        (and harness-voice-live-recovery-window
             (harness-voice-recovery-arm
              (list :id (cl-incf harness-voice-live--recovery-seq)
                    :session (plist-get (plist-get job :route) :session)
                    :generation (plist-get (plist-get job :route) :generation)
                    :route (plist-get job :route)
                    :turn (plist-get job :id)
                    :text (plist-get job :text)
                    :items (plist-get job :items)
                    :segments (plist-get job :segments)
                    :submitted (float-time))))))

(defun harness-voice-live--recovery-cancel-timer ()
  "Invalidate the cancel-wait deadline, including callbacks already queued."
  (cl-incf harness-voice-live--recovery-token)
  (when (timerp harness-voice-live--recovery-timer)
    (cancel-timer harness-voice-live--recovery-timer))
  (setq harness-voice-live--recovery-timer nil))

(defun harness-voice-live--recovery-cancel ()
  "Forget the recovery, whatever it was doing."
  (harness-voice-live--recovery-cancel-timer)
  (setq harness-voice-live--recovery nil))

(defun harness-voice-live--recovery-drop (why)
  "Abandon the recovery for WHY, keeping what it saw as evidence.
The turn it was about stays exactly as it is."
  (when harness-voice-live--recovery
    (setq harness-voice-live--recovery
          (harness-voice-recovery-abandon harness-voice-live--recovery why))
    ;; The record's own words for it, so the section does not say the same
    ;; thing twice in two ways.
    (harness-voice-live--recovery-say
     (car (last (harness-voice-recovery-evidence harness-voice-live--recovery))))
    (harness-voice-live--recovery-cancel-timer)))

(defun harness-voice-live--recovery-note (text)
  "Keep TEXT as evidence of the recovery, when one is armed."
  (when harness-voice-live--recovery
    (setq harness-voice-live--recovery
          (harness-voice-recovery-note harness-voice-live--recovery text))))

(defun harness-voice-live--recovery-evidence (text)
  "Keep TEXT as evidence and write it into the transcript's Recovery section.
The section is the audit record of a recovery: what was heard, when,
which measure timed it, and what the history allowed.  Nothing is
rewritten and nothing is removed: the nodes a rewind left behind stay in
the session's tree."
  (harness-voice-live--recovery-note text)
  (harness-voice-live--recovery-say text))

(defun harness-voice-live--recovery-say (text)
  "Write TEXT into the transcript's Recovery section, as it stands."
  (when (and (stringp text) (not (string-empty-p text)))
    (harness-voice-live--transcript-text 'recovery "Recovery" (concat text "\n")
                                         'harness-caution-face)))

(defun harness-voice-live--recovery-same-p (record)
  "Non-nil when RECORD is the recovery still armed.
A record is a value that an evidence note replaces with a copy, so it is
named by its id, never by identity."
  (and record harness-voice-live--recovery
       (eql (plist-get record :id) (plist-get harness-voice-live--recovery :id))))

(defun harness-voice-live--recovery-here-p ()
  "Non-nil when the armed recovery still belongs to this call and target."
  (and harness-voice-live--recovery
       (harness-voice-live--active-p)
       (not harness-voice-live--muted)
       (not (memq harness-voice-live--state '(ending failed)))
       (harness-voice-live--route-current-p
        (plist-get harness-voice-live--recovery :generation))))

(defun harness-voice-live--recovery-onset (event)
  "Note that speech resumed in EVENT, which may take back the voice turn.
The sidecar reports the onset as it hears it, before any word exists;
that is what the window is measured from.  The submitted message's own
capture is not resumed speech, and neither is a speech event for it."
  (when (and harness-voice-live--recovery
             (harness-voice-live--recovery-here-p)
             (equal (plist-get event :event) "speech")
             (plist-get event :active)
             (not (equal (plist-get event :reason) "muted")))
    (setq harness-voice-live--recovery
          (harness-voice-recovery-onset
           harness-voice-live--recovery
           (and (plist-get event :utterance)
                (format "u-%s" (plist-get event :utterance)))
           (float-time)))))

(defun harness-voice-live--recovery-words (text source &optional certainty)
  "Take the voice turn back for TEXT, the first words of resumed speech.
SOURCE is the capture the words came from and CERTAINTY the provider's
own word about its reading.  Nothing is cancelled for an empty or
wordless transcription, an unsure reading, the message's own capture, or
words whose speech began outside the window: those are a new thought or
no thought at all.  The decision is made here, in the event that
carried the words, with no wait of any kind."
  (let ((decision (and harness-voice-live--recovery
                       (harness-voice-live--recovery-here-p)
                       (harness-voice-recovery-trigger
                        harness-voice-live--recovery text
                        (list :source source :certainty certainty
                              :now (float-time)
                              :window harness-voice-live-recovery-window)))))
    (pcase (car-safe decision)
      ('trigger
       (setq harness-voice-live--recovery (cdr decision))
       (harness-voice-live--recovery-start source text))
      ('ignore
       (when (memq (cdr decision) '(outside-window finished))
         (harness-voice-live--recovery-cancel))
       nil))))

(defun harness-voice-live--recovery-revise ()
  "Put a revised continuation back in the draft the recovery made.
A transcript that arrives again with other words is the same utterance
corrected; the draft it already built is rebuilt, so the thought says
the words once, as they finally were."
  (when (and (eq (harness-voice-recovery-state harness-voice-live--recovery) 'done)
             (plist-get harness-voice-live--recovery :plan)
             harness-voice-live--pending)
    (harness-voice-live--recovery-finish
     (plist-get harness-voice-live--recovery :plan))))

(defun harness-voice-live--recovery-caption (text source &optional final certainty)
  "Keep TEXT, SOURCE's caption, as part of the thought being recovered.
Return non-nil when the caption belongs to a recovery already under way:
its words join the thought, and the caption is not new input for the
pending turn.  A caption of a capture the recovery does not hold is
ordinary speech, and the caller decides what it is."
  (when (and (memq (harness-voice-recovery-state harness-voice-live--recovery)
                   '(recovering done))
             (harness-voice-recovery-continuation-source-p
              harness-voice-live--recovery source))
    (unless (equal certainty "unsure")
      (setq harness-voice-live--recovery
            (harness-voice-recovery-caption
             harness-voice-live--recovery source text final))
      (harness-voice-live--recovery-revise))
    t))

(defun harness-voice-live--recovery-absorb (event)
  "Non-nil when delegation EVENT is words of the thought being taken back.
Resumed speech is transcribed and delegated like any other; while a
recovery holds that capture, its transcript is part of the thought, not
a turn of its own, and nothing is sent to the agent for it."
  (and (memq (harness-voice-recovery-state harness-voice-live--recovery)
             '(recovering done))
       (harness-voice-recovery-continuation-source-p
        harness-voice-live--recovery (harness-voice-live--input-source event))))

(defun harness-voice-live--recovery-absorbed (event)
  "Keep delegation EVENT's words as the continuation they are, and drop the turn.
The sidecar asked for a turn it will not get: it is answered with a
cancellation, so it stops waiting, and the words are already in the
draft."
  (let* ((text (or (plist-get event :text) ""))
         (source (harness-voice-live--input-source event))
         (id (plist-get event :id))
         (record (and source (cdr (assoc source harness-voice-live--input-chunks)))))
    (setq harness-voice-live--recovery
          (harness-voice-recovery-continue harness-voice-live--recovery source text))
    ;; The capture is the thought's own: it is resolved, not waiting for
    ;; a turn that will never be sent.
    (when record
      (setf (plist-get record :open) nil
            (plist-get record :await-delegate) nil
            (plist-get record :state) 'resolved))
    (harness-voice-live--pipeline-segment
     (list :event "segment" :state "dropped" :id source :reason "recovered"))
    ;; The words are the thought's now: a draft built before they came
    ;; says them as they finally are.
    (harness-voice-live--recovery-revise)
    (harness-voice-live--send
     (list :event "delegate_result" :id id :text "" :error t :message "recovered"))))

(defun harness-voice-live--recovery-start (source text)
  "Take the turn back now, for SOURCE's TEXT, the continuation's first words.
Playback stops at once and the output gate closes; the turn is cancelled
through the ordinary `session/cancel' path, and the continuation is kept
as part of the thought the draft will carry.  The rewind waits for the
cancel to be acknowledged (`harness-voice-live--recovery-cancelled'),
because a head moved under a running turn would go on being written
after."
  (let* ((record harness-voice-live--recovery)
         (session (plist-get record :session)))
    (setq harness-voice-live--recovery
          (harness-voice-recovery-continue record source text))
    ;; What timed it, and what was heard: the record of why this turn is
    ;; being taken back.
    (harness-voice-live--recovery-say
     (car (harness-voice-recovery-evidence harness-voice-live--recovery)))
    (harness-voice-live--recovery-evidence
     (format "Recovering · %s" (harness-ui-one-line text)))
    (harness-voice-live--send (list :event "interrupt"))
    (harness-voice-live--acknowledgment-cancel)
    (harness-voice-live--cancel-held-timer)
    (setq harness-voice-live--held nil)
    (harness-voice-live--stage-set 'recovering)
    (harness-voice-live--turn-hold t)
    (harness-voice-live--pipeline-playback 'interrupted)
    (harness-voice-live--refresh)
    (if (and (stringp session) (not (string-empty-p session))
             (harness-voice-live--recovery-turn-running-p record))
        (progn
          (harness-ui-notify "session/cancel" (list :sessionId session))
          (let ((token (cl-incf harness-voice-live--recovery-token)))
            (setq harness-voice-live--recovery-timer
                  (run-at-time harness-voice-live-recovery-cancel-timeout nil
                               #'harness-voice-live--recovery-cancel-expired token))))
      ;; No turn of this call is in flight -- it already ended, or a
      ;; workspace thread runs it elsewhere: the history is read at once.
      (harness-voice-live--recovery-cancelled))))

(defun harness-voice-live--recovery-turn-running-p (record)
  "Non-nil when the turn RECORD was submitted for is still running.
A turn this call already saw end has nothing to cancel, and waiting for
an acknowledgement that will never come would only delay the recovery."
  (and harness-voice-live--working
       (equal (plist-get record :turn)
              (plist-get harness-voice-live--delegation :id))))

(defun harness-voice-live--recovery-cancel-expired (token)
  "Finish a recovery whose cancelled turn TOKEN waited for and never ended.
A turn that does not acknowledge its cancellation may still be writing,
so its history is not rewound: the continuation is submitted on its own,
and the transcript says so."
  (when (and (= token harness-voice-live--recovery-token)
             (eq (harness-voice-recovery-state harness-voice-live--recovery) 'recovering))
    (setq harness-voice-live--recovery-timer nil)
    (harness-voice-live--recovery-evidence "History · kept · cancel timeout")
    ;; The voice message was submitted, so it is in the history; only
    ;; the continuation goes on, and the head is not touched.
    (harness-voice-live--recovery-finish
     (list :action 'append :draft nil :why "cancel timeout"))))

(defun harness-voice-live--recovery-cancelled ()
  "Continue a recovery whose turn the cancel ended: read the history, then act.
The transcript is read from the harness rather than guessed, and what
the rewind may do is decided from it (`harness-voice-recovery-plan')."
  (when (eq (harness-voice-recovery-state harness-voice-live--recovery) 'recovering)
    (let ((record harness-voice-live--recovery))
      (if (not (harness-voice-live--active-p))
          (harness-voice-live--recovery-cancel)
        (harness-voice-live--recovery-cancel-timer)
        (harness-ui-call
         "_harness/session/nodes"
         (list :id (plist-get record :session))
         (lambda (nodes)
           (when (harness-voice-live--recovery-same-p record)
             (harness-voice-live--recovery-plan nodes)))
         (lambda (_error)
           (when (harness-voice-live--recovery-same-p record)
             (harness-voice-live--recovery-plan nil))))))))

(defun harness-voice-live--recovery-plan (nodes)
  "Carry out the recovery over the history NODES the cancelled turn left.
A rewind moves the session's head to the node before the voice message,
through `session/set-head', which the agent follows before its next
turn: the provider's conversation is cut to match, and the cancelled
turn's nodes stay on their own branch of the tree.  Anything a rewind
cannot safely undo keeps the history and appends the continuation
instead."
  (let* ((record harness-voice-live--recovery)
         (plan (harness-voice-recovery-plan record nodes))
         (session (plist-get record :session)))
    (setq harness-voice-live--recovery
          (plist-put (copy-sequence record) :plan plan))
    (harness-voice-live--recovery-evidence
     (harness-voice-recovery-plan-line plan))
    (if (and (eq (plist-get plan :action) 'rewind)
             (stringp session) (not (string-empty-p session)))
        (harness-ui-call
         "_harness/session/set-head"
         (list :id session :node-id (plist-get plan :head))
         (lambda (_)
           (when (harness-voice-live--recovery-same-p record)
             (harness-voice-live--recovery-finish plan)))
         (lambda (error)
           (when (harness-voice-live--recovery-same-p record)
             ;; A head that would not move leaves the history as it is;
             ;; the message is in it, so only the continuation goes on.
             (harness-voice-live--recovery-evidence
              (format "History · kept · %s"
                      (harness-ui-one-line (harness-error-message error))))
             (harness-voice-live--recovery-finish
              (harness-voice-recovery-fallback plan "rollback failed")))))
      (harness-voice-live--recovery-finish plan))))

(defun harness-voice-live--recovery-finish (plan)
  "Put the thought back in the draft, as PLAN says, and let it be submitted.
The continuations and, when PLAN says so, the original words go into the
ordinary pending turn, so the turn-completion grace decides when the
person is done talking and submits the whole thought once.  A history
that kept the voice message already holds the original, so only the
continuations are added."
  (let* ((record harness-voice-live--recovery)
         (items (harness-voice-recovery-draft record plan))
         (continuations (harness-voice-recovery-continuations record))
         (text (harness-voice-recovery-combined record continuations))
         (order (or (plist-get (car (last items)) :order) 0)))
    (setq harness-voice-live--recovery (harness-voice-recovery-finish record 'done))
    (when (and (harness-voice-live--active-p)
               (not (memq harness-voice-live--state '(ending failed))))
      (if (string-empty-p text)
          (harness-voice-live--recovery-cancel)
        (unless harness-voice-live--pending
          (setq harness-voice-live--pending
                (list :route (or (plist-get record :route)
                                 (harness-voice-live--route))
                      :items nil)))
        ;; A revised continuation rebuilds what this recovery put there
        ;; before: its own sources go, and are added again as they are
        ;; now, so the thought says each utterance once.
        (let ((mine (plist-get record :draft-segments)))
          (when mine
            (setf (plist-get harness-voice-live--pending :items)
                  (cl-remove-if (lambda (item)
                                  (member (plist-get item :segment) mine))
                                (plist-get harness-voice-live--pending :items)))))
        (setq harness-voice-live--recovery
              (plist-put (copy-sequence harness-voice-live--recovery)
                         :draft-segments
                         (append (plist-get record :segments)
                                 (mapcar #'car continuations))))
        (dolist (item items)
          (harness-voice-live--pending-add
           (list :segment (plist-get item :segment)
                 :order (plist-get item :order)
                 :raw-text (plist-get item :text)
                 :text (plist-get item :text)
                 :caption (plist-get item :caption)
                 :truncated (plist-get item :truncated))))
        ;; Each continuation is one source of the same thought, in the
        ;; order it was spoken.
        (dolist (pair continuations)
          (cl-incf order)
          (harness-voice-live--pending-add
           (list :segment (car pair) :order order
                 :raw-text (cdr pair) :text (cdr pair))))
        ;; The words are the draft's now: a caption hold from the same
        ;; captures cannot keep it from being submitted.
        (setq harness-voice-live--caption-hold nil
              harness-voice-live--caption-recovery nil
              harness-voice-live--caption-hold-order 0)
        (harness-voice-live--stage-set 'finishing)
        (harness-voice-live--pending-update)
        (harness-voice-live--refresh)))))

;;;; Delegation

(defun harness-voice-live--delegate-result (job text &optional error held)
  "Answer each source delegation of JOB with TEXT, ERROR and HELD."
  (dolist (id (or (plist-get job :ids) (list (plist-get job :id))))
    (harness-voice-live--send
     (append (list :event "delegate_result" :id id :text text)
             (and error (list :error t :message error))
             (and held (list :held t))))
    ;; Every chunk receives an acknowledgement, but the combined reply
    ;; is presented only once on the audio side too.
    (setq text "")))

(defun harness-voice-live--delegate-next ()
  "Send the next delegation to the agent, unless one is running.
The job carries the route it was spoken under.  A job whose route has
moved is answered with `retargeted' instead of being sent: the words
belong to the thread they were said in, and a thread selected after
them is not it."
  (when (and (null harness-voice-live--delegation)
             harness-voice-live--delegations
             (harness-voice-live--active-p)
             ;; A turn taken back is still ending: a prompt sent now
             ;; would steer the very turn the recovery is undoing.
             (not (eq (harness-voice-recovery-state harness-voice-live--recovery)
                      'recovering)))
    (let* ((job (pop harness-voice-live--delegations))
           (id (plist-get job :id))
           (text (plist-get job :text))
           (route (plist-get job :route)))
      (if (not (harness-voice-live--route-current-p (plist-get route :generation)))
          (progn
            (harness-voice-live--pipeline-turn id 'cancelled "retargeted")
            (harness-voice-live--delegate-result job "" "retargeted")
            (harness-voice-live--delegate-next))
        (cl-incf harness-voice-live--agent-watch)
        (cl-incf harness-voice-live--control-seq)
        (setq harness-voice-live--agent-turn nil
              harness-voice-live--output-suppressed nil
              harness-voice-live--control-status nil
              harness-voice-live--delegation
              (plist-put job :session (plist-get route :session))
              harness-voice-live--turn-id id
              harness-voice-live--working t
              harness-voice-live--turn-active t
              harness-voice-live--nodes (make-hash-table :test 'equal)
              harness-voice-live--order nil)
        (harness-voice-live--pipeline-turn-sent id (plist-get job :segments))
        (harness-voice-live--send (list :event "thinking" :text "Agent turn started"))
        (harness-voice-live--stage-set 'thinking)
        (harness-voice-live--refresh)
        (condition-case err
            (progn
              (harness-voice-live--dispatch route text
                                            (lambda (error)
                                              (harness-voice-live--delegate-error id error)))
              (harness-voice-live--capture-agent-turn)
              ;; The prompt is out: one short receipt of its arrival now,
              ;; beside the turn it belongs to.  This is after the request,
              ;; never before it, and the sidecar drops it rather than
              ;; queueing it.
              (harness-voice-live--acknowledge id))
          (error
           (harness-voice-live--delegate-error id err)))))))

(defun harness-voice-live--dispatch (route text on-error)
  "Send TEXT to ROUTE's target, calling ON-ERROR with a failure.
A session gets the ordinary `session/prompt' path, so its tools,
permissions and questions are the ones it always has.  A workspace
thread gets `_harness/workspace/prompt' with the thread, which is how
the workspace routes a message to that thread's live episode; the
workspace's own agent does the work, and no second model is asked to
interpret the words."
  (pcase (plist-get route :kind)
    ('workspace
     (let ((workspace (plist-get route :workspace))
           (thread (or (plist-get route :thread) (plist-get route :resolved-thread))))
       (unless (and (stringp workspace) (not (string-empty-p workspace)))
         (user-error "Live voice workspace unavailable"))
       (harness-ui-call
        "_harness/workspace/prompt"
        (append (list :id workspace :text text)
                (and thread (list :opts (list :thread thread))))
        #'ignore
        on-error)))
    (_
     (let ((session (plist-get route :session)))
       (unless (and (stringp session) (not (string-empty-p session)))
         (user-error "Live voice session unavailable"))
       (harness-ui-call-turn session "session/prompt"
                             (list :sessionId session
                                   :prompt (list (list :type "text" :text text)))
                             #'ignore
                             on-error)))))

(defun harness-voice-live--acknowledge-possible-p (delegation)
  "Non-nil when DELEGATION's receipt could be heard now.
The sidecar decides what it can play -- a person speaking, a held
transcript and the reply all keep it quiet -- but a request that this
client knows is muted, stopped, off or about to be said is not sent at
all.  DELEGATION must be the turn in flight: a receipt for another one
would be heard in a conversation it was not made for."
  (and harness-voice-acknowledgment
       harness-voice-live-acknowledgment
       (harness-voice-live--active-p)
       (not harness-voice-live--muted)
       (not (harness-voice-live--holding-output-p))
       (equal delegation (plist-get harness-voice-live--delegation :id))
       ;; The turn has produced nothing yet: a receipt is for a request,
       ;; not for an answer that has started to arrive.
       (zerop (hash-table-count (or harness-voice-live--nodes (make-hash-table))))))

(defun harness-voice-live--acknowledge (delegation)
  "Send DELEGATION's spoken receipt to the sidecar, or nothing.
The receipt is a phrase the sidecar generated before the call: it plays
one that no speech, held reply, mute or started output stands in front
of, and drops it otherwise.  Nothing here waits for the sidecar, and a
failure or a missing setting is silence, never a failed turn."
  (when (harness-voice-live--acknowledge-possible-p delegation)
    (harness-voice-live--send
     (list :event "acknowledge" :delegation delegation))))

(defun harness-voice-live--acknowledgment-cancel ()
  "Tell the sidecar to drop a receipt it has not started yet.
The receipt of a request that a later request or an interruption made
stale is silence, never heard after the fact."
  (when (harness-voice-live--active-p)
    (harness-voice-live--send (list :event "acknowledgment-cancel"))))

(defun harness-voice-live--delegate-error (id error)
  "Report that delegation ID failed with ERROR."
  (when (and (equal id (plist-get harness-voice-live--delegation :id)))
    (harness-voice-live--pipeline-turn-ended
     'failed (harness-ui-one-line (harness-error-message error)))
    (harness-voice-live--delegate-result
     harness-voice-live--delegation "" (harness-ui-one-line (harness-error-message error)))
    (setq harness-voice-live--held
          (cl-remove id harness-voice-live--held
                     :key (lambda (item) (plist-get item :turn)) :test #'equal))
    (setq harness-voice-live--delegation nil
          harness-voice-live--turn-id nil
          harness-voice-live--working nil
          harness-voice-live--turn-active nil)
    (harness-voice-live--settle-stage)
    (harness-voice-live--refresh)
    (harness-voice-live--delegate-next)))

(defun harness-voice-live--delegate (event)
  "Accumulate EVENT's original words before any agent delivery.
Stable utterance ids are consumed on receipt, including during a hold.
The final transcript starts grace only after all accepted chunks resolve;
continuation intent and explicit or likely cut-offs have no deadline."
  (harness-voice-live--follow-selection)
  (let* ((id (or (plist-get event :id) (format "d-%s" (float-time))))
         (text (or (plist-get event :text) (plist-get event :prompt) ""))
         (text (string-trim (if (string-empty-p text) harness-voice-live--heard text)))
         (source (or (harness-voice-live--input-source event) (concat "d:" id)))
         (record (harness-voice-live--input-record source))
         (route (plist-get record :route))
         (caption harness-voice-live--heard))
    (unless (harness-voice-live--delegate-seen-p event)
      (setq harness-voice-live--heard ""
            harness-voice-live--input-anonymous nil)
      (when (>= (plist-get record :order) harness-voice-live--caption-hold-order)
        (setq harness-voice-live--caption-hold nil
              harness-voice-live--caption-recovery nil))
      (harness-voice-live--pending-cancel-timer)
      (harness-voice-live--cancel-held-timer)
      (cond
       ((plist-get record :accounted)
        (harness-voice-live--send (list :event "delegate_result" :id id :text "")))
       ((or (eq (plist-get record :state) 'cancelled)
            harness-voice-live--muted
            (memq harness-voice-live--state '(ending failed))
            (not (harness-voice-live--route-current-p (plist-get route :generation))))
        (setf (plist-get record :open) nil)
        (harness-voice-live--send
         (list :event "delegate_result" :id id :text "" :error t
               :message (if (harness-voice-live--route-current-p (plist-get route :generation))
                            "cancelled" "retargeted"))))
       ((string-empty-p text)
        (setf (plist-get record :open) nil
              (plist-get record :state) 'dropped)
        (harness-voice-live--drop-burst event "no words")
        (harness-voice-live--transcript-sent nil)
        (harness-voice-live--send (list :event "delegate_result" :id id :text ""))
        (harness-voice-live--turn-hold
         (or harness-voice-live--pending (harness-voice-live--input-busy-p)))
        (harness-voice-live--settle-stage))
       (t
        (setf (plist-get record :open) nil
              (plist-get record :state) 'resolved)
        (harness-voice-pipeline-segment harness-voice-live--pipeline source 'transcribed
                                        (list :text text))
        (unless harness-voice-live--pending
          (setq harness-voice-live--pending (list :route route :items nil)))
        (harness-voice-live--pending-add
         (list :id id :raw-text text :text text :caption caption
               :segment source :order (plist-get record :order)
               :cue (harness-voice-turn-recovery-p text)
               :pause (harness-voice-turn-continuation-p text)
               :truncated (or (eq (plist-get event :truncated) t)
                              (plist-get record :truncated))))
        ;; A failure arriving before an earlier slow transcript is still
        ;; a missing continuation, not permission to send the old fragment.
        (dolist (entry harness-voice-live--input-chunks)
          (when (and (eq (plist-get (cdr entry) :state) 'failed)
                     (not (plist-get (cdr entry) :accounted))
                     (harness-voice-live--route-current-p
                      (plist-get (plist-get (cdr entry) :route) :generation)))
            (harness-voice-live--pending-add
             (list :segment (car entry) :order (plist-get (cdr entry) :order) :failed t))))
        (when (equal source harness-voice-live--utterance-done)
          (setq harness-voice-live--utterance-done nil))
        (when (equal source harness-voice-live--utterance)
          (setq harness-voice-live--utterance nil))
        (harness-voice-live--pending-update))))))

(defun harness-voice-live--drop-burst (event reason)
  "Record EVENT's burst as dropped with REASON, and return to listening."
  (let ((segment (harness-voice-live--input-source event)))
    (when segment
      (harness-voice-live--pipeline-segment
       (list :event "segment" :state "dropped" :id segment :reason reason))
      (when (equal segment harness-voice-live--utterance-done)
        (setq harness-voice-live--utterance-done nil)))))

(defun harness-voice-live--settle-stage ()
  "Return to the stage the session is really in, after a burst is done."
  (harness-voice-live--stage-set
   (cond ((not (harness-voice-live--active-p)) nil)
         (harness-voice-live--muted 'muted)
         (harness-voice-live--speech-active 'hearing)
         ((harness-voice-live--input-busy-p) 'transcribing)
         (harness-voice-live--pending (harness-voice-live--pending-stage))
         (harness-voice-live--caption-hold harness-voice-live--caption-hold)
         ((eq (harness-voice-recovery-state harness-voice-live--recovery) 'recovering)
          'recovering)
         (harness-voice-live--held 'holding)
         (harness-voice-live--working 'thinking)
         (t 'listening))))

(defun harness-voice-live--finish-turn (outcome)
  "Finish the agent turn that ended with OUTCOME.
A turn whose route moved while it ran is answered, but its reply is not
spoken: the person is in another thread now, and a sentence about the
old one would arrive as if it answered the new one."
  (let* ((cancelled (member outcome '("cancelled" "error" "failed")))
         (delegation harness-voice-live--delegation)
         (route (plist-get delegation :route))
         (stale (and route
                     (not (harness-voice-live--route-current-p
                           (plist-get route :generation)))))
         (suppressed harness-voice-live--output-suppressed)
         (text nil))
    (cl-incf harness-voice-live--agent-watch)
    (setq harness-voice-live--agent-turn nil)
    (if cancelled
        (progn
          (harness-voice-live--pipeline-turn-ended 'failed (or outcome "cancelled"))
          (setq harness-voice-live--working nil
                harness-voice-live--turn-active nil
                harness-voice-live--delegation nil
                harness-voice-live--nodes nil
                harness-voice-live--order nil)
          (harness-voice-live--cancel-held-timer)
          (setq harness-voice-live--held
                (cl-remove (plist-get delegation :id) harness-voice-live--held
                           :key (lambda (item) (plist-get item :turn)) :test #'equal))
          (when delegation
            (harness-voice-live--delegate-result
             delegation "" (unless suppressed (or outcome "cancelled")))))
      (maphash (lambda (id _entry)
                 (harness-voice-live--drain-node id t))
               (or harness-voice-live--nodes (make-hash-table)))
      (setq text (harness-voice-live--reply-text)
            harness-voice-live--working nil
            harness-voice-live--turn-active nil
            harness-voice-live--delegation nil)
      (harness-voice-live--pipeline-turn-ended
       (if stale 'cancelled 'done) (and stale "retargeted"))
      (when delegation
        (cond
         (stale
          ;; The words went to the thread they were said in; the reply
          ;; stays there, and the sidecar is told so it stops waiting.
          (harness-voice-live--delegate-result delegation "" "retargeted"))
         (suppressed
          ;; A tool or stream finishing after interruption must not restart
          ;; the answer.  This is an empty successful acknowledgment, not
          ;; an error that a provider might speak as fabricated dialogue.
          (harness-voice-live--delegate-result delegation ""))
         ((harness-voice-live--holding-output-p)
          ;; Keep the full result as context only when no sentence of
          ;; it was already held; otherwise the pieces are the truth.
          (unless (cl-find (plist-get delegation :id) harness-voice-live--held
                           :key (lambda (item) (plist-get item :turn))
                           :test #'equal)
            (harness-voice-live--hold
             (format "result:%s" (plist-get delegation :id)) text))
          (harness-voice-live--delegate-result delegation text nil t))
         (t
          (harness-voice-live--delegate-result delegation text)
          (harness-voice-conversation-say
           harness-voice-live--conversation text 'result))))
      (setq harness-voice-live--nodes nil
            harness-voice-live--order nil))
    ;; A turn that ends while another delegation waits stays in Working:
    ;; the next turn starts at once.
    ;; A turn the recovery cancelled is over: its history can be read and
    ;; its head moved without a write following it.
    (when (and cancelled
               (eq (harness-voice-recovery-state harness-voice-live--recovery)
                   'recovering))
      (harness-voice-live--recovery-cancelled))
    (unless (or (eq harness-voice-live--state 'speaking)
                harness-voice-live--delegations
                (eq (harness-voice-recovery-state harness-voice-live--recovery)
                    'recovering))
      (harness-voice-live--settle-stage))
    (harness-voice-live--refresh)
    (harness-voice-live--delegate-next)))

;;;; Agent updates and events

(defun harness-voice-live--capture-agent-turn ()
  "Learn the watched backend turn's identity without guessing from session status.
A late snapshot cannot replace the identity of a later turn or route."
  (let ((session (or (plist-get harness-voice-live--delegation :session)
                     harness-voice-live--session))
        (watch harness-voice-live--agent-watch)
        (generation harness-voice-live--route-generation))
    (when session
      (harness-ui-call
       "_harness/agent/activity" (list :session-id session)
       (lambda (activity)
         (when (and (= watch harness-voice-live--agent-watch)
                    (= generation harness-voice-live--route-generation)
                    harness-voice-live--working)
           (setq harness-voice-live--agent-turn (plist-get activity :turn-id))))
       #'ignore))))

(defun harness-voice-live--on-update (sid update)
  "Follow live assistant text for session SID from UPDATE.
A session the call is about answers, whether it is the route's now or
the one the running turn was sent to: a turn that outlives a switch
still finishes where it was sent."
  (when (and (harness-voice-live-p)
             (harness-voice-live--active-p)
             (harness-voice-live--watched-session-p sid))
    (pcase (plist-get update :sessionUpdate)
      ("_harness/session_deleted" (harness-voice-live-stop))
      ("_harness/activity"
       (when (harness-voice-live--turn-session-p sid)
         (cl-incf harness-voice-live--agent-watch)
         (setq harness-voice-live--agent-turn
               (plist-get (plist-get update :activity) :turn-id))))
      ((or "agent_message_chunk" "_harness/node" "tool_call")
       (when harness-voice-live--turn-active
         (pcase (plist-get update :sessionUpdate)
           ("agent_message_chunk"
            (let ((id (plist-get (plist-get update :_harness) :nodeId))
                  (text (plist-get (plist-get update :content) :text)))
              (when (and id (stringp text))
                (harness-voice-live--add-chunk id text))))
           ("_harness/node"
            (let ((node (plist-get update :node)))
              (when (equal (format "%s" (plist-get node :kind)) "assistant")
                (harness-voice-live--add-node (plist-get node :id)
                                              (plist-get node :content)))))
           ("tool_call"
            (when-let* ((title (plist-get update :title)))
              (harness-voice-live--transcript-tool title)
              (harness-voice-live--send
               (list :event "thinking" :text (format "Tool call: %s" title)))))))))))

(defun harness-voice-live--workspace-episode (args)
  "Attach the episode in ARGS before its agent events or the UI cache arrive.
The server emits (WORKSPACE THREAD-PLIST SESSION DIVIDER) before starting
that episode's turn.  Its payload, not a debounced fetch, owns this binding."
  (let* ((workspace (car args))
         (thread (plist-get (cadr args) :id))
         (session (nth 2 args))
         (job harness-voice-live--delegation)
         (route (plist-get job :route))
         (job-thread (or (plist-get route :thread) (plist-get route :resolved-thread)))
         (job-match (and job (eq (plist-get route :kind) 'workspace)
                         (equal workspace (plist-get route :workspace))
                         (or (equal thread job-thread)
                             (and (null job-thread) (null (plist-get job :session)))))))
    (when (and (stringp thread) (stringp session))
      (when (and job-match (null (plist-get job :session)))
        (setq harness-voice-live--delegation
              (plist-put job :session session))
        (setf (plist-get route :resolved-thread) thread))
      (when (and (eq harness-voice-live--route-kind 'workspace)
                 (equal workspace harness-voice-live--route-workspace)
                 (or (equal thread (or harness-voice-live--route-thread
                                       harness-voice-live--route-resolved-thread))
                     (and job-match (null harness-voice-live--route-thread)
                          (null harness-voice-live--route-resolved-thread)
                          (harness-voice-live--route-current-p (plist-get route :generation)))))
        (setq harness-voice-live--session session)
        (unless harness-voice-live--route-thread
          (setq harness-voice-live--route-resolved-thread thread))))))

(defun harness-voice-live--on-event (event args)
  "Follow agent EVENT with ARGS while a live session runs."
  (when (and (harness-voice-live-p) (harness-voice-live--active-p))
    (if (equal event "workspace/episode-changed")
        (harness-voice-live--workspace-episode args)
      (when (harness-voice-live--watched-session-p (car args))
        (pcase event
          ("agent/turn-started"
           ;; Only the session the running delegation went to is this call's
           ;; turn: a turn started in a thread the person just selected is
           ;; driven by that thread's own message, not by the microphone.
           (when (harness-voice-live--turn-session-p (car args))
             (unless harness-voice-live--turn-active
               (cl-incf harness-voice-live--agent-watch)
               (cl-incf harness-voice-live--control-seq)
               (setq harness-voice-live--nodes (make-hash-table :test 'equal)
                     harness-voice-live--order nil
                     harness-voice-live--agent-turn nil
                     harness-voice-live--output-suppressed nil
                     harness-voice-live--control-status nil))
             (setq harness-voice-live--turn-active t
                   harness-voice-live--working t)
             (harness-voice-live--capture-agent-turn)
             (harness-voice-live--refresh)))
          ("agent/turn-ended"
           (when (harness-voice-live--turn-session-p (car args))
             (harness-voice-live--finish-turn (cadr args))))
          ((or "_harness/session_deleted" "session/deleted")
           (harness-voice-live-stop)))))))

(defun harness-voice-live--route-resolve ()
  "Refresh the route's session from the workspace thread it names.
A thread's live episode is made by the harness when the first message
of a new episode goes out, so the route learns it from the workspace
rather than guessing one.  A route that is not a workspace is left as
it is."
  (when (eq harness-voice-live--route-kind 'workspace)
    (when (buffer-live-p harness-voice-live--buffer)
      (with-current-buffer harness-voice-live--buffer
        (when (and (bound-and-true-p harness-ui-workspace--id)
                   (equal harness-ui-workspace--id
                          harness-voice-live--route-workspace)
                   (fboundp 'harness-ui-workspace--live-session))
          (let ((session (harness-ui-workspace--live-session)))
            (unless (equal session harness-voice-live--session)
              (setq harness-voice-live--session session))))))))

;;;; Sidecar events

(defun harness-voice-live--stale-input-p (event)
  "Whether EVENT is input canceled by a route or lifecycle change."
  (when (member (plist-get event :event)
                '("speech" "hearing" "transcribing" "user_delta" "segment"))
    (let* ((source (if (equal (plist-get event :event) "segment") (plist-get event :id)
                     (and (plist-get event :utterance)
                          (format "u-%s" (plist-get event :utterance)))))
           (record (cdr (assoc source harness-voice-live--input-chunks))))
      (or harness-voice-live--muted
          (memq harness-voice-live--state '(ending failed))
          (eq (plist-get record :state) 'cancelled)
          (and (equal (plist-get event :event) "user_delta")
               (eq (plist-get record :state) 'resolved)
               (not (and harness-voice-live--pending (eq (plist-get event :truncated) t))))
          (and record (not (harness-voice-live--route-current-p
                            (plist-get (plist-get record :route) :generation))))))))

(defun harness-voice-live--handle (event)
  "Handle one parsed sidecar EVENT.
Explicit interruption acknowledgments are tagged by bundled sidecars.
The client already applied that control synchronously; a late echo must
not suppress a newer answer or overwrite its playback state."
  (unless (or (and (member (plist-get event :event) '("interrupted" "listening"))
                   (plist-member event :interrupt_id))
              (and (member (plist-get event :event) '("interrupted" "listening" "speaking"))
                   (memq harness-voice-live--state '(nil ending failed)))
              (harness-voice-live--stale-input-p event))
    (harness-voice-live--handle-current event)))

(defun harness-voice-live--handle-current (event)
  "Handle EVENT after its input route and lifecycle have been checked."
  (harness-voice-live--input-event event)
  (pcase (plist-get event :event)
    ("level"
     (harness-voice-live--pipeline-level (plist-get event :input)
                                         (plist-get event :peak)
                                         (plist-get event :dbfs)))
    ("camera"
     ;; A camera provider's own state: the device, the faces in view and
     ;; the rate.  It is drawn beside the live status, so an open camera
     ;; is never invisible, and `closed' or `ended' clears it.
     (setq harness-voice-live--camera
           (pcase (plist-get event :state)
             ("closed" nil)
             ("ended" nil)
             (_ event)))
     (harness-voice-live--refresh))
    ("segment"
     (harness-voice-live--pipeline-segment event))
    ("ready"
     (when (eq harness-voice-live--state 'starting)
       (when (timerp harness-voice-live--timer)
         (cancel-timer harness-voice-live--timer))
       (setq harness-voice-live--timer nil
             harness-voice-live--state 'listening)
       (harness-voice-pipeline-set-capture
        harness-voice-live--pipeline 'live nil
        (harness-voice-live--pipeline-generation))
       (harness-voice-live--stage-set 'listening)
       (harness-voice-live--pipeline-touch t)
       (harness-voice-live--refresh)))
    ("speech"
     (harness-voice-live--recovery-onset event)
     (let ((active (plist-get event :active)))
       (when (plist-get event :utterance)
         (harness-voice-live--utterance-route-set
          (plist-get event :utterance) (harness-voice-live--route)))
       (harness-voice-live--pipeline-speech active)
       (when (and active (plist-get event :utterance))
         (harness-voice-live--pipeline-segment
          (list :event "segment" :state "accepted"
                :id (format "u-%s" (plist-get event :utterance)))))
       (setq harness-voice-live--speech-active (and active t))
       (harness-voice-live--cancel-held-timer)
       (when active
         (unless (eq harness-voice-live--stage 'thinking)
           (harness-voice-live--stage-set 'hearing)))
       (harness-voice-live--refresh)))
    ("listening"
     (setq harness-voice-live--state 'listening)
     (harness-voice-live--pipeline-playback 'listening)
     (if (and harness-voice-live--held
              (not harness-voice-live--speech-active))
         (progn
           (harness-voice-live--stage-set
            (if harness-voice-live--pending (harness-voice-live--pending-stage) 'holding))
           (harness-voice-live--schedule-held-release))
       (harness-voice-live--settle-stage))
     (harness-voice-live--refresh))
    ("hearing"
     (setq harness-voice-live--state 'listening)
     (when (plist-get event :utterance)
       (harness-voice-live--utterance-route-set
        (plist-get event :utterance) (harness-voice-live--route))
       (let ((id (format "u-%s" (plist-get event :utterance))))
         (unless (equal id harness-voice-live--utterance)
           (setq harness-voice-live--utterance nil
                 harness-voice-live--utterance-done nil))
         (harness-voice-live--pipeline-segment
          (list :event "segment" :state "accepted" :id id))
         (setq harness-voice-live--utterance id)))
     (harness-voice-live--stage-set 'hearing)
     (harness-voice-live--refresh))
    ("transcribing"
     (harness-voice-live--cancel-held-timer)
     (setq harness-voice-live--state 'listening)
     (when (plist-get event :utterance)
       (harness-voice-live--pipeline-segment
        (list :event "segment" :state "transcribing"
              :id (format "u-%s" (plist-get event :utterance)))))
     (harness-voice-live--stage-set 'transcribing)
     (harness-voice-live--refresh))
    ("speaking"
     (if (or harness-voice-live--output-suppressed harness-voice-live--muted
             (harness-voice-live--holding-output-p))
         ;; Completion of stale synthesis is not permission to speak over
         ;; the person or to reopen a muted path.
         (harness-voice-live--silence-output)
       (setq harness-voice-live--state 'speaking)
       (harness-voice-live--pipeline-playback 'speaking)
       (harness-voice-live--stage-set 'speaking))
     (harness-voice-live--refresh))
    ((or "user_delta" "assistant_delta")
     (let ((text (or (plist-get event :text) ""))
           (certainty (plist-get event :certainty))
           (final (plist-get event :final)))
       (cond
        ((and (equal (plist-get event :event) "user_delta")
              (equal certainty "unsure"))
         ;; A provider that measures its own confidence says when its
         ;; words are a guess.  They are shown as such, and no request
         ;; crosses into the session: the person may not have said any
         ;; of it.
         (harness-voice-live--uncertain-caption text final))
        ((equal (plist-get event :event) "user_delta")
         (when (plist-get event :utterance)
           (setq harness-voice-live--utterance
                 (format "u-%s" (plist-get event :utterance))))
         ;; The first accepted words of resumed speech take the turn back
         ;; in this very event; the rest of the thought joins the draft.
         (if (harness-voice-live--recovery-caption
              text (harness-voice-live--input-source event) final certainty)
             ;; A caption of the thought being recovered is not new input
             ;; for the pending turn: it is already part of the draft.
             nil
           (harness-voice-live--recovery-words
            text (harness-voice-live--input-source event) certainty)
           (harness-voice-live--pipeline-caption text final))
         (setq harness-voice-live--heard
               (concat harness-voice-live--heard text))
         (unless (memq harness-voice-live--stage '(transcribing recovering))
           (harness-voice-live--stage-set 'hearing))
         (harness-voice-live--caption "You" text final
                                       (and (equal certainty "likely") "likely"))
         (unless (or harness-voice-live--muted
                     (harness-voice-recovery-continuation-source-p
                      harness-voice-live--recovery
                      (harness-voice-live--input-source event)))
           (harness-voice-live--caption-hold-update
            text final (eq (plist-get event :truncated) t)
            (harness-voice-live--input-source event))))
        (t
         (harness-voice-live--caption "Voice" text final)
         ;; A provider's own speech, outside the agent's turn, is
         ;; voice-only: the session never saw it.  A turn's result is
         ;; recorded when it is handed back, and held text was not
         ;; heard, so neither is a voice turn here.
         (unless (or (harness-voice-live--holding-output-p)
                     harness-voice-live--turn-active)
           (harness-voice-conversation-say
            harness-voice-live--conversation text 'provider nil t))))))
    ("backchannel"
     (let ((text (or (plist-get event :text) "mm-hmm")))
       (harness-voice-live--backchannel text)
       (harness-voice-conversation-say
        harness-voice-live--conversation text 'backchannel)))
    ("delegation"
     (harness-voice-live--cancel-held-timer)
     ;; A provider that sends no captions still takes its turn back on
     ;; the first words of the continuation.
     (harness-voice-live--recovery-words
      (plist-get event :text) (harness-voice-live--input-source event))
     (if (harness-voice-live--recovery-absorb event)
         ;; The words are the thought being taken back, not a new turn.
         (harness-voice-live--recovery-absorbed event)
       (harness-voice-live--delegate event)))
    ("interrupted"
     ;; A provider barge-in is a playback/control fact, not dictation and
     ;; not a closed capture state.  Explicit command echoes are ignored
     ;; above; this untagged edge belongs to the provider's speech gate.
     (unless harness-voice-live--output-suppressed
       (harness-voice-live--control-note "Playback interrupted")
       (harness-voice-live--agent-control "interrupt"))
     (harness-voice-live--silence-output t))
    ("error"
     (harness-voice-live--pipeline-end
      'failed (format "Live voice failed · %s"
                      (or (plist-get event :message) "sidecar error")))
     (harness-voice-live--fail
      (format "Live voice failed · %s"
              (or (plist-get event :message) "sidecar error"))))
    ("notice"
     (harness-voice-live--show-notice
      (or (plist-get event :message) "Sidecar notice")))
    ("closed"
     (harness-voice-live--pipeline-end 'ended)
     (setq harness-voice-live--closing t)
     (harness-voice-live--dispose)
     (setq harness-voice-live--state nil
           harness-voice-live--closing nil)
     (harness-voice-live--clear-turn)
     (harness-voice-live--refresh)))
  (harness-voice-live--pending-update)
  (harness-voice-live--turn-hold
   (and (not harness-voice-live--muted)
        (not (memq harness-voice-live--state '(ending failed)))
        (or harness-voice-live--pending harness-voice-live--caption-hold
            (harness-voice-live--input-busy-p))))
  (when (and harness-voice-live--caption-recovery
             (not (plist-get harness-voice-live--caption-recovery :released))
             (not harness-voice-live--pending)
             (not (harness-voice-live--input-busy-p)))
    (setf (plist-get harness-voice-live--caption-recovery :released) t)
    (harness-voice-live--release-held))
  (when (and harness-voice-live--caption-hold
             (not harness-voice-live--pending)
             (not (harness-voice-live--input-busy-p)))
    (harness-voice-live--stage-set harness-voice-live--caption-hold)))

;;;; Commands

(defun harness-voice-live--last-frame-p (frame frames)
  "Return non-nil when FRAME is the last of FRAMES that can show the UI.
A graphic frame counts against the other graphic frames; a terminal
frame counts against every frame.  A daemon keeps an unseen terminal
frame after its last graphical window closes, and voice must not hold
the microphone and the speaker for a window nobody can see."
  (let ((graphic (display-graphic-p frame)))
    (null (seq-filter (lambda (other)
                        (and (not (eq other frame))
                             (if graphic (display-graphic-p other) t)))
                      frames))))

(defun harness-voice-live--frame-deleted (frame)
  "End live voice when FRAME was the last frame that could show it.
Closing the Emacs window must stop the sound: the sidecar owns the
microphone and the speaker, and a reply playing on to an empty desktop
cannot be interrupted from the UI that is gone."
  (when (and (harness-voice-live--active-p)
             (harness-voice-live--last-frame-p frame (frame-list)))
    (harness-voice-live-stop)))

(defun harness-voice-live--start-here ()
  "Start live voice, showing validation failures in the controls."
  (interactive)
  (condition-case err
      (harness-voice-live-start)
    (error
     (setq harness-voice--controls t
           harness-voice-live--state 'failed
           harness-voice-live--error (harness-ui-one-line (error-message-string err)))
     ;; The failure can come before the sidecar's buffer is recorded, so
     ;; refresh this compose box directly: otherwise the control still
     ;; reads Off with a Start button that seems to do nothing.
     (harness-voice--refresh))))

(defun harness-voice-live--prepare ()
  "Run the selected provider's start hook, or refuse the session.
A camera provider asks for the camera here, once per session, and a
refusal is a user error: no sidecar process starts and no device opens."
  (let ((prepare (plist-get (harness-voice-provider-get harness-voice-provider)
                            :prepare)))
    (when (functionp prepare)
      (funcall prepare))))

(defun harness-voice-live--stopped ()
  "Tell the selected provider its session ended, however it ended."
  (let ((stopped (plist-get (harness-voice-provider-get harness-voice-provider)
                            :stopped)))
    (when (functionp stopped)
      (condition-case err
          (funcall stopped)
        (error
         (harness-log 'warn "voice: the stopped hook failed: %s"
                      (harness-error-message err)))))))

;;;###autoload
(defun harness-voice-live-start ()
  "Start the live sidecar session for this compose box.
A call that already runs is retargeted here instead of refused: the
sidecar, the microphone and the speech services are shared, and only
the words' destination moves.

The local pipeline is the harness server's, and it is started when it
is not running: the controls read `Initializing' while it comes up, and
the sidecar starts once it answers.  A pipeline that fails says why at
once, with a Retry control, rather than waiting out its own deadline."
  (interactive)
  (unless (harness-voice-live-p)
    (user-error "Live voice provider unavailable"))
  (unless (harness-compose-live-p)
    (user-error "Live voice compose unavailable"))
  (let ((route (harness-voice-live--route-of-buffer (current-buffer))))
    (unless route
      (user-error "Live voice session unavailable"))
    (if (harness-voice-live--active-p)
        (harness-voice-live-retarget (current-buffer))
      (progn
        ;; The provider's own permission and readiness, before anything starts.
        (harness-voice-live--prepare)
        (unless harness-voice-mode (harness-voice-mode 1))
        (harness-voice--adopt)
        ;; Through the setter, never `setf': this file's `setf' on the
        ;; accessor compiles to a call of a function that does not exist
        ;; when it is compiled before the struct is (see
        ;; `harness-voice-pipeline-set-input').
        (harness-voice-pipeline-set-input harness-voice-live--pipeline
                                          (harness-voice-live--input))
        (harness-voice-live--pipeline-bump 'connecting)
        (setq harness-voice-live--error nil
              harness-voice-live--notice nil
              harness-voice-live--muted nil
              harness-voice-live--closing nil
              harness-voice-live--tail ""
              harness-voice-live--speaker nil
              harness-voice-live--seen (make-hash-table :test 'equal)
              harness-voice-live--input-chunks nil
              harness-voice-live--input-seq 0
              harness-voice-live--held-seq 0
              harness-voice-live--route-generation 0
              harness-voice-live--utterance-routes nil)
        (harness-voice-live--route-set route)
        (harness-voice-live--clear-gate)
        (harness-voice-live--clear-turn)
        (when (buffer-live-p harness-voice-live--transcript)
          (with-current-buffer harness-voice-live--transcript
            (let ((inhibit-read-only t)) (erase-buffer))
            (setq-local harness-voice-live--pipeline-end nil))
          (harness-voice-live--pipeline-draw))
        (harness-voice-live--transcript-route)
        (harness-voice-live--begin)))))

(defun harness-voice-live--begin ()
  "Start the sidecar, once the speech services it needs are up.
A provider that needs no local pipeline starts at once.  The local
pipeline is the harness server's and is shared by every client, so a
start attaches to one that runs or is already starting, and starts one
that is stopped."
  (let ((reason (harness-voice-live--pipeline-need)))
    (cond
     ((null reason)
      (harness-voice-live--spawn))
     ((eq reason 'starting)
      (setq harness-voice-live--state 'initializing)
      (harness-voice-live--stage-set 'initializing)
      (harness-voice-live--refresh)
      (harness-voice-live--watch-pipeline))
     (t
      (harness-voice-live--pipeline-start)))))

(defun harness-voice-live--pipeline-need ()
  "Return what the local pipeline still needs, or nil when it is ready.
Only the local provider uses the harness server's pipeline: a sidecar
of your own, the fixture or GPT-Live needs nothing of it.  `starting'
means a start is in flight, which this call waits for; a string is the
reason it cannot be used, which is shown as it is."
  (when (and (eq harness-voice-provider 'unmute)
             (fboundp 'harness-voice-unmute-need))
    (let ((reason (harness-voice-unmute-need)))
      (cond
       ((null reason) nil)
       ((harness-voice-live--pipeline-starting-p) 'starting)
       (t (or reason "Local voice pipeline · stopped"))))))

(defun harness-voice-live--pipeline-starting-p ()
  "Non-nil when the harness reports its local pipeline starting."
  (and (fboundp 'harness-voice-pipeline-state)
       (eq 'starting (harness-voice-pipeline-state))))

(defun harness-voice-live--pipeline-start ()
  "Start the shared local pipeline and wait for it, visibly.
The controls read `Initializing' while it comes up.  A start that fails
fails this call at once with the harness's own reason, so a broken
pipeline is a sentence in the controls, not a two-minute wait."
  (setq harness-voice-live--state 'initializing)
  (harness-voice-live--stage-set 'initializing)
  (harness-voice-live--refresh)
  (harness-voice-live--watch-pipeline)
  (condition-case err
      (harness-voice-pipeline-start)
    (error
     (harness-voice-live--fail
      (format "Local voice pipeline · %s" (error-message-string err))))))

(defun harness-voice-live--watch-pipeline ()
  "Follow the shared pipeline until it runs, or says why it cannot.
The harness reports its state as it moves (`speech/changed'), and this
reads the cached state on a short timer as well, so a client that
missed an event still starts."
  (harness-voice-live--cancel-pipeline-timer)
  (setq harness-voice-live--pipeline-timer
        (run-at-time 0.2 0.2 #'harness-voice-live--pipeline-tick)))

(defun harness-voice-live--cancel-pipeline-timer ()
  "Stop following the shared pipeline."
  (when (timerp harness-voice-live--pipeline-timer)
    (cancel-timer harness-voice-live--pipeline-timer))
  (setq harness-voice-live--pipeline-timer nil))

(defun harness-voice-live--pipeline-tick ()
  "Start the sidecar when the pipeline runs, or fail with its reason."
  (cond
   ((not (eq harness-voice-live--state 'initializing))
    (harness-voice-live--cancel-pipeline-timer))
   ((harness-voice-live--active-p)
    (harness-voice-live--cancel-pipeline-timer))
   ((null (harness-voice-live--pipeline-need))
    (harness-voice-live--cancel-pipeline-timer)
    (harness-voice-live--spawn))
   ((let ((state (and (fboundp 'harness-voice-pipeline-state)
                      (harness-voice-pipeline-state))))
      (eq state 'failed))
    (harness-voice-live--cancel-pipeline-timer)
    (harness-voice-live--fail
     (or (and (fboundp 'harness-voice-pipeline-reason)
              (harness-voice-pipeline-reason))
         "Local voice pipeline · failed")))))

(defun harness-voice-live--spawn ()
  "Start the sidecar process for the current route."
  (let ((command (harness-voice-live--command))
        (stderr (generate-new-buffer " *harness-voice-live-errors*")))
    (setq harness-voice-live--stderr stderr
          harness-voice-live--state 'starting
          harness-voice-live--error nil
          harness-voice-live--closing nil
          harness-voice-live--camera nil
          harness-voice-live--tail ""
          harness-voice-live--speaker nil
          harness-voice-live--seen (make-hash-table :test 'equal)
          harness-voice-live--held-seq 0)
    (harness-voice-live--clear-gate)
    (harness-voice-live--clear-turn)
    (when (buffer-live-p harness-voice-live--transcript)
      (with-current-buffer harness-voice-live--transcript
        (let ((inhibit-read-only t)) (erase-buffer))
        (setq-local harness-voice-live--pipeline-end nil))
      (harness-voice-live--pipeline-draw))
    (condition-case err
        (let ((process
               (make-process
                :name "harness-voice-live" :command command
                :connection-type 'pipe :coding 'utf-8-unix :noquery t
                :buffer nil :stderr stderr
                :filter #'harness-voice-live--filter
                :sentinel #'harness-voice-live--finished)))
          (setq harness-voice-live--process process)
          (harness-voice-live--start-timer harness-voice-live-startup-timeout
                                           #'harness-voice-live--startup-timeout)
          (process-send-string
           process
           (harness-voice-live--json
            (list :event "start" :protocol harness-voice-live--protocol))))
      (error
       (harness-voice-live--dispose)
       (setq harness-voice-live--state 'failed
             harness-voice-live--error (harness-ui-one-line (error-message-string err)))))
    (harness-voice-live--refresh)))

;;;###autoload
(defun harness-voice-live-stop ()
  "End the live sidecar session."
  (interactive)
  (unless (eq harness-voice-live--state 'ending)
    (harness-voice-live--pending-cancel "cancelled")
    (cond
     ((harness-voice-live--active-p)
      (setq harness-voice-live--state 'ending
            harness-voice-live--closing t
            harness-voice-live--working nil)
      (harness-voice-live--pipeline-end 'ended)
      (harness-voice-live--send (list :event "stop"))
      (harness-voice-live--start-timer harness-voice-live--stop-timeout
                                       #'harness-voice-live--stop-timeout)
      (harness-voice-live--refresh))
     (harness-voice-live--state
      (harness-voice-live--pipeline-end 'ended)
      (harness-voice-live--dispose)
      (setq harness-voice-live--state nil
            harness-voice-live--closing nil)
      (harness-voice-live--clear-turn)
      (harness-voice-live--refresh)))
    (let ((buffer harness-voice-live--buffer))
      (when (and (buffer-live-p buffer)
                 (buffer-local-value 'harness-voice-mode buffer))
        (with-current-buffer buffer (harness-voice-mode -1))))))

;;;###autoload
(defun harness-voice-live-use-here ()
  "Point the running live call at this compose box's session or thread."
  (interactive)
  (unless (harness-voice-live--active-p)
    (user-error "Live voice inactive"))
  (unless (harness-voice-live-retarget (current-buffer))
    (user-error "Live voice target unchanged")))

;;;###autoload
(defun harness-voice-live-toggle ()
  "Start a live session, or end the running one."
  (interactive)
  (if (harness-voice-live--active-p)
      (harness-voice-live-stop)
    (harness-voice-live--start-here)))

(defun harness-voice-live--control-note (text)
  "Show control outcome TEXT outside the user/agent dictation stream."
  (setq harness-voice-live--control-status text)
  (harness-voice-live--transcript-section 'control "Control")
  (harness-voice-live--transcript-insert (concat "  " text "\n") 'harness-dim-face)
  (harness-voice-live--refresh))

(defun harness-voice-live--silence-output (&optional provider)
  "Silence the current answer, never capture or work.
PROVIDER means the sidecar already stopped playback; no echo is needed."
  (unless provider
    (harness-voice-live--send
     (list :event "interrupt" :id (cl-incf harness-voice-live--interrupt-seq))))
  (harness-voice-live--acknowledgment-cancel)
  (harness-voice-live--cancel-held-timer)
  (harness-voice-live--pipeline-playback 'interrupted)
  (setq harness-voice-live--output-suppressed t
        harness-voice-live--held nil)
  (unless (memq harness-voice-live--state '(ending failed starting initializing))
    (setq harness-voice-live--state 'listening))
  (harness-voice-live--settle-stage)
  (harness-voice-live--refresh))

(defun harness-voice-live--control-result-text (result)
  "Return exact interface copy for backend control RESULT."
  (pcase (format "%s" (plist-get result :status))
    ("requested" "Cancellation requested")
    ("completed" "Turn completed")
    ("stale" "Cancellation stale")
    (_ "Cancellation unavailable")))

(defun harness-voice-live--agent-control (action)
  "Send ACTION as an audited control, never a fabricated user prompt.
Cancellation requires the identity captured from the watched turn.  A
missing identity is unavailable rather than permission to cancel a newer
turn of the same session.  The backend distinguishes tool capabilities."
  (let ((session (or (plist-get harness-voice-live--delegation :session)
                     harness-voice-live--session))
        (turn harness-voice-live--agent-turn)
        (generation harness-voice-live--route-generation)
        (request (cl-incf harness-voice-live--control-seq)))
    (if (or (not session) (and (equal action "cancel") (not turn)))
        (when (equal action "cancel")
          (harness-voice-live--control-note "Cancellation unavailable"))
      (harness-ui-call
       "_harness/agent/voice-control"
       (list :session-id session :action action :opts (list :turn-id turn))
       (lambda (result)
         (when (and (equal action "cancel")
                    (= request harness-voice-live--control-seq)
                    (= generation harness-voice-live--route-generation)
                    (harness-voice-live--active-p))
           (harness-voice-live--control-note (harness-voice-live--control-result-text result))
           (when (plist-get result :tools)
             (harness-then
              (harness-ui-fetch-tools)
              (lambda (_table)
                (when (and (= request harness-voice-live--control-seq)
                           (= generation harness-voice-live--route-generation)
                           (harness-voice-live--active-p))
                  (harness-voice-live--transcript-section 'control "Control")
                  (dolist (tool (plist-get result :tools))
                    (harness-voice-live--transcript-insert
                     (concat "  "
                             (pcase (format "%s" (plist-get tool :status))
                               ("requested" "Tool cancellation requested")
                               ("completed" "Tool completed")
                               (_ "Tool cancellation unavailable"))
                             " · " (harness-ui-tool-label (plist-get tool :tool)) "\n")
                     'harness-dim-face))))))))
       (lambda (_error)
         (when (and (equal action "cancel")
                    (= request harness-voice-live--control-seq)
                    (= generation harness-voice-live--route-generation)
                    (harness-voice-live--active-p))
           (harness-voice-live--control-note "Cancellation unavailable")))))))

;;;###autoload
(defun harness-voice-live-interrupt ()
  "Silence this answer and keep listening, without cancelling agent work.
The interruption is a control event, never invented user dictation."
  (interactive)
  (unless (harness-voice-live--active-p)
    (user-error "Live voice inactive"))
  (harness-voice-live--silence-output)
  (harness-voice-live--control-note "Playback interrupted")
  (harness-voice-live--agent-control "interrupt"))

;;;###autoload
(defun harness-voice-live-mute ()
  "Mute or unmute the live sidecar microphone."
  (interactive)
  (unless (harness-voice-live--active-p)
    (user-error "Live voice inactive"))
  (setq harness-voice-live--muted (not harness-voice-live--muted))
  (when harness-voice-live--muted
    (harness-voice-live--recovery-drop "muted")
    (harness-voice-live--pending-cancel "cancelled")
    (setq harness-voice-live--speech-active nil
          harness-voice-live--utterance nil
          harness-voice-live--utterance-done nil)
    (harness-voice-live--stage-set 'muted))
  (harness-voice-live--pipeline-muted harness-voice-live--muted)
  (harness-voice-live--send
   (list :event "mute" :on (if harness-voice-live--muted t :false)))
  (when (memq harness-voice-live--stage '(listening muted))
    (harness-voice-live--stage-set (if harness-voice-live--muted 'muted 'listening)))
  (harness-voice-live--refresh))

;;;###autoload
(defun harness-voice-live-cancel ()
  "Silence output and request cancellation of this exact agent turn.
Completed actions are not undone, and tools without supported
cancellation are reported as unavailable, not as stopped."
  (interactive)
  (unless (harness-voice-live--active-p)
    (user-error "Live voice inactive"))
  (harness-voice-live--silence-output)
  (harness-voice-live--agent-control "cancel"))

(defun harness-voice-live--reset ()
  "Stop the sidecar and discard its transcripts, on reload or redaction.
The provider's stopped hook runs even when no process is left -- a
failed session has none -- so a camera grant never outlives the session
it was granted for."
  (harness-voice-live--cancel-pipeline-timer)
  (when (harness-voice-live--active-p)
    (harness-voice-live--dispose))
  (let ((buffer harness-voice-live--buffer))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when harness-voice-mode (setq harness-voice-mode nil)))))
  (setq harness-voice-live--state nil
        harness-voice-live--error nil
        harness-voice-live--notice nil
        harness-voice-live--muted nil
        harness-voice-live--closing nil
        harness-voice-live--camera nil
        harness-voice-live--buffer nil
        harness-voice-live--session nil
        harness-voice-live--route-kind 'session
        harness-voice-live--route-workspace nil
        harness-voice-live--route-thread nil
        harness-voice-live--route-resolved-thread nil
        harness-voice-live--route-name nil
        harness-voice-live--route-generation 0
        harness-voice-live--utterance-routes nil
        harness-voice-live--speaker nil
        harness-voice-live--section nil
        harness-voice-live--stage nil
        harness-voice-live--stage-since nil)
  (harness-voice-live--clear-gate)
  (when (timerp harness-voice-live--pipeline-timer)
    (cancel-timer harness-voice-live--pipeline-timer))
  (when (timerp harness-voice-live--pipeline-stale-timer)
    (cancel-timer harness-voice-live--pipeline-stale-timer))
  (setq harness-voice-live--pipeline-timer nil
        harness-voice-live--pipeline-stale-timer nil
        harness-voice-live--pipeline (harness-voice-pipeline-create 'off)
        harness-voice-live--utterance nil
        harness-voice-live--utterance-done nil
        harness-voice-live--seen (make-hash-table :test 'equal)
        harness-voice-live--held-seq 0)
  (harness-voice-live--clear-turn)
  (when (buffer-live-p harness-voice-live--transcript)
    (kill-buffer harness-voice-live--transcript))
  (setq harness-voice-live--transcript nil))

(provide 'harness-ui-voice-live)
;;; harness-ui-voice-live.el ends here
