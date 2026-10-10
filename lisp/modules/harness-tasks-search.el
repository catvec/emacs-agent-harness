;;; harness-tasks-search.el --- Search and command the task board with a cheap model  -*- lexical-binding: t; -*-

;;; Commentary:

;; The task board's search, a command palette run by a model.  A line
;; typed on the board -- a question about the tasks ("did I have a task
;; about the question button?") or an order to manage some ("get rid of
;; the mq land task", "restart the errored tasks") -- goes, with a
;; compact dump of the board, to the cheapest model of the user's
;; provider.  It answers in one line of JSON and nothing else: which
;; tasks the line is about, and what to do with them.  No prose comes
;; back: the board shows the answer by showing only those tasks, and
;; says what the actions did.
;;
;; `task/search CWD QUERY' runs a search and returns its plan without
;; changing anything: the tasks to show, best match first, and the
;; actions the model proposes, each marked `:confirm' when it waits for
;; the user's OK.  Those are the ones that interrupt work, merge it or
;; send words to an agent (stop, verify, complete, message, reject, and
;; archiving a task at work); the others (archive, restore, retry,
;; start, priority) undo easily or do no harm, and a board runs them at
;; once.
;; `task/search-apply ACTIONS' runs actions and says how each went, with
;; the action that undoes it where there is one.
;;
;; The model reads the board only, as a rule.  When the board does not
;; say enough it may ask once to look further, instead of answering: the
;; sessions whose transcripts mention a text (by `session/search', its
;; words in any form, best match first; by grep over the logs, for the
;; text as typed, without that module), or the latest transcript of up
;; to three tasks; then it must answer.
;;
;; Every search runs under a session id of its own, so a provider that
;; keeps a process per session (the Claude CLI) gives each search a
;; fresh conversation, closed when the search ends (`provider/close').
;; `task/search-warm CWD', which a board calls as its search opens,
;; starts the process for the next search ahead (`provider/warm'), so it
;; is ready by the time the line is typed; one left unused is closed
;; after `harness-tasks-search--warm-idle' seconds.  The process works
;; in a directory of its own under the state directory: a search needs
;; no files, and the project's own history and instructions stay out of
;; it.  What a search costs goes to the usage records (`usage/record'),
;; under the board's project.
;;
;; The same search answers anywhere in the harness: `search/ask CWD
;; QUERY OPTS' reads, besides the board's tasks, the other sessions
;; (chats, side conversations, sub-agents, forks, of every project) and
;; the harness's commands, and its plan names sessions to open and
;; commands to run as well as tasks.  The commands are the UI's to know
;; -- its menu, keymaps and modes -- so it sends their catalogue along
;; (OPTS `:commands'), as the server may be another Emacs.  Where the
;; query was typed (OPTS `:context') sets what the search favours, its
;; bias: tasks on the board, sessions in the session list or a
;; conversation tree, commands anywhere else.  Favoured, not alone: the
;; model reads the rest too, and its one look further may search every
;; session's transcripts (`session/search', where that module is
;; loaded; their names otherwise) or the commands.  A search does not
;; settle for nothing.  Told to look beyond what it favours when that
;; has no answer, the model widens the search itself and says so in a
;; note; when it still answers with nothing, the search adds the nearest
;; sessions and commands it finds itself, with no third call of the
;; model, and says so.  `task/search' is the board's own search:
;; `search/ask' favouring tasks, which never widens by itself.  Both
;; share one system prompt, so the process `task/search-warm' starts
;; serves either.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-files)
(require 'harness-priority)

(defvar harness-state-directory)

;;;; Settings

(defcustom harness-tasks-search-model 'auto
  "Model that answers the task board's search, as PROVIDER:NAME, or `auto'.
`auto' (the default) asks the provider of the model new tasks start
with for its `cheap' tier (see `harness-provider-tier-model'): a search
reads a list and answers in a line, which the fastest, cheapest model
does best.  A PROVIDER:NAME forces that model, and nil uses the task
model itself."
  :type '(choice (const :tag "The task provider's cheap model" auto)
                 (const :tag "The task model" nil)
                 (string :tag "Model" :names model))
  :group 'harness)

(defcustom harness-tasks-search-thinking nil
  "Thinking level of the task board's search, or nil for the model's default.
A search reads a list and answers in one line, so it should not think
long: leave it nil, or name the model's lowest level."
  :type '(choice (const :tag "The model's default" nil) (string :tag "Level"))
  :group 'harness)

(defconst harness-tasks-search--timeout 45
  "Seconds one call of a search's model may take before the search fails.")

(defconst harness-tasks-search--max-tasks 200
  "Most tasks a search shows its model: the newest ones.")

(defconst harness-tasks-search--max-tasks-elsewhere 40
  "Most tasks a search that favours something else shows its model.
The newest ones: away from the board, sessions or commands come first.")

(defconst harness-tasks-search--max-sessions 25
  "Most sessions besides the board's tasks a search shows its model.
The best matches by name first, then the newest.  A search that favours
tasks shows only the ones whose names match, at most
`harness-tasks-search--max-sessions-matching'.")

(defconst harness-tasks-search--max-sessions-matching 10
  "Most sessions a search that favours tasks shows: those whose names match.")

(defconst harness-tasks-search--max-found 8
  "Most sessions a look at the sessions finds.")

(defconst harness-tasks-search--max-commands 30
  "Most commands a search that favours commands shows its model.
When fewer than `harness-tasks-search--few-commands' match the query,
the menu's commands make the list up to
`harness-tasks-search--menu-commands'.")

(defconst harness-tasks-search--max-commands-elsewhere 10
  "Most commands a search that favours something else shows its model.")

(defconst harness-tasks-search--few-commands 10
  "Fewer matching commands than this, and a search favouring them adds the menu's.")

(defconst harness-tasks-search--menu-commands 20
  "How many commands the menu's make the list of a search favouring commands up to.")

(defconst harness-tasks-search--max-looked-commands 15
  "Most commands a look at the commands finds.")

(defconst harness-tasks-search--plan-sessions 8
  "Most sessions a plan names.")

(defconst harness-tasks-search--plan-commands 6
  "Most commands a plan names.")

(defconst harness-tasks-search--max-nearest 5
  "Most sessions, and most commands, a search that found nothing adds itself.")

(defconst harness-tasks-search--stop-words
  '("a" "an" "and" "are" "can" "do" "does" "for" "from" "how" "i" "in" "is" "it" "me" "my" "of"
    "on" "or" "the" "to" "what" "when" "where" "which" "who" "why" "with" "you" "your" "about"
    "did" "had" "have" "that" "this" "there" "was" "were" "open" "show" "find" "get" "look"
    "looking" "session" "sessions" "command" "commands" "task" "tasks" "please")
  "Words of a query that say nothing about what it looks for.
Matching names and commands by the words of a query leaves them out.")

(defconst harness-tasks-search--max-tokens 2000
  "Output budget of a search's model: a list of ids and a few actions.")

(defconst harness-tasks-search--warm-idle 300
  "Seconds a model process started for a board's next search waits for it.
After that it is closed.")

(defconst harness-tasks-search--read-limit 3
  "Most tasks whose transcripts a search may read.")

(defconst harness-tasks-search--read-nodes 14
  "Transcript entries a search reads of each task.")

(defconst harness-tasks-search--grep-program "grep"
  "Program that searches the transcript logs.")

(defconst harness-tasks-search--stop-wait 20
  "Seconds archiving a task at work waits for it to stop.")

;;;; What the model is told

(defconst harness-tasks-search--system
  "You are the search box of a coding harness in Emacs: AI agent sessions (chats, task sessions, BTW side conversations, sub-agents, forks) working on software projects; a task board per project, each task one agent session working on one change; and the harness's Emacs commands. The engineer types a query: a question about tasks, sessions or commands (\"did I have a task about X?\", \"where did I debug the merge queue?\", \"how do I attach a file?\") or an order to manage tasks. You get one context line saying where the engineer is and what to favour, then the data blocks there are: the board's tasks, sessions, commands. Answer with exactly one line of JSON and nothing else: no prose, no markdown, no code fence.

{\"show\":[\"TASK-ID\",...],\"sessions\":[\"SESSION-ID\",...],\"commands\":[\"COMMAND\",...],\"do\":[{\"task\":\"TASK-ID\",\"action\":\"ACTION\",\"text\":\"...\"}],\"note\":\"...\"}

\"show\" lists the tasks the query is about, best match first, or [] when none fits. A question (\"did I have a task about X?\", \"what is working on Y?\", \"which ones failed?\") shows the tasks that answer it. An order shows the tasks it acts on.

\"sessions\" lists the sessions the query is about, by id or the first 8 characters given, best first: the session to open, the conversation where something was discussed or done.

\"commands\" lists the commands, by name exactly as listed, that do what the query asks or answer \"how do I ...\", best first, at most 5.

\"do\" stays [] unless the query clearly orders a change. Each entry acts on one task. ACTION is one of:
- archive: take a task off the board (\"get rid of\", \"remove\", \"delete\", \"hide\", \"clean up\"); a task at work is stopped first
- restore: bring an archived task back
- stop: stop a task that is working
- retry: have a task that stopped work again (\"restart\", \"retry\", \"resume\", \"rerun\", \"unstick\"): one that failed with an error, was cancelled or interrupted, or whose merge or write-up failed
- start: start a pending or backlog task now
- verify: accept a task waiting for review; its work merges (\"approve\", \"accept\", \"ship\")
- complete: mark a task done by hand
- message: send \"text\" to the task's agent: an instruction, a follow-up, a question for it
- reject: send a task in review back to its agent with \"text\" as the feedback
- priority: set the task's priority to \"text\": high, medium or low (\"prioritize\", \"urgent\", \"do first\", \"bump\", \"deprioritize\", \"later\"). While the slots are full, waiting tasks start highest priority first. A task says its priority when it is not medium.
\"text\" is only for message, reject and priority.

\"note\" is one short sentence when you looked beyond the favoured data or answer with what comes nearest (\"No task matched; these sessions mention it.\"); leave it out otherwise.

Favour what the context line names; the other lists may hold answers too.

Match loosely: words in any order, abbreviations (mq = merge queue), typos, synonyms; titles, requests, todos, summaries and branches all count. \"Errored\", \"failed\" or \"broken\" tasks are those whose state says error or failed. \"Them\", \"those\" and \"these\" are the tasks shown on the board now. Act only on tasks the query clearly means; when unsure, show them and do nothing.

Most queries need nothing but what you got. When it does not say enough, you may ask once to look further instead of answering, with one JSON object holding any of: {\"grep\":\"TEXT\"} the tasks whose session transcripts mention TEXT; {\"read\":[\"TASK-ID\",...]} the latest transcript of up to 3 tasks; {\"sessions\":\"TEXT\"} every session, not only the tasks', whose transcript or name mentions TEXT; {\"commands\":\"TEXT\"} more commands matching TEXT. Then you answer.

Do not give up at once: when the favoured data has nothing for the query, use that one look to search beyond it, sessions and commands, and answer with what comes nearest, saying so in note. Only when that finds nothing either, answer with empty lists."
  "System prompt of a search's model, on the board and anywhere else.
It never changes, so a model process started ahead for a search
\(`task/search-warm') has the settings the search comes with, whichever
method (`task/search', `search/ask') runs it.")

(defconst harness-tasks-search--final-text
  "That is all there is to look at. Now answer the query with one line of JSON: {\"show\":[...],\"sessions\":[...],\"commands\":[...],\"do\":[...],\"note\":\"...\"}."
  "What closes the message that hands a search's model what it asked to see.")

;;;; The board as the model reads it

(defun harness-tasks-search--str (value)
  "VALUE as a string: symbols and strings alike, nil as nil."
  (and value (format "%s" value)))

(defun harness-tasks-search--squash (text max)
  "TEXT on one line, its whitespace collapsed, at most MAX characters."
  (harness-truncate-end (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " (or text ""))) max))

(defun harness-tasks-search--session (task)
  "Return the session plist of TASK, or nil."
  (let ((sid (plist-get task :session)))
    (and sid (harness-method-exists-p 'session/exists-p)
         (harness-call 'session/exists-p sid)
         (ignore-errors (harness-call 'session/get sid)))))

(defun harness-tasks-search--title (task &optional session)
  "TASK's title on the board: its SESSION's name, else its own, else its prompt's.
A task gets its own `:name' as soon as it is submitted; without one the
title is its prompt's first line."
  (let ((name (plist-get (or session (harness-tasks-search--session task)) :name)))
    (when (harness-string-blank-p name) (setq name (plist-get task :name)))
    (if (harness-string-blank-p name)
        (let ((line (harness-first-line (or (plist-get task :prompt) ""))))
          (string-trim (if (string-match "\\`#+[ \t]+" line) (substring line (match-end 0)) line)))
      (string-trim name))))

(defun harness-tasks-search--working-p (task &optional session)
  "Non-nil when TASK is at work: its SESSION runs a turn, or waits mid-turn."
  (let ((session (or session (harness-tasks-search--session task)))
        (sid (plist-get task :session)))
    (or (member (harness-tasks-search--str (plist-get session :status)) '("running" "blocked"))
        (and sid (harness-method-exists-p 'agent/running) (harness-call 'agent/running sid) t))))

(defun harness-tasks-search--archived-p (task)
  "Non-nil when TASK is archived."
  (harness-json-true-p (plist-get task :archived)))

(defun harness-tasks-search--priority (value)
  "VALUE as a priority, \"low\", \"medium\" or \"high\"; nil when it names none.
VALUE is a string or a symbol; \"med\" is medium, and case and spaces
around it do not matter.  What a priority is, and which one a task
has, is the priority plugin's (`harness-priority-levels',
`harness-priority-of-task'), so the levels are read the way it reads
them."
  (when-let* ((level (harness-priority-known value)))
    (symbol-name level)))

(defun harness-tasks-search--waits-on (session)
  "Say what SESSION waits for the user on, or nil."
  (when-let* ((pending (car (plist-get session :pending))))
    (let ((payload (plist-get pending :payload)))
      (if (equal (harness-tasks-search--str (plist-get pending :kind)) "question")
          (format "asks you: %s" (harness-tasks-search--squash (plist-get payload :question) 120))
        (format "waits for your permission to run %s"
                (or (plist-get payload :tool) (plist-get payload :title) "a tool"))))))

(defun harness-tasks-search--status (task session)
  "Say where TASK, with SESSION, stands: its column, then what it does or waits on."
  (let* ((column (harness-tasks-search--str (plist-get task :column)))
         (state (harness-tasks-search--str (plist-get task :state)))
         (outcome (harness-tasks-search--str (plist-get task :outcome)))
         (err (plist-get task :error))
         (merged (harness-json-true-p (plist-get task :merged))))
    (concat
     (pcase column
       ("needs-input" "needs input")
       ("active" "in progress")
       (_ (or column state "?")))
     ": "
     (cond
      ((harness-tasks-search--waits-on session))
      ((equal outcome "duplicate")
       (format "its write-up refused it as a duplicate of %s" (or (plist-get task :duplicate-of) "another task")))
      ((and (equal state "refining") outcome) (format "its write-up stopped (%s)" outcome))
      ((equal state "refining") "being written up for the backlog")
      ((equal outcome "merge-failed") "its merge failed")
      ((equal outcome "adopted") "waits for your next message")
      ((equal column "needs-input") (format "stopped (%s)" (or outcome "?")))
      ((equal (harness-tasks-search--str (plist-get task :merge-status)) "conflict") "resolving merge conflicts")
      ((equal state "merging") "finished, merging")
      ((equal column "active") (if (harness-tasks-search--working-p task session) "working" "starting"))
      ((equal column "pending") "queued, starts on its own when a slot frees")
      ((equal column "backlog")
       (if (plist-get task :refined) "written up, waits for you to start it" "waits for you to start it"))
      ((equal column "review") (if merged "finished and merged, waits for your review" "finished, waits for your review"))
      ((equal column "done") (if merged "merged" "completed"))
      (t (or state "?")))
     (if (and (equal column "needs-input") (not (harness-string-blank-p err)))
         (concat " -- " (harness-tasks-search--squash err 160))
       "")
     (if (harness-tasks-search--archived-p task) "; archived" ""))))

(defun harness-tasks-search--facts (task session)
  "Return the other facts about TASK and its SESSION, as a list of strings."
  (let* ((todos (plist-get session :todos))
         (current (cl-find "in-progress" todos :key (lambda (td) (harness-tasks-search--str (plist-get td :status)))
                           :test #'equal))
         (done (cl-count "done" todos :key (lambda (td) (harness-tasks-search--str (plist-get td :status)))
                         :test #'equal))
         (summary (plist-get (plist-get task :report) :summary))
         (rounds (length (plist-get task :feedback)))
         (created (plist-get task :created))
         (finished (plist-get task :finished))
         (priority (harness-tasks-search--priority (plist-get task :priority))))
    (delq nil
          (list (and priority (not (equal priority "medium")) (format "priority %s" priority))
                (and current (format "doing: %s (%d/%d done)"
                                     (harness-tasks-search--squash (plist-get current :text) 100)
                                     done (length todos)))
                (and (not (harness-string-blank-p summary))
                     (format "handed in: %s" (harness-tasks-search--squash summary 220)))
                (and (> rounds 0) (format "sent back %d time%s" rounds (if (= rounds 1) "" "s")))
                (and (plist-get task :branch) (format "branch %s" (plist-get task :branch)))
                (and (numberp created) (format "created %s" (harness-relative-time created)))
                (and (numberp finished) (format "finished %s" (harness-relative-time finished)))))))

(defun harness-tasks-search--asked (task)
  "The words TASK was asked in: its note (a backlog task's), else its prompt."
  (let ((note (plist-get task :note)))
    (if (harness-string-blank-p note) (plist-get task :prompt) note)))

(defun harness-tasks-search--entry (task)
  "Return TASK as the model reads it: two or three lines."
  (let* ((session (harness-tasks-search--session task))
         (title (harness-tasks-search--title task session))
         (asked (harness-tasks-search--squash (harness-tasks-search--asked task) 260))
         (facts (harness-tasks-search--facts task session)))
    (concat (format "%s | %s | %s" (plist-get task :id) (harness-tasks-search--status task session)
                    (harness-tasks-search--squash title 120))
            ;; The request, unless the title is all of it.
            (if (or (string-empty-p asked) (equal asked (harness-tasks-search--squash title 260)))
                ""
              (concat "\n  asked: " asked))
            (if facts (concat "\n  " (string-join facts "; ")) ""))))

(defun harness-tasks-search--project-name (root)
  "The name of the project at ROOT."
  (if (harness-method-exists-p 'project/name)
      (or (ignore-errors (harness-call 'project/name root))
          (file-name-nondirectory (directory-file-name root)))
    (file-name-nondirectory (directory-file-name root))))

(defun harness-tasks-search--field (plist key)
  "The value of KEY in PLIST as a trimmed string, or nil when it is blank or false."
  (let ((value (plist-get plist key)))
    (when (and value (not (eq value :false)))
      (let ((text (string-trim (format "%s" value))))
        (and (not (string-empty-p text)) text)))))

(defun harness-tasks-search--id8 (id)
  "The first eight characters of session ID, as the model is shown it."
  (let ((id (or (harness-tasks-search--str id) "")))
    (if (> (length id) 8) (substring id 0 8) id)))

(defun harness-tasks-search--bias (bias context)
  "What a search favours: \"tasks\", \"sessions\" or \"commands\".
BIAS when it names one of them (a string or a symbol, singular or
plural), else what the view of CONTEXT suggests: tasks on the board,
sessions in the session list or a conversation tree, commands anywhere
else."
  (let ((name (and bias (not (eq bias :false))
                   (downcase (string-trim (format "%s" bias))))))
    (when (member name '("task" "session" "command"))
      (setq name (concat name "s")))
    (if (member name '("tasks" "sessions" "commands"))
        name
      (pcase (harness-tasks-search--str (plist-get context :view))
        ("board" "tasks")
        ((or "sessions" "tree") "sessions")
        (_ "commands")))))

(defun harness-tasks-search--context-project (context root)
  "The name of the project CONTEXT names, else that of the project at ROOT."
  (let ((project (harness-tasks-search--field context :project)))
    (cond ((null project) (harness-tasks-search--project-name root))
          ((file-name-absolute-p project)
           (harness-tasks-search--project-name (harness-files-main-checkout project)))
          (t project))))

(defun harness-tasks-search--context-line (context bias root)
  "The line that tells the model where the query was typed and what to favour.
CONTEXT is (:view VIEW :title TITLE :mode MODE :session ID :project
PROJECT), any of them missing: VIEW \"board\" for a task board, \"chat\"
for a session's chat, \"sessions\" for the session list, \"tree\" for a
conversation tree, anything else for some other buffer, TITLE and MODE
that buffer's.  BIAS is what the search favours (see
`harness-tasks-search--bias'), ROOT its project's root.  The session
the engineer is in, ID, is to stay out of the answer."
  (let* ((title (harness-tasks-search--field context :title))
         (quoted (and title (format "“%s”" (harness-tasks-search--squash title 80))))
         (mode (harness-tasks-search--field context :mode))
         (sid (harness-tasks-search--field context :session))
         (id8 (and sid (harness-tasks-search--id8 sid)))
         (where
          (pcase (harness-tasks-search--str (plist-get context :view))
            ("board" (format "the task board of project %s" (harness-tasks-search--context-project context root)))
            ("chat" (cond ((and quoted id8) (format "the chat of session %s (%s)" quoted id8))
                          (quoted (format "the chat of session %s" quoted))
                          (id8 (format "the chat of session %s" id8))
                          (t "a chat")))
            ("sessions" "the session list")
            ("tree" (if quoted (format "the conversation tree of %s" quoted) "a conversation tree"))
            (_ (cond ((and quoted mode) (format "Emacs buffer %s (%s)" quoted mode))
                     (quoted (format "Emacs buffer %s" quoted))
                     (mode (format "an Emacs buffer (%s)" mode))
                     (t "an Emacs buffer"))))))
    (concat "Context: " where "."
            (pcase bias
              ("tasks" " Favour tasks; sessions and commands count too.")
              ("sessions" " Favour sessions, then commands; tasks count too.")
              (_ " Favour commands, then sessions; tasks count too."))
            (if id8 (format " Leave session %s out of \"sessions\": the engineer is in it." id8) ""))))

(defun harness-tasks-search--text (root tasks query shown &optional context blocks no-board)
  "The first message of a search: the project of ROOT, its TASKS, BLOCKS and QUERY.
TASKS come newest first; SHOWN lists the ids the board shows now, when
it shows only some.  CONTEXT is the line saying where the query was
typed (`harness-tasks-search--context-line'); BLOCKS are more data,
the sessions and the commands, each left out when nil.  NO-BOARD says
there is no task board at all: task mode is off."
  (string-join
   (delq nil
         (append
          (list (concat
                 (format "Project: %s. Now: %s.\n" (harness-tasks-search--project-name root)
                         (format-time-string "%A %Y-%m-%d %H:%M"))
                 (if context (concat context "\n") "")
                 (cond (tasks
                        (format "%d task%s, newest first. Archived ones are off the board but still count."
                                (length tasks) (if (= 1 (length tasks)) "" "s")))
                       (no-board "There is no task board: task mode is off.")
                       (t "The board has no tasks."))
                 (if shown (format "\nShown on the board now: %s." (string-join shown ", ")) ""))
                (and tasks (mapconcat #'harness-tasks-search--entry tasks "\n")))
          blocks
          (list (format "Query: %s" (string-trim query))
                "Answer with one line of JSON.")))
   "\n\n"))

(defun harness-tasks-search--board-text (root tasks query shown)
  "The message that gives the model the board of ROOT, its TASKS, and QUERY.
TASKS come newest first; SHOWN lists the ids the board shows now, when
it shows only some.  That is the first message of a search on the
board with no sessions or commands to add; see
`harness-tasks-search--text'."
  (harness-tasks-search--text root tasks query shown
                              (harness-tasks-search--context-line '(:view "board") "tasks" root)))

;;;; Words

(defun harness-tasks-search--words (text)
  "The words of TEXT a match counts.
They are downcased, at least two characters long, and none of
`harness-tasks-search--stop-words'."
  (delete-dups
   (cl-remove-if (lambda (word) (or (< (length word) 2) (member word harness-tasks-search--stop-words)))
                 (split-string (downcase (or text "")) "[^[:alnum:]]+" t))))

(defun harness-tasks-search--text-words (text)
  "Every word of TEXT, downcased."
  (split-string (downcase (or text "")) "[^[:alnum:]]+" t))

(defun harness-tasks-search--has-p (word text-words)
  "Non-nil when one of TEXT-WORDS starts with the stem of WORD.
The stem is WORD's first five characters, all of it when shorter, so
\"debugged\" finds \"debug\" and \"attach\" \"attachments\"."
  (let ((stem (if (> (length word) 5) (substring word 0 5) word)))
    (cl-some (lambda (w) (string-prefix-p stem w)) text-words)))

(defun harness-tasks-search--score (words text)
  "How many of WORDS TEXT matches, whatever the case.
A word matches when TEXT has a word starting with its stem (see
`harness-tasks-search--has-p')."
  (let ((text-words (harness-tasks-search--text-words text)))
    (cl-count-if (lambda (word) (harness-tasks-search--has-p word text-words)) words)))

;;;; Sessions

;; The state of a search, a plist each search makes
;; (`harness-tasks-search--search'), holds what these read: `:sessions',
;; every session there is; `:board', the project's tasks by session id;
;; `:exclude', the session the engineer is in; `:found', the sessions a
;; look found, by id, each with the first `:snippet' that matched;
;; `:projects', project names by root, as they are worked out.

(defun harness-tasks-search--all-sessions ()
  "Every session there is, newest first; nil without the session module."
  (and (harness-method-exists-p 'session/list)
       (condition-case err
           (harness-call 'session/list)
         (error (harness-log 'warn "search: listing the sessions failed: %s" (harness-error-message err))
                nil))))

(defun harness-tasks-search--by-session (tasks)
  "A table of TASKS by the ids of their sessions."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (task tasks table)
      (when-let* ((sid (harness-tasks-search--str (plist-get task :session))))
        (puthash sid task table)))))

(defun harness-tasks-search--session-task (session search)
  "The task of SEARCH's board that SESSION works on, or nil."
  (let ((table (plist-get search :board)))
    (and (hash-table-p table)
         (gethash (harness-tasks-search--str (plist-get session :id)) table))))

(defun harness-tasks-search--session-name (session search)
  "What SESSION is called: its name, else the title of its task.
That is the task of SEARCH's board it works on."
  (let ((name (plist-get session :name)))
    (if (and (stringp name) (not (string-blank-p name)))
        (string-trim name)
      (when-let* ((task (harness-tasks-search--session-task session search)))
        (harness-tasks-search--title task)))))

(defun harness-tasks-search--session-kind (session search)
  "SESSION's kind as the model reads it: task, chat, btw, sub-agent, fork.
A session of a task on SEARCH's board reads as that task."
  (if-let* ((task (harness-tasks-search--session-task session search)))
      (format "task %s" (plist-get task :id))
    (pcase (harness-tasks-search--str (plist-get session :kind))
      ((or 'nil "main") "chat")
      ("subagent" "sub-agent")
      (kind kind))))

(defun harness-tasks-search--session-project (session search)
  "The name of SESSION's project, that of its main checkout; nil when unknown.
SEARCH keeps the names worked out already."
  (let ((root (or (harness-tasks-search--field session :project) (harness-tasks-search--field session :cwd)))
        (memo (plist-get search :projects)))
    (when root
      (or (and (hash-table-p memo) (gethash root memo))
          (let ((name (or (ignore-errors
                            (harness-tasks-search--project-name (harness-files-main-checkout root)))
                          (file-name-nondirectory (directory-file-name root)))))
            (when (hash-table-p memo) (puthash root name memo))
            name)))))

(defun harness-tasks-search--session-line (session search &optional detail)
  "SESSION as the model reads it, on one line.
That is its id's first eight characters, kind, status and project,
then DETAIL, by default when it was last updated and its name.  SEARCH
is the search's state."
  (let ((updated (plist-get session :updated)))
    (string-join
     (delq nil
           (list (harness-tasks-search--id8 (plist-get session :id))
                 (harness-tasks-search--session-kind session search)
                 (or (harness-tasks-search--str (plist-get session :status)) "?")
                 (or (harness-tasks-search--session-project session search) "?")
                 (or detail
                     (concat (if (numberp updated) (format "updated %s | " (harness-relative-time updated)) "")
                             (harness-tasks-search--squash
                              (or (harness-tasks-search--session-name session search) "(no name yet)")
                              120)))))
     " | ")))

(defun harness-tasks-search--rank-sessions (words sessions search)
  "SESSIONS ranked by how many of WORDS their names match, then newest first.
Return a list of (SCORE . SESSION).  SEARCH is the search's state."
  (let ((scored (mapcar (lambda (session)
                          (cons (if words
                                    (harness-tasks-search--score
                                     words (or (harness-tasks-search--session-name session search) ""))
                                  0)
                                session))
                        sessions)))
    (sort scored (lambda (a b)
                   (if (/= (car a) (car b))
                       (> (car a) (car b))
                     (> (or (plist-get (cdr a) :updated) 0) (or (plist-get (cdr b) :updated) 0)))))))

(defun harness-tasks-search--sessions-block (search)
  "The sessions SEARCH shows its model besides its board's tasks, or nil.
Every session but the one the engineer is in and those of the tasks it
shows, ranked by how well their names match the query, then newest
first: `harness-tasks-search--max-sessions' of them, or, when the
search favours tasks, only those whose names match, at most
`harness-tasks-search--max-sessions-matching'."
  (let* ((listed (delq nil (mapcar (lambda (task) (harness-tasks-search--str (plist-get task :session)))
                                   (plist-get search :tasks))))
         (exclude (plist-get search :exclude))
         (candidates (cl-remove-if (lambda (session)
                                     (let ((id (plist-get session :id)))
                                       (or (not (stringp id)) (equal id exclude) (member id listed))))
                                   (plist-get search :sessions)))
         (ranked (harness-tasks-search--rank-sessions
                  (harness-tasks-search--words (plist-get search :query)) candidates search))
         (picked (if (equal (plist-get search :bias) "tasks")
                     (seq-take (cl-remove-if-not (lambda (x) (> (car x) 0)) ranked)
                               harness-tasks-search--max-sessions-matching)
                   (seq-take ranked harness-tasks-search--max-sessions))))
    (when picked
      (concat "Sessions besides the board's tasks (chats, side conversations, sub-agents, forks), best match first:"
              (mapconcat (lambda (x) (concat "\n" (harness-tasks-search--session-line (cdr x) search)))
                         picked "")))))

(defun harness-tasks-search--known-sessions (search)
  "Every session SEARCH knows of: those there are, and those its look found."
  (let ((found (plist-get search :found)))
    (append (plist-get search :sessions)
            (and (hash-table-p found) (hash-table-values found)))))

(defun harness-tasks-search--resolve-session (ref sessions)
  "Return the id of the session of SESSIONS that REF names, or nil.
SESSIONS are session plists or ids.  REF is a whole id, or the start of
exactly one, at least six characters long: the model is shown eight."
  (when-let* ((ref (and (stringp ref) (string-trim ref)))
              ((not (string-empty-p ref))))
    (let ((ids (delete-dups (delq nil (mapcar (lambda (s) (if (stringp s) s (harness-tasks-search--str (plist-get s :id))))
                                              sessions)))))
      (or (car (member ref ids))
          (and (>= (length ref) 6)
               (let ((hits (cl-remove-if-not (lambda (id) (string-prefix-p ref id t)) ids)))
                 (and (= 1 (length hits)) (car hits))))))))

(defun harness-tasks-search--remember (session snippet search)
  "Remember that a look of SEARCH found SESSION, with its first SNIPPET."
  (let ((found (plist-get search :found))
        (id (harness-tasks-search--str (plist-get session :id))))
    (when (and id (hash-table-p found) (not (gethash id found)))
      (puthash id (append (list :snippet snippet) (harness-plist-remove session :snippet)) found))))

(defun harness-tasks-search--found-text (text result search)
  "Say what RESULT, what `session/search' found for TEXT, holds.
Return (WORDS . SESSIONS): the text for the model and the sessions
found, best first, remembered in SEARCH with their first snippet."
  (let* ((sessions (seq-take (cl-remove-if-not (lambda (s) (stringp (plist-get s :id)))
                                               (plist-get result :sessions))
                             harness-tasks-search--max-found))
         (snippets (lambda (s)
                     (delq nil (mapcar (lambda (hit)
                                         (let ((snippet (plist-get hit :snippet)))
                                           (and (stringp snippet) (not (string-blank-p snippet))
                                                (harness-tasks-search--squash snippet 200))))
                                       (seq-take (plist-get s :hits) 2))))))
    (dolist (s sessions)
      (harness-tasks-search--remember s (car (funcall snippets s)) search))
    (cons (if (null sessions)
              (format "No session mentions %S." text)
            (concat (format (cond ((equal (harness-tasks-search--str (plist-get result :engine)) "vectors")
                                   "No session mentions %S; these are the nearest in meaning:")
                                  ((harness-json-true-p (plist-get result :loose))
                                   "No session mentions all of %S; these mention some of it:")
                                  (t "Sessions that mention %S, best first:"))
                            text)
                    (mapconcat (lambda (s)
                                 (let ((name (harness-tasks-search--squash
                                              (or (harness-tasks-search--session-name s search) "(no name yet)") 120))
                                       (said (funcall snippets s)))
                                   (concat "\n" (harness-tasks-search--session-line
                                                 s search (if said (concat name ": " (string-join said " | ")) name)))))
                               sessions "")))
          sessions)))

(defun harness-tasks-search--names-text (text search &optional max)
  "Say which sessions have names that mention TEXT, without searching transcripts.
The fallback without the session search.  Return (WORDS . SESSIONS),
at most MAX of them (default `harness-tasks-search--max-found'),
remembered in SEARCH."
  (let* ((words (harness-tasks-search--words text))
         (exclude (plist-get search :exclude))
         (candidates (cl-remove-if (lambda (s) (or (not (stringp (plist-get s :id))) (equal (plist-get s :id) exclude)))
                                   (plist-get search :sessions)))
         (sessions (and words
                        (mapcar #'cdr (seq-take (cl-remove-if-not (lambda (x) (> (car x) 0))
                                                                  (harness-tasks-search--rank-sessions words candidates search))
                                                (or max harness-tasks-search--max-found))))))
    (dolist (s sessions) (harness-tasks-search--remember s nil search))
    (cons (if sessions
              (concat (format "Sessions whose names mention %S (their transcripts were not searched):" text)
                      (mapconcat (lambda (s) (concat "\n" (harness-tasks-search--session-line s search))) sessions ""))
            (format "No session name mentions %S." text))
          sessions)))

(defun harness-tasks-search--find-sessions (text search &optional max)
  "Return a promise of what the sessions say of TEXT, for SEARCH.
That is (WORDS . SESSIONS), the text for the model and the sessions
found, best first, at most MAX (default `harness-tasks-search--max-found').
Every session but the one the engineer is in is searched: by
`session/search', their transcripts and names, where that module is
loaded; else only their names (`harness-tasks-search--names-text')."
  (let ((max (or max harness-tasks-search--max-found)))
    (if (not (harness-method-exists-p 'session/search))
        (harness-resolved (harness-tasks-search--names-text text search max))
      (harness-then
       (harness-call-async 'session/search text
                           (list :mode 'text :exclude (delq nil (list (plist-get search :exclude)))
                                 :max-sessions max :max-matches 2))
       (lambda (result)
         (if (keywordp (car-safe result))
             (harness-tasks-search--found-text text result search)
           (harness-tasks-search--found-text text nil search)))
       (lambda (err)
         (harness-log 'warn "search: the session search for %S failed: %s" text (harness-error-message err))
         (harness-tasks-search--names-text text search max))))))

(defun harness-tasks-search--session-entry (id search)
  "Session ID as a plan names it, from what SEARCH knows of it.
That is (:id :name :kind :status :project :cwd :updated :snippet
:task): `:project' the project's name, `:snippet' the first snippet a
look found in it or nil, `:task' the id of the task of the board it
works on or nil."
  (let* ((found (and (hash-table-p (plist-get search :found)) (gethash id (plist-get search :found))))
         (session (or (cl-find id (plist-get search :sessions)
                               :key (lambda (s) (plist-get s :id)) :test #'equal)
                      found
                      (list :id id)))
         (task (harness-tasks-search--session-task session search)))
    (list :id id
          :name (harness-tasks-search--session-name session search)
          :kind (harness-tasks-search--str (plist-get session :kind))
          :status (harness-tasks-search--str (plist-get session :status))
          :project (harness-tasks-search--session-project session search)
          :cwd (plist-get session :cwd)
          :updated (plist-get session :updated)
          :snippet (plist-get found :snippet)
          :task (and task (plist-get task :id)))))

;;;; Commands

(defun harness-tasks-search--catalogue (value)
  "VALUE, the commands a search was given, as a list of entries.
Each is (:command NAME :keys KEYS :where WHERE :label LABEL :doc DOC
:here HERE), strings or nil but HERE, t when the command runs where
the search was opened, else false.  Entries without a name are dropped."
  (let (out)
    (dolist (entry (if (vectorp value) (append value nil) (harness-tasks-search--list value)))
      (when (keywordp (car-safe entry))
        (when-let* ((name (harness-tasks-search--field entry :command)))
          (push (list :command name
                      :keys (harness-tasks-search--field entry :keys)
                      :where (harness-tasks-search--field entry :where)
                      :label (harness-tasks-search--field entry :label)
                      :doc (harness-tasks-search--field entry :doc)
                      :here (if (harness-json-true-p (plist-get entry :here)) t :false))
                out))))
    (nreverse out)))

(defun harness-tasks-search--rank-commands (catalogue text)
  "The commands of CATALOGUE the words of TEXT match, best first.
Each word (see `harness-tasks-search--words') scores 3 when the
command's label has it, 2 its name (\"harness\" and \"ui\" aside), 1 its
doc and 1 where it applies, by its stem (`harness-tasks-search--has-p').
A command that scores nothing is left out; of those that score alike, one
that runs where the search was opened comes first, then the shorter name."
  (let ((words (harness-tasks-search--words text))
        (scored nil))
    (when words
      (dolist (entry catalogue)
        (let* ((parts (cl-remove-if (lambda (part) (member part '("harness" "ui")))
                                    (split-string (downcase (plist-get entry :command)) "-" t)))
               (label (harness-tasks-search--text-words (plist-get entry :label)))
               (doc (harness-tasks-search--text-words (plist-get entry :doc)))
               (where (harness-tasks-search--text-words (plist-get entry :where)))
               (score (cl-loop for word in words
                               sum (+ (if (harness-tasks-search--has-p word label) 3 0)
                                      (if (harness-tasks-search--has-p word parts) 2 0)
                                      (if (harness-tasks-search--has-p word doc) 1 0)
                                      (if (harness-tasks-search--has-p word where) 1 0)))))
          (when (> score 0) (push (cons score entry) scored))))
      (mapcar #'cdr
              (sort (nreverse scored)
                    (lambda (a b)
                      (let ((here-a (eq t (plist-get (cdr a) :here)))
                            (here-b (eq t (plist-get (cdr b) :here))))
                        (cond ((/= (car a) (car b)) (> (car a) (car b)))
                              ((not (eq here-a here-b)) here-a)
                              (t (< (length (plist-get (cdr a) :command))
                                    (length (plist-get (cdr b) :command))))))))))))

(defun harness-tasks-search--command-line (entry)
  "Command ENTRY as the model reads it: name | keys | where | label — doc.
Parts it lacks are left out."
  (let* ((label (plist-get entry :label))
         (doc (and (plist-get entry :doc) (harness-tasks-search--squash (plist-get entry :doc) 120)))
         (what (if (and label doc) (concat label " — " doc) (or label doc))))
    (string-join (delq nil (list (plist-get entry :command) (plist-get entry :keys) (plist-get entry :where) what))
                 " | ")))

(defun harness-tasks-search--commands-block (search)
  "The commands SEARCH shows its model, or nil.
Those its query matches (`harness-tasks-search--rank-commands'), at
most `harness-tasks-search--max-commands' when it favours commands and
`harness-tasks-search--max-commands-elsewhere' otherwise.  A search
favouring commands that matches few adds the menu's, so the model
knows what there is."
  (when-let* ((catalogue (plist-get search :catalogue)))
    (let* ((favoured (equal (plist-get search :bias) "commands"))
           (ranked (seq-take (harness-tasks-search--rank-commands catalogue (plist-get search :query))
                             (if favoured harness-tasks-search--max-commands
                               harness-tasks-search--max-commands-elsewhere)))
           (entries (if (and favoured (< (length ranked) harness-tasks-search--few-commands))
                        (append ranked
                                (seq-take (cl-remove-if (lambda (entry)
                                                          (or (memq entry ranked)
                                                              (not (equal (plist-get entry :where) "menu"))))
                                                        catalogue)
                                          (- harness-tasks-search--menu-commands (length ranked))))
                      ranked)))
      (when entries
        (concat "Commands (name | keys | where | what it does):"
                (mapconcat (lambda (entry) (concat "\n" (harness-tasks-search--command-line entry))) entries ""))))))

(defun harness-tasks-search--commands-text (text search)
  "Say which commands of SEARCH match TEXT, for a look at the commands."
  (let ((found (seq-take (harness-tasks-search--rank-commands (plist-get search :catalogue) text)
                         harness-tasks-search--max-looked-commands)))
    (if (null found)
        (format "No command matches %S." text)
      (concat (format "Commands matching %S:" text)
              (mapconcat (lambda (entry) (concat "\n" (harness-tasks-search--command-line entry))) found "")))))

(defun harness-tasks-search--resolve-command (ref catalogue)
  "Return the entry of CATALOGUE that REF names, or nil.
REF is a command's name, or its name without \"harness-\": nothing
outside CATALOGUE is ever named."
  (when-let* ((ref (and (stringp ref) (string-trim ref)))
              ((not (string-empty-p ref))))
    (let ((named (lambda (name) (cl-find name catalogue :key (lambda (e) (plist-get e :command)) :test #'equal))))
      (or (funcall named ref) (funcall named (concat "harness-" ref))))))

;;;; The model's answer

(defun harness-tasks-search--json (text)
  "Return the JSON object TEXT holds, as a plist, or nil.
The object may sit inside other text, a code fence say."
  (when (stringp text)
    (let ((start (string-search "{" text))
          (end (cl-position ?} text :from-end t)))
      (when (and start end (< start end))
        (let ((obj (ignore-errors (harness-json-parse (substring text start (1+ end))))))
          (and (keywordp (car-safe obj)) obj))))))

(defun harness-tasks-search--list (value)
  "VALUE as a list of items: a string alone becomes one."
  (cond ((stringp value) (list value))
        ((and (listp value) (not (keywordp (car-safe value)))) value)))

(defun harness-tasks-search--resolve (ref tasks)
  "Return the id of the task of TASKS that REF names, or nil.
REF is an id, an id without its \"t-\", or the start of exactly one."
  (when-let* ((ref (and (stringp ref) (string-trim ref)))
              ((not (string-empty-p ref))))
    (let ((ids (mapcar (lambda (task) (plist-get task :id)) tasks)))
      (or (car (member ref ids))
          (car (member (concat "t-" ref) ids))
          (let ((hits (cl-remove-if-not (lambda (id) (string-prefix-p ref id)) ids)))
            (and (= 1 (length hits)) (car hits)))))))

(defconst harness-tasks-search-actions
  '("archive" "restore" "stop" "retry" "start" "verify" "complete" "message" "reject" "priority")
  "The actions a search may propose.")

(defconst harness-tasks-search--confirm-actions '("stop" "verify" "complete" "message" "reject")
  "Actions that wait for the user's OK.
They interrupt work, merge it, or send words to an agent.  Archiving a
task at work does too, as it stops the task first.")

(defconst harness-tasks-search--text-actions '("message" "reject")
  "Actions that carry the words they send.")

(defconst harness-tasks-search--synonyms
  '(("remove" . "archive") ("delete" . "archive") ("drop" . "archive") ("hide" . "archive")
    ("unarchive" . "restore") ("cancel" . "stop") ("kill" . "stop") ("pause" . "stop")
    ("restart" . "retry") ("resume" . "retry") ("rerun" . "retry")
    ("approve" . "verify") ("accept" . "verify") ("done" . "complete") ("finish" . "complete")
    ("send" . "message") ("tell" . "message") ("steer" . "message") ("reply" . "message")
    ("send-back" . "reject") ("send back" . "reject")
    ("prioritize" . "priority") ("prioritise" . "priority") ("reprioritize" . "priority")
    ("set-priority" . "priority") ("set priority" . "priority"))
  "Names a model may give an action instead of its own: (NAME . ACTION).")

(defun harness-tasks-search--action-name (value)
  "Return the action VALUE names, or nil."
  (when-let* ((name (and (or (stringp value) (symbolp value)) value
                         (downcase (string-trim (format "%s" value))))))
    (or (car (member name harness-tasks-search-actions))
        (cdr (assoc name harness-tasks-search--synonyms)))))

(defun harness-tasks-search--applies-p (action task session &optional priority)
  "Non-nil when ACTION means anything for TASK, with SESSION, as it is now.
Archiving an archived task, restoring one that is not, stopping one
not at work, and giving a task the PRIORITY it has (or a done task any)
do nothing; whether the rest can run, running them says."
  (pcase action
    ("archive" (not (harness-tasks-search--archived-p task)))
    ("restore" (harness-tasks-search--archived-p task))
    ("stop" (harness-tasks-search--working-p task session))
    ("priority" (and (not (equal (harness-tasks-search--str (plist-get task :column)) "done"))
                     (not (equal priority (or (harness-tasks-search--priority (plist-get task :priority))
                                              "medium")))))
    (_ t)))

(defun harness-tasks-search--action (entry tasks)
  "Return the action ENTRY of the model's answer proposes for one of TASKS, or nil.
The action is (:task ID :action NAME :text TEXT :title TITLE :confirm
BOOL); nil when ENTRY names no task of the board, no known action, an
action that would do nothing, one that needs words without them, or a
priority action whose text names no priority.  The TEXT of a priority
action is the priority: low, medium or high."
  (when (keywordp (car-safe entry))
    (let* ((id (harness-tasks-search--resolve (or (plist-get entry :task) (plist-get entry :id)) tasks))
           (task (and id (cl-find id tasks :key (lambda (task) (plist-get task :id)) :test #'equal)))
           (session (and task (harness-tasks-search--session task)))
           (name (harness-tasks-search--action-name (or (plist-get entry :action) (plist-get entry :do))))
           (text (let ((text (plist-get entry :text))) (and (stringp text) (string-trim text))))
           (priority (and (equal name "priority") (harness-tasks-search--priority text))))
      (when (and task name
                 (or (not (member name harness-tasks-search--text-actions)) (not (harness-string-blank-p text)))
                 (or (not (equal name "priority")) priority)
                 (harness-tasks-search--applies-p name task session priority))
        (list :task id :action name
              :text (or priority (and (member name harness-tasks-search--text-actions) text))
              :title (harness-tasks-search--title task session)
              :confirm (if (or (member name harness-tasks-search--confirm-actions)
                               (and (equal name "archive") (harness-tasks-search--working-p task session)))
                           t
                         :false))))))

(defun harness-tasks-search--task-entry (id tasks)
  "Task ID of TASKS as a plan names it.
That is (:id ID :title TITLE :status STATUS :session SID), STATUS
saying where it stands, as the model read it: a view without the board
shows the task by these."
  (let* ((task (cl-find id tasks :key (lambda (task) (plist-get task :id)) :test #'equal))
         (session (and task (harness-tasks-search--session task))))
    (list :id id
          :title (and task (harness-tasks-search--title task session))
          :status (and task (harness-tasks-search--status task session))
          :session (and task (harness-tasks-search--str (plist-get task :session))))))

(defun harness-tasks-search--named-sessions (answer search)
  "The ids of the sessions ANSWER names that SEARCH knows of, best first.
The session the engineer is in is left out, as are repeats, and there
are at most `harness-tasks-search--plan-sessions' of them."
  (let ((known (harness-tasks-search--known-sessions search))
        (ids nil))
    (dolist (ref (harness-tasks-search--list (plist-get answer :sessions)))
      (when-let* ((id (harness-tasks-search--resolve-session ref known)))
        (unless (or (member id ids) (equal id (plist-get search :exclude)))
          (push id ids))))
    (seq-take (nreverse ids) harness-tasks-search--plan-sessions)))

(defun harness-tasks-search--named-commands (answer search)
  "The entries of the commands ANSWER names that SEARCH was given, best first.
Repeats are left out, and there are at most
`harness-tasks-search--plan-commands' of them."
  (let ((catalogue (plist-get search :catalogue)))
    (seq-take (delete-dups (delq nil (mapcar (lambda (ref) (harness-tasks-search--resolve-command ref catalogue))
                                             (harness-tasks-search--list (plist-get answer :commands)))))
              harness-tasks-search--plan-commands)))

(defun harness-tasks-search--plan (answer tasks &optional search)
  "Return the plan made of the model's ANSWER about TASKS.
That is (:ids IDS :actions ACTIONS :tasks ENTRIES :sessions SESSIONS
:commands COMMANDS :note NOTE).  IDS are the tasks to show, best match
first; every task an action is for is among them.  Ids that name no
task of the board are dropped.  ENTRIES are those tasks, each (:id
:title :status :session), for a view without the board.

SEARCH, the search's state, is what sessions and commands are named
from: SESSIONS are the sessions ANSWER names, each as
`harness-tasks-search--session-entry' gives it, and COMMANDS the
entries of its catalogue ANSWER names.  NOTE is what the model says of
its answer, or nil."
  (let* ((ids (delete-dups (delq nil (mapcar (lambda (ref) (harness-tasks-search--resolve ref tasks))
                                             (harness-tasks-search--list (plist-get answer :show))))))
         (actions (delq nil (mapcar (lambda (entry) (harness-tasks-search--action entry tasks))
                                    (harness-tasks-search--list
                                     (or (plist-get answer :do) (plist-get answer :actions))))))
         (note (let ((note (plist-get answer :note)))
                 (and (stringp note) (not (string-blank-p note)) (string-trim note)))))
    (dolist (action actions)
      (unless (member (plist-get action :task) ids)
        (setq ids (append ids (list (plist-get action :task))))))
    (list :ids ids :actions actions
          :tasks (mapcar (lambda (id) (harness-tasks-search--task-entry id tasks)) ids)
          :sessions (and search (mapcar (lambda (id) (harness-tasks-search--session-entry id search))
                                        (harness-tasks-search--named-sessions answer search)))
          :commands (and search (harness-tasks-search--named-commands answer search))
          :note note)))

;;;; Looking further

(defun harness-tasks-search--wants (answer tasks &optional search)
  "Return what ANSWER asks to look at before it answers, or nil.
That is (:grep TEXT :read IDS :sessions TEXT :commands TEXT), from an
answer that shows, names and does nothing; IDS name tasks of TASKS, at
most `harness-tasks-search--read-limit' of them.  A text for
\"sessions\" or \"commands\" asks to search them, where a list answers;
one that names a session or a command SEARCH knows of answers too."
  (let* ((text (lambda (key)
                 (let ((value (plist-get answer key)))
                   (and (stringp value) (not (string-blank-p value)) (string-trim value)))))
         (grep (funcall text :grep))
         (read (seq-take (delete-dups (delq nil (mapcar (lambda (ref) (harness-tasks-search--resolve ref tasks))
                                                        (harness-tasks-search--list (plist-get answer :read)))))
                         harness-tasks-search--read-limit))
         (sessions (and search (harness-tasks-search--named-sessions answer search)))
         (commands (and search (harness-tasks-search--named-commands answer search)))
         (find-sessions (and (null sessions) (funcall text :sessions)))
         (find-commands (and (null commands) (funcall text :commands))))
    (when (and (or grep read find-sessions find-commands)
               (null (harness-tasks-search--list (plist-get answer :show)))
               (null sessions) (null commands)
               (not (consp (plist-get answer :sessions)))
               (not (consp (plist-get answer :commands)))
               (null (harness-tasks-search--list (or (plist-get answer :do) (plist-get answer :actions)))))
      (list :grep grep :read read :sessions find-sessions :commands find-commands))))

(defun harness-tasks-search--node-text (node)
  "The readable text of transcript NODE."
  (pcase (harness-tasks-search--str (plist-get node :kind))
    ("tool-call" (concat (or (plist-get node :title) (plist-get node :tool) "")
                         (if (plist-get node :input) (concat " " (harness-json-encode-text (plist-get node :input))) "")))
    ("tool-result" (or (plist-get node :output) ""))
    (_ (or (plist-get node :content) ""))))

(defun harness-tasks-search--read (task)
  "Return the latest transcript of TASK's session, briefly, as text."
  (let* ((session (harness-tasks-search--session task))
         (id (plist-get task :id))
         (all (and session (ignore-errors
                             (harness-call 'session/nodes (plist-get session :id) (list :limit 60))))))
    (cond
     ((not session)
      (format "%s has no session yet." id))
     ((null all)
      (format "%s has not started yet." id))
     (t
      (let* ((nodes (last (cl-remove-if-not
                           (lambda (n) (member (harness-tasks-search--str (plist-get n :kind))
                                               '("user" "assistant" "tool-call" "plan")))
                           all)
                          harness-tasks-search--read-nodes))
             (todos (plist-get session :todos)))
        (concat (format "%s, its latest transcript:" id)
                (if todos
                    (concat "\n  todos: "
                            (mapconcat (lambda (td) (format "[%s] %s" (harness-tasks-search--str (plist-get td :status))
                                                            (harness-tasks-search--squash (plist-get td :text) 80)))
                                       todos "; "))
                  "")
                (mapconcat (lambda (n) (format "\n  [%s] %s" (harness-tasks-search--str (plist-get n :kind))
                                               (harness-tasks-search--squash (harness-tasks-search--node-text n) 300)))
                           nodes "")))))))

(defun harness-tasks-search--snippet (text needle)
  "The part of TEXT around NEEDLE, on one line."
  (let* ((case-fold-search t)
         (text (harness-tasks-search--squash text 100000))
         (pos (string-search (downcase needle) (downcase text))))
    (if (not pos)
        (harness-truncate-end text 160)
      (let ((from (max 0 (- pos 70)))
            (to (min (length text) (+ pos (length needle) 90))))
        (concat (if (> from 0) "…" "") (substring text from to) (if (< to (length text)) "…" ""))))))

(defun harness-tasks-search--find (needle tasks)
  "Return a promise of the text saying which of TASKS' transcripts mention NEEDLE.
They are searched by `session/search', for NEEDLE's words in any form,
best match first.  When no transcript has every word, the text says the
ones listed have some of them; when none has any, and an embedding
model is set, that they are the nearest in meaning."
  (let ((by-session (make-hash-table :test 'equal)))
    (dolist (task tasks)
      (when (stringp (plist-get task :session))
        (puthash (plist-get task :session) task by-session)))
    (if (zerop (hash-table-count by-session))
        (harness-resolved (format "No task session mentions %S." needle))
      (harness-then
       (harness-call 'session/search needle
                     (list :mode 'text :sessions (hash-table-keys by-session)
                           :max-sessions (hash-table-count by-session) :max-matches 2))
       (lambda (result)
         (let ((found (cl-remove-if-not (lambda (s) (plist-get s :hits)) (plist-get result :sessions))))
           (if (null found)
               (format "No task session mentions %S." needle)
             (concat (format (cond ((equal (plist-get result :engine) "vectors")
                                    "No task session mentions %S; these are the nearest in meaning:")
                                   ((plist-get result :loose)
                                    "No task session mentions all of %S; these mention some of it:")
                                   (t "Task sessions that mention %S:"))
                             needle)
                     (mapconcat (lambda (s)
                                  (format "\n%s: %s" (plist-get (gethash (plist-get s :id) by-session) :id)
                                          (mapconcat (lambda (h) (plist-get h :snippet)) (plist-get s :hits) " | ")))
                                found "")))))))))

(defun harness-tasks-search--grep (needle tasks)
  "Return a promise of the text saying which of TASKS' transcripts mention NEEDLE.
With the session search (harness-session-search.el) that is
`harness-tasks-search--find'.  Without it, the node logs are searched by
`harness-tasks-search--grep-program', in a process: transcripts are
never loaded just to be searched."
  (if (harness-method-exists-p 'session/search)
      (harness-tasks-search--find needle tasks)
    (harness-tasks-search--grep-logs needle tasks)))

(defun harness-tasks-search--grep-logs (needle tasks)
  "Return a promise of the text saying which of TASKS' logs hold NEEDLE, by grep."
  (let* ((dir (expand-file-name "sessions" harness-state-directory))
         (by-session (make-hash-table :test 'equal))
         (files (cl-loop for task in tasks
                         for sid = (plist-get task :session)
                         for file = (and sid (expand-file-name (format "%s.nodes.jsonl" sid) dir))
                         when (and file (file-exists-p file))
                         do (puthash sid task by-session)
                         and collect file))
         ;; In a log, text sits inside JSON strings.
         (fragment (let ((json (json-serialize needle)))
                     (substring (if (multibyte-string-p json) json (decode-coding-string json 'utf-8)) 1 -1))))
    (if (null files)
        (harness-resolved (format "No task session mentions %S." needle))
      (harness-then
       (harness-run-command (append (list harness-tasks-search--grep-program "-i" "-H" "-F" "--max-count=3"
                                          "-e" fragment "--")
                                    files)
                            :cwd dir :timeout 20 :name "harness-task-search-grep")
       (lambda (r)
         (let ((hits (make-hash-table :test 'equal)) order)
           (dolist (line (split-string (or (plist-get r :stdout) "") "\n" t))
             ;; A line holds a whole node, which can be megabytes long:
             ;; `harness-grep-hit' splits it without a regexp.
             (when-let* ((hit (harness-grep-hit line ".nodes.jsonl")))
               (let ((task (gethash (car hit) by-session))
                     (node (ignore-errors (harness-json-parse (cdr hit)))))
                 (when (and task node)
                   (let ((id (plist-get task :id)))
                     (unless (gethash id hits) (push id order))
                     (puthash id (append (gethash id hits)
                                         (list (harness-tasks-search--snippet
                                                (harness-tasks-search--node-text node) needle)))
                              hits))))))
           (if (null order)
               (format "No task session mentions %S." needle)
             (concat (format "Task sessions that mention %S:" needle)
                     (mapconcat (lambda (id)
                                  (format "\n%s: %s" id (string-join (seq-take (gethash id hits) 2) " | ")))
                                (nreverse order) "")))))))))

(defun harness-tasks-search--look (wants tasks &optional search)
  "Return a promise of the text of what WANTS asked to see of TASKS.
That is, in this order, the task transcripts that mention a text, the
tasks' latest transcripts, the sessions that mention a text and the
commands that match one.  SEARCH, the search's state, is what the
sessions and commands are looked up in; the sessions found are
remembered there."
  (let ((reads (mapcar (lambda (id)
                         (harness-tasks-search--read
                          (cl-find id tasks :key (lambda (task) (plist-get task :id)) :test #'equal)))
                       (plist-get wants :read))))
    (harness-then (harness-all
                   (list (if (plist-get wants :grep)
                             (harness-tasks-search--grep (plist-get wants :grep) tasks)
                           (harness-resolved nil))
                         (if (plist-get wants :sessions)
                             (harness-then (harness-tasks-search--find-sessions (plist-get wants :sessions) search)
                                           #'car)
                           (harness-resolved nil))))
                  (lambda (found)
                    (concat "Here is what you asked to see.\n\n"
                            (string-join (delq nil (append (list (car found))
                                                           reads
                                                           (list (cadr found)
                                                                 (and (plist-get wants :commands)
                                                                      (harness-tasks-search--commands-text
                                                                       (plist-get wants :commands) search)))))
                                         "\n\n")
                            "\n\n" harness-tasks-search--final-text)))))

(defun harness-tasks-search--and (parts)
  "PARTS, strings, joined as words list them: \"a\", \"a and b\", \"a, b and c\"."
  (if (cddr parts)
      (concat (string-join (butlast parts) ", ") " and " (car (last parts)))
    (string-join parts " and ")))

(defun harness-tasks-search--looked (wants)
  "Say in a few words what WANTS looked at, for the board."
  (harness-tasks-search--and
   (delq nil (list (and (plist-get wants :grep)
                        (format "searched the transcripts for %S" (plist-get wants :grep)))
                   (and (plist-get wants :read)
                        (let ((n (length (plist-get wants :read))))
                          (format "read %d transcript%s" n (if (= n 1) "" "s"))))
                   (and (plist-get wants :sessions)
                        (format "searched the sessions for %S" (plist-get wants :sessions)))
                   (and (plist-get wants :commands)
                        (format "looked up commands for %S" (plist-get wants :commands)))))))

;;;; The model

(defun harness-tasks-search--root (cwd)
  "The project root of CWD: the main checkout, as the board's."
  (let ((root (if (harness-method-exists-p 'project/root)
                  (harness-call 'project/root cwd)
                (file-name-as-directory (expand-file-name cwd)))))
    (harness-files-main-root root)))

(defun harness-tasks-search--model (cwd)
  "Return the model that answers the search of CWD's board, or nil.
See `harness-tasks-search-model'."
  (let ((base (or (plist-get (and (harness-method-exists-p 'task/settings)
                                  (ignore-errors (harness-call 'task/settings cwd)))
                             :model)
                  (and (boundp 'harness-model) (symbol-value 'harness-model))))
        (choice harness-tasks-search-model))
    (cond ((or (eq choice 'auto) (equal choice "auto"))
           (or (and base (harness-method-exists-p 'provider/tier-model)
                    (ignore-errors (harness-call 'provider/tier-model base 'cheap)))
               base))
          ((and (stringp choice) (not (string-empty-p choice))) choice)
          (t base))))

(defun harness-tasks-search--directory ()
  "The directory a search's model process works in: one of its own."
  (harness-ensure-directory (expand-file-name "task-search/" harness-state-directory)))

(defun harness-tasks-search--request (model sid)
  "The request a search with MODEL makes under session id SID, without messages."
  (list :model model
        :session (list :id sid :cwd (file-name-as-directory (harness-tasks-search--directory)))
        :system harness-tasks-search--system
        :thinking harness-tasks-search-thinking
        :max-tokens harness-tasks-search--max-tokens
        :tools nil))

(defun harness-tasks-search--record (search event)
  "Record the usage EVENT of SEARCH's model, under its project."
  (when (harness-method-exists-p 'usage/record)
    (condition-case err
        (let* ((model (plist-get search :model))
               (cost (plist-get event :cost))
               (cost (if (numberp cost) cost
                       (or (and (harness-method-exists-p 'usage/price)
                                (ignore-errors (harness-call 'usage/price model event)))
                           0)))
               (list-cost (plist-get event :list-cost))
               (billing (harness-billing-of event)))
          (when (cl-some (lambda (k) (numberp (plist-get event k))) '(:input :output :cache-read :cache-write))
            (harness-call 'usage/record
                          (list :session nil :project (plist-get search :root) :model model
                                :input (plist-get event :input) :output (plist-get event :output)
                                :cache-read (plist-get event :cache-read)
                                :cache-write (plist-get event :cache-write)
                                :cost cost
                                :list-cost (cond ((numberp list-cost) list-cost)
                                                 ((eq billing 'subscription)
                                                  (or (ignore-errors (harness-call 'usage/price model event)) cost))
                                                 (t cost))
                                :billing billing))))
      (error (harness-log 'warn "task search: recording usage failed: %S" err)))))

(defun harness-tasks-search--ask (search messages)
  "Send MESSAGES to SEARCH's model; return a promise of its reply's text.
It fails after `harness-tasks-search--timeout' seconds, and when the
provider ends the request with an error."
  (harness-with-promise (resolve reject)
    (let* ((text "") (settled nil) (timer nil) (handle nil)
           (finish (lambda (ok value)
                     (unless settled
                       (setq settled t)
                       (when timer (cancel-timer timer))
                       (funcall (if ok resolve reject) value)))))
      (setq timer (run-at-time harness-tasks-search--timeout nil
                               (lambda ()
                                 (funcall finish nil (list 'error (format "The model took longer than %ds"
                                                                          harness-tasks-search--timeout)))
                                 (when handle (ignore-errors (funcall (plist-get handle :cancel)))))))
      (setq handle
            (harness-call
             'provider/complete
             (append (harness-tasks-search--request (plist-get search :model) (plist-get search :session))
                     (list :messages messages
                           :on-event
                           (lambda (ev)
                             (pcase (plist-get ev :type)
                               ('text (setq text (concat text (or (plist-get ev :delta) ""))))
                               ('usage (harness-tasks-search--record search ev))
                               ('done
                                (let ((reason (plist-get ev :stop-reason)))
                                  (if (memq reason '(error cancelled))
                                      (funcall finish nil (list 'error (format "The model failed: %s"
                                                                               (or (plist-get ev :error) reason))))
                                    (funcall finish t text)))))))))))))

(defun harness-tasks-search--user (text)
  "A user message of TEXT."
  (list :role 'user :content (list (list :type "text" :text text))))

(defun harness-tasks-search--no-answer (text)
  "A rejected promise saying why TEXT, the model's reply, holds no answer."
  (harness-rejected
   (list 'error (if (harness-string-blank-p text)
                    "The model gave no answer"
                  (format "The model did not answer in JSON: %s" (harness-tasks-search--squash text 120))))))

;;;; Warming up

(defvar harness-tasks-search--warm (make-hash-table :test 'equal)
  "Project root -> (:session ID :model MODEL :timer TIMER).
A model process started for the next search of that project's board.")

(defun harness-tasks-search--new-session ()
  "A session id of a search's own."
  (format "task-search-%s" (harness-short-id 10)))

(defun harness-tasks-search--drop-warm (root &optional keep-process)
  "Forget the process warmed for ROOT's next search.
It is closed unless KEEP-PROCESS.  Return its session id, or nil when
there was none."
  (when-let* ((entry (gethash root harness-tasks-search--warm)))
    (remhash root harness-tasks-search--warm)
    (when (timerp (plist-get entry :timer)) (cancel-timer (plist-get entry :timer)))
    (unless keep-process
      (harness-call 'provider/close (plist-get entry :model) (plist-get entry :session)))
    (plist-get entry :session)))

(defun harness-tasks-search--expire (root sid)
  "Close the process warmed for ROOT's next search, SID, if it is still waiting."
  (when (equal sid (plist-get (gethash root harness-tasks-search--warm) :session))
    (harness-tasks-search--drop-warm root)))

(defun harness-tasks-search--take-session (root model)
  "Return the session id a search of ROOT's board with MODEL runs under.
The one warmed for it when its model is MODEL, else a new one."
  (let ((entry (gethash root harness-tasks-search--warm)))
    (if (and entry (equal (plist-get entry :model) model))
        (harness-tasks-search--drop-warm root t)
      (harness-tasks-search--new-session))))

(harness-defmethod task/search-warm (cwd)
  "Start the model process the next search of CWD's board will use.
Return (:model MODEL :warm BOOL), MODEL being the model that will
answer and BOOL t when a process is ready for it, else false; nil when
there is no model to search with.  A board calls this as its search
opens, so the process is up by the time the line is typed.  Only a
provider that keeps a process per session prepares anything (see
`provider/warm'); a process left unused is closed after
`harness-tasks-search--warm-idle' seconds."
  (let* ((cwd (file-name-as-directory (expand-file-name cwd)))
         (root (harness-tasks-search--root cwd))
         (model (harness-tasks-search--model cwd))
         (entry (gethash root harness-tasks-search--warm))
         (warm
          (cond
           ((or (null model) (not (harness-method-exists-p 'provider/warm))) nil)
           ((and entry (equal (plist-get entry :model) model))
            ;; Ready: it waits a while longer.
            (when (timerp (plist-get entry :timer)) (cancel-timer (plist-get entry :timer)))
            (puthash root (plist-put (copy-sequence entry) :timer
                                     (run-at-time harness-tasks-search--warm-idle nil #'harness-tasks-search--expire
                                                  root (plist-get entry :session)))
                     harness-tasks-search--warm)
            t)
           (t
            (when entry (harness-tasks-search--drop-warm root))
            (let ((sid (harness-tasks-search--new-session)))
              (when (harness-call 'provider/warm (harness-tasks-search--request model sid))
                (puthash root (list :session sid :model model
                                    :timer (run-at-time harness-tasks-search--warm-idle nil
                                                        #'harness-tasks-search--expire root sid))
                         harness-tasks-search--warm)
                t))))))
    (and model (list :model model :warm (if warm t :false)))))

;;;; Searching

(defun harness-tasks-search--board (cwd)
  "Return the tasks of CWD's board a search reads: the newest first."
  (let ((tasks (harness-call 'task/list cwd)))
    (reverse (last tasks harness-tasks-search--max-tasks))))

(defun harness-tasks-search--empty-p (plan)
  "Non-nil when PLAN shows, names and does nothing."
  (not (or (plist-get plan :ids) (plist-get plan :actions)
           (plist-get plan :sessions) (plist-get plan :commands))))

(defun harness-tasks-search--nearest (search)
  "Return a promise of what comes nearest the query of SEARCH, which found nothing.
That is (:sessions SESSIONS :commands COMMANDS :note NOTE :widened t):
the sessions a look at them for the whole query finds and the commands
it matches, at most `harness-tasks-search--max-nearest' of each, and
NOTE saying so, or saying nothing matched at all.  The model is not
asked again."
  (let ((query (plist-get search :query)))
    (harness-then
     (harness-tasks-search--find-sessions query search harness-tasks-search--max-nearest)
     (lambda (found)
       (let ((sessions (delq nil (mapcar (lambda (s)
                                           (let ((id (plist-get s :id)))
                                             (and (not (equal id (plist-get search :exclude)))
                                                  (harness-tasks-search--session-entry id search))))
                                         (seq-take (cdr found) harness-tasks-search--max-nearest))))
             (commands (seq-take (harness-tasks-search--rank-commands (plist-get search :catalogue) query)
                                 harness-tasks-search--max-nearest)))
         (list :sessions sessions :commands commands :widened t
               :note (if (or sessions commands)
                         "Nothing matched exactly; these come nearest."
                       "Nothing matched: no task, session or command.")))))))

(defun harness-tasks-search--count (n word)
  "N WORDs, in words: \"1 task\", \"2 tasks\"."
  (format "%d %s%s" n word (if (= n 1) "" "s")))

(defun harness-tasks-search--search (cwd query opts)
  "Run the search of QUERY typed at CWD; return a promise of its plan.
OPTS are what `search/ask' takes, and the plan what it returns."
  (condition-case err
      (let* ((cwd (file-name-as-directory (expand-file-name cwd)))
             (root (harness-tasks-search--root cwd))
             (model (or (harness-tasks-search--model cwd) (error "No model to search with")))
             (context (let ((context (plist-get opts :context))) (and (keywordp (car-safe context)) context)))
             (bias (harness-tasks-search--bias (plist-get opts :bias) context))
             (no-board (not (harness-method-exists-p 'task/list)))
             ;; Oldest first.
             (board (and (not no-board) (harness-call 'task/list cwd)))
             (tasks (reverse (last board (if (equal bias "tasks")
                                             harness-tasks-search--max-tasks
                                           harness-tasks-search--max-tasks-elsewhere))))
             (shown (delq nil (mapcar (lambda (ref) (harness-tasks-search--resolve ref tasks))
                                      (harness-tasks-search--list (plist-get opts :shown)))))
             (query (string-trim query))
             (widen (if (plist-member opts :widen) (harness-json-true-p (plist-get opts :widen)) t))
             (state (list :root root :model model :query query :bias bias :context context
                          :exclude (harness-tasks-search--field context :session)
                          :tasks tasks :board (harness-tasks-search--by-session board)
                          :sessions (harness-tasks-search--all-sessions)
                          :catalogue (harness-tasks-search--catalogue (plist-get opts :commands))
                          :found (make-hash-table :test 'equal)
                          :projects (make-hash-table :test 'equal)))
             (first (list (harness-tasks-search--user
                           (harness-tasks-search--text
                            root tasks query shown
                            (harness-tasks-search--context-line context bias root)
                            (list (harness-tasks-search--sessions-block state)
                                  (harness-tasks-search--commands-block state))
                            no-board))))
             ;; Taken last, so that nothing fails between taking the
             ;; process and the search's closing it.
             (search (append (list :session (harness-tasks-search--take-session root model)) state))
             (start (float-time))
             (looked nil)
             (finish
              (lambda (answer)
                (let ((plan (harness-tasks-search--plan answer tasks search)))
                  (harness-then
                   (if (and widen (harness-tasks-search--empty-p plan))
                       ;; Nothing: what comes nearest, rather than no answer.
                       (harness-then (harness-tasks-search--nearest search)
                                     (lambda (nearest) (harness-plist-merge plan nearest)))
                     (harness-resolved (append plan (list :widened :false))))
                   (lambda (plan)
                     (harness-log 'info "search %S, favouring %s: %s, %s, %s, %s%s (%s, %.1fs)"
                                  query bias
                                  (harness-tasks-search--count (length (plist-get plan :ids)) "task")
                                  (harness-tasks-search--count (length (plist-get plan :sessions)) "session")
                                  (harness-tasks-search--count (length (plist-get plan :commands)) "command")
                                  (harness-tasks-search--count (length (plist-get plan :actions)) "action")
                                  (if (eq t (plist-get plan :widened)) ", widened" "")
                                  model (- (float-time) start))
                     (append (list :query query :model model :bias bias :looked looked) plan))))))
             (promise
              (harness-then
               (harness-tasks-search--ask search first)
               (lambda (reply)
                 (let* ((answer (harness-tasks-search--json reply))
                        (wants (and answer (harness-tasks-search--wants answer tasks search))))
                   (cond
                    ((null answer) (harness-tasks-search--no-answer reply))
                    ((not wants) (funcall finish answer))
                    (t
                     (setq looked (harness-tasks-search--looked wants))
                     (harness-then
                      (harness-tasks-search--look wants tasks search)
                      (lambda (found)
                        (harness-then
                         (harness-tasks-search--ask
                          search (append first (list (list :role 'assistant
                                                           :content (list (list :type "text" :text reply)))
                                                     (harness-tasks-search--user found))))
                         (lambda (again)
                           (let ((answer (harness-tasks-search--json again)))
                             (cond
                              ((null answer) (harness-tasks-search--no-answer again))
                              ;; It looks further once only.
                              ((harness-tasks-search--wants answer tasks search)
                               (harness-rejected (list 'error "The model asked to look further again instead of answering")))
                              (t (funcall finish answer)))))))))))))))
        ;; Every search has a process of its own: it goes with the search.
        (harness-then promise
                      (lambda (plan)
                        (harness-call 'provider/close model (plist-get search :session))
                        plan)
                      (lambda (e)
                        (harness-call 'provider/close model (plist-get search :session))
                        (harness-log 'warn "search %S failed: %s" query (harness-error-message e))
                        (harness-rejected e))))
    (error (harness-rejected err))))

(harness-defmethod search/ask (cwd query &optional opts)
  "Ask the search model about QUERY, typed anywhere in the harness at CWD.
Return a promise of the plan: (:query QUERY :model MODEL :bias BIAS
:looked LOOKED :note NOTE :widened WIDENED :ids IDS :actions ACTIONS
:tasks TASKS :sessions SESSIONS :commands COMMANDS).  Nothing changes
yet.

IDS and ACTIONS are what `task/search' says of CWD's board: the tasks
QUERY is about, best match first, and the actions it orders, which
`task/search-apply' runs.  TASKS are those tasks again, each (:id
:title :status :session), for a view without the board.  SESSIONS
are the sessions, of any project, QUERY is about, best first, each
\(:id :name :kind :status :project :cwd :updated :snippet :task):
`:project' its project's name, `:snippet' a passage a look found in it
or nil, `:task' the task of the board it works on or nil.  COMMANDS are
the entries of OPTS `:commands' that do what QUERY asks, best first.
BIAS is what the search favoured.  LOOKED says what the model looked
at besides what it was given, when it did.  NOTE is the model's word on
its answer (\"No task matched; these sessions mention it.\"), else nil.
WIDENED is t when the model answered with nothing and the search added
the sessions and commands that come nearest QUERY itself, NOTE saying
so; else false.

The model is `harness-tasks-search-model'.  It reads the board's
tasks, the other sessions and the commands, and answers in JSON, at
most once after looking further: into the tasks' transcripts, every
session's (`session/search' where it is loaded, their names otherwise)
or the commands.  OPTS:
  :bias      what to favour: \"tasks\", \"sessions\" or \"commands\";
             by default what the view of `:context' suggests: tasks on
             the board, sessions in the session list or a conversation
             tree, commands anywhere else
  :context   where QUERY was typed: (:view VIEW :title TITLE :mode
             MODE :session ID :project PROJECT), VIEW being \"board\",
             \"chat\", \"sessions\", \"tree\" or another for any other
             buffer, TITLE and MODE that buffer's, ID the session the
             engineer is in, which the answer leaves out
  :shown     the ids the board shows now, which \"them\" in QUERY means
  :commands  the commands the model may name, the UI's catalogue: each
             (:command NAME :keys KEYS :where WHERE :label LABEL :doc
             DOC :here HERE), HERE true when it runs where QUERY was
             typed
  :widen     false keeps the search from adding what comes nearest
             when the model finds nothing; true by default"
  (if (or (not (stringp query)) (string-blank-p query))
      (harness-rejected (list 'error "Nothing to search for"))
    (harness-tasks-search--search cwd query opts)))

(defun harness-tasks-search--board-opts (opts)
  "OPTS of `task/search' as `search/ask' takes them.
The search favours tasks, is seen from the board and never widens by
itself."
  (let ((context (let ((context (plist-get opts :context))) (and (keywordp (car-safe context)) context))))
    (append (list :bias "tasks" :widen :false
                  :context (append (list :view "board") (harness-plist-remove context :view)))
            (harness-plist-remove opts :bias :widen :context))))

(harness-defmethod task/search (cwd query &optional opts)
  "Ask the search model about QUERY on the task board of CWD's project.
Return a promise of the plan: (:query QUERY :ids IDS :actions ACTIONS
:model MODEL :looked LOOKED), with what `search/ask' adds.  Nothing
changes yet.

IDS are the tasks QUERY is about, best match first, archived ones
included: the board shows only those.  ACTIONS are what QUERY orders,
in order, each (:task ID :action NAME :text TEXT :title TITLE :confirm
BOOL), NAME being one of `harness-tasks-search-actions' and TEXT the
words a message or a send-back carries, or the priority a priority
action gives (low, medium or high); `:confirm' is t for an action
that waits for the user's OK (see `harness-tasks-search--confirm-actions'),
else false.  `task/search-apply' runs them.  LOOKED says what the model
looked at besides the board, when it did.

The model is `harness-tasks-search-model'; it reads a dump of the board
and answers in JSON, at most once after looking further.  OPTS:
`:shown', the ids the board shows now, which \"them\" in QUERY means,
and `:commands', as `search/ask' takes them.  This is `search/ask'
favouring tasks, seen from the board, that never widens by itself: what
it finds is what the model answers."
  (cond
   ((or (not (stringp query)) (string-blank-p query)) (harness-rejected (list 'error "Nothing to search for")))
   ((not (harness-method-exists-p 'task/list))
    (harness-rejected (list 'error "Task mode (the tasks module) is not loaded")))
   (t (harness-tasks-search--search cwd query (harness-tasks-search--board-opts opts)))))

;;;; Acting

(defun harness-tasks-search--when-stopped (id then)
  "Return a promise of THEN's value, called once task ID has stopped working.
It fails when the task still works after `harness-tasks-search--stop-wait'
seconds."
  (harness-with-promise (resolve reject)
    (let ((deadline (+ (float-time) harness-tasks-search--stop-wait))
          (timer nil))
      (setq timer
            (run-at-time 0.2 0.2
                         (lambda ()
                           (let ((task (ignore-errors (harness-call 'task/get id))))
                             (cond
                              ((null task) (cancel-timer timer) (funcall reject (list 'error "The task is gone")))
                              ((not (harness-tasks-search--working-p task))
                               (cancel-timer timer)
                               (condition-case err (funcall resolve (funcall then))
                                 (error (funcall reject err))))
                              ((> (float-time) deadline)
                               (cancel-timer timer)
                               (funcall reject (list 'error "It did not stop in time")))))))))))

(defun harness-tasks-search--archive (id)
  "Archive task ID; one at work is stopped first, then archived once it stops.
Return the task, or a promise of it."
  (let ((task (harness-call 'task/get id)))
    (if (not (harness-tasks-search--working-p task))
        (harness-call 'task/archive id)
      (harness-call 'task/cancel id)
      (harness-tasks-search--when-stopped id (lambda () (harness-call 'task/archive id))))))

(defun harness-tasks-search--stop (id)
  "Stop task ID's turn, which must be at work.
Never `task/cancel' on a task that is not at work: that drops a pending one."
  (unless (harness-tasks-search--working-p (harness-call 'task/get id))
    (error "It is not working"))
  (harness-call 'task/cancel id))

(defun harness-tasks-search--message (id text)
  "Send TEXT to task ID's session; a task waiting for a slot gets it in its prompt."
  (when (harness-string-blank-p text) (error "A message needs words"))
  (let ((task (harness-call 'task/get id)))
    (if (and (equal (harness-tasks-search--str (plist-get task :state)) "pending")
             (not (harness-json-true-p (plist-get task :backlog))))
        (harness-call 'task/update id (concat (plist-get task :prompt) "\n\n" text) (plist-get task :attachments))
      (harness-call 'task/prompt id text))))

(defun harness-tasks-search--run (action)
  "Run ACTION, as `task/search' proposes it; return a promise of how it went.
That is ACTION's `:task' and `:action' with `:ok' t, or false and
`:error' the reason, `:title' the task's title, and `:undo' the action
that undoes it, when there is one; a priority action's `:text' is the
priority it gives.  The promise never rejects."
  (let* ((id (plist-get action :task))
         (name (harness-tasks-search--action-name (plist-get action :action)))
         (text (plist-get action :text))
         (task (ignore-errors (harness-call 'task/get id)))
         (title (or (and task (ignore-errors (harness-tasks-search--title task))) (plist-get action :title)))
         ;; The priority to go back to, for undo.
         (was (and task (harness-tasks-search--priority (plist-get task :priority))))
         (priority (and (equal name "priority") (harness-tasks-search--priority text)))
         (result (append (list :task id :action (or name (harness-tasks-search--str (plist-get action :action)))
                               :title title)
                         (and (equal name "priority") (list :text (or priority text))))))
    (harness-then
     (condition-case err
         (harness-as-promise
          (pcase name
            ("archive" (harness-tasks-search--archive id))
            ("restore" (harness-call 'task/archive id t))
            ("stop" (harness-tasks-search--stop id))
            ("retry" (harness-call 'task/retry id))
            ("start" (harness-call 'task/start id))
            ("verify" (harness-call 'task/verify id))
            ("complete" (harness-call 'task/complete id))
            ("message" (harness-tasks-search--message id text))
            ("reject" (harness-call 'task/reject id text))
            ;; A priority is its session's (the task has one from
            ;; submission); never nothing for medium, which the level
            ;; list does not count as one.
            ("priority" (harness-call 'priority/set (plist-get task :session)
                                      (or priority (error "Unknown priority %s; it is low, medium or high"
                                                          (or text "(none)")))))
            (_ (error "Unknown action %s" (plist-get action :action)))))
       (error (harness-rejected err)))
     (lambda (_)
       (append result (list :ok t)
               (pcase name
                 ("archive" (list :undo (list :task id :action "restore")))
                 ("restore" (list :undo (list :task id :action "archive")))
                 ("priority" (and was (not (equal was priority))
                                  (list :undo (list :task id :action "priority" :text was)))))))
     (lambda (e)
       (append result (list :ok :false :error (harness-tasks-search--clean-error e)))))))

(defun harness-tasks-search--clean-error (err)
  "The message of ERR as the end of a sentence about a task.
\"Task t-1234 is working already\" reads \"it is working already\", so a
board can say \"Could not retry “Fix X”: it is working already\"."
  (let ((msg (string-trim (harness-error-message err))))
    (cond ((string-match "\\`Task t-[[:alnum:]]+ \\(\\(?:.\\|\n\\)*\\)\\'" msg) (concat "it " (match-string 1 msg)))
          ((string-empty-p msg) "it failed")
          (t (concat (downcase (substring msg 0 1)) (substring msg 1))))))

(harness-defmethod task/search-apply (actions)
  "Run ACTIONS, as `task/search' proposed them, one after the other.
Return a promise of how each went: its `:task' and `:action', `:ok' t
or false with `:error', its `:title', and `:undo', the action that
undoes it when there is one (restore for archive and back, the
priority it had for priority).  The actions mean what a search's model
was told: archive stops a task at work first and archives it once
stopped, stop never drops a pending task, retry is `task/retry',
message is a follow-up to the session (or words added to the prompt of
a backlog task still being written up), priority is `priority/set' on
the task's session, which is where a task's priority lives."
  (let ((results nil)
        (chain (harness-resolved nil)))
    (dolist (action actions)
      (setq chain (harness-then chain
                                (lambda (_)
                                  (harness-then (harness-tasks-search--run action)
                                                (lambda (result) (push result results) nil))))))
    (harness-then chain (lambda (_) (nreverse results)))))

;;;; Module

(defun harness-tasks-search--shutdown ()
  "Close the processes warmed for searches that never came."
  (dolist (root (hash-table-keys harness-tasks-search--warm))
    (ignore-errors (harness-tasks-search--drop-warm root))))

(harness-define-module 'tasks-search
  :doc "Search the harness with a cheap model, in JSON only: tasks and actions on them, sessions and commands."
  :requires '(tasks provider)
  :shutdown #'harness-tasks-search--shutdown)

(provide 'harness-tasks-search)
;;; harness-tasks-search.el ends here
