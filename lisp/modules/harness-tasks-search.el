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
;; sessions whose transcripts mention a text (grep over their logs), or
;; the latest transcript of up to three tasks; then it must answer.
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
  "You are the search box of a task board in a coding harness. Each task is one AI agent session working on one change to a software project. The engineer types a query: a question about the tasks, or an order to manage some. You get the board as data. Answer with exactly one line of JSON and nothing else: no prose, no markdown, no code fence.

{\"show\":[\"TASK-ID\",...],\"do\":[{\"task\":\"TASK-ID\",\"action\":\"ACTION\",\"text\":\"...\"}]}

\"show\" lists the tasks the query is about, best match first, or [] when none fits. A question (\"did I have a task about X?\", \"what is working on Y?\", \"which ones failed?\") shows the tasks that answer it. An order shows the tasks it acts on.

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

Match loosely: words in any order, abbreviations (mq = merge queue), typos, synonyms; titles, requests, todos, summaries and branches all count. \"Errored\", \"failed\" or \"broken\" tasks are those whose state says error or failed. \"Them\", \"those\" and \"these\" are the tasks shown on the board now. Act only on tasks the query clearly means; when unsure, show them and do nothing.

Most queries need nothing but the board. Only when it really does not say enough, you may ask once to look further instead of answering: {\"grep\":\"TEXT\"} finds the tasks whose session transcripts mention TEXT; {\"read\":[\"TASK-ID\",...]} gives the latest transcript of up to 3 tasks. Then you answer."
  "System prompt of a search's model.
It never changes, so a model process started ahead for a search
\(`task/search-warm') has the settings the search comes with.")

(defconst harness-tasks-search--final-text
  "That is all there is to look at. Now answer the query with one line of JSON: {\"show\":[...],\"do\":[...]}."
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

(defun harness-tasks-search--board-text (root tasks query shown)
  "The message that gives the model the board of ROOT, its TASKS, and QUERY.
TASKS come newest first; SHOWN lists the ids the board shows now, when
it shows only some."
  (concat
   (format "Project: %s. Now: %s.\n" (harness-tasks-search--project-name root)
           (format-time-string "%A %Y-%m-%d %H:%M"))
   (if tasks
       (format "%d task%s, newest first. Archived ones are off the board but still count.\n"
               (length tasks) (if (= 1 (length tasks)) "" "s"))
     "The board has no tasks.\n")
   (if shown (format "Shown on the board now: %s.\n" (string-join shown ", ")) "")
   "\n"
   (mapconcat #'harness-tasks-search--entry tasks "\n")
   (format "\n\nQuery: %s\n\nAnswer with one line of JSON." (string-trim query))))

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

(defun harness-tasks-search--plan (answer tasks)
  "Return (:ids IDS :actions ACTIONS) from the model's ANSWER about TASKS.
IDS are the tasks to show, best match first; every task an action is
for is among them.  Ids that name no task of the board are dropped."
  (let ((ids (delete-dups (delq nil (mapcar (lambda (ref) (harness-tasks-search--resolve ref tasks))
                                            (harness-tasks-search--list (plist-get answer :show))))))
        (actions (delq nil (mapcar (lambda (entry) (harness-tasks-search--action entry tasks))
                                   (harness-tasks-search--list
                                    (or (plist-get answer :do) (plist-get answer :actions)))))))
    (dolist (action actions)
      (unless (member (plist-get action :task) ids)
        (setq ids (append ids (list (plist-get action :task))))))
    (list :ids ids :actions actions)))

;;;; Looking further

(defun harness-tasks-search--wants (answer tasks)
  "Return what ANSWER asks to look at before it answers, or nil.
That is (:grep TEXT :read IDS), from an answer that shows and does
nothing; IDS name tasks of TASKS, at most
`harness-tasks-search--read-limit' of them."
  (let ((grep (let ((g (plist-get answer :grep))) (and (stringp g) (not (harness-string-blank-p g)) (string-trim g))))
        (read (seq-take (delete-dups (delq nil (mapcar (lambda (ref) (harness-tasks-search--resolve ref tasks))
                                                       (harness-tasks-search--list (plist-get answer :read)))))
                        harness-tasks-search--read-limit)))
    (when (and (or grep read)
               (null (harness-tasks-search--list (plist-get answer :show)))
               (null (harness-tasks-search--list (or (plist-get answer :do) (plist-get answer :actions)))))
      (list :grep grep :read read))))

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

(defun harness-tasks-search--grep (needle tasks)
  "Return a promise of the text saying which of TASKS' transcripts mention NEEDLE.
The node logs are searched by `harness-tasks-search--grep-program', in a
process: transcripts are never loaded just to be searched."
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

(defun harness-tasks-search--look (wants tasks)
  "Return a promise of the text of what WANTS asked to see of TASKS."
  (let ((reads (mapcar (lambda (id)
                         (harness-tasks-search--read
                          (cl-find id tasks :key (lambda (task) (plist-get task :id)) :test #'equal)))
                       (plist-get wants :read))))
    (harness-then (if (plist-get wants :grep)
                      (harness-tasks-search--grep (plist-get wants :grep) tasks)
                    (harness-resolved nil))
                  (lambda (found)
                    (concat "Here is what you asked to see.\n\n"
                            (string-join (delq nil (append (list found) reads)) "\n\n")
                            "\n\n" harness-tasks-search--final-text)))))

(defun harness-tasks-search--looked (wants)
  "Say in a few words what WANTS looked at, for the board."
  (string-join (delq nil (list (and (plist-get wants :grep)
                                    (format "searched the transcripts for %S" (plist-get wants :grep)))
                               (and (plist-get wants :read)
                                    (let ((n (length (plist-get wants :read))))
                                      (format "read %d transcript%s" n (if (= n 1) "" "s"))))))
               " and "))

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

(harness-defmethod task/search (cwd query &optional opts)
  "Ask the search model about QUERY on the task board of CWD's project.
Return a promise of the plan: (:query QUERY :ids IDS :actions ACTIONS
:model MODEL :looked LOOKED).  Nothing changes yet.

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
`:shown', the ids the board shows now, which \"them\" in QUERY means."
  (cond
   ((harness-string-blank-p query) (harness-rejected (list 'error "Nothing to search for")))
   ((not (harness-method-exists-p 'task/list))
    (harness-rejected (list 'error "Task mode (the tasks module) is not loaded")))
   (t
    (condition-case err
        (let* ((cwd (file-name-as-directory (expand-file-name cwd)))
               (root (harness-tasks-search--root cwd))
               (model (or (harness-tasks-search--model cwd) (error "No model to search with")))
               (tasks (harness-tasks-search--board cwd))
               (shown (delq nil (mapcar (lambda (ref) (harness-tasks-search--resolve ref tasks))
                                        (harness-tasks-search--list (plist-get opts :shown)))))
               (query (string-trim query))
               (search (list :root root :model model :query query
                             :session (harness-tasks-search--take-session root model)))
               (start (float-time))
               (first (list (harness-tasks-search--user
                             (harness-tasks-search--board-text root tasks query shown))))
               (looked nil)
               (finish (lambda (answer)
                         (let ((plan (harness-tasks-search--plan answer tasks)))
                           (harness-log 'info "task search %S: %d shown, %d action%s (%s, %.1fs)"
                                        query (length (plist-get plan :ids)) (length (plist-get plan :actions))
                                        (if (= 1 (length (plist-get plan :actions))) "" "s")
                                        model (- (float-time) start))
                           (append (list :query query :model model :looked looked) plan))))
               (promise
                (harness-then
                 (harness-tasks-search--ask search first)
                 (lambda (reply)
                   (let* ((answer (harness-tasks-search--json reply))
                          (wants (and answer (harness-tasks-search--wants answer tasks))))
                     (cond
                      ((null answer) (harness-tasks-search--no-answer reply))
                      ((not wants) (funcall finish answer))
                      (t
                       (setq looked (harness-tasks-search--looked wants))
                       (harness-then
                        (harness-tasks-search--look wants tasks)
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
                                ((harness-tasks-search--wants answer tasks)
                                 (harness-rejected (list 'error "The model asked to look further again instead of answering")))
                                (t (funcall finish answer)))))))))))))))
          ;; Every search has a process of its own: it goes with the search.
          (harness-then promise
                        (lambda (plan)
                          (harness-call 'provider/close model (plist-get search :session))
                          plan)
                        (lambda (e)
                          (harness-call 'provider/close model (plist-get search :session))
                          (harness-log 'warn "task search %S failed: %s" query (harness-error-message e))
                          (harness-rejected e))))
      (error (harness-rejected err))))))

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
  :doc "The task board's search: a cheap model finds tasks and proposes actions on them, in JSON only."
  :requires '(tasks provider)
  :shutdown #'harness-tasks-search--shutdown)

(provide 'harness-tasks-search)
;;; harness-tasks-search.el ends here
