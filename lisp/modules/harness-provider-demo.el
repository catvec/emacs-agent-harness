;;; harness-provider-demo.el --- Scripted provider for demos and tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; A provider that never talks to a network.  It replays a script of
;; events with small delays so streaming, tool calls, permissions and
;; markdown rendering can be exercised in a live Emacs without cost.
;; The script is chosen from the last user message:
;;
;;   "tour"        thinking, text, a read_file call, markdown
;;   "tools"       two coalescable tool calls, then a bash call
;;   "work"        a todo list worked through with tool calls (task mode);
;;                 in a worktree it also writes and commits notes/ID.md
;;   "ask"         calls ask_user
;;   "diagram"     calls ask_user with an ASCII diagram for each option
;;   "debug"       describes find-file in the user's Emacs, finds its
;;                 definition and traces find-file-noselect
;;   "status"      looks at the task board with task_list (a BTW over it)
;;   anything else echo the prompt back as markdown
;;
;; A session writing a backlog task up (the system prompt has the task
;; refinement section) instead looks at the board with task_list, takes
;; a quick look at the project and writes it up -- or, when another task
;; on the board asks for it in the same words, refuses it as a duplicate.
;; A task board's search gets the JSON a search model answers with,
;; matched from the words of the query (`harness-provider-demo--search'),
;; and a request to name a session the first words of its opening
;; message (`harness-provider-demo--title').  The companion pet gets
;; its name and its lines (`harness-provider-demo--pet'), and the
;; Insights report a summary of its figures
;; (`harness-provider-demo--insights').

;;; Code:

(require 'cl-lib)
(require 'harness-core)
(require 'harness-util)
(require 'harness-provider)

(defconst harness-provider-demo--delay 0.03
  "Seconds between scripted events.")

(defvar harness-provider-demo-script-override nil
  "When non-nil, the events used instead of the built-in scripts.
A list of events, or a function of the request returning one: a test
that needs a reply per request (a search that looks further, then
answers) gives a function.")

(defconst harness-provider-demo--layouts
  '(("Sidebar on the left"
     . "+----------+---------------------------+
| Settings |  General                  |
|----------|                           |
| General  |  Name    [_____________]  |
| Account  |  Theme   [Dark        v]  |
| Privacy  |                           |
|          |               [ Save ]    |
+----------+---------------------------+")
    ("Sidebar on the right"
     . "+---------------------------+----------+
|  General                  | Settings |
|                           |----------|
|  Name    [_____________]  | General  |
|  Theme   [Dark        v]  | Account  |
|                           | Privacy  |
|               [ Save ]    |          |
+---------------------------+----------+")
    ("Tabs across the top"
     . "+--------------------------------------+
| [General]   Account   Privacy        |
|--------------------------------------|
|  Name    [_____________]             |
|  Theme   [Dark        v]             |
|                                      |
|               [ Save ]               |
+--------------------------------------+"))
  "Options of the demo `diagram' question: (LABEL . ASCII-DIAGRAM).")

(defun harness-provider-demo--last-user-text (request)
  "Return the text of the last text block of REQUEST's user messages.
Not an image's token, [image 1], which the agent puts before each
labelled image (`harness-agent--prepare-content'): that is no text the
user wrote."
  (let ((msgs (plist-get request :messages)) text)
    (dolist (m msgs)
      (when (equal (plist-get m :role) 'user)
        (dolist (b (plist-get m :content))
          (when (and (equal (plist-get b :type) "text")
                     (not (string-match-p "\\`\\[image [0-9]+\\]\\'" (or (plist-get b :text) ""))))
            (setq text (plist-get b :text))))))
    (or text "")))

(defun harness-provider-demo--script (request)
  (let ((text (downcase (harness-provider-demo--last-user-text request)))
        (cwd (or (plist-get (plist-get request :session) :cwd) default-directory)))
    (cond
     ((functionp harness-provider-demo-script-override)
      (funcall harness-provider-demo-script-override request))
     (harness-provider-demo-script-override harness-provider-demo-script-override)
     ((string-prefix-p "You write short titles" (or (plist-get request :system) ""))
      (harness-provider-demo--title request))
     ((string-match-p "^## Task refinement" (or (plist-get request :system) ""))
      (harness-provider-demo--write-up request cwd))
     ((string-prefix-p "You are the search box of a task board" (or (plist-get request :system) ""))
      (harness-provider-demo--search request))
     ((string-match-p "\\`You \\(?:name newly hatched\\|are a\\) coding companion" (or (plist-get request :system) ""))
      (harness-provider-demo--pet request))
     ((string-prefix-p "You write the Insights report" (or (plist-get request :system) ""))
      (harness-provider-demo--insights request))
     ((string-match-p "\\btour\\b" text)
      `((:type thinking :delta "The user wants a tour. ")
        (:type thinking :delta "I will read a file, then summarise.")
        (:type text :delta "Let me look at the project first.\n")
        (:type tool-call :id "demo-1" :name "list_dir" :input (:path ,cwd))
        (:type text :delta "# Tour\n\nThis session runs the **demo** provider. It streams *markdown*, `code`, and tool calls.\n\n")
        (:type text :delta "- streamed text\n- a tool call above\n- a fenced block below\n\n```emacs-lisp\n(defun hello ()\n  (message \"hi\"))\n```\n\n> Quotes render too.\n")
        (:type usage :input 1200 :output 180 :cache-read 800 :cache-write 0 :cost 0.0042 :context 2000)
        (:type done :stop-reason end-turn)))
     ((string-match-p "\\btools\\b" text)
      `((:type text :delta "Running a few tools.\n")
        (:type tool-call :id "demo-a" :name "glob" :input (:pattern "*.el" :path ,cwd))
        (:type tool-call :id "demo-b" :name "grep" :input (:pattern "defun" :path ,cwd))
        (:type tool-call :id "demo-c" :name "bash" :input (:command "echo hello from bash"))
        (:type text :delta "Done.")
        (:type usage :input 900 :output 60 :cache-read 0 :cache-write 900 :cost 0.003 :context 1500)
        (:type done :stop-reason end-turn)))
     ((string-match-p "\\bwork\\b" text)
      (let ((todos (lambda (&rest statuses)
                     (list :todos (cl-mapcar (lambda (id label status) (list :id id :text label :status status))
                                             '("1" "2" "3")
                                             '("Survey the project" "Make the change" "Check the result")
                                             statuses)))))
        `((:type thinking :delta "A task. I will plan it as todos and work through them.")
          (:type tool-call :id "demo-w1" :name "todo_write" :input ,(funcall todos "in-progress" "pending" "pending"))
          (:type tool-call :id "demo-w2" :name "list_dir" :input (:path ,cwd))
          (:type tool-call :id "demo-w3" :name "todo_write" :input ,(funcall todos "done" "in-progress" "pending"))
          (:type text :delta "Making the change.\n")
          (:type tool-call :id "demo-w4" :name "glob" :input (:pattern "*.el" :path ,cwd))
          ;; In a task's worktree, make and commit a real change, as the task prompt asks.
          ,@(when-let* ((session (plist-get request :session))
                        ((plist-get session :worktree))
                        (name (format "notes/%s.md" (substring (plist-get session :id) 0 8))))
              `((:type tool-call :id "demo-w4a" :name "write_file"
                       :input (:path ,(expand-file-name name cwd) :content ,(format "# %s\n\nDone by the demo agent.\n" text)))
                (:type tool-call :id "demo-w4b" :name "bash"
                       :input (:command ,(format "git add -A && git -c user.name=Demo -c user.email=demo@example.invalid commit -q --no-gpg-sign -m 'Add %s'" name)))))
          (:type tool-call :id "demo-w5" :name "todo_write" :input ,(funcall todos "done" "done" "in-progress"))
          (:type tool-call :id "demo-w6" :name "grep" :input (:pattern "defun" :path ,cwd))
          (:type tool-call :id "demo-w7" :name "todo_write" :input ,(funcall todos "done" "done" "done"))
          (:type text :delta "Done: surveyed the project, made the change and checked it.")
          (:type usage :input 2400 :output 220 :cache-read 1800 :cost 0.006 :context 2600)
          (:type done :stop-reason end-turn))))
     ((string-match-p "\\bdebug\\b" text)
      `((:type text :delta "Let me see what `find-file` is in your Emacs, and where it is defined.\n")
        (:type tool-call :id "demo-g1" :name "emacs_describe" :input (:symbol "find-file"))
        (:type tool-call :id "demo-g2" :name "emacs_find_definition" :input (:symbol "find-file"))
        (:type text :delta "Now I will trace `find-file-noselect`, which it calls.\n")
        (:type tool-call :id "demo-g3" :name "emacs_trace"
               :input (:symbol "find-file-noselect" :callers 2 :limit 20))
        (:type text :delta "Open a file with `C-x C-f`: each call is recorded in `*trace-output*`, with the functions that led to it.")
        (:type usage :input 1100 :output 90 :cost 0.0021 :context 1400)
        (:type done :stop-reason end-turn)))
     ((string-match-p "\\bdiagrams?\\b" text)
      `((:type text :delta "A few layouts would work; have a look at each.\n")
        (:type tool-call :id "demo-d" :name "ask_user"
               :input (:question "Which layout should the settings page use?"
                       :options ,(mapcar (lambda (layout) (list :label (car layout) :diagram (cdr layout)))
                                         harness-provider-demo--layouts)))
        (:type text :delta "Thanks, noted.")
        (:type usage :input 700 :output 160 :cost 0.0015 :context 900)
        (:type done :stop-reason end-turn)))
     ((string-match-p "\\bask\\b" text)
      `((:type text :delta "I need to check something with you.\n")
        (:type tool-call :id "demo-q" :name "ask_user" :input (:question "Which colour?" :options ("red" "green" "blue")))
        (:type text :delta "Thanks, noted.")
        (:type usage :input 500 :output 40 :cost 0.001 :context 600)
        (:type done :stop-reason end-turn)))
     ((string-match-p "\\bstatus\\b" text)
      `((:type text :delta "Let me look at the board.\n")
        (:type tool-call :id "demo-s1" :name "task_list" :input nil)
        (:type text :delta "Those are the tasks on the board, each with its column and state. Ask about one and I will read its session.")
        (:type usage :input 700 :output 45 :cost 0.0012 :context 900)
        (:type done :stop-reason end-turn)))
     (t
      `((:type text :delta ,(format "You said: *%s*\n\nThis is the demo provider; try `tour`, `tools`, `ask`, `diagram` or `debug`." text))
        (:type usage :input 400 :output 30 :cost 0.0008 :context 450)
        (:type done :stop-reason end-turn))))))

(defun harness-provider-demo--title (request)
  "Answer the naming REQUEST as a model would: the gist of the opening message.
That message is REQUEST's first user text, quoted between message tags
when the session is named from its first message (see `naming/name').
The title is the first words of its first clause, capitalised."
  (let* ((first (or (cl-loop for m in (plist-get request :messages)
                             when (eq (plist-get m :role) 'user)
                             thereis (cl-loop for b in (plist-get m :content)
                                              when (equal (plist-get b :type) "text")
                                              return (plist-get b :text)))
                    ""))
         (opening (if (string-match "<message>\n\\(\\(?:.\\|\n\\)*?\\)\n</message>" first)
                      (match-string 1 first)
                    first))
         (clause (car (split-string (harness-first-line opening)
                                    "[,;:!?]\\|\\.\\(?:[[:space:]]\\|\\'\\)" t "[[:space:]]+")))
         (words (take 6 (split-string (or clause "") "[[:space:]]+" t)))
         (title (if words (string-join words " ") "Demo conversation")))
    `((:type text :delta ,(concat (upcase (substring title 0 1)) (substring title 1)))
      (:type usage :input 80 :output 8 :cost 0.0001)
      (:type done :stop-reason end-turn))))

(defun harness-provider-demo--same-task (request note)
  "Return another task on the board that asks for NOTE in the same words.
That is a task of REQUEST's project, other than the one REQUEST's
session writes up, whose request or prompt is NOTE, ignoring case and
spacing; nil when there is none, or no task board."
  (when (harness-method-exists-p 'task/list)
    (let* ((session (plist-get request :session))
           (words (lambda (s) (downcase (string-join (split-string (or s "")) " "))))
           (key (funcall words note)))
      (cl-find-if (lambda (task)
                    (and (not (equal (plist-get task :session) (plist-get session :id)))
                         (or (equal key (funcall words (plist-get task :note)))
                             (equal key (funcall words (plist-get task :prompt))))))
                  (ignore-errors (harness-call 'task/list (or (plist-get session :cwd) default-directory)))))))

(defun harness-provider-demo--write-up (request cwd)
  "Return the script that writes a backlog task up for REQUEST in CWD.
It looks at the board first, as the refinement prompt asks.  The title
comes from the first message, the note it is written from; a later
message is feedback and lands under Also.  A note another task on the
board has in the same words is refused as a duplicate of it, the first
time."
  (let* ((texts (cl-loop for m in (plist-get request :messages)
                         when (eq (plist-get m :role) 'user)
                         append (cl-loop for b in (plist-get m :content)
                                         when (equal (plist-get b :type) "text") collect (plist-get b :text))))
         (note (string-trim (or (car texts) "the task")))
         (feedback (and (cdr texts) (string-trim (car (last texts)))))
         (title (let ((line (car (split-string note "\n" t))))
                  (concat (upcase (substring line 0 1)) (substring line 1))))
         (same (and (not feedback) (harness-provider-demo--same-task request note)))
         (search '(:type tool-call :id "demo-r0" :name "task_list" :input (:include_archived t :limit 50))))
    (if same
        `((:type thinking :delta "A task for the backlog: first a look at the board for the same one.")
          ,search
          (:type text :delta ,(format "Duplicate of %s\n\nThe board has this already: %s (%s) asks for it in the same words."
                                      (plist-get same :id)
                                      (concat "“" (harness-first-line (plist-get same :prompt) 60) "”")
                                      (plist-get same :column)))
          (:type usage :input 600 :output 40 :cache-read 300 :cost 0.0012 :context 800)
          (:type done :stop-reason end-turn))
      `((:type thinking :delta "A task for the backlog: a look at the board and the project, then the write-up.")
        ,search
        (:type tool-call :id "demo-r1" :name "list_dir" :input (:path ,cwd))
        (:type text :delta ,(concat (truncate-string-to-width title 60) "\n\n"
                                    "**What and why.** " note "\n\n"
                                    "**Change.** The demo provider does not read code; a real agent names the files and functions here.\n\n"
                                    "**Done when.** The behaviour above works and the test suite passes.\n\n"
                                    "**Open questions.** None for the demo."
                                    (if feedback (concat "\n\n**Also.** " feedback) "")))
        (:type usage :input 700 :output 120 :cache-read 300 :cost 0.002 :context 900)
        (:type done :stop-reason end-turn)))))

(defconst harness-provider-demo--pet-lines
  '(("hatched" . "*blinks* Oh. Hello. Is it always this bright in here?")
    ("petted" . "*leans into it* Yes. That. Do that again after the next commit.")
    ("Tests just failed" . "*peers at the red* Somebody's assertion has feelings.")
    ("failed" . "*winces* That one went sideways. I saw nothing.")
    ("big change" . "*whistles* That diff needs its own postcode.")
    ("by name" . "*perks up* You called? I was only pretending to nap.")
    ("grew a level" . "*stretches* I feel taller. Probably am."))
  "The demo pet's line for what happened, by words of the request.")

(defun harness-provider-demo--pet (request)
  "Answer the companion pet's REQUEST, as a scripted cheap model would.
Hatching names it after the first of its inspiration words; otherwise
it says the line of `harness-provider-demo--pet-lines' for what
happened, or remarks on the longest word of the user's last message."
  (let* ((text (harness-provider-demo--last-user-text request))
         (answer
          (if (string-prefix-p "You name" (plist-get request :system))
              (let ((word (if (string-match "^Inspiration words: \\([[:alpha:]]+\\)" text)
                              (match-string 1 text)
                            "pebble"))
                    (species (if (string-match "^Species: \\(.*\\)$" text) (match-string 1 text) "creature")))
                (format "{\"name\":%S,\"personality\":%S}"
                        (capitalize word)
                        (format "%s %s that rates every function by how it would taste, and hums when the tests pass."
                                (if (string-match-p "\\`[aeiou]" species) "An" "A") species)))
            ;; What happened is the first line; the user's last words, the last "user:" line.
            (or (let ((what (car (split-string text "\n"))))
                  (cdr (cl-find-if (lambda (line) (string-search (car line) what)) harness-provider-demo--pet-lines)))
                (let* ((last (car (last (cl-remove-if-not (lambda (line) (string-prefix-p "user: " line))
                                                          (split-string text "\n")))))
                       (said (and last
                                  (car (sort (split-string (substring last 6) "[^[:alnum:]']+" t)
                                             (lambda (a b) (> (length a) (length b))))))))
                  (if said
                      (format "*tilts head* %s? Bold. I like it." (capitalize said))
                    "..."))))))
    `((:type text :delta ,answer)
      (:type usage :input 300 :output 30 :cost 0.0003 :context 330)
      (:type done :stop-reason end-turn))))

(defconst harness-provider-demo--search-verbs
  '(("archive" "get rid of" "archive" "remove" "delete" "hide" "clean up")
    ("retry" "restart" "retry" "rerun" "resume" "unstick")
    ("restore" "restore" "unarchive" "bring back")
    ("stop" "stop" "cancel" "kill")
    ("verify" "verify" "approve" "accept" "ship")
    ("start" "start"))
  "Words that order an action in a search, by action, for the demo's answers.")

(defconst harness-provider-demo--search-states
  '(("error\\|fail\\|stopped" "errored" "failed" "failing" "broken" "stopped")
    ("^needs input" "blocked" "stuck" "waiting" "need me" "needs me")
    ("^review" "review" "to review" "reviewed")
    ("^in progress" "running" "working" "in progress" "active")
    ("^pending" "pending" "queued" "backlog")
    ("^done" "done" "completed" "finished" "merged"))
  "Words of a search that name a state, with the regexp of the states they mean.")

(defconst harness-provider-demo--search-stopwords
  '("a" "an" "the" "task" "tasks" "about" "did" "i" "have" "had" "any" "all" "my" "me" "of" "for"
    "to" "on" "in" "is" "are" "was" "were" "that" "this" "these" "those" "them" "it" "which" "what"
    "show" "find" "where" "with" "and" "or" "one" "ones" "do" "does" "there" "please" "adding" "add")
  "Words a demo search ignores when it matches tasks.")

(defun harness-provider-demo--search (request)
  "Answer a task board search from REQUEST's board, as a scripted model would.
No model: words of the query that order an action pick it, words that
name a state keep the tasks in that state, and the other words keep the
tasks whose lines hold them all (or, when none does, the most of them)."
  (let* ((text (harness-provider-demo--last-user-text request))
         (query (downcase (if (string-match "^Query: \\(.*\\)$" text) (match-string 1 text) "")))
         (entries nil))
    ;; Each task is a line "ID | STATUS | TITLE" and the indented lines after it.
    (dolist (line (split-string text "\n"))
      (cond ((string-match "\\`\\(t-[[:alnum:]]+\\) | \\([^|]*\\) | \\(.*\\)\\'" line)
             (push (list (match-string 1 line) (match-string 2 line) (downcase line)) entries))
            ((and entries (string-prefix-p "  " line))
             (setf (nth 2 (car entries)) (concat (nth 2 (car entries)) " " (downcase line))))))
    (setq entries (nreverse entries))
    (let* ((action (car (cl-find-if (lambda (verbs) (cl-some (lambda (w) (string-match-p (concat "\\b" (regexp-quote w) "\\b") query))
                                                              (cdr verbs)))
                                    harness-provider-demo--search-verbs)))
           (state (car (cl-find-if (lambda (states) (cl-some (lambda (w) (string-match-p (concat "\\b" (regexp-quote w) "\\b") query))
                                                              (cdr states)))
                                   harness-provider-demo--search-states)))
           (noise (append harness-provider-demo--search-stopwords
                          (split-string (string-join (apply #'append (mapcar #'cdr harness-provider-demo--search-verbs)) " "))
                          (split-string (string-join (apply #'append (mapcar #'cdr harness-provider-demo--search-states)) " "))))
           (words (cl-remove-if (lambda (w) (or (< (length w) 2) (member w noise)))
                                (split-string query "[^[:alnum:]]+" t)))
           (in-state (if state
                         (cl-remove-if-not (lambda (e) (string-match-p state (nth 1 e))) entries)
                       entries))
           (scored (mapcar (lambda (e) (cons (cl-count-if (lambda (w) (string-search w (nth 2 e))) words) e))
                           in-state))
           (best (if words (apply #'max 0 (mapcar #'car scored)) 0))
           (shown (mapcar (lambda (s) (nth 1 s))
                          (cond ((null words) (mapcar (lambda (e) (cons 0 e)) in-state))
                                ((> best 0) (cl-remove-if-not (lambda (s) (= (car s) best)) scored)))))
           (answer (format "{\"show\":[%s],\"do\":[%s]}"
                           (mapconcat (lambda (id) (format "%S" id)) shown ",")
                           (if action
                               (mapconcat (lambda (id) (format "{\"task\":%S,\"action\":%S}" id action)) shown ",")
                             ""))))
      `((:type text :delta ,answer)
        (:type usage :input ,(/ (length text) 4) :output ,(/ (length answer) 4) :cost 0.0004 :context ,(/ (length text) 4))
        (:type done :stop-reason end-turn)))))

(defun harness-provider-demo--insights (request)
  "Write an Insights summary from REQUEST's figures, as a scripted model would.
No model: the summary names the sessions and tools the figures name, in
the JSON the report asks for."
  (let* ((text (harness-provider-demo--last-user-text request))
         (line (lambda (re) (and (string-match re text) (match-string 1 text))))
         (sessions (or (funcall line "^Sessions: \\([0-9]+\\) worked") "no"))
         (projects (funcall line "^Projects: \\([^(;\n]+\\)"))
         (tool (funcall line "Most used: \\([^ ,.\n]+\\)"))
         (failing (funcall line "^Most failing: \\([^ ,.\n]+\\)"))
         (hours (funcall line "busiest hours \\([^;\n]+\\)"))
         (named (let (out (start 0))
                  (while (and (< (length out) 3)
                              (string-match "^- [^,\n]+, \\([^:\n]+\\): \\(.*\\)$" text start))
                    (push (format "%s: %s" (match-string 1 text) (match-string 2 text)) out)
                    (setq start (match-end 0)))
                  (nreverse out)))
         (answer
          (harness-json-encode-text
           (list :summary (format "You ran %s %s%s, and most of the work went through %s."
                                  sessions (if (equal sessions "1") "session" "sessions")
                                  (if projects (format ", mostly in %s" (string-trim projects)) "")
                                  (or tool "a handful of tools"))
                 :themes (or named (list "No sessions named a theme."))
                 :patterns (list (if hours (format "You work most around %s." hours)
                                   "Your hours were too few to show a pattern."))
                 :friction (list (if failing (format "%s failed more than any other tool." failing)
                                   "Nothing failed often enough to stand out."))
                 :suggestions (list "Hand the long-running work to tasks, and review it in one sitting."
                                    "Name a project's habits in its instructions file, so every session starts with them.")))))
    `((:type text :delta ,answer)
      (:type usage :input ,(/ (length text) 4) :output ,(/ (length answer) 4) :cost 0.0011 :context ,(/ (length text) 4))
      (:type done :stop-reason end-turn))))

(defvar harness-provider-demo--continuations (make-hash-table :test 'equal)
  "Session id -> remaining script after a tool call, resumed on the next request.")

(defun harness-provider-demo--complete (request)
  (let* ((on-event (plist-get request :on-event))
         (sid (or (plist-get (plist-get request :session) :id) "none"))
         (script (harness-provider-demo--script request))
         (cancelled nil)
         (timer nil)
         (steps 0))
    (cl-labels ((step ()
                  (unless cancelled
                    (if (null script)
                        nil
                      (let ((ev (pop script)))
                        (cl-incf steps)
                        (if (eq (plist-get ev :type) 'tool-call)
                            ;; Native loop: emit the call, then stop with tool-use so the
                            ;; agent executes it and calls us again; the rest of the script
                            ;; continues on the next request.
                            (progn
                              ;; Stored before the call runs: the call may
                              ;; end the turn (a tool handing its work in
                              ;; with `:end-turn'), and the cancel must find
                              ;; this to drop it, rather than leave the rest
                              ;; of the script for the next turn.
                              (puthash sid script harness-provider-demo--continuations)
                              (funcall on-event ev)
                              (funcall on-event '(:type done :stop-reason tool-use)))
                          (funcall on-event ev)
                          (unless (eq (plist-get ev :type) 'done)
                            (setq timer (run-at-time harness-provider-demo--delay nil #'step)))))))))
      (when (and (gethash sid harness-provider-demo--continuations)
                 (harness-provider-demo--has-tool-results-p request))
        (setq script (gethash sid harness-provider-demo--continuations))
        (remhash sid harness-provider-demo--continuations))
      (funcall on-event '(:type start))
      (setq timer (run-at-time harness-provider-demo--delay nil #'step)))
    (list :cancel (lambda ()
                    (setq cancelled t)
                    (when timer (cancel-timer timer))
                    ;; Whatever came after a tool call belongs to the turn
                    ;; that just stopped: a turn a tool ended early
                    ;; (`hand_in') must not leave it for the next one.
                    (remhash sid harness-provider-demo--continuations)
                    (funcall on-event '(:type done :stop-reason cancelled))))))

(defun harness-provider-demo--has-tool-results-p (request)
  (let ((last (car (last (plist-get request :messages)))))
    (and last (cl-some (lambda (b) (equal (plist-get b :type) "tool_result"))
                       (plist-get last :content)))))

(harness-define-provider 'demo
  :label "Demo"
  :doc "Scripted provider that never calls a network."
  :models (lambda ()
            (harness-resolved
             (list (list :name "scripted" :label "Demo scripted" :context-window 8000
                         :input-modalities '("text" "image")
                         :pricing '(:input 1.0 :output 2.0 :cache-read 0.1 :cache-write 1.25)
                         :thinking-levels '("low" "high")))))
  :complete #'harness-provider-demo--complete
  :capabilities '(:vision t :thinking t))

(harness-define-module 'provider-demo
  :doc "Scripted provider for demos and tests."
  :requires '(provider))

(provide 'harness-provider-demo)
;;; harness-provider-demo.el ends here
