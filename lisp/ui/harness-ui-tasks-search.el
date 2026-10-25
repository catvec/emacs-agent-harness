;;; harness-ui-tasks-search.el --- The task board's search: a command palette a model runs  -*- lexical-binding: t; -*-

;;; Commentary:

;; / on the task board -- or [Search] in its header line, or C-c h /
;; there, which is the board's own search on a board (see
;; harness-ui-quick-search.el) -- turns the board's compose box into a
;; search box, in colours of its own.  What the box held waits aside and
;; comes back once the search is sent, or the search box closed with
;; C-g.  A line in words there is a question about the tasks ("did I
;; have a task about the question button?"), an order to manage some
;; ("get rid of the mq land task", "restart the errored tasks"), or a
;; session or a command to find ("where did I debug the merge queue?",
;; "how do I attach a file?").  RET sends it, with the board and the
;; harness's commands, to a quick, cheap model (`search/ask', see
;; harness-tasks-search.el) that favours tasks; it answers with the
;; tasks, sessions and commands the line is about and what to do with
;; the tasks and, when words answer the line ("how many tasks failed?",
;; "how do I attach a file?"), with the answer itself.  M-p and M-n in
;; the search box bring back earlier searches, the quick search's among
;; them.
;;
;; The board then shows only those tasks, in their columns, archived
;; ones included, under a banner that says what it shows: the line, what
;; it matched, and what the model looked at besides the board.  The
;; answer in words comes next, whole, rendered as Markdown
;; (`harness-quick-search-answer-text'): it is never cut to a line.  The
;; sessions and commands it found follow, each on a line of its own with
;; its buttons -- [Open] a session, at the message where the search found
;; its words when it did (`harness-quick-search-open-session'), [Run] or
;; [Describe] a command -- and the model's note, or the search's when
;; nothing matched and it looked wider.  C-g on the board, or [Clear],
;; shows every task again.  The tasks stay shown while they change, so
;; what an action does shows on their cards.
;;
;; An order runs at once when it is easily undone or does no harm --
;; archive (of a task not at work), restore, retry, start, a new
;; priority ("do the docs task first") -- and the banner says what was
;; done, the way a toast would, with [Undo] where it can: archive and
;; restore undo each other, and a priority goes back to what it was.
;; An order that interrupts work, merges it or sends words to an agent
;; -- stop, archive of a task at work, verify, mark done, message, send
;; back -- is proposed instead: the banner asks, with a button that
;; does it and one that skips it, and / then RET on an empty box does
;; it too, as the search box's placeholder says.
;;
;; The model's process starts as the search box opens (`search/warm'),
;; so the answer comes sooner, and the header line's [Search] spins
;; while the model works.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'text-property-search)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)
(require 'harness-ui-compose)
(require 'harness-ui-tasks)
(require 'harness-ui-quick-search)

(defface harness-task-search-face '((t :inherit harness-task-title-face))
  "The line a board's search asked, in the banner above the tasks it shows."
  :group 'harness-ui-tasks)

(defface harness-task-search-proposal-face '((t :inherit harness-task-attention-face))
  "What a board's search proposes to do, waiting for your OK."
  :group 'harness-ui-tasks)

(defvar-local harness-ui-tasks-search--state nil
  "This board's search, or nil.  A plist:
`:query'    the line asked;
`:seq'      its number, which an answer must carry to count;
`:status'   `searching', `acting', `done' or `failed';
`:model'    the model that answers, once known;
`:ids'      the ids of the tasks shown, or `all' before an answer;
`:tasks'    those tasks as the answer names them;
`:sessions' the sessions it found, as `search/ask' names them;
`:commands' the commands it found, entries of the catalogue;
`:answer'   its answer in words, Markdown, or nil;
`:note'     what the model, or the search, says of the answer;
`:widened'  non-nil when the search looked wider, having found nothing;
`:looked'   what the model looked at besides the board;
`:error'    why the search failed;
`:proposed' actions waiting for the user's OK;
`:running'  actions being run;
`:results'  how the actions run last went;
`:undo'     the actions that undo them;
`:focus'    non-nil when the best match is to get point.")

(defvar-local harness-ui-tasks-search--seq 0
  "The number of this board's latest search.  Answers to earlier ones are dropped.")

(defvar-local harness-ui-tasks-search--model nil
  "The model that answers this board's searches, as `search/warm' said.")

(defvar-local harness-ui-tasks-search--draft nil
  "What this board's compose box held when it turned into a search box.
A plist: `:text' and `:attachments', which come back when the search
box closes, with `:target', what the box did then (see
`harness-ui-tasks--target'); `:in-box' is non-nil when point was in
the box, not on the board, and `:task' is the task whose card point
was on, which point goes back to.")

(defconst harness-ui-tasks-search--max-found 4
  "The most sessions, and the most commands, a board's banner lists.
A line says how many more the search found.")

;;;; Words

(defconst harness-ui-tasks-search--verbs
  '(("archive" "Archived" "archive")
    ("restore" "Restored" "restore")
    ("stop" "Stopped" "stop")
    ("retry" "Retried" "retry")
    ("start" "Started" "start")
    ("verify" "Verified" "verify")
    ("complete" "Marked done" "mark done")
    ("message" "Sent a message to" "message")
    ("reject" "Sent back" "send back")
    ("priority" "Changed the priority of" "change the priority of"))
  "How a board says each action of a search: (ACTION DONE FAILED).
DONE opens what it did, FAILED says what it could not do.  What a
priority action did names the priority it gave instead, when it is
known: \"Made “A” and “B” high priority\".")

(defun harness-ui-tasks-search--title (action)
  "The title of the task ACTION is about, quoted."
  (harness-ui-tasks--quote
   (harness-truncate-end
    (let ((task (harness-ui-tasks--find (plist-get action :task))))
      (or (and task (harness-ui-tasks--title task)) (plist-get action :title) (plist-get action :task) "?"))
    60)))

(defun harness-ui-tasks-search--titles (actions)
  "The quoted titles of the tasks of ACTIONS, as a list in words."
  (let ((titles (mapcar #'harness-ui-tasks-search--title actions)))
    (pcase (length titles)
      (1 (car titles))
      (2 (concat (car titles) " and " (cadr titles)))
      (_ (concat (string-join (butlast titles) ", ") " and " (car (last titles)))))))

(defun harness-ui-tasks-search--group (actions &optional key)
  "ACTIONS grouped by action, in the order each first comes.
Each group is (NAME . ACTIONS).  KEY, a function of an action, gives
what to group by instead, and NAME is that."
  (let ((key (or key (lambda (a) (plist-get a :action))))
        groups)
    (dolist (a actions)
      (let* ((name (funcall key a))
             (cell (assoc name groups)))
        (if cell (setcdr cell (append (cdr cell) (list a)))
          (push (list name a) groups))))
    (nreverse groups)))

(defun harness-ui-tasks-search--done-text (results)
  "Say what RESULTS, the actions that ran, did: \"Retried “A” and “B”\".
Failures follow, each saying why: \"could not retry “C”: it is working already\"."
  (let ((ok (cl-remove-if-not (lambda (r) (harness-json-true-p (plist-get r :ok))) results))
        (failed (cl-remove-if (lambda (r) (harness-json-true-p (plist-get r :ok))) results)))
    (string-join
     (append
      (mapcar (lambda (group)
                (let ((titles (harness-ui-tasks-search--titles (cdr group))))
                  (pcase (car group)
                    (`("priority" . ,(and priority (pred stringp)))
                     (format "Made %s %s priority" titles priority))
                    (`(,name . ,_)
                     (concat (or (nth 1 (assoc name harness-ui-tasks-search--verbs)) (capitalize name))
                             " " titles)))))
              ;; Priorities given go by the priority: each says it.
              (harness-ui-tasks-search--group
               ok (lambda (r) (let ((name (plist-get r :action)))
                                (cons name (and (equal name "priority") (plist-get r :text)))))))
      (mapcar (lambda (r)
                (format "%s %s %s: %s" (if ok "could not" "Could not")
                        (or (nth 2 (assoc (plist-get r :action) harness-ui-tasks-search--verbs)) (plist-get r :action))
                        (harness-ui-tasks-search--title r)
                        (or (plist-get r :error) "it failed")))
              failed))
     "; ")))

(defun harness-ui-tasks-search--ask-text (proposed)
  "Ask whether to do PROPOSED, the actions waiting for the user's OK."
  (string-join
   (mapcar (lambda (group)
             (let* ((actions (cdr group))
                    (titles (harness-ui-tasks-search--titles actions))
                    (many (cdr actions))
                    (text (plist-get (car actions) :text)))
               (pcase (car group)
                 ("archive" (format "Stop and archive %s?" titles))
                 ("stop" (format "Stop %s?" titles))
                 ("verify" (format "Verify %s? %s work merges." titles (if many "Their" "Its")))
                 ("complete" (format "Mark %s done?" titles))
                 ("message" (format "Send %s to %s?" (harness-ui-tasks--quote (harness-truncate-end text 80)) titles))
                 ("reject" (format "Send %s back: %s?" titles (harness-ui-tasks--quote (harness-truncate-end text 80))))
                 ("priority" (format "Change the priority of %s?" titles))
                 (name (format "%s %s?" (capitalize name) titles)))))
           (harness-ui-tasks-search--group proposed))
   "  "))

(defun harness-ui-tasks-search--do-label (proposed)
  "The label of the button that does PROPOSED: its action when it is one."
  (let ((groups (harness-ui-tasks-search--group proposed)))
    (if (cdr groups)
        "Do it"
      (pcase (car (car groups))
        ("archive" "Stop and archive")
        ("complete" "Mark done")
        ("message" "Send")
        ("reject" "Send back")
        (name (capitalize name))))))

(defun harness-ui-tasks-search--short (proposed)
  "PROPOSED in a few words, for the search box's placeholder."
  (let* ((groups (harness-ui-tasks-search--group proposed))
         (n (length proposed)))
    (if (cdr groups)
        (format "do the %d proposed actions" n)
      (format "%s %s" (downcase (harness-ui-tasks-search--do-label proposed))
              (if (= n 1) (harness-ui-tasks-search--title (car proposed)) (format "%d tasks" n))))))

(defun harness-ui-tasks-search-proposal-text ()
  "What this board's search proposes, in a few words, or nil.
The search box's placeholder names it, since \\`RET' on the empty box
does it."
  (when-let* ((proposed (plist-get harness-ui-tasks-search--state :proposed)))
    (substring-no-properties (harness-ui-tasks-search--short proposed))))

(defun harness-ui-tasks-search--plural (n word)
  "N WORDs, in words: \"1 session\", \"2 sessions\"."
  (format "%d %s%s" n word (if (= n 1) "" "s")))

(defun harness-ui-tasks-search--count (n)
  "N tasks in words."
  (pcase n (0 "no task matches") (1 "1 task") (_ (format "%d tasks" n))))

(defun harness-ui-tasks-search--answer (state)
  "The answer in words of the search STATE, or of a plan; nil when it has none."
  (let ((answer (plist-get state :answer)))
    (and (stringp answer) (not (string-blank-p answer)) answer)))

(defun harness-ui-tasks-search--counts (state)
  "What the search STATE matched, in words: \"1 task · 2 sessions · 1 command\".
No task is \"no task matches\", whatever else it found, unless the
search answered in words: then it is \"answered\"."
  (let* ((ids (plist-get state :ids))
         (n (if (listp ids) (length ids) 0))
         (sessions (length (plist-get state :sessions)))
         (commands (length (plist-get state :commands))))
    (string-join
     (delq nil (list (if (and (= n 0) (harness-ui-tasks-search--answer state))
                         "answered"
                       (harness-ui-tasks-search--count n))
                     (and (> sessions 0) (harness-ui-tasks-search--plural sessions "session"))
                     (and (> commands 0) (harness-ui-tasks-search--plural commands "command"))))
     " · ")))

(defun harness-ui-tasks-search--found-text (plan)
  "Say what PLAN, an answer, found, for the echo area.
That is \"1 task matches · 2 sessions\", or \"No task matches “…”\"
with what else it found; a plan that answers in words says
\"Answered\" first, and no task matching goes without saying."
  (let ((n (length (plist-get plan :ids)))
        (answered (harness-ui-tasks-search--answer plan))
        (sessions (length (plist-get plan :sessions)))
        (commands (length (plist-get plan :commands))))
    (string-join
     (delq nil (list (and answered "Answered")
                     (pcase n
                       (0 (and (not answered)
                               (format "No task matches %s" (harness-ui-tasks--quote (plist-get plan :query)))))
                       (1 "1 task matches")
                       (_ (format "%d tasks match" n)))
                     (and (> sessions 0) (harness-ui-tasks-search--plural sessions "session"))
                     (and (> commands 0) (harness-ui-tasks-search--plural commands "command"))))
     " · ")))

;;;; The banner

(defun harness-ui-tasks-search--button (label action help)
  "A board button LABEL that calls ACTION, a command, with HELP as its tooltip."
  (harness-ui-tasks--button label (lambda () (call-interactively action)) help action))

(defun harness-ui-tasks-search--line (left right)
  "A banner line: LEFT, then RIGHT (buttons) against the right edge."
  (let* ((right (or right ""))
         (left (harness-ui-tasks--fit left (- (harness-ui-tasks--width) (string-width right) 6))))
    (concat left
            (if (string-empty-p right) ""
              (concat (propertize " " 'display `(space :align-to (- right ,(1+ (string-width right)))))
                      right))
            "\n")))

(defun harness-ui-tasks-search--found-button (name)
  "Return the function that makes the board's buttons of the thing NAME.
It takes what `harness-quick-search-session-line' gives its BUTTON:
the label, the action and the tooltip.  NAME keeps each button's
place on the board across redraws, with its label."
  (lambda (label action help)
    (harness-ui-tasks--button label action help (format "search:%s:%s" name label))))

(defun harness-ui-tasks-search--fit-found (text)
  "TEXT, lines of what a search found, fitted to the board.
TEXT is what `harness-quick-search-session-line' and its kin return;
each line's buttons go against the right edge, as the banner's do."
  (mapconcat (lambda (line)
               (if-let* ((at (text-property-any 0 (length line) 'button t line)))
                   (harness-ui-tasks-search--line (string-trim-right (substring line 0 at)) (substring line at))
                 (harness-ui-tasks-search--line line nil)))
             (split-string text "\n" t)
             ""))

(defun harness-ui-tasks-search--more (n word)
  "The line that says N more WORDs were found than listed, or \"\"."
  (if (> n 0)
      (harness-ui-tasks-search--line
       (propertize (format "    … %s more" (harness-ui-tasks-search--plural n word)) 'face 'harness-dim-face)
       nil)
    ""))

(defun harness-ui-tasks-search--found-lines (state)
  "The lines of what the search STATE found besides tasks.
That is its note, then the sessions and the commands, at most
`harness-ui-tasks-search--max-found' of each, with the board's buttons."
  (let ((note (plist-get state :note))
        (sessions (plist-get state :sessions))
        (commands (plist-get state :commands))
        (max harness-ui-tasks-search--max-found))
    (concat
     (if (and (stringp note) (not (string-blank-p note)))
         (harness-ui-tasks-search--line
          (concat "  "
                  (if (plist-get state :widened)
                      (harness-ui-level-icon 'caution)
                    (propertize (harness-ui-icon 'harness-icon-search) 'face 'harness-dim-face))
                  " " (propertize (harness-ui-one-line note) 'face 'harness-dim-face))
          nil)
       "")
     (mapconcat (lambda (session)
                  (harness-ui-tasks-search--fit-found
                   (harness-quick-search-session-line
                    session (harness-ui-tasks-search--found-button (format "session:%s" (plist-get session :id))))))
                (take max sessions) "")
     (harness-ui-tasks-search--more (- (length sessions) max) "session")
     (mapconcat (lambda (command)
                  (harness-ui-tasks-search--fit-found
                   (harness-quick-search-command-line
                    command (harness-ui-tasks-search--found-button (format "command:%s" (plist-get command :command))))))
                (take max commands) "")
     (harness-ui-tasks-search--more (- (length commands) max) "command"))))

(defun harness-ui-tasks-search--banner ()
  "The text above a board its search filters: what it shows, and what was done.
Its first line has the line asked and where the search is, or what it
matched; the answer in words, whole (`harness-quick-search-answer-text'),
the note and the sessions and commands it found follow, then what the
actions did, then a line that asks about what waits for an OK."
  (let* ((state harness-ui-tasks-search--state)
         (status (plist-get state :status))
         (dot (propertize "  ·  " 'face 'harness-dim-face))
         (icon (concat "  " (propertize (harness-ui-icon 'harness-icon-search) 'face 'harness-dim-face) " "))
         (first
          (lambda (rest right)
            ;; The line asked, then REST: the line asked gives way first,
            ;; so what the search found stays in sight.
            (let ((room (- (harness-ui-tasks--width) 6 (string-width right) (string-width rest)
                           (string-width icon) (string-width dot) 2)))
              (harness-ui-tasks-search--line
               (concat icon
                       (propertize (harness-ui-tasks--quote
                                    (harness-truncate-end (plist-get state :query) (max 12 (min 80 room))))
                                   'face 'harness-task-search-face)
                       dot rest)
               right))))
         (clear (harness-ui-tasks-search--button
                 "[Clear]" #'harness-ui-tasks-search-clear "Show every task again (C-g)")))
    (concat
     (pcase status
       ('searching
        (funcall first
                 (propertize (format "asking %s%s"
                                     (if-let* ((model (or (plist-get state :model) harness-ui-tasks-search--model)))
                                         (harness-ui-model-label model)
                                       "the model")
                                     harness-ui-tasks--ellipsis)
                             'face 'harness-dim-face)
                 (harness-ui-tasks-search--button "[Cancel]" #'harness-ui-tasks-search-clear
                                                  "Drop this search and show every task (C-g)")))
       ('failed
        (funcall first
                 (concat (harness-ui-level-icon 'failure) " "
                         (propertize (concat "the search failed: " (harness-ui-one-line (plist-get state :error)))
                                     'face 'harness-failure-face))
                 (concat (harness-ui-tasks-search--button "[Retry]" #'harness-ui-tasks-search-retry "Ask again")
                         " " clear)))
       (_
        (funcall first
                 (concat (propertize (harness-ui-tasks-search--counts state) 'face 'harness-dim-face)
                         (if-let* ((looked (plist-get state :looked)))
                             (concat dot (propertize looked 'face 'harness-dim-face))
                           ""))
                 clear)))
     ;; Its answer in words, whole, under the line it answers.
     (if-let* ((answer (harness-ui-tasks-search--answer state)))
         (harness-quick-search-answer-text answer 4 (harness-ui-tasks--width))
       "")
     ;; What else it found.
     (harness-ui-tasks-search--found-lines state)
     ;; What ran.
     (cond
      ((plist-get state :running)
       (harness-ui-tasks-search--line
        (concat "  " (harness-ui-level-icon 'caution) " "
                (propertize (concat (harness-ui-tasks-search--ask-text-running (plist-get state :running))
                                    harness-ui-tasks--ellipsis)
                            'face 'harness-dim-face))
        nil))
      ((plist-get state :results)
       (let* ((results (plist-get state :results))
              (failed (cl-some (lambda (r) (not (harness-json-true-p (plist-get r :ok)))) results)))
         (harness-ui-tasks-search--line
          (concat "  " (harness-ui-level-icon (if failed 'failure 'success)) " "
                  (harness-ui-tasks-search--done-text results))
          (and (plist-get state :undo)
               (harness-ui-tasks-search--button "[Undo]" #'harness-ui-tasks-search-undo
                                                "Undo what the search just did"))))))
     ;; What waits for an OK.
     (when-let* ((proposed (plist-get state :proposed)))
       (harness-ui-tasks-search--line
        (concat "  " (harness-ui-status-icon "blocked") " "
                (propertize (harness-ui-tasks-search--ask-text proposed) 'face 'harness-task-search-proposal-face))
        (concat (harness-ui-tasks-search--button
                 (format "[%s]" (harness-ui-tasks-search--do-label proposed))
                 #'harness-ui-tasks-search-confirm
                 (substitute-command-keys
                  "Do what the search proposes (or \\<harness-ui-tasks-board-map>\\[harness-ui-tasks-search] then RET on an empty box)"))
                " "
                (harness-ui-tasks-search--button "[Skip]" #'harness-ui-tasks-search-dismiss
                                                 "Leave it undone"))))
     "\n")))

(defun harness-ui-tasks-search--ask-text-running (running)
  "Say what RUNNING, the actions under way, are doing."
  (string-join
   (mapcar (lambda (group)
             (concat (pcase (car group)
                       ("archive" "archiving") ("restore" "restoring") ("stop" "stopping")
                       ("retry" "retrying") ("start" "starting") ("verify" "verifying")
                       ("complete" "marking done") ("message" "sending to") ("reject" "sending back")
                       ("priority" "changing the priority of")
                       (name name))
                     " " (harness-ui-tasks-search--titles (cdr group))))
           (harness-ui-tasks-search--group running))
   ", "))

;;;; The filter

(defun harness-ui-tasks-search--show-p (task)
  "Non-nil when this board's search shows TASK."
  (let ((ids (plist-get harness-ui-tasks-search--state :ids)))
    (if (eq ids 'all)
        (not (harness-json-true-p (plist-get task :archived)))
      (member (plist-get task :id) ids))))

(defun harness-ui-tasks-search--install ()
  "Make this board show what its search found, and draw it."
  (setq harness-ui-tasks-filter
        (list :show #'harness-ui-tasks-search--show-p
              :banner #'harness-ui-tasks-search--banner
              :clear #'harness-ui-tasks-search-clear))
  ;; Forced: the banner says what the search is doing, which the board's
  ;; key -- the tasks -- does not change.
  (harness-ui-tasks--render t)
  ;; The search box's placeholder names what an empty RET does, which
  ;; an answer may just have changed.
  (when (harness-ui-tasks--searching-p) (harness-compose-update-placeholder))
  (force-mode-line-update))

(defun harness-ui-tasks-search--update (board seq &rest changes)
  "Merge CHANGES into BOARD's search SEQ, and draw it; nil when it is gone.
A search the board dropped, or one asked after, is left alone."
  (when (harness-ui-tasks--board-p board)
    (with-current-buffer board
      (when (and harness-ui-tasks-search--state (= seq harness-ui-tasks-search--seq))
        (let ((state (copy-sequence harness-ui-tasks-search--state)))
          (cl-loop for (k v) on changes by #'cddr do (setq state (plist-put state k v)))
          (setq harness-ui-tasks-search--state state))
        (harness-ui-tasks-search--install)
        t))))

;;;; The search box

(defun harness-ui-tasks-search--board ()
  "The board a search goes to: this buffer when it is one, else the project's."
  (if (harness-ui-tasks--board-p (current-buffer))
      (current-buffer)
    (let ((board (harness-tasks)))
      (and (harness-ui-tasks--board-p board) board))))

(defun harness-ui-tasks-search--warm ()
  "Have the harness start the model of this board's next search now.
It also says which model answers, which the banner names."
  (let ((board (current-buffer)))
    (harness-ui-call "_harness/search/warm" (list :cwd (harness-ui-tasks--scope-dir))
                     (lambda (r)
                       (when (and (buffer-live-p board) (plist-get r :model))
                         (with-current-buffer board
                           (setq harness-ui-tasks-search--model (plist-get r :model)))))
                     #'ignore)))

(defun harness-ui-tasks-search--open ()
  "Turn this board's compose box into a search box, and put point in it.
What the box held waits aside (`harness-ui-tasks-search--draft') until
the search is sent or the box closed (`harness-ui-tasks-search-leave').
A box that is a search box already keeps its line."
  (unless (harness-ui-tasks--searching-p)
    (setq harness-ui-tasks-search--draft
          (list :text (harness-compose-text)
                :attachments harness-compose-attachments
                :target harness-ui-tasks--target
                :in-box (harness-compose-in-p)
                :task (and (not (harness-compose-in-p)) (get-text-property (point) 'harness-task-id))))
    (setq harness-compose-attachments nil)
    (harness-ui-tasks--set-compose "" '(search)))
  (unless harness-quick-search-box-mode (harness-quick-search-box-mode 1))
  (setq harness-quick-search-box-function #'harness-ui-tasks-search-submit)
  (harness-ui-tasks-search--warm)
  (goto-char harness-compose-end)
  (dolist (w (get-buffer-window-list nil nil t)) (set-window-point w (point))))

(defun harness-ui-tasks-search-end ()
  "Stop this board's compose box taking a search, keys and all.
What the box held before is forgotten, and what it does is left as it
is: `harness-ui-tasks-search-leave' gives both back instead.  The board
calls this when the box turns to something else, a reply say."
  (when harness-quick-search-box-mode (harness-quick-search-box-mode -1))
  (setq harness-quick-search-box-function nil
        harness-ui-tasks-search--draft nil))

(defun harness-ui-tasks-search-leave ()
  "Close this board's search box: the box gets back what it held before.
Its text and attachments come back, and what it did -- a new task, an
edited prompt, a message.  Point goes back to the card it was on when
the search box opened, if the board still shows it, else stays in the
box.  Nothing happens when the box takes no search."
  (when (harness-ui-tasks--searching-p)
    (let ((draft harness-ui-tasks-search--draft))
      (harness-ui-tasks-search-end)
      (setq harness-compose-attachments (plist-get draft :attachments))
      (harness-ui-tasks--set-compose (or (plist-get draft :text) "") (plist-get draft :target))
      (when-let* ((task (plist-get draft :task))
                  (card (save-excursion
                          (goto-char (point-min))
                          (text-property-search-forward 'harness-task-id task #'equal))))
        (goto-char (prop-match-beginning card))
        (dolist (w (get-buffer-window-list nil nil t)) (set-window-point w (point)))))))

(defun harness-ui-tasks-search-submit (text)
  "Search TEXT, the line this board's search box sent, or do what is proposed.
TEXT is trimmed.  A line goes to the search, and to the history of
searches (`harness-quick-search-history'); the box gets back what it
held before (`harness-ui-tasks-search-leave').  An empty line does what
the board's search proposes, when it proposes something; else the
search box stays, saying what it takes."
  (let ((query (string-trim (or text ""))))
    (cond
     ((and (string-empty-p query) (plist-get harness-ui-tasks-search--state :proposed))
      (harness-ui-tasks-search-leave)
      (harness-ui-tasks-search-confirm))
     ((string-empty-p query)
      (message "Say what to find, or what to do"))
     (t
      (add-to-history 'harness-quick-search-history query)
      ;; Point goes to the best match when it was on the board before
      ;; the search box opened, as it would have stayed there.
      (let ((focus (if (harness-ui-tasks--searching-p)
                       (not (plist-get harness-ui-tasks-search--draft :in-box))
                     (not (harness-compose-in-p)))))
        (harness-ui-tasks-search-leave)
        (harness-ui-tasks-search--start query focus))))))

;;;###autoload
(defun harness-tasks-search (&optional query)
  "Find tasks, sessions and commands from the project's board, or act on tasks.
The board's compose box turns into a search box, in colours of its own;
what it held waits aside, and comes back once the search is sent or
the box closed with \\<harness-ui-tasks-mode-map>\\[harness-ui-tasks-compose-quit].  A line there is a question about the
tasks (\"did I have a task about the question button?\", \"what is
stuck?\"), an order to manage some (\"get rid of the mq land task\",
\"restart the errored tasks\"), or a session or a command to find
\(\"where did I debug the merge queue?\").  \\`RET' sends it, with the
board and the harness's commands, to a quick, cheap model
\(`harness-tasks-search-model'), which favours tasks: it answers with
the tasks the line is about and what to do with them, the sessions and
commands it found and, when words answer the line (\"how many failed?\"),
the answer in words.  \\`M-p' and \\`M-n' bring back earlier searches.

The board shows those tasks only, under a banner that says what it
shows, has the answer in words, whole, and lists the sessions and
commands found, with buttons to open or run them;
\\[harness-ui-tasks-compose-quit] there shows every task again.  What is easily
undone or does no harm (archive, restore, retry, start) is done at once
and the banner says so, with [Undo]; what interrupts work, merges it or
sends words to an agent is proposed, and \\`RET' on the empty search box
then does it.

On a board this searches it; elsewhere the current project's board
opens first.  With QUERY, from Lisp, the search starts at once, and the
compose box is left as it is."
  (interactive)
  (let ((board (or (harness-ui-tasks-search--board) (user-error "No task board to search"))))
    (with-current-buffer board
      ;; The board of every project is searched one project at a time.
      (harness-ui-tasks--need-project)
      (if query
          (harness-ui-tasks-search-submit query)
        (harness-ui-tasks-search--open)))
    board))

;;;; Searching

(defun harness-ui-tasks-search--start (query &optional focus)
  "Ask this board's search model about QUERY, and show what it finds.
The search favours tasks; the board, where it was typed and the
harness's commands go along (`search/ask').  FOCUS non-nil gives point
to the best match, once the board shows it."
  (let* ((board (current-buffer))
         (seq (cl-incf harness-ui-tasks-search--seq))
         (old harness-ui-tasks-search--state)
         ;; \"Them\" in QUERY means the tasks a finished search shows.
         (shown (let ((ids (plist-get old :ids))) (and (listp ids) ids)))
         (opts (list :bias "tasks"
                     :context (harness-quick-search-context)
                     :shown shown
                     :commands (harness-quick-search-commands))))
    (setq harness-ui-tasks--error nil
          harness-ui-tasks-search--state
          (list :query query :seq seq :status 'searching
                ;; Until the answer, the board shows what it showed.
                :ids (if (listp (plist-get old :ids)) (plist-get old :ids) 'all)
                :focus focus))
    (harness-ui-tasks-search--install)
    (harness-ui-tasks-search--spin)
    (harness-ui-call "_harness/search/ask" (list :cwd (harness-ui-tasks--scope-dir) :query query :opts opts)
                     (lambda (plan) (harness-ui-tasks-search--arrived board seq plan))
                     (lambda (err)
                       (harness-ui-tasks-search--update board seq :status 'failed
                                                        :error (harness-error-message err))))))

(defun harness-ui-tasks-search--arrived (board seq plan)
  "Show PLAN, the answer to BOARD's search SEQ, and run what it orders at once."
  (let* ((actions (plist-get plan :actions))
         (now (cl-remove-if (lambda (a) (harness-json-true-p (plist-get a :confirm))) actions))
         (later (cl-remove-if-not (lambda (a) (harness-json-true-p (plist-get a :confirm))) actions))
         (ids (plist-get plan :ids)))
    (when (harness-ui-tasks-search--update board seq :status 'done :ids ids :model (plist-get plan :model)
                                           :looked (plist-get plan :looked) :proposed later
                                           :tasks (plist-get plan :tasks)
                                           :sessions (plist-get plan :sessions)
                                           :commands (plist-get plan :commands)
                                           :answer (harness-ui-tasks-search--answer plan)
                                           :note (plist-get plan :note)
                                           :widened (eq t (plist-get plan :widened))
                                           :results nil :undo nil)
      (with-current-buffer board
        (when (and ids (plist-get harness-ui-tasks-search--state :focus))
          ;; Point goes to the best match, once the board shows it.
          (setq harness-ui-tasks--focus (cons (car ids) (float-time)))
          (harness-ui-tasks--focus-card))
        (cond
         (now (harness-ui-tasks-search--apply board seq now))
         (later (message "%s" (substring-no-properties (harness-ui-tasks-search--ask-text later))))
         (t (message "%s" (harness-ui-tasks-search--found-text plan))))))))

(defun harness-ui-tasks-search--apply (board seq actions)
  "Run ACTIONS of BOARD's search SEQ; then say how they went.
The echo area says it as a toast would, and the banner too, as long as
the board shows that search."
  (harness-ui-tasks-search--update board seq :running actions :proposed
                                   (cl-set-difference (plist-get (buffer-local-value 'harness-ui-tasks-search--state board)
                                                                 :proposed)
                                                      actions :test #'equal))
  (harness-ui-call "_harness/task/search-apply" (list :actions actions)
                   (lambda (results)
                     (let ((text (harness-ui-tasks-search--done-text results)))
                       (harness-ui-tasks-search--update
                        board seq :running nil :results results
                        :undo (delq nil (mapcar (lambda (r) (and (harness-json-true-p (plist-get r :ok))
                                                                 (plist-get r :undo)))
                                                results)))
                       (message "%s" (substring-no-properties text))))
                   (lambda (err)
                     (harness-ui-tasks-search--update
                      board seq :running nil
                      :results (mapcar (lambda (a) (append a (list :ok :false :error (harness-error-message err))))
                                       actions))
                     (message "The search's actions failed: %s" (harness-error-message err)))))

(defun harness-ui-tasks-search-show-plan (plan)
  "Show PLAN on this board, as its search would: its tasks, under a banner.
PLAN is what `search/ask' answers, or as much of it as the quick
search's [Board] has: (:ids IDS :query QUERY), with `:sessions',
`:commands', `:answer', `:note', `:widened', `:looked' and `:model'
when it has them.  The board shows the tasks IDS only, point on the
first, under a banner naming QUERY and the rest.  Nothing is done, nor
proposed: PLAN's actions stay where they were found.  An answer still
on its way to this board's own search is dropped."
  (unless (harness-ui-tasks--board-p (current-buffer)) (user-error "Not a task board"))
  (let ((ids (plist-get plan :ids)))
    (setq harness-ui-tasks--error nil
          harness-ui-tasks-search--state
          (list :query (or (plist-get plan :query) "")
                :seq (cl-incf harness-ui-tasks-search--seq)
                :status 'done :ids ids :model (plist-get plan :model)
                :looked (plist-get plan :looked)
                :tasks (plist-get plan :tasks)
                :sessions (plist-get plan :sessions)
                :commands (plist-get plan :commands)
                :answer (harness-ui-tasks-search--answer plan)
                :note (plist-get plan :note)
                :widened (eq t (plist-get plan :widened))))
    (harness-ui-tasks-search--install)
    (when ids
      (setq harness-ui-tasks--focus (cons (car ids) (float-time)))
      (harness-ui-tasks--focus-card))))

;;;; Commands of the banner

(defun harness-ui-tasks-search--state-or-error ()
  "This board's search, or a user error when it has none."
  (unless (harness-ui-tasks--board-p (current-buffer)) (user-error "Not a task board"))
  (or harness-ui-tasks-search--state (user-error "The board shows no search")))

(defun harness-ui-tasks-search-confirm ()
  "Do what this board's search proposes, waiting for your OK."
  (interactive)
  (let* ((state (harness-ui-tasks-search--state-or-error))
         (proposed (or (plist-get state :proposed) (user-error "The search proposes nothing"))))
    (harness-ui-tasks-search--apply (current-buffer) harness-ui-tasks-search--seq proposed)))

(defun harness-ui-tasks-search-dismiss ()
  "Leave undone what this board's search proposes."
  (interactive)
  (harness-ui-tasks-search--state-or-error)
  (harness-ui-tasks-search--update (current-buffer) harness-ui-tasks-search--seq :proposed nil)
  (message "Left as it is"))

(defun harness-ui-tasks-search-undo ()
  "Undo what this board's search just did.
Archive and restore undo each other; a priority goes back to what it was."
  (interactive)
  (let* ((state (harness-ui-tasks-search--state-or-error))
         (undo (or (plist-get state :undo) (user-error "Nothing to undo"))))
    (harness-ui-tasks-search--update (current-buffer) harness-ui-tasks-search--seq :undo nil)
    (harness-ui-tasks-search--apply (current-buffer) harness-ui-tasks-search--seq undo)))

(defun harness-ui-tasks-search-retry ()
  "Ask the line of this board's search again."
  (interactive)
  (harness-ui-tasks-search--start (plist-get (harness-ui-tasks-search--state-or-error) :query)
                                  (not (harness-compose-in-p))))

(defun harness-ui-tasks-search-clear ()
  "Drop this board's search: every task shows again.
An answer still on its way is dropped too."
  (interactive)
  (when (harness-ui-tasks--board-p (current-buffer))
    (cl-incf harness-ui-tasks-search--seq)
    (setq harness-ui-tasks-search--state nil
          harness-ui-tasks-filter nil)
    (harness-ui-tasks--render t)
    (force-mode-line-update)))

;;;; The header line

(defconst harness-ui-tasks-search--frames ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"]
  "Frames of the spinner the header line shows while a search's model works.")

(defvar harness-ui-tasks-search--frame 0 "The spinner's frame.")
(defvar harness-ui-tasks-search--timer nil "Turns the spinner while a board searches.")

(defun harness-ui-tasks-search--searching ()
  "The boards whose search waits for its model."
  (cl-remove-if-not (lambda (b) (eq 'searching (plist-get (buffer-local-value 'harness-ui-tasks-search--state b)
                                                           :status)))
                    (harness-ui-tasks--buffers)))

(defun harness-ui-tasks-search--tick ()
  "Turn the spinner of every board that searches; stop once none does."
  (let ((boards (harness-ui-tasks-search--searching)))
    (if (null boards)
        (progn (when (timerp harness-ui-tasks-search--timer) (cancel-timer harness-ui-tasks-search--timer))
               (setq harness-ui-tasks-search--timer nil)
               (mapc (lambda (b) (with-current-buffer b (force-mode-line-update))) (harness-ui-tasks--buffers)))
      (cl-incf harness-ui-tasks-search--frame)
      (dolist (b boards)
        (when (get-buffer-window b t)
          (with-current-buffer b (force-mode-line-update)))))))

(defun harness-ui-tasks-search--spin ()
  "Start the spinner unless it turns already."
  (unless (timerp harness-ui-tasks-search--timer)
    (setq harness-ui-tasks-search--timer (run-at-time 0.1 0.1 #'harness-ui-tasks-search--tick))))

(defun harness-ui-tasks-search--header ()
  "The board's [Search] segment, with a spinner while its model works."
  (when (harness-ui-tasks--board-p (current-buffer))
    (harness-ui-tasks--segment
     (if (eq 'searching (plist-get harness-ui-tasks-search--state :status))
         (concat (propertize (aref harness-ui-tasks-search--frames
                                   (% harness-ui-tasks-search--frame (length harness-ui-tasks-search--frames)))
                             'face 'harness-status-running-face)
                 " [Search]")
       "[Search]")
     #'harness-ui-tasks-search
     #'harness-ui-tasks-search--help)))

(defun harness-ui-tasks-search--help (window _object _pos)
  "The tooltip of the [Search] segment in WINDOW's header line.
A `help-echo' function, so the keymaps are searched on hover, not every
time the header line is drawn, which is on every key typed."
  (with-current-buffer (if (window-live-p window) (window-buffer window) (current-buffer))
    (harness-ui-one-line
     (substitute-command-keys
      "Find tasks, sessions and commands, or act on tasks, by saying so in words (\\<harness-ui-tasks-board-map>\\[harness-ui-tasks-search])"))))

;;;; Module

(defun harness-ui-tasks-search--init ()
  "Hook the search into the boards' header line.
Its key is the board's own / (`harness-ui-tasks-search'); / under the
harness prefix is the quick search's, which on a board is this search."
  (add-hook 'harness-ui-tasks-header-functions #'harness-ui-tasks-search--header))

(defun harness-ui-tasks-search--shutdown ()
  "Stop the spinner, and give every board's search box back what it held."
  (when (timerp harness-ui-tasks-search--timer) (cancel-timer harness-ui-tasks-search--timer))
  (setq harness-ui-tasks-search--timer nil)
  (dolist (board (harness-ui-tasks--buffers))
    (with-current-buffer board
      (when (harness-ui-tasks--searching-p)
        (ignore-errors (harness-ui-tasks-search-leave))))))

(harness-define-module 'ui-tasks-search
  :doc "The task board's search: find tasks, sessions and commands or act on tasks in words, answered by a cheap model."
  :requires '(ui-tasks ui-quick-search)
  :init #'harness-ui-tasks-search--init
  :shutdown #'harness-ui-tasks-search--shutdown)

(provide 'harness-ui-tasks-search)
;;; harness-ui-tasks-search.el ends here
