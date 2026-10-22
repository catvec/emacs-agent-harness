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
;; first.  Until then the user can take one back (`agent/withdraw').
;; Queued messages wait for the turn to end and then go out
;; together as a turn of their own.  A message is delivered when it
;; starts a turn or steers one, a queued one when its queue goes out;
;; then, and only then, the `agent/message' filters see it and may
;; change it (task mode sends a task waiting for review back this way).
;; A model that stops on its own, with nothing steering, is not let go
;; at once: the `agent/stop' filters may answer it with a message of the
;; harness's and a step more, a few times at most (`harness-agent--stopped').
;;
;; A tool result may carry pictures for the model (`:images', as read_file
;; on an image gives): a hosted loop is handed them with the result, a
;; native one reads them from the transcript with its next request, and
;; only a model that reads images is sent any (see "Images tools return").
;; The images a steering message attached go the same way: a hosted loop
;; gets them with the tool result that carries the message's text, each
;; after its token ([image 1]), and a native one with the message itself
;; in its next request (see `harness-agent--with-steering').
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
(declare-function harness-tools-tail-line "harness-tools" (text))

(defconst harness-agent--base-system-prompt
  "You are an expert software engineering agent working inside the user's GNU Emacs through the Emacs agent harness.

Work carefully and verify what you do. Prefer the provided tools over guessing; read files before editing them; keep edits minimal and correct. When a tool call is denied, read the reason: it tells you what is permitted, so adjust your approach instead of repeating the call. Keep the full output of a command whose detail you may need again -- a test run, a build -- in a log file and read that log, rather than piping it through grep or tail and running the command again. Stay inside the session's working directory unless told otherwise. When you need a decision only the user can make, use the ask_user tool. Keep answers concise and concrete."
  "First section of every system prompt.")

(defconst harness-agent--cancel-grace 3
  "Seconds to wait for a provider to acknowledge a cancel before forcing it.")

(defconst harness-agent--progress-interval 0.5
  "Seconds between announcements of a running tool's progress.")

(defconst harness-agent--max-error-retries 8
  "Most times one turn runs a failed step again for `agent/step-error'.
Each retry follows a handler's verdict that another try can work (the
fallback module moves the session to another provider first), so a
handful covers every provider of a fallback list; the cap only keeps a
handler that is wrong from looping.")

(defconst harness-agent--max-stop-continues 3
  "Most times one turn is sent on after its model stopped, for `agent/stop'.
Each time a handler had the stop answered with a message of the
harness's and one more step; the cap only keeps a handler that is
wrong, or a model that stops again whatever it is told, from looping.")

(defconst harness-agent--handoff-max-chars 120000
  "Most characters of transcript a handoff to a hosted loop carries.
About 30k tokens: enough for the turns a provider missed while another
one worked, without filling its context; the oldest go first.")

(defconst harness-agent--handoff-item-chars 4000
  "Most characters of one message, tool call or result in a handoff.")

(defcustom harness-agent-history-images 16
  "How many of the newest images that tools returned a request carries.
A model that reads images sees the pictures a tool returned (an image
read_file read, say), and a provider whose loop the harness runs is sent
the whole conversation again at every step, those pictures with it.  So
only the newest this many go with a request.  When there are more, the
oldest are left out in chunks of half this many: the request then stays
the same from one step to the next until the next chunk goes, and the
provider's prompt cache with it.  The result of a call whose image was
left out says so, and the model can read the file again.  nil keeps
every one."
  :type '(choice (integer :tag "Newest images kept") (const :tag "All of them" nil))
  :safe (lambda (v) (or (null v) (natnump v)))
  :group 'harness)

(defconst harness-agent--image-mimes '("image/png" "image/jpeg" "image/gif" "image/webp")
  "The media types of the images a tool result can hand a model.
They are what the providers take as an image of a tool result.")

(defconst harness-agent--no-vision-note
  "\n\n[This model does not read images: only the user sees this one.]"
  "Added to a tool result whose image goes to a model that cannot read it.")

(defconst harness-agent--image-dropped-note
  "\n\n[The image this call returned is no longer attached, to keep the request small; read the file again to see it.]"
  "Added to a tool result whose image `harness-agent-history-images' left out.")

(defconst harness-agent--inline-reply-note
  "[This message answers yours inline: each line that starts with \"> \" quotes a part of your earlier message, and the lines under it are the user's answer to that part.  Answer the same way: quote the part you answer with \"> \", keeping the quotes that are already there, and write your answer under it, so the thread reads in order.]"
  "Added to a user message that answers the model inline.
Only the model reads it; the transcript keeps the message as the user
wrote it (`harness-agent--inline-reply-p').")

(defun harness-agent--inline-reply-p (blocks)
  "Non-nil when BLOCKS, a user message, answers the model inline.
That is a line of the message from \"> \" on with, further down, a line
of its own: the user's answer under the part it quotes.  A message that
only quotes -- a region prompt, a selection pasted in -- has no such
line, and is not answered inline."
  (let ((quoted nil))
    (catch 'found
      (dolist (block blocks)
        (when (equal (plist-get block :type) "text")
          (dolist (line (split-string (or (plist-get block :text) "") "\n"))
            (cond ((string-match-p "\\`[ \t]*>" line) (setq quoted t))
                  ((and quoted (not (string-blank-p line))) (throw 'found t))))))
      nil)))

(defun harness-agent--image-gone-note (path)
  "Return what a tool result says of its image, the file at PATH, once unreadable."
  (format "\n\n[The image this call returned (%s) is gone; read the file again to see it.]" path))

(defconst harness-agent--steering-no-vision-note
  "\n\n[This model does not read images: only the user sees the images their message attached.]"
  "Added after a steering message whose images go to a model that cannot read them.")

(defun harness-agent--steering-image-note (image why)
  "Return what a tool result says of IMAGE, a steering message's, that did not go.
WHY says what stopped it."
  (let ((label (harness-agent--image-label image)))
    (format "\n\n[The image %sthe user attached could not be sent: %s.]"
            (if label (format "[%s] " label) "") why)))

(cl-defstruct (harness-agent-turn (:copier nil))
  session-id promise handle (steps 0) cancelled
  steering                              ; pending (:node ID :text TEXT [:images IMAGES]), oldest first
  text-node text-buf think-node think-buf
  step-nodes                            ; the nodes this step wrote, for a retry
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

(defmacro harness-agent--try (what &rest body)
  "Run BODY; when it signals, log that WHAT failed, short, and return nil.
WHAT, a text such as \"recording result of bash\", is evaluated only
then.  The error is quoted short (`harness-error-short-message'): it can
carry the whole text that failed, a tool's output of megabytes among
it, which must not be repeated in the log.  For the steps of a turn
that must not hold up the ones after them -- recording a tool result
before the provider is sent it, say."
  (declare (indent 1) (debug (form body)))
  (let ((err (make-symbol "err")))
    `(condition-case ,err
         (progn ,@body)
       (error (harness-log 'error "agent: %s failed: %s" ,what (harness-error-short-message ,err))
              nil))))

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
:detail TEXT :note TEXT).  `:detail' is the latest progress line the
tool reported (`tools/progress'), `:note' the note it shows under its
call (`tools/note').")

(defvar harness-agent--progress-timers (make-hash-table :test 'equal)
  "Session id -> the timer that announces held-back tool progress.")

(defvar harness-agent--step-models (make-hash-table :test 'equal)
  "Session id -> the model its running turn's current step was sent to.
The session's model may change while a step runs (it applies from the
next step), so what the step writes names this one.  Kept beside the
turn records, as the activity tables are.")

(defvar harness-agent--failures (make-hash-table :test 'equal)
  "Session id -> the failure of its running turn's last step, if it failed.
The `done' event's keys (`:error' `:error-kind' `:resets' ...) plus the
`:model' and `:step' it ran on; read when the turn decides what follows.
Kept beside the turn records, so a reload keeps the turns working.")

(defvar harness-agent--retries (make-hash-table :test 'equal)
  "Session id -> how many failed steps its running turn ran again.")

(defvar harness-agent--stop-continues (make-hash-table :test 'equal)
  "Session id -> how many times its running turn was sent on past a stop.
Counted against `harness-agent--max-stop-continues'.  Kept beside the
turn records, as the retries are, so a reload keeps the turns working.")

(defvar harness-agent--last-requests (make-hash-table :test 'equal)
  "Session id -> the request of the latest step of its running turn.
Without its `:on-event'.  The step that follows a tool call starts with
what this request ended with, so sending this one again reads the
prompt cache the tool's wait is letting lapse (harness-cache-warm.el).
Kept while the turn runs and dropped when it ends, beside the turn
records, as the activity tables are.")

(defun harness-agent-last-request (session-id)
  "Return the request of the latest step of SESSION-ID's running turn, or nil.
Nothing but the request: no `:on-event'.  The caller must not change it."
  (gethash session-id harness-agent--last-requests))

(defvar harness-agent--open-nodes (make-hash-table :test 'equal)
  "Session id -> the text or thinking node its turn wrote last, until a tool call.
A provider `checkpoint' event without a call id belongs to that node.
Kept beside the turn records, as the activity tables are.")

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

(defun harness-agent--call-activity (call)
  "Return what the running tool CALL, of `harness-agent--calls', shows the UI.
The plist carries the call's id, so a chat can put its note under the
call's own block, and its latest progress line and note."
  (let ((props (cdr call)))
    (harness-agent--compact
     (list :call-id (car call)
           :tool (plist-get props :tool)
           :title (plist-get props :title)
           :checking (plist-get props :checking)
           :detail (plist-get props :detail)
           :note (plist-get props :note)
           :since (plist-get props :since)))))

(defun harness-agent--calls-activity (sid)
  "Return the activity of the tool calls SID's turn runs, or nil if none.
The oldest call is the activity itself, as before; `:calls' carries
every one of them, each as `harness-agent--call-activity' returns it,
so a UI can attach a note to the block of the call it belongs to."
  (when-let* ((calls (gethash sid harness-agent--calls)))
    (let ((oldest (cdar calls)))
      (harness-agent--compact
       (list :phase 'tool
             :tool (plist-get oldest :tool)
             :title (plist-get oldest :title)
             :checking (plist-get oldest :checking)
             :detail (plist-get oldest :detail)
             :count (and (cdr calls) (length calls))
             :calls (mapcar #'harness-agent--call-activity calls)
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
        (remhash sid harness-agent--open-nodes)
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
  (harness-tools-tail-line text))

(defun harness-agent--announce-progress (sid)
  "Announce SID's activity now, and once more when the interval is up.
Further changes within `harness-agent--progress-interval' go out once it
is up, so a chatty tool does not redraw the line for every chunk."
  (unless (gethash sid harness-agent--progress-timers)
    (harness-agent--update-activity sid)
    ;; Further progress within the interval goes out once it is up.
    (puthash sid (run-at-time harness-agent--progress-interval nil
                              (lambda ()
                                (remhash sid harness-agent--progress-timers)
                                (when (gethash sid harness-agent--turns)
                                  (harness-agent--update-activity sid))))
             harness-agent--progress-timers)))

(defun harness-agent--on-tool-progress (sid call-id text)
  "Note progress TEXT from SID's tool call CALL-ID; announce it now and then."
  (when-let* ((call (assoc call-id (gethash sid harness-agent--calls)))
              (line (harness-agent--progress-line text)))
    (setcdr call (plist-put (cdr call) :detail line))
    (harness-agent--announce-progress sid)))

(defun harness-agent--on-tool-note (sid call-id text)
  "Note TEXT, the note under SID's tool call CALL-ID.
The note is kept on the call, which the activity carries with the
running call (`agent/activity' `:calls'), so the chat draws it under
the call's block; it goes when the call ends.  Announcements are held
back as progress is, so a tool that writes often does not redraw it for
every line, and a multiline note travels whole."
  (when-let* ((call (assoc call-id (gethash sid harness-agent--calls)))
              (text (and (stringp text) (not (harness-string-blank-p text))
                         (string-trim text))))
    (setcdr call (plist-put (cdr call) :note text))
    (harness-agent--announce-progress sid)))

(harness-defmethod agent/activity (session-id)
  "Return what SESSION-ID's running turn is doing now, or nil.
The value is a plist (:phase PHASE :since FLOAT ...), `:since' being
when PHASE began.  PHASE is `waiting' (for the model), `thinking',
`writing', `tool-input' (the model writes the input of a call to
`:tool', `:chars' characters so far), `compacting', or `tool': calls
run, the oldest of them `:tool' with `:title', `:checking' while its
permission is decided and `:detail', its latest progress, and `:count'
when several run.  A `tool' phase also carries `:calls', one plist per
running call (:call-id, :tool, :title, :detail, :note and :since), the
`:note' being what the call shows under its own block in a chat.
Every change is announced as `agent/activity-changed'."
  (gethash session-id harness-agent--activities))

(harness-defmethod agent/note-activity (session-id activity)
  "Announce ACTIVITY as what SESSION-ID's turn does, before the turn starts.
For an `agent/before-turn' gate that works first, such as the cold
cache's compaction (harness-cowboy.el): ACTIVITY is a plist as
`agent/activity' returns, say (:phase compacting).  Nothing happens
when SESSION-ID has no turn; the turn's own activity replaces it once
it starts, and its end clears it."
  (harness-agent--update-activity session-id activity)
  nil)

;;;; Prompt assembly

(defconst harness-agent--tmp-dir-line
  "- Temporary directory: %s (yours alone and already allowed, bash included: put scratch files, logs and screenshots there rather than in the working directory or /tmp)\n"
  "System prompt line naming the session's own temporary directory (%s).
It steers scratch files there: inside the sandbox /tmp is private to
each command and starts empty, so a file a command leaves there is gone
by the next call, and outside the sandbox /tmp is not an allowed
directory.")

(defun harness-agent--tmp-dir (session)
  "Return SESSION's own temporary directory, made if missing, or nil."
  (let ((id (plist-get session :id)))
    (and id (harness-method-exists-p 'session/tmp-dir)
         (condition-case err
             (harness-call 'session/tmp-dir id)
           (error (harness-log 'debug "agent: no temporary directory for %s: %s"
                               id (harness-error-message err))
                  nil)))))

(defun harness-agent--system-prompt (session)
  "Return the system prompt for SESSION after the `agent/system-prompt' filter.
Its Environment section names the session's own temporary directory,
made here when it is missing (see `session/tmp-dir'), so the directory
the model is told about exists when it reads about it."
  (let* ((tmp (harness-agent--tmp-dir session))
         (base (format "%s\n\n## Environment\n- Working directory: %s\n%s- Project: %s\n- Date: %s\n- System: %s\n- Editor: GNU Emacs %s\n"
                      harness-agent--base-system-prompt
                      (plist-get session :cwd)
                      (if tmp (format harness-agent--tmp-dir-line tmp) "")
                      (or (and (harness-method-exists-p 'project/name)
                               (harness-call 'project/name (plist-get session :project)))
                          (plist-get session :project))
                      (format-time-string "%Y-%m-%d")
                      system-configuration
                      emacs-version)))
    (harness-run-filter 'agent/system-prompt base session)))

(defun harness-agent--vision-p (session)
  "Non-nil when SESSION's model reads images.
That is when `provider/model' lists \"image\" in its `:input-modalities'."
  (member "image" (plist-get (and (harness-method-exists-p 'provider/model)
                                  (harness-call 'provider/model (plist-get session :model)))
                             :input-modalities)))

(defun harness-agent--file-base64 (path)
  "Return the bytes of file PATH encoded in base64, on one line."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally path)
    (base64-encode-string (buffer-string) t)))

(defun harness-agent--prepare-block (block session)
  "Return BLOCK ready for SESSION's provider: images inlined, files described.
An image file is inlined only when SESSION's model reads images; else a
text block names it.  A tool_result block whose call returned images
gets them the same way (`harness-agent--prepare-result'); any other is
returned as it is."
  (pcase (plist-get block :type)
    ;; What marks the text of an attachment is for the transcript.
    ("text" (if (plist-member block :attached)
                (list :type "text" :text (plist-get block :text))
              block))
    ("image"
     (cond ((plist-get block :data) block)
           ((and (plist-get block :path) (harness-agent--vision-p session)
                 (file-readable-p (plist-get block :path)))
            (append (list :type "image" :mime (or (plist-get block :mime) "image/png")
                          :data (harness-agent--file-base64 (plist-get block :path)))
                    (and (harness-agent--image-label block) (list :label (harness-agent--image-label block)))))
           (t (list :type "text" :text (format "[image attached: %s]" (or (plist-get block :path) "clipboard"))))))
    ("audio"
     (if (plist-get block :data) block
       (list :type "text" :text (format "[audio attached: %s]" (plist-get block :path)))))
    ("file"
     (list :type "text"
           :text (format "Attached file: %s (%s bytes)" (plist-get block :path)
                         (or (plist-get block :size) (harness-file-size (plist-get block :path)) "?"))))
    ("tool_result"
     (if (plist-get block :images) (harness-agent--prepare-result block session) block))
    (_ block)))

(defalias 'harness-agent--image-label #'harness-image-label
  "Alias of `harness-image-label', shared with the UIs (harness-util.el).")

(defun harness-agent--prepare-content (blocks session)
  "Return BLOCKS, the content of a user message, ready for SESSION's provider.
Each block as `harness-agent--prepare-block' leaves it, and an image
with a label after a text block of its token, [image 1]: the text of
the message names its images by their tokens, and the model must tell
which image each one means.  A message that answers the model inline
gets `harness-agent--inline-reply-note' after its text, which only the
model reads: the transcript keeps the message as the user wrote it."
  (let ((ready (mapcan (lambda (b)
                         (let ((ready (harness-agent--prepare-block b session))
                               (label (harness-agent--image-label b)))
                           (if label
                               (list (list :type "text" :text (format "[%s]" label)) ready)
                             (list ready))))
                       blocks)))
    (if (harness-agent--inline-reply-p blocks)
        (append ready (list (list :type "text" :text harness-agent--inline-reply-note)))
      ready)))

(defun harness-agent--prepare-messages (session messages)
  "Return MESSAGES with the content of each user message ready for SESSION.
See `harness-agent--prepare-content'.  The images of tool results are
cut to the newest `harness-agent-history-images' first (see
`harness-agent--cap-images'), so the files of those cut are never read."
  (mapcar (lambda (m)
            (if (eq (plist-get m :role) 'user)
                (list :role 'user
                      :content (harness-agent--prepare-content (plist-get m :content) session))
              m))
          (harness-agent--cap-images messages session)))

(defalias 'harness-agent--names-file-p #'harness-names-file-p
  "Alias of `harness-names-file-p', shared with the UIs (harness-util.el).")

(defalias 'harness-agent--attached-text-p #'harness-attached-text-p
  "Alias of `harness-attached-text-p', shared with the UIs (harness-util.el).")

(defalias 'harness-agent--blocks-text #'harness-blocks-text
  "Alias of `harness-blocks-text', shared with the UIs (harness-util.el).
A UI reads a queued message with it as the agent will record it
\(`harness-queued-message-node').")

(defun harness-agent--only-text-p (blocks)
  "Non-nil when every block of BLOCKS is a text block."
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

(defun harness-agent--label-number (label)
  "Return the number of the image LABEL, 2 for \"image 2\", or nil."
  (and (stringp label) (string-match "\\`image \\([1-9][0-9]*\\)\\'" label)
       (string-to-number (match-string 1 label))))

(defun harness-agent--queue-blocks (items)
  "Return the content blocks of the queued ITEMS, sent as one message.
Each item's text, then its attachments.  The compose box numbers the
images of each message from 1, so two items could both hold an [image
1]: the images of an item after one with images go on from the highest
number before them, the tokens of its text naming them with them, and
the model can tell apart every image of the message."
  (let ((high 0) (blocks nil))
    (dolist (it items)
      (let* ((text (or (plist-get it :text) ""))
             (atts (plist-get it :attachments))
             (numbers (delq nil (mapcar (lambda (a) (harness-agent--label-number (plist-get a :label))) atts)))
             (shift high))
        (when (and numbers (> shift 0))
          (setq text (replace-regexp-in-string
                      "\\[image \\([1-9][0-9]*\\)\\]"
                      (lambda (token)
                        (let ((n (string-to-number (match-string 1 token))))
                          (if (memql n numbers) (format "[image %d]" (+ n shift)) token)))
                      text t t)
                atts (mapcar (lambda (a)
                               (let ((n (harness-agent--label-number (plist-get a :label))))
                                 (if n (plist-put (copy-sequence a) :label (format "image %d" (+ n shift))) a)))
                             atts)))
        (when numbers (setq high (+ shift (apply #'max numbers))))
        (setq blocks (append blocks
                             (unless (harness-string-blank-p text) (list (list :type "text" :text text)))
                             (harness-agent-attachments-to-blocks atts)))))
    (harness-agent--join-texts blocks)))

(defalias 'harness-agent-attachments-to-blocks #'harness-attachments-to-blocks
  "Alias of `harness-attachments-to-blocks', shared with the UIs (harness-util.el).")

;;;; Images tools return
;;
;; A tool may hand the model a picture with its result: read_file on an
;; image returns the image file as `:images', (:path PATH :mime MIME)
;; each, beside the `:attachments' the chat shows the user.  The
;; transcript keeps those paths on the result's node and never the bytes
;; (`harness-agent--record-result'); `session/messages' gives them to a
;; native provider as the `:images' of the result's tool_result block,
;; which the request is made ready with (`harness-agent--prepare-result',
;; `harness-agent--cap-images'); a hosted loop is handed them with the
;; result as it comes (`harness-agent--hosted-images').  Only a model that
;; reads images (`harness-agent--vision-p') is sent one: any other is told
;; in the result's text that only the user sees it.

(defun harness-agent--result-images (result)
  "Return the images RESULT, what a tool returned, hands the model, paths only.
Each is (:path PATH :mime MIME), the tool's `:images' reduced to those
two keys: a picture the transcript names and never holds.  Only one a
provider can be sent stays -- a file named, of a type in
`harness-agent--image-mimes' -- and none stays of a call that failed,
whose result a provider takes as text."
  (unless (plist-get result :is-error)
    (let ((images (plist-get result :images)))
      (and (proper-list-p images)
           (delq nil (mapcar (lambda (image)
                               (let ((path (and (consp image) (plist-get image :path)))
                                     (mime (and (consp image) (plist-get image :mime))))
                                 (and (stringp path) (not (string-empty-p path))
                                      (member mime harness-agent--image-mimes)
                                      (list :path path :mime mime))))
                             images))))))

(defun harness-agent--image-data (path)
  "Return the base64 of the image file PATH, or nil when it cannot be read.
A file that is empty, gone or not readable is no image to send."
  (and (stringp path) (file-readable-p path)
       (let ((data (condition-case nil (harness-agent--file-base64 path) (error nil))))
         (and data (not (string-empty-p data)) data))))

(defun harness-agent--revise-result (block images note)
  "Return tool_result BLOCK with IMAGES as `:images' and NOTE added to its text.
A BLOCK without IMAGES has no `:images' key.  NOTE, a string or nil for
none, is appended to the block's `:content', which stays a string; BLOCK
itself is not changed."
  (let ((new (if images
                 (plist-put (copy-sequence block) :images images)
               (harness-plist-remove block :images))))
    (if (and note (stringp (plist-get new :content)))
        (plist-put new :content (concat (plist-get new :content) note))
      new)))

(defun harness-agent--prepare-result (block session)
  "Return tool_result BLOCK, which holds `:images', ready for SESSION's provider.
For a model that reads images each image becomes (:type \"image\" :mime
MIME :data BASE64), read from its `:path'; one whose file cannot be read
any more is left out, and the block's text says it is gone.  For any
other model all the images go, and the text says that only the user
sees them.  The images stay in the transcript either way."
  (if (not (harness-agent--vision-p session))
      (harness-agent--revise-result block nil harness-agent--no-vision-note)
    (let (images notes)
      (dolist (image (plist-get block :images))
        (let* ((path (plist-get image :path))
               (data (or (plist-get image :data) (harness-agent--image-data path))))
          (if data
              (push (list :type "image" :mime (or (plist-get image :mime) "image/png") :data data) images)
            (push (harness-agent--image-gone-note (or path "?")) notes))))
      (harness-agent--revise-result block (nreverse images) (and notes (apply #'concat (nreverse notes)))))))

(defun harness-agent--result-image-count (messages)
  "Return how many images the tool results in MESSAGES carry."
  (let ((count 0))
    (dolist (m messages count)
      (when (eq (plist-get m :role) 'user)
        (dolist (b (plist-get m :content))
          (when (equal (plist-get b :type) "tool_result")
            (cl-incf count (safe-length (plist-get b :images)))))))))

(defun harness-agent--drop-oldest-images (messages count)
  "Return MESSAGES without the oldest COUNT images of their tool results.
The text of a result that lost images says so
\(`harness-agent--image-dropped-note').  A message that lost none is
returned as it is."
  (mapcar (lambda (m)
            (if (or (<= count 0) (not (eq (plist-get m :role) 'user)))
                m
              (let* ((changed nil)
                     (blocks (mapcar
                              (lambda (b)
                                (let ((have (and (> count 0) (equal (plist-get b :type) "tool_result")
                                                 (safe-length (plist-get b :images)))))
                                  (if (or (null have) (zerop have))
                                      b
                                    (let ((drop (min have count)))
                                      (setq count (- count drop) changed t)
                                      (harness-agent--revise-result b (nthcdr drop (plist-get b :images))
                                                                    harness-agent--image-dropped-note)))))
                              (plist-get m :content))))
                (if changed (list :role 'user :content blocks) m))))
          messages))

(defun harness-agent--cap-images (messages session)
  "Return MESSAGES with only the newest tool-result images the limit allows.
The limit N is `harness-agent-history-images'.  With more of them, T,
the oldest D go, D being the least multiple of N/2 that leaves no more
than N: N/2 for a T up to N + N/2, then N, and so on.  D follows from
the conversation alone, so the images a request carries stay the same
from one step to the next until D grows, and the provider's prompt
cache lasts.  Counted and cut before any file is read.  Nothing goes
for a model of SESSION that reads no images, which is sent none."
  (let ((limit harness-agent-history-images))
    (if (not (natnump limit))
        messages
      (let ((total (harness-agent--result-image-count messages)))
        (if (or (<= total limit) (not (harness-agent--vision-p session)))
            messages
          (let ((chunk (max 1 (/ limit 2))))
            (harness-agent--drop-oldest-images
             messages (min total (* chunk (ceiling (- total limit) chunk))))))))))

(defun harness-agent-strip-result-images (messages)
  "Return MESSAGES without the images of their tool results; their text stays.
For a request that needs the conversation's words and not its pictures:
a hosted loop keeps the pictures it was handed itself, and a summary or
a title is written from text.  A message without images is returned as
it is."
  (mapcar (lambda (m)
            (if (and (eq (plist-get m :role) 'user)
                     (cl-some (lambda (b) (and (equal (plist-get b :type) "tool_result")
                                               (plist-member b :images)))
                              (plist-get m :content)))
                (list :role 'user
                      :content (mapcar (lambda (b)
                                         (if (and (equal (plist-get b :type) "tool_result")
                                                  (plist-member b :images))
                                             (harness-plist-remove b :images)
                                           b))
                                       (plist-get m :content)))
              m))
          messages))

;;;; Handoff to a hosted loop
;;
;; A provider that runs its own loop (Claude Code, Copilot) keeps the
;; conversation itself and is only sent the newest user message.  When
;; another provider's model worked in the session meanwhile -- the
;; fallback moved it there while this one was out of quota, or the
;; model was switched by hand -- that conversation misses those turns.
;; They are rendered as text at the head of the message it is sent.

(defun harness-agent--model-provider (model)
  "Return the provider part of MODEL, a model id, as a string, or nil."
  (and (stringp model) (string-match "\\`\\([^:]+\\):" model) (match-string 1 model)))

(defun harness-agent--node-provider (node)
  "Return the provider of the model that produced NODE, or nil when unrecorded."
  (harness-agent--model-provider (plist-get (plist-get node :meta) :model)))

(defun harness-agent--hosted-p (session)
  "Non-nil when SESSION's provider runs its own tool loop."
  (and (harness-method-exists-p 'provider/capabilities)
       (plist-get (ignore-errors (harness-call 'provider/capabilities (plist-get session :model)))
                  :hosted-loop)))

(defun harness-agent--handoff-cut (text)
  "Return TEXT cut to `harness-agent--handoff-item-chars', saying so."
  (let ((text (string-trim (or text ""))))
    (if (<= (length text) harness-agent--handoff-item-chars)
        text
      (format "%s… [%d more characters]" (substring text 0 harness-agent--handoff-item-chars)
              (- (length text) harness-agent--handoff-item-chars)))))

(defun harness-agent--handoff-item (node)
  "Return NODE as one item of a handoff, or nil for a node left out.
Thinking is another model's own working and hints are the harness's,
as are the tool calls it recorded (`harness-outside-node-p')."
  (pcase (and (not (harness-outside-node-p node)) (plist-get node :kind))
    ('user
     (let ((from (harness-node-sender node)))
       (format "%s: %s" (if from (concat "Message from " (harness-sender-description from)) "User")
               (harness-agent--handoff-cut (plist-get node :content)))))
    ('assistant
     (unless (harness-string-blank-p (plist-get node :content))
       (format "Assistant (%s): %s" (or (plist-get (plist-get node :meta) :model) "another model")
               (harness-agent--handoff-cut (plist-get node :content)))))
    ('tool-call
     (format "Tool call %s: %s" (plist-get node :tool)
             (harness-agent--handoff-cut
              (or (ignore-errors (harness-json-encode-text (or (plist-get node :input) :empty))) ""))))
    ('tool-result
     (format "Tool result%s: %s" (if (plist-get node :is-error) " (error)" "")
             (harness-agent--handoff-cut (plist-get node :output))))
    ('plan (format "Plan: %s" (harness-agent--handoff-cut (plist-get node :content))))
    ('compaction (format "Summary of the conversation before: %s"
                         (harness-agent--handoff-cut (plist-get node :content))))
    (_ nil)))

(defun harness-agent--handoff-text (nodes models newest)
  "Return the handoff text telling a hosted loop what NODES it missed.
MODELS are the ids of the models that worked meanwhile.  NEWEST non-nil
means the newest message follows the text; otherwise the request ends
on tool results the provider never asked for, so it is told to carry
on.  Items beyond `harness-agent--handoff-max-chars' go, oldest first."
  (let* ((items (delq nil (mapcar #'harness-agent--handoff-item nodes)))
         (total (apply #'+ (mapcar (lambda (s) (+ 2 (length s))) items)))
         (dropped 0))
    (while (and (cdr items) (> total harness-agent--handoff-max-chars))
      (setq total (- total (+ 2 (length (car items))))
            items (cdr items)
            dropped (1+ dropped)))
    (concat (format "[While you were unavailable, this conversation went on with %s. This is what happened since your last reply, oldest first.]\n\n"
                    (string-join models ", "))
            (if (> dropped 0) (format "[%d earlier item%s left out.]\n\n" dropped (if (= dropped 1) "" "s")) "")
            (string-join items "\n\n")
            "\n\n"
            (if newest
                "[End of what you missed. The newest message follows.]"
              "[End of what you missed. Carry on with the task from where it stopped.]"))))

(defun harness-agent--handoff (session messages)
  "Return MESSAGES for SESSION's hosted loop, caught up on what it missed.
The provider's own conversation ends at the last node one of its models
produced; nodes another provider's model produced after that, from the
last compaction on, are what it missed.  When there are any, MESSAGES
becomes one user message: the handoff text (see
`harness-agent--handoff-text'), then the newest message's own blocks.
Otherwise MESSAGES is returned as it is."
  (let* ((provider (harness-agent--model-provider (plist-get session :model)))
         (path (harness-call 'session/nodes (plist-get session :id)))
         (start (cl-position 'compaction path :key (lambda (n) (plist-get n :kind)) :from-end t))
         (path (if start (nthcdr start path) path))
         (own (cl-position-if (lambda (n) (equal (harness-agent--node-provider n) provider)) path :from-end t))
         ;; A handoff note is the conversation's deliberate opening for this
         ;; provider, not something it missed: the handoff module wrote it,
         ;; and a note in the trailing messages already brings the provider
         ;; up to date, so the catch-up would only repeat it.
         (trailing (cl-loop for n in (reverse path)
                            while (or (memq (plist-get n :kind) '(user hint tool-result compaction))
                                      (harness-outside-node-p n))
                            thereis (harness-node-handoff n)))
         ;; Nor is a call the harness recorded, which no model made.
         (missed (cl-remove-if (lambda (n) (or (harness-node-handoff n) (harness-outside-node-p n)))
                               (if own (nthcdr (1+ own) path) path)))
         (models (delete-dups
                  (delq nil (mapcar (lambda (n)
                                      (let ((p (harness-agent--node-provider n)))
                                        (and p (not (equal p provider))
                                             (plist-get (plist-get n :meta) :model))))
                                    missed)))))
    (if (or (null models) trailing)
        messages
      (let* (;; The newest message: the user nodes after the last other one.
             (tail (length (seq-take-while (lambda (n) (eq (plist-get n :kind) 'user)) (reverse missed))))
             (context (butlast missed tail))
             (last (car (last messages)))
             (blocks (and (> tail 0) last (eq (plist-get last :role) 'user)
                          (cl-remove-if (lambda (b) (equal (plist-get b :type) "tool_result"))
                                        (plist-get last :content)))))
        (list (list :role 'user
                    :content (cons (list :type "text"
                                         :text (harness-agent--handoff-text context models blocks))
                                   blocks)))))))

(defun harness-agent--request-messages (session)
  "Return the provider messages of SESSION's next request.
A hosted loop gets the turns it missed handed over, see
`harness-agent--handoff'.  It is also sent no tool result's images
here: it was handed each with its result (`harness-agent--hosted-images')
and keeps them in the conversation it holds itself, so reading the files
again to send none of them would only cost time."
  (let* ((hosted (harness-agent--hosted-p session))
         (history (harness-call 'session/messages (plist-get session :id)))
         (messages (harness-agent--prepare-messages
                    session (if hosted (harness-agent-strip-result-images history) history))))
    (if hosted
        (condition-case err
            (harness-agent--handoff session messages)
          (error (harness-log 'warn "agent: handing %s over failed: %S" (plist-get session :id) err)
                 messages))
      messages)))

;;;; Turn start

(defun harness-agent--reanimate (session-id)
  "Resume SESSION-ID when it is inactive, so a message sent to it revives it.
A turn still running in it (it was closed mid-turn) keeps it running."
  (when (eq (plist-get (harness-call 'session/get session-id) :status) 'inactive)
    (harness-call 'session/resume session-id)
    (when (gethash session-id harness-agent--turns)
      (harness-call 'session/set-status session-id 'running))))

(defun harness-agent--message (session-id blocks from steering &optional queued)
  "Return BLOCKS, a message delivered to SESSION-ID, as the filters leave it.
The sync filter `agent/message' gets BLOCKS and its arguments
SESSION-ID and (:from FROM :steering STEERING :queued QUEUED): FROM is
who sent the message (nil for the user, see `agent/prompt'), STEERING
is non-nil when the message steers the running turn rather than
starting one, and QUEUED is non-nil when it is the session's queue going
out (`agent/send-queue') rather than a message written now.
Each filter returns the blocks to deliver.  A filter that returns
none leaves the message as it was, so a message is never emptied."
  (or (harness-run-filter 'agent/message blocks session-id
                          (list :from from :steering steering :queued queued))
      blocks))

(defun harness-agent--message-images (blocks)
  "Return the image blocks of BLOCKS, a message: the pictures it attached.
Each is (:type \"image\" :mime MIME) with `:data', base64, or a `:path'
to read, and a `:label' when the message's text names it by its token."
  (cl-remove-if-not (lambda (b) (equal (plist-get b :type) "image")) blocks))

(defun harness-agent--record-steering (turn blocks from)
  "Record BLOCKS, a message from FROM, as steering of the running TURN.
The message is a user node marked `:steering' (and `:from', when FROM is
who sent it: see `agent/prompt') and waits for the next step boundary,
which delivers it once (`harness-agent--take-steering').  The pending
entry keeps the message's text and its images, which a hosted loop is
handed with the tool result that delivers it
\(`harness-agent--with-steering').  Return the node."
  (let* ((text (harness-agent--blocks-text blocks))
         (images (harness-agent--message-images blocks))
         (node (harness-call 'session/append (harness-agent-turn-session-id turn)
                             (list :kind 'user :content text
                                   :blocks (unless (harness-agent--only-text-p blocks) blocks)
                                   :meta (append (list :steering t) (and from (list :from from)))))))
    (setf (harness-agent-turn-steering turn)
          (append (harness-agent-turn-steering turn)
                  (list (append (list :node (plist-get node :id) :text text)
                                (and images (list :images images))))))
    node))

(harness-defmethod agent/prompt (session-id blocks &optional opts)
  "Send BLOCKS (content blocks, or a string) to SESSION-ID.
Idle session: start a turn and return a promise of (:stop-reason …).
Running session: steer — the message is recorded now and delivered at
the next step boundary, once; the running turn's promise is returned.
OPTS `:queue' true only queues the message, with OPTS `:attachments',
for the next turn, whatever the session is doing.
OPTS `:from' says who sent the message when the user did not: the
harness (`harness-sender-system') or another session's agent
\(`harness-sender-session').  The message's node keeps it in its
`:meta' (a queued item keeps it too), so UIs show who sent it; the
model gets the message as a user message all the same.
OPTS `:queued' says the message is the session's queue going out
\(`agent/send-queue'), not one written now: the `agent/message' filters
get it as `:queued', so a module can treat it as what the queue kept.
An inactive session is resumed first: sending to it brings it back.
Blank text blocks are dropped; a message left empty signals an error,
so no turn, steering message or queued item is ever empty.
A message that starts a turn or steers one goes through the
`agent/message' filters first (see `harness-agent--message'); a queued
one does when its queue is sent.  An internal session (see
`session/internal-start') refuses every message: it records one model
call the harness made and cannot be continued."
  (when (and (harness-call 'session/exists-p session-id)
             (eq (plist-get (harness-call 'session/get session-id) :kind) 'internal))
    (signal 'harness-error
            (list (format "Session %s records one internal model call and cannot be continued"
                          session-id))))
  (let* ((blocks (cl-remove-if #'harness-agent--blank-p
                               (if (stringp blocks) (list (list :type "text" :text blocks)) blocks)))
         (queue (harness-json-true-p (plist-get opts :queue)))
         (attachments (and queue (plist-get opts :attachments)))
         (from (let ((f (plist-get opts :from))) (and (harness-sender-kind f) f)))
         (queued (plist-get opts :queued))
         (turn (gethash session-id harness-agent--turns)))
    (unless (or blocks attachments)
      (signal 'harness-error (list "Nothing to send: the message is empty")))
    (unless queue
      (harness-agent--reanimate session-id)
      (setq blocks (harness-agent--message session-id blocks from (and turn t) queued)))
    (cond
     (queue
      (harness-call 'session/queue session-id (harness-agent--blocks-text blocks) attachments from)
      (harness-resolved (list :queued t)))
     (turn
      (harness-agent--record-steering turn blocks from)
      (harness-emit 'agent/steered session-id)
      (harness-agent-turn-promise turn))
     (t (harness-agent--start session-id blocks from)))))

(defun harness-agent--follow-head (session-id)
  "Make the provider conversation of SESSION-ID the transcript up to its head.
Return a promise that settles once it is; it never rejects.  A hosted
provider holds the conversation itself, and the head may have moved
off it since the last turn: checked out at an earlier node, or on
another branch (`session/set-head').  The conversation is then cut at
the last provider checkpoint on the head's path, a fork of it that
`provider/fork' makes, or, without a checkpoint or a provider able to
cut there, dropped, so that the provider starts a new one from the
transcript.  Either way the model gets nothing that comes after the
head.  See `session/provider-continuation'."
  (condition-case err
      (let ((continuation (harness-call 'session/provider-continuation session-id)))
        (if (eq (plist-get continuation :mode) 'current)
            (harness-resolved nil)
          (let* ((session (harness-call 'session/get session-id))
                 (checkpoint (plist-get continuation :checkpoint)))
            (harness-then
             (if (and checkpoint (harness-method-exists-p 'provider/fork))
                 (harness-catch (harness-call 'provider/fork (plist-get session :model)
                                              (plist-get session :provider-state) checkpoint)
                                (lambda (e)
                                  (harness-log 'warn "agent: cutting the provider conversation of %s failed: %s"
                                               session-id (harness-error-message e))
                                  nil))
               (harness-resolved nil))
             (lambda (state)
               (when (harness-call 'session/exists-p session-id)
                 (harness-log 'info "agent: %s continues from %s, %s" session-id (plist-get session :head)
                              (if state (format "its provider conversation cut at node %s"
                                                (plist-get continuation :node))
                                "in a new provider conversation"))
                 (harness-call 'session/set-provider-state session-id state)
                 (harness-call 'session/set-provider-node session-id (plist-get session :head)))
               nil)))))
    (error (harness-log 'warn "agent: following the head of %s failed: %S" session-id err)
           (harness-resolved nil))))

(defun harness-agent--start (session-id blocks &optional from)
  "Start a turn of SESSION-ID with the message BLOCKS; return its promise.
FROM, when non-nil, is who sent the message (see `agent/prompt')."
  (let* ((session (harness-call 'session/get session-id))
         (promise (harness-make-promise))
         (turn (make-harness-agent-turn :session-id session-id :promise promise :started (float-time)))
         (node (append (list :kind 'user :content (harness-agent--blocks-text blocks)
                             :blocks (unless (harness-agent--only-text-p blocks) blocks))
                       (and from (list :meta (list :from from))))))
    (puthash session-id turn harness-agent--turns)
    (remhash session-id harness-agent--failures)
    (remhash session-id harness-agent--retries)
    (remhash session-id harness-agent--stop-continues)
    ;; The provider conversation follows the head first, then the gate
    ;; runs, so that an automatic compaction lands before the user's new
    ;; message, never after it.  The gate's value carries the message
    ;; (:text TEXT :from FROM), for a gate that asks about it.
    (harness-then
     (harness-then (harness-agent--follow-head session-id)
                   (lambda (_)
                     (harness-run-filter-async 'agent/before-turn
                                               (list :proceed t
                                                     :message (list :text (harness-agent--blocks-text blocks)
                                                                    :from from))
                                               (if (harness-call 'session/exists-p session-id)
                                                   (harness-call 'session/get session-id)
                                                 session))))
     (lambda (gate)
       (when (harness-call 'session/exists-p session-id)
         (harness-call 'session/append session-id node))
       (cond
        ;; Cancelled while a gate held it (one asking the user, say): the
        ;; message stays, the turn is over, or ends now.
        ((not (harness-agent--current-p turn)) nil)
        ((harness-agent-turn-cancelled turn) (harness-agent--end turn 'cancelled))
        ((not (plist-get gate :proceed))
         (when (plist-get gate :reason)
           (harness-call 'session/hint session-id (format "Turn not started: %s" (plist-get gate :reason))))
         (harness-agent--end turn 'blocked (plist-get gate :reason)))
        (t
         (harness-call 'session/set-status session-id 'running)
         (harness-emit 'agent/turn-started session-id)
         (harness-agent--step turn)))))
    promise))

;;;; Steps

(defun harness-agent--provider-state (sid model)
  "Return the provider state a step of session SID on MODEL continues, or nil.
That is the state MODEL's provider can continue (`session/provider-state').
A state another provider wrote is dropped from the session here: this
step's turns go where that provider never sees them, so its conversation
is stale from now on, and switching back to it must not look as if it
could carry on.  Switching away and back with no step in between keeps
the state."
  (let* ((raw (plist-get (harness-call 'session/get sid) :provider-state))
         (usable (if (harness-method-exists-p 'session/provider-state)
                     (harness-call 'session/provider-state sid model)
                   raw)))
    (when (and raw (not usable))
      (harness-log 'info "agent: %s moves on with %s; dropping the provider state of %s"
                   sid model (or (harness-provider-state-owner raw) "an unknown provider"))
      (harness-call 'session/set-provider-state sid nil))
    usable))

(defun harness-agent-step-request (session-id state on-event)
  "Return the request the next step of SESSION-ID sends to its model.
STATE is the provider state the step carries (`harness-agent--provider-state')
and ON-EVENT listens to the provider's events.  The session record is
read now, after STATE was settled, so that it holds the state the
request carries.  This is the one place the request of a step is made:
the turn calls it for every step, and so does whatever has to send
something that starts like a step -- the same model, system prompt,
tools, thinking level and conversation -- so that a provider's prompt
cache, which reads a request only as far as it starts like the one that
wrote it, serves both (see harness-cache-warm.el).  Nothing is changed
by making it."
  (let* ((session (harness-call 'session/get session-id))
         (model (plist-get session :model)))
    (list :model model
          :session session
          :system (harness-agent--system-prompt session)
          :messages (harness-agent--request-messages session)
          :tools (if (harness-method-exists-p 'tools/list) (harness-call 'tools/list session-id) nil)
          ;; Tools the provider runs itself, in place of these.
          :builtin-tools (and (harness-method-exists-p 'tools/builtin)
                              (harness-call 'tools/builtin session-id))
          :thinking (plist-get session :thinking)
          :provider-state state
          :on-event on-event)))

(defun harness-agent--step (turn)
  "Call the provider once for TURN."
  (let ((sid (harness-agent-turn-session-id turn)))
    (cond
     ((harness-agent-turn-cancelled turn) (harness-agent--end turn 'cancelled))
     ((not (harness-call 'session/exists-p sid)) (harness-agent--end turn 'error "session deleted"))
     (t
      (cl-incf (harness-agent-turn-steps turn))
      ;; Steering still waiting goes out with this request, as the newest
      ;; user message: after a model that stopped, that is what it answers.
      (harness-agent--take-steering turn)
      (setf (harness-agent-turn-text-node turn) nil (harness-agent-turn-text-buf turn) nil
            (harness-agent-turn-think-node turn) nil (harness-agent-turn-think-buf turn) nil
            (harness-agent-turn-step-nodes turn) nil
            (harness-agent-turn-pending turn) 0 (harness-agent-turn-waiting-done turn) nil
            (harness-agent-turn-stop-reason turn) nil (harness-agent-turn-error turn) nil)
      (let* ((model (plist-get (harness-call 'session/get sid) :model))
             (state (harness-agent--provider-state sid model))
             (request (harness-agent-step-request
                       sid state (lambda (ev) (harness-agent--on-event turn ev model)))))
        (puthash sid model harness-agent--step-models)
        (puthash sid (harness-plist-remove request :on-event) harness-agent--last-requests)
        (harness-emit 'agent/step-started sid (harness-agent-turn-steps turn))
        (harness-agent--update-activity sid '(:phase waiting))
        (setf (harness-agent-turn-handle turn) (harness-call 'provider/complete request)))))))

(defun harness-agent--take-pending (turn)
  "Deliver the pending steering of TURN: clear it and return its entries.
Return nil when nothing is pending.  Every boundary takes it, so a
message is delivered once.  Each one is recorded as delivered after the
newest node that is not one of them, which is where `session/messages'
puts it for the model, rather than where it was sent mid-step.  An
entry is (:node ID :text TEXT), with `:images' when the message attached
any (see `harness-agent--record-steering'); a turn running across a
reload may still hold bare texts."
  (when-let* ((pending (harness-agent-turn-steering turn)))
    (setf (harness-agent-turn-steering turn) nil)
    (condition-case err
        (harness-agent--mark-delivered (harness-agent-turn-session-id turn)
                                       (delq nil (mapcar (lambda (p) (and (consp p) (plist-get p :node)))
                                                         pending)))
      (error (harness-log 'warn "agent: recording delivered steering failed: %S" err)))
    pending))

(defun harness-agent--steering-text (pending)
  "Return the text of PENDING, steering entries: one paragraph each."
  (mapconcat (lambda (p) (if (stringp p) p (plist-get p :text))) pending "\n\n"))

(defun harness-agent--steering-images (pending)
  "Return the images PENDING, steering entries, attached, oldest first."
  (cl-loop for p in pending when (consp p) append (plist-get p :images)))

(defun harness-agent--take-steering (turn)
  "Deliver the pending steering of TURN: clear it and return its text.
Return nil when nothing is pending.  See `harness-agent--take-pending'."
  (when-let* ((pending (harness-agent--take-pending turn)))
    (harness-agent--steering-text pending)))

(defun harness-agent--mark-delivered (sid ids)
  "Mark the steering nodes IDS of session SID as delivered now.
They count as delivered after the newest node that is not one of them,
which is where `session/messages' puts them for the model.  A node
already after it keeps its place there, and is marked all the same:
the mark is also how a UI tells a message the model has from one that
still waits for its next step."
  (let* ((nodes (and ids (harness-call 'session/nodes sid)))
         (anchor (cl-find-if-not (lambda (n) (member (plist-get n :id) ids)) nodes :from-end t)))
    (when anchor
      (dolist (n nodes)
        (when (member (plist-get n :id) ids)
          (harness-call 'session/update-node sid (plist-get n :id)
                        :meta (plist-put (copy-sequence (plist-get n :meta))
                                         :delivered-after (plist-get anchor :id))))))))

(defun harness-agent--on-event (turn ev &optional model)
  "Handle EV from TURN's provider; late events of a finished turn are dropped.
MODEL is the model the step was sent to: the provider state it reports
is that model's provider's, whatever the session's model is by now."
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
                             :context (plist-get ev :context)
                             ;; A hosted loop's turn says what its last call wrote.
                             :last-output (plist-get ev :last-output)
                             ;; The cache the request used is this model's.
                             :model model
                             :cache-at (plist-get ev :cache-at) :cache-ttl (plist-get ev :cache-ttl))))
        ;; A model call of a hosted loop's turn, which the turn's `usage'
        ;; counts: announced for the output rate and the live token
        ;; count, recorded nowhere.
        ('call-usage
         (harness-emit 'agent/call-usage sid (harness-plist-remove ev :type)))
        ('provider-state
         (harness-call 'session/set-provider-state sid
                       (harness-tag-provider-state
                        (plist-get ev :state)
                        (or model (plist-get (harness-call 'session/get sid) :model)))))
        ('checkpoint (harness-agent--checkpoint turn ev))
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
           ;; Kept for `agent/step-error', with the model the step ran on.
           (puthash sid (append (harness-plist-remove ev :type :stop-reason)
                                (list :model (plist-get (harness-call 'session/get sid) :model)
                                      :step (harness-agent-turn-steps turn)))
                    harness-agent--failures)
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
          (puthash sid node-id harness-agent--open-nodes)
          ;; Kept for a step that fails and is tried again: the partial
          ;; answer it streamed is dropped before the next try.
          (push node-id (harness-agent-turn-step-nodes turn))
          (if thinking
              (setf (harness-agent-turn-think-node turn) node-id)
            (setf (harness-agent-turn-text-node turn) node-id))
          ;; The node's first chunk is all it opened with.
          (harness-emit 'agent/stream sid node-id kind buf)))))))

(defun harness-agent--finalize (turn kind)
  "Write the live node of KIND (assistant or thinking) of TURN for good.
Whitespace held back for a node that never got visible text is dropped.
The turn lets go of the node whether or not it could be written."
  (let* ((sid (harness-agent-turn-session-id turn))
         (thinking (eq kind 'thinking))
         (node-id (if thinking (harness-agent-turn-think-node turn) (harness-agent-turn-text-node turn)))
         (buf (if thinking (harness-agent-turn-think-buf turn) (harness-agent-turn-text-buf turn))))
    (unwind-protect
        (when node-id
          (harness-call 'session/update-node sid node-id :content (or buf "")
                        :meta (list :model (or (gethash sid harness-agent--step-models)
                                               (plist-get (harness-call 'session/get sid) :model))
                                    :usage (and (not thinking) (harness-agent-turn-last-usage turn)))))
      (if thinking
          (setf (harness-agent-turn-think-node turn) nil (harness-agent-turn-think-buf turn) nil)
        (setf (harness-agent-turn-text-node turn) nil (harness-agent-turn-text-buf turn) nil)))))

(defun harness-agent--finalize-live (turn)
  "Write the live thinking and assistant nodes of TURN for good.
Never signals: a node that cannot be written is logged, short, and let
go of.  The callers are on their way to answering the provider, or to
ending the turn, and neither may wait on it."
  (dolist (kind '(thinking assistant))
    (harness-agent--try (format "writing the %s node of %s" kind (harness-agent-turn-session-id turn))
      (harness-agent--finalize turn kind))))

(defun harness-agent--with-steering (turn content &optional sid failed)
  "Return (CONTENT . IMAGES): tool result CONTENT with TURN's pending steering.
The result is a step boundary, so this delivers that steering: a hosted
loop reads it in the content, a native one with its next request.

SID, the session's id, says the loop is hosted.  Its model then gets
the images the steering messages attached with the result: IMAGES, in
the shape `harness-agent--respond' takes, each labelled with the token
the message's text names it by (see
`harness-agent--hosted-steering-images'), and CONTENT ends with a note
of each that could not go.  Without SID IMAGES is nil: a native loop's
next request carries each message whole, its images with it.

FAILED says the call failed.  A provider takes the result of one as
text, so steering with images waits for the next boundary, whole, when
the loop is hosted: the next result, or the next step's request, which
ends with the messages, their images in them.  Content that is no text
\(nil aside) takes no steering either, which waits the same way.

Never signals: should the steering not be added, CONTENT goes out as it
is, for the result must reach the provider."
  (or (harness-agent--try "adding steering to a tool result"
        (if (or (not (or (null content) (stringp content)))
                (and sid failed (harness-agent--steering-images (harness-agent-turn-steering turn))))
            (cons content nil)
          (let ((pending (harness-agent--take-pending turn)))
            (if (null pending)
                (cons content nil)
              (let* ((images (and sid (harness-agent--steering-images pending)))
                     (shown (and images (harness-agent--hosted-steering-images sid images))))
                (cons (concat content "\n\n<user_message>\n" (harness-agent--steering-text pending)
                              "\n</user_message>" (car shown))
                      (cdr shown)))))))
      (cons content nil)))

(defun harness-agent--respond-with-fallback (respond what message fallback)
  "Give the provider MESSAGE, about WHAT, through RESPOND; never signal.
RESPOND is the `:respond' of a provider event that waits for an answer:
a hosted loop's tool call, or its request for a permission.  Taking the
answer can fail -- the provider encodes it, and text it cannot encode
makes it signal -- and a provider that never gets its answer waits for
it for good, with the turn behind it.  So the failure is logged, short
\(the error can carry the whole text that failed), and RESPOND is called
once more with \(funcall FALLBACK WHY), WHY being that short text: a few
words, which the provider can always take.  Should that fail too, it is
logged and given up.  Return non-nil when MESSAGE itself went out."
  (condition-case err
      (progn (funcall respond message) t)
    (error
     (let ((why (harness-error-short-message err)))
       (harness-log 'error "agent: sending %s failed: %s" what why)
       (condition-case err2
           (funcall respond (funcall fallback why))
         (error (harness-log 'error "agent: sending %s failed again: %s"
                             what (harness-error-short-message err2))))
       nil))))

(defun harness-agent--respond (respond name content is-error &optional images)
  "Send CONTENT, the result of the call of tool NAME, through RESPOND.
IS-ERROR marks a failed call.  IMAGES, when given, are the pictures the
model is to see with it, each (:mime MIME :data BASE64 :name FILENAME),
and `:label' (image 1) for one a message of the user's attached, whose
text names it by its token, [image 1]: they go as the result's
`:images', and the provider puts each label by its image (see
`harness-agent--hosted-steering-images').  Never signals: a result the
provider cannot take is answered with one saying that the harness could
not send it, so that the model hears of the call all the same (see
`harness-agent--respond-with-fallback'); that one is text alone, even
when the images were what the provider could not take."
  (harness-agent--respond-with-fallback
   respond (format "the result of %s" name)
   (append (list :content content :is-error is-error)
           (and images (list :images images)))
   (lambda (why)
     (list :content (format "The harness could not send the result of %s: %s" name why)
           :is-error t))))

(defun harness-agent--hosted-images (sid images)
  "Return (NOTE . SENT): what SID's hosted loop is told of a result's IMAGES.
IMAGES are (:path PATH :mime MIME).  For a model that reads images SENT
holds each one that can be read as (:mime MIME :data BASE64 :name
FILENAME), the shape of `harness-agent--respond's IMAGES; NOTE then
says of each that cannot that it is gone.  Any other model gets no
SENT and a NOTE saying that only the user sees the image.  NOTE is
text to add to the result's content, or nil for none.  The model is the
one the running step went to (`harness-agent--step-vision-p')."
  (if (not (harness-agent--step-vision-p sid))
      (cons harness-agent--no-vision-note nil)
    (let (sent notes)
      (dolist (image images)
        (let* ((path (plist-get image :path))
               (data (harness-agent--image-data path)))
          (if data
              (push (list :mime (plist-get image :mime) :data data
                          :name (file-name-nondirectory path))
                    sent)
            (push (harness-agent--image-gone-note path) notes))))
      (cons (and notes (apply #'concat (nreverse notes))) (nreverse sent)))))

(defun harness-agent--step-vision-p (sid)
  "Non-nil when the model SID's running step went to reads images.
A switch of the session's model leaves that one be until the next step;
without a step, the session's own model."
  (harness-agent--vision-p
   (list :model (or (gethash sid harness-agent--step-models)
                    (plist-get (harness-call 'session/get sid) :model)))))

(defun harness-agent--hosted-steering-images (sid images)
  "Return (NOTE . SENT): what SID's hosted loop is told of steering IMAGES.
IMAGES are the pictures the messages a tool result delivers attached
\(`harness-agent--message-images'): image blocks with base64 `:data'
or a `:path' to read, each with its `:label' when the message's text
names it by its token.  The text reaches the model inside the result,
so the images go with the result too, or the model would read of an
image it never sees.

For a model that reads images SENT holds each that can go, as
\(:mime MIME :data BASE64 :name NAME) with its `:label', the shape of
`harness-agent--respond's IMAGES, in the order the messages attached
them; NOTE then says of each that cannot why: its file is gone, or its
type is none a provider takes as an image
\(`harness-agent--image-mimes').  Any other model gets no SENT and a
NOTE saying that only the user sees the images.  NOTE is text to add
after the steering, or nil for none.  The model is the one the running
step went to (`harness-agent--step-vision-p')."
  (if (not (harness-agent--step-vision-p sid))
      (cons harness-agent--steering-no-vision-note nil)
    (let (sent notes)
      (dolist (image images)
        (let* ((path (plist-get image :path))
               (mime (or (plist-get image :mime) "image/png"))
               (given (plist-get image :data))
               (data (cond ((not (member mime harness-agent--image-mimes)) nil)
                           ((and (stringp given) (not (string-empty-p given))) given)
                           (t (harness-agent--image-data path))))
               (label (harness-agent--image-label image)))
          (cond
           (data (push (append (list :mime mime :data data
                                     :name (cond ((stringp path) (file-name-nondirectory path))
                                                 (label)
                                                 (t "image")))
                               (and label (list :label label)))
                       sent))
           ((not (member mime harness-agent--image-mimes))
            (push (harness-agent--steering-image-note
                   image (format "the model takes no image of type %s" mime))
                  notes))
           (t (push (harness-agent--steering-image-note
                     image (if (stringp path) (format "%s is gone" path) "it holds no data"))
                    notes)))))
      (cons (and notes (apply #'concat (nreverse notes))) (nreverse sent)))))

(defun harness-agent--call-title (name input)
  "Return the title of a call of tool NAME with INPUT, for people to read.
NAME itself when the title cannot be made: no reason to drop the call."
  (or (harness-agent--try (format "titling the call of %s" name)
        (if (fboundp 'harness-tool-title) (harness-tool-title name input) name))
      name))

(defun harness-agent--record-result (sid name call-id result started)
  "Record RESULT, what the call CALL-ID of tool NAME returned, in session SID.
STARTED is when the call began.  Return the node, or nil when it could
not be recorded: the store may refuse the output, or the disk be full.
That is logged, short, and the result goes on to the provider all the
same: a result the transcript refuses must not leave the model waiting."
  (harness-agent--try (format "recording result of %s" name)
    (harness-call 'session/append sid
                  (append
                   (list :kind 'tool-result :call-id call-id
                         :output (plist-get result :content)
                         :is-error (plist-get result :is-error)
                         :attachments (plist-get result :attachments))
                   ;; The images the model is to see: their files, never
                   ;; their bytes (`harness-agent--result-images').
                   (when-let* ((images (harness-agent--result-images result)))
                     (list :images images))
                   (list :meta (append
                                (list :duration (- (float-time) started)
                                      :denied (plist-get result :denied)
                                      :truncated (plist-get result :truncated))
                                ;; What the tool recorded on its
                                ;; result -- the child session a
                                ;; spawn_agent call ran, the report a
                                ;; hand_in handed in, the denied call a
                                ;; rerun_approved call ran again and
                                ;; the tool it was -- rides the node,
                                ;; so the transcript can draw it later.
                                ;; Its `:child-id', `:rerun-of' and
                                ;; `:rerun-tool' are among it.
                                (plist-get result :meta)))))))

(defun harness-agent--tool-call (turn ev)
  "Run the call EV of a harness tool for TURN; record it and its result.
The result, with any steering waiting, goes back to the provider through
EV's `:respond' when it runs a hosted loop, and with it the images the
tool returned for the model to see (`harness-agent--hosted-images'); a
model that reads none is told in the text that only the user sees them.
Then the turn ends, if the tool asked it to (`:end-turn'), or decides
what follows.

The call is over, and the turn decides what follows, whatever happens to
the result on the way: a transcript that refuses it, a provider that
cannot take it.  The turn waits for each of its calls and a hosted loop
for the result of each, so a failure here that skipped the rest would
leave the session waiting for the model for good.  A step that fails is
logged, short, and the ones after it still run."
  (let* ((sid (harness-agent-turn-session-id turn))
         (name (plist-get ev :name)) (input (plist-get ev :input))
         (call-id (or (plist-get ev :id) (harness-short-id)))
         (respond (plist-get ev :respond))
         (title (harness-agent--call-title name input))
         (started (float-time)))
    (harness-agent--finalize-live turn)
    (setf (harness-agent-turn-hosted turn) (and respond t))
    (cl-incf (harness-agent-turn-pending turn))
    (remhash sid harness-agent--open-nodes)
    ;; The model asked for the call and waits for its result: the call
    ;; runs even when the transcript refuses to record it.
    (let ((node (harness-agent--try (format "recording the call of %s" name)
                  (harness-call 'session/append sid
                                (append (list :kind 'tool-call :tool name :call-id call-id :input input
                                              :title title
                                              :meta (list :model (plist-get (harness-call 'session/get sid) :model)))
                                        (and (plist-get ev :checkpoint)
                                             (list :checkpoint (plist-get ev :checkpoint)))))))
          (execution nil))
      (when node (harness-emit 'agent/tool-call sid node))
      ;; Recorded before it starts, so its permission decision finds it.
      (harness-agent--add-call sid call-id name title)
      (setq execution (harness-call-async 'tools/execute sid (list :id call-id :name name :input input)))
      (harness-agent--update-activity sid)
      (harness-then
       execution
       (lambda (result)
         ;; Before `respond': sending the result can run the provider's
         ;; process filter, whose news must not hide behind this call.
         (harness-agent--remove-call sid call-id)
         (harness-agent--update-activity sid)
         (unwind-protect
             (let* ((rnode (harness-agent--record-result sid name call-id result started))
                    ;; The pictures of the result go to a hosted loop with
                    ;; it, for a model that reads them: (NOTE . IMAGES).  A
                    ;; loop the harness runs reads them from the transcript
                    ;; with its next request, and nothing is read here.
                    (shown (and respond
                                (harness-agent--try (format "reading the images of %s" name)
                                  (when-let* ((wanted (harness-agent--result-images result)))
                                    (harness-agent--hosted-images sid wanted)))))
                    ;; Steering rides on the result: (CONTENT . IMAGES),
                    ;; the images its messages attached for a hosted loop.
                    (steered (harness-agent--with-steering
                              turn (let ((text (plist-get result :content)))
                                     (if (and (car shown) (or (null text) (stringp text)))
                                         (concat text (car shown))
                                       text))
                              (and respond sid) (plist-get result :is-error))))
               (when rnode
                 (harness-agent--try (format "announcing the result of %s" name)
                   (harness-emit 'agent/tool-result sid rnode)))
               (when respond
                 (harness-agent--respond respond name (car steered) (plist-get result :is-error)
                                         (append (cdr shown) (cdr steered)))))
           ;; Whatever went wrong above, the call is over.
           (cl-decf (harness-agent-turn-pending turn))
           (if (plist-get result :end-turn)
               ;; A tool finished the work (`hand_in'): no step may follow.
               (harness-agent--finish-turn turn)
             (harness-agent--maybe-continue turn))))
       (lambda (err)
         (harness-agent--remove-call sid call-id)
         (harness-agent--update-activity sid)
         (unwind-protect
             (let ((msg (harness-run-filter
                         'tools/output-text
                         (format "Tool %s failed: %s" name (harness-error-short-message err))
                         sid)))
               (harness-agent--try (format "recording the failure of %s" name)
                 (harness-call 'session/append sid
                               (list :kind 'tool-result :call-id call-id :output msg :is-error t)))
               ;; A failed call's result is text: steering with images waits.
               (let ((content (car (harness-agent--with-steering turn msg (and respond sid) t))))
                 (when respond (harness-agent--respond respond name content t))))
           (cl-decf (harness-agent-turn-pending turn))
           (harness-agent--maybe-continue turn)))))))

;;;; Provider checkpoints

(defun harness-agent--result-node (sid call-id)
  "Return the id of the latest result of tool call CALL-ID on SID's path, or nil."
  (plist-get (cl-find-if (lambda (n) (and (eq (plist-get n :kind) 'tool-result)
                                          (equal (plist-get n :call-id) call-id)))
                         (harness-call 'session/nodes sid) :from-end t)
             :id))

(defun harness-agent--checkpoint (turn ev)
  "Stamp the provider checkpoint of EV on the node of TURN that it marks.
A hosted provider reports where its own conversation stands as content
lands in it, so that a fork or a checkout at a node can later cut that
conversation there (see `session/provider-continuation').  With
`:call-id' EV marks that call's result; without, the text or thinking
node the turn wrote last, unless a tool call came after it (a tool
call brings its own checkpoint on its `tool-call' event).  A
checkpoint with no such node is dropped: the node it would mark, such
as a thinking block without text, has none to show."
  (let* ((sid (harness-agent-turn-session-id turn))
         (checkpoint (plist-get ev :checkpoint))
         (call-id (plist-get ev :call-id))
         (node-id (if call-id
                      (harness-agent--result-node sid call-id)
                    (gethash sid harness-agent--open-nodes))))
    (when (and checkpoint node-id)
      (condition-case err
          (harness-call 'session/update-node sid node-id :checkpoint checkpoint)
        (error (harness-log 'warn "agent: recording a checkpoint of %s failed: %S" sid err))))))

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
      (remhash sid harness-agent--open-nodes)
      ;; The provider runs the call, and may be waiting for the harness's
      ;; permission (`harness-agent--tool-permission'): it goes on, and is
      ;; tracked, even when the transcript refuses to record it.
      (let* ((title (harness-agent--call-title name input))
             (node (harness-agent--try (format "recording the call of %s" name)
                     (harness-call 'session/append sid
                                   (append (list :kind 'tool-call :tool name :call-id call-id :input input
                                                 :title title
                                                 :meta (list :builtin t
                                                             :model (plist-get (harness-call 'session/get sid) :model)))
                                           (and (plist-get ev :checkpoint)
                                                (list :checkpoint (plist-get ev :checkpoint))))))))
        (when node (harness-emit 'agent/tool-call sid node))
        (harness-agent--add-call sid call-id name title)
        ;; Nothing checks its permission until the provider asks.
        (harness-agent--set-call sid call-id :checking nil :builtin t :started (float-time))
        (harness-agent--update-activity sid)))))

(defun harness-agent--tool-permission (turn ev)
  "Decide whether the call EV of a tool TURN's provider runs itself may run.
The harness's permission chain decides it as a call of the harness tool
it stands in for (`tools/authorize'), and EV's `:respond' gets the
DECISION: (:behavior allow ...), or (:behavior deny :message TEXT ...)
where TEXT is what the model is told.  A call EV the turn has not
recorded yet is recorded first.

The provider waits for the answer, so it always gets one: should it
not take the DECISION, it is told that the call is denied because the
harness could not send it (see `harness-agent--respond-with-fallback')."
  (let* ((sid (harness-agent-turn-session-id turn))
         (call-id (plist-get ev :id))
         (respond (plist-get ev :respond))
         (answer (lambda (decision)
                   (when respond
                     (harness-agent--respond-with-fallback
                      respond (format "the permission decision about %s" call-id) decision
                      (lambda (why)
                        (list :behavior 'deny :reason why
                              :message (format "Denied: the harness could not send its decision: %s" why)))))))
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
         (funcall refuse (format "the permission check failed: %s" (harness-error-short-message err)))))))))

(defun harness-agent--builtin-output (output)
  "Return OUTPUT, what a provider's own tool printed, as the transcript keeps it.
The provider ran the tool and the model has all of OUTPUT.  The
transcript is read by people and sent to models again, so it keeps no
more than a harness tool's output may be (`harness-tools-max-output-chars'),
the rest said in a line, where a harness tool saves the whole to a file."
  (let* ((text (if (stringp output) output (format "%s" (or output ""))))
         (max (and (boundp 'harness-tools-max-output-chars) harness-tools-max-output-chars)))
    (if (and (natnump max) (> (length text) max))
        (concat (substring text 0 max)
                (format "\n[%d more characters: the provider's tool printed them to the model, the transcript keeps the first %d]"
                        (- (length text) max) max))
      text)))

(defun harness-agent--record-builtin-result (sid call output is-error &optional meta)
  "Record OUTPUT as the result of SID's running built-in CALL and end it.
IS-ERROR marks a failed call; META is added to the node's meta.  Return
the node, or nil when it could not be recorded: that is logged, short,
and the call is over all the same.  The output goes through the
`tools/output-text' filter first, as the text of a harness tool does, so
the secrets module masks it here too; a long one is cut
\(`harness-agent--builtin-output')."
  (harness-agent--remove-call sid (car call))
  (let ((node (harness-agent--try (format "recording result of %s" (or (plist-get (cdr call) :tool) (car call)))
                (harness-call 'session/append sid
                              (list :kind 'tool-result :call-id (car call)
                                    :output (harness-run-filter
                                             'tools/output-text
                                             (harness-agent--builtin-output output)
                                             sid)
                                    :is-error (and is-error t)
                                    :meta (append (list :builtin t
                                                        :duration (- (float-time)
                                                                     (or (plist-get (cdr call) :started) (float-time))))
                                                  (and (plist-get (cdr call) :denied) (list :denied t))
                                                  meta))))))
    (when node (harness-emit 'agent/tool-result sid node))
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
\(`:end-turn' on its result): the turn ends with `end-turn' as if the
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

(defun harness-agent--next-step (turn)
  "Run one more step of TURN, once the `agent/step' filters let it.
They are asked at every step boundary: a filter that refuses (a merge
hold, say) ends the turn `blocked', with its reason as a hint."
  (let ((sid (harness-agent-turn-session-id turn)))
    (harness-then
     (harness-run-filter-async 'agent/step (list :proceed t) (harness-call 'session/get sid))
     (lambda (gate)
       (if (plist-get gate :proceed)
           (harness-agent--step turn)
         (when (plist-get gate :reason) (harness-call 'session/hint sid (plist-get gate :reason)))
         (harness-agent--end turn 'blocked (plist-get gate :reason)))))))

(defun harness-agent--maybe-continue (turn)
  "Decide what happens to TURN once its provider is done and no tool runs."
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
           (harness-agent--next-step turn)))
        ;; A model that stopped on its own is asked of the `agent/stop' filters.
        ('end-turn (harness-agent--stopped turn))
        ('max-tokens (harness-call 'session/hint sid "The model hit its output limit.")
                     (harness-agent--end turn 'max-tokens))
        ('cancelled (harness-agent--end turn 'cancelled))
        ('error (harness-agent--step-failed turn))
        (_ (harness-agent--end turn (or reason 'end-turn)))))))

(defun harness-agent--stop-message (decision)
  "Return (TEXT . FROM) when DECISION, an `agent/stop' answer, sends the model on.
That is an answer that does not stop, (:stop nil :message TEXT), with a
TEXT that says something.  FROM is the answer's `:from' when that names
a sender (see `harness-node-sender'), else the harness itself.  Nil for
any other answer."
  (when (and (consp decision) (not (harness-json-true-p (plist-get decision :stop))))
    (let ((text (plist-get decision :message))
          (from (plist-get decision :from)))
      (when (and (stringp text) (not (harness-string-blank-p text)))
        (cons text (if (harness-sender-kind from) from (harness-sender-system "harness")))))))

(defun harness-agent--stopped (turn)
  "Decide what follows the model of TURN stopping on its own.
It is the turn's end, or a step more.  Called when the model ended its
turn (`end-turn') with no steering waiting and the turn is not cancelled.

The async filter `agent/stop' gets the value (:stop t) and the session
plist.  A handler that answers (:stop nil :message TEXT) sends the
model on: TEXT is recorded as a message of the harness's -- from
`(harness-sender-system \"harness\")', or from the answer's own `:from',
a sender -- marked as steering like a message sent mid-turn, and the
turn takes one more step (asked of `agent/step', as any step is), which
delivers it, exactly as when the model stopped with steering waiting.
This happens at most `harness-agent--max-stop-continues' times a turn,
and the filters are not asked after that.  Any other answer ends the
turn `end-turn', and with no handler on the filter it ends at once,
without asking, as it did before the filter existed.

A handler that fails is logged and leaves the answer as it was.  A turn
cancelled while the filters run ends `cancelled', one that is no longer
its session's current turn is left alone, and a message sent to the
turn meanwhile gets its step even when the answer is to stop."
  (let* ((sid (harness-agent-turn-session-id turn))
         (count (gethash sid harness-agent--stop-continues 0)))
    (if (or (harness-agent-turn-cancelled turn)
            (>= count harness-agent--max-stop-continues)
            (not (memq 'agent/stop (harness-filters)))
            (not (harness-call 'session/exists-p sid)))
        (harness-agent--end turn 'end-turn)
      (harness-then
       (harness-run-filter-async 'agent/stop (list :stop t) (harness-call 'session/get sid))
       (lambda (decision) (harness-agent--stop-decided turn decision))
       (lambda (err)
         (harness-log 'error "agent: agent/stop for %s failed: %S" sid err)
         (when (harness-agent--current-p turn)
           (harness-agent--end turn 'end-turn)))))))

(defun harness-agent--stop-continue (turn decision)
  "Send TURN on past its model's stop as DECISION says; non-nil when it goes on.
DECISION is what the `agent/stop' filters answered (see
`harness-agent--stopped').  A message in it is recorded and counted; a
message sent to the turn meanwhile is steering that waits for its step
all the same.  Either one is delivered by the step that follows."
  (let* ((sid (harness-agent-turn-session-id turn))
         (sent (and (harness-call 'session/exists-p sid) (harness-agent--stop-message decision))))
    (cond
     (sent
      (puthash sid (1+ (gethash sid harness-agent--stop-continues 0)) harness-agent--stop-continues)
      (harness-agent--record-steering turn (list (list :type "text" :text (car sent))) (cdr sent))
      (harness-agent--next-step turn)
      t)
     ((harness-agent-turn-steering turn)
      (harness-agent--next-step turn)
      t))))

(defun harness-agent--stop-decided (turn decision)
  "Carry out DECISION, what the `agent/stop' filters answered, for TURN.
See `harness-agent--stopped'.  A failure to go on ends the turn, logged."
  (cond
   ((not (harness-agent--current-p turn)) nil)
   ((harness-agent-turn-cancelled turn) (harness-agent--end turn 'cancelled))
   ((condition-case err
        (harness-agent--stop-continue turn decision)
      (error (harness-log 'error "agent: carrying on %s after agent/stop failed: %S"
                          (harness-agent-turn-session-id turn) err)
             nil)))
   (t (harness-agent--end turn 'end-turn))))

(defun harness-agent--rewind-step (turn)
  "Drop what TURN's failed step already streamed, before it is tried again.
The text and thinking nodes the step wrote go (see
`session/discard-nodes'): no partial answer is then sent to the model
twice, and the retry writes its own.  Tool calls the step made, and
their results, stay where they are, re-parented to the last node kept
before them, so the model goes on from the work they did.

A hosted-loop provider keeps its own conversation, which this cannot
rewind, so nothing is dropped for one: the provider carries on from
what it already produced, and the retry continues it.  A failure to
drop the nodes is logged and the turn goes on as it did before -- the
retry may then repeat the partial answer, but never the work a tool
already did."
  (let ((sid (harness-agent-turn-session-id turn))
        (nodes (harness-agent-turn-step-nodes turn)))
    (when (and nodes (harness-call 'session/exists-p sid)
               (not (harness-agent--hosted-p (harness-call 'session/get sid))))
      (condition-case err
          (let ((dropped (harness-call 'session/discard-nodes sid nodes)))
            (when dropped
              (harness-log 'info "agent: %s failed a step; dropped %d partial node(s) before trying again"
                           sid (length dropped))))
        (error (harness-log 'warn "agent: dropping the partial output of %s failed: %S" sid err))))
    (setf (harness-agent-turn-step-nodes turn) nil
          (harness-agent-turn-text-node turn) nil (harness-agent-turn-text-buf turn) nil
          (harness-agent-turn-think-node turn) nil (harness-agent-turn-think-buf turn) nil)
    (remhash sid harness-agent--open-nodes)))

(defun harness-agent--step-failed (turn)
  "Decide what follows TURN's failed step: another try, or the turn's end.
The async filter `agent/step-error' gets (:retry nil), the session and
the FAILURE (the `done' event's keys, `:model' and `:step').  A handler
that answers (:retry t) -- the fallback module, having moved the
session to another provider, or `harness-retry', for a failure a
connection or a rate limit caused -- has the step run again, at most
`harness-agent--max-error-retries' times a turn.  The partial answer
the failed step had streamed is dropped first
\(`harness-agent--rewind-step'), so the retry cannot send it twice.
Otherwise, and once the turn was cancelled, it ends with `error'."
  (let* ((sid (harness-agent-turn-session-id turn))
         (error (harness-agent-turn-error turn))
         (failure (or (gethash sid harness-agent--failures) (list :error error)))
         (count (gethash sid harness-agent--retries 0)))
    (remhash sid harness-agent--failures)
    (if (or (harness-agent-turn-cancelled turn)
            (>= count harness-agent--max-error-retries)
            (not (harness-call 'session/exists-p sid)))
        (harness-agent--end turn 'error error)
      (harness-then
       (harness-run-filter-async 'agent/step-error (list :retry nil)
                                 (harness-call 'session/get sid) failure)
       (lambda (decision)
         (when (harness-agent--current-p turn)
           (if (and (plist-get decision :retry)
                    (not (harness-agent-turn-cancelled turn))
                    (harness-call 'session/exists-p sid))
               (progn (harness-agent--rewind-step turn)
                      (puthash sid (1+ count) harness-agent--retries)
                      (harness-agent--step turn))
             (harness-agent--end turn 'error error))))
       (lambda (err)
         (harness-log 'error "agent: agent/step-error for %s failed: %S" sid err)
         (when (harness-agent--current-p turn)
           (harness-agent--end turn 'error error)))))))

(defun harness-agent--end (turn reason &optional error)
  "End TURN with stop REASON, and ERROR when it failed.
Only the session's current turn ends: the built-in calls still running
get a result, an open session goes idle, or blocked when something
waits on the user, `agent/turn-ended' is emitted and the turn's promise
resolves.  A turn that ends with `end-turn' sends the session's queued
messages next."
  (let ((sid (harness-agent-turn-session-id turn)))
    (when (eq (gethash sid harness-agent--turns) turn)
      ;; A turn cancelled before its provider was done.
      (when (harness-call 'session/exists-p sid)
        (harness-agent--close-builtins turn reason))
      (remhash sid harness-agent--turns)
      (remhash sid harness-agent--step-models)
      (remhash sid harness-agent--last-requests)
      (remhash sid harness-agent--failures)
      (remhash sid harness-agent--retries)
      (remhash sid harness-agent--stop-continues)
      (harness-agent--clear-activity sid)
      (when (harness-call 'session/exists-p sid)
        (harness-call 'session/usage-add sid (list :turns 1))
        (let ((session (harness-call 'session/get sid)))
          ;; The provider conversation got this far: a head moved off it
          ;; later makes the next turn cut it (`harness-agent--follow-head').
          (harness-call 'session/set-provider-node sid (plist-get session :head))
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
  "Cancel the running turn of SESSION-ID, if any.
`agent/cancelling' tells whatever holds a turn up before it starts, a
gate asking the user say, to let it go: the turn then ends as soon as
its gate settles, rather than after the grace period."
  (let ((turn (gethash session-id harness-agent--turns)))
    (when turn
      (setf (harness-agent-turn-cancelled turn) t)
      (let ((cancel (plist-get (harness-agent-turn-handle turn) :cancel)))
        (when cancel (ignore-errors (funcall cancel))))
      (harness-emit 'agent/cancelling session-id)
      (run-at-time harness-agent--cancel-grace nil
                   (lambda () (when (eq (gethash session-id harness-agent--turns) turn)
                                (harness-agent--finalize-live turn)
                                (harness-agent--end turn 'cancelled))))
      t)))

(defun harness-agent--queue-sender (items)
  "Return who sent ITEMS, queued messages that go out as one, or nil.
Nil means the user: the message is theirs when any of ITEMS is.
Otherwise it is from the first item's sender (see `agent/prompt')."
  (unless (cl-some (lambda (it) (null (harness-sender-kind (plist-get it :from)))) items)
    (plist-get (car items) :from)))

(harness-defmethod agent/send-queue (session-id &optional qids)
  "Send the queued messages of SESSION-ID as one turn; return its promise.
Every queued message goes, or with QIDS, a list of queue item ids (a
vector works too), only those: one message sent now, the others still
waiting for the turn that sends the queue (`session/queue-take').
Items with neither text nor attachments are dropped, and the images of
the others numbered across the message (`harness-agent--queue-blocks').
With nothing to send -- an empty queue, or QIDS naming items that went
already -- no turn starts and the promise resolves to
\(:stop-reason nothing-queued).  While a turn runs the messages steer
it, like any message sent then, and reach the model at its next step.
The message is the user's when any item is, else from the first item's
sender.  It goes as the queue's (`:queued'), so `agent/message' filters
can tell it from a message written now."
  (let* ((items (cl-remove-if (lambda (it) (and (harness-string-blank-p (plist-get it :text))
                                                (null (plist-get it :attachments))))
                              (harness-call 'session/queue-take session-id qids)))
         (blocks (harness-agent--queue-blocks items))
         (from (harness-agent--queue-sender items)))
    (if (null blocks)
        (harness-resolved (list :stop-reason 'nothing-queued))
      (harness-call 'agent/prompt session-id blocks (list :from from :queued t)))))

;;;; Taking a message back

(defun harness-agent--steering-entry (turn node-id)
  "Return the pending steering entry of TURN that records the node NODE-ID, or nil."
  (cl-find-if (lambda (p) (and (consp p) (equal (plist-get p :node) node-id)))
              (harness-agent-turn-steering turn)))

(harness-defmethod agent/withdraw (session-id node-id)
  "Take back the steering message NODE-ID of SESSION-ID; return the node it was.
A message sent while a turn runs waits for the turn's next step, which
delivers it (`harness-agent--take-pending'): until then it is the
user's, to delete or to write again.  This removes it from what the turn
will deliver, so the model never gets it, and from the transcript
\(`session/discard-nodes', which announces it as `session/nodes-removed').
It signals when the turn does not hold the message: it was delivered
at a step boundary meanwhile, the turn is over -- a message it never
took is read by the next turn -- or NODE-ID is no steering message of the
session.  Nothing happens then."
  (let* ((turn (gethash session-id harness-agent--turns))
         (entry (and turn (harness-agent--steering-entry turn node-id)))
         (pending (and entry (harness-agent-turn-steering turn)))
         (node (and entry (harness-call 'session/node session-id node-id))))
    (unless entry
      (signal 'harness-error (list "The model has this message already: it cannot be taken back")))
    ;; Off the turn's list first, so no step can deliver it; back on if the
    ;; transcript refuses to let it go.  A message whose node is gone
    ;; already has nothing to deliver either.
    (setf (harness-agent-turn-steering turn) (delq entry (copy-sequence pending)))
    (when node
      (condition-case err
          (harness-call 'session/discard-nodes session-id (list node-id))
        (error (setf (harness-agent-turn-steering turn) pending)
               (signal (car err) (cdr err)))))
    node))

(harness-defmethod agent/running (&optional session-id)
  "Return running session ids, or non-nil when SESSION-ID is running."
  (if session-id
      (harness-agent-running-p session-id)
    (let (out) (maphash (lambda (k _) (push k out)) harness-agent--turns) out)))

(harness-defmethod agent/outstanding (session-id)
  "Return what runs for SESSION-ID outside its own turn, as a short text, or nil.
A module that started work for the session which goes on without its
turn -- a supervisor plan's workers, say -- reports it to the sync
filter `agent/outstanding', whose value starts at nil and whose
argument is SESSION-ID.  A handler with nothing to report returns the
value unchanged; one that reports returns its own text, or appends it to
the text the handlers before it returned, separated by \"; \".  Task
mode keeps the task of a session whose turn ended working while this
says something (`harness-tasks--on-turn-ended').  A value that is not a
text with words in it counts as nothing outstanding."
  (let ((text (harness-run-filter 'agent/outstanding nil session-id)))
    (and (stringp text) (not (harness-string-blank-p text)) text)))

(harness-defmethod agent/stop-outstanding (session-id &optional reason)
  "Stop what runs for SESSION-ID outside its own turn; return what it stopped.
The counterpart of `agent/outstanding': a module that started work for
the session which goes on without its turn -- a supervisor plan's
workers, a background sub-agent -- stops it when asked through the sync
filter `agent/stop-outstanding', whose value starts at nil and whose
arguments are SESSION-ID and REASON.  REASON is a short text saying
why, such as \"its task was paused\", or nil; a handler
records it where the owner of the work reads it, as a supervisor step's
error.  A handler with nothing to stop for the session returns the value
unchanged; one that stopped something returns a text saying what, or
appends it to the text the handlers before it returned, separated by
\"; \".  Cheap registrations, the waits of `session_wait' say, are left
alone.  The result is that text, or nil when it is not a text with
words in it: nothing was stopped.

Task mode calls this when a task is pre-empted or returned to the
queue, once no turn of the session runs, so that the reports the
stopped work sends reach an idle session."
  (let ((text (harness-run-filter 'agent/stop-outstanding nil session-id reason)))
    (and (stringp text) (not (harness-string-blank-p text)) text)))

(dolist (ev '((agent/turn-started . "(SESSION-ID)") (agent/turn-ended . "(SESSION-ID REASON)")
              (agent/cancelling
               . "(SESSION-ID) when the running turn is cancelled, before it ends: a gate holding the turn up lets it go")
              (agent/step-started . "(SESSION-ID STEP)")
              (agent/stream . "(SESSION-ID NODE-ID KIND DELTA)")
              (agent/tool-call . "(SESSION-ID NODE)") (agent/tool-result . "(SESSION-ID NODE)")
              (agent/steered . "(SESSION-ID)") (agent/quota . "(SESSION-ID WINDOWS)")
              (agent/call-usage
               . "(SESSION-ID USAGE) when a model call of a hosted loop's turn reports its usage, (:output N), with `:context' N, the size of the call's prompt, when the provider knows it; the turn's `usage' event counts it")
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
  (harness-on 'tools/progress #'harness-agent--on-tool-progress)
  (harness-on 'tools/note #'harness-agent--on-tool-note))

(harness-define-module 'agent
  :doc "The turn loop: prompt, stream, run tools, steer, queue."
  :requires '(session provider tools)
  :init #'harness-agent--init
  :shutdown #'harness-agent--save-live)

(provide 'harness-agent)
;;; harness-agent.el ends here
