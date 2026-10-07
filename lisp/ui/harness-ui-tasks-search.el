;;; harness-ui-tasks-search.el --- The task board's search: a command palette a model runs  -*- lexical-binding: t; -*-

;;; Commentary:

;; / on the task board -- or [Search] in its header line, or C-c h /
;; from anywhere, which opens the project's board first -- reads a line
;; in the minibuffer, Emacs's own command palette: a question about the
;; tasks ("did I have a task about the question button?") or an order
;; to manage some ("get rid of the mq land task", "restart the errored
;; tasks").  The line goes with the board to a quick, cheap model
;; (`task/search', see harness-tasks-search.el), which answers with the
;; tasks the line is about and what to do with them, never with prose.
;;
;; The board then shows only those tasks, in their columns, archived
;; ones included, under a banner that says what it shows: the line, how
;; many tasks, and what the model looked at besides the board.  C-g on
;; the board, or [Clear], shows every task again.  The tasks stay shown
;; while they change, so what an action does shows on their cards.
;;
;; An order runs at once when it is easily undone or does no harm --
;; archive (of a task not at work), restore, retry, start -- and the
;; banner says what was done, the way a toast would, with [Undo] where
;; it can: archive and restore undo each other.  An order that
;; interrupts work, merges it or sends words to an agent -- stop,
;; archive of a task at work, verify, mark done, message, send back --
;; is proposed instead: the banner asks, with a button that does it and
;; one that skips it, and / then RET on an empty line does it too.
;;
;; The model's process starts as the line is being typed
;; (`task/search-warm'), so the answer comes sooner, and the header
;; line's [Search] spins while the model works.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)
(require 'harness-ui-compose)
(require 'harness-ui-tasks)

(harness-ui-define-icon harness-icon-search "search" "⌕" "find" "A search.")

(defface harness-task-search-face '((t :inherit harness-task-title-face))
  "The line a board's search asked, in the banner above the tasks it shows."
  :group 'harness-ui-tasks)

(defface harness-task-search-proposal-face '((t :inherit harness-task-attention-face))
  "What a board's search proposes to do, waiting for your OK."
  :group 'harness-ui-tasks)

(defvar harness-ui-tasks-search-history nil
  "The lines searched on task boards, for the minibuffer's history.")

(defvar-local harness-ui-tasks-search--state nil
  "This board's search, or nil.  A plist:
`:query'    the line asked;
`:seq'      its number, which an answer must carry to count;
`:status'   `searching', `acting', `done' or `failed';
`:model'    the model that answers, once known;
`:ids'      the ids of the tasks shown, or `all' before an answer;
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
  "The model that answers this board's searches, as `task/search-warm' said.")

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
    ("reject" "Sent back" "send back"))
  "How a board says each action of a search: (ACTION DONE FAILED).
DONE opens what it did, FAILED says what it could not do.")

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

(defun harness-ui-tasks-search--group (actions)
  "ACTIONS grouped by action, in the order each first comes.
Each group is (NAME . ACTIONS)."
  (let (groups)
    (dolist (a actions)
      (let ((cell (assoc (plist-get a :action) groups)))
        (if cell (setcdr cell (append (cdr cell) (list a)))
          (push (list (plist-get a :action) a) groups))))
    (nreverse groups)))

(defun harness-ui-tasks-search--done-text (results)
  "Say what RESULTS, the actions that ran, did: \"Retried “A” and “B”\".
Failures follow, each saying why: \"could not retry “C”: it is working already\"."
  (let ((ok (cl-remove-if-not (lambda (r) (harness-json-true-p (plist-get r :ok))) results))
        (failed (cl-remove-if (lambda (r) (harness-json-true-p (plist-get r :ok))) results)))
    (string-join
     (append
      (mapcar (lambda (group)
                (let ((verb (or (nth 1 (assoc (car group) harness-ui-tasks-search--verbs)) (capitalize (car group)))))
                  (concat verb " " (harness-ui-tasks-search--titles (cdr group)))))
              (harness-ui-tasks-search--group ok))
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
  "PROPOSED in a few words, for the minibuffer's prompt."
  (let* ((groups (harness-ui-tasks-search--group proposed))
         (n (length proposed)))
    (if (cdr groups)
        (format "do the %d proposed actions" n)
      (format "%s %s" (downcase (harness-ui-tasks-search--do-label proposed))
              (if (= n 1) (harness-ui-tasks-search--title (car proposed)) (format "%d tasks" n))))))

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

(defun harness-ui-tasks-search--count (n)
  "N tasks in words."
  (pcase n (0 "no task matches") (1 "1 task") (_ (format "%d tasks" n))))

(defun harness-ui-tasks-search--banner ()
  "The text above a board its search filters: what it shows, and what was done.
Its first line has the line asked and where the search is; a second
says what the actions did, and a third asks about what waits for an OK."
  (let* ((state harness-ui-tasks-search--state)
         (status (plist-get state :status))
         (ids (plist-get state :ids))
         (dot (propertize "  ·  " 'face 'harness-dim-face))
         (head (concat "  " (propertize (harness-ui-icon 'harness-icon-search) 'face 'harness-dim-face) " "
                       (propertize (harness-ui-tasks--quote (harness-truncate-end (plist-get state :query) 80))
                                   'face 'harness-task-search-face)
                       dot))
         (clear (harness-ui-tasks-search--button
                 "[Clear]" #'harness-ui-tasks-search-clear "Show every task again (C-g)")))
    (concat
     (pcase status
       ('searching
        (harness-ui-tasks-search--line
         (concat head (propertize (format "asking %s%s"
                                          (if-let* ((model (or (plist-get state :model) harness-ui-tasks-search--model)))
                                              (harness-ui-model-label model)
                                            "the model")
                                          harness-ui-tasks--ellipsis)
                                  'face 'harness-dim-face))
         (harness-ui-tasks-search--button "[Cancel]" #'harness-ui-tasks-search-clear
                                          "Drop this search and show every task (C-g)")))
       ('failed
        (harness-ui-tasks-search--line
         (concat head (harness-ui-level-icon 'failure) " "
                 (propertize (concat "the search failed: " (harness-ui-one-line (plist-get state :error)))
                             'face 'harness-failure-face))
         (concat (harness-ui-tasks-search--button "[Retry]" #'harness-ui-tasks-search-retry "Ask again")
                 " " clear)))
       (_
        (harness-ui-tasks-search--line
         (concat head
                 (propertize (harness-ui-tasks-search--count (if (listp ids) (length ids) 0)) 'face 'harness-dim-face)
                 (if-let* ((looked (plist-get state :looked)))
                     (concat dot (propertize looked 'face 'harness-dim-face))
                   ""))
         clear)))
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
                  "Do what the search proposes (or \\<harness-ui-tasks-board-map>\\[harness-ui-tasks-search] then RET on an empty line)"))
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

;;;; Searching

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
    (harness-ui-call "_harness/task/search-warm" (list :cwd harness-ui-tasks--dir)
                     (lambda (r)
                       (when (and (buffer-live-p board) (plist-get r :model))
                         (with-current-buffer board
                           (setq harness-ui-tasks-search--model (plist-get r :model)))))
                     #'ignore)))

(defun harness-ui-tasks-search--read ()
  "Read the line to search, naming in the prompt what an empty line does."
  (let ((proposed (plist-get harness-ui-tasks-search--state :proposed)))
    (read-string (if proposed
                     (format "Find or act on tasks (RET: %s): " (harness-ui-tasks-search--short proposed))
                   "Find or act on tasks: ")
                 nil 'harness-ui-tasks-search-history)))

;;;###autoload
(defun harness-tasks-search (&optional query)
  "Find tasks on the project's board, or act on them, by saying so.
QUERY, read in the minibuffer, is a question about the tasks (\"did I
have a task about the question button?\", \"what is stuck?\") or an
order to manage some (\"get rid of the mq land task\", \"restart the
errored tasks\").  It goes with the board to a quick, cheap model
\(`harness-tasks-search-model'), which answers with the tasks QUERY is
about and what to do with them.

The board shows those tasks only, under a banner that says what it
shows; \\<harness-ui-tasks-mode-map>\\[harness-ui-tasks-compose-quit] there shows every task again.  What is easily undone or
does no harm (archive, restore, retry, start) is done at once and the
banner says so, with [Undo]; what interrupts work, merges it or sends
words to an agent is proposed, and an empty QUERY then does it.

On a board this searches it; elsewhere the current project's board
opens first."
  (interactive)
  (let ((board (or (harness-ui-tasks-search--board) (user-error "No task board to search"))))
    (with-current-buffer board
      (when (called-interactively-p 'any) (harness-ui-tasks-search--warm))
      (let ((query (string-trim (or query (harness-ui-tasks-search--read)))))
        (cond
         ((not (string-empty-p query)) (harness-ui-tasks-search--start query))
         ((plist-get harness-ui-tasks-search--state :proposed) (harness-ui-tasks-search-confirm))
         (t (message "Say what to find, or what to do")))))))

(defun harness-ui-tasks-search--start (query)
  "Ask this board's search model about QUERY, and show what it finds."
  (let* ((board (current-buffer))
         (seq (cl-incf harness-ui-tasks-search--seq))
         (old harness-ui-tasks-search--state)
         ;; \"Them\" in QUERY means the tasks a finished search shows.
         (shown (let ((ids (plist-get old :ids))) (and (listp ids) ids))))
    (setq harness-ui-tasks--error nil
          harness-ui-tasks-search--state
          (list :query query :seq seq :status 'searching
                ;; Until the answer, the board shows what it showed.
                :ids (if (listp (plist-get old :ids)) (plist-get old :ids) 'all)
                :focus (not (harness-compose-in-p))))
    (harness-ui-tasks-search--install)
    (harness-ui-tasks-search--spin)
    (harness-ui-call "_harness/task/search" (list :cwd harness-ui-tasks--dir :query query :opts (list :shown shown))
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
                                           :results nil :undo nil)
      (with-current-buffer board
        (when (and ids (plist-get harness-ui-tasks-search--state :focus))
          ;; Point goes to the best match, once the board shows it.
          (setq harness-ui-tasks--focus (cons (car ids) (float-time)))
          (harness-ui-tasks--focus-card))
        (cond
         (now (harness-ui-tasks-search--apply board seq now))
         (later (message "%s" (substring-no-properties (harness-ui-tasks-search--ask-text later))))
         (t (message "%s" (pcase (length ids)
                            (0 (format "No task matches %s" (harness-ui-tasks--quote (plist-get plan :query))))
                            (1 "1 task matches")
                            (n (format "%d tasks match" n))))))))))

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
  "Undo what this board's search just did: archive and restore undo each other."
  (interactive)
  (let* ((state (harness-ui-tasks-search--state-or-error))
         (undo (or (plist-get state :undo) (user-error "Nothing to undo"))))
    (harness-ui-tasks-search--update (current-buffer) harness-ui-tasks-search--seq :undo nil)
    (harness-ui-tasks-search--apply (current-buffer) harness-ui-tasks-search--seq undo)))

(defun harness-ui-tasks-search-retry ()
  "Ask the line of this board's search again."
  (interactive)
  (harness-ui-tasks-search--start (plist-get (harness-ui-tasks-search--state-or-error) :query)))

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
      "Find tasks, or act on them, by saying so in words (\\<harness-ui-tasks-board-map>\\[harness-ui-tasks-search])"))))

;;;; Module

(defun harness-ui-tasks-search--init ()
  "Hook the search into the boards and the global keys."
  (add-hook 'harness-ui-tasks-header-functions #'harness-ui-tasks-search--header)
  (define-key harness-ui-map (kbd "/") #'harness-tasks-search)
  (ignore-errors
    (unless (ignore-errors (transient-get-suffix 'harness-menu "/"))
      (transient-append-suffix 'harness-menu "a" '("/" "Search tasks" harness-tasks-search)))))

(defun harness-ui-tasks-search--shutdown ()
  "Stop the spinner."
  (when (timerp harness-ui-tasks-search--timer) (cancel-timer harness-ui-tasks-search--timer))
  (setq harness-ui-tasks-search--timer nil))

(declare-function transient-get-suffix "transient")
(declare-function transient-append-suffix "transient")

(harness-define-module 'ui-tasks-search
  :doc "The task board's search: find tasks or act on them in words, answered by a cheap model."
  :requires '(ui-tasks)
  :init #'harness-ui-tasks-search--init
  :shutdown #'harness-ui-tasks-search--shutdown)

(provide 'harness-ui-tasks-search)
;;; harness-ui-tasks-search.el ends here
