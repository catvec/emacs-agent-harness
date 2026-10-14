;;; harness-ui-cache.el --- The expired prompt cache of a session  -*- lexical-binding: t; -*-

;;; Commentary:

;; A provider keeps the start of a conversation cached for a while after
;; a request used it: five minutes or an hour for Claude, hours for
;; DeepSeek (see `harness-cache-ttl').  A session left alone for longer
;; sends its whole context again uncached with its next message, which
;; costs more and answers slower.  The harness knows when each session's
;; requests last used the cache, the model they went to and how long its
;; provider keeps it: the session's `:cache', (:at TIME :ttl SECONDS
;; :expires TIME :model MODEL).  Once that moment is past, a panel above
;; the compose box says so, with how much context the next message sends
;; uncached and what that costs at list prices.  A session whose turn is
;; still running shows no panel, blocked on an answer included: its next
;; request is part of that turn, not the next message.  Nor does a
;; session this UI sent a message that has no answer yet
;; (`harness-ui-prompt-in-flight-p'; the answer to a prompt comes when
;; its turn ends).  The UI can be behind the harness -- an Emacs that
;; reads its socket late still holds the session idle, with the cache
;; stamp of the turn before -- and a panel saying the cache expired a
;; minute after the user's message would be false: the turn is running
;; and has just used the cache.
;;
;; It offers to compact the conversation first, so the next message sends
;; only what stands in for it (harness-ui-compact.el): a button for each
;; kind with what it costs (`compaction/estimate', asked once per thing
;; the panel says and drawn when it comes), the brief summary first.
;; That one is the cheap way out of a long conversation gone cold: a
;; cheap model reads the conversation's narrative -- every message,
;; tool calls in brief -- for cents, where a summary on the session's
;; model reads all of it uncached, as
;; carrying on would.  A transcript file asks no model at all.  The
;; buttons' keys work while point is on their line; in the compose box
;; they type, and C-c . and a key press it there
;; (`harness-compose-panel-key'), as the line under the buttons says.  A
;; session blocked on an answer is in the middle of a turn, so it shows no
;; panel at all.
;;
;; A cache can be dropped before its clock says so.  A redaction
;; (harness-redact.el) takes a secret out of a conversation and resets a
;; hosted session's provider conversation (Claude Code, Copilot), which
;; may hold the secret where the harness cannot reach it; the cache the
;; provider kept of that conversation goes with it, and the next message
;; opens a new one that is sent the redacted transcript as text, whole
;; and uncached.  The session's `:cache' then carries `:dropped', the
;; moment of the reset, which is its `:expires' too, so the panel shows
;; from then on, headed "dropped" and saying a redaction did it.  It
;; compares no cached price with the uncached one: none can be had.
;;
;; A cache serves one model, so a session switched to another model
;; finds nothing cached for it: the panel says so at once, with what the
;; new model's first request costs, and goes when that request caches the
;; conversation again (or the session switches back while the old cache
;; lasts).  A switch that starts a conversation of its own on the new
;; provider -- a hosted loop, handed over a summary or a transcript or
;; nothing -- sends none of the old one, and a compaction replaces it
;; with its summary: the session reports no cache then, and no panel
;; shows.  While the switch banner asks how to hand over
;; (harness-ui-handoff.el), the panel stays away: what the next request
;; sends depends on the answer, and the banner says what the cache
;; means for each.  So it does while a message sent to the session
;; waits on the question of what goes first, the cache being cold
;; (harness-cowboy.el, drawn by harness-ui-cowboy.el), and while the
;; compaction chosen there runs, the session running its turn.
;;
;; The panel comes on its own: each chat buffer has one timer, for the
;; moment its session's cache lapses, which draws the tail again then
;; (`harness-compose-redraw'), the switch banner included.  Nothing
;; polls.  A session update moves the timer, as a new request keeps the
;; cache longer, and the panel goes while the session runs -- a turn
;; waiting on an answer included -- to come back when the turn ends with
;; the cache lapsed.  So does a message sent: the panel goes as it is
;; sent, and comes back with its answer (or its failure) when the cache
;; lapsed (`harness-ui-prompt-functions').  The record the panel reads is
;; the newest the UI took in (`harness-ui-session'), the session list and
;; fetches included.  The panel names clock times, never ages, so it
;; stays true for as long as it shows without being drawn again.  A
;; session that never used a cache, a new one included, has no `:cache'
;; and never shows it.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)
(require 'harness-ui-compact)

(defvar harness-chat-panel-functions)
(defvar harness-chat-mode-hook)
(defvar harness-chat--session)
(defvar harness-ui-session-id)
(defvar harness-compose-redraw-function)
(defvar harness-ui-handoff--prompt)
(declare-function harness-chat--buffer-for "harness-ui-chat" (sid))
(declare-function harness-compose-redraw "harness-ui-compose" ())
(declare-function harness-compose-panel-hint "harness-ui-compose" (key))
(declare-function harness-chat--button "harness-ui-chat" (label action &rest props))
(declare-function harness-chat--kbd "harness-ui-chat" (key))
(declare-function harness-ui-cowboy-waiting-p "harness-ui-cowboy" (session-id))

(defgroup harness-ui-cache nil
  "Telling when a session's prompt cache has expired." :group 'harness-ui)

(defface harness-chat-cache-face
  '((((background light)) :background "#f8e6f4" :extend t)
    (((background dark)) :background "#3a2237" :extend t))
  "Background of the cache panel: the session's prompt cache has expired.
It shows when a redaction dropped the cache too.  An orchid of its own,
apart from the activity line's lavender, which shows in the same place
while the session runs."
  :group 'harness-ui-cache)

(harness-ui-define-icon harness-icon-clock "clock" "◷" "cache" "Time: a cache that lapsed.")

(defvar-local harness-ui-cache--shown nil
  "What this buffer's cache panel showed when last drawn, or nil for nothing.
See `harness-ui-cache--state'.")

(defvar-local harness-ui-cache--timer nil
  "Timer that draws this buffer's tail again when its session's cache lapses.")

(defvar-local harness-ui-cache--due nil
  "The moment `harness-ui-cache--timer' is set for, a float time.")

(defvar-local harness-ui-cache--estimate nil
  "What compacting this buffer's session costs, as its cache panel last asked.
A cons (STATE . ESTIMATE): STATE what the panel showed when it asked
\(`harness-ui-cache--state'), ESTIMATE the `compaction/estimate'
answer, `pending' while it is asked, or `failed'.")

(defvar-local harness-ui-cache--compacting nil
  "The kind of compaction the cache panel started in this buffer, while it runs.")

;;;; What the panel shows

(defun harness-ui-cache--session ()
  "Return the session of this chat buffer, as last heard.
That is the newest record the UI took in (`harness-ui-session'): the
session list and a fetch land there as well as every `_harness/session'
update, whereas this buffer's own copy (`harness-chat--session') is only
what the chat last took in from an update, and can be older.  It serves
once the session is gone from the cache, as the chat has it."
  (or (and harness-ui-session-id (harness-ui-session harness-ui-session-id))
      (bound-and-true-p harness-chat--session)))

(defun harness-ui-cache--other-model (session)
  "Return the model of SESSION's cache when it is not SESSION's model, else nil.
A cache serves the model that wrote it, so SESSION, switched since,
has nothing cached for its own.  Nil when either model is unknown: a
record without its model says nothing of a switch, as the server's
`harness-cowboy--cache-model' holds too."
  (let ((cached (plist-get (plist-get session :cache) :model))
        (model (plist-get session :model)))
    (and (stringp cached) (stringp model) (not (equal cached model)) cached)))

(defun harness-ui-cache--running-p (session)
  "Non-nil when SESSION's turn is still running, whatever its status reads.
A session waiting on an answer -- a tool approval, say -- reads
`blocked', but it is in the middle of a turn: its next request is part
of that turn, not the user's next message, which is what the panel
speaks of.  The live token figures the UI keeps for a session are
non-nil exactly while its turn runs (`harness-ui-session-live').  So is
a prompt this UI sent it that has no answer yet
\(`harness-ui-prompt-in-flight-p'): the answer comes when the turn ends.
The record of SESSION may be behind the harness, an Emacs that reads
its socket late having it idle still, with the cache stamp of the turn
before; the prompt is not."
  (let ((id (plist-get session :id)))
    (and (or (harness-ui-session-live id) (harness-ui-prompt-in-flight-p id)) t)))

(defun harness-ui-cache--state (session &optional now)
  "Return what the cache panel shows of SESSION at NOW, or nil for nothing.
NOW is the current time by default.  The panel shows once the cache
SESSION's requests last used has lapsed (its `:cache' `:expires' is
past), and at once when that cache is of a model SESSION no longer uses
\(`:from'), while SESSION waits for the user: idle or closed.  A cache a
redaction dropped (its `:dropped', the moment, which is its `:expires'
too) has lapsed from then on, however long its provider would have
kept it; the state carries `:dropped' for the panel to say so.  A
session whose turn is still running shows nothing: a session blocked on
an answer is in the middle of a turn, and the panel speaks of the
user's next message, which only a session that is not running has.  So does a
session this UI sent a prompt that has no answer yet
\(`harness-ui-cache--running-p'), whatever its record reads.  States
that read the same are `equal', so a session update that changes
nothing the panel says does not draw it again."
  (let* ((cache (plist-get session :cache))
         (expires (plist-get cache :expires))
         (dropped (plist-get cache :dropped))
         (from (harness-ui-cache--other-model session))
         (status (format "%s" (plist-get session :status))))
    (when (and (numberp expires)
               (member status '("idle" "inactive"))
               (not (harness-ui-cache--running-p session))
               (or from (>= (or now (float-time)) expires)))
      (append (list :at (plist-get cache :at) :ttl (plist-get cache :ttl) :expires expires
                    :context (plist-get (plist-get session :usage) :context)
                    :model (plist-get session :model)
                    :from from)
              (and (numberp dropped) (list :dropped dropped))))))

(defun harness-ui-cache--dropped (state)
  "Return when a redaction dropped the cache STATE speaks of, or nil.
That is STATE's `:dropped'.  A cache held for another model (`:from')
is cold for that reason, whatever became of it: the model the session
uses now has none of it either way, so it reads as that."
  (let ((dropped (plist-get state :dropped)))
    (and (numberp dropped) (not (plist-get state :from)) dropped)))

(defun harness-ui-cache--asked-p (session)
  "Non-nil while SESSION waits on the question about its cold cache.
That is a pending question with a `:cowboy' (harness-cowboy.el), in
SESSION's own pending list or among the requests the UI knows of."
  (or (cl-some (lambda (item) (plist-get (plist-get item :payload) :cowboy))
               (append (plist-get session :pending) nil))
      (and (fboundp 'harness-ui-cowboy-waiting-p)
           (harness-ui-cowboy-waiting-p (or (plist-get session :id) harness-ui-session-id)))))

(defun harness-ui-cache--current (session &optional now)
  "Return what this buffer's cache panel shows of SESSION at NOW, or nil.
That is `harness-ui-cache--state', save while the switch banner asks
how to hand over, or while a message waits on the question about the
cold cache (`harness-ui-cache--asked-p'): what the next request sends
depends on the answer, and the banner or the question says what the
cache means for each."
  (unless (or (bound-and-true-p harness-ui-handoff--prompt)
              (harness-ui-cache--asked-p session))
    (harness-ui-cache--state session now)))

(defun harness-ui-cache--duration (seconds)
  "Describe SECONDS, how long a cache lasts, in words: \"5 minutes\"."
  (pcase-let* ((s (max 1 (round seconds)))
               (`(,n . ,unit) (cond ((< s 120) (cons s "second"))
                                    ((< s 3600) (cons (round s 60) "minute"))
                                    ((< s 172800) (cons (round s 3600) "hour"))
                                    (t (cons (round s 86400) "day")))))
    (format "%d %s%s" n unit (if (= n 1) "" "s"))))

(defun harness-ui-cache--price (tokens model key)
  "Return what TOKENS tokens cost at MODEL's KEY price, or nil.
The price, in US dollars per million tokens, is the catalogue's."
  (let ((price (plist-get (plist-get (gethash model harness-ui--models) :pricing) key)))
    (and (numberp tokens) (> tokens 0) (numberp price) (>= price 0)
         (/ (* tokens price) 1e6))))

(defun harness-ui-cache--uncached-cost (state)
  "Return what the context of STATE costs sent uncached, or nil.
That is writing it to the cache at the model's list price: the higher
of the cache-write and the input price, as a provider that does not
charge for writes (DeepSeek, whose catalogue says 0) still charges the
input.  Nil when the catalogue prices neither."
  (let* ((tokens (plist-get state :context))
         (model (plist-get state :model))
         (written (harness-ui-cache--price tokens model :cache-write))
         (input (harness-ui-cache--price tokens model :input)))
    (if (and written input) (max written input) (or written input))))

(defun harness-ui-cache--cost (state)
  "Return what the context of STATE costs uncached and cached, or nil.
A cons (UNCACHED . CACHED) at the model's list prices: written to the
cache again against read back from it (`harness-ui-cache--uncached-cost').
Nil when the catalogue does not price both."
  (let ((uncached (harness-ui-cache--uncached-cost state))
        (cached (harness-ui-cache--price (plist-get state :context) (plist-get state :model) :cache-read)))
    (and uncached cached (> uncached cached) (cons uncached cached))))

(defun harness-ui-cache--help (state)
  "Return the tooltip of the cache panel for STATE.
It says why nothing is cached: the cache of the model the session used
before, a cache a redaction dropped, or one that lapsed."
  (let ((dropped (harness-ui-cache--dropped state)))
    (concat
     (cond
      ((plist-get state :from)
       (format (concat "A provider caches a conversation for one model only.\n"
                       "This session's requests last used the cache of %s, at %s; %s has none of it.\n")
               (harness-ui-model-label (plist-get state :from))
               (format-time-string "%H:%M:%S" (plist-get state :at))
               (harness-ui-model-label (plist-get state :model))))
      (dropped
       (format (concat "A redaction took a secret out of this conversation at %s"
                       " and dropped the provider's copy of it, and its prompt cache with it.\n")
               (format-time-string "%H:%M:%S" dropped)))
      (t
       (format (concat "The provider keeps the start of a conversation cached for %s after a request uses it.\n"
                       "This session's requests last used the cache at %s, so it lapsed at %s.\n")
               (harness-ui-cache--duration (plist-get state :ttl))
               (format-time-string "%H:%M:%S" (plist-get state :at))
               (format-time-string "%H:%M:%S" (plist-get state :expires)))))
     (format "Your next message sends the whole context, %s tokens, at the uncached rate, and caches it again."
             (harness-format-tokens (plist-get state :context))))))

(defun harness-ui-cache--heading (state now)
  "Return the first line of the cache panel for STATE, drawn at NOW.
It says why nothing is cached: the cache lapsed, and when; a redaction
dropped it, and when; or it is the cache of the model the session used
before."
  (let ((from (plist-get state :from))
        (dropped (harness-ui-cache--dropped state)))
    (concat
     " " (propertize (concat (harness-ui-icon 'harness-icon-clock)
                             (cond (from " Prompt cache cold")
                                   (dropped " Prompt cache dropped")
                                   (t " Prompt cache expired")))
                     'face 'harness-label-face)
     "  "
     (propertize (cond (from
                        (format "cached for %s, not %s"
                                (harness-ui-model-label from)
                                (harness-ui-model-label (plist-get state :model))))
                       (dropped
                        (format "at %s, by a redaction" (harness-ui-format-clock dropped now)))
                       (t
                        (format "at %s, %s after its last use"
                                (harness-ui-format-clock (plist-get state :expires) now)
                                (harness-ui-cache--duration (plist-get state :ttl)))))
                 'face 'harness-dim-face)
     "\n")))

(defun harness-ui-cache--cost-text (state)
  "Return how the line under the heading ends for STATE: a cost, or a period.
A lapsed cache, or a model's, compares the uncached price with the
cached one it would have cost.  A cache a redaction dropped cannot be
had, so it names the uncached price only."
  (if (harness-ui-cache--dropped state)
      (if-let* ((uncached (harness-ui-cache--uncached-cost state)))
          (format ": about %s, at list prices." (harness-format-cost uncached))
        ".")
    (if-let* ((cost (harness-ui-cache--cost state)))
        (format ": about %s instead of %s, at list prices."
                (harness-format-cost (car cost)) (harness-format-cost (cdr cost)))
      ".")))

(defun harness-ui-cache--banner (state now &optional offer)
  "Return the cache panel for STATE, drawn at NOW.
OFFER, when given, is the line offering to compact the conversation
first (`harness-ui-cache--offer'), which goes last."
  (let* ((tokens (plist-get state :context))
         (string
          (concat
           (harness-ui-cache--heading state now)
           (propertize (concat "   Your next message"
                               (if (and (numberp tokens) (> tokens 0))
                                   (format " re-sends ~%s tokens uncached" (harness-format-tokens tokens))
                                 " re-sends the conversation uncached")
                               (harness-ui-cache--cost-text state))
                       'wrap-prefix "   ")
           "\n")))
    (add-text-properties 0 (length string) (list 'help-echo (harness-ui-cache--help state)) string)
    (when offer (setq string (concat string offer)))
    (add-text-properties 0 (length string) (list 'harness-ui-cache-panel t) string)
    (harness-ui-add-face string 'harness-chat-cache-face)))

;;;; Compacting first

(defun harness-ui-cache--estimated (buffer state estimate)
  "Keep ESTIMATE, what compacting costs, for the panel of BUFFER showing STATE.
The tail is drawn again when the panel still shows STATE."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (equal (car harness-ui-cache--estimate) state)
        (setq harness-ui-cache--estimate (cons state estimate))
        (when (equal state harness-ui-cache--shown)
          (harness-ui-cache--redraw))))))

(defun harness-ui-cache--estimate (state)
  "Return what compacting costs while the panel shows STATE, or nil.
The `compaction/estimate' answer, asked once per STATE; nil while it is
asked, and its answer draws the tail again, or when asking failed."
  (let ((known (and (equal (car harness-ui-cache--estimate) state)
                    (cdr harness-ui-cache--estimate))))
    (cond ((consp known) known)
          (known nil)
          (harness-ui-session-id
           (let ((buffer (current-buffer)))
             (setq harness-ui-cache--estimate (cons state 'pending))
             (harness-ui-call "_harness/compaction/estimate" (list :session-id harness-ui-session-id)
                              (lambda (estimate) (harness-ui-cache--estimated buffer state estimate))
                              (lambda (_err) (harness-ui-cache--estimated buffer state 'failed) nil))
             nil)))))

(defun harness-ui-cache--compact (buffer kind)
  "Compact the session of BUFFER as KIND, from its cache panel.
The panel says so while it runs, and goes once the conversation is
compacted, as nothing of it is cached any more."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (unless harness-ui-cache--compacting
        (setq harness-ui-cache--compacting kind)
        (harness-ui-cache--redraw)
        (harness-ui-compact-run harness-ui-session-id kind
                                (lambda (_node)
                                  (when (buffer-live-p buffer)
                                    (with-current-buffer buffer
                                      (setq harness-ui-cache--compacting nil)
                                      (harness-ui-cache--redraw)))))))))

(defun harness-ui-cache--command (buffer kind)
  "Return the command compacting the session of BUFFER as KIND."
  (lambda () (interactive) (harness-ui-cache--compact buffer kind)))

(defun harness-ui-cache--offer-help (estimate kind)
  "Return the tooltip of the button compacting as KIND, as ESTIMATE says.
ESTIMATE is nil while it is asked."
  (let ((entry (assq kind harness-ui-compact-kinds))
        (cost (harness-ui-compact-cost-text estimate kind)))
    (concat (harness-ui-compact-label kind) (if cost (format " (%s)" cost) "") ": "
            (if estimate
                (harness-ui-compact-describe estimate kind)
              (concat (nth 3 entry) "."))
            (format "\nPress %c on this line, or click, to compact the conversation this way."
                    (nth 1 entry)))))

(defun harness-ui-cache--offer (state)
  "Return the line of the cache panel for STATE that offers to compact, or nil.
A button for each kind of compaction (`harness-ui-compact-kinds') says
what it costs as the harness estimates it; while it is asked, or
without a price, the buttons only name the kinds.  While a compaction
the panel started runs, the line says so instead."
  (cond
   (harness-ui-cache--compacting
    (propertize (format "   %s\n" (harness-ui-compact-doing harness-ui-cache--compacting))
                'face 'harness-dim-face))
   (t
    (let* ((buffer (current-buffer))
           (estimate (harness-ui-cache--estimate state))
           (map (make-sparse-keymap))
           (line
            (concat
             (propertize "   Compact it first" 'face 'harness-label-face)
             (mapconcat
              (lambda (entry)
                (pcase-let* ((`(,kind ,key . ,_) entry)
                             (cost (harness-ui-compact-cost-text estimate kind)))
                  (define-key map (char-to-string key) (harness-ui-cache--command buffer kind))
                  (concat "  " (harness-chat--kbd (format " %c " key)) " "
                          (harness-chat--button (harness-ui-compact-label kind)
                                                (harness-ui-cache--command buffer kind)
                                                :help (harness-ui-cache--offer-help estimate kind))
                          (if cost (propertize (format " (%s)" cost) 'face 'harness-dim-face) ""))))
              harness-ui-compact-kinds "")
             "\n"
             ;; The keys type in the compose box: this is how to press one there.
             "   " (harness-compose-panel-hint (char-to-string (cadr (car harness-ui-compact-kinds)))) "\n")))
      ;; The lines are a panel of the compose box too (`harness-compose-panel-key').
      (add-text-properties 0 (length line) (list 'wrap-prefix "   " 'harness-compose-panel 'cache) line)
      (harness-ui-with-keymap line map)))))

;;;; Showing it on time

(defun harness-ui-cache--cancel ()
  "Stop this buffer's cache timer, if any."
  (when (timerp harness-ui-cache--timer)
    (cancel-timer harness-ui-cache--timer))
  (setq harness-ui-cache--timer nil
        harness-ui-cache--due nil))

(defun harness-ui-cache--schedule (session)
  "Set this buffer's timer for the moment SESSION's cache lapses.
Nothing is set when it has lapsed already, SESSION has no cache, or
it is another model's, which is cold already; a timer already set for
that moment stays."
  (let* ((expires (plist-get (plist-get session :cache) :expires))
         (due (and (numberp expires) (> expires (float-time))
                   (not (harness-ui-cache--other-model session))
                   expires)))
    (unless (and due (equal due harness-ui-cache--due)
                 (memq harness-ui-cache--timer timer-list))
      (harness-ui-cache--cancel)
      (when due
        (setq harness-ui-cache--due due
              harness-ui-cache--timer (run-at-time (- due (float-time)) nil
                                                   #'harness-ui-cache--lapse (current-buffer)))))))

(defun harness-ui-cache--redraw ()
  "Draw the tail of this chat buffer again."
  (when (functionp harness-compose-redraw-function)
    (harness-compose-redraw)))

(defun harness-ui-cache--sync ()
  "Bring this chat buffer's cache timer and panel up to date with its session.
The tail is drawn again only when what the panel shows changed."
  (let ((session (harness-ui-cache--session)))
    (harness-ui-cache--schedule session)
    (unless (equal (harness-ui-cache--current session) harness-ui-cache--shown)
      (harness-ui-cache--redraw))))

(defun harness-ui-cache--lapse (buffer)
  "Draw BUFFER's tail again, its session's cache having lapsed by now.
The cache panel shows from now on, or, while the switch banner asks
instead, the banner says the cache expired; drawing sets the next
timer, if any."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq harness-ui-cache--timer nil
            harness-ui-cache--due nil)
      (harness-ui-cache--redraw))))

(defun harness-ui-cache--panel ()
  "Return the cache panel when this session's prompt cache is cold, else nil.
On `harness-chat-panel-functions'.  Drawing sets the timer for when
the cache lapses too, so a buffer that just opened shows it on time."
  (let* ((session (harness-ui-cache--session))
         (now (float-time))
         (state (harness-ui-cache--current session now)))
    (setq harness-ui-cache--shown state)
    (harness-ui-cache--schedule session)
    (and state (harness-ui-cache--banner state now (harness-ui-cache--offer state)))))

(defun harness-ui-cache--sync-session (sid)
  "Bring the cache timer and panel of session SID's chat buffer up to date.
Nothing happens without a chat buffer for SID that shows the panel."
  (when-let* ((buffer (and (fboundp 'harness-chat--buffer-for) (harness-chat--buffer-for sid))))
    (with-current-buffer buffer
      (when (memq #'harness-ui-cache--panel harness-chat-panel-functions)
        (harness-ui-cache--sync)))))

(defun harness-ui-cache--on-update (sid update)
  "Follow the record of session SID, which UPDATE may bring.
On `harness-ui-update-functions', after the chat has taken it in."
  (when (equal (plist-get update :sessionUpdate) "_harness/session")
    (harness-ui-cache--sync-session sid)))

(defun harness-ui-cache--on-prompt (sid)
  "Follow the prompts in flight to session SID, which just changed.
On `harness-ui-prompt-functions'.  A message sent takes the panel away
at once, without waiting for the news that the session runs.  The
answer to the last prompt brings it back, the turn having ended with the
cache lapsed, or its failure: the panel speaks of the next message, and
the record the UI holds says whether the cache lapsed."
  (harness-ui-cache--sync-session sid))

;;;; Setup

(defun harness-ui-cache--setup ()
  "Show the cache panel in this chat buffer."
  (add-hook 'harness-chat-panel-functions #'harness-ui-cache--panel t t)
  (add-hook 'kill-buffer-hook #'harness-ui-cache--cancel nil t))

(defun harness-ui-cache--init-hooks ()
  "Add the hooks that came after the module's first version.
A reload does not initialise a running module again, so the file adds
them itself when the module is ready (below)."
  (add-hook 'harness-ui-prompt-functions #'harness-ui-cache--on-prompt t))

(defun harness-ui-cache--init ()
  "Add the cache panel to every chat buffer, those open already included."
  (with-eval-after-load 'harness-ui-chat
    (add-hook 'harness-chat-mode-hook #'harness-ui-cache--setup)
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (derived-mode-p 'harness-chat-mode)
          (harness-ui-cache--setup)))))
  (add-hook 'harness-ui-update-functions #'harness-ui-cache--on-update t)
  (harness-ui-cache--init-hooks))

(harness-define-module 'ui-cache
  :doc "Warns above a session's compose box once its prompt cache has expired or been dropped, offering to compact."
  :requires '(ui ui-chat)
  :init #'harness-ui-cache--init)

(when (harness-module-ready-p 'ui-cache)
  (harness-ui-cache--init-hooks))

(provide 'harness-ui-cache)
;;; harness-ui-cache.el ends here
