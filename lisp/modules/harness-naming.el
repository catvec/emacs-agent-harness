;;; harness-naming.el --- Name sessions with the model  -*- lexical-binding: t; -*-

;;; Commentary:

;; A session that was not given a name gets one from the model as soon
;; as its first message is sent: when its turn starts
;; (`agent/turn-started'), not when it ends.  A task's first turn lasts
;; until the task is done, so naming after it left the board showing the
;; task's raw first message as its title all along.
;;
;; That request runs beside the turn.  It is a request of its own, to the
;; naming model (`harness-naming-model': by default the cheap tier of the
;; session's provider), holding only the conversation's opening message
;; (and its latest one, when it has moved on since, as a fork's has) and
;; the question.  It carries no provider state and is `:ephemeral', so a
;; hosted provider answers it apart from the session's conversation (a
;; CLI process of its own for Claude Code, a throwaway session for
;; Copilot) and the turn never sees it.  A session still nameless when a
;; later turn starts (its naming failed, say) is named then, and so is a
;; nameless session whose turn already runs when the harness is
;; reloaded.  The sync filter `naming/auto-p' (value the verdict, args
;; the session) lets another module hold this off a session it names
;; itself: task mode, while the title of the session's task is on its
;; way.  The request gives up after `harness-naming--timeout' seconds, so
;; a provider that never answers does not keep a session nameless.
;;
;; `naming/title' sends the same request for a message that has no
;; session to name yet, and only returns the title: task mode names a
;; task from its prompt that way as soon as it is submitted, while it
;; waits for a slot, and its session takes that name when it starts.
;;
;; `naming/name' can also be called at any time to title the whole
;; conversation as it stands.  Then the cheap way is to reuse the prefix
;; the provider has cached: when the provider can fork its state
;; (`:fork' capability) the request goes out on a fork of the session's
;; state, so a hosted loop only sends the naming question and an API
;; provider hits the cache for the transcript.  Otherwise the transcript
;; is sent again as plain messages.
;;
;; The result is sanitised (first line, no quotes or markdown, at most
;; `harness-naming--max-length' characters) and stored with
;; `session/update', which adds the "renamed to" hint, unless the
;; session's name changed while the model was asked: a name the user
;; gave meanwhile stays.
;;
;; The request's system prompt goes through the sync filter
;; `naming/system-prompt' (value the prompt, args the session), as a
;; turn's goes through `agent/system-prompt', so other modules can say
;; how their sessions are titled: task mode asks for ticket titles.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)

(defcustom harness-naming-auto t
  "When non-nil, name a nameless session as soon as its first message is sent."
  :type 'boolean :group 'harness)

(defcustom harness-naming-model 'auto
  "Model that names a session from its first message, as PROVIDER:NAME, or `auto'.
`auto' (the default) asks the session's provider for its `cheap' tier
\(see `harness-provider-tier-model'): a title is a few words, which the
fastest, cheapest model writes as well as any, falling back to the
session's own model when the provider names none.  A PROVIDER:NAME
forces that model, and nil uses the session's own model."
  :type '(choice (const :tag "The session provider's cheap model" auto)
                 (const :tag "The session's own model" nil)
                 (string :tag "Model" :names model))
  :group 'harness)

(defconst harness-naming--max-length 60
  "Longest name the model may give a session.")

(defconst harness-naming--max-tokens 40
  "Output budget of a naming request: a title is a handful of words.")

(defconst harness-naming--base-system-prompt
  "You write short titles for conversations between a software engineer and a coding agent.  A good title says what the conversation is about in 3 to 6 words, like a commit subject or a ticket title."
  "System prompt for the naming request.
Modules add to it per session through the `naming/system-prompt' filter.")

(defconst harness-naming--request-text
  "Give the conversation above a title of 3 to 6 words.  Reply with the title only: no quotes, no trailing period, no markdown, no explanation."
  "User message that asks the model for a title of the whole conversation.")

(defconst harness-naming--opening-text
  "The engineer opened a conversation with the agent with this message:"
  "Line before the opening message in a request that names a session from it.")

(defconst harness-naming--latest-text
  "Their latest message in it:"
  "Line before the latest message, when the conversation has moved on since.")

(defconst harness-naming--opening-request-text
  "Give the conversation a title of 3 to 6 words.  Do not answer the message or carry it out.  Reply with the title only: no quotes, no trailing period, no markdown, no explanation."
  "Text that asks the model for a title of a conversation from its messages.")

(defconst harness-naming--message-chars 3000
  "Characters of a message that a request naming a session from it carries.
The start of a long message (a task's whole write-up, say) is enough to
title it, and keeps the request short.")

(defconst harness-naming--skip-kinds '(btw subagent)
  "Session kinds that are never named automatically.")

(defvar harness-naming--timeout 60
  "Seconds a request naming from a first message may take before it fails.
A title is a few words, so a provider that has not answered by then is
not going to: the request is cancelled, and a session it was for is
named again when its next turn starts.")

(defvar harness-naming--running (make-hash-table :test 'equal)
  "Session id -> promise of the naming request in flight.")

;;;; Sanitising

(defun harness-naming-sanitise (text)
  "Turn model output TEXT into a session name, or nil when nothing is left.
Keeps the first non-blank line, strips markdown markers, quotes and a
trailing period, collapses whitespace and truncates to
`harness-naming--max-length' characters."
  (let ((line (harness-first-line (or text ""))))
    (setq line (replace-regexp-in-string "\\`\\(?:title\\|name\\)[ \t]*:[ \t]*" "" line nil nil nil))
    (setq line (replace-regexp-in-string "[*_`#>]+" "" line))
    (setq line (string-trim line "[][ \t\"'“”‘’(){}<>.,:;!?-]+" "[][ \t\"'“”‘’(){}<>.,:;!?-]+"))
    (setq line (replace-regexp-in-string "[ \t]+" " " line))
    (unless (string-empty-p line)
      (harness-truncate-end line harness-naming--max-length))))

;;;; What the model is asked

(defun harness-naming--system-prompt (session)
  "Return the naming system prompt for SESSION after `naming/system-prompt'.
SESSION is the session named, or what `naming/title' is told of the
title it asks for: its options, `:task' naming a task's id, say."
  (harness-run-filter 'naming/system-prompt harness-naming--base-system-prompt session))

(defun harness-naming--model (session)
  "Return the model that names SESSION from its first message.
See `harness-naming-model'.  SESSION's `:model' is the model of the
session, or the one `naming/title' is told the title is for."
  (let ((model (plist-get session :model))
        (choice harness-naming-model))
    (cond ((or (eq choice 'auto) (equal choice "auto"))
           (or (and model (harness-method-exists-p 'provider/tier-model)
                    (ignore-errors (harness-call 'provider/tier-model model 'cheap)))
               model))
          ((and (stringp choice) (not (string-empty-p choice))) choice)
          (t model))))

(defun harness-naming--user-texts (session-id)
  "Return the texts of SESSION-ID's user messages that title it, oldest first.
That is every message the user (or another session's agent) wrote:
what the harness sent on its own and the notes that hand a conversation
over to another model say nothing of what it is about.  The opening
message counts whoever sent it, as a task's prompt does."
  (let ((texts nil) (first t))
    (dolist (node (harness-call 'session/nodes session-id))
      (when (and (eq (plist-get node :kind) 'user)
                 (not (harness-node-handoff node))
                 (not (harness-string-blank-p (plist-get node :content)))
                 (or first (not (eq (harness-sender-kind (harness-node-sender node)) 'system))))
        (setq first nil)
        (push (string-trim (plist-get node :content)) texts)))
    (nreverse texts)))

(defun harness-naming--opening (session-id)
  "Return (OPENING . LATEST), the messages SESSION-ID is named from, or nil.
OPENING is the conversation's first user message, LATEST its last one
when that is another (nil otherwise).  Nil when it has no user message."
  (let ((texts (harness-naming--user-texts session-id)))
    (when texts
      (cons (car texts) (and (cdr texts) (car (last texts)))))))

(defun harness-naming--quote (text)
  "Return TEXT cut to `harness-naming--message-chars', between message tags."
  (format "<message>\n%s\n</message>" (harness-truncate-end text harness-naming--message-chars)))

(defun harness-naming--opening-blocks (opening)
  "Return the content of a request naming a session from OPENING.
OPENING is what `harness-naming--opening' returns.  The question comes
last, in a block of its own."
  (list (list :type "text"
              :text (concat harness-naming--opening-text "\n\n" (harness-naming--quote (car opening))
                            (if (cdr opening)
                                (concat "\n\n" harness-naming--latest-text "\n\n"
                                        (harness-naming--quote (cdr opening)))
                              "")))
        (list :type "text" :text harness-naming--opening-request-text)))

(defun harness-naming--messages (session-id)
  "Return the naming messages for SESSION-ID: the transcript plus the question."
  (let* ((messages (harness-call 'session/messages session-id))
         (ask (list :type "text" :text harness-naming--request-text))
         (last (car (last messages))))
    (if (and last (eq (plist-get last :role) 'user))
        (append (butlast messages)
                (list (list :role 'user :content (append (plist-get last :content) (list ask)))))
      (append messages (list (list :role 'user :content (list ask)))))))

(defun harness-naming--forked-state (session)
  "Return a promise of a forked provider state for SESSION, or of nil.
Only a state the session's model can continue is forked (see
`session/provider-state')."
  (let ((model (plist-get session :model)))
    (if (and (plist-get (harness-call 'provider/capabilities model) :fork)
             (harness-method-exists-p 'provider/fork))
        (harness-catch (harness-call-async 'provider/fork model
                                           (if (harness-method-exists-p 'session/provider-state)
                                               (harness-call 'session/provider-state (plist-get session :id) model)
                                             (plist-get session :provider-state)))
                       (lambda (e)
                         (harness-log 'warn "naming: provider fork failed, sending the transcript: %s"
                                      (harness-error-message e))
                         nil))
      (harness-resolved nil))))

;;;; Asking

(defun harness-naming--fail (session-id promise err)
  "Reject PROMISE with ERR and tell SESSION-ID about it."
  (let ((msg (harness-error-message err)))
    (harness-log 'warn "naming %s failed: %s" session-id msg)
    (ignore-errors (harness-call 'session/hint session-id (format "Naming failed: %s" msg)))
    (harness-emit 'naming/failed session-id msg)
    (harness-reject promise err)))

(defun harness-naming--store (sid name before promise)
  "Store NAME as session SID's name and resolve PROMISE with it.
BEFORE is the name SID had when it was asked for; a session renamed
since keeps its new name, which PROMISE resolves with instead."
  (let ((now (plist-get (harness-call 'session/get sid) :name)))
    (if (equal now before)
        (progn
          (harness-call 'session/update sid :name name)
          (harness-emit 'naming/done sid name)
          (harness-resolve promise name))
      (harness-log 'info "naming %s: renamed to %S meanwhile, so %S is dropped" sid now name)
      (harness-resolve promise now))))

(defun harness-naming--on-event (sid before promise)
  "Return the event handler of a naming request for session SID.
It gathers the reply and settles PROMISE when the request is done,
storing the name unless the session's name is no longer BEFORE."
  (let ((text ""))
    (lambda (ev)
      (pcase (plist-get ev :type)
        ('text (setq text (concat text (plist-get ev :delta))))
        ('done
         (let* ((reason (plist-get ev :stop-reason))
                (name (harness-naming-sanitise text))
                (problem (cond ((memq reason '(error cancelled))
                                (or (plist-get ev :error) (format "%s" reason)))
                               ((null name) "the model returned no usable title"))))
           (if problem
               (harness-naming--fail sid promise problem)
             (condition-case err
                 (harness-naming--store sid name before promise)
               (error (harness-naming--fail sid promise err))))))
        (_ nil)))))

(defun harness-naming--request (session state promise)
  "Name SESSION from its whole conversation with provider STATE, settling PROMISE."
  (let ((sid (plist-get session :id)))
    (harness-call
     'provider/complete
     (list :model (plist-get session :model) :session session
           :system (harness-naming--system-prompt session)
           :messages (harness-naming--messages sid)
           :tools nil :provider-state state :max-tokens harness-naming--max-tokens
           :on-event (harness-naming--on-event sid (plist-get session :name) promise)))))

(defun harness-naming--ask (model session system opening)
  "Ask MODEL for a title of OPENING; return a promise of the sanitised title.
OPENING is (OPENING . LATEST), as `harness-naming--opening' returns.
SESSION is the session record the request carries, `:id', `:cwd' and
`:host' only; SYSTEM its system prompt.  The request stands on its
own: no transcript, no provider state, no tools and no thinking, and
`:ephemeral', so a hosted provider answers it apart from any session's
conversation.  The promise rejects with a message when the provider
fails (at once or later), when the reply holds no usable title, and
when `harness-naming--timeout' seconds pass first, which cancels the
request."
  (let ((promise (harness-make-promise))
        (text "") (timer nil) (handle nil))
    (cl-flet ((finish (ok value)
                (unless (harness-promise-settled-p promise)
                  (when timer (cancel-timer timer))
                  (if ok (harness-resolve promise value) (harness-reject promise value)))))
      (setq timer (run-at-time harness-naming--timeout nil
                               (lambda ()
                                 (finish nil "the model took too long")
                                 (when handle (ignore-errors (funcall (plist-get handle :cancel)))))))
      (condition-case err
          (setq handle
                (harness-call
                 'provider/complete
                 (list :model model :session session :ephemeral t :system system
                       :messages (list (list :role 'user :content (harness-naming--opening-blocks opening)))
                       :tools nil :no-thinking t :max-tokens harness-naming--max-tokens
                       :on-event
                       (lambda (ev)
                         (pcase (plist-get ev :type)
                           ('text (setq text (concat text (plist-get ev :delta))))
                           ('done
                            (let ((reason (plist-get ev :stop-reason))
                                  (name (harness-naming-sanitise text)))
                              (cond ((memq reason '(error cancelled))
                                     (finish nil (or (plist-get ev :error) (format "%s" reason))))
                                    ((null name) (finish nil "the model returned no usable title"))
                                    (t (finish t name)))))
                           (_ nil))))))
        (error (finish nil (harness-error-message err)))))
    promise))

(defun harness-naming--opening-request (session promise)
  "Name SESSION from its opening message with the naming model, settling PROMISE.
The request stands on its own, beside the session's turn
\(`harness-naming--ask'): the session record it carries has no provider
state, so the session's conversation never sees it."
  (let* ((sid (plist-get session :id))
         (before (plist-get session :name))
         (opening (or (harness-naming--opening sid)
                      (signal 'harness-error (list "the session has no message to name it from")))))
    (harness-then (harness-naming--ask (harness-naming--model session)
                                       (list :id sid :cwd (plist-get session :cwd) :host (plist-get session :host))
                                       (harness-naming--system-prompt session)
                                       opening)
                  (lambda (name)
                    (condition-case err
                        (harness-naming--store sid name before promise)
                      (error (harness-naming--fail sid promise err)))
                    nil)
                  (lambda (err) (harness-naming--fail sid promise err) nil))))

(harness-defmethod naming/name (session-id &optional opts)
  "Ask the model for a title for SESSION-ID; return a promise of the name.
With OPTS `:opening' non-nil the title comes from the conversation's
opening message (and its latest one, when it has moved on since), in a
request of its own to `harness-naming-model' that runs beside the
session's turn: how a session is named as soon as its first message is
sent.  Without it the whole conversation is titled, on the session's
own model and a fork of its provider state where the provider can fork
one, so the cached prefix is reused.
The name is stored with `session/update', unless the session was renamed
while the model was asked: the promise then resolves with the name it
has.  A second call while one is running returns the running promise."
  (or (gethash session-id harness-naming--running)
      (let ((session (harness-call 'session/get session-id))
            (promise (harness-make-promise)))
        (puthash session-id promise harness-naming--running)
        ;; Both ways: `harness-finally' would log a failed naming as an error.
        (harness-then promise
                      (lambda (_) (remhash session-id harness-naming--running) nil)
                      (lambda (_) (remhash session-id harness-naming--running) nil))
        (harness-call 'session/hint session-id "Naming session…")
        (if (harness-json-true-p (plist-get opts :opening))
            (condition-case err
                (harness-naming--opening-request session promise)
              (error (harness-naming--fail session-id promise err)))
          (harness-then (harness-naming--forked-state session)
                        (lambda (state)
                          (condition-case err
                              (harness-naming--request session state promise)
                            (error (harness-naming--fail session-id promise err))))
                        (lambda (err) (harness-naming--fail session-id promise err))))
        promise)))

(defun harness-naming--close (model id)
  "Have MODEL's provider free what it kept for the one-off request ID."
  (ignore-errors (harness-call 'provider/close model id)))

(harness-defmethod naming/title (text &optional opts)
  "Ask for a title of TEXT, a first message; return a promise of the title.
This is the request that names a session from its first message
\(`naming/name' with `:opening') for a message with no session to name
yet: task mode names a task from its prompt this way while it waits for
a slot.  It goes to `harness-naming-model' for the model OPTS' `:model'
names (by default that model's cheap tier), ephemeral and without
thinking, under an id of its own that is closed once it is answered.
Nothing is stored and no session hears of it.  OPTS also give `:cwd'
and `:host', where the request runs, and go to the `naming/system-prompt'
filters as what is named, so that `:task' ID, say, has a task titled like
a ticket.  The promise resolves with the sanitised title, and rejects
when the request fails, gives no usable title or takes longer than
`harness-naming--timeout' seconds."
  (let ((model (harness-naming--model opts))
        (id (format "naming-%s" (harness-short-id 10))))
    (cond
     ((harness-string-blank-p text)
      (harness-rejected "there is no message to name it from"))
     ((null model) (harness-rejected "no model to ask for a title"))
     (t
      (harness-then
       (condition-case err
           (harness-naming--ask model
                                (list :id id
                                      :cwd (file-name-as-directory
                                            (expand-file-name (or (plist-get opts :cwd) default-directory)))
                                      :host (plist-get opts :host))
                                (harness-naming--system-prompt opts)
                                (cons (string-trim text) nil))
         ;; The system prompt's filters, say.
         (error (harness-rejected (harness-error-message err))))
       (lambda (title) (harness-naming--close model id) title)
       (lambda (err) (harness-naming--close model id) (harness-rejected err)))))))

;;;; Automatic naming

(defun harness-naming--auto-p (session)
  "Non-nil when SESSION is to be named from its first message now.
That is when it has no name, is of a kind that gets one (not btw or
subagent), has a message to name it from, and no `naming/auto-p' filter
\(value the verdict so far, args SESSION) says otherwise: task mode holds
it off a session whose task's title is on its way, which then names the
session."
  (and (harness-string-blank-p (plist-get session :name))
       (not (memq (plist-get session :kind) harness-naming--skip-kinds))
       (harness-naming--opening (plist-get session :id))
       (harness-run-filter 'naming/auto-p t session)))

(defun harness-naming--on-turn-started (session-id)
  "Name SESSION-ID from its first message as its turn starts, if it is nameless.
That is as soon as its first message is sent: the request runs beside
the turn (`naming/name' with `:opening'), so the name is there while
the turn works, however long it takes.  A session still nameless when
a later turn starts, because its naming failed, say, is named then.
See `harness-naming--auto-p' for the sessions that are."
  (when (and harness-naming-auto
             (harness-call 'session/exists-p session-id))
    (when (harness-naming--auto-p (harness-call 'session/get session-id))
      (harness-call 'naming/name session-id '(:opening t)))))

(defun harness-naming--name-running ()
  "Name the nameless sessions whose turn runs already, as if it just started.
A harness reloaded while turns run would leave them nameless until
their next turn, and a task's first turn lasts until the task is done:
the sessions whose turn ran across the reload that brought naming at
the start of turns stayed \"unnamed\" that way."
  (when (and harness-naming-auto (harness-method-exists-p 'agent/running))
    (dolist (sid (harness-call 'agent/running))
      (condition-case err
          (harness-naming--on-turn-started sid)
        (error (harness-log 'warn "naming %s at reload failed: %s" sid (harness-error-message err)))))))

(defun harness-naming--init ()
  "Subscribe automatic naming to the start of turns.
Naming once followed the end of turns: a harness reloaded from that
version drops that subscription here."
  (harness-off (cons 'agent/turn-ended 'harness-naming--on-turn-ended))
  (harness-on 'agent/turn-started #'harness-naming--on-turn-started))

(defun harness-naming--shutdown ()
  "Stop naming sessions automatically."
  (harness-off (cons 'agent/turn-started #'harness-naming--on-turn-started)))

(harness-naming--init)

;; A reload does not initialise the module again: the sessions whose
;; turn runs across it are named once everything is loaded again, the
;; modules' `naming/auto-p' filters included.
(when (harness-module-ready-p 'naming)
  (harness-run-soon #'harness-naming--name-running))

(harness-declare-event 'naming/done "(SESSION-ID NAME) after a session is named by the model.")
(harness-declare-event 'naming/failed "(SESSION-ID MESSAGE) when naming fails.")

(harness-define-module 'naming
  :doc "Name nameless sessions with a cheap model as soon as their first message is sent."
  :requires '(session provider agent)
  :init #'harness-naming--init
  :shutdown #'harness-naming--shutdown)

(provide 'harness-naming)
;;; harness-naming.el ends here
