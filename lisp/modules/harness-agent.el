;;; harness-agent.el --- The turn loop  -*- lexical-binding: t; -*-

;;; Commentary:

;; One turn: the user's message goes in, the model streams text and
;; thinking, asks for tools, the harness runs them (through the
;; permission chain) and feeds the results back, until the model stops.
;; Providers that run their own loop (hosted) hand each tool call to us
;; through a `:respond' callback; native providers stop with `tool-use'
;; and are called again with the results.  Steering messages sent while
;; a turn runs are delivered once, at the next step boundary: with the
;; next tool result, or as the next user message when the model stops
;; first.  Queued messages wait for the turn to end and then go out
;; together as a turn of their own.
;;
;; A provider may run a tool of its own in place of a harness tool (see
;; `tools/builtin'): Claude Code's web search for web_search, say.  It
;; reports such a call (a `tool-call' event marked `:builtin'), asks the
;; harness whether it may run (`tool-permission', decided by
;; `tools/authorize') and reports its result (`tool-result').  The turn
;; records them as it records the calls it runs, and gives every such
;; call still open a result once the provider is done, since a call
;; without a result breaks the transcript for providers that pair them.
;;
;; The loop is entirely event driven: nothing here waits.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)

(declare-function harness-tool-title "harness-tools")

(defcustom harness-agent-max-steps 200
  "Maximum model calls in one turn before the harness stops it."
  :type 'integer :group 'harness)

(defconst harness-agent--base-system-prompt
  "You are an expert software engineering agent working inside the user's GNU Emacs through the Emacs agent harness.

Work carefully and verify what you do. Prefer the provided tools over guessing; read files before editing them; keep edits minimal and correct. When a tool call is denied, read the reason: it tells you what is permitted, so adjust your approach instead of repeating the call. Stay inside the session's working directory unless told otherwise. When you need a decision only the user can make, use the ask_user tool. Keep answers concise and concrete."
  "First section of every system prompt.")

(defconst harness-agent--cancel-grace 3
  "Seconds to wait for a provider to acknowledge a cancel before forcing it.")

(defconst harness-agent--progress-interval 0.5
  "Seconds between announcements of a running tool's progress.")

(cl-defstruct (harness-agent-turn (:copier nil))
  session-id promise handle (steps 0) cancelled
  steering                              ; pending (:node ID :text TEXT), oldest first
  text-node text-buf think-node think-buf
  (pending 0) waiting-done stop-reason error hosted last-usage started
  ending)                               ; a tool ended the turn (hand_in)

