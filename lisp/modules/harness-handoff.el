;;; harness-handoff.el --- Hand a conversation over to another provider  -*- lexical-binding: t; -*-

;;; Commentary:

;; A hosted-loop provider (Claude Code, Copilot) keeps the conversation
;; itself and is sent only the user messages after the model's last
;; reply.  A session switched to it from another provider therefore
;; starts a new conversation there that holds nothing of what came
;; before: the model answers the newest message with no idea of the
;; task.  An API provider is sent the whole transcript at every step,
;; and a provider that still holds the session's conversation resumes
;; it, so switching to either loses nothing.  This module tells a lossy
;; switch from a harmless one, says what it costs, and carries the
;; conversation over when asked to:
;;
;; - `handoff/check' says whether switching a session to a model is
;;   lossy, why or why not, and its risks; `handoff/check-all' answers
;;   for every session a switch of many would change.
;; - `handoff/switch' switches and hands over as its MODE says:
;;   `compact' summarises the conversation on the old model first
;;   (`compaction/compact'); `session/messages' turns the compaction
;;   node into the user message that opens the new conversation.
;;   `compact-new' has the *new* model write the summary instead, from
;;   only the first and last messages of the session: the old provider
;;   may not be able to answer at all (its plan ran out, it is down),
;;   and a bounded context keeps the job cheap.  `transcript' writes the
;;   whole transcript (`session/transcript-text') to a file in the
;;   session's directory, which its tools may read and the new
;;   provider's cache holds as it reads, and leaves a user message
;;   telling the model to read it before answering, marked as a handoff
;;   note so the chat shows it as the harness's.  `none' only switches.
;;   A summary that cannot be made (the summariser fails) falls back to
;;   the transcript.  Every handoff marks the message that opens the new
;;   conversation as a lossy one and tells the model to re-investigate
;;   what it is unsure of.  `handoff/switch-all' switches many at once,
;;   with one MODE for the lossy ones.
;;
;; The switch itself is immediate: a running turn finishes the step it
;; is in on the old model and takes the new one from its next step.  A
;; handoff has to land in the trailing user messages, after the model's
;; last reply, or a hosted loop never sees it, so for a running session
;; it waits for that next step: the `agent/step' and `agent/before-turn'
;; gates run it and hold the step until it is done, and a turn that
;; ends first has it run as soon as it is over.  An idle session's
;; handoff starts at once, and a turn started meanwhile waits for it.
;;
;; The prompt cache decides what a summary on the old model costs: it
;; reads the conversation back from that model's cache while the cache
;; lasts, and pays for all of it again uncached once it lapsed, so
;; `handoff/check' hands the UI the session's cache (`:cache') to say
;; which.  Whatever the mode, the new provider starts a conversation of
;; its own, which nothing cached serves and none of the old one is sent
;; to: the session reports no cache for it until its first request
;; caches one (see harness-session.el), and a summary drops the old
;; cache's stamp as any compaction does.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)

(defconst harness-handoff-modes '(compact compact-new transcript none)
  "How `handoff/switch' carries a conversation over to the new model.
`compact' summarises on the old model, `compact-new' on the new one
from a bounded context, `transcript' hands the whole conversation over
as a file and `none' only switches.")

(defconst harness-handoff--directory ".harness/handoff/"
  "Where in a session's directory handoff transcripts are written.
Inside the directory the session's tools may read without asking;
the state directory is out of every session's reach.  Git ignores it:
a `.gitignore' of `*' is written into it.")

(defconst harness-handoff--sender "model handoff"
  "What the chat names as the sender of a handoff note.")

(defconst harness-handoff--history-kinds '(assistant thinking tool-call tool-result plan)
  "Node kinds a hosted loop is never sent: everything but user messages.")

(defvar harness-handoff--pending (make-hash-table :test 'equal)
  "Session id -> the handoff waiting for that session's next step, or under way.
A plist (:mode MODE :from MODEL :to MODEL :promise PROMISE), `:promise'
once it runs.")

;;;; Checking a switch

(defun harness-handoff--model-label (model)
  "Return the label people read for MODEL."
  (or (and (harness-method-exists-p 'provider/model)
           (plist-get (ignore-errors (harness-call 'provider/model model)) :label))
      model))

(defun harness-handoff--provider-label (model)
  "Return the label of MODEL's provider."
  (or (and (harness-method-exists-p 'provider/model)
           (plist-get (ignore-errors (harness-call 'provider/model model)) :provider-label))
      (format "%s" (or (harness-model-provider model) model))))

(defun harness-handoff--hosted-p (model)
  "Non-nil when MODEL's provider runs the tool loop and keeps the conversation."
  (and (harness-method-exists-p 'provider/capabilities)
       (harness-json-true-p (plist-get (harness-call 'provider/capabilities model) :hosted-loop))))

(defun harness-handoff--history-p (path)
  "Non-nil when PATH holds history a hosted loop would not be sent.
That is anything a model or a tool wrote since the last compaction,
whose summary opens what is sent.  A tool call the harness recorded
\(`harness-outside-node-p') is no model's history."
  (let ((start (cl-position 'compaction path :key (lambda (n) (plist-get n :kind)) :from-end t)))
    (cl-some (lambda (n) (and (memq (plist-get n :kind) harness-handoff--history-kinds)
                              (not (harness-outside-node-p n))))
             (if start (nthcdr start path) path))))

(defun harness-handoff--waiting-p (path)
  "Non-nil when a handoff waits in PATH's trailing user messages.
Those come after the model's last reply, so a hosted loop is sent them."
  (cl-loop for n in (reverse path)
           while (or (memq (plist-get n :kind) '(user hint tool-result compaction))
                     (harness-outside-node-p n))
           thereis (harness-node-handoff n)))

(defun harness-handoff--running-p (session-id)
  "Non-nil while SESSION-ID has a turn running."
  (and (harness-method-exists-p 'agent/running)
       (harness-call 'agent/running session-id)
       t))

(defconst harness-handoff-risks
  '("Cold cache: the new conversation starts uncached, so it pays cache writes where carrying on pays reads."
    "Fidelity: the model explores again; tool calls, results and thinking arrive as text or a summary."
    "Old state: a conversation it could resume, its own compaction and built-in tools stay behind."
    "Timing: takes effect at the next step, not mid-step.")
  "The risks of a lossy model switch, as `handoff/check' states them.
Each is a short label, a colon and what it means, which the switch UI
lays out as aligned rows.")

(defun harness-handoff--price (tokens model key)
  "Return what TOKENS tokens cost at MODEL's KEY price (USD per million), or nil."
  (let ((price (plist-get (plist-get (ignore-errors (harness-call 'provider/model model)) :pricing) key)))
    (and (numberp tokens) (> tokens 0) (numberp price) (>= price 0)
         (/ (* tokens price) 1e6))))

(defun harness-handoff--cache-cost (session model)
  "Describe what a cold cache costs SESSION on MODEL, at list prices, or nil.
That is its context, the size of its last request, written to MODEL's
cache rather than read back from it."
  (let* ((context (plist-get (plist-get session :usage) :context))
         (write (harness-handoff--price context model :cache-write))
         (read (harness-handoff--price context model :cache-read)))
    (when (and write read)
      (format "%s tokens: %s to write, %s to read"
              (harness-format-tokens context) (harness-format-cost write) (harness-format-cost read)))))

(defun harness-handoff--check (session model)
  "Return what switching SESSION, a session plist, to MODEL means.
See `handoff/check' for the shape."
  (let* ((id (plist-get session :id))
         (from (plist-get session :model))
         (path (harness-call 'session/nodes id))
         (history (and (harness-handoff--history-p path) t))
         (running (harness-handoff--running-p id))
         (reason
          (cond ((equal from model) "It already uses this model.")
                ((eq (harness-model-provider from) (harness-model-provider model))
                 "The new model is of the same provider, which carries on the session's conversation.")
                ((not (harness-handoff--hosted-p model))
                 "The new model is sent the whole conversation at every step.")
                ((harness-call 'session/provider-state id model)
                 (format "%s still holds this session's conversation and resumes it."
                         (harness-handoff--provider-label model)))
                ((not history) "The session has no history the new model would miss.")
                ((or (harness-handoff--waiting-p path)
                     (let ((plan (gethash id harness-handoff--pending)))
                       (and plan (eq (harness-model-provider (plist-get plan :to))
                                     (harness-model-provider model)))))
                 "A handoff already waits for the new model.")))
         (lossy (null reason)))
    (list :id id :name (plist-get session :name)
          :from from :from-label (harness-handoff--model-label from)
          :to model :to-label (harness-handoff--model-label model)
          :to-provider (harness-handoff--provider-label model)
          :lossy lossy :history history :running running
          :reason (or reason
                      (format (concat "%s keeps its own conversation and is sent only the user messages after"
                                      " the model's last reply, so none of this session's history reaches it.")
                              (harness-handoff--provider-label model)))
          :risks (and lossy harness-handoff-risks)
          :cache-cost (and lossy (harness-handoff--cache-cost session model))
          ;; Summarising on the current model is cheap while its cache
          ;; lasts: the UI says whether it still does when it asks.
          :cache (plist-get session :cache))))

(harness-defmethod handoff/check (session-id model)
  "Say what switching SESSION-ID to MODEL means for its conversation.
Return (:id :name :from :from-label :to :to-label :to-provider :lossy
BOOL :history BOOL :running BOOL :reason TEXT :risks (TEXT...)
:cache-cost TEXT :cache CACHE).  A switch is lossy when MODEL's provider
runs a hosted loop (it keeps the conversation and is sent only the
newest user messages), cannot continue the session's own conversation
\(`session/provider-state'), is not the session's current provider, and
the session has history that would not reach it with no handoff
waiting for it.  `:reason' says why it is lossy or why not; for a lossy
switch `:risks' are `harness-handoff-risks', `:cache-cost' what the
cold cache costs at MODEL's list prices (nil when they are unknown),
and `:running' says a turn runs, which the switch reaches at its next
step.  `:cache' is the session's prompt cache as `session/get' gives
it, (:at :ttl :expires :model) or nil: a summary on the current model
\(mode `compact') reads the conversation back from it while it lasts,
and pays for all of it again uncached once it lapsed."
  (harness-handoff--check (harness-call 'session/get session-id) model))

(defun harness-handoff--selected (filter)
  "Return the session plists FILTER selects, as `session/set-all' does.
That is `session/select', which with `:tasks' takes in the sessions of
the current tasks, inactive ones too: a switch of every session must
not leave them to a later `task/set-all', which would switch them
without a handoff."
  (harness-call 'session/select filter))

(harness-defmethod handoff/check-all (model &optional filter)
  "Check switching every session FILTER selects to MODEL; see `handoff/check'.
FILTER is the one of `session/set-all' (see `session/select').
Sessions that already use MODEL are left out, as `session/set-all'
leaves them alone.  Return the checks, newest session first."
  (cl-loop for s in (harness-handoff--selected filter)
           unless (equal (plist-get s :model) model)
           collect (harness-handoff--check s model)))

;;;; Handing over

(defun harness-handoff--mode (mode)
  "Return MODE, a symbol or its name, as one of `harness-handoff-modes'."
  (let ((m (cond ((null mode) 'none)
                 ((stringp mode) (intern mode))
                 (t mode))))
    (unless (memq m harness-handoff-modes)
      (signal 'harness-error
              (list (format "Unknown handoff mode %s (use compact, compact-new, transcript or none)"
                            mode))))
    m))

(defun harness-handoff--root (session)
  "Return SESSION's directory, as a file name this Emacs can open."
  (let ((cwd (plist-get session :cwd))
        (host (plist-get session :host)))
    (file-name-as-directory (if (and host (not (file-remote-p cwd))) (concat host cwd) cwd))))

(defun harness-handoff--transcript-file (session)
  "Return a new transcript file name for SESSION, in its directory."
  (let ((dir (expand-file-name harness-handoff--directory (harness-handoff--root session))))
    (expand-file-name (format "%s-%s.md"
                              (substring (plist-get session :id) 0 (min 8 (length (plist-get session :id))))
                              (format-time-string "%Y%m%dT%H%M%S"))
                      dir)))

(defun harness-handoff--transcript-text (session plan)
  "Return the file text handing SESSION's conversation over as PLAN says."
  (let ((id (plist-get session :id)))
    (concat
     "# Conversation handoff\n\n"
     (format "- Session: %s (%s)\n" (or (plist-get session :name) "unnamed") id)
     (format "- Handed over from %s to %s, %s\n"
             (plist-get plan :from) (plist-get plan :to) (format-time-string "%Y-%m-%d %H:%M %Z"))
     (format "- Working directory: %s\n\n" (plist-get session :cwd))
     "This is the conversation so far, oldest first, one entry per message:"
     " [user] the user (or who sent it), [assistant] the model's replies, [thinking] its reasoning,"
     " [tool NAME] a tool call and what it was about, [result] that call's result, [hint] notes of the"
     " harness, [compaction] a summary that stood in for what came before it.\n\n"
     "---\n\n"
     (harness-call 'session/transcript-text id)
     "\n")))

(defun harness-handoff--caveat (plan &optional mode)
  "Return the note that opens PLAN's conversation on the new model.
MODE is what was actually handed over, defaulting to PLAN's mode: a
summary can fall back to the transcript.  Every handoff is lossy: the
new provider starts a conversation of its own, so what it is given may
be incomplete or out of date.  The note says what was handed over and
asks the model to re-investigate rather than trust it."
  (let ((mode (or mode (plist-get plan :mode))))
    (format (concat "Harness note: this conversation was handed over from %s in a lossy handoff, and %s."
                    "  Treat the context above as possibly incomplete or out of date: re-investigate"
                    " anything you are unsure of -- read the files, check the state -- before you act on it.")
            (harness-handoff--model-label (plist-get plan :from))
            (pcase mode
              ('compact
               (format "it is a summary %s wrote just before the handoff, not the conversation itself"
                       (harness-handoff--model-label (plist-get plan :from))))
              ('compact-new
               (format (concat "it is a summary %s wrote from only the first and the most recent messages,"
                               " so most of the middle of the conversation is not in it")
                       (harness-handoff--model-label (plist-get plan :to))))
              (_ "the whole conversation reached you as text, without the other provider's own state, tool-call structure or thinking")))))

(defun harness-handoff--note (plan file lines)
  "Return the user node pointing the new model at transcript FILE of LINES lines.
PLAN is the handoff.  The model is told the file's name on the
session's host; the node's `:handoff' keeps FILE as this Emacs opens it."
  (list :kind 'user
        :content (format (concat "This conversation was handed over to you from %s, so you start without any of it."
                                 " Before you answer, read %s: it is the whole conversation so far, oldest first"
                                 " (%d lines; read all of it, in parts if it is long).  Then carry on where it left off."
                                 "\n\n%s")
                         (harness-handoff--model-label (plist-get plan :from))
                         (if (file-remote-p file) (file-local-name file) file)
                         lines (harness-handoff--caveat plan 'transcript))
        :meta (list :from (harness-sender-system harness-handoff--sender)
                    :handoff (list :mode "transcript" :file file
                                   :from (plist-get plan :from) :to (plist-get plan :to)))))

(defun harness-handoff--write-transcript (session-id plan)
  "Write SESSION-ID's transcript to a file and append the note pointing at it.
PLAN is the handoff.  Return (:mode transcript :file FILE :node ID)."
  (let* ((session (harness-call 'session/get session-id))
         (root (harness-handoff--root session))
         (file (harness-handoff--transcript-file session))
         (dir (file-name-directory file))
         (text (harness-handoff--transcript-text session plan)))
    (unless (file-directory-p root)
      (signal 'harness-error (list (format "the session's directory %s does not exist" root))))
    (harness-ensure-directory dir)
    (let ((ignore (expand-file-name ".gitignore" dir)))
      (unless (file-exists-p ignore)
        (harness-write-file-atomically ignore "*\n")))
    (harness-write-file-atomically file text)
    (let ((node (harness-call 'session/append session-id
                              (harness-handoff--note plan file (1+ (cl-count ?\n text))))))
      (harness-log 'info "handoff: %s handed over to %s in %s" session-id (plist-get plan :to) file)
      (list :mode 'transcript :file (plist-get (harness-node-handoff node) :file) :node (plist-get node :id)))))

(defun harness-handoff--transcript (session-id plan &optional why)
  "Hand SESSION-ID's conversation over as a transcript file, as PLAN says.
WHY, when non-nil, is why a summary could not be made instead.  Return
a promise of the result; a failure is reported to the session and
resolves with `:error'."
  (condition-case err
      (let ((result (harness-handoff--write-transcript session-id plan)))
        (harness-resolved (if why (append result (list :fallback why)) result)))
    (error
     (let ((msg (harness-error-message err)))
       (harness-log 'warn "handoff: %s: the transcript could not be handed over: %s" session-id msg)
       (ignore-errors
         (harness-call 'session/hint session-id
                       (format "Handoff failed: %s.  %s starts without the conversation."
                               msg (harness-handoff--model-label (plist-get plan :to)))))
       (harness-resolved (list :mode 'none :error msg))))))

(defun harness-handoff--compact (session-id plan summarizer context)
  "Hand SESSION-ID's conversation over as a summary made on SUMMARIZER.
CONTEXT is what SUMMARIZER is given (see `compaction/compact'):
`full' for the old model, which has the conversation, or `sample' for
the new one, which does not and gets only the first and last messages.
PLAN is the handoff.  When no summary can be made, the transcript goes
over instead.  Return a promise of the result."
  (harness-then
   (harness-call-async 'compaction/compact session-id (list :model summarizer :context context))
   (lambda (node)
     (let ((caveat (harness-handoff--caveat plan)))
       (ignore-errors
         (harness-call 'session/update-node session-id (plist-get node :id)
                       :content (concat (plist-get node :content) "\n\n" caveat)
                       :meta (append (plist-get node :meta)
                                     (list :handoff (list :mode (symbol-name (plist-get plan :mode))
                                                          :context (symbol-name context)
                                                          :summarizer summarizer
                                                          :from (plist-get plan :from)
                                                          :to (plist-get plan :to)))))))
     (list :mode (plist-get plan :mode) :summarizer summarizer :context context
           :node (plist-get node :id)))
   (lambda (err)
     (let ((msg (harness-error-message err)))
       (ignore-errors
         (harness-call 'session/hint session-id
                       (format "No summary from %s (%s): handing the whole transcript over instead"
                               (harness-handoff--model-label summarizer) msg)))
       (harness-handoff--transcript session-id plan msg)))))

(defun harness-handoff--perform (session-id plan)
  "Carry out handoff PLAN of SESSION-ID; return a promise of the result.
The promise never rejects: a failure is reported to the session."
  (condition-case err
      (pcase (plist-get plan :mode)
        ('compact (harness-handoff--compact session-id plan (plist-get plan :from) 'full))
        ('compact-new (harness-handoff--compact session-id plan (plist-get plan :to) 'sample))
        ('transcript (harness-handoff--transcript session-id plan))
        (_ (harness-resolved (list :mode 'none))))
    (error (harness-resolved (list :mode 'none :error (harness-error-message err))))))

(defun harness-handoff--run (session-id)
  "Carry out the handoff waiting for SESSION-ID; return a promise of its result.
One under way already is waited for, not started again; with none
waiting the promise resolves to nil at once."
  (let ((plan (gethash session-id harness-handoff--pending)))
    (cond
     ((null plan) (harness-resolved nil))
     ((plist-get plan :promise))
     ((not (eq (harness-model-provider (plist-get (harness-call 'session/get session-id) :model))
               (harness-model-provider (plist-get plan :to))))
      ;; Switched elsewhere since: that model gets no handoff meant for another.
      (remhash session-id harness-handoff--pending)
      (harness-resolved nil))
     (t
      (let* ((promise (harness-make-promise))
             (running (plist-put (copy-sequence plan) :promise promise)))
        (puthash session-id running harness-handoff--pending)
        (harness-then (harness-handoff--perform session-id plan)
                      (lambda (result)
                        (when (eq (gethash session-id harness-handoff--pending) running)
                          (remhash session-id harness-handoff--pending))
                        (harness-emit 'handoff/done session-id result)
                        (harness-resolve promise result)
                        nil))
        promise)))))

(defun harness-handoff--switch (session model mode)
  "Switch SESSION, a session plist, to MODEL and hand over as MODE where lossy.
Return a promise of the result; see `handoff/switch'."
  (let* ((id (plist-get session :id))
         (from (plist-get session :model))
         (check (harness-handoff--check session model))
         (lossy (plist-get check :lossy))
         (mode (if lossy mode 'none))
         (result (list :id id :model model :from from :lossy lossy)))
    (if (equal from model)
        (harness-resolved (append result (list :mode 'none)))
      (harness-call 'session/update id :model model)
      (if (eq mode 'none)
          (harness-resolved (append result (list :mode 'none)))
        (puthash id (list :mode mode :from from :to model) harness-handoff--pending)
        (if (plist-get check :running)
            (progn
              (harness-call 'session/hint id
                            (format "%s goes over to %s at the turn's next step"
                                    (pcase mode
                                      ('compact "A summary of the conversation")
                                      ('compact-new "A summary written by the new model")
                                      (_ "The transcript"))
                                    (harness-handoff--model-label model)))
              (harness-resolved (append result (list :mode mode :deferred t))))
          (harness-then (harness-handoff--run id)
                        (lambda (done) (append result done))))))))

(harness-defmethod handoff/switch (session-id model &optional mode)
  "Switch SESSION-ID to MODEL, handing its conversation over as MODE says.
MODE is `compact' (the current model summarises first), `compact-new'
\(the new model summarises, from only the first and last messages of the
session: use it when the current provider cannot answer, its plan having
run out, or to keep the job small), `transcript' (a file in the
session's directory, and a note telling the new model to read it) or
`none' (nil: only switch); see the Commentary.  A switch `handoff/check'
does not find lossy is a plain switch whatever MODE says.  The model
changes at once; the handoff runs now, or for a session with a running
turn at that turn's next step.  Return a promise of (:id :model :from
:lossy BOOL :mode MODE-DONE :summarizer MODEL :context CONTEXT :deferred
BOOL :file FILE :node ID :fallback WHY :error TEXT), settled once the
handoff is done or deferred: `:mode' is what was done (a summary can
fall back to transcript, and anything to none on an error, which
`:error' says)."
  (harness-handoff--switch (harness-call 'session/get session-id) model (harness-handoff--mode mode)))

(harness-defmethod handoff/switch-all (model &optional filter mode)
  "Switch every session FILTER selects to MODEL, handing over as MODE where lossy.
FILTER is the one of `session/set-all'; sessions that already use MODEL
are left alone, the others switch as `handoff/switch' does, the handoffs
running on their own.  Return the ids switched, newest first."
  (let ((mode (harness-handoff--mode mode))
        (ids nil))
    (dolist (s (harness-handoff--selected filter))
      (unless (equal (plist-get s :model) model)
        (let* ((id (plist-get s :id))
               (fail (lambda (err)
                       (harness-log 'warn "handoff: switching %s failed: %s" id (harness-error-message err))
                       nil)))
          (condition-case err
              (harness-catch (harness-handoff--switch s model mode) fail)
            (error (funcall fail err)))
          (push id ids))))
    (nreverse ids)))

;;;; Waiting for the next step

(defun harness-handoff--gate (value next session)
  "Hold SESSION's next step until the handoff waiting for it is done.
VALUE and NEXT are those of the `agent/step' and `agent/before-turn'
filters: the step that takes the new model must find the handoff in
its messages."
  (if (or (not (plist-get value :proceed))
          (not (gethash (plist-get session :id) harness-handoff--pending)))
      (funcall next value)
    (harness-then (harness-handoff--run (plist-get session :id))
                  (lambda (_) (funcall next value))
                  (lambda (_) (funcall next value))))
  nil)

(defun harness-handoff--on-turn-ended (session-id _reason)
  "Run the handoff that waited for SESSION-ID's turn, now that it is over."
  (when (gethash session-id harness-handoff--pending)
    (harness-run-soon (lambda ()
                        (when (and (harness-call 'session/exists-p session-id)
                                   (not (harness-handoff--running-p session-id)))
                          (harness-handoff--run session-id))))))

(defun harness-handoff--on-deleted (session-id &rest _)
  "Forget the handoff of SESSION-ID, which is gone."
  (remhash session-id harness-handoff--pending))

(defun harness-handoff--init ()
  "Hook the handoff into the turn loop (idempotent)."
  ;; Before automatic compaction (20), which a summary makes moot.
  (harness-add-filter 'agent/before-turn #'harness-handoff--gate 10)
  (harness-add-filter 'agent/step #'harness-handoff--gate 10)
  (harness-on 'agent/turn-ended #'harness-handoff--on-turn-ended)
  (harness-on 'session/deleted #'harness-handoff--on-deleted))

(harness-handoff--init)

(harness-declare-event 'handoff/done "(SESSION-ID RESULT) after a handoff to another provider was carried out.")

(harness-define-module 'handoff
  :doc "Warn before a lossy switch to a hosted-loop provider, and hand the conversation over."
  ;; Compaction is optional: without it a summary falls back to the transcript.
  :requires '(session provider agent)
  :init #'harness-handoff--init)

(provide 'harness-handoff)
;;; harness-handoff.el ends here
