;;; harness-cowboy.el --- What a message does first when the prompt cache went cold  -*- lexical-binding: t; -*-

;;; Commentary:

;; A provider keeps the start of a conversation cached for a while after
;; a request used it (a session's `:cache', see harness-session.el).  A
;; message that reaches a session after that -- the user back after a
;; while, feedback on a task that sat in review for a day, another
;; session's agent writing to it, the merge queue reporting a conflict
;; -- sends the whole conversation again uncached: for a long one, much
;; of what the session ever cost, paid at once for a cache nothing reads.
;;
;; Cowboy compaction is the quick way out the switch banner offered for
;; a switch of provider (harness-handoff.el): replace the conversation
;; with something small before the message goes, rather than send it
;; all again.  This module makes it part of every turn.  Its
;; `agent/before-turn' gate (`harness-cowboy--gate') holds a turn whose
;; session's cache lapsed -- or is held for a model the session no
;; longer uses, which caches nothing for the model the message goes to
;; -- whoever sent the message, and asks what goes first
;; (`harness-cowboy-choices'):
;;
;; - `brief'      a brief summary by a cheap model, from the whole
;;                narrative, tool calls in brief: cents;
;; - `summary'    a summary by the session's model, which reads all of
;;                the conversation again uncached;
;; - `transcript' the conversation written to a file the model reads as
;;                it needs; no model asked;
;; - `fresh'      nothing carried over: the model starts afresh and looks
;;                back when it needs to; no model asked;
;; - `carry-on'   the whole conversation, uncached, as before;
;; - `ignore'     the same, and nothing else: no note, no compaction,
;;                nothing added to the conversation at all;
;; - `hold'       not now: the message is kept and the turn does not start.
;;
;; Whatever goes first, the conversation stays on record: a compaction
;; ends in a line pointing the model at the session_history tool
;; (harness-tools-sessions.el), which searches and reads what it
;; replaced, so nothing left out is out of the model's reach.
;;
;; A cache can go cold before its clock says so.  A redaction
;; (harness-redact.el) takes a secret out of a conversation, and the
;; hosted provider's own copy of it (Claude Code, Copilot) may hold the
;; secret where the harness cannot reach it, so the redaction drops that
;; conversation (`session/reset-provider'): the next message opens a new
;; one that gets the redacted transcript as text, a prefix the old cache
;; does not hold, and the whole of it is sent uncached.  The session's
;; `:cache' then says the cache is gone from the drop on (`:dropped',
;; which is its `:expires' too), so the gate finds it cold and asks at
;; once, in words that say why and with no cached price to compare with:
;; there is none to be had.
;;
;; The question is the harness's own (`question/ask'): pending on the
;; session, which is blocked on it, and answered like any question -- the
;; chat's cold-cache panel (harness-ui-cowboy.el), a popout, an ACP
;; client, typed text -- with a choice, or with "always" and a choice,
;; which makes it the default and stops the asking (`harness-cowboy-default'
;; and `harness-cowboy-ask', saved as any setting is).  That answer is a
;; lasting decision the harness keeps, which the chat offers to undo, and
;; then to redo, from any session (see "\"Always\": a lasting decision"
;; below).  Dismissing it holds the message.  Its payload's `:cowboy' says what each choice costs, for
;; the clients that draw more than the question; the others show it as an
;; ordinary question with its options.
;;
;; A session that never waits for the user (`harness-non-interactive') is
;; not asked, and neither is any session once asking is off: no judge
;; model weighs the choices, the default is taken.  The default default
;; is the brief summary, the one choice that never pays for the whole
;; conversation uncached and still leaves the model a summary to go on.
;; A summary that cannot be made falls back to the transcript, and that
;; to carrying on: the message always goes, unless held.
;;
;; The message waiting for the answer is not in the transcript yet: the
;; turn appends it once the gate settles, after the compaction (see
;; `harness-agent--start').  A harness that stops meanwhile loses the
;; turn, so the question's payload keeps the message (`:waiting-message')
;; and the session's settling at the next start puts it back in its
;; queue (`harness-session--settle').  A turn cancelled while the
;; question waits dismisses it.
;;
;; A compaction already under way answers the question before it is
;; asked: a message that comes while one of its session runs -- the user
;; compacted it from the cache panel, say -- waits for it
;; (`harness-compaction--wait-gate', ahead of this gate) and meets a
;; session the compaction left with no cache, which is not cold.  And a
;; message sent to the turn this gate holds while its compaction runs
;; waits with the turn (`agent/hold') and goes after the compaction, the
;; turn's own message first, rather than steering it: recorded at once it
;; would lie before the compaction node, where the model never reads it.
;;
;; The gate only sees a session whose own `:cache' lapsed.  A session
;; made from another -- the supervisor's worker, a fork of the
;; supervisor's whole conversation onto a model that has never read it
;; (harness-supervisor.el) -- has no `:cache' at all, so it is never
;; cold, and its first turn would send the whole conversation uncached
;; with nobody asked.  `cowboy/compact' is the gate's unasked path for
;; such a caller, before the session's first turn: it takes
;; `harness-cowboy-default' (never `hold', and nothing when the context
;; is under `harness-cowboy-min-context'), says so in a hint, compacts as
;; the gate does -- with the same fallbacks -- and resolves with the
;; choice taken.  It never rejects, so the caller can always go on.  It
;; records its decision as `cold-start' by default and, with `:why',
;; opens its hint with the caller's reason in place of the clock.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-policy)

(defvar harness-non-interactive)
(declare-function harness-compaction-history-p "harness-compaction" (session-id))

;;;; Settings

(defconst harness-cowboy-choices
  '((brief "Brief summary" "a cheap model summarises the narrative, tool calls in brief")
    (summary "Summary" "the session's model summarises it all, reading it uncached")
    (transcript "Transcript file" "the conversation goes to a file the model reads as it needs")
    (fresh "Start afresh" "nothing is carried over; the model looks back when it needs to")
    (carry-on "Carry on" "the whole conversation goes again, uncached")
    (ignore "Ignore" "send the whole context as it is, adding nothing")
    (hold "Not now" "the message waits; nothing is sent yet"))
  "What a message to a session whose prompt cache went cold can do first.
Each entry is (CHOICE LABEL WHAT), in the order they are offered.
CHOICE is a symbol, LABEL what the options and the UI call it, and WHAT
says what it does in a few words.  All but `hold' can be the default
\(`harness-cowboy-default'); `hold' is only ever an answer.")

(defcustom harness-cowboy-default 'brief
  "What a message to a session whose prompt cache went cold does first, unasked.
A provider caches a conversation for a while after each request; a
message that comes later sends all of it again, uncached.  This is
what goes first when nobody is asked: in a non-interactive session,
or in any once `harness-cowboy-ask' is off.  Answering the question
with \"always\" and a choice sets it.

`brief' (the default) has a cheap model write a short summary from the
conversation's narrative -- every user and assistant message, each tool
call and result in a line, never a payload -- so it never pays for the
whole conversation; `summary' has the session's model summarise all of it,
reading it uncached; `transcript' writes the conversation to a file
the model reads as it needs, and `fresh' carries nothing over, neither
asking any model; `carry-on' sends it all again as before and says so
in a hint; `ignore' sends it all again and adds nothing at all, no hint
included.  Whatever it is, the model can search and read the
conversation it replaced with the session_history tool."
  :type '(choice (const :tag "Brief summary: a cheap model reads the narrative, tool calls in brief" brief)
                 (const :tag "Summary: the session's model reads all of it, uncached" summary)
                 (const :tag "Transcript file: the model reads what it needs" transcript)
                 (const :tag "Start afresh: nothing carried over" fresh)
                 (const :tag "Carry on: the whole conversation, uncached" carry-on)
                 (const :tag "Ignore: send the whole context, adding nothing" ignore))
  :safe (lambda (v) (memq v '(brief summary transcript fresh carry-on ignore)))
  :group 'harness)

(defcustom harness-cowboy-ask t
  "Non-nil to ask what goes first when a message meets a cold prompt cache.
The question offers every choice with what it costs; the session waits
for the answer.  Nil takes `harness-cowboy-default' without asking, as
a non-interactive session always does.  Answering with \"always\" and a
choice turns this off."
  :type 'boolean :safe #'booleanp :group 'harness)

(defcustom harness-cowboy-min-context 0
  "Smallest context, in tokens, whose cold prompt cache is worth a question.
A message to a session whose next request would send less than this
goes on as it is: sending a small conversation uncached costs little.
0, the default, asks about every one."
  :type 'natnum :safe #'natnump :group 'harness)

(defun harness-cowboy--choice (value)
  "Return the choice VALUE names, a symbol or its name, or nil."
  (let ((sym (cond ((and value (symbolp value)) value)
                   ((stringp value) (intern-soft (downcase (string-trim value)))))))
    (and (assq sym harness-cowboy-choices) sym)))

(defun harness-cowboy-label (choice)
  "Return the label of CHOICE, a symbol."
  (or (nth 1 (assq choice harness-cowboy-choices)) (format "%s" choice)))

(defun harness-cowboy--default ()
  "Return the choice taken unasked: `harness-cowboy-default', or `brief'."
  (let ((choice (harness-cowboy--choice harness-cowboy-default)))
    (if (and choice (not (eq choice 'hold))) choice 'brief)))

;;;; When to ask

(defun harness-cowboy--cache-model (session)
  "Return the model of SESSION's prompt cache when SESSION no longer uses it.
A cache serves the model that wrote it, no other, so a session switched
since has nothing cached for its own however warm the old cache is, and
its next message sends the whole conversation uncached.  Nil when the
cache is SESSION's model's, or SESSION has none."
  (let ((cached (plist-get (plist-get session :cache) :model))
        (model (plist-get session :model)))
    (and (stringp cached) (stringp model) (not (equal cached model)) cached)))

(defun harness-cowboy--model-label (model)
  "Return the label people read for MODEL."
  (or (and (stringp model) (harness-method-exists-p 'provider/model)
           (plist-get (ignore-errors (harness-call 'provider/model model)) :label))
      model))

(defun harness-cowboy--dropped (session)
  "Return when a redaction dropped SESSION's prompt cache, or nil.
SESSION is a session plist.  That is its `:cache' `:dropped': the
moment `session/reset-provider' dropped the provider conversation the
cache held, which the cache's clock would have kept warm for longer."
  (let ((dropped (plist-get (plist-get session :cache) :dropped)))
    (and (numberp dropped) dropped)))

(defun harness-cowboy-cold-p (session &optional now)
  "Non-nil when SESSION's next message sends its conversation uncached.
SESSION is a session plist.  That is when the prompt cache its
requests last used lapsed by NOW (the current time by default), or
serves a model SESSION no longer uses -- a cache holds nothing for
another model, whatever its clock says -- and its context is at least
`harness-cowboy-min-context'.  A cache a redaction dropped has lapsed
from that moment (`harness-session--cache' reports its `:expires' as
the drop, and `:dropped'): the provider conversation that held it went
with the secret it may have held, and the next message opens a new one
with the whole transcript as text, so it asks as for any cold cache,
though the provider would have kept the old one longer.  A session with
no `:cache' never is: it has no conversation yet, or it started over (a
compaction, a new conversation on a provider of its own), and nothing of
it is cached to lose.  A switch to a provider that keeps its own
conversation drops the cache outright, so only a switch between models
that read the same conversation reaches here (`harness-session--cache')."
  (let* ((cache (plist-get session :cache))
         (expires (plist-get cache :expires))
         (context (plist-get (plist-get session :usage) :context)))
    (and (numberp expires)
         (or (harness-cowboy--cache-model session)
             (<= expires (or now (float-time))))
         (plist-get session :head)
         (>= (if (numberp context) context 0) (max 0 (or harness-cowboy-min-context 0)))
         t)))

(defun harness-cowboy--non-interactive-p (session)
  "Non-nil when SESSION never waits for the user.
A switch the policy sets wins, then the session's own, then
`harness-non-interactive' where the session works."
  (harness-json-true-p
   (cond ((harness-policy-entry 'harness-non-interactive)
          (cdr (harness-policy-entry 'harness-non-interactive)))
         ((plist-member session :non-interactive)
          (plist-get session :non-interactive))
         ((harness-method-exists-p 'config/get)
          (condition-case nil
              (harness-call 'config/get 'harness-non-interactive
                            (or (plist-get session :cwd) default-directory))
            (error (bound-and-true-p harness-non-interactive))))
         (t (bound-and-true-p harness-non-interactive)))))

(defun harness-cowboy--asks-p (session)
  "Non-nil when the cold cache of SESSION is asked about rather than decided."
  (and harness-cowboy-ask
       (not (harness-cowboy--non-interactive-p session))
       (harness-method-exists-p 'question/ask)))

;;;; What each choice costs

(defun harness-cowboy--estimate (session-id)
  "Return what compacting SESSION-ID costs (`compaction/estimate'), or nil."
  (and (harness-method-exists-p 'compaction/estimate)
       (condition-case err
           (harness-call 'compaction/estimate session-id)
         (error (harness-log 'warn "cowboy: no estimate for %s: %s" session-id (harness-error-short-message err))
                nil))))

(defun harness-cowboy--kind-estimate (estimate choice)
  "Return ESTIMATE's entry for compaction kind CHOICE, or nil."
  (cl-find-if (lambda (k) (eq (harness-cowboy--choice (plist-get k :kind)) choice))
              (plist-get estimate :kinds)))

(defun harness-cowboy--cost (estimate choice)
  "Return what CHOICE costs as ESTIMATE says, in US dollars, or nil.
Carrying on costs sending the context as things are; holding nothing."
  (pcase choice
    ('carry-on (plist-get estimate :carry-on))
    ('ignore (plist-get estimate :carry-on))
    ('hold nil)
    (_ (plist-get (harness-cowboy--kind-estimate estimate choice) :cost))))

(defun harness-cowboy-cost-text (estimate choice)
  "Return what CHOICE costs as ESTIMATE says, in a few words, or nil.
\"free\" for what asks no model, \"~$0.42\" for the rest, and for
carrying on what the uncached context costs."
  (let ((cost (harness-cowboy--cost estimate choice)))
    (cond ((memq choice '(transcript fresh)) "free")
          ((not (numberp cost)) nil)
          ((memq choice '(carry-on ignore)) (format "~%s uncached" (harness-format-cost cost)))
          (t (format "~%s" (harness-format-cost cost))))))

(defun harness-cowboy--duration (seconds)
  "Describe SECONDS in words: \"5 minutes\", \"3 hours\"."
  (pcase-let* ((s (max 1 (round seconds)))
               (`(,n . ,unit) (cond ((< s 120) (cons s "second"))
                                    ((< s 7200) (cons (round s 60) "minute"))
                                    ((< s 172800) (cons (round s 3600) "hour"))
                                    (t (cons (round s 86400) "day")))))
    (format "%d %s%s" n unit (if (= n 1) "" "s"))))

(defun harness-cowboy--clock (time)
  "Return TIME as a clock time, with its date when it is not today."
  (if (equal (format-time-string "%F" time) (format-time-string "%F"))
      (format-time-string "%H:%M" time)
    (format-time-string "%b %-d %H:%M" time)))

;;;; The question

(defun harness-cowboy--sender-text (from)
  "Return who sent the waiting message, FROM, as the question's subject.
Another session's agent goes by its session's name, else a short id:
a person reads the question."
  (pcase (harness-sender-kind from)
    ('nil "Your message")
    ('session
     (let ((name (plist-get from :name))
           (id (format "%s" (or (plist-get from :id) "?"))))
       (format "A message from session %s"
               (if (and (stringp name) (not (string-blank-p name)))
                   (format "%S" name)
                 (substring id 0 (min 8 (length id)))))))
    (_ (format "A message from %s" (harness-sender-description from)))))

(defun harness-cowboy--question-text (session estimate from &optional note)
  "Return the question about SESSION's cold cache.
ESTIMATE is `compaction/estimate''s answer, or nil; FROM who sent the
waiting message; NOTE, when given, opens the question (why it is asked
again).  A cache held for another model than SESSION's says so.  One a
redaction dropped (`harness-cowboy--dropped') says that instead of
when it lapsed, and names no cost of a cached request to compare with:
the new conversation the redaction made has no cache to be had."
  (let* ((cache (plist-get session :cache))
         (expires (plist-get cache :expires))
         (stale (harness-cowboy--cache-model session))
         (dropped (and (not stale) (harness-cowboy--dropped session)))
         (context (or (plist-get estimate :context) (plist-get (plist-get session :usage) :context)))
         (carry (plist-get estimate :carry-on))
         (cached (plist-get estimate :carry-on-cached)))
    (concat
     (if note (concat note "  ") "")
     (cond
      (stale
       (format (concat "%s waits: this session's prompt cache is cold.  It is held for %s,"
                       " which this session no longer uses, so %s has none of it.")
               (harness-cowboy--sender-text from)
               (harness-cowboy--model-label stale)
               (harness-cowboy--model-label (plist-get session :model))))
      (dropped
       (format (concat "%s waits: a redaction dropped this session's provider conversation at %s,"
                       " so no prompt cache holds it.")
               (harness-cowboy--sender-text from)
               (harness-cowboy--clock dropped)))
      (t
       (format "%s waits: this session's prompt cache lapsed at %s, %s ago."
               (harness-cowboy--sender-text from)
               (harness-cowboy--clock expires)
               (harness-cowboy--duration (- (float-time) expires)))))
     (format "  Carrying on sends the whole conversation%s uncached%s."
             (if (and (numberp context) (> context 0)) (format ", ~%s tokens," (harness-format-tokens context)) "")
             (if (and (not dropped) (numberp carry) (numberp cached) (> carry cached))
                 (format ": about %s instead of %s" (harness-format-cost carry) (harness-format-cost cached))
               ""))
     "  What goes first?  Answer \"always\" with a choice to make it the default and stop asking.")))

(defun harness-cowboy--option (choice estimate default)
  "Return the option offering CHOICE, with its cost as ESTIMATE says.
DEFAULT, the choice taken unasked, says so."
  (let ((cost (harness-cowboy-cost-text estimate choice)))
    (concat (harness-cowboy-label choice)
            (cond ((and cost (eq choice default)) (format " (%s, the default)" cost))
                  (cost (format " (%s)" cost))
                  ((eq choice default) " (the default)")
                  (t "")))))

(defun harness-cowboy--preview (text)
  "Return the first line of message TEXT worth showing, or nil.
A first line that is all one bracketed note, as the header another
session's message opens with (\"[Message from session ID]\"), says no
more than its sender does: the line after it shows instead."
  (when (stringp text)
    (let ((lines (cl-remove-if #'string-blank-p (split-string text "\n"))))
      (when (and (cdr lines) (string-match-p "\\`\\[[^]\n]*\\]\\'" (string-trim (car lines))))
        (setq lines (cdr lines)))
      (and lines (harness-first-line (string-trim (car lines)) 200)))))

(defun harness-cowboy--info (session-id session estimate from default message)
  "Return the `:cowboy' of the question about SESSION-ID's cold cache.
SESSION is its record, ESTIMATE `compaction/estimate''s answer or nil,
FROM who sent the waiting MESSAGE (:text :from), DEFAULT the choice
taken unasked.  It is what a client needs to draw more than the
question: when the cache lapsed and for which model, the context, what
carrying on costs, and per choice its cost, the model doing it and the
context after it.  `:cache-model', when it is not SESSION's `:model',
says the cache is held for a model the session no longer uses: its
`:cache-model-label' names it for people, and it holds nothing for
SESSION's own model however warm its clock says it is.  `:dropped',
when a redaction dropped the cache (the moment, which is `:expires'
too), says its provider conversation went with a secret taken out of
it, so no cache holds the session's conversation, whatever its clock
would have said; nil otherwise."
  (let ((cache (plist-get session :cache))
        (stale (harness-cowboy--cache-model session)))
    (list :at (plist-get cache :at) :ttl (plist-get cache :ttl) :expires (plist-get cache :expires)
          :dropped (harness-cowboy--dropped session)
          :cache-model (plist-get cache :model)
          :cache-model-label (and stale (harness-cowboy--model-label stale))
          :model (plist-get session :model)
          :model-label (or (plist-get estimate :model-label) (plist-get session :model))
          :context (or (plist-get estimate :context) (plist-get (plist-get session :usage) :context))
          :messages (plist-get estimate :messages)
          :carry-on (plist-get estimate :carry-on)
          :carry-on-cached (plist-get estimate :carry-on-cached)
          :from from
          :preview (harness-cowboy--preview (plist-get message :text))
          :default (symbol-name default)
          :history (and (fboundp 'harness-compaction-history-p)
                        (harness-compaction-history-p session-id)
                        t)
          :choices (mapcar (lambda (entry)
                             (let* ((choice (car entry))
                                    (kind (harness-cowboy--kind-estimate estimate choice)))
                               (list :choice (symbol-name choice) :label (nth 1 entry) :what (nth 2 entry)
                                     :cost (harness-cowboy--cost estimate choice)
                                     :cost-text (harness-cowboy-cost-text estimate choice)
                                     :by (plist-get kind :model-label)
                                     :after (plist-get kind :after))))
                           harness-cowboy-choices))))

;;;; Reading the answer

(defconst harness-cowboy--words
  '((hold "not now" "hold" "later" "cancel" "skip" "dismiss")
    (ignore "ignore" "send whole context" "send the whole context" "send whole conversation"
            "send the whole conversation" "send it all" "nothing" "leave it")
    (fresh "afresh" "fresh" "from scratch")
    (carry-on "carry on" "carry-on" "carryon" "continue" "keep going" "go on" "as is" "full")
    (transcript "transcript" "file")
    (brief "brief" "cheap")
    (summary "summary" "summarise" "summarize"))
  "Words that name a choice in a typed answer, the first choice to match winning.
`hold' comes first, so an answer that says not to do anything does
not; `ignore' before `carry-on', so \"ignore, send it all\" ignores
rather than carries on with a note; `brief' before `summary', so \"brief
summary\" is brief.")

(defconst harness-cowboy--keys
  '(("b" . brief) ("s" . summary) ("t" . transcript) ("f" . fresh) ("c" . carry-on)
    ("i" . ignore) ("q" . hold) ("h" . hold) ("n" . hold))
  "One-letter answers, the keys of the chat's panel.")

(defun harness-cowboy-parse-answer (text)
  "Return the choice TEXT answers, as (CHOICE . ALWAYS), or nil.
ALWAYS is non-nil when TEXT says \"always\": the choice becomes the
default and the question stops.  TEXT may be a choice's name (brief,
carry-on), its label or an option as offered (\"Brief summary (~$0.01)\"),
its number among the options, its key (b, s, t, f, c, i, q) or words
naming it (see `harness-cowboy--words').  Nil when it names none."
  (let* ((case-fold-search t)
         (raw (downcase (string-trim (or text ""))))
         (always (and (string-match-p "\\balways\\b" raw) t))
         (rest (string-trim (replace-regexp-in-string "\\balways\\b[:,]?" "" raw)))
         (rest (string-trim rest "[ \t\n\"'“”.:!-]+" "[ \t\n\"'“”.:!-]+"))
         (choice
          (or (harness-cowboy--choice (replace-regexp-in-string " " "-" rest))
              (cdr (assoc rest harness-cowboy--keys))
              (and (string-match-p "\\`[1-9]\\'" rest)
                   (car (nth (1- (string-to-number rest)) harness-cowboy-choices)))
              (car (cl-find-if (lambda (entry) (string-prefix-p (downcase (nth 1 entry)) rest))
                               harness-cowboy-choices))
              (car (cl-find-if (lambda (entry)
                                 (cl-some (lambda (word)
                                            (string-match-p (concat "\\b" (regexp-quote word) "\\b") rest))
                                          (cdr entry)))
                               harness-cowboy--words)))))
    (and choice (cons choice always))))

;;;; "Always": a lasting decision
;;
;; An "always" answer changes two settings for every session, so it is
;; a lasting decision the harness keeps (harness-decisions.el), of the
;; kind `cowboy', with the settings before it and after it.  The hint
;; written right after it names it (`:meta' `:decision'), and so does
;; every hint written later, in any session, where the default it set
;; went first unasked (`:decided-by', see `harness-cowboy--hint'): the
;; chat offers its undo, and then its redo, on each.  Undo puts both
;; settings back as they were before it -- asking on, the old default --
;; while they still hold what the answer set; redo sets them again while
;; they still hold what the undo put back.  Settings changed by hand in
;; between are left as they are, and the decision ends there.

(defun harness-cowboy--settings ()
  "Return what the cold-cache settings hold now, as a decision records them.
That is (:default CHOICE :ask BOOL), CHOICE the name of the choice taken
unasked (`harness-cowboy--default') and BOOL t or `:false', so it
travels as JSON."
  (list :default (symbol-name (harness-cowboy--default)) :ask (if harness-cowboy-ask t :false)))

(defun harness-cowboy--settings-equal (a b)
  "Non-nil when cold-cache settings A and B say the same.
Each is as `harness-cowboy--settings' returns it, perhaps back from JSON."
  (and (eq (harness-cowboy--choice (plist-get a :default)) (harness-cowboy--choice (plist-get b :default)))
       (eq (and (harness-json-true-p (plist-get a :ask)) t)
           (and (harness-json-true-p (plist-get b :ask)) t))))

(defun harness-cowboy--set-settings (settings)
  "Make the cold-cache settings hold SETTINGS, saved as Settings saves them.
SETTINGS is as `harness-cowboy--settings' returns it.  Signal when one
cannot be saved, as when the policy sets it."
  (let ((choice (harness-cowboy--choice (plist-get settings :default)))
        (ask (and (harness-json-true-p (plist-get settings :ask)) t)))
    (if (harness-method-exists-p 'config/set)
        (progn (harness-call 'config/set 'harness-cowboy-default choice)
               (harness-call 'config/set 'harness-cowboy-ask ask))
      (harness-save-user-option 'harness-cowboy-default choice)
      (harness-save-user-option 'harness-cowboy-ask ask))))

(defun harness-cowboy--decision-text (choice)
  "Return what an \"always\" answer of CHOICE does, in words."
  (format "Always %s when the prompt cache is cold, without asking"
          (if (eq choice 'ignore)
              "ignore it and send the whole context"
            (harness-cowboy--choice-text choice nil))))

(defun harness-cowboy--record-decision (session-id choice before)
  "Keep the \"always\" answer of CHOICE in SESSION-ID as a lasting decision.
BEFORE is what the settings held before it.  Return the decision's id,
or nil without the decisions module or when keeping it failed (logged)."
  (when (harness-method-exists-p 'decision/record)
    (condition-case err
        (plist-get (harness-call 'decision/record 'cowboy session-id (harness-cowboy--decision-text choice)
                                 (list :choice (symbol-name choice) :before before
                                       :after (list :default (symbol-name choice) :ask :false)))
                   :id)
      (error (harness-log 'warn "cowboy: could not keep the answer in %s as a decision: %s"
                          session-id (harness-error-short-message err))
             nil))))

(defun harness-cowboy--remember (choice &optional session-id)
  "Make CHOICE the default and stop asking, as an \"always\" answer says.
Both settings are saved as the settings page saves them (`config/set'),
and the answer, given in SESSION-ID, is kept as a lasting decision with
the settings before it, which can be undone and redone from any
session (`harness-cowboy--record-decision').  Return (:decision ID)
once saved, ID nil when no decision was kept, else (:failed WHY): an
option the policy sets, say, which then stays as it is."
  (let ((before (harness-cowboy--settings)))
    (condition-case err
        (progn
          (harness-cowboy--set-settings (list :default (symbol-name choice) :ask :false))
          (list :decision (harness-cowboy--record-decision session-id choice before)))
      (error (let ((msg (harness-error-short-message err)))
               (harness-log 'warn "cowboy: could not make %s the default: %s" choice msg)
               (list :failed msg))))))

(defun harness-cowboy--undone-text (record)
  "Return what undoing the \"always\" answer RECORD keeps did, in words."
  (let* ((before (plist-get record :before))
         (old (harness-cowboy--choice (plist-get before :default)))
         (default (and old (not (eq old (harness-cowboy--choice (plist-get record :choice))))
                       (format "“%s” is the default again" (harness-cowboy-label old)))))
    (cond ((harness-json-true-p (plist-get before :ask))
           (concat "Undone: asking again what goes first when the prompt cache is cold"
                   (if default (concat ", and " default) "")))
          (default (format "Undone: %s when the prompt cache is cold" default))
          (t "Undone: the cold-cache settings are as they were before it"))))

(defun harness-cowboy--decision-undo (decision)
  "Undo the \"always\" answer DECISION keeps: the `:undo' of the kind `cowboy'.
While the settings hold what the answer set, they go back to what they
held before it.  Return (OUTCOME . MESSAGE), as
`harness-decisions-define-kind' says."
  (let* ((record (plist-get decision :record))
         (now (harness-cowboy--settings)))
    (cond ((harness-cowboy--settings-equal now (plist-get record :after))
           (harness-cowboy--set-settings (plist-get record :before))
           (cons 'undone (harness-cowboy--undone-text record)))
          ((harness-cowboy--settings-equal now (plist-get record :before))
           (cons 'changed "Not undone: the cold-cache settings were put back since, so they stay as they are"))
          (t (cons 'changed "Not undone: the cold-cache settings changed since (in Settings, say), so they stay as they are")))))

(defun harness-cowboy--decision-redo (decision)
  "Redo the \"always\" answer DECISION keeps: the `:redo' of the kind `cowboy'.
While the settings hold what its undo put back, they hold what the
answer set again.  Return (OUTCOME . MESSAGE), as
`harness-decisions-define-kind' says."
  (let* ((record (plist-get decision :record))
         (now (harness-cowboy--settings)))
    (cond ((harness-cowboy--settings-equal now (plist-get record :before))
           (harness-cowboy--set-settings (plist-get record :after))
           (list 'done))
          ((harness-cowboy--settings-equal now (plist-get record :after))
           (cons 'changed "Not redone: the cold-cache settings are so again already (another answer, say), so they stay as they are"))
          (t (cons 'changed "Not redone: the cold-cache settings changed since (in Settings, say), so they stay as they are")))))

(declare-function harness-decisions-define-kind "harness-decisions" (kind &rest spec))

(with-eval-after-load 'harness-decisions
  (harness-decisions-define-kind 'cowboy
                                 :undo #'harness-cowboy--decision-undo
                                 :redo #'harness-cowboy--decision-redo))

(defun harness-cowboy--live-decision ()
  "Return the id of the \"always\" decision the settings hold now, or nil.
That is the newest `cowboy' decision in effect whose settings after it
are the settings now: its choice is the default, and asking is off,
because of it."
  (when (harness-method-exists-p 'decision/list)
    (let ((now (harness-cowboy--settings)))
      (plist-get (cl-find-if (lambda (d)
                               (harness-cowboy--settings-equal (plist-get (plist-get d :record) :after) now))
                             (harness-call 'decision/list :kind 'cowboy :state 'done))
                 :id))))

(defun harness-cowboy--hint-meta (by &optional decision)
  "Return the `:meta' of the hint saying what goes first, as BY decided.
DECISION is the id of the decision an \"always\" answer kept just now,
which the hint names as `:decision': it was made there.  Otherwise a
choice taken unasked -- asking off, a session that does not wait for
you, a question that could not be asked, a cold start -- is the default,
and when an \"always\" answer still holding set it, the hint names that
answer's decision as `:decided-by' (`harness-cowboy--live-decision').
Nil when there is neither."
  (cond ((and (stringp decision) (not (string-empty-p decision))) (list :decision decision))
        ((memq by '(default non-interactive unasked cold-start))
         (when-let* ((live (ignore-errors (harness-cowboy--live-decision))))
           (list :decided-by live)))))

(defun harness-cowboy--hint (session-id text &optional meta)
  "Append the hint TEXT to SESSION-ID's transcript, with `:meta' META.
A hint whose META names the decision made there (`:decision') becomes
that decision's note (`decision/attach').  Return the hint."
  (if (null meta)
      (harness-call 'session/hint session-id text)
    (let ((node (harness-call 'session/append session-id (list :kind 'hint :content text :meta meta)))
          (decision (plist-get meta :decision)))
      (when (and decision (harness-method-exists-p 'decision/attach))
        (condition-case err
            (harness-call 'decision/attach decision session-id (plist-get node :id))
          (error (harness-log 'warn "cowboy: could not name the note of %s: %s"
                              decision (harness-error-short-message err)))))
      node)))

;;;; Asking

(defvar harness-cowboy--asking (make-hash-table :test 'equal)
  "Session id -> (:pid PID :settle FN) while its cold-cache question waits.
FN takes the choice and who made it, once: it lets the turn go on.")

(defun harness-cowboy--ask (session-id session value estimate settle &optional note)
  "Ask what goes first in SESSION-ID, whose record is SESSION.
VALUE is the `agent/before-turn' value, whose `:message' is the
message waiting; ESTIMATE `compaction/estimate''s answer, or nil.
SETTLE is called once with the choice and who made it: `user', or
`always' for an answer that made it the default, and then with the id
of the lasting decision kept of it, or nil (`harness-cowboy--remember').
An answer that names no choice asks again, NOTE then saying so; a
dismissed question holds the message."
  (let* ((message (plist-get value :message))
         (from (plist-get message :from))
         (default (harness-cowboy--default))
         (choices (mapcar #'car harness-cowboy-choices))
         (answered nil)
         (pid nil))
    (setq pid
          (harness-call
           'question/ask session-id
           (list :question (harness-cowboy--question-text session estimate from note)
                 :options (mapcar (lambda (c) (harness-cowboy--option c estimate default)) choices)
                 :allow-free-text t
                 :cowboy (harness-cowboy--info session-id session estimate from default message)
                 :waiting-message message)
           (lambda (text dismissed)
             (setq answered t)
             (when (equal (plist-get (gethash session-id harness-cowboy--asking) :pid) pid)
               (remhash session-id harness-cowboy--asking))
             (let ((parsed (and (not dismissed) (harness-cowboy-parse-answer text))))
               (cond
                ((or dismissed (not (harness-call 'session/exists-p session-id)))
                 (funcall settle 'hold 'user))
                ((null parsed)
                 (condition-case err
                     (harness-cowboy--ask session-id (harness-call 'session/get session-id) value estimate settle
                                          (format "“%s” is not one of the choices."
                                                  (harness-truncate-end (harness-first-line text) 60)))
                   (error (harness-log 'warn "cowboy: could not ask %s again: %s"
                                       session-id (harness-error-short-message err))
                          (funcall settle 'hold 'user))))
                ((and (cdr parsed) (not (eq (car parsed) 'hold)))
                 (let* ((saved (harness-cowboy--remember (car parsed) session-id))
                        (failed (plist-get saved :failed)))
                   (when failed
                     (harness-call 'session/hint session-id
                                   (format "Could not make %s the default: %s"
                                           (downcase (harness-cowboy-label (car parsed))) failed)))
                   (funcall settle (car parsed) (if failed 'user 'always) (plist-get saved :decision))))
                (t (funcall settle (car parsed) 'user)))))))
    (unless answered
      (puthash session-id (list :pid pid :settle settle) harness-cowboy--asking)
      (harness-emit 'cowboy/asked session-id pid))
    pid))

;;;; Doing what was chosen

(defconst harness-cowboy--hold-reason
  "not now: the prompt cache is cold, and the message waits; the next one sends it too"
  "Why a held turn did not start, as the hint after it says.")

(defun harness-cowboy--choice-text (choice context)
  "Return in words what CHOICE does first.
CONTEXT, a number of tokens or nil, is what carrying on sends again."
  (pcase choice
    ('brief "compacting into a brief summary first")
    ('summary "compacting into a summary first")
    ('transcript "writing the conversation to a transcript file first")
    ('fresh "starting afresh")
    ('ignore (format "ignoring the cold cache and carrying on with the whole conversation%s"
                     (if (and (numberp context) (> context 0))
                         (format ", ~%s tokens uncached" (harness-format-tokens context))
                       "")))
    (_ (format "carrying on with the whole conversation%s"
               (if (and (numberp context) (> context 0))
                   (format ", ~%s tokens uncached" (harness-format-tokens context))
                 "")))))

(defun harness-cowboy--by-text (by)
  "Return in words why BY, who decided what goes first, decided as it did."
  (pcase by
    ('user "as you chose")
    ('always "as you chose, from now on without asking (harness-cowboy-ask turns asking back on)")
    ('non-interactive "the default for a session that does not wait for you (harness-cowboy-default)")
    ('unasked "the default, as the question could not be asked (harness-cowboy-default)")
    ('cold-start "the default for a session no warm cache holds (harness-cowboy-default)")
    (_ "the default, as asking is off (harness-cowboy-ask)")))

(defun harness-cowboy--hint-text (choice by session estimate &optional why)
  "Return the hint saying CHOICE goes first in SESSION, as BY decided.
ESTIMATE is `compaction/estimate''s answer, or nil.  WHY, a string,
opens the hint in place of the time the prompt cache went cold: a
session with no cache of its own has none to date.  Without it, the
hint opens with the cache held for another model than SESSION's, else
the redaction that dropped the cache and when (`harness-cowboy--dropped'),
else when the cache went cold."
  (let ((context (or (plist-get estimate :context) (plist-get (plist-get session :usage) :context)))
        (expires (plist-get (plist-get session :cache) :expires))
        (stale (harness-cowboy--cache-model session))
        (dropped (harness-cowboy--dropped session)))
    (format "%s: %s, %s"
            (cond ((and (stringp why) (not (string-blank-p why))) (string-trim why))
                  (stale (format "Prompt cache cold: held for %s, not %s"
                                 (harness-cowboy--model-label stale)
                                 (harness-cowboy--model-label (plist-get session :model))))
                  (dropped (format "Prompt cache dropped at %s by a redaction"
                                   (harness-cowboy--clock dropped)))
                  ((numberp expires) (format "Prompt cache cold since %s" (harness-cowboy--clock expires)))
                  (t "No warm prompt cache holds this conversation"))
            (harness-cowboy--choice-text choice context)
            (harness-cowboy--by-text by))))

(defun harness-cowboy--compact (session-id choice by)
  "Compact SESSION-ID as CHOICE says, BY deciding; return a promise.
The promise resolves once it is done, never rejecting: a summary that
cannot be made falls back to the transcript, and a transcript that
cannot be written to carrying on, each said in a hint."
  (let ((meta (lambda (&optional fallback)
                (list :cowboy (append (list :choice (symbol-name choice) :by (symbol-name by))
                                      (and fallback (list :fallback fallback))))))
        (carry-on (lambda (msg)
                    (when (harness-call 'session/exists-p session-id)
                      (harness-call 'session/hint session-id
                                    (format "No compaction (%s): carrying on with the whole conversation" msg)))
                    nil)))
    (harness-catch
     (harness-call-async 'compaction/compact session-id (list :kind choice :meta (funcall meta)))
     (lambda (err)
       ;; Short: the error can carry a whole transcript or request body
       ;; (`harness-error-short-message'), and the hint is read.
       (let ((msg (harness-error-short-message err)))
         (if (and (memq choice '(brief summary)) (harness-call 'session/exists-p session-id))
             (progn
               (harness-call 'session/hint session-id
                             (format "No %s (%s): writing the conversation to a transcript file instead"
                                     (downcase (harness-cowboy-label choice)) msg))
               (harness-catch
                (harness-call-async 'compaction/compact session-id
                                    (list :kind 'transcript :meta (funcall meta msg)))
                (lambda (err) (funcall carry-on (harness-error-short-message err)))))
           (funcall carry-on msg)))))))

(defun harness-cowboy--busy (session-id)
  "Show SESSION-ID at work while the compaction chosen runs before its turn.
Its status turns running, its turn having begun, and its activity says
it compacts: a client stops offering to compact it (the cache panel)
and says what the message waits for.  The turn sets both again when it
starts, and its end, cancelled or not, when it ends."
  (condition-case err
      (progn
        (harness-call 'session/set-status session-id 'running)
        (when (harness-method-exists-p 'agent/note-activity)
          (harness-call 'agent/note-activity session-id (list :phase 'compacting))))
    (error (harness-log 'warn "cowboy: could not mark %s busy: %s" session-id (harness-error-short-message err)))))

(defun harness-cowboy--apply (session-id choice by value estimate &optional decision)
  "Do CHOICE before SESSION-ID's turn, as BY decided; promise the gate value.
VALUE is the `agent/before-turn' value the turn goes on with; ESTIMATE
`compaction/estimate''s answer, or nil.  DECISION is the id of the
lasting decision an \"always\" answer kept just now, which the hint
saying what goes first names (`harness-cowboy--hint-meta').  `hold'
stops the turn, with `harness-cowboy--hold-reason'; a session deleted
meanwhile has no turn.  `ignore' does nothing at all: the message goes
with the whole conversation and no hint is added to it."
  (harness-emit 'cowboy/decided session-id choice by)
  (cond
   ((not (harness-call 'session/exists-p session-id))
    (harness-resolved (list :proceed nil)))
   ((eq choice 'hold)
    (harness-resolved (list :proceed nil :reason harness-cowboy--hold-reason)))
   ;; Ignoring the cold cache leaves the conversation exactly as it is:
   ;; no compaction, no note, nothing but the message.
   ((eq choice 'ignore)
    (harness-resolved value))
   (t
    (let ((session (harness-call 'session/get session-id)))
      (harness-cowboy--hint session-id (harness-cowboy--hint-text choice by session estimate)
                            (harness-cowboy--hint-meta by decision))
      (if (eq choice 'carry-on)
          (harness-resolved value)
        (harness-cowboy--busy session-id)
        (harness-then (harness-cowboy--compact session-id choice by)
                      (lambda (_) value)))))))

(defun harness-cowboy--decide (session-id session value)
  "Decide what goes first in SESSION-ID, whose record is SESSION, and do it.
VALUE is the `agent/before-turn' value.  Return a promise of the value
the turn goes on with: asked (`harness-cowboy--ask') or taken unasked
\(`harness-cowboy-default')."
  (let ((estimate (harness-cowboy--estimate session-id)))
    (if (not (harness-cowboy--asks-p session))
        (harness-cowboy--apply session-id (harness-cowboy--default)
                               (if (harness-cowboy--non-interactive-p session) 'non-interactive 'default)
                               value estimate)
      (let* ((promise (harness-make-promise))
             (settled nil)
             (settle (lambda (choice by &optional decision)
                       (unless settled
                         (setq settled t)
                         (harness-resolve promise
                                          (harness-cowboy--apply session-id choice by value estimate decision))))))
        (condition-case err
            (harness-cowboy--ask session-id session value estimate settle)
          (error
           (harness-log 'warn "cowboy: could not ask %s: %s" session-id (harness-error-short-message err))
           (funcall settle (harness-cowboy--default) 'unasked)))
        promise))))

;;;; Compacting unasked

(defun harness-cowboy--by (value)
  "Return who decided, as VALUE, a symbol or its name, says, else `cold-start'."
  (cond ((and value (symbolp value)) value)
        ((and (stringp value) (not (string-blank-p value))) (intern (string-trim value)))
        (t 'cold-start)))

(harness-defmethod cowboy/compact (session-id &rest opts)
  "Compact SESSION-ID, unasked, before its first turn; promise the choice.
For a caller that makes a session whose conversation no warm prompt
cache holds: a fork of a long session onto a model that never read it,
say.  Such a session has no `:cache' of its own, so the cold-cache gate
never finds it cold, and its first turn would send the whole
conversation uncached.  This does what the gate does for a session
nobody is asked about: it takes `harness-cowboy-default' (never `hold'),
emits `cowboy/decided', adds a hint saying so to SESSION-ID and, unless
the choice is `carry-on' or `ignore', compacts as the gate does, with
the same fallbacks: a brief or full summary that cannot be made gives
way to the transcript file, and that to carrying on, each said in a
hint.  `carry-on' adds the hint and compacts nothing; `ignore' adds
nothing at all.  As in the gate, the compaction node's `:meta' `:cowboy'
holds the choice and who decided.

The promise resolves with the choice taken, a symbol, or with nil when
nothing was done: the context is under `harness-cowboy-min-context',
SESSION-ID does not exist, or something failed (it is logged).  It never
rejects, so a caller can always go on.  No turn is running, so the
session is not shown busy while it compacts.

OPTS keys:
 `:by'   who decided, a symbol: the `:by' of the node's meta and the
         third argument of `cowboy/decided'.  The default, `cold-start',
         is the default for a session no warm cache holds, which is
         what the hint says whatever the caller names.
 `:why'  a string that opens the hint in place of \"Prompt cache cold
         since HH:MM\": a session with no cache of its own has no time
         to give.  Say what no cache holds, for example \"No prompt cache
         on MODEL holds this conversation\"."
  (condition-case err
      (let* ((session (harness-call 'session/get session-id))
             (estimate (harness-cowboy--estimate session-id))
             (context (or (plist-get estimate :context)
                          (plist-get (plist-get session :usage) :context)))
             (smallest (max 0 (or harness-cowboy-min-context 0)))
             (choice (harness-cowboy--default))
             (by (harness-cowboy--by (plist-get opts :by))))
        (if (< (if (numberp context) context 0) smallest)
            (harness-resolved nil)
          (harness-emit 'cowboy/decided session-id choice by)
          ;; Whoever the caller says decided, what was done is the default
          ;; for a session no warm cache holds: the hint says so, and
          ;; names the "always" answer that set the default, if one did.
          ;; Ignoring adds no hint at all: nothing is done to the conversation.
          (unless (eq choice 'ignore)
            (harness-cowboy--hint session-id
                                  (harness-cowboy--hint-text choice 'cold-start session estimate (plist-get opts :why))
                                  (harness-cowboy--hint-meta 'cold-start)))
          (if (memq choice '(carry-on ignore))
              (harness-resolved choice)
            (harness-then (harness-cowboy--compact session-id choice by)
                          (lambda (_) choice)
                          (lambda (err)
                            (harness-log 'warn "cowboy: compacting %s unasked failed: %s"
                                         session-id (harness-error-short-message err))
                            nil)))))
    (error (harness-log 'warn "cowboy: compacting %s unasked failed: %s"
                        session-id (harness-error-short-message err))
           (harness-resolved nil))))

;;;; The gate

(defun harness-cowboy--gate (value next session)
  "Hold SESSION's turn while what goes first, its cache being cold, is decided.
VALUE and NEXT are those of the `agent/before-turn' filter.  SESSION is
read again first: an earlier gate (the fallback, a handoff) may have
changed it."
  (let* ((id (plist-get session :id))
         (session (or (ignore-errors (harness-call 'session/get id)) session)))
    (if (or (not (plist-get value :proceed))
            (not (harness-cowboy-cold-p session)))
        (funcall next value)
      (harness-then (harness-cowboy--decide id session value)
                    (lambda (gate) (funcall next gate) nil)
                    (lambda (err)
                      (harness-log 'warn "cowboy: deciding for %s failed: %s" id (harness-error-short-message err))
                      (funcall next value)
                      nil))))
  nil)

(defun harness-cowboy--on-turn-ended (session-id &optional _reason)
  "Dismiss SESSION-ID's cold-cache question: its turn is over before the answer.
That is a turn cancelled while the gate held it (`agent/cancelling',
then `agent/turn-ended'); the message is kept."
  (when-let* ((asking (gethash session-id harness-cowboy--asking)))
    (remhash session-id harness-cowboy--asking)
    (if (and (harness-method-exists-p 'question/cancel)
             (harness-call 'session/exists-p session-id))
        (harness-call 'question/cancel session-id (plist-get asking :pid))
      (funcall (plist-get asking :settle) 'hold 'user))))

(defun harness-cowboy--on-deleted (session-id &rest _)
  "Let the turn waiting on SESSION-ID's question go: the session is gone."
  (when-let* ((asking (gethash session-id harness-cowboy--asking)))
    (remhash session-id harness-cowboy--asking)
    (funcall (plist-get asking :settle) 'hold 'user)))

(harness-defmethod cowboy/asking (session-id)
  "Return the id of the cold-cache question SESSION-ID waits on, or nil."
  (plist-get (gethash session-id harness-cowboy--asking) :pid))

(harness-defmethod cowboy/default (&optional session-id)
  "Return what goes first, unasked, when a session's prompt cache is cold.
That is the compaction option the user saved: (:choice CHOICE :ask BOOL
:asks BOOL :decision ID).  CHOICE is `harness-cowboy-default', a symbol of
`harness-cowboy-choices' but `hold' -- `brief', unless they chose
otherwise --, ASK whether the question is asked at all
\(`harness-cowboy-ask'), ASKS whether a message that meets the cold cache
of SESSION-ID would be asked about -- asking is on and the session waits
for the user, which a non-interactive one never does; without SESSION-ID
it is ASK -- and ID the lasting decision (see \"decisions\") that set
the two, when an \"always\" answer still in force did, else nil.  Whatever
acts on the user's behalf where a cold cache is concerned, without
asking -- compacting a conversation just before its cache lapses
\(harness-cache-compact.el) -- takes this choice where nobody would be
asked, and names the decision on its note, so that the note offers its
undo and redo."
  (let ((session (and session-id (harness-call 'session/exists-p session-id)
                      (harness-call 'session/get session-id))))
    (list :choice (harness-cowboy--default)
          :ask (if harness-cowboy-ask t :false)
          :asks (if (if session (harness-cowboy--asks-p session) harness-cowboy-ask) t :false)
          :decision (ignore-errors (harness-cowboy--live-decision)))))

(defun harness-cowboy--init ()
  "Hook the cold-cache gate into the turn loop (idempotent)."
  ;; After the fallback and a handoff (10), which may change the model
  ;; or start the conversation over; before automatic compaction (20),
  ;; which would summarise on the session's model, reading it all
  ;; uncached.
  (harness-add-filter 'agent/before-turn #'harness-cowboy--gate 15)
  (harness-on 'agent/cancelling #'harness-cowboy--on-turn-ended)
  (harness-on 'agent/turn-ended #'harness-cowboy--on-turn-ended)
  (harness-on 'session/deleted #'harness-cowboy--on-deleted))

(harness-cowboy--init)

(harness-declare-event 'cowboy/asked "(SESSION-ID PENDING-ID) after asking what goes first in a session whose prompt cache went cold.")
(harness-declare-event 'cowboy/decided "(SESSION-ID CHOICE BY) once what goes first is decided: CHOICE one of `harness-cowboy-choices', BY `user', `always' (the answer made it the default), `non-interactive', `default' (asking is off), `unasked' (the question could not be asked) or `cold-start' (`cowboy/compact', for a session no warm cache holds; its caller may name another BY).")

(harness-define-module 'cowboy
  :doc "Ask what goes first when a message meets a session whose prompt cache went cold."
  :requires '(session agent compaction)
  :init #'harness-cowboy--init)

(provide 'harness-cowboy)
;;; harness-cowboy.el ends here