(defvar harness-agent--turns (make-hash-table :test 'equal)
  "Session id -> running `harness-agent-turn'.")

(defun harness-agent-turn-for (session-id)
  "Return the running turn of SESSION-ID or nil."
  (gethash session-id harness-agent--turns))

(defun harness-agent-running-p (session-id)
  "Non-nil while SESSION-ID has a running turn."
  (and (gethash session-id harness-agent--turns) t))

;;;; Activity
;;
;; What a running turn is doing right now, so a UI can say so while
;; nothing else changes: the model may think for minutes without
;; streaming a word, or write a tool call's input, and a tool may run
;; for as long.  The tables live beside the turn records rather than in
;; them, so a reload keeps both working.

(defvar harness-agent--activities (make-hash-table :test 'equal)
  "Session id -> what its running turn is doing (see `agent/activity').")

(defvar harness-agent--calls (make-hash-table :test 'equal)
  "Session id -> the tool calls its turn runs, oldest first.
Each is (CALL-ID :tool NAME :title TITLE :since FLOAT :checking BOOL
:detail TEXT).")

(defvar harness-agent--progress-timers (make-hash-table :test 'equal)
  "Session id -> the timer that announces held-back tool progress.")

(defun harness-agent--compact (plist)
  "Return PLIST without the keys whose value is nil."
  (cl-loop for (k v) on plist by #'cddr when v append (list k v)))

(defun harness-agent--set-activity (sid activity)
  "Record ACTIVITY as what SID's turn does now; announce it when it changed.
ACTIVITY is a plist with `:phase', or nil once the turn is over.  It
keeps the start time of the activity it continues (same phase and
tool) unless it brings its own `:since'."
  (let* ((old (gethash sid harness-agent--activities))
         (new (and activity
                   (append (harness-plist-remove activity :since)
                           (list :since
                                 (or (plist-get activity :since)
                                     (and old (eq (plist-get old :phase) (plist-get activity :phase))
                                          (equal (plist-get old :tool) (plist-get activity :tool))
                                          (plist-get old :since))
                                     (float-time)))))))
    (unless (equal old new)
      (if new
          (puthash sid new harness-agent--activities)
        (remhash sid harness-agent--activities))
      (harness-emit 'agent/activity-changed sid new))))

(defun harness-agent--calls-activity (sid)
  "Return the activity of the tool calls SID's turn runs, or nil if none."
  (when-let* ((calls (gethash sid harness-agent--calls)))
    (let ((oldest (cdar calls)))
      (harness-agent--compact
       (list :phase 'tool
             :tool (plist-get oldest :tool)
             :title (plist-get oldest :title)
             :checking (plist-get oldest :checking)
             :detail (plist-get oldest :detail)
             :count (and (cdr calls) (length calls))
             :since (apply #'min (mapcar (lambda (c) (plist-get (cdr c) :since)) calls)))))))

(defun harness-agent--update-activity (sid &optional activity)
  "Announce what SID's turn does: its running tool calls, else ACTIVITY.
Without either it waits for the model.  Nothing happens once the turn
is over (a tool of a cancelled turn may finish later).  Never signals:
it runs on the turn's own path, between a tool's result and the
provider waiting for it."
  (condition-case err
      (when (gethash sid harness-agent--turns)
        (harness-agent--set-activity
         sid (or (harness-agent--calls-activity sid) activity (list :phase 'waiting))))
    (error (harness-log 'warn "agent: activity of %s: %S" sid err))))

(defun harness-agent--clear-activity (sid)
  "Forget what SID's turn was doing; it has ended.  Never signals."
  (condition-case err
      (progn
        (when-let* ((timer (gethash sid harness-agent--progress-timers)))
          (cancel-timer timer)
          (remhash sid harness-agent--progress-timers))
        (remhash sid harness-agent--calls)
        (harness-agent--set-activity sid nil))
    (error (harness-log 'warn "agent: clearing the activity of %s: %S" sid err))))

(defun harness-agent--add-call (sid call-id name title)
  "Record that SID's turn runs tool call CALL-ID of NAME, labelled TITLE.
It counts as having its permission checked until that is decided."
  (puthash sid (append (gethash sid harness-agent--calls)
                       (list (list call-id :tool name :title title :since (float-time) :checking t)))
           harness-agent--calls))

(defun harness-agent--remove-call (sid call-id)
  "Record that SID's tool call CALL-ID is over."
  (let ((calls (cl-remove call-id (gethash sid harness-agent--calls) :key #'car :test #'equal)))
    (if calls (puthash sid calls harness-agent--calls) (remhash sid harness-agent--calls))))

(defun harness-agent--set-call (sid call-id &rest props)
  "Set PROPS on SID's running tool call CALL-ID; return the call, or nil."
  (when-let* ((call (assoc call-id (gethash sid harness-agent--calls))))
    (cl-loop for (k v) on props by #'cddr
             do (setcdr call (plist-put (cdr call) k v)))
    call))

(defun harness-agent--on-permission-decided (sid request _decision)
  "The call in REQUEST of session SID runs, or is refused, from now on."
  (when-let* ((call (assoc (plist-get request :call-id) (gethash sid harness-agent--calls))))
    (setcdr call (plist-put (plist-put (cdr call) :checking nil) :since (float-time)))
    (harness-agent--update-activity sid)))

(defun harness-agent--progress-line (text)
  "Return the last visible line of tool progress TEXT, or nil.
Terminal colour codes and other control characters go; a progress bar
redrawn with carriage returns gives its latest state."
  (let* ((text (replace-regexp-in-string "\e\\[[0-9;?]*[A-Za-z]" "" (or text "")))
         (lines (split-string text "[\n\r]+" t "[ \t]+"))
         (line (and lines (string-trim (replace-regexp-in-string "[[:cntrl:]]+" " " (car (last lines)))))))
    (unless (or (null line) (string-empty-p line))
      (harness-truncate-end line 80))))

(defun harness-agent--on-tool-progress (sid call-id text)
  "Note progress TEXT from SID's tool call CALL-ID; announce it now and then."
  (when-let* ((call (assoc call-id (gethash sid harness-agent--calls)))
              (line (harness-agent--progress-line text)))
    (setcdr call (plist-put (cdr call) :detail line))
    (unless (gethash sid harness-agent--progress-timers)
      (harness-agent--update-activity sid)
      ;; Further progress within the interval goes out once it is up.
      (puthash sid (run-at-time harness-agent--progress-interval nil
                                (lambda ()
                                  (remhash sid harness-agent--progress-timers)
                                  (when (gethash sid harness-agent--turns)
                                    (harness-agent--update-activity sid))))
               harness-agent--progress-timers))))

(harness-defmethod agent/activity (session-id)
  "Return what SESSION-ID's running turn is doing now, or nil.
The value is a plist (:phase PHASE :since FLOAT ...), `:since' being
when PHASE began.  PHASE is `waiting' (for the model), `thinking',
`writing', `tool-input' (the model writes the input of a call to
`:tool', `:chars' characters so far), `compacting', or `tool': calls
run, the oldest of them `:tool' with `:title', `:checking' while its
permission is decided and `:detail', its latest progress, and
`:count' when several run.  Every change is announced as
`agent/activity-changed'."
  (gethash session-id harness-agent--activities))

;;;; Prompt assembly

(defun harness-agent--system-prompt (session)
  "Return the system prompt for SESSION after the `agent/system-prompt' filter."
  (let ((base (format "%s\n\n## Environment\n- Working directory: %s\n- Project: %s\n- Date: %s\n- System: %s\n- Editor: GNU Emacs %s\n"
                      harness-agent--base-system-prompt
                      (plist-get session :cwd)
                      (or (and (harness-method-exists-p 'project/name)
                               (harness-call 'project/name (plist-get session :project)))
                          (plist-get session :project))
                      (format-time-string "%Y-%m-%d")
                      system-configuration
                      emacs-version)))
    (harness-run-filter 'agent/system-prompt base session)))

(defun harness-agent--vision-p (session)
  (member "image" (plist-get (and (harness-method-exists-p 'provider/model)
                                  (harness-call 'provider/model (plist-get session :model)))
                             :input-modalities)))

(defun harness-agent--file-base64 (path)
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally path)
    (base64-encode-string (buffer-string) t)))

(defun harness-agent--prepare-block (block session)
  "Return BLOCK ready for a provider: images inlined, files described."
  (pcase (plist-get block :type)
    ("image"
     (cond ((plist-get block :data) block)
           ((and (plist-get block :path) (harness-agent--vision-p session)
                 (file-readable-p (plist-get block :path)))
            (list :type "image" :mime (or (plist-get block :mime) "image/png")
                  :data (harness-agent--file-base64 (plist-get block :path))))
           (t (list :type "text" :text (format "[image attached: %s]" (or (plist-get block :path) "clipboard"))))))
    ("audio"
     (if (plist-get block :data) block
       (list :type "text" :text (format "[audio attached: %s]" (plist-get block :path)))))
    ("file"
     (list :type "text"
           :text (format "Attached file: %s (%s bytes)" (plist-get block :path)
                         (or (plist-get block :size) (harness-file-size (plist-get block :path)) "?"))))
    (_ block)))

(defun harness-agent--prepare-messages (session messages)
  (mapcar (lambda (m)
            (if (eq (plist-get m :role) 'user)
                (list :role 'user
                      :content (mapcar (lambda (b) (harness-agent--prepare-block b session))
                                       (plist-get m :content)))
              m))
          messages))

(defun harness-agent--blocks-text (blocks)
  "Return the plain text of BLOCKS for a transcript node."
  (mapconcat (lambda (b)
               (pcase (plist-get b :type)
                 ("text" (plist-get b :text))
                 ("file" (format "@%s" (file-name-nondirectory (or (plist-get b :path) ""))))
                 ("image" "[image]")
                 ("audio" "[audio]")
                 (_ "")))
             blocks " "))

(defun harness-agent--only-text-p (blocks)
  (cl-every (lambda (b) (equal (plist-get b :type) "text")) blocks))

(defun harness-agent--blank-p (block)
  "Non-nil when BLOCK is a text block holding nothing but whitespace."
  (and (equal (plist-get block :type) "text")
       (harness-string-blank-p (plist-get block :text))))

(defun harness-agent--join-texts (blocks)
  "Return BLOCKS with every run of adjacent text blocks joined into one.
Messages sent together stay apart as paragraphs."
  (let (out)
    (dolist (b blocks (nreverse out))
      (if (and (equal (plist-get b :type) "text") out (equal (plist-get (car out) :type) "text"))
          (setcar out (list :type "text" :text (concat (plist-get (car out) :text) "\n\n" (plist-get b :text))))
        (push b out)))))

(defun harness-agent-attachments-to-blocks (attachments)
  "Turn ATTACHMENT plists into content blocks."
  (mapcar (lambda (a)
            (let ((mime (or (plist-get a :mime) "")))
              (cond ((string-prefix-p "image/" mime)
                     (list :type "image" :mime mime :path (plist-get a :path)))
                    ((string-prefix-p "audio/" mime)
                     (list :type "audio" :mime mime :path (plist-get a :path)))
                    (t (list :type "file" :path (plist-get a :path) :size (plist-get a :size)
                             :mime mime :name (plist-get a :name))))))
          attachments))

;;;; Turn start

(defun harness-agent--reanimate (session-id)
  "Resume SESSION-ID when it is inactive, so a message sent to it revives it.
A turn still running in it (it was closed mid-turn) keeps it running."
  (when (eq (plist-get (harness-call 'session/get session-id) :status) 'inactive)
    (harness-call 'session/resume session-id)
    (when (gethash session-id harness-agent--turns)
      (harness-call 'session/set-status session-id 'running))))

(harness-defmethod agent/prompt (session-id blocks &optional opts)
  "Send BLOCKS (content blocks, or a string) to SESSION-ID.
Idle session: start a turn and return a promise of (:stop-reason …).
Running session: steer — the message is recorded now and delivered at
the next step boundary, once; the running turn's promise is returned.
OPTS `:queue' true only queues the message, with OPTS `:attachments',
for the next turn, whatever the session is doing.
An inactive session is resumed first: sending to it brings it back.
Blank text blocks are dropped; a message left empty signals an error,
so no turn, steering message or queued item is ever empty."
  (let* ((blocks (cl-remove-if #'harness-agent--blank-p
                               (if (stringp blocks) (list (list :type "text" :text blocks)) blocks)))
         (queue (harness-json-true-p (plist-get opts :queue)))
         (attachments (and queue (plist-get opts :attachments)))
         (turn (gethash session-id harness-agent--turns)))
    (unless (or blocks attachments)
      (signal 'harness-error (list "Nothing to send: the message is empty")))
    (unless queue
      (harness-agent--reanimate session-id))
    (cond
     (queue
      (harness-call 'session/queue session-id (harness-agent--blocks-text blocks) attachments)
      (harness-resolved (list :queued t)))
     (turn
      (let ((node (harness-call 'session/append session-id
                                (list :kind 'user :content (harness-agent--blocks-text blocks)
                                      :blocks (unless (harness-agent--only-text-p blocks) blocks)
                                      :meta (list :steering t)))))
        (setf (harness-agent-turn-steering turn)
              (append (harness-agent-turn-steering turn)
                      (list (list :node (plist-get node :id) :text (harness-agent--blocks-text blocks))))))
      (harness-emit 'agent/steered session-id)
      (harness-agent-turn-promise turn))
     (t (harness-agent--start session-id blocks)))))

(defun harness-agent--start (session-id blocks)
  (let* ((session (harness-call 'session/get session-id))
         (promise (harness-make-promise))
         (turn (make-harness-agent-turn :session-id session-id :promise promise :started (float-time)))
         (node (list :kind 'user :content (harness-agent--blocks-text blocks)
                     :blocks (unless (harness-agent--only-text-p blocks) blocks))))
    (puthash session-id turn harness-agent--turns)
    ;; The gate runs first so that an automatic compaction lands before
    ;; the user's new message, never after it.
    (harness-then
     (harness-run-filter-async 'agent/before-turn (list :proceed t) session)
     (lambda (gate)
       (when (harness-call 'session/exists-p session-id)
         (harness-call 'session/append session-id node))
       (if (not (plist-get gate :proceed))
           (progn
             (when (plist-get gate :reason)
               (harness-call 'session/hint session-id (format "Turn not started: %s" (plist-get gate :reason))))
             (harness-agent--end turn 'blocked (plist-get gate :reason)))
         (harness-call 'session/set-status session-id 'running)
         (harness-emit 'agent/turn-started session-id)
         (harness-agent--step turn))))
    promise))

;;;; Steps

(defun harness-agent--step (turn)
  "Call the provider once for TURN."
  (let ((sid (harness-agent-turn-session-id turn)))
    (cond
     ((harness-agent-turn-cancelled turn) (harness-agent--end turn 'cancelled))
     ((>= (harness-agent-turn-steps turn) harness-agent-max-steps)
      (harness-call 'session/hint sid (format "Stopped after %d steps" harness-agent-max-steps))
      (harness-agent--end turn 'max-steps))
     ((not (harness-call 'session/exists-p sid)) (harness-agent--end turn 'error "session deleted"))
     (t
      (cl-incf (harness-agent-turn-steps turn))
      ;; Steering still waiting goes out with this request, as the newest
      ;; user message: after a model that stopped, that is what it answers.
      (harness-agent--take-steering turn)
      (setf (harness-agent-turn-text-node turn) nil (harness-agent-turn-text-buf turn) nil
            (harness-agent-turn-think-node turn) nil (harness-agent-turn-think-buf turn) nil
            (harness-agent-turn-pending turn) 0 (harness-agent-turn-waiting-done turn) nil
            (harness-agent-turn-stop-reason turn) nil (harness-agent-turn-error turn) nil)
      (let* ((session (harness-call 'session/get sid))
             (request (list :model (plist-get session :model)
                            :session session
                            :system (harness-agent--system-prompt session)
                            :messages (harness-agent--prepare-messages session (harness-call 'session/messages sid))
                            :tools (if (harness-method-exists-p 'tools/list) (harness-call 'tools/list sid) nil)
                            ;; Tools the provider runs itself, in place of these.
                            :builtin-tools (and (harness-method-exists-p 'tools/builtin)
                                                (harness-call 'tools/builtin sid))
                            :thinking (plist-get session :thinking)
                            :provider-state (plist-get session :provider-state)
                            :on-event (lambda (ev) (harness-agent--on-event turn ev)))))
        (harness-emit 'agent/step-started sid (harness-agent-turn-steps turn))
        (harness-agent--update-activity sid '(:phase waiting))
        (setf (harness-agent-turn-handle turn) (harness-call 'provider/complete request)))))))

(defun harness-agent--take-steering (turn)
  "Deliver the pending steering of TURN: clear it and return its text.
Return nil when nothing is pending.  Every boundary takes it, so a
message is delivered once.  Each one is recorded as delivered after the
newest node that is not one of them, which is where `session/messages'
puts it for the model, rather than where it was sent mid-step."
  (when-let* ((pending (harness-agent-turn-steering turn)))
    (setf (harness-agent-turn-steering turn) nil)
    (condition-case err
        (harness-agent--mark-delivered (harness-agent-turn-session-id turn)
                                       (delq nil (mapcar (lambda (p) (and (consp p) (plist-get p :node)))
                                                         pending)))
      (error (harness-log 'warn "agent: recording delivered steering failed: %S" err)))
    ;; A turn running across a reload may still hold bare texts.
    (mapconcat (lambda (p) (if (stringp p) p (plist-get p :text))) pending "\n\n")))

(defun harness-agent--mark-delivered (sid ids)
  "Mark the steering nodes IDS of session SID as delivered now.
They count as delivered after the newest node that is not one of them;
a node already after it keeps its place and is left untouched."
  (let* ((nodes (and ids (harness-call 'session/nodes sid)))
         (anchor (cl-find-if-not (lambda (n) (member (plist-get n :id) ids)) nodes :from-end t)))
    (when anchor
      (cl-loop for n in nodes
               until (eq n anchor)
               when (member (plist-get n :id) ids)
               do (harness-call 'session/update-node sid (plist-get n :id)
                                :meta (plist-put (copy-sequence (plist-get n :meta))
                                                 :delivered-after (plist-get anchor :id)))))))

(defun harness-agent--on-event (turn ev)
  "Handle EV from TURN's provider; late events of a finished turn are dropped."
  (when (harness-agent--current-p turn)
    (let ((sid (harness-agent-turn-session-id turn)))
      (pcase (plist-get ev :type)
        ('start nil)
        ('activity
         (harness-agent--update-activity
          sid (harness-agent--compact (list :phase (plist-get ev :phase) :tool (plist-get ev :tool)
                                            :chars (plist-get ev :chars)))))
        ('text (harness-agent--stream turn 'assistant (plist-get ev :delta)))
        ('thinking (harness-agent--stream turn 'thinking (plist-get ev :delta)))
        ('tool-call (if (plist-get ev :builtin)
                        (harness-agent--builtin-call turn ev)
                      (harness-agent--tool-call turn ev)))
        ('tool-permission (harness-agent--tool-permission turn ev))
        ;; Hosted loops echo the results of every call; the turn records
        ;; those of the provider's own tools only, having recorded the rest.
        ('tool-result (harness-agent--builtin-result turn ev))
        ('usage
         (setf (harness-agent-turn-last-usage turn) ev)
         (harness-call 'session/usage-add sid
                       (list :input (plist-get ev :input) :output (plist-get ev :output)
                             :cache-read (plist-get ev :cache-read) :cache-write (plist-get ev :cache-write)
                             :cost (plist-get ev :cost) :list-cost (plist-get ev :list-cost)
                             :billing (plist-get ev :billing) :plan (plist-get ev :plan)
                             :context (plist-get ev :context))))
        ('provider-state (harness-call 'session/set-provider-state sid (plist-get ev :state)))
        ('quota (harness-call 'session/runtime sid :quota (plist-get ev :windows))
                (harness-emit 'agent/quota sid (plist-get ev :windows)))
        ('hint (harness-call 'session/hint sid (plist-get ev :text)))
        ('done
         (harness-agent--finalize-live turn)
         ;; The provider's request is over: its own tools report no more.
         (harness-agent--close-builtins turn (plist-get ev :stop-reason))
         (setf (harness-agent-turn-stop-reason turn) (plist-get ev :stop-reason)
               (harness-agent-turn-error turn) (plist-get ev :error)
               (harness-agent-turn-waiting-done turn) t)
         (when (eq (plist-get ev :stop-reason) 'error)
           (harness-call 'session/hint sid (format "Error: %s" (or (plist-get ev :error) "unknown"))))
         (harness-agent--maybe-continue turn))
        (other (harness-log 'debug "agent: unknown provider event %S" other))))))

(defun harness-agent--stream (turn kind delta)
  "Append DELTA of KIND (assistant or thinking) to the live node of TURN.
Whitespace that comes before any visible text is held back and opens
the node together with that text, so a stray newline the model emits
before a tool call never becomes an empty message."
  (when (and delta (not (string-empty-p delta)))
    (let* ((sid (harness-agent-turn-session-id turn))
           (thinking (eq kind 'thinking))
           (phase (if thinking 'thinking 'writing)))
      (unless (eq phase (plist-get (gethash sid harness-agent--activities) :phase))
        (harness-agent--update-activity sid (list :phase phase)))
      ;; Switching between thinking and text closes the other live node.
      (harness-agent--finalize turn (if thinking 'assistant 'thinking))
      (let ((node-id (if thinking (harness-agent-turn-think-node turn) (harness-agent-turn-text-node turn)))
            (buf (concat (if thinking (harness-agent-turn-think-buf turn) (harness-agent-turn-text-buf turn))
                         delta)))
        (if thinking (setf (harness-agent-turn-think-buf turn) buf) (setf (harness-agent-turn-text-buf turn) buf))
        (cond
         (node-id
          (harness-call 'session/update-node sid node-id :content buf :transient t)
          (harness-emit 'agent/stream sid node-id kind delta))
         ;; Only whitespace so far: held back.
         ((string-blank-p buf))
         (t
          (setq node-id (plist-get (harness-call 'session/append sid (list :kind kind :content buf)) :id))
          (if thinking
              (setf (harness-agent-turn-think-node turn) node-id)
            (setf (harness-agent-turn-text-node turn) node-id))
          ;; The node's first chunk is all it opened with.
          (harness-emit 'agent/stream sid node-id kind buf)))))))

(defun harness-agent--finalize (turn kind)
  "Write the live node of KIND (assistant or thinking) of TURN for good.
Whitespace held back for a node that never got visible text is dropped."
  (let* ((sid (harness-agent-turn-session-id turn))
         (thinking (eq kind 'thinking))
         (node-id (if thinking (harness-agent-turn-think-node turn) (harness-agent-turn-text-node turn)))
         (buf (if thinking (harness-agent-turn-think-buf turn) (harness-agent-turn-text-buf turn))))
    (when node-id
      (harness-call 'session/update-node sid node-id :content (or buf "")
                    :meta (list :model (plist-get (harness-call 'session/get sid) :model)
                                :usage (and (not thinking) (harness-agent-turn-last-usage turn)))))
    (if thinking
        (setf (harness-agent-turn-think-node turn) nil (harness-agent-turn-think-buf turn) nil)
      (setf (harness-agent-turn-text-node turn) nil (harness-agent-turn-text-buf turn) nil))))

(defun harness-agent--finalize-live (turn)
  (harness-agent--finalize turn 'thinking)
  (harness-agent--finalize turn 'assistant))

(defun harness-agent--with-steering (turn content)
  "Return tool result CONTENT carrying the pending steering of TURN.
The result is a step boundary, so this delivers that steering: a hosted
loop reads it in the content, a native one with its next request."
  (let ((steer (harness-agent--take-steering turn)))
    (if steer
        (concat content "\n\n<user_message>\n" steer "\n</user_message>")
      content)))

(defun harness-agent--tool-call (turn ev)
  (let* ((sid (harness-agent-turn-session-id turn))
         (name (plist-get ev :name)) (input (plist-get ev :input))
         (call-id (or (plist-get ev :id) (harness-short-id)))
         (respond (plist-get ev :respond))
         (started (float-time)))
    (harness-agent--finalize-live turn)
    (setf (harness-agent-turn-hosted turn) (and respond t))
    (cl-incf (harness-agent-turn-pending turn))
    (let ((node (harness-call 'session/append sid
                              (list :kind 'tool-call :tool name :call-id call-id :input input
                                    :title (if (fboundp 'harness-tool-title) (harness-tool-title name input) name))))
          (execution nil))
      (harness-emit 'agent/tool-call sid node)
      ;; Recorded before it starts, so its permission decision finds it.
      (harness-agent--add-call sid call-id name (plist-get node :title))
      (setq execution (harness-call-async 'tools/execute sid (list :id call-id :name name :input input)))
      (harness-agent--update-activity sid)
      (harness-then
       execution
       (lambda (result)
         ;; Before `respond': sending the result can run the provider's
         ;; process filter, whose news must not hide behind this call.
         (harness-agent--remove-call sid call-id)
         (harness-agent--update-activity sid)
         (condition-case err
             (let* ((rnode (harness-call 'session/append sid
                                         (list :kind 'tool-result :call-id call-id
                                               :output (plist-get result :content)
                                               :is-error (plist-get result :is-error)
                                               :attachments (plist-get result :attachments)
                                               :meta (list :duration (- (float-time) started)
                                                           :denied (plist-get result :denied)
                                                           :truncated (plist-get result :truncated)))))
                    (content (harness-agent--with-steering turn (plist-get result :content))))
               (harness-emit 'agent/tool-result sid rnode)
               (when respond
                 (funcall respond (list :content content :is-error (plist-get result :is-error)))))
           (error
            (harness-log 'error "agent: recording result of %s failed: %S" name err)
            (when respond
              (funcall respond (list :content (plist-get result :content)
                                     :is-error (plist-get result :is-error))))))
         (cl-decf (harness-agent-turn-pending turn))
         (if (plist-get result :end-turn)
             ;; A tool finished the work (`hand_in'): no step may follow.
             (harness-agent--finish-turn turn)
           (harness-agent--maybe-continue turn)))
       (lambda (err)
         (harness-agent--remove-call sid call-id)
         (harness-agent--update-activity sid)
         (let ((msg (format "Tool %s failed: %s" name (harness-error-message err))))
           (ignore-errors
             (harness-call 'session/append sid (list :kind 'tool-result :call-id call-id :output msg :is-error t)))
           (let ((content (harness-agent--with-steering turn msg)))
             (when respond (funcall respond (list :content content :is-error t))))
           (cl-decf (harness-agent-turn-pending turn))
           (harness-agent--maybe-continue turn)))))))

;;;; Tools the provider runs itself

(defun harness-agent--current-p (turn)
  "Non-nil while TURN is its session's running turn."
  (eq (gethash (harness-agent-turn-session-id turn) harness-agent--turns) turn))

(defun harness-agent--builtin-call (turn ev)
  "Record the call EV of a tool that TURN's provider runs itself.
EV names the harness tool the provider's tool stands in for.  The call
runs, as far as the turn shows, until the provider reports its result
or is done."
  (let ((sid (harness-agent-turn-session-id turn))
        (name (plist-get ev :name))
        (input (plist-get ev :input))
        (call-id (or (plist-get ev :id) (harness-short-id))))
    (when (and (harness-agent--current-p turn)
               (not (assoc call-id (gethash sid harness-agent--calls))))
      (harness-agent--finalize-live turn)
      (let ((node (harness-call 'session/append sid
                                (list :kind 'tool-call :tool name :call-id call-id :input input
                                      :title (if (fboundp 'harness-tool-title) (harness-tool-title name input) name)
                                      :meta (list :builtin t)))))
        (harness-emit 'agent/tool-call sid node)
        (harness-agent--add-call sid call-id name (plist-get node :title))
        ;; Nothing checks its permission until the provider asks.
        (harness-agent--set-call sid call-id :checking nil :builtin t :started (float-time))
        (harness-agent--update-activity sid)))))

(defun harness-agent--tool-permission (turn ev)
  "Decide whether the call EV of a tool TURN's provider runs itself may run.
The harness's permission chain decides it as a call of the harness tool
it stands in for (`tools/authorize'), and EV's `:respond' gets the
DECISION: (:behavior allow ...), or (:behavior deny :message TEXT ...)
where TEXT is what the model is told.  A call EV the turn has not
recorded yet is recorded first."
  (let* ((sid (harness-agent-turn-session-id turn))
         (call-id (plist-get ev :id))
         (respond (plist-get ev :respond))
         (answer (lambda (decision)
                   (when respond
                     (condition-case err
                         (funcall respond decision)
                       (error (harness-log 'error "agent: answering the permission of %s failed: %S"
                                           call-id err))))))
         (refuse (lambda (reason)
                   (funcall answer (list :behavior 'deny :reason reason :message (concat "Denied: " reason))))))
    (cond
     ((not (harness-agent--current-p turn)) (funcall refuse "the turn is over"))
     ((not (harness-method-exists-p 'tools/authorize)) (funcall refuse "no permission handler answered"))
     (t
      (unless (assoc call-id (gethash sid harness-agent--calls))
        (harness-agent--builtin-call turn ev))
      (harness-agent--set-call sid call-id :checking t)
      (harness-agent--update-activity sid)
      (harness-then
       (harness-call-async 'tools/authorize sid
                           (list :id call-id :name (plist-get ev :name) :input (plist-get ev :input)
                                 :kind (plist-get ev :kind)))
       (lambda (decision)
         (harness-agent--set-call sid call-id :checking nil
                                  :denied (not (eq (plist-get decision :behavior) 'allow)))
         (harness-agent--update-activity sid)
         (funcall answer decision))
       (lambda (err)
         (harness-agent--set-call sid call-id :checking nil :denied t)
         (harness-agent--update-activity sid)
         (funcall refuse (format "the permission check failed: %s" (harness-error-message err)))))))))

(defun harness-agent--record-builtin-result (sid call output is-error &optional meta)
  "Record OUTPUT as the result of SID's running built-in CALL and end it.
IS-ERROR marks a failed call; META is added to the node's meta."
  (harness-agent--remove-call sid (car call))
  (let ((node (harness-call 'session/append sid
                            (list :kind 'tool-result :call-id (car call)
                                  :output (if (stringp output) output (format "%s" (or output "")))
                                  :is-error (and is-error t)
                                  :meta (append (list :builtin t
                                                      :duration (- (float-time)
                                                                   (or (plist-get (cdr call) :started) (float-time))))
                                                (and (plist-get (cdr call) :denied) (list :denied t))
                                                meta)))))
    (harness-emit 'agent/tool-result sid node)
    (harness-agent--update-activity sid)
    node))

(defun harness-agent--builtin-result (turn ev)
  "Record the result EV of a call that TURN's provider ran itself.
Results of the calls the harness ran, which the turn recorded when it
ran them, and of calls it never heard of are left alone."
  (let* ((sid (harness-agent-turn-session-id turn))
         (call (and (harness-agent--current-p turn)
                    (assoc (plist-get ev :id) (gethash sid harness-agent--calls)))))
    (when (and call (plist-get (cdr call) :builtin))
      (harness-agent--record-builtin-result sid call (plist-get ev :content) (plist-get ev :is-error)))))

(defun harness-agent--close-builtins (turn reason)
  "Give each built-in call of TURN still running a result: it got none.
REASON is why the provider stopped (`cancelled', say)."
  (let ((sid (harness-agent-turn-session-id turn)))
    (when (harness-agent--current-p turn)
      (dolist (call (gethash sid harness-agent--calls))
        (when (plist-get (cdr call) :builtin)
          (condition-case err
              (harness-agent--record-builtin-result
               sid call
               (if (eq reason 'cancelled)
                   "Cancelled before this call returned a result."
                 "The provider stopped before this call returned a result.")
               t (list :interrupted t))
            (error (harness-log 'warn "agent: closing built-in call %s failed: %S" (car call) err)
                   (harness-agent--remove-call sid (car call)))))))))

(defun harness-agent--finish-turn (turn)
  "End TURN cleanly as a tool asked, and stop its provider.
The provider may still be streaming when a tool hands the work in
(`:end-turn' on its result): the turn ends with `end-turn' as if the
model had stopped itself, and no further step follows.  The provider
is cancelled first, so it drops whatever it kept for a next step -- a
scripted provider's remaining script -- which this turn will not take;
marking the turn ending keeps the provider's own news of that cancel
from ending it as `cancelled' instead.  The transcript keeps
everything recorded so far."
  (setf (harness-agent-turn-ending turn) t)
  (when-let* ((handle (harness-agent-turn-handle turn)))
    (ignore-errors (funcall (plist-get handle :cancel))))
  (harness-agent--end turn 'end-turn))

(defun harness-agent--maybe-continue (turn)
  "Decide what happens once the provider is done and no tools are running."
  (when (and (harness-agent-turn-waiting-done turn)
             (not (harness-agent-turn-ending turn))
             (zerop (harness-agent-turn-pending turn)))
    (setf (harness-agent-turn-waiting-done turn) nil)
    (let ((sid (harness-agent-turn-session-id turn))
          (reason (harness-agent-turn-stop-reason turn)))
      (pcase reason
        ;; A model that stopped with steering still waiting gets it as its
        ;; next user message: one more step, which takes the steering.
        ((or 'tool-use (and 'end-turn (guard (harness-agent-turn-steering turn))))
         (if (harness-agent-turn-cancelled turn)
             (harness-agent--end turn 'cancelled)
           (harness-then
            (harness-run-filter-async 'agent/step (list :proceed t) (harness-call 'session/get sid))
            (lambda (gate)
              (if (plist-get gate :proceed)
                  (harness-agent--step turn)
                (when (plist-get gate :reason) (harness-call 'session/hint sid (plist-get gate :reason)))
                (harness-agent--end turn 'blocked (plist-get gate :reason)))))))
        ('end-turn (harness-agent--end turn 'end-turn))
        ('max-tokens (harness-call 'session/hint sid "The model hit its output limit.")
                     (harness-agent--end turn 'max-tokens))
        ('cancelled (harness-agent--end turn 'cancelled))
        ('error (harness-agent--end turn 'error (harness-agent-turn-error turn)))
        (_ (harness-agent--end turn (or reason 'end-turn)))))))

(defun harness-agent--end (turn reason &optional error)
  (let ((sid (harness-agent-turn-session-id turn)))
    (when (eq (gethash sid harness-agent--turns) turn)
      ;; A turn cancelled before its provider was done.
      (when (harness-call 'session/exists-p sid)
        (harness-agent--close-builtins turn reason))
      (remhash sid harness-agent--turns)
      (harness-agent--clear-activity sid)
      (when (harness-call 'session/exists-p sid)
        (harness-call 'session/usage-add sid (list :turns 1))
        (let ((session (harness-call 'session/get sid)))
          (unless (eq (plist-get session :status) 'inactive)
            (harness-call 'session/set-status sid (if (plist-get session :pending) 'blocked 'idle)))))
      (harness-emit 'agent/turn-ended sid reason)
      (harness-resolve (harness-agent-turn-promise turn)
                       (list :stop-reason reason :error error
                             :duration (- (float-time) (harness-agent-turn-started turn))))
      (when (and (eq reason 'end-turn)
                 (harness-call 'session/exists-p sid)
                 (plist-get (harness-call 'session/get sid) :queue))
        (harness-run-soon #'harness-agent--send-queued sid)))))

(defun harness-agent--send-queued (session-id)
  "Send the queue of SESSION-ID as a turn of its own, after a turn ended.
A turn that started meanwhile sends it when it ends instead: sent into
a running turn, the queued messages would steer it."
  (when (and (harness-call 'session/exists-p session-id)
             (not (harness-agent-running-p session-id)))
    (harness-catch (harness-call-async 'agent/send-queue session-id)
                   (lambda (err)
                     (harness-log 'warn "agent: sending the queue of %s failed: %s"
                                  session-id (harness-error-message err))))))

;;;; Cancel and queue

(harness-defmethod agent/cancel (session-id)
  "Cancel the running turn of SESSION-ID, if any."
  (let ((turn (gethash session-id harness-agent--turns)))
    (when turn
      (setf (harness-agent-turn-cancelled turn) t)
      (let ((cancel (plist-get (harness-agent-turn-handle turn) :cancel)))
        (when cancel (ignore-errors (funcall cancel))))
      (run-at-time harness-agent--cancel-grace nil
                   (lambda () (when (eq (gethash session-id harness-agent--turns) turn)
                                (harness-agent--finalize-live turn)
                                (harness-agent--end turn 'cancelled))))
      t)))

(harness-defmethod agent/send-queue (session-id)
  "Send every queued message of SESSION-ID as one turn; return its promise.
Items with neither text nor attachments are dropped.  With nothing to
send no turn starts and the promise resolves to (:stop-reason
nothing-queued).  While a turn runs the messages steer it, like any
message sent then."
  (let* ((items (harness-call 'session/queue-take session-id))
         (blocks (harness-agent--join-texts
                  (cl-loop for it in items
                           append (append (unless (harness-string-blank-p (plist-get it :text))
                                            (list (list :type "text" :text (plist-get it :text))))
                                          (harness-agent-attachments-to-blocks (plist-get it :attachments)))))))
    (if (null blocks)
        (harness-resolved (list :stop-reason 'nothing-queued))
      (harness-call 'agent/prompt session-id blocks))))

(harness-defmethod agent/running (&optional session-id)
  "Return running session ids, or non-nil when SESSION-ID is running."
  (if session-id
      (harness-agent-running-p session-id)
    (let (out) (maphash (lambda (k _) (push k out)) harness-agent--turns) out)))

(dolist (ev '((agent/turn-started . "(SESSION-ID)") (agent/turn-ended . "(SESSION-ID REASON)")
              (agent/step-started . "(SESSION-ID STEP)")
              (agent/stream . "(SESSION-ID NODE-ID KIND DELTA)")
              (agent/tool-call . "(SESSION-ID NODE)") (agent/tool-result . "(SESSION-ID NODE)")
              (agent/steered . "(SESSION-ID)") (agent/quota . "(SESSION-ID WINDOWS)")
              (agent/activity-changed
               . "(SESSION-ID ACTIVITY) when what a running turn does changes; ACTIVITY nil once it ends (see `agent/activity')")))
  (harness-declare-event (car ev) (cdr ev)))

;;;; Exit

(defun harness-agent--save-live ()
  "Write the text that running turns have streamed so far.
Streaming updates are not written one by one, so a harness exiting
mid-turn would otherwise keep only the first chunk of the message it
was receiving."
  (maphash (lambda (_ turn)
             (condition-case err
                 (harness-agent--finalize-live turn)
               (error (harness-log 'warn "agent: saving a streamed message failed: %S" err))))
           harness-agent--turns))

(defun harness-agent--init ()
  "Save streamed text when Emacs exits; follow tool calls (idempotent)."
  (add-hook 'kill-emacs-hook #'harness-agent--save-live)
  (harness-on 'permission/decided #'harness-agent--on-permission-decided)
  (harness-on 'tools/progress #'harness-agent--on-tool-progress))

(harness-define-module 'agent
  :doc "The turn loop: prompt, stream, run tools, steer, queue."
  :requires '(session provider tools)
  :init #'harness-agent--init
  :shutdown #'harness-agent--save-live)

;; A reload does not initialise a running module again: subscribe the
;; handlers this version adds now.
(when (harness-module-ready-p 'agent)
  (harness-agent--init))

(provide 'harness-agent)
;;; harness-agent.el ends here
