;;; harness-todo-sync.el --- Keep a session's todo list true to its work  -*- lexical-binding: t; -*-

;;; Commentary:

;; Many models never keep the todo list (`todo_write') they are given:
;; they write it once, or not at all, and the panel above the compose box
;; says nothing of how far a long task has come -- or shows a plan the
;; model dropped hours ago.  Forcing the tool on them does harm (a
;; reminder in the model's context, a model that writes lists to please
;; it), so this module leaves the model alone and keeps the list for
;; you: every few steps it has a cheap model look at the work and write
;; the list as it should read now.  Nothing is ever added to the model's
;; conversation or prompt, and the model is never told.
;;
;; A step is one go the model has at the work: its own words, thinking or
;; request for a tool after a tool result or a message of yours.  A turn
;; is the whole run, from your message to the model stopping, and has
;; many steps.  They are counted from the transcript, which holds for
;; every provider.  For a loop the harness runs itself these are the
;; steps `agent/step-started' announces and a task card counts for the
;; running turn; a hosted loop (Claude Code, Copilot) makes all its model
;; calls inside one request, which that event counts as one step, so only
;; the transcript sees its steps.  (A hosted loop that runs calls the
;; model made together one after another -- Claude Code can, for tools
;; that do not say they only read, as the harness's do not -- may have
;; each of them count.)
;;
;; After `harness-todo-sync-steps' steps with no update of the todo list
;; the list is rewritten, in the middle of a turn, steps being counted
;; across turns.  Any update starts the count over -- the model's own
;; `todo_write' too -- so a model that keeps its list up is never
;; second-guessed, and the module fills in only where the list went
;; stale.  A turn that ends gets its list looked at after half that many
;; steps, when the list still has open items, so it does not stay behind
;; what the turn just did; a list is made from nothing only in the
;; middle of a turn, after the whole interval, so a short exchange never
;; gets one.
;;
;; Who writes it is `harness-todo-sync-model'.  By default a dumb agent:
;; the simple tier of the session's provider, asked a question that
;; stands on its own -- the engineer's request, the list as it stands,
;; and the tail of what the agent did since the list was last updated --
;; as a one-off call without tools or thinking, which a hosted provider
;; answers apart from the session's conversation.  It costs next to
;; nothing.  With nil it is the session's own agent: its own model, asked
;; about the whole conversation, on a fork of the provider's state where
;; the provider can fork one (a hosted loop that cannot is asked the dumb
;; agent's question instead, so the turn's own process is never
;; disturbed).  That knows more and costs the conversation read again.
;;
;; The answer is a checklist, one item a line, `[x]' for finished, `[~]'
;; for the one in hand and `[ ]' for the rest; or `UNCHANGED' when the list
;; is right, or `NONE' when the work is too small to need one.  It may
;; replace the whole list, and is told to when the agent has changed its
;; approach.  It is read leniently (`harness-todo-sync-parse'), the items
;; keep the ids of the ones whose words stay, and it is dropped when the
;; list changed while it was asked (the model wrote its own meanwhile).
;; The list lands as any other (`session/set-todos'): the chat's panel,
;; the task cards and ACP clients show it.  Each call is recorded as an
;; internal "Todo sync" session under the session it was made for, with
;; its prompt, reply and cost.
;;
;; One request per session runs at a time, a failed one waits
;; `harness-todo-sync--retry' seconds, and a request that takes longer than
;; `harness-todo-sync--timeout' is cancelled.  An internal or BTW session is
;; left alone.  A session can turn the module off for itself, or on
;; where it is off for the rest (`todo-sync/set'); `todo-sync/run' updates
;; a list now, and `todo-sync/state' says how a session stands.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)

(declare-function harness-agent-strip-result-images "harness-agent" (messages))

(defcustom harness-todo-sync-steps 6
  "Steps without an update of a session's todo list before it is synced.
A step is one go the model has at the work: what it writes, thinks or
asks a tool for after a tool result or a message of yours.  Steps are
counted across turns (a turn is a whole run, from your message to the
model stopping), and the count starts over whenever the list is
updated, by the model's own `todo_write' too.  A list is also looked at
when a turn ends with open items after half this many.  nil never syncs
a list on its own; a session can still ask for it (`todo-sync/set') or
have it done once (`todo-sync/run')."
  :type '(choice (const :tag "Never on its own" nil)
                 (integer :tag "Steps"))
  :group 'harness)

(defcustom harness-todo-sync-model 'auto
  "Who writes the todo list, as PROVIDER:NAME, `auto' or nil.
`auto' (the default) is a dumb agent: the simple tier of the session's
provider (see `harness-provider-tier-model'), asked a question that
stands on its own, which costs next to nothing, falling back to the
session's own model when the provider names no simple one.  A
PROVIDER:NAME asks that model the same question.  nil asks the
session's own model about its whole conversation, on a fork of its
provider state where the provider can fork one: it knows what the
agent knows, and costs the conversation read again each time."
  :type '(choice (const :tag "The session provider's simple model" auto)
                 (const :tag "The session's own model, on a fork of it" nil)
                 (string :tag "Model" :names model))
  :group 'harness)

(defconst harness-todo-sync--default-steps 6
  "Steps between syncs for a session that turned the module on for itself.
It applies when `harness-todo-sync-steps' is nil.")

(defconst harness-todo-sync--ext-key :todo-sync
  "The `:ext' key under which a session keeps its own switch.
`:false' turns the module off for the session, t on; no key leaves it to
`harness-todo-sync-steps'.")

(defconst harness-todo-sync--skip-kinds '(internal btw)
  "Session kinds whose todo lists are left alone.
An internal session records one model call, and a BTW is a side
conversation.")

(defconst harness-todo-sync--max-items 15
  "Most items a synced list holds.")

(defconst harness-todo-sync--item-chars 100
  "Most characters of one item of a synced list.")

(defconst harness-todo-sync--max-tokens 600
  "Output budget of a request: a list of ten short lines.")

(defconst harness-todo-sync--timeout 90
  "Seconds a request may take before it is cancelled and counts as failed.")

(defconst harness-todo-sync--retry 120
  "Seconds a failed request keeps the next try off.")

(defconst harness-todo-sync--message-chars 2500
  "Characters of the engineer's request that a question carries.")

(defconst harness-todo-sync--activity-chars 10000
  "Characters of the agent's work that a question carries, the newest last.")

(defconst harness-todo-sync--system-prompt
  "You keep the todo list of a coding agent current, for the engineer who watches the agent work and reads the list to see how far along the work is.  You are shown the engineer's request, the list as it stands (it may be empty) and what the agent has done since the list was last updated.  Write the list as it should read now.

Write one item per line, with its state in brackets before it:
[x] an item that is finished
[~] the item the agent is working on right now (at most one)
[ ] an item still to do

- Write 3 to 10 items, each a short imperative phrase of at most 80 characters about the work to do, never about the tools used.  Put them in the order the work goes.
- Keep the items of the current list that still hold, in their own words, and mark done only what the agent's work shows done.
- When the agent changed its approach, or took on work the list does not describe, write a list that fits the work now: keep the finished items that are still true, and drop the ones that no longer apply.
- Answer with the list alone: no other words, no numbering, no markdown.  Answer UNCHANGED alone when the list is right as it stands, and NONE alone when the work is too small or too unclear to need a list."
  "System prompt of a request to write a todo list.")

(defconst harness-todo-sync--ask
  "Write the todo list as it should read now: the list alone, one item a line, each starting with [x], [~] or [ ]; or UNCHANGED alone, or NONE alone."
  "Last line of a question to the dumb agent.")

(defconst harness-todo-sync--fork-ask
  "[harness] Stop the work for a moment and use no tools.  The engineer keeps a todo list of it.  Write that list as it should read now, from the work so far.

Write one item per line, with its state in brackets before it: [x] finished, [~] the one item in hand, [ ] still to do.  Keep 3 to 10 short imperative items, in the order the work goes, about the work and not the tools.  Keep the items of the current list that still hold, in their words, and mark done only what the work shows done; if you changed your approach, write a list that fits the work now.  Answer with the list alone, no other words and no markdown; or UNCHANGED alone when the current list is right, or NONE alone when the work is too small to need a list."
  "The instructions at the end of a question put to the session's own agent.
The conversation it is asked on holds none of this, and a forked hosted
conversation ignores the system prompt of the request.")

;;;; State

(defvar harness-todo-sync--steps (make-hash-table :test 'equal)
  "Session id -> steps since its todo list was last updated or checked.")

(defvar harness-todo-sync--phase (make-hash-table :test 'equal)
  "Session id -> what its transcript last held: `model' or `result' or `input'.
A step is counted when the model speaks after anything but itself.")

(defvar harness-todo-sync--last-node (make-hash-table :test 'equal)
  "Session id -> the id of the last node its transcript got.")

(defvar harness-todo-sync--anchor (make-hash-table :test 'equal)
  "Session id -> the last node its transcript had when its list was last touched.
That is when the list was last updated or checked.  What the agent did
since is what follows the node.")

(defvar harness-todo-sync--counted (make-hash-table :test 'equal)
  "Session id -> t when its steps are counted, `skip' when its kind is left alone.")

(defvar harness-todo-sync--running (make-hash-table :test 'equal)
  "Session id -> promise of the request in flight.")

(defvar harness-todo-sync--failed (make-hash-table :test 'equal)
  "Session id -> the time a failed request may be tried again.")

;;;; Counting steps

(defun harness-todo-sync--counted-p (sid)
  "Non-nil when the steps of session SID are counted.
That is for a session whose kind keeps a todo list (not an internal one,
nor a BTW).  The kind is read once and remembered."
  (let ((known (gethash sid harness-todo-sync--counted 'unknown)))
    (when (eq known 'unknown)
      (setq known (if (and (harness-call 'session/exists-p sid)
                           (not (memq (intern (format "%s" (plist-get (harness-call 'session/get sid) :kind)))
                                      harness-todo-sync--skip-kinds)))
                      t
                    'skip))
      (puthash sid known harness-todo-sync--counted))
    (eq known t)))

(defun harness-todo-sync--touch (sid)
  "Start the count of SID over: its list was just updated or checked."
  (puthash sid 0 harness-todo-sync--steps)
  (if-let* ((node (gethash sid harness-todo-sync--last-node)))
      (puthash sid node harness-todo-sync--anchor)
    (remhash sid harness-todo-sync--anchor)))

(defun harness-todo-sync--on-node-added (sid node)
  "Count a step when NODE, which session SID just got, starts one.
A step starts when the model writes, thinks or asks for a tool after a
tool result or a message of the user's, whichever provider runs the
loop: a hosted loop's many model calls in one request count as the
steps they are, which `agent/step-started' would not see.  A call the
harness recorded for the session, and its result, are not the model's."
  (when (harness-todo-sync--counted-p sid)
    (puthash sid (plist-get node :id) harness-todo-sync--last-node)
    (pcase (format "%s" (plist-get node :kind))
      ((or "assistant" "thinking" "tool-call")
       (unless (harness-outside-node-p node)
         (unless (eq (gethash sid harness-todo-sync--phase) 'model)
           (puthash sid 'model harness-todo-sync--phase)
           (cl-incf (gethash sid harness-todo-sync--steps 0))
           ;; Out of the subscriber: the request is started from a clean stack.
           (harness-run-soon #'harness-todo-sync--maybe sid))))
      ("tool-result"
       (unless (harness-outside-node-p node)
         (puthash sid 'result harness-todo-sync--phase)))
      ("user" (puthash sid 'input harness-todo-sync--phase)))))

(defun harness-todo-sync--on-todos (sid _todos)
  "Start the count of SID over: its todo list was updated, by whoever."
  (harness-todo-sync--touch sid))

(defun harness-todo-sync--on-turn-ended (sid _reason)
  "Look at SID's list when its turn ended: it should not stay behind the turn."
  (remhash sid harness-todo-sync--phase)
  (when (harness-todo-sync--counted-p sid)
    (harness-run-soon #'harness-todo-sync--maybe sid t)))

(defun harness-todo-sync--on-deleted (sid &rest _)
  "Forget session SID, which is gone."
  (dolist (table (list harness-todo-sync--steps harness-todo-sync--phase
                       harness-todo-sync--last-node harness-todo-sync--anchor
                       harness-todo-sync--counted harness-todo-sync--running
                       harness-todo-sync--failed))
    (remhash sid table)))

;;;; The todo list

(defun harness-todo-sync--status (todo)
  "Return the state of TODO, a todo item: `done', `in-progress' or `pending'.
It may come back from the store as a string."
  (let ((s (downcase (format "%s" (or (plist-get todo :status) "pending")))))
    (cond ((member s '("done" "completed" "complete")) 'done)
          ((member s '("in-progress" "in_progress" "in progress" "active" "doing")) 'in-progress)
          (t 'pending))))

(defun harness-todo-sync--text (todo)
  "Return the words of TODO, a todo item."
  (format "%s" (or (plist-get todo :text) (plist-get todo :content) "")))

(defun harness-todo-sync--open-p (todos)
  "Non-nil when TODOS, a todo list, has an item that is not done."
  (cl-some (lambda (todo) (not (eq (harness-todo-sync--status todo) 'done))) todos))

(defun harness-todo-sync--same-p (a b)
  "Non-nil when todo lists A and B read the same.
That is the same items, in the same states."
  (equal (mapcar (lambda (todo) (cons (harness-todo-sync--text todo) (harness-todo-sync--status todo))) a)
         (mapcar (lambda (todo) (cons (harness-todo-sync--text todo) (harness-todo-sync--status todo))) b)))

(defun harness-todo-sync--render (todos)
  "Return TODOS, a todo list, as the checklist the model reads and writes."
  (if todos
      (mapconcat (lambda (todo)
                   (format "%s %s"
                           (pcase (harness-todo-sync--status todo)
                             ('done "[x]") ('in-progress "[~]") (_ "[ ]"))
                           (harness-todo-sync--text todo)))
                 todos "\n")
    "(empty)"))

;;;; Reading the answer

(defun harness-todo-sync--clean (text)
  "Return TEXT, the words of an item, tidied; nil when nothing is left."
  (let* ((text (replace-regexp-in-string "[ \t]+" " " (string-trim text)))
         ;; A final period, and a whole item between bold or code marks.
         (text (string-trim (replace-regexp-in-string "[.]+\\'" "" text)))
         (text (string-trim (replace-regexp-in-string "\\`\\(\\*\\*\\|__\\|`\\)\\(.+\\)\\1\\'" "\\2" text))))
    (unless (string-empty-p text)
      (harness-truncate-end text harness-todo-sync--item-chars))))

(defun harness-todo-sync--parse-line (line)
  "Return the item the checklist LINE is, (:text TEXT :status STATUS), or nil.
A line is an item when a state in brackets starts it, after a bullet or a
number if it has one: [x] finished, [~] in hand, [ ] to do."
  (when (string-match
         "\\`[ \t]*\\(?:\\(?:[-*+•]\\|[0-9]+[.)]\\)[ \t]+\\)?\\[\\([^]\n]?\\)\\][ \t]*\\(.+\\)\\'" line)
    (let* ((mark (match-string 1 line))
           (text (harness-todo-sync--clean (match-string 2 line)))
           (status (cond ((member mark '("x" "X" "✓" "✔" "✅")) 'done)
                         ((member mark '("~" ">" "-" "/" "*" "o")) 'in-progress)
                         ((member mark '(" " "")) 'pending))))
      (when (and text status)
        (list :text text :status status)))))

(defun harness-todo-sync--word (text)
  "Return the first line of TEXT without markup or punctuation, in lower case."
  (downcase (string-trim (replace-regexp-in-string "[^[:alnum:] ]+" "" (harness-first-line (or text ""))))))

(defun harness-todo-sync-parse (text)
  "Return what the model's answer TEXT says of the todo list, or nil.
The value is (:todos ITEMS), ITEMS being (:text TEXT :status STATUS)
from the lines that are checklist items (at most one `in-progress', at
most `harness-todo-sync--max-items' of them); (:unchanged) when the answer
is the word UNCHANGED; (:none) when it is NONE; nil when it is none of
these.  Lines that are no items -- a preamble, a closing remark -- are
left out, so a model that cannot help talking still gets understood."
  (let ((items nil) (seen-hand nil))
    (dolist (line (split-string (or text "") "[\r\n]+" t))
      (when-let* ((item (harness-todo-sync--parse-line line)))
        (when (eq (plist-get item :status) 'in-progress)
          (if seen-hand
              (setq item (plist-put (copy-sequence item) :status 'pending))
            (setq seen-hand t)))
        (push item items)))
    (cond (items (list :todos (take harness-todo-sync--max-items (nreverse items))))
          ((equal (harness-todo-sync--word text) "unchanged") (list :unchanged))
          ((equal (harness-todo-sync--word text) "none") (list :none)))))

(defun harness-todo-sync--todos (items old)
  "Return ITEMS, as read from an answer, as the todos of a session.
Each is (:id ID :text TEXT :status STATUS).  An item whose words an item
of OLD, the list as it was, has keeps its id; the others are numbered
t1, t2... as `todo_write' numbers its items, skipping the ids kept."
  (let ((taken nil) (next 0) (out nil))
    (dolist (item items)
      (let* ((key (downcase (plist-get item :text)))
             (match (cl-find-if (lambda (o)
                                  (and (equal (downcase (harness-todo-sync--text o)) key)
                                       (plist-get o :id)
                                       (not (member (format "%s" (plist-get o :id)) taken))))
                                old))
             (id (and match (format "%s" (plist-get match :id)))))
        (when id (push id taken))
        (push (list :id id :text (plist-get item :text) :status (plist-get item :status)) out)))
    (setq out (nreverse out))
    (mapcar (lambda (todo)
              (if (plist-get todo :id)
                  todo
                (let (id)
                  (while (member (setq id (format "t%d" (cl-incf next))) taken))
                  (push id taken)
                  (plist-put (copy-sequence todo) :id id))))
            out)))

;;;; What the model is asked

(defun harness-todo-sync--clip (text max)
  "Return TEXT on one line, cut to MAX characters."
  (harness-truncate-end (string-trim (replace-regexp-in-string "[ \t\r\n]+" " " (or text ""))) max))

(defun harness-todo-sync--quote (text)
  "Return TEXT cut to `harness-todo-sync--message-chars', between message tags."
  (format "<message>\n%s\n</message>"
          (harness-truncate-end (string-trim (or text "")) harness-todo-sync--message-chars)))

(defun harness-todo-sync--user-texts (nodes)
  "Return the texts of the messages in NODES that say what the work is.
They come oldest first.  That is the user messages someone wrote: what
the harness sent on its own and the notes that hand a conversation over
say nothing of it.  The first message counts whoever sent it, as a
task's prompt does."
  (let ((texts nil) (first t))
    (dolist (node nodes)
      (when (and (equal (format "%s" (plist-get node :kind)) "user")
                 (not (harness-node-handoff node))
                 (not (harness-string-blank-p (plist-get node :content)))
                 (or first (not (eq (harness-sender-kind (harness-node-sender node)) 'system))))
        (setq first nil)
        (push (string-trim (plist-get node :content)) texts)))
    (nreverse texts)))

(defun harness-todo-sync--entry (node)
  "Return NODE of a transcript as a line of what the agent did, or nil.
Thinking, hints and calls the harness recorded for the session show
nothing."
  (unless (harness-outside-node-p node)
    (pcase (format "%s" (plist-get node :kind))
      ("user" (unless (harness-node-handoff node)
                (when-let* ((text (plist-get node :content)))
                  (format "[%s] %s"
                          (if (harness-node-sender node) "message" "engineer")
                          (harness-todo-sync--clip text 600)))))
      ("assistant" (format "[agent] %s" (harness-todo-sync--clip (plist-get node :content) 700)))
      ("tool-call" (format "[tool %s] %s" (plist-get node :tool)
                           (harness-todo-sync--clip (or (plist-get node :title) "") 160)))
      ("tool-result" (format "[%s] %s" (if (plist-get node :is-error) "failed" "result")
                             (harness-todo-sync--clip (plist-get node :output) 240)))
      ("plan" (format "[plan] %s" (harness-todo-sync--clip (plist-get node :content) 500)))
      ("compaction" (format "[work before, summarised] %s"
                            (harness-todo-sync--clip (plist-get node :content) 900))))))

(defun harness-todo-sync--activity (nodes anchor)
  "Return what the agent did after node ANCHOR in NODES, as lines, newest last.
NODES is the session's transcript, oldest first.  Without ANCHOR, or
when it is not there, it is all of it.  Only what fits
`harness-todo-sync--activity-chars' is kept, the newest; a line says
how many entries were left out before it."
  (let* ((from (and anchor (cl-member anchor nodes :key (lambda (n) (plist-get n :id)) :test #'equal)))
         ;; An anchor that is the last node leaves nothing after it.
         (tail (if from (cdr from) nodes))
         (older (nreverse (delq nil (mapcar #'harness-todo-sync--entry tail))))
         (kept nil) (size 0))
    (while (and older (< size harness-todo-sync--activity-chars))
      (let ((entry (pop older)))
        (push entry kept)
        (cl-incf size (1+ (length entry)))))
    (concat (if older (format "[%d earlier entries left out]\n" (length older)) "")
            (string-join kept "\n"))))

(defun harness-todo-sync--prompt (session nodes todos anchor)
  "Return the question put to the dumb agent about SESSION.
NODES is its transcript, TODOS its list and ANCHOR the node it was last
updated at (see `harness-todo-sync--activity')."
  (let* ((texts (harness-todo-sync--user-texts nodes))
         (opening (car texts))
         (latest (and (cdr texts) (car (last texts))))
         (plan (plist-get session :plan))
         (activity (harness-todo-sync--activity nodes anchor)))
    (string-join
     (delq nil
           (list (and opening (concat "The engineer's request:\n" (harness-todo-sync--quote opening)))
                 (and latest (concat "Their latest message:\n" (harness-todo-sync--quote latest)))
                 (and (stringp plan) (not (harness-string-blank-p plan))
                      (concat "The agent's plan:\n" (harness-truncate-end (string-trim plan) 1200)))
                 (concat "The todo list now:\n" (harness-todo-sync--render todos))
                 (concat "What the agent did since the list was last updated, oldest first:\n<activity>\n"
                         (if (string-empty-p activity) "(nothing yet)" activity)
                         "\n</activity>")
                 harness-todo-sync--ask))
     "\n\n")))

(defun harness-todo-sync--fork-question (todos)
  "Return the question put to the session's own agent, about TODOS, its list."
  (concat "The todo list now:\n" (harness-todo-sync--render todos) "\n\n" harness-todo-sync--fork-ask))

(defun harness-todo-sync--model (session)
  "Return the model that writes SESSION's todo list.
See `harness-todo-sync-model'."
  (let ((model (plist-get session :model))
        (choice harness-todo-sync-model))
    (cond ((or (eq choice 'auto) (equal choice "auto"))
           (or (and model (harness-method-exists-p 'provider/tier-model)
                    (ignore-errors (harness-call 'provider/tier-model model 'simple)))
               model))
          ((and (stringp choice) (not (string-empty-p choice))) choice)
          (t model))))

(defun harness-todo-sync--own-agent-p ()
  "Non-nil when the session's own agent writes the list, not a dumb one."
  (null harness-todo-sync-model))

(defun harness-todo-sync--hosted-p (session)
  "Non-nil when SESSION's provider holds the conversation in a loop of its own."
  (harness-json-true-p
   (plist-get (ignore-errors (harness-call 'provider/capabilities (plist-get session :model)))
              :hosted-loop)))

(defun harness-todo-sync--forked-state (session)
  "Return a promise of a fork of SESSION's provider state, or of nil.
Nil when its provider cannot fork one, or fails to."
  (let ((model (plist-get session :model)))
    (if (and (harness-json-true-p (plist-get (ignore-errors (harness-call 'provider/capabilities model)) :fork))
             (harness-method-exists-p 'provider/fork))
        (harness-catch (harness-call-async 'provider/fork model
                                           (if (harness-method-exists-p 'session/provider-state)
                                               (harness-call 'session/provider-state (plist-get session :id) model)
                                             (plist-get session :provider-state)))
                       (lambda (err)
                         (harness-log 'warn "todo-sync: forking the provider state failed: %s"
                                      (harness-error-message err))
                         nil))
      (harness-resolved nil))))

(defun harness-todo-sync--messages (sid question)
  "Return the messages of session SID with QUESTION, a text, at their end.
The transcript is what the model has, the images of its tool results
left out: a list is written from the words."
  (let* ((messages (if (fboundp 'harness-agent-strip-result-images)
                       (harness-agent-strip-result-images (harness-call 'session/messages sid))
                     (harness-call 'session/messages sid)))
         (ask (list :type "text" :text question))
         (last (car (last messages))))
    (if (and last (eq (plist-get last :role) 'user))
        (append (butlast messages)
                (list (list :role 'user :content (append (plist-get last :content) (list ask)))))
      (append messages (list (list :role 'user :content (list ask)))))))

;;;; Asking

(defun harness-todo-sync--complete (request)
  "Send REQUEST, a `provider/complete' request without `:on-event'.
Return a promise of the text of the answer.  It rejects with a message
when the provider fails, and when the answer takes longer than
`harness-todo-sync--timeout' seconds, which cancels the request."
  (let ((promise (harness-make-promise))
        (text "") (timer nil) (handle nil))
    (cl-flet ((finish (ok value)
                (unless (harness-promise-settled-p promise)
                  (when timer (cancel-timer timer))
                  (if ok (harness-resolve promise value) (harness-reject promise value)))))
      (setq timer (run-at-time harness-todo-sync--timeout nil
                               (lambda ()
                                 (finish nil "the model took too long")
                                 (when handle (ignore-errors (funcall (plist-get handle :cancel)))))))
      (condition-case err
          (setq handle
                (harness-call
                 'provider/complete
                 (append request
                         (list :on-event
                               (lambda (ev)
                                 (pcase (plist-get ev :type)
                                   ('text (setq text (concat text (or (plist-get ev :delta) ""))))
                                   ('done
                                    (let ((reason (plist-get ev :stop-reason)))
                                      (if (memq reason '(error cancelled))
                                          (finish nil (or (plist-get ev :error) (format "%s" reason)))
                                        (finish t text))))
                                   (_ nil)))))))
        (error (finish nil (harness-error-message err)))))
    promise))

(defun harness-todo-sync--dumb-request (session model prompt)
  "Return the request that asks MODEL, a dumb agent, PROMPT about SESSION.
It stands on its own: no transcript, no provider state, no tools and no
thinking, and `:ephemeral', so that a hosted provider answers it apart from
any session's conversation.  It is recorded as an internal session
made for SESSION."
  (list :model model
        :session (list :id (plist-get session :id) :cwd (plist-get session :cwd)
                       :host (plist-get session :host))
        :ephemeral t :job "Todo sync" :job-parent (plist-get session :id)
        :system harness-todo-sync--system-prompt
        :messages (list (list :role 'user :content (list (list :type "text" :text prompt))))
        :tools nil :no-thinking t :max-tokens harness-todo-sync--max-tokens))

(defun harness-todo-sync--own-request (session state todos)
  "Return the request that asks SESSION's own agent about its conversation.
STATE is a fork of its provider state, or nil for a provider that is sent
the conversation at every request.  TODOS is the list as it stands."
  (list :model (plist-get session :model) :session session
        :job "Todo sync" :job-parent (plist-get session :id)
        :system harness-todo-sync--system-prompt
        :messages (harness-todo-sync--messages (plist-get session :id)
                                               (harness-todo-sync--fork-question todos))
        :tools nil :provider-state state :no-thinking t :max-tokens harness-todo-sync--max-tokens))

(defun harness-todo-sync--ask (session todos)
  "Ask for SESSION's todo list, TODOS being what it reads now.
Return a promise of the answer, read: see `harness-todo-sync-parse'.  It
rejects with a message when the request fails or the answer holds no
list, nor UNCHANGED, nor NONE."
  (let* ((sid (plist-get session :id))
         (nodes (harness-call 'session/nodes sid))
         (dumb (lambda (model)
                 (harness-todo-sync--dumb-request
                  session model
                  (harness-todo-sync--prompt session nodes todos (gethash sid harness-todo-sync--anchor)))))
         (request
          (if (harness-todo-sync--own-agent-p)
              (harness-then
               (harness-todo-sync--forked-state session)
               (lambda (state)
                 ;; A hosted loop that gave no fork would answer in the
                 ;; process that runs the turn: ask it as a dumb agent is.
                 (if (and (null state) (harness-todo-sync--hosted-p session))
                     (funcall dumb (plist-get session :model))
                   (harness-todo-sync--own-request session state todos))))
            (harness-resolved (funcall dumb (harness-todo-sync--model session))))))
    (harness-then request
                  (lambda (request)
                    (harness-then (harness-todo-sync--complete request)
                                  (lambda (text)
                                    (or (harness-todo-sync-parse text)
                                        (signal 'harness-error
                                                (list "the model returned no usable todo list")))))))))

;;;; Applying the answer

(defun harness-todo-sync--fail (sid err promise)
  "Reject PROMISE, the request for SID's list, with ERR, and back off."
  (let ((msg (harness-error-message err)))
    (puthash sid (+ (float-time) harness-todo-sync--retry) harness-todo-sync--failed)
    (harness-log 'warn "todo-sync %s failed: %s" sid msg)
    (harness-emit 'todo-sync/failed sid msg)
    (harness-reject promise err)))

(defun harness-todo-sync--apply (sid before answer promise)
  "Take ANSWER, read from the model, for session SID and settle PROMISE.
BEFORE is the list as it stood when the request was made.  The promise
resolves with (:status STATUS :todos TODOS): `updated' when the list was
rewritten, `unchanged' when the answer left it as it was, `none' when
the model found the work too small for one, `stale' when the answer was
dropped because the list changed while the model was asked, and `gone'
when the session was deleted meanwhile."
  (if (not (harness-call 'session/exists-p sid))
      (harness-resolve promise (list :status 'gone))
    (let ((now (plist-get (harness-call 'session/get sid) :todos)))
      (cond
       ((not (equal now before))
        ;; The model wrote its own list meanwhile: it knows better.
        (harness-resolve promise (list :status 'stale :todos now)))
       ((eq (car answer) :unchanged)
        (harness-todo-sync--touch sid)
        (harness-resolve promise (list :status 'unchanged :todos now)))
       ((eq (car answer) :none)
        (harness-todo-sync--touch sid)
        (harness-resolve promise (list :status 'none :todos now)))
       (t
        (let ((todos (harness-todo-sync--todos (plist-get answer :todos) now)))
          (if (harness-todo-sync--same-p todos now)
              (progn (harness-todo-sync--touch sid)
                     (harness-resolve promise (list :status 'unchanged :todos now)))
            ;; The event this raises starts the count over.
            (harness-call 'session/set-todos sid todos)
            (harness-emit 'todo-sync/done sid todos)
            (harness-resolve promise (list :status 'updated :todos todos)))))))))

(defun harness-todo-sync--start (session)
  "Ask for SESSION's todo list now; return a promise of the outcome.
See `harness-todo-sync--apply' for what it resolves with.  It rejects
when the model could not be asked or gave nothing usable."
  (let* ((sid (plist-get session :id))
         (before (plist-get session :todos))
         (promise (harness-make-promise)))
    (puthash sid promise harness-todo-sync--running)
    (condition-case err
        (harness-then (harness-todo-sync--ask session before)
                      (lambda (answer)
                        (remhash sid harness-todo-sync--running)
                        (condition-case err
                            (harness-todo-sync--apply sid before answer promise)
                          (error (harness-todo-sync--fail sid err promise)))
                        nil)
                      (lambda (err)
                        (remhash sid harness-todo-sync--running)
                        (harness-todo-sync--fail sid err promise)
                        nil))
      (error (remhash sid harness-todo-sync--running)
             (harness-todo-sync--fail sid err promise)))
    promise))

;;;; When

(defun harness-todo-sync--setting (session)
  "Return SESSION's own switch: `on', `off', or `default' when it has none."
  (let ((value (plist-get (plist-get session :ext) harness-todo-sync--ext-key)))
    (cond ((eq value :false) 'off)
          ((harness-json-true-p value) 'on)
          (t 'default))))

(defun harness-todo-sync--every (session)
  "Return how many steps SESSION goes between syncs, or nil for none.
It is `harness-todo-sync-steps', unless the session switched the module
off for itself, or on where the option has none."
  (let ((steps (and (integerp harness-todo-sync-steps) (> harness-todo-sync-steps 0)
                    harness-todo-sync-steps)))
    (pcase (harness-todo-sync--setting session)
      ('off nil)
      ('on (or steps harness-todo-sync--default-steps))
      (_ steps))))

(defun harness-todo-sync--due-p (sid session every ending)
  "Non-nil when SID's list is due for a sync, EVERY steps apart.
SESSION is its record.  ENDING says a turn just ended: then a list that
still has open items is due after half as many steps, and none is made
from nothing."
  (let ((steps (gethash sid harness-todo-sync--steps 0)))
    (if ending
        (and (harness-todo-sync--open-p (plist-get session :todos))
             (>= steps (/ (1+ every) 2)))
      (>= steps every))))

(defun harness-todo-sync--fewest-steps ()
  "Return the fewest steps any session can be due after.
That is the interval of `harness-todo-sync-steps', or of the sessions
that turned the module on where it has none, halved as a turn that ended
halves it.  Below it no session needs to be looked at."
  (/ (1+ (if (and (integerp harness-todo-sync-steps) (> harness-todo-sync-steps 0))
             harness-todo-sync-steps
           harness-todo-sync--default-steps))
     2))

(defun harness-todo-sync--maybe (sid &optional ending)
  "Sync SID's todo list when it is due; ENDING says a turn just ended.
Return the promise of a request just started, or nil."
  (let ((retry (gethash sid harness-todo-sync--failed)))
    (when (and (not (gethash sid harness-todo-sync--running))
               (or (null retry) (>= (float-time) retry))
               ;; Cheap checks first: this runs at every step.
               (>= (gethash sid harness-todo-sync--steps 0) (harness-todo-sync--fewest-steps))
               (harness-call 'session/exists-p sid)
               (harness-todo-sync--counted-p sid))
      (let* ((session (harness-call 'session/get sid))
             (every (harness-todo-sync--every session)))
        (when (and every (harness-todo-sync--due-p sid session every ending))
          (harness-todo-sync--start session))))))

;;;; Methods

(harness-defmethod todo-sync/run (session-id)
  "Write the todo list of SESSION-ID now, whatever the steps say; return a promise.
It resolves with (:status STATUS :todos TODOS): `updated', `unchanged',
`none', `stale' or `gone' (see `harness-todo-sync--apply'), and rejects
when the model could not be asked or gave nothing usable.  A request
already under way for the session is the one returned.  An internal
session has no list to keep and is refused."
  (or (gethash session-id harness-todo-sync--running)
      (let ((session (harness-call 'session/get session-id)))
        (when (equal (format "%s" (plist-get session :kind)) "internal")
          (error "An internal session has no todo list to keep"))
        (harness-todo-sync--start session))))

(defun harness-todo-sync--setting-value (value)
  "Return VALUE, a switch as a client sends it, as `:ext' keeps it.
That is t, `:false' or nil, nil going back to what `harness-todo-sync-steps'
says.  Signal for anything else."
  (cond ((null value) nil)
        ((eq value :false) :false)
        ((eq value t) t)
        ((stringp value)
         (pcase (downcase (string-trim value))
           ((or "on" "yes" "true" "t") t)
           ((or "off" "no" "false") :false)
           ((or "" "default" "nil") nil)
           (_ (error "Not a switch: %s; it is on, off or default" value))))
        (t (error "Not a switch: %S; it is on, off or default" value))))

(harness-defmethod todo-sync/set (session-id enabled)
  "Turn todo syncing on or off for SESSION-ID; return its `todo-sync/state'.
ENABLED is t or \"on\" (sync its list even where the option is nil, every
`harness-todo-sync--default-steps' steps then), :false or \"off\" (never),
or nil or \"default\" to leave it to `harness-todo-sync-steps' again.  The
switch is kept with the session across restarts."
  (let ((value (harness-todo-sync--setting-value enabled)))
    (harness-call 'session/get session-id)
    (harness-call 'session/set-ext session-id harness-todo-sync--ext-key value)
    (harness-call 'todo-sync/state session-id)))

(harness-defmethod todo-sync/state (session-id)
  "Say how syncing stands for SESSION-ID, as a plist.
`:setting' is its own switch (\"on\", \"off\" or \"default\"), `:every' the
steps between syncs (nil when the list is not kept), `:steps' those
since its list was updated or checked, `:running' whether a request is
under way, and `:model' the model that would be asked (`:own' t when it
is the session's own agent, on a fork)."
  (let* ((session (harness-call 'session/get session-id))
         (every (and (not (memq (intern (format "%s" (plist-get session :kind)))
                                harness-todo-sync--skip-kinds))
                     (harness-todo-sync--every session))))
    (list :setting (symbol-name (harness-todo-sync--setting session))
          :every every
          :steps (gethash session-id harness-todo-sync--steps 0)
          :running (and (gethash session-id harness-todo-sync--running) t)
          :model (harness-todo-sync--model session)
          :own (if (harness-todo-sync--own-agent-p) t :false))))

;;;; Init

(defun harness-todo-sync--init ()
  "Follow the transcripts and the todo lists of the sessions."
  (harness-on 'session/node-added #'harness-todo-sync--on-node-added)
  (harness-on 'session/todos #'harness-todo-sync--on-todos)
  (harness-on 'agent/turn-ended #'harness-todo-sync--on-turn-ended)
  (harness-on 'session/deleted #'harness-todo-sync--on-deleted))

(defun harness-todo-sync--shutdown ()
  "Stop following the sessions."
  (harness-off (cons 'session/node-added #'harness-todo-sync--on-node-added))
  (harness-off (cons 'session/todos #'harness-todo-sync--on-todos))
  (harness-off (cons 'agent/turn-ended #'harness-todo-sync--on-turn-ended))
  (harness-off (cons 'session/deleted #'harness-todo-sync--on-deleted)))

(harness-declare-event 'todo-sync/done "(SESSION-ID TODOS) after a session's todo list was rewritten by the module.")
(harness-declare-event 'todo-sync/failed "(SESSION-ID MESSAGE) when the model could not be asked for a todo list, or gave none.")

(harness-define-module 'todo-sync
  :doc "Keep a session's todo list true to its work: every few steps a cheap model rewrites it."
  :requires '(session provider agent)
  :init #'harness-todo-sync--init
  :shutdown #'harness-todo-sync--shutdown)

(provide 'harness-todo-sync)
;;; harness-todo-sync.el ends here
