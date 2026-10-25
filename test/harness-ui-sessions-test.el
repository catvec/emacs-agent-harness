;;; harness-ui-sessions-test.el --- Tests for the session list  -*- lexical-binding: t; -*-

;;; Commentary:

;; The session list's project scope.  A task's session runs in a linked
;; git worktree under ROOT/.worktrees/ and has that worktree as its
;; `:project'; the list shows it with ROOT, the main checkout, resolved
;; once per root without running git.  Sessions go straight into the UI
;; cache; no harness or connection is needed.
;;
;; The tasks: a task's session is of kind task and shows its task's
;; title until it has a name.  The harness's answer to `_harness/task/list'
;; is `harness-ui-sessions-test--tasks'; events are run as the UI runs them.
;;
;; The filters and the pause: the internal sessions the list leaves out
;; and the filter of the tasks' sessions, then the pause that holds the
;; list still while the paths that follow the sessions go on.  Those tests
;; count the calls of `harness-ui-sessions--redraw'
;; (`harness-ui-sessions-test--counting-redraws') and let the timers run
;; (`harness-ui-sessions-test--spin').  One test fills the list with 300
;; sessions and reports how long a redraw takes.
;;
;; The marks: m, u, DEL, U and t on rows, in a list built by
;; `harness-ui-sessions-test--rows' and read back by
;; `harness-ui-sessions-test--starred'; the marks through redraws, filters
;; and the pause; and the commands that act on the marked sessions, with
;; the requests they send recorded in `harness-ui-sessions-test--requests'.
;;
;; The setting commands: the list names its target to them, the marked
;; sessions or the session at point, and the commands change the marked
;; sessions and their tasks.  The sessions have settings of their own
;; (`harness-ui-sessions-test--settings-rows'), the harness's answers are
;; named in `harness-ui-sessions-test--replies', and the supervisor
;; module is loaded for its command.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-ui)
(require 'harness-ui-sessions)
(require 'harness-ui-supervisor)

(defvar harness-ui--sessions)

(defvar harness-ui-sessions-test--tasks nil
  "What the harness answers `_harness/task/list' with: the tasks, or `fail'.")

(defvar harness-ui-sessions-test--requests nil
  "The requests the list sent the harness, newest first: (METHOD PARAMS).")

(defvar harness-ui-sessions-test--refused nil
  "Ids of the sessions the harness refuses to delete, in a test that has some.")

(defvar harness-ui-sessions-test--replies nil
  "What the harness answers requests with, in a test that sets some.
An alist (METHOD . ANSWER): ANSWER is the value the request resolves
with, a function of the request's params returning it, or `fail', which
rejects the request.  It wins over the answers the harness gives by
itself (`harness-ui-sessions-test--request').")

(defun harness-ui-sessions-test--request (method &optional params)
  "Answer METHOD with PARAMS as the harness would.
`_harness/task/list' is answered with the tasks.  An answer to what a
session waits on is taken, and so is a request to delete or deactivate a
session or make it a task, but for the sessions of
`harness-ui-sessions-test--refused', which cannot be deleted.  A
priority is set, for one session or for the ids of a filter, which
change.  So is a setting, for one session or for the ids of a filter
\(`session/set-all', `supervisor/set-all', `task/set-all' and
`handoff/switch-all' change them all); `handoff/check-all' finds no
conversation lost and `handoff/check' none.  What
`harness-ui-sessions-test--replies' names is answered as it says.
Anything else, or the tasks when they are `fail', fails.  Each request is
recorded in `harness-ui-sessions-test--requests'."
  (push (list method params) harness-ui-sessions-test--requests)
  (cond ((assoc method harness-ui-sessions-test--replies)
         (let ((reply (cdr (assoc method harness-ui-sessions-test--replies))))
           (cond ((eq reply 'fail)
                  (harness-rejected (list 'harness-error (format "%s failed" method))))
                 ((functionp reply) (harness-resolved (funcall reply params)))
                 (t (harness-resolved reply)))))
        ((and (equal method "_harness/task/list") (listp harness-ui-sessions-test--tasks))
         (harness-resolved harness-ui-sessions-test--tasks))
        ((and (equal method "_harness/session/delete")
              (member (plist-get params :id) harness-ui-sessions-test--refused))
         (harness-rejected (list 'harness-error "The session cannot be deleted")))
        ((member method '("_harness/permission/answer" "_harness/question/answer"
                          "_harness/task/adopt" "_harness/session/delete"
                          "_harness/session/deactivate"))
         (harness-resolved t))
        ((equal method "_harness/priority/set")
         (harness-resolved (plist-get params :priority)))
        ((equal method "_harness/priority/set-all")
         (harness-resolved (plist-get (plist-get params :filter) :ids)))
        ((member method '("_harness/session/set-all" "_harness/supervisor/set-all"
                          "_harness/task/set-all" "_harness/handoff/switch-all"))
         (harness-resolved (plist-get (plist-get params :filter) :ids)))
        ((equal method "_harness/handoff/check-all")
         (harness-resolved (mapcar (lambda (id) (list :id id :lossy :false))
                                   (plist-get (plist-get params :filter) :ids))))
        ((equal method "_harness/handoff/check")
         (harness-resolved (list :id (plist-get params :sessionId) :lossy :false)))
        ((member method '("_harness/session/update" "session/set_model" "session/set_mode"))
         (harness-resolved t))
        ((equal method "_harness/session/move")
         (harness-resolved (harness-plist-merge (harness-ui-session (plist-get params :id))
                                                (list :cwd (plist-get params :dir)
                                                      :project (plist-get params :project)))))
        (t (harness-rejected (list 'harness-error (format "%s: no such method" method))))))

(defun harness-ui-sessions-test--answers ()
  "Return the answers the list sent the harness, oldest first: (METHOD PARAMS)."
  (reverse (cl-remove "_harness/task/list" harness-ui-sessions-test--requests
                      :key #'car :test #'equal)))

(defun harness-ui-sessions-test--git (dir &rest args)
  "Run git ARGS synchronously in DIR; signal on failure."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (unless (zerop (apply #'call-process "git" nil t nil args))
        (error "git %s failed: %s" args (buffer-string))))))

(defmacro harness-ui-sessions-test-with-repo (&rest body)
  "Run BODY with a git repository at `root', a linked worktree of it at
`wt' (under ROOT/.worktrees/, where tasks work), an unrelated directory
`other' and an empty session cache.  The list never asks the harness."
  (declare (indent 0))
  `(let* ((base (file-name-as-directory (file-truename (harness-test-temp-dir))))
          (root (file-name-as-directory (expand-file-name "repo" base)))
          (wt (file-name-as-directory (expand-file-name ".worktrees/task-x" root)))
          (other (file-name-as-directory (expand-file-name "other" base))))
     (unwind-protect
         (progn
           (make-directory root t)
           (make-directory other t)
           (harness-ui-sessions-test--git root "init" "-q" "-b" "main")
           (harness-ui-sessions-test--git root "config" "user.name" "Harness Test")
           (harness-ui-sessions-test--git root "config" "user.email" "test@example.invalid")
           (harness-ui-sessions-test--git root "config" "commit.gpgsign" "false")
           (harness-ui-sessions-test--git root "commit" "-q" "--allow-empty" "-m" "initial")
           (harness-ui-sessions-test--git root "worktree" "add" "-q" "-b" "task/x" wt)
           (clrhash harness-ui--sessions)
           (cl-letf (((symbol-function 'harness-ui-refresh-sessions)
                      (lambda (&optional callback) (when callback (funcall callback nil))))
                     ((symbol-function 'harness-ui-request) #'harness-ui-sessions-test--request)
                     ;; The list shows in the selected window, as it does when
                     ;; it is opened: a list no window shows is not followed
                     ;; (`harness-ui-sessions-test--hide' hides it).
                     ((symbol-function 'harness-ui-display-view)
                      (lambda (buffer &rest _) (set-window-buffer (selected-window) buffer))))
             (let ((harness-ui-sessions-test--tasks nil)
                   (harness-ui-sessions-test--replies nil)
                   (harness-ui-sessions-test--requests nil))
               ,@body)))
       (clrhash harness-ui--sessions)
       (harness-ui-pending--forget-all)
       (when-let* ((buf (get-buffer harness-ui-sessions--buffer-name))) (kill-buffer buf))
       (ignore-errors (delete-directory base t)))))

(defun harness-ui-sessions-test--add (id project &rest props)
  "Cache a session ID whose project root is PROJECT, as the wire has it.
It is named ID unless PROPS, which go first, say otherwise."
  (puthash id (append props
                      (list :id id :name id :project project :cwd project :status "idle" :kind "main"
                            :model "demo:scripted" :permission-mode "auto" :usage (list :cost 0 :context 0)
                            :context-window 200000 :created (float-time) :updated (float-time)))
           harness-ui--sessions))

(defun harness-ui-sessions-test--shown ()
  "Return the sorted ids the list buffer shows."
  (with-current-buffer harness-ui-sessions--buffer-name
    (sort (mapcar #'car tabulated-list-entries) #'string<)))

(defun harness-ui-sessions-test--row (id)
  "Return (NAME KIND) as the list buffer shows session ID, as plain text."
  (with-current-buffer harness-ui-sessions--buffer-name
    (let ((columns (cadr (assoc id tabulated-list-entries))))
      (list (substring-no-properties (aref columns 1))
            (substring-no-properties (aref columns 3))))))

(defun harness-ui-sessions-test--cell (id column)
  "Return the plain text of COLUMN in session ID's row, or nil without one."
  (with-current-buffer harness-ui-sessions--buffer-name
    (let* ((columns (cadr (assoc id tabulated-list-entries)))
           (at (and columns (cl-position column tabulated-list-format
                                         :key #'car :test #'equal))))
      (and at (substring-no-properties (aref columns at))))))

(defun harness-ui-sessions-test--raw-cell (id column)
  "Return COLUMN in session ID's row with its text properties, or nil.
Nil when the row has no such column, as when the list hides it."
  (with-current-buffer harness-ui-sessions--buffer-name
    (let* ((columns (cadr (assoc id tabulated-list-entries)))
           (at (and columns (cl-position column tabulated-list-format
                                         :key #'car :test #'equal))))
      (and at (aref columns at)))))

(defun harness-ui-sessions-test--help (id column)
  "Return the tooltip of COLUMN in session ID's row, or nil without one.
A tooltip made when it is hovered is a function; it is asked as Emacs asks it."
  (when-let* ((cell (harness-ui-sessions-test--raw-cell id column)))
    (let ((help (get-text-property 0 'help-echo cell)))
      (if (functionp help)
          (funcall help (selected-window) harness-ui-sessions--buffer-name 0)
        help))))

(defun harness-ui-sessions-test--column (name)
  "Return the format entry of column NAME, or nil when the list hides it."
  (with-current-buffer harness-ui-sessions--buffer-name
    (cl-find name tabulated-list-format :key #'car :test #'equal)))

(defun harness-ui-sessions-test--names ()
  "Return the names of the columns the list shows, in order."
  (with-current-buffer harness-ui-sessions--buffer-name
    (mapcar #'car tabulated-list-format)))

(defun harness-ui-sessions-test--header-text ()
  "Return the text of the list's header line, without properties.
\(`format-mode-line' formats nothing in batch.)"
  (with-current-buffer harness-ui-sessions--buffer-name
    (substring-no-properties (car (last header-line-format)))))

(defun harness-ui-sessions-test--row-start (id)
  "Return (CHAR . ID): the first character of session ID's row, and the id there."
  (with-current-buffer harness-ui-sessions--buffer-name
    (let ((at (harness-ui-sessions--position id)))
      (cons (char-after at) (tabulated-list-get-id at)))))

(defun harness-ui-sessions-test--arrow-position (id)
  "Return the buffer position of the priority arrow in session ID's row."
  (with-current-buffer harness-ui-sessions--buffer-name
    (let ((start (harness-ui-sessions--position id))
          (end (save-excursion (goto-char (harness-ui-sessions--position id))
                               (line-end-position)))
          (glyphs (list (harness-ui-icon 'harness-icon-priority-high)
                        (harness-ui-icon 'harness-icon-priority-low)))
          found)
      (dolist (glyph glyphs)
        (save-excursion
          (goto-char start)
          (when (search-forward glyph end t) (setq found (match-beginning 0)))))
      found)))

(defun harness-ui-sessions-test--message (thunk)
  "Call THUNK and return the message it showed, or nil."
  (let (said)
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args)
                 (setq said (apply #'format format-string args)))))
      (funcall thunk))
    said))

(defun harness-ui-sessions-test--messages (thunk)
  "Call THUNK and return all the messages it showed, oldest first."
  (let (said)
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args)
                 (when format-string
                   (push (apply #'format format-string args) said)))))
      (funcall thunk))
    (nreverse said)))

(defun harness-ui-sessions-test--blocked (id project kind &rest props)
  "Cache a session ID in PROJECT blocked on a request of KIND, as the wire has it.
KIND is \"permission\", for a shell command, or \"question\"; the
request's id is ID-p or ID-q.  PROPS go first."
  (apply #'harness-ui-sessions-test--add id project
         (append props
                 (list :status "blocked"
                       :pending (list (if (equal kind "question")
                                          (list :id (concat id "-q") :kind "question"
                                                :payload (list :question "Which colour?\nThe second line"
                                                               :options '("red" "green")))
                                        (list :id (concat id "-p") :kind "permission"
                                              :payload (list :title "Bash: rm -rf build/" :tool "bash"
                                                             :options '("allow-once" "allow-session"
                                                                        "deny-once")))))))))

(defun harness-ui-sessions-test--text ()
  "Return the text of the list buffer, without properties."
  (with-current-buffer harness-ui-sessions--buffer-name
    (buffer-substring-no-properties (point-min) (point-max))))

(defun harness-ui-sessions-test--mode-line ()
  "Return the text of the list's mode line, without properties.
That is the pause button, then what it says of the scope and the filters."
  (with-current-buffer harness-ui-sessions--buffer-name
    (substring-no-properties mode-line-process)))

(defun harness-ui-sessions-test--spin (seconds)
  "Spin the event loop for SECONDS, so the timers due by then run."
  (let ((deadline (+ (float-time) seconds)))
    (while (< (float-time) deadline)
      (accept-process-output nil 0.02))))

(defun harness-ui-sessions-test--hide ()
  "Show another buffer wherever the list shows, so no window shows the list."
  (dolist (window (get-buffer-window-list harness-ui-sessions--buffer-name nil t))
    (set-window-buffer window (get-buffer-create " *harness-ui-sessions-test-other*"))))

(defun harness-ui-sessions-test--show ()
  "Show the list in the selected window, and do what showing it does.
Redisplay does not run in a batch test, so the hook that a window which
got a buffer makes it run (`window-buffer-change-functions', the list's
own, `harness-ui-view--shown') is run by hand, once it is seen to be
there."
  (let ((buffer (get-buffer harness-ui-sessions--buffer-name)))
    (set-window-buffer (selected-window) buffer)
    (with-current-buffer buffer
      (should (memq #'harness-ui-view--shown window-buffer-change-functions))
      (harness-ui-view--shown (selected-window)))))

(defmacro harness-ui-sessions-test--counting-redraws (var &rest body)
  "Run BODY with VAR counting the calls of `harness-ui-sessions--redraw'."
  (declare (indent 1))
  `(let ((,var 0))
     (advice-add 'harness-ui-sessions--redraw :before (lambda () (cl-incf ,var))
                 '((name . harness-ui-sessions-test-count)))
     (unwind-protect (progn ,@body)
       (advice-remove 'harness-ui-sessions--redraw 'harness-ui-sessions-test-count))))

(defun harness-ui-sessions-test--goto (id)
  "Put point on the row of session ID in the current buffer, the list."
  (goto-char (harness-ui-sessions--position id))
  (should (equal id (tabulated-list-get-id))))

(defun harness-ui-sessions-test--line (id)
  "Return the line under the row of session ID, as plain text, or nil.
Only a line of the session's own: the one saying what it waits on."
  (with-current-buffer harness-ui-sessions--buffer-name
    (save-excursion
      (harness-ui-sessions-test--goto id)
      (forward-line 1)
      (when (and (not (eobp)) (equal id (tabulated-list-get-id)))
        (buffer-substring-no-properties (line-beginning-position) (line-end-position))))))

(defmacro harness-ui-sessions-test--with-init (&rest body)
  "Run BODY with the list's module started, its hooks kept to BODY."
  (declare (indent 0))
  `(let ((harness-ui-event-functions nil)
         (harness-ui-redraw-hook nil)
         (harness-ui-sessions-changed-hook nil)
         (harness-ui-pending-changed-hook nil)
         (harness-ui-rate-functions nil)
         (harness-ui-live-functions nil))
     (harness-ui-sessions--init)
     (unwind-protect
         (progn ,@body)
       ;; No redraw left to fire in a test that follows.
       (harness-ui-sessions--drop-pending-redraws))))

(ert-deftest harness-ui-sessions-show-token-figures ()
  "The Context and Output columns show each session's token figures.
They sort by the figures.  A running session's grow as its model
streams: the list redraws for them at most every half second, all the
sessions that grew at once, and not at all while they read the same.
They do not drop when the count ends before the session's new totals
arrive."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--with-init
      (let ((harness-ui--live (make-hash-table :test 'equal))
            ;; Output is left out by default; this test reads it.
            (harness-ui-sessions-hidden-columns nil)
            (redraws 0))
        (harness-ui-sessions-test--add "busy" root :status "running"
                                       :usage (list :cost 0 :context 1000 :last-output 200 :output 300))
        (harness-ui-sessions-test--add "quiet" root :usage (list :cost 0 :context 50000 :output 9000))
        (harness-ui-sessions-test--add "fresh" root)
        (let ((default-directory root)) (harness-sessions))
        (advice-add 'harness-ui-sessions--redraw :before (lambda () (cl-incf redraws))
                    '((name . harness-ui-sessions-test-count)))
        (unwind-protect
            (with-current-buffer harness-ui-sessions--buffer-name
              (let* ((column (lambda (name) (cl-position name tabulated-list-format :key #'car :test #'equal)))
                     (cell (lambda (id name)
                             (substring-no-properties
                              (aref (cadr (assoc id tabulated-list-entries)) (funcall column name)))))
                     (sorted (lambda (name)
                               (mapcar #'car (sort (copy-sequence tabulated-list-entries)
                                                   (nth 2 (aref tabulated-list-format (funcall column name))))))))
                (should (equal "1.2k/200k" (funcall cell "busy" "Context")))
                (should (equal "300" (funcall cell "busy" "Output")))
                (should (equal "50.0k/200k" (funcall cell "quiet" "Context")))
                (should (equal "9.0k" (funcall cell "quiet" "Output")))
                (should (equal "0/200k" (funcall cell "fresh" "Context")))
                (should (equal "" (funcall cell "fresh" "Output")))
                (should (equal '("fresh" "busy" "quiet") (funcall sorted "Context")))
                (should (equal '("fresh" "busy" "quiet") (funcall sorted "Output")))
                ;; The count grows: one redraw, half a second later.
                (harness-ui--store-live "busy" '(:context 1700 :output 800 :estimated 500))
                (let ((timer harness-ui-sessions--live-timer))
                  (should (timerp timer))
                  (harness-ui--store-live "busy" '(:context 1900 :output 1000 :estimated 700))
                  (should (eq timer harness-ui-sessions--live-timer)))
                (should (equal "1.2k/200k" (funcall cell "busy" "Context")))
                (should (= 0 redraws))
                (harness-test-wait (lambda () (equal "~1.0k" (funcall cell "busy" "Output")))
                                   5 "the list to show the live count")
                (should (= 1 redraws))
                (should (equal "~1.9k/200k" (funcall cell "busy" "Context")))
                (should-not harness-ui-sessions--live-timer)
                ;; It sorts by the live figures.
                (harness-ui--store-live "busy" '(:context 60000 :output 10000 :estimated 0))
                (harness-test-wait (lambda () (equal "10.0k" (funcall cell "busy" "Output")))
                                   5 "the list to show the reported count")
                (should (equal '("fresh" "quiet" "busy") (funcall sorted "Context")))
                (should (equal '("fresh" "quiet" "busy") (funcall sorted "Output")))
                ;; Figures that read the same redraw nothing.
                (setq redraws 0)
                (harness-ui--store-live "busy" '(:context 60010 :output 10010 :estimated 0))
                (should-not harness-ui-sessions--live-timer)
                ;; The count ends before the totals come: the figures stay.
                (harness-ui--store-live "busy" nil)
                (should-not harness-ui-sessions--live-timer)
                (should (equal "10.0k" (funcall cell "busy" "Output")))
                (should (equal '(:context 60010 :output 10010 :estimated 0)
                               (harness-ui-session-tokens (harness-ui-session "busy"))))
                (should (= 0 redraws))
                ;; The totals come with the session idle, and count from then on.
                (harness-ui-cache-session (append (list :status "idle"
                                                        :usage (list :cost 0 :context 61000 :last-output 1200
                                                                     :output 10200))
                                                  (harness-ui-session "busy")))
                (should-not (gethash "busy" harness-ui--live))
                (harness-test-wait (lambda () (equal "62.2k/200k" (funcall cell "busy" "Context")))
                                   5 "the list to show the totals")
                (should (equal "10.2k" (funcall cell "busy" "Output")))))
          (advice-remove 'harness-ui-sessions--redraw 'harness-ui-sessions-test-count))))))

(ert-deftest harness-ui-sessions-show-average-output-rates ()
  "The Avg tok/s column shows each session's average output rate and sorts by it.
The average is the output tokens of the model calls the harness timed
over the seconds they streamed, the totals in the session's usage: none
without them or under a second of streaming.  It is not dimmed once the
session is idle.  Its tooltip says it is the average of the whole
session, not the current rate, which it names beside it once the
harness measured one; a new rate and new totals redraw the list."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--with-init
      (let ((harness-ui--rates (make-hash-table :test 'equal)))
        (harness-ui-sessions-test--add "fast" root :status "running" :updated 400
                                       :usage (list :cost 0 :context 0
                                                    :stream-output 1200 :stream-seconds 20.0))
        (harness-ui-sessions-test--add "slow" root :updated 300
                                       :usage (list :cost 0 :context 0
                                                    :stream-output 600 :stream-seconds 100.0))
        (harness-ui-sessions-test--add "brief" root :updated 200
                                       :usage (list :cost 0 :context 0
                                                    :stream-output 30 :stream-seconds 0.5))
        (harness-ui-sessions-test--add "never" root :updated 100)
        (puthash "fast" '(:rate 61.4 :output 600 :seconds 9.8 :calls 2 :at 1000.0 :model "demo:scripted")
                 harness-ui--rates)
        (let ((default-directory root)) (harness-sessions))
        ;; It replaces the column of the current rate.
        (should-not (harness-ui-sessions-test--column "Tok/s"))
        (should (= 9 (nth 1 (harness-ui-sessions-test--column "Avg tok/s"))))
        (should (plist-get (nthcdr 3 (harness-ui-sessions-test--column "Avg tok/s")) :right-align))
        (should (equal "60" (harness-ui-sessions-test--cell "fast" "Avg tok/s")))
        (should (equal "6.0" (harness-ui-sessions-test--cell "slow" "Avg tok/s")))
        ;; None without totals, or with under a second of streaming.
        (should (equal "" (harness-ui-sessions-test--cell "brief" "Avg tok/s")))
        (should (equal "" (harness-ui-sessions-test--cell "never" "Avg tok/s")))
        ;; An idle session's average is no last figure to dim.
        (should-not (get-text-property 0 'face (harness-ui-sessions-test--raw-cell "slow" "Avg tok/s")))
        ;; The tooltip speaks of the average of the whole session, and of
        ;; no current rate while none was measured.
        (let ((help (harness-ui-sessions-test--help "slow" "Avg tok/s")))
          (should (string-prefix-p (concat "Average output rate over the whole session: 6.0 tokens per second,"
                                           " 600 output tokens in 1m40s of streaming, not the current rate. ")
                                   help))
          (should-not (string-match-p "measured at" help)))
        ;; With one measured, it follows as the current rate.
        (should (string-prefix-p (concat "Average output rate over the whole session: 60 tokens per second,"
                                         " 1.2k output tokens in 20.0s of streaming, not the current rate."
                                         " Output rate: 61 tokens per second, 600 output tokens in 9.8s"
                                         " of streaming over the 2 latest model calls")
                                 (harness-ui-sessions-test--help "fast" "Avg tok/s")))
        ;; Sorting puts the sessions without an average first, the fastest last.
        (with-current-buffer harness-ui-sessions--buffer-name
          (should (equal '("brief" "never" "slow" "fast")
                         (mapcar #'car (sort (copy-sequence tabulated-list-entries)
                                             (nth 2 (harness-ui-sessions-test--column "Avg tok/s")))))))
        ;; A rate from the harness redraws the list: an idle session's
        ;; tooltip names it as the last one measured.
        (harness-ui--store-rate "slow" '(:rate 120.0 :output 1200 :seconds 10.0 :calls 1
                                         :at 1100.0 :model "demo:scripted"))
        (harness-test-wait (lambda () (string-match-p "Last output rate: 120 tokens per second"
                                                      (harness-ui-sessions-test--help "slow" "Avg tok/s")))
                           5 "the list to name the new rate")
        ;; So do new totals.
        (harness-ui-cache-session (append (list :usage (list :cost 0 :context 0
                                                             :stream-output 1200 :stream-seconds 100.0))
                                          (harness-ui-session "slow")))
        (harness-test-wait (lambda () (equal "12" (harness-ui-sessions-test--cell "slow" "Avg tok/s")))
                           5 "the list to show the new average")))))

;;;; Columns

(ert-deftest harness-ui-sessions-have-the-columns-of-the-spec ()
  "The header has the columns of the spec, and the rows hold their cells.
Avg tok/s, Think and Last msg are there and Tok/s and Updated are not;
Mode and Output are left out by default and come back when the option
does not name them.  The status icon column always shows."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "main" root)
    (let ((default-directory root)) (harness-sessions))
    (let ((shown '("" "Name" "Status" "Kind" "Model" "Think" "Priority" "Context"
                   "Avg tok/s" "Cost" "Last msg")))
      (should (equal shown (harness-ui-sessions-test--names)))
      (with-current-buffer harness-ui-sessions--buffer-name
        ;; A cell for each, in the same order.
        (should (= (length shown) (length (cadr (assoc "main" tabulated-list-entries)))))
        (should (equal "main" (harness-ui-sessions-test--cell "main" "Name")))
        ;; The header line names them too.
        (should (string-match-p "Think.*Priority.*Context.*Avg tok/s.*Cost.*Last msg"
                                (harness-ui-sessions-test--header-text)))
        (let ((case-fold-search nil))
          (should-not (string-match-p "\\<\\(Mode\\|Output\\|Updated\\|Tok/s\\|Project\\)\\>"
                                      (harness-ui-sessions-test--header-text))))))
    (should (equal '(("Model" . 22) ("Think" . 7) ("Avg tok/s" . 9) ("Last msg" . 9))
                   (mapcar (lambda (name) (cons name (nth 1 (harness-ui-sessions-test--column name))))
                           '("Model" "Think" "Avg tok/s" "Last msg"))))
    (should-not (harness-ui-sessions-test--column "Tok/s"))
    (should-not (harness-ui-sessions-test--column "Updated"))
    (should-not (harness-ui-sessions-test--cell "main" "Mode"))
    (should-not (harness-ui-sessions-test--cell "main" "Output"))
    ;; The option names the columns left out; a change of it shows at the
    ;; next redraw, the header with it.
    (let ((harness-ui-sessions-hidden-columns nil))
      (harness-ui-sessions--redraw))
    (should (equal '("" "Name" "Status" "Kind" "Model" "Think" "Mode" "Priority" "Context"
                     "Output" "Avg tok/s" "Cost" "Last msg")
                   (harness-ui-sessions-test--names)))
    (should (equal "Auto" (harness-ui-sessions-test--cell "main" "Mode")))
    (should (string-match-p "Think.*Mode.*Priority.*Context.*Output.*Avg tok/s"
                            (harness-ui-sessions-test--header-text)))
    (let ((harness-ui-sessions-hidden-columns '("Name" "Cost")))
      (harness-ui-sessions--redraw))
    (should (equal '("" "Status" "Kind" "Model" "Think" "Mode" "Priority" "Context" "Output"
                     "Avg tok/s" "Last msg")
                   (harness-ui-sessions-test--names)))
    ;; A sort by a column that is not shown ends at the next redraw.
    (let ((harness-ui-sessions-hidden-columns nil))
      (harness-ui-sessions--redraw))
    (with-current-buffer harness-ui-sessions--buffer-name
      (setq tabulated-list-sort-key (cons "Output" t))
      (tabulated-list-init-header)
      (should (string-match-p "Output" (harness-ui-sessions-test--header-text))))
    (harness-ui-sessions--redraw)
    (should-not (harness-ui-sessions-test--column "Output"))
    (should-not (buffer-local-value 'tabulated-list-sort-key
                                    (get-buffer harness-ui-sessions--buffer-name)))
    (let ((case-fold-search nil))
      (should-not (string-match-p "Output" (harness-ui-sessions-test--header-text))))
    ;; The status icon is not a column to leave out, whatever the option says.
    (let ((harness-ui-sessions-hidden-columns '("")))
      (harness-ui-sessions--redraw))
    (should (equal "" (car (harness-ui-sessions-test--names))))
    (should (= (length (harness-ui-sessions-test--names))
               (length (cadr (assoc "main" (buffer-local-value 'tabulated-list-entries
                                                               (get-buffer harness-ui-sessions--buffer-name)))))))))

(ert-deftest harness-ui-sessions-project-column-is-for-all-projects ()
  "The Project column shows in the list of all projects only.
In one project's list it says the same on every row.  The scope decides
at the next redraw, whatever the option says."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "main" root)
    (harness-ui-sessions-test--add "elsewhere" other)
    (let ((default-directory root)) (harness-sessions))
    (should-not (harness-ui-sessions-test--column "Project"))
    (should-not (harness-ui-sessions-test--cell "main" "Project"))
    (with-current-buffer harness-ui-sessions--buffer-name
      (harness-ui-sessions-toggle-scope))
    (should (equal "Project" (car (last (harness-ui-sessions-test--names)))))
    (should (equal "repo" (harness-ui-sessions-test--cell "main" "Project")))
    (should (equal "other" (harness-ui-sessions-test--cell "elsewhere" "Project")))
    (should (string-match-p "Last msg.*Project" (harness-ui-sessions-test--header-text)))
    ;; The option hides it there too, and back in one project's list the
    ;; header is without it again.
    (let ((harness-ui-sessions-hidden-columns '("Project")))
      (harness-ui-sessions--redraw))
    (should-not (harness-ui-sessions-test--column "Project"))
    (should-not (string-match-p "Project" (harness-ui-sessions-test--header-text)))
    (harness-ui-sessions--redraw)
    (should (harness-ui-sessions-test--column "Project"))
    (with-current-buffer harness-ui-sessions--buffer-name
      (harness-ui-sessions-toggle-scope))
    (should-not (harness-ui-sessions-test--column "Project"))
    (should-not (string-match-p "Project" (harness-ui-sessions-test--header-text)))
    (should (equal '("main") (harness-ui-sessions-test--shown)))
    ;; A list opened for every project shows it from the start.
    (let ((default-directory root)) (harness-sessions t))
    (should (harness-ui-sessions-test--column "Project"))
    (should (equal "other" (harness-ui-sessions-test--cell "elsewhere" "Project")))))

(ert-deftest harness-ui-sessions-toggle-column-shows-or-hides-one-here ()
  "C asks for a column, noting which are shown, and shows or hides it here.
The option stays as it is, and from the first toggle on the list keeps
its own choice, whatever the option becomes.  A sort by a column that
goes ends; one by a column that stays does not."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "main" root)
    (let ((default-directory root)) (harness-sessions))
    (let (asked answer)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt table &rest _) (setq asked (list prompt table)) answer)))
        (with-current-buffer harness-ui-sessions--buffer-name
          (should (eq 'harness-ui-sessions-toggle-column (key-binding (kbd "C"))))
          (should-not (local-variable-p 'harness-ui-sessions--hidden-columns))
          ;; Mode is hidden by default: C shows it.
          (setq answer "Mode")
          (call-interactively (key-binding (kbd "C")))
          (should (equal "Show or hide column: " (car asked)))
          (should (equal '("Name" "Status" "Kind" "Model" "Think" "Mode" "Priority" "Context"
                           "Output" "Avg tok/s" "Cost" "Last msg" "Project")
                         (all-completions "" (cadr asked))))
          (let ((note (completion-metadata-get (completion-metadata "" (cadr asked) nil)
                                               'annotation-function)))
            (should (string-match-p "hidden" (funcall note "Mode")))
            (should (string-match-p "hidden" (funcall note "Output")))
            (should (string-match-p "hidden" (funcall note "Project")))
            (should (string-match-p "shown" (funcall note "Name")))
            (should (string-match-p "shown" (funcall note "Avg tok/s"))))
          (should (member "Mode" (harness-ui-sessions-test--names)))
          (should (equal "Auto" (harness-ui-sessions-test--cell "main" "Mode")))
          ;; Only this list's: the option is as it was.
          (should (equal '("Mode" "Output") (default-value 'harness-ui-sessions-hidden-columns)))
          (should (local-variable-p 'harness-ui-sessions--hidden-columns))
          ;; Again, and Mode is hidden.
          (call-interactively (key-binding (kbd "C")))
          (should-not (member "Mode" (harness-ui-sessions-test--names)))
          (let ((note (completion-metadata-get (completion-metadata "" (cadr asked) nil)
                                               'annotation-function)))
            (should (string-match-p "shown" (funcall note "Mode"))))
          ;; A sort by a column that stays survives a toggle; one by the
          ;; column that goes ends, and the list prints on.
          (setq tabulated-list-sort-key (cons "Context" nil))
          (tabulated-list-init-header)
          (setq answer "Kind")
          (call-interactively (key-binding (kbd "C")))
          (should-not (member "Kind" (harness-ui-sessions-test--names)))
          (should (equal '("Context") tabulated-list-sort-key))
          (setq tabulated-list-sort-key (cons "Cost" t))
          (setq answer "Cost")
          (call-interactively (key-binding (kbd "C")))
          (should-not (member "Cost" (harness-ui-sessions-test--names)))
          (should-not tabulated-list-sort-key)
          (should (equal '("main") (harness-ui-sessions-test--shown)))
          ;; The list's own choice holds whatever the option becomes.
          (let ((harness-ui-sessions-hidden-columns '("Think")))
            (harness-ui-sessions--redraw))
          (should (member "Think" (harness-ui-sessions-test--names)))
          (should-not (member "Output" (harness-ui-sessions-test--names)))
          (should-not (member "Kind" (harness-ui-sessions-test--names)))
          (should-not (member "Cost" (harness-ui-sessions-test--names)))
          ;; The status icon is not offered, and nothing else is made up.
          (should-error (harness-ui-sessions-toggle-column "") :type 'user-error)
          (should-error (harness-ui-sessions-toggle-column "Tok/s") :type 'user-error)
          ;; The project's list has no Project column to show: it says so.
          (should (string-match-p "only when the list covers all projects"
                                  (harness-ui-sessions-test--message
                                   (lambda () (harness-ui-sessions-toggle-column "Project")))))
          (should-not (member "Project" (harness-ui-sessions-test--names)))
          (harness-ui-sessions-toggle-scope)
          (should-not (member "Project" (harness-ui-sessions-test--names)))
          (harness-ui-sessions-toggle-column "Project")
          (should (member "Project" (harness-ui-sessions-test--names))))))))

(ert-deftest harness-ui-sessions-show-the-thinking-level ()
  "The Think column shows a session's thinking level as plain text.
A session without one thinks as its model does by default, and its cell
is empty.  A level has a tooltip naming it and the command that changes
it.  The column sorts by the level's place in the order of strength, the
sessions without a level, or with one that order does not know, first."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "deep" root :thinking "xhigh" :updated 500)
    (harness-ui-sessions-test--add "sharp" root :thinking "high" :updated 450)
    (harness-ui-sessions-test--add "light" root :thinking "low" :updated 400)
    (harness-ui-sessions-test--add "plain" root :updated 300)
    (harness-ui-sessions-test--add "odd" root :thinking "bespoke" :updated 200)
    (harness-ui-sessions-test--add "top" root :thinking "max" :updated 100)
    (let ((default-directory root)) (harness-sessions))
    (should (equal "xhigh" (harness-ui-sessions-test--cell "deep" "Think")))
    (should (equal "high" (harness-ui-sessions-test--cell "sharp" "Think")))
    (should (equal "low" (harness-ui-sessions-test--cell "light" "Think")))
    (should (equal "max" (harness-ui-sessions-test--cell "top" "Think")))
    (should (equal "" (harness-ui-sessions-test--cell "plain" "Think")))
    (should-not (harness-ui-sessions-test--help "plain" "Think"))
    ;; The cell is right after the model's.
    (should (equal "Think" (nth (1+ (cl-position "Model" (harness-ui-sessions-test--names) :test #'equal))
                                (harness-ui-sessions-test--names))))
    (let ((help (harness-ui-sessions-test--help "deep" "Think")))
      (should (string-match-p "\\`Thinking level: xhigh" help))
      (should (string-match-p "harness-set-thinking" help))
      (should-not (string-match-p "\n" help)))
    (with-current-buffer harness-ui-sessions--buffer-name
      (should (equal '("plain" "odd" "light" "sharp" "deep" "top")
                     (mapcar #'car (sort (copy-sequence tabulated-list-entries)
                                         (nth 2 (harness-ui-sessions-test--column "Think")))))))))

(ert-deftest harness-ui-sessions-show-when-the-last-message-came ()
  "The Last msg column is how long ago a session's last message came.
That is a user or assistant message, which can be an hour older than the
session's last change of any kind.  A record from before the harness
kept that falls back to the last change, and its tooltip says so.  The
column sorts by the same time, and the rows stay in the order of the
last change."
  (harness-ui-sessions-test-with-repo
    (let ((now (float-time)))
      ;; Changed 10 minutes ago, its last message an hour before that.
      (harness-ui-sessions-test--add "quiet" root :updated (- now 600) :last-message (- now 4200))
      ;; No message time recorded: its last change stands in.
      (harness-ui-sessions-test--add "old" root :updated (- now 1200))
      ;; Changed a while ago, wrote a minute ago.
      (harness-ui-sessions-test--add "fresh" root :updated (- now 1800) :last-message (- now 120))
      (let ((default-directory root)) (harness-sessions))
      (should-not (harness-ui-sessions-test--column "Updated"))
      (should (equal "1h ago" (harness-ui-sessions-test--cell "quiet" "Last msg")))
      (should (equal "20m ago" (harness-ui-sessions-test--cell "old" "Last msg")))
      (should (equal "2m ago" (harness-ui-sessions-test--cell "fresh" "Last msg")))
      (should (string-prefix-p "Last user or assistant message: "
                               (harness-ui-sessions-test--help "quiet" "Last msg")))
      (should (string-suffix-p (format-time-string "%F %H:%M" (- now 4200))
                               (harness-ui-sessions-test--help "quiet" "Last msg")))
      (let ((help (harness-ui-sessions-test--help "old" "Last msg")))
        (should (string-match-p "\\`No message time is recorded for this session" help))
        (should (string-suffix-p (format-time-string "%F %H:%M" (- now 1200)) help)))
      ;; The rows keep the order of the last change; the column sorts by
      ;; the last message, oldest first.
      (with-current-buffer harness-ui-sessions--buffer-name
        (should (equal '("quiet" "old" "fresh") (mapcar #'car tabulated-list-entries)))
        (should (equal '("quiet" "old" "fresh")
                       (mapcar #'car (sort (copy-sequence tabulated-list-entries)
                                           (nth 2 (harness-ui-sessions-test--column "Last msg"))))))
        (should (equal '("fresh" "old" "quiet")
                       (mapcar #'car (sort (copy-sequence tabulated-list-entries)
                                           (lambda (a b) (funcall (nth 2 (harness-ui-sessions-test--column "Last msg"))
                                                                  b a))))))))))

(ert-deftest harness-ui-sessions-show-the-marks ()
  "A marked session's row starts with a * in place of the padding space.
The row keeps its text properties, so the start of the line is still on
its session, and point stays there over a redraw.  Marks survive
redraws, an unmarked row starts with a space, and so does the line under
a blocked session's row, marked or not."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "plain" root :updated 300)
    (harness-ui-sessions-test--blocked "asks" root "permission" :updated 200)
    (harness-ui-sessions-test--add "child" root :parent-id "plain" :updated 100)
    (let ((default-directory root)) (harness-sessions))
    (with-current-buffer harness-ui-sessions--buffer-name
      (should (hash-table-p harness-ui-sessions--marked))
      (should (equal (cons ?\s "plain") (harness-ui-sessions-test--row-start "plain")))
      (let ((before (progn (harness-ui-sessions-test--goto "asks")
                           (buffer-substring-no-properties (line-beginning-position) (line-end-position))))
            (under (harness-ui-sessions-test--line "asks")))
        (puthash "asks" t harness-ui-sessions--marked)
        (puthash "child" t harness-ui-sessions--marked)
        (harness-ui-sessions--redraw)
        (should (equal (cons ?* "asks") (harness-ui-sessions-test--row-start "asks")))
        (should (equal (cons ?* "child") (harness-ui-sessions-test--row-start "child")))
        (should (equal (cons ?\s "plain") (harness-ui-sessions-test--row-start "plain")))
        (should (eq 'harness-ui-sessions-mark-face
                    (get-text-property (harness-ui-sessions--position "asks") 'face)))
        ;; Nothing else of the row changed, and point is on it still.
        (should (equal "asks" (tabulated-list-get-id)))
        (should (equal (concat "*" (substring before 1))
                       (buffer-substring-no-properties (line-beginning-position) (line-end-position))))
        (should (equal "asks" (tabulated-list-get-id (line-beginning-position))))
        (should (equal "asks" (tabulated-list-get-id (1+ (line-beginning-position)))))
        (should (tabulated-list-get-entry (line-beginning-position)))
        ;; The line under a blocked session's row is not marked.
        (should (equal under (harness-ui-sessions-test--line "asks")))
        (should (string-prefix-p " " (harness-ui-sessions-test--line "asks")))
        ;; Marks outlive redraws, and unmarking takes the mark away.
        (harness-ui-sessions--redraw)
        (should (equal (cons ?* "asks") (harness-ui-sessions-test--row-start "asks")))
        (remhash "asks" harness-ui-sessions--marked)
        (harness-ui-sessions--redraw)
        (should (equal (cons ?\s "asks") (harness-ui-sessions-test--row-start "asks")))
        (should (equal before (progn (harness-ui-sessions-test--goto "asks")
                                     (buffer-substring-no-properties (line-beginning-position)
                                                                     (line-end-position)))))
        (should (equal (cons ?* "child") (harness-ui-sessions-test--row-start "child")))))))

(ert-deftest harness-ui-sessions-redraw-for-the-token-cells-shown ()
  "A session's growing token figures redraw the list for the cells it shows.
Output is left out by default, so a count that grows in output alone
leaves the list as it is, and one that grows the context redraws it;
with Context left out as well nothing redraws for either."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--with-init
      (let ((harness-ui--live (make-hash-table :test 'equal)))
        (harness-ui-sessions-test--add "busy" root :status "running"
                                       :usage (list :cost 0 :context 1000 :last-output 200 :output 300))
        (let ((default-directory root)) (harness-sessions))
        ;; The count of 1.2k context, as the totals have it, writes more.
        (harness-ui--store-live "busy" '(:context 1200 :output 900 :estimated 0))
        (should (harness-ui-sessions--tokens-shown-p "busy"))
        (should-not harness-ui-sessions--live-timer)
        ;; The context grows: the list redraws soon.
        (harness-ui--store-live "busy" '(:context 5000 :output 900 :estimated 0))
        (should-not (harness-ui-sessions--tokens-shown-p "busy"))
        (should (timerp harness-ui-sessions--live-timer))
        (harness-test-wait (lambda () (equal "5.0k/200k" (harness-ui-sessions-test--cell "busy" "Context")))
                           5 "the list to show the context")
        (should (harness-ui-sessions--tokens-shown-p "busy"))
        ;; With only Output shown, the output decides.
        (let ((harness-ui-sessions-hidden-columns '("Context")))
          (harness-ui-sessions--redraw))
        (should (equal "900" (harness-ui-sessions-test--cell "busy" "Output")))
        (harness-ui--store-live "busy" '(:context 9000 :output 900 :estimated 0))
        (should (harness-ui-sessions--tokens-shown-p "busy"))
        (harness-ui--store-live "busy" '(:context 9000 :output 1500 :estimated 0))
        (should-not (harness-ui-sessions--tokens-shown-p "busy"))
        ;; With neither shown there is nothing to redraw for.
        (let ((harness-ui-sessions-hidden-columns '("Context" "Output")))
          (harness-ui-sessions--redraw))
        (should (harness-ui-sessions--tokens-shown-p "busy"))
        (harness-ui--store-live "busy" '(:context 90000 :output 15000 :estimated 0))
        (should (harness-ui-sessions--tokens-shown-p "busy"))))))

(ert-deftest harness-ui-sessions-project-includes-its-worktrees ()
  "A task's session in a worktree is listed with its project, not another's."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "main" root)
    (harness-ui-sessions-test--add "task" wt)
    (harness-ui-sessions-test--add "elsewhere" other)
    (let ((default-directory root)) (harness-sessions))
    (should (equal '("main" "task") (harness-ui-sessions-test--shown)))
    ;; `a' toggles every project, and back.
    (with-current-buffer harness-ui-sessions--buffer-name
      (harness-ui-sessions-toggle-scope)
      (should (equal '("elsewhere" "main" "task") (harness-ui-sessions-test--shown)))
      (harness-ui-sessions-toggle-scope)
      (should (equal '("main" "task") (harness-ui-sessions-test--shown))))
    ;; The other project's list has only its own session.
    (let ((default-directory other)) (harness-sessions))
    (should (equal '("elsewhere") (harness-ui-sessions-test--shown)))
    ;; A task created while the list is open shows on the next redraw.
    (let ((default-directory root)) (harness-sessions))
    (let ((wt2 (file-name-as-directory (expand-file-name ".worktrees/task-y" root))))
      (harness-ui-sessions-test--git root "worktree" "add" "-q" "-b" "task/y" wt2)
      (harness-ui-sessions-test--add "task-2" wt2))
    (harness-ui-sessions--redraw)
    (should (equal '("main" "task" "task-2") (harness-ui-sessions-test--shown)))))

(ert-deftest harness-ui-sessions-from-a-worktree-shows-the-whole-project ()
  "Opened from a task's worktree, the list is scoped to the main checkout."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "main" root)
    (harness-ui-sessions-test--add "task" wt)
    (harness-ui-sessions-test--add "elsewhere" other)
    (let ((default-directory (expand-file-name "sub/" wt)))
      (make-directory default-directory t)
      (harness-sessions))
    (should (equal root (buffer-local-value 'harness-ui-sessions--project
                                            (get-buffer harness-ui-sessions--buffer-name))))
    (should (equal '("main" "task") (harness-ui-sessions-test--shown)))))

(ert-deftest harness-ui-sessions-removed-worktree-stays-with-its-project ()
  "An archived task's worktree is gone from disk; its session still lists."
  (harness-ui-sessions-test-with-repo
    (let ((gone (file-name-as-directory (expand-file-name ".worktrees/task-gone" root))))
      (harness-ui-sessions-test--git root "worktree" "add" "-q" "-b" "task/gone" gone)
      (harness-ui-sessions-test--git root "worktree" "remove" gone)
      (should-not (file-exists-p gone))
      (harness-ui-sessions-test--add "main" root)
      (harness-ui-sessions-test--add "archived" gone)
      (let ((default-directory root)) (harness-sessions))
      (should (equal '("archived" "main") (harness-ui-sessions-test--shown))))))

(ert-deftest harness-ui-sessions-remote-roots-are-not-looked-at ()
  "A remote session's root is compared as it is, with no file access."
  (harness-ui-sessions-test-with-repo
    (let ((remote "/ssh:nobody@example.invalid:/srv/project/"))
      (harness-ui-sessions-test--add "main" root)
      (harness-ui-sessions-test--add "remote" remote)
      (let ((default-directory root)) (harness-sessions))
      (should (equal '("main") (harness-ui-sessions-test--shown)))
      (with-current-buffer harness-ui-sessions--buffer-name
        (cl-letf (((symbol-function 'harness-files-main-checkout) (lambda (&rest _) (error "Looked at")))
                  ((symbol-function 'harness-files-main-root) (lambda (&rest _) (error "Looked at")))
                  ((symbol-function 'file-directory-p) (lambda (&rest _) (error "Looked at"))))
          (setq harness-ui-sessions--main-roots nil)
          (should (equal remote (harness-ui-sessions--main-root remote))))
        (harness-ui-sessions-toggle-scope)
        (should (equal '("main" "remote") (harness-ui-sessions-test--shown)))))))

(ert-deftest harness-ui-sessions-resolve-each-root-once ()
  "Redraws reuse resolved roots; `g' resolves them again."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "main" root)
    (harness-ui-sessions-test--add "task" wt)
    (harness-ui-sessions-test--add "task-again" wt)
    (harness-ui-sessions-test--add "elsewhere" other)
    (let* ((calls 0)
           (resolve (symbol-function 'harness-files-main-checkout)))
      (cl-letf (((symbol-function 'harness-files-main-checkout)
                 (lambda (r) (cl-incf calls) (funcall resolve r))))
        (let ((default-directory root)) (harness-sessions))
        (should (equal '("main" "task" "task-again") (harness-ui-sessions-test--shown)))
        ;; One for the scope, one for each distinct session root.
        (should (= 4 calls))
        (dotimes (_ 3) (harness-ui-sessions--redraw))
        (should (= 4 calls))
        (with-current-buffer harness-ui-sessions--buffer-name (harness-ui-sessions-reload))
        (should (= 7 calls))
        (should (equal '("main" "task" "task-again") (harness-ui-sessions-test--shown)))))))

;;;; Tasks

(ert-deftest harness-ui-sessions-task-sessions-show-their-task ()
  "A task's session is of kind task.  Until it is named it shows its
task's title, as on the board: the task's own name, which it gets as
soon as it is submitted, else its prompt's first line."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "plain" root)
    (harness-ui-sessions-test--add "working" wt :name nil :status "running")
    (harness-ui-sessions-test--add "named" wt :name "Fix login redirect loop")
    (harness-ui-sessions-test--add "titled" wt :name nil :status "running")
    (setq harness-ui-sessions-test--tasks
          (list (list :id "t-1" :session "working" :state "active" :column "active"
                      :prompt "make btw open up with a lower effort level\n\nunless the config says otherwise")
                (list :id "t-2" :session "named" :state "review" :column "review"
                      :prompt "the login page loops")
                (list :id "t-3" :state "pending" :column "pending" :prompt "not started, so no session")
                (list :id "t-4" :session "titled" :state "active" :column "active"
                      :name "Export orders as CSV" :prompt "finance wants the orders as a CSV file")))
    (let ((default-directory root)) (harness-sessions))
    (should (equal '("named" "plain" "titled" "working") (harness-ui-sessions-test--shown)))
    (should (equal '("make btw open up with a lower effort level" "task")
                   (harness-ui-sessions-test--row "working")))
    (should (equal '("Fix login redirect loop" "task") (harness-ui-sessions-test--row "named")))
    (should (equal '("Export orders as CSV" "task") (harness-ui-sessions-test--row "titled")))
    (should (equal '("plain" "") (harness-ui-sessions-test--row "plain")))
    ;; Named by the model after its turn: the name wins over the title.
    (harness-ui-sessions-test--add "working" wt :name "Lower BTW effort level" :status "idle")
    (harness-ui-sessions--redraw)
    (should (equal '("Lower BTW effort level" "task") (harness-ui-sessions-test--row "working")))))

(ert-deftest harness-ui-sessions-follow-task-events ()
  "`task/changed' and `task/deleted' update the list between fetches."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "s-1" wt :name nil :status "running")
    (let ((default-directory root)) (harness-sessions))
    (should (equal '("unnamed" "") (harness-ui-sessions-test--row "s-1")))
    (harness-ui-sessions-test--with-init
      (cl-flet ((event (name &rest args) (run-hook-with-args 'harness-ui-event-functions name args))
                (shows (row) (harness-test-wait (lambda () (equal row (harness-ui-sessions-test--row "s-1")))
                                                5 (format "the list to show %S" row))))
        ;; Submitted: no session yet.
        (event "task/changed" (list :id "t-1" :prompt "Paginate GET /orders" :state "pending"))
        ;; Started: its session works on it.
        (event "task/changed" (list :id "t-1" :session "s-1" :prompt "Paginate GET /orders" :state "active"))
        (shows '("Paginate GET /orders" "task"))
        ;; Its prompt edited: the same task, shown anew.
        (event "task/changed" (list :id "t-1" :session "s-1" :prompt "Paginate GET /orders and /products"
                                    :state "active"))
        (shows '("Paginate GET /orders and /products" "task"))
        ;; Deleted, its session kept: a plain session again.
        (event "task/deleted" "t-1")
        (shows '("unnamed" ""))
        ;; Other events leave the list alone.
        (event "agent/turn-ended" "s-1" "end-turn")
        (should (equal '("unnamed" "") (harness-ui-sessions-test--row "s-1")))))))

(ert-deftest harness-ui-sessions-tasks-come-again-on-reload ()
  "`g' and a reload or reconnect ask for the tasks again.  When the
harness cannot say, as one without tasks, the list names no task."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "s-1" wt :name nil)
    (setq harness-ui-sessions-test--tasks (list (list :id "t-1" :session "s-1" :prompt "Log slow requests")))
    (let ((default-directory root)) (harness-sessions))
    (should (equal '("Log slow requests" "task") (harness-ui-sessions-test--row "s-1")))
    (setq harness-ui-sessions-test--tasks
          (list (list :id "t-1" :session "s-1" :prompt "Log requests slower than 500 ms")))
    (with-current-buffer harness-ui-sessions--buffer-name (harness-ui-sessions-reload))
    (should (equal '("Log requests slower than 500 ms" "task") (harness-ui-sessions-test--row "s-1")))
    ;; Connected to a harness without tasks.
    (setq harness-ui-sessions-test--tasks 'fail)
    (harness-ui-sessions-test--with-init (run-hooks 'harness-ui-redraw-hook))
    (should (equal '("unnamed" "") (harness-ui-sessions-test--row "s-1")))))

(ert-deftest harness-ui-sessions-filter-finds-tasks ()
  "The filter matches what a row shows: a task's title and the kind task."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "s-task" wt :name nil)
    (harness-ui-sessions-test--add "s-guide" root :name "Write the API guide")
    (setq harness-ui-sessions-test--tasks (list (list :id "t-1" :session "s-task" :prompt "Paginate GET /orders")))
    (let ((default-directory root)) (harness-sessions))
    (with-current-buffer harness-ui-sessions--buffer-name
      (harness-ui-sessions-filter "paginate")
      (should (equal '("s-task") (harness-ui-sessions-test--shown)))
      (harness-ui-sessions-filter "task")
      (should (equal '("s-task") (harness-ui-sessions-test--shown)))
      (harness-ui-sessions-filter "")
      (should (equal '("s-guide" "s-task") (harness-ui-sessions-test--shown))))))

;;;; Filters

(ert-deftest harness-ui-sessions-hide-the-internal-sessions ()
  "A session of kind internal is left out of the list until I shows it.
The kinds left out are those of `harness-ui-sessions-hidden-kinds'.  The
rows and the printed buffer lack them, and the mode line says when they
are shown.  A shown one indents under its parent like any child, and the
fullscreen layout never picks one to show beside the list, though it is
the newest session listed."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "chat" root :updated 100)
    (harness-ui-sessions-test--add "judge" root :kind "internal" :name "Permission judge"
                                   :updated 300)
    (harness-ui-sessions-test--add "naming" root :kind "internal" :name "Auto-naming"
                                   :parent-id "chat" :created 10 :updated 200)
    (harness-ui-sessions-test--add "aside" root :kind "btw" :parent-id "chat"
                                   :created 20 :updated 150)
    (let ((default-directory root)) (harness-sessions))
    ;; Out of the rows and of the buffer, by default.
    (should (equal '("aside" "chat") (harness-ui-sessions-test--shown)))
    (should-not (string-match-p "judge\\|naming" (harness-ui-sessions-test--text)))
    (should (equal " [Pause] [project]" (harness-ui-sessions-test--mode-line)))
    (with-current-buffer harness-ui-sessions--buffer-name
      (should (eq 'harness-ui-sessions-toggle-internal (key-binding (kbd "I"))))
      (goto-char (point-max))
      (should (equal "chat" (harness-ui-sessions--overview-session)))
      ;; I shows them, a child under its parent as any is.
      (call-interactively (key-binding (kbd "I")))
      (should (equal '("aside" "chat" "judge" "naming") (harness-ui-sessions-test--shown)))
      (should (equal '("judge" "chat" "naming" "aside") (mapcar #'car tabulated-list-entries)))
      (should (string-match-p "Permission judge" (harness-ui-sessions-test--text)))
      (should (equal "internal" (harness-ui-sessions-test--cell "judge" "Kind")))
      (should (equal "  ↳ Auto-naming" (harness-ui-sessions-test--cell "naming" "Name")))
      (should (equal " [Pause] [project +internal]" (harness-ui-sessions-test--mode-line)))
      ;; With point on no row the layout shows the newest session, not
      ;; the judge that was updated after it, nor the BTW conversation.
      (goto-char (point-max))
      (should-not (tabulated-list-get-id))
      (should (equal "chat" (harness-ui-sessions--overview-session)))
      ;; I again hides them.
      (call-interactively (key-binding (kbd "I")))
      (should (equal '("aside" "chat") (harness-ui-sessions-test--shown)))
      (should (equal " [Pause] [project]" (harness-ui-sessions-test--mode-line)))
      ;; The option names the kinds: with none nothing is left out, and
      ;; another kind goes the way the internal ones did.
      (let ((harness-ui-sessions-hidden-kinds nil))
        (harness-ui-sessions--redraw))
      (should (equal '("aside" "chat" "judge" "naming") (harness-ui-sessions-test--shown)))
      (let ((harness-ui-sessions-hidden-kinds '("btw")))
        (harness-ui-sessions--redraw))
      (should (equal '("chat" "judge" "naming") (harness-ui-sessions-test--shown)))
      ;; A kind is compared as text: a symbol counts, a session with none does not.
      (should (harness-ui-sessions--hidden-kind-p '(:kind internal)))
      (should-not (harness-ui-sessions--hidden-kind-p '(:id "no-kind"))))))

(ert-deftest harness-ui-sessions-list-only-the-tasks ()
  "T lists only the sessions that work on a task, and those under them.
A task's sub-agent, the fork of that and a BTW conversation of the task
are listed, indented under it.  A session that is no task's and has no
ancestor that is stays out, one whose parent the cache lacks too, until
T lists every session again.  The search up the parents ends at a cycle
of them.  Making the session at point a task, which T used to do, has a
key of its own now."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "task" wt :name nil :status "running" :updated 700)
    (harness-ui-sessions-test--add "agent" wt :kind "subagent" :parent-id "task"
                                   :created 10 :updated 600)
    (harness-ui-sessions-test--add "fork" wt :kind "fork" :parent-id "agent"
                                   :created 10 :updated 500)
    (harness-ui-sessions-test--add "aside" wt :kind "btw" :parent-id "task"
                                   :created 20 :updated 400)
    (harness-ui-sessions-test--add "plain" root :updated 300)
    (harness-ui-sessions-test--add "plain-child" root :kind "fork" :parent-id "plain" :updated 200)
    (harness-ui-sessions-test--add "orphan" root :parent-id "gone" :updated 100)
    (setq harness-ui-sessions-test--tasks
          (list (list :id "t-1" :session "task" :state "active" :prompt "Paginate GET /orders")))
    (let ((default-directory root)) (harness-sessions))
    (with-current-buffer harness-ui-sessions--buffer-name
      (should (equal '("agent" "aside" "fork" "orphan" "plain" "plain-child" "task")
                     (harness-ui-sessions-test--shown)))
      (should (eq 'harness-ui-sessions-toggle-tasks-only (key-binding (kbd "T"))))
      (call-interactively (key-binding (kbd "T")))
      (should (equal '("task" "agent" "fork" "aside") (mapcar #'car tabulated-list-entries)))
      (should (equal '(0 1 2 1) (mapcar (lambda (id) (gethash id harness-ui-sessions--depths))
                                        '("task" "agent" "fork" "aside"))))
      (should (equal "    ↳ fork" (harness-ui-sessions-test--cell "fork" "Name")))
      (should (equal " [Pause] [project tasks]" (harness-ui-sessions-test--mode-line)))
      ;; T again lists every session.
      (call-interactively (key-binding (kbd "T")))
      (should (equal '("agent" "aside" "fork" "orphan" "plain" "plain-child" "task")
                     (harness-ui-sessions-test--shown)))
      (should (equal " [Pause] [project]" (harness-ui-sessions-test--mode-line)))
      ;; Parents that lead in a circle, or to a session the cache lacks,
      ;; end the search, unless a task is among them.
      (harness-ui-sessions-test--add "ring-a" root :parent-id "ring-b")
      (harness-ui-sessions-test--add "ring-b" root :parent-id "ring-a")
      (should-not (harness-ui-sessions--on-task-p (harness-ui-session "ring-a")))
      (should-not (harness-ui-sessions--on-task-p (harness-ui-session "orphan")))
      (puthash "ring-b" (list :id "t-2" :session "ring-b") harness-ui-sessions--tasks)
      (should (harness-ui-sessions--on-task-p (harness-ui-session "ring-a")))
      (should (harness-ui-sessions--on-task-p (harness-ui-session "ring-b")))
      ;; M-t, which T gave way to, makes the session at point a task.
      (should (eq 'harness-ui-sessions-make-task (key-binding (kbd "M-t"))))
      (harness-ui-sessions-test--goto "plain")
      (should (string-prefix-p "Added to the task board"
                               (harness-ui-sessions-test--message
                                (lambda () (call-interactively (key-binding (kbd "M-t")))))))
      (should (equal '(("_harness/task/adopt" (:session-id "plain")))
                     (harness-ui-sessions-test--answers))))))

(ert-deftest harness-ui-sessions-toggles-work-from-any-buffer ()
  "The toggles set their flag in the list, whichever buffer is current.
That is how they run from the menu, or from a click in the mode line,
which may not have the list current."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "chat" root)
    (harness-ui-sessions-test--add "judge" root :kind "internal")
    (let ((default-directory root)) (harness-sessions))
    (with-temp-buffer
      (harness-ui-sessions-toggle-internal)
      (harness-ui-sessions-toggle-tasks-only)
      (should-not (local-variable-p 'harness-ui-sessions--show-hidden-kinds))
      (should-not (local-variable-p 'harness-ui-sessions--tasks-only)))
    (should (equal " [Pause] [project tasks +internal]" (harness-ui-sessions-test--mode-line)))
    ;; No task, so the tasks-only list is empty.
    (should-not (harness-ui-sessions-test--shown))
    (harness-ui-sessions-toggle-tasks-only)
    (should (equal '("chat" "judge") (harness-ui-sessions-test--shown)))
    ;; Without a list the toggles have nothing to do.
    (kill-buffer harness-ui-sessions--buffer-name)
    (harness-ui-sessions-toggle-internal)
    (harness-ui-sessions-toggle-tasks-only)
    (harness-ui-sessions-toggle-pause)
    (should-not (get-buffer harness-ui-sessions--buffer-name))))

;;;; Pausing

(defun harness-ui-sessions-test--button ()
  "Return the pause button of the list's mode line, with its properties."
  (with-current-buffer harness-ui-sessions--buffer-name
    (when (string-match "\\[Pause[^]]*\\]" mode-line-process)
      (match-string 0 mode-line-process))))

(defun harness-ui-sessions-test--paused-p ()
  "Non-nil when the list buffer is paused."
  (buffer-local-value 'harness-ui-sessions--paused (get-buffer harness-ui-sessions--buffer-name)))

(ert-deftest harness-ui-sessions-pause-holds-the-list-still ()
  "P pauses the list: nothing that follows the sessions redraws it.
Changes, output rates, requests answered, growing token figures, task
events and a reload of the UI leave a paused list as it is and start no
timer.  Pausing drops a redraw already scheduled, whether it is the one
of a burst of changes or the one the token figures wait for, and
redraws nothing itself.  Resuming redraws once, with all that changed
meanwhile.  The marks and the filter are as they were."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--with-init
      (let ((harness-ui--live (make-hash-table :test 'equal))
            (harness-ui--rates (make-hash-table :test 'equal)))
        (harness-ui-sessions-test--add "busy" root :status "running" :updated 300
                                       :usage (list :cost 0 :context 1000 :last-output 200 :output 300))
        (harness-ui-sessions-test--add "quiet" root :updated 200)
        (let ((default-directory root)) (harness-sessions))
        (with-current-buffer harness-ui-sessions--buffer-name
          (harness-ui-sessions-filter "demo")
          (puthash "busy" t harness-ui-sessions--marked))
        (harness-ui-sessions-test--counting-redraws redraws
          (with-current-buffer harness-ui-sessions--buffer-name
            (should (eq 'harness-ui-sessions-toggle-pause (key-binding (kbd "P"))))
            (should-not harness-ui-sessions--paused)
            ;; A burst of changes, then P before it redraws: pausing
            ;; redraws nothing, the burst's redraw is dropped, and
            ;; resuming right away makes the only one.
            (harness-ui-sessions--on-changed)
            (call-interactively (key-binding (kbd "P")))
            (should harness-ui-sessions--paused)
            (should (= 0 redraws))
            (call-interactively (key-binding (kbd "P")))
            (should-not harness-ui-sessions--paused)
            (should (= 1 redraws))
            (harness-ui-sessions-test--spin 0.3)
            (should (= 1 redraws))
            ;; A burst and a growing count scheduled, and then P: both
            ;; are dropped, the live timer cancelled.
            (setq redraws 0)
            (harness-ui-sessions--on-changed)
            (harness-ui--store-live "busy" '(:context 1500 :output 400 :estimated 0))
            (let ((timer harness-ui-sessions--live-timer))
              (should (timerp timer))
              (call-interactively (key-binding (kbd "P")))
              (should-not harness-ui-sessions--live-timer)
              (should-not (memq timer timer-list)))
            (harness-ui-sessions-test--spin 0.3)
            (should (= 0 redraws))
            ;; Everything that follows the sessions, left to fire.  The
            ;; figures read otherwise than the list shows them, so
            ;; without the pause they start the live timer.
            (puthash "busy" '(:context 6000 :output 1000 :estimated 0) harness-ui--live)
            (harness-ui-sessions--on-changed)
            (harness-ui-sessions--on-rate "busy" '(:rate 40.0))
            (harness-ui-sessions--on-pending "busy")
            (harness-ui-sessions--on-live "busy" nil)
            (harness-ui-sessions--on-live nil nil)
            (should-not harness-ui-sessions--live-timer)
            (harness-ui--store-live "busy" '(:context 6000 :output 1100 :estimated 0))
            (harness-ui--store-rate "busy" (list :rate 42.0 :output 600 :seconds 14.0 :calls 1
                                                 :at 1000.0 :model "demo:scripted"))
            (harness-ui-cache-session (append (list :name "Renamed") (harness-ui-session "quiet")))
            (setq harness-ui-sessions-test--tasks
                  (list (list :id "t-1" :session "quiet" :state "active" :prompt "Rename it")))
            (run-hook-with-args 'harness-ui-event-functions "task/changed"
                                (list (car harness-ui-sessions-test--tasks)))
            (run-hooks 'harness-ui-redraw-hook)
            (should-not harness-ui-sessions--live-timer)
            (harness-ui-sessions-test--spin 0.3)
            (should (= 0 redraws))
            (should-not harness-ui-sessions--live-timer)
            ;; The redraws that fire by themselves look at the pause when
            ;; they do, whatever scheduled them.
            (harness-ui-sessions--live-redraw)
            (harness-ui-sessions--redraw-live)
            (should (= 0 redraws))
            ;; The list shows what it showed.
            (should (equal "1.2k/200k" (harness-ui-sessions-test--cell "busy" "Context")))
            (should (equal '("quiet" "") (harness-ui-sessions-test--row "quiet")))
            ;; Resuming redraws once, with all of it.
            (call-interactively (key-binding (kbd "P")))
            (should (= 1 redraws))
            (should (equal "6.0k/200k" (harness-ui-sessions-test--cell "busy" "Context")))
            (should (equal '("Renamed" "task") (harness-ui-sessions-test--row "quiet")))
            (harness-ui-sessions-test--spin 0.3)
            (should (= 1 redraws))
            ;; The marks and the filter were left alone.
            (should (gethash "busy" harness-ui-sessions--marked))
            (should (equal "demo" harness-ui-sessions--filter))
            (should (equal '("busy" "quiet") (harness-ui-sessions-test--shown)))))))))

(ert-deftest harness-ui-sessions-pause-still-redraws-for-what-you-ask ()
  "A paused list is redrawn by its own commands, by g and by opening it.
The filter, the scope, the toggles and the columns redraw it, once each;
g does when the harness has answered with the sessions and with the
tasks; opening the list shows it afresh.  The hook that runs after a
reload or reconnect asks for the tasks too, and keeps them, but does not
redraw the list: they show once it is resumed.  It stays paused."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--with-init
      (harness-ui-sessions-test--add "busy" root :status "running" :updated 300)
      (harness-ui-sessions-test--add "quiet" root :updated 200)
      (let ((default-directory root)) (harness-sessions))
      (harness-ui-sessions-test--counting-redraws redraws
        (with-current-buffer harness-ui-sessions--buffer-name
          (harness-ui-sessions-toggle-pause)
          (should harness-ui-sessions--paused)
          ;; The list's own commands.
          (setq redraws 0)
          (harness-ui-sessions-filter "busy")
          (should (= 1 redraws))
          (should (equal '("busy") (harness-ui-sessions-test--shown)))
          (harness-ui-sessions-filter "")
          (dolist (command '(harness-ui-sessions-toggle-scope harness-ui-sessions-toggle-inactive
                             harness-ui-sessions-toggle-blocked harness-ui-sessions-toggle-tasks-only
                             harness-ui-sessions-toggle-internal))
            (setq redraws 0)
            (funcall command)
            (should (= 1 redraws))
            (funcall command))
          (setq redraws 0)
          (harness-ui-sessions-toggle-column "Mode")
          (should (= 1 redraws))
          (harness-ui-sessions-toggle-column "Mode")
          ;; g: the sessions and the tasks the harness answers with.
          (harness-ui-sessions-test--add "late" root :name nil :updated 900)
          (setq harness-ui-sessions-test--tasks
                (list (list :id "t-9" :session "late" :prompt "Late task")))
          (setq redraws 0)
          (call-interactively (key-binding (kbd "g")))
          (should (= 2 redraws))
          (should (equal '("Late task" "task") (harness-ui-sessions-test--row "late")))
          ;; The hook after a reload takes the tasks and leaves the list.
          (setq harness-ui-sessions-test--tasks
                (list (list :id "t-9" :session "late" :prompt "Late task, edited")))
          (setq redraws 0)
          (run-hooks 'harness-ui-redraw-hook)
          (should (= 0 redraws))
          (should (equal '("Late task" "task") (harness-ui-sessions-test--row "late")))
          ;; Resumed, the tasks it fetched show.
          (harness-ui-sessions-toggle-pause)
          (should (= 1 redraws))
          (should (equal '("Late task, edited" "task") (harness-ui-sessions-test--row "late")))
          ;; Paused again, opening the list shows it afresh: the sessions
          ;; and the tasks it asks for redraw it, and it stays paused.
          (harness-ui-sessions-toggle-pause)
          (harness-ui-sessions-test--add "later" root :updated 950)
          (setq harness-ui-sessions-test--tasks
                (list (list :id "t-9" :session "late" :prompt "Late task, opened")))
          (let ((default-directory root)) (harness-sessions))
          (should (member "later" (harness-ui-sessions-test--shown)))
          (should (equal '("Late task, opened" "task") (harness-ui-sessions-test--row "late")))
          (should harness-ui-sessions--paused))))))

(ert-deftest harness-ui-sessions-pause-button-in-the-mode-line ()
  "The mode line always has a pause button, and a click on it toggles the pause.
It reads [Pause] while the list follows the sessions, and [Paused: resume],
highlighted, while it holds still, with a tooltip naming P.  The click
is a left click in the mode line.  The pause is the list's own, so a
command from any buffer sets it.  The button comes first, as a narrow
mode line cuts its end, and the other things the mode line says follow."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "main" root)
    (let ((default-directory root)) (harness-sessions))
    (let ((live (harness-ui-sessions-test--button)))
      (should (equal "[Pause]" (substring-no-properties live)))
      (should-not (get-text-property 0 'face live))
      (should (eq 'mode-line-highlight (get-text-property 0 'mouse-face live)))
      (should (string-match-p "\\<P\\>" (get-text-property 0 'help-echo live))))
    (let ((event (list 'mouse-1 (list (selected-window) 1 '(0 . 0) 0))))
      ;; A click pauses it; the button then says so.
      (funcall (lookup-key (get-text-property 0 'local-map (harness-ui-sessions-test--button))
                           [mode-line mouse-1])
               event)
      (should (harness-ui-sessions-test--paused-p))
      (let ((paused (harness-ui-sessions-test--button)))
        (should (equal "[Paused: resume]" (substring-no-properties paused)))
        (should (eq 'harness-ui-sessions-paused-face (get-text-property 0 'face paused)))
        (should (eq 'mode-line-highlight (get-text-property 0 'mouse-face paused)))
        (should (string-match-p "\\<P\\>" (get-text-property 0 'help-echo paused)))
        ;; A click again resumes it.
        (funcall (lookup-key (get-text-property 0 'local-map paused) [mode-line mouse-1]) event))
      (should-not (harness-ui-sessions-test--paused-p))
      (should (equal "[Pause]" (substring-no-properties (harness-ui-sessions-test--button)))))
    ;; From another buffer, the list's own flag is the one that changes.
    (with-temp-buffer
      (harness-ui-sessions-toggle-pause)
      (should-not (local-variable-p 'harness-ui-sessions--paused)))
    (should (harness-ui-sessions-test--paused-p))
    ;; The rest of the mode line follows the button, whatever is on.
    (harness-ui-sessions-toggle-internal)
    (harness-ui-sessions-toggle-tasks-only)
    (with-current-buffer harness-ui-sessions--buffer-name
      (harness-ui-sessions-filter "ma"))
    (should (equal " [Paused: resume] [project /ma tasks +internal]"
                   (harness-ui-sessions-test--mode-line)))))

(ert-deftest harness-ui-sessions-stay-responsive-with-many-sessions ()
  "Hundreds of sessions redraw in a moment, and bursts of changes coalesce.
There are 300 sessions in eight projects, in trees of three, a fifth of
them running with live token figures.  One full redraw stays well
within a generous bound.  200 changes and 200 growing counts in a row
end in a few redraws -- the debounce and `harness-ui-sessions--live-interval'
coalesce them -- and in none while the list is paused."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--with-init
      (let ((harness-ui--live (make-hash-table :test 'equal))
            (projects (list root wt other))
            (count 300)
            (running nil))
        (dotimes (i 5)
          (let ((dir (file-name-as-directory (expand-file-name (format "extra-%d" i) base))))
            (make-directory dir t)
            (push dir projects)))
        (dotimes (i count)
          (let ((id (format "s-%03d" i)))
            ;; Trees of three: a session, its fork and the fork of that.
            (harness-ui-sessions-test--add
             id (nth (% (/ i 3) (length projects)) projects)
             :status (if (zerop (% i 5)) "running" "idle")
             :kind (if (zerop (% i 3)) "main" "fork")
             :parent-id (and (> (% i 3) 0) (format "s-%03d" (1- i)))
             :created (+ 1000 i) :updated (+ 1000 i)
             :usage (list :cost (* 0.01 i) :context (* 100 i) :last-output 50 :output (* 10 i)))
            (when (zerop (% i 5))
              (push id running)
              (puthash id (list :context (+ 5000 i) :output (* 20 i) :estimated 100) harness-ui--live))))
        (let ((default-directory root)) (harness-sessions t))
        (should (= count (length (harness-ui-sessions-test--shown))))
        ;; One full redraw.
        (let* ((start (float-time))
               (_ (harness-ui-sessions--redraw))
               (took (- (float-time) start)))
          (message "harness-ui-sessions: one full redraw of %d sessions took %.3fs" count took)
          (should (< took 2.0)))
        (harness-ui-sessions-test--counting-redraws redraws
          (cl-flet ((burst ()
                      (dotimes (n 200)
                        (harness-ui-sessions--on-changed)
                        (harness-ui--store-live (nth (% n (length running)) running)
                                                (list :context (+ 10000 n) :output (* 30 n)
                                                      :estimated 0)))))
            ;; Following the sessions, the burst ends in a couple of
            ;; redraws: one of the debounce, one of the live interval.
            (let ((start (float-time)))
              (burst)
              (message "harness-ui-sessions: a burst of 200 changes and 200 counts took %.3fs"
                       (- (float-time) start)))
            (harness-test-wait (lambda () (and (null harness-ui-sessions--live-timer) (> redraws 0)))
                               5 "the burst to redraw the list")
            (should (<= 1 redraws 3))
            (message "harness-ui-sessions: the burst ended in %d redraws" redraws)
            ;; Paused, the same burst redraws nothing, and starts no timer.
            (harness-ui-sessions-toggle-pause)
            (setq redraws 0)
            (burst)
            (should-not harness-ui-sessions--live-timer)
            (harness-ui-sessions-test--spin 0.3)
            (should (= 0 redraws))
            ;; Resumed, one redraw shows the last counts.
            (harness-ui-sessions-toggle-pause)
            (should (= 1 redraws))
            (should (= count (length (harness-ui-sessions-test--shown))))))))))

;;;; Following only what a window shows

(defun harness-ui-sessions-test--pending-redraw-p ()
  "Non-nil when the list has a redraw scheduled: a burst's or the token figures'."
  (and (or (timerp harness-ui-sessions--live-timer)
           (gethash 'harness-ui-sessions harness--debounce-timers))
       t))

(ert-deftest harness-ui-sessions-leaves-a-list-nobody-looks-at-alone ()
  "A list no window shows is not redrawn for the changes that come by themselves.
The session cache changes many times a second while agents work, and
the list, a thousand rows of a project with a worktree for each task,
took over half a second of the UI thread to redraw, whether a window
showed it or not.  Hidden, the sessions that change, their output rates
and growing token figures, the requests they wait on, the tasks, a
reload of the UI and the pet's footer start no timer and draw nothing;
the list notes what it missed and draws once when a window shows it
again, with all of it."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--with-init
      (let ((harness-ui--live (make-hash-table :test 'equal))
            (harness-ui--rates (make-hash-table :test 'equal)))
        (harness-ui-sessions-test--add "busy" root :status "running" :updated 300
                                       :usage (list :cost 0 :context 1000 :last-output 200 :output 300))
        (harness-ui-sessions-test--add "quiet" root :updated 200)
        (let ((default-directory root)) (harness-sessions))
        (let ((buf (get-buffer harness-ui-sessions--buffer-name)))
          (should (memq #'harness-ui-view--shown (buffer-local-value 'window-buffer-change-functions buf)))
          (harness-ui-sessions-test--counting-redraws redraws
            (cl-flet ((stale () (buffer-local-value 'harness-ui-view-stale buf)))
              ;; Shown, it follows a burst of changes with one redraw.
              (should-not (stale))
              (dotimes (_ 5) (harness-ui-sessions--on-changed))
              (should (harness-ui-sessions-test--pending-redraw-p))
              (harness-test-wait (lambda () (= 1 redraws)) 5 "the list to follow the changes")
              (harness-ui-sessions-test--spin 0.3)
              (should (= 1 redraws))
              (should-not (stale))
              ;; Hidden, everything that follows the sessions is left undone.
              (harness-ui-sessions-test--hide)
              (should-not (get-buffer-window buf t))
              (setq redraws 0)
              (harness-ui-sessions-test--add "quiet" root :updated 200 :name "Renamed")
              (dotimes (_ 5) (harness-ui-sessions--on-changed))
              (harness-ui-sessions--on-rate "busy" '(:rate 40.0))
              (harness-ui-sessions--on-pending "busy")
              (harness-ui-sessions--on-live "busy" nil)
              (harness-ui-sessions--on-live nil nil)
              (harness-ui--store-live "busy" '(:context 6000 :output 1100 :estimated 0))
              (harness-ui--store-rate "busy" (list :rate 42.0 :output 600 :seconds 14.0 :calls 1
                                                   :at 1000.0 :model "demo:scripted"))
              (harness-ui-cache-session (append (list :status "idle") (harness-ui-session "busy")))
              (setq harness-ui-sessions-test--tasks
                    (list (list :id "t-1" :session "quiet" :state "active" :prompt "Rename it")))
              (run-hook-with-args 'harness-ui-event-functions "task/changed"
                                  (list (car harness-ui-sessions-test--tasks)))
              (run-hooks 'harness-ui-redraw-hook)
              (harness-ui-sessions--redraw-live)
              (harness-ui-sessions--redraw-spaced)
              (harness-ui-sessions--live-redraw)
              (harness-ui-sessions-redraw)
              (should-not (harness-ui-sessions-test--pending-redraw-p))
              (harness-ui-sessions-test--spin 0.4)
              (should (= 0 redraws))
              (should (stale))
              ;; It shows what it showed.
              (should (equal "1.2k/200k" (harness-ui-sessions-test--cell "busy" "Context")))
              (should (equal '("quiet" "") (harness-ui-sessions-test--row "quiet")))
              ;; Its own commands still draw it: that is not a change that came by itself.
              (harness-ui-sessions-filter "")
              (should (= 1 redraws))
              (should-not (stale))
              (setq redraws 0)
              ;; Missed again, shown at last: it draws once, with all it missed.
              (harness-ui-sessions--on-changed)
              (should (stale))
              (harness-ui-sessions-test--show)
              (should-not (harness-ui-sessions-test--pending-redraw-p))
              (should (= 0 redraws))    ; redisplay runs the hook: the draw waits for a timer
              (harness-test-wait (lambda () (= 1 redraws)) 5 "the list to catch up")
              (should-not (stale))
              (should (equal "6.0k/200k" (harness-ui-sessions-test--cell "busy" "Context")))
              (should (equal '("Renamed" "task") (harness-ui-sessions-test--row "quiet")))
              (harness-ui-sessions-test--spin 0.3)
              (should (= 1 redraws))
              ;; Shown again after missing nothing, it draws nothing.
              (setq redraws 0)
              (harness-ui-sessions-test--hide)
              (harness-ui-sessions-test--show)
              (harness-ui-sessions-test--spin 0.3)
              (should (= 0 redraws)))))))))

(ert-deftest harness-ui-sessions-hidden-and-paused-holds-still-when-shown ()
  "A paused list that is hidden misses changes as a hidden one does, but a window does not wake it.
Pausing holds the list still; showing it draws nothing until it is
resumed, which draws it once, with what changed meanwhile."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--with-init
      (harness-ui-sessions-test--add "one" root :updated 300)
      (let ((default-directory root)) (harness-sessions))
      (harness-ui-sessions-test--counting-redraws redraws
        (harness-ui-sessions-toggle-pause)
        (harness-ui-sessions-test--spin 0.05) ; pausing drops the redraws it had scheduled
        (harness-ui-sessions-test--hide)
        (harness-ui-sessions-test--add "one" root :updated 300 :name "Renamed")
        (harness-ui-sessions--on-changed)
        (should-not (harness-ui-sessions-test--pending-redraw-p))
        (harness-ui-sessions-test--show)
        (harness-ui-sessions-test--spin 0.4)
        (should (= 0 redraws))
        (should (equal '("one" "") (harness-ui-sessions-test--row "one")))
        ;; Shown and paused, the sessions still do not draw it.
        (harness-ui-sessions--on-changed)
        (should-not (harness-ui-sessions-test--pending-redraw-p))
        (harness-ui-sessions-toggle-pause)
        (should (= 1 redraws))
        (should (equal '("Renamed" "") (harness-ui-sessions-test--row "one")))))))

(ert-deftest harness-ui-sessions-says-it-is-suspended-and-wakes-on-a-click ()
  "A list a window shows without catching up says it is suspended, and a click redraws it.
The mark is the same one every view that follows the harness only while
shown has (`harness-ui-view-indicator'), in the mode line's misc info.
It is there while the list has missed changes, and a paused list, which
misses none, has none."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--with-init
      (harness-ui-sessions-test--add "one" root :updated 300)
      (let ((default-directory root)) (harness-sessions))
      (let ((buf (get-buffer harness-ui-sessions--buffer-name)))
        (harness-ui-sessions-test--counting-redraws redraws
          (cl-flet ((mark () (with-current-buffer buf (substring-no-properties (harness-ui-view-indicator)))))
            (should (member harness-ui-view--mode-line (buffer-local-value 'mode-line-misc-info buf)))
            (should (equal "" (mark)))
            ;; Hidden, it misses a change and is marked.
            (harness-ui-sessions-test--hide)
            (harness-ui-sessions-test--add "one" root :updated 300 :name "Renamed")
            (harness-ui-sessions--on-changed)
            (should (equal "[Suspended: resume]" (mark)))
            ;; A window shows it, and the catch-up does not run: it says so still.
            (set-window-buffer (selected-window) buf)
            (harness-ui-sessions-test--spin 0.3)
            (should (= 0 redraws))
            (should (equal "[Suspended: resume]" (mark)))
            (should (equal '("one" "") (harness-ui-sessions-test--row "one")))
            ;; A click on the mark wakes it: drawn, and the mark is gone.
            (let ((event (list 'mouse-1 (list (selected-window) 1 '(0 . 0) 0))))
              (funcall (lookup-key (get-text-property 0 'local-map
                                                      (with-current-buffer buf (harness-ui-view-indicator)))
                                   [mode-line mouse-1])
                       event))
            (should (= 1 redraws))
            (should (equal "" (mark)))
            (should (equal '("Renamed" "") (harness-ui-sessions-test--row "one")))
            ;; A redraw of any kind takes the mark away.
            (harness-ui-sessions-test--hide)
            (harness-ui-sessions--on-changed)
            (should (equal "[Suspended: resume]" (mark)))
            (with-current-buffer buf (harness-ui-sessions--redraw))
            (should (equal "" (mark)))
            ;; Paused, it holds still and misses nothing: no mark.
            (harness-ui-sessions-toggle-pause)
            (harness-ui-sessions-test--spin 0.05)
            (harness-ui-sessions--on-changed)
            (should (equal "" (mark)))))))))

(ert-deftest harness-ui-sessions-wait-as-long-as-their-redraws-cost ()
  "The changes that come all the time wait for the cost of the last redraw.
A redraw is followed by four times as long as it took before the
sessions draw the list again, one redraw for everything that changed
meanwhile, however many changes come.  That bounds the share of Emacs's
time the list takes, a fifth, whatever it costs and however fast the
sessions change.  A reload of the UI does not wait."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--with-init
      (harness-ui-sessions-test--add "one" root :updated 300)
      (let ((default-directory root)) (harness-sessions))
      (let ((buf (get-buffer harness-ui-sessions--buffer-name))
            (refresh (symbol-function 'harness-ui-sessions--refresh)))
        (harness-ui-sessions-test--counting-redraws redraws
          ;; A slow redraw (a thousand rows, a collection of garbage).
          (cl-letf (((symbol-function 'harness-ui-sessions--refresh)
                     (lambda () (sleep-for 0.05) (funcall refresh))))
            (let ((before (float-time)))
              (harness-ui-sessions--redraw)
              (should (>= (buffer-local-value 'harness-ui-sessions--due buf)
                          (+ before 0.05 (* 4 0.05))))))
          ;; The next redraw is not due yet: changes wait, in one timer.
          (with-current-buffer buf (setq harness-ui-sessions--due (+ (float-time) 0.4)))
          (setq redraws 0)
          (dotimes (_ 5) (harness-ui-sessions--redraw-spaced))
          (harness-ui-sessions--on-changed)
          (harness-ui-sessions-test--spin 0.25)    ; the burst's debounce has fired
          (should (= 0 redraws))
          (should (timerp harness-ui-sessions--live-timer))
          (let ((timer harness-ui-sessions--live-timer))
            (harness-ui-sessions--redraw-spaced)
            (harness-ui-sessions--on-live nil nil)
            (should (eq timer harness-ui-sessions--live-timer)))
          (harness-test-wait (lambda () (= 1 redraws)) 5 "the redraw that waited")
          (should-not harness-ui-sessions--live-timer)
          (harness-ui-sessions-test--spin 0.3)
          (should (= 1 redraws))
          ;; Due, a change draws the list at once.
          (with-current-buffer buf (setq harness-ui-sessions--due 0.0))
          (setq redraws 0)
          (harness-ui-sessions--redraw-spaced)
          (should (= 1 redraws))
          ;; A reload of the UI does not wait for it: it draws the list as
          ;; it is reloaded, and again as the tasks come.
          (with-current-buffer buf (setq harness-ui-sessions--due (+ (float-time) 60)))
          (setq redraws 0)
          (run-hooks 'harness-ui-redraw-hook)
          (should (= 2 redraws))
          (should-not harness-ui-sessions--live-timer))))))

(ert-deftest harness-ui-sessions-make-tooltips-when-they-are-hovered ()
  "The tooltips of the token, rate, cost and time cells are made on hover.
Making them for every row at every redraw, a thousand rows of string
work per redraw, was most of what a redraw cost.  A redraw makes none;
asked, a tooltip says what the eager formatter says, of the session as
the cache has it then."
  (harness-ui-sessions-test-with-repo
    (let ((harness-ui--live (make-hash-table :test 'equal))
          (harness-ui-sessions-hidden-columns nil)
          (made 0))
      (harness-ui-sessions-test--add "busy" root :status "running" :last-message 1000.0
                                     :usage (list :cost 1.5 :context 1000 :last-output 200 :output 300
                                                  :stream-output 900 :stream-seconds 30.0))
      (let ((counters '(harness-ui-context-limit-help harness-ui-tokens-help harness-ui-spend-help
                        harness-ui-average-rate-help harness-ui-sessions--last-message-help)))
        (dolist (fn counters)
          (advice-add fn :before (lambda (&rest _) (cl-incf made)) '((name . harness-ui-sessions-test-made))))
        (unwind-protect
            (progn
              (let ((default-directory root)) (harness-sessions))
              (harness-ui-sessions--redraw)
              (should (= 0 made))
              (dolist (column '("Context" "Output" "Avg tok/s" "Cost" "Last msg"))
                (should (functionp (get-text-property 0 'help-echo
                                                      (harness-ui-sessions-test--raw-cell "busy" column))))
                (should (stringp (harness-ui-sessions-test--help "busy" column))))
              (should (> made 0)))
          (dolist (fn counters)
            (advice-remove fn 'harness-ui-sessions-test-made))))
      (let ((session (harness-ui-session "busy")))
        (should (equal (get-text-property 0 'help-echo (harness-ui-format-context session))
                       (harness-ui-sessions-test--help "busy" "Context")))
        (should (equal (get-text-property 0 'help-echo (harness-ui-format-output session t))
                       (harness-ui-sessions-test--help "busy" "Output")))
        (should (equal (get-text-property 0 'help-echo (harness-ui-format-average-rate session t))
                       (harness-ui-sessions-test--help "busy" "Avg tok/s")))
        (should (equal (get-text-property 0 'help-echo (harness-ui-format-spend session))
                       (harness-ui-sessions-test--help "busy" "Cost"))))
      (should (string-prefix-p "Last user or assistant message:"
                               (harness-ui-sessions-test--help "busy" "Last msg")))
      ;; Never older than the hover: the count grows, the row is not drawn
      ;; again, and the tooltip says the new figure over the old text.
      (harness-ui--store-live "busy" '(:context 90000 :output 5000 :estimated 0))
      (should (equal "1.2k/200k" (harness-ui-sessions-test--cell "busy" "Context")))
      (should (string-match-p "in use: 90\\.0k of" (harness-ui-sessions-test--help "busy" "Context"))))))

(ert-deftest harness-ui-sessions-reload-gives-an-existing-list-the-show-hook ()
  "A list that was made before the harness reloaded catches up when shown too.
The mode function installs the catch-up, and an old list never ran this
version's; the module's init gives it, once however often it runs."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--with-init
      (harness-ui-sessions-test--add "one" root)
      (let ((default-directory root)) (harness-sessions))
      (let ((buf (get-buffer harness-ui-sessions--buffer-name)))
        (with-current-buffer buf
          (remove-hook 'window-buffer-change-functions #'harness-ui-view--shown t)
          (setq harness-ui-view-catch-up nil))
        (harness-ui-sessions--init)
        (should (= 1 (cl-count #'harness-ui-view--shown
                               (buffer-local-value 'window-buffer-change-functions buf))))
        (should (eq #'harness-ui-sessions--catch-up
                    (buffer-local-value 'harness-ui-view-catch-up buf)))
        (harness-ui-sessions--init)
        (should (= 1 (cl-count #'harness-ui-view--shown
                               (buffer-local-value 'window-buffer-change-functions buf))))))))

;;;; Marks

(defun harness-ui-sessions-test--rows (root ids &rest props)
  "Cache a session in ROOT for each of IDS and open the list on them.
The first of IDS is the newest session, so the rows come in the order of
IDS.  PROPS go to every session."
  (let ((updated (* 100 (length ids))))
    (dolist (id ids)
      (apply #'harness-ui-sessions-test--add id root :updated updated props)
      (cl-decf updated 100)))
  (let ((default-directory root)) (harness-sessions)))

(defun harness-ui-sessions-test--press (keys)
  "Run what the list binds to KEYS, in the list buffer, as typing them would."
  (with-current-buffer harness-ui-sessions--buffer-name
    (call-interactively (key-binding (kbd keys)))))

(defun harness-ui-sessions-test--starred ()
  "Return the ids of the rows that start with a *, in the order of the rows."
  (with-current-buffer harness-ui-sessions--buffer-name
    (let (ids)
      (save-excursion
        (goto-char (point-min))
        (while (not (eobp))
          (when (and (eq (char-after) ?*) (tabulated-list-get-id))
            (push (tabulated-list-get-id) ids))
          (forward-line 1)))
      (nreverse ids))))

(defun harness-ui-sessions-test--mark (&rest ids)
  "Mark the sessions IDS with m, one row after the other, as a user would.
Point ends on the row after the last one marked, or stays on it at the
end of the list."
  (with-current-buffer harness-ui-sessions--buffer-name
    (dolist (id ids)
      (harness-ui-sessions-test--goto id)
      (harness-ui-sessions-test--press "m"))))

(ert-deftest harness-ui-sessions-mark-and-unmark-the-rows ()
  "The mark keys mark, unmark and invert rows, and move over them.
m marks the session at point and moves to the next row, skipping the
line under a blocked session's row, which is the row's own, and keeping
the column; at the last row point stays.  A numeric prefix marks that
many rows.  u unmarks and moves on; DEL moves up and unmarks; U unmarks
every session and says how many; t inverts the rows listed and leaves
the marks of the sessions the filters hide.  A mark changes its row in
place: nothing is redrawn, the row keeps its properties, and an
unmarked row is as it was printed."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "gone" root :status "inactive" :updated 100)
    (harness-ui-sessions-test--add "three" root :updated 200)
    (harness-ui-sessions-test--add "two" root :updated 300)
    (harness-ui-sessions-test--blocked "asks" root "permission" :updated 400)
    (harness-ui-sessions-test--add "one" root :updated 500)
    (let ((default-directory root)) (harness-sessions))
    (harness-ui-sessions-test--counting-redraws redraws
      (with-current-buffer harness-ui-sessions--buffer-name
        (should (equal '("one" "asks" "two" "three" "gone") (mapcar #'car tabulated-list-entries)))
        (dolist (binding '(("m" . harness-ui-sessions-mark) ("u" . harness-ui-sessions-unmark)
                           ("DEL" . harness-ui-sessions-unmark-backward)
                           ("U" . harness-ui-sessions-unmark-all)
                           ("t" . harness-ui-sessions-toggle-marks)
                           ("M" . harness-ui-sessions-move)))
          (should (eq (cdr binding) (key-binding (kbd (car binding))))))
        (should-not (harness-ui-sessions--marked-ids))
        ;; m marks the row and moves to the same column of the next.
        (let ((row (progn (harness-ui-sessions-test--goto "one")
                          (buffer-substring (line-beginning-position) (line-end-position))))
              (under (harness-ui-sessions-test--line "asks")))
          (move-to-column 5)
          (harness-ui-sessions-test--press "m")
          (should (equal '("one") (harness-ui-sessions-test--starred)))
          (should (equal "asks" (tabulated-list-get-id)))
          (should (= 5 (current-column)))
          (should (equal '("one") (harness-ui-sessions--marked-ids)))
          (should (equal " [Pause] [project] 1 marked" (harness-ui-sessions-test--mode-line)))
          ;; The row is the same but for its tag, and still its session's.
          (let ((start (harness-ui-sessions--position "one")))
            (should (equal (concat "*" (substring-no-properties (substring row 1)))
                           (buffer-substring-no-properties start (save-excursion (goto-char start)
                                                                                 (line-end-position)))))
            (should (equal "one" (tabulated-list-get-id start)))
            (should (equal "one" (tabulated-list-get-id (1+ start))))
            (should (tabulated-list-get-entry start))
            (should (eq 'harness-ui-sessions-mark-face (get-text-property start 'face))))
          (should-not (buffer-modified-p))
          ;; The blocked row: the line under it is no row, nor marked.
          (harness-ui-sessions-test--press "m")
          (should (equal '("one" "asks") (harness-ui-sessions-test--starred)))
          (should (equal "two" (tabulated-list-get-id)))
          (should (= 5 (current-column)))
          (should (equal under (harness-ui-sessions-test--line "asks")))
          (should (string-prefix-p " " (harness-ui-sessions-test--line "asks"))))
        ;; A numeric prefix marks that many rows, and point ends after them.
        (let ((current-prefix-arg 2)) (harness-ui-sessions-test--press "m"))
        (should (equal '("one" "asks" "two" "three") (harness-ui-sessions-test--starred)))
        (should (equal "gone" (tabulated-list-get-id)))
        ;; At the last row point stays, with the row marked.
        (harness-ui-sessions-test--press "m")
        (should (equal "gone" (tabulated-list-get-id)))
        (should (equal '("one" "asks" "two" "three" "gone") (harness-ui-sessions-test--starred)))
        ;; DEL moves up, then unmarks.
        (harness-ui-sessions-test--press "DEL")
        (should (equal "three" (tabulated-list-get-id)))
        (should (equal '("one" "asks" "two" "gone") (harness-ui-sessions-test--starred)))
        (harness-ui-sessions-test--press "DEL")
        (should (equal "two" (tabulated-list-get-id)))
        (should (equal '("one" "asks" "gone") (harness-ui-sessions-test--starred)))
        ;; u unmarks the row it is on, the blocked one from the line under it
        ;; too, and moves on; the padding is as it was printed.
        (harness-ui-sessions-test--goto "asks")
        (forward-line 1)
        (should (equal "asks" (tabulated-list-get-id)))
        (harness-ui-sessions-test--press "u")
        (should (equal '("one" "gone") (harness-ui-sessions-test--starred)))
        (should (equal "two" (tabulated-list-get-id)))
        (should (equal (cons ?\s "asks") (harness-ui-sessions-test--row-start "asks")))
        (should-not (get-text-property (harness-ui-sessions--position "asks") 'face))
        ;; Marking from the line under the row marks the row.
        (harness-ui-sessions-test--goto "asks")
        (forward-line 1)
        (harness-ui-sessions-test--press "m")
        (should (equal '("one" "asks" "gone") (harness-ui-sessions-test--starred)))
        (should (equal "two" (tabulated-list-get-id)))
        (should (string-prefix-p " " (harness-ui-sessions-test--line "asks")))
        ;; U unmarks them all and says how many.
        (should (equal '("Unmarked 3 sessions")
                       (harness-ui-sessions-test--messages
                        (lambda () (harness-ui-sessions-test--press "U")))))
        (should-not (harness-ui-sessions-test--starred))
        (should-not (harness-ui-sessions--marked-ids))
        (should (= 0 (hash-table-count harness-ui-sessions--marked)))
        (should (equal " [Pause] [project]" (harness-ui-sessions-test--mode-line)))
        (should (equal '("No session was marked")
                       (harness-ui-sessions-test--messages
                        (lambda () (harness-ui-sessions-test--press "U")))))
        (should (= 0 redraws))
        ;; t inverts the rows listed and leaves a hidden session's mark.
        (harness-ui-sessions-test--mark "two" "gone")
        (harness-ui-sessions-test--press "i")
        (should (equal '("one" "asks" "two" "three") (mapcar #'car tabulated-list-entries)))
        (should (equal '("two") (harness-ui-sessions-test--starred)))
        (setq redraws 0)
        (harness-ui-sessions-test--press "t")
        (should (equal '("one" "asks" "three") (harness-ui-sessions-test--starred)))
        (should (equal '("one" "asks" "three" "gone") (harness-ui-sessions--marked-ids)))
        (should (equal " [Pause] [project active] 4 marked" (harness-ui-sessions-test--mode-line)))
        (should (= 0 redraws))
        (harness-ui-sessions-test--press "i")
        (should (equal '("one" "asks" "three" "gone") (harness-ui-sessions-test--starred)))
        (harness-ui-sessions-test--press "t")
        (should (equal '("two") (harness-ui-sessions-test--starred)))
        (should (equal '("two") (harness-ui-sessions--marked-ids)))))))

(ert-deftest harness-ui-sessions-a-mark-in-place-is-what-a-redraw-prints ()
  "Marking in place leaves the list as a redraw of the marks prints it.
Marked and unmarked, the text and every text property are the same, for
a plain row and for the rows of sessions waiting on a permission request
and on a question, whose lines under them and keys must stay as they
are: y on the tag of a marked permission row still allows."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "plain" root :updated 300)
    (harness-ui-sessions-test--blocked "asks" root "permission" :updated 200)
    (harness-ui-sessions-test--blocked "wonders" root "question" :updated 100)
    (let ((default-directory root)) (harness-sessions))
    (cl-flet ((text () (with-current-buffer harness-ui-sessions--buffer-name
                         (buffer-substring (point-min) (point-max)))))
      (let ((unmarked (text)))
        (harness-ui-sessions-test--mark "plain" "asks" "wonders")
        (let ((in-place (text)))
          (should (equal '("plain" "asks" "wonders") (harness-ui-sessions-test--starred)))
          (harness-ui-sessions--redraw)
          (should (equal-including-properties in-place (text))))
        (with-current-buffer harness-ui-sessions--buffer-name
          (let ((start (harness-ui-sessions--position "asks")))
            (should (eq harness-ui-sessions-permission-map (get-text-property start 'keymap)))
            (should (eq 'harness-ui-sessions-allow
                        (lookup-key (get-text-property start 'keymap) (kbd "y"))))))
        (harness-ui-sessions-test--press "U")
        (should (equal-including-properties unmarked (text)))))))

(ert-deftest harness-ui-sessions-marks-work-under-the-banner-of-the-blocked-filter ()
  "The banner above the rows of the sessions waiting for you is no row.
DEL on the first row stays on it, m marks the rows below the banner and
moves down them, and the banner is not tagged."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--blocked "first" root "permission" :updated 200)
    (harness-ui-sessions-test--blocked "second" root "question" :updated 100)
    (harness-sessions-waiting)
    (with-current-buffer harness-ui-sessions--buffer-name
      (should-not (tabulated-list-get-id (point-min)))
      (harness-ui-sessions-test--goto "first")
      (harness-ui-sessions-test--press "DEL")
      (should (equal "first" (tabulated-list-get-id)))
      (should-not (harness-ui-sessions-test--starred))
      ;; m moves down, past the line under the first row, and stays at the last.
      (harness-ui-sessions-test--press "m")
      (should (equal "second" (tabulated-list-get-id)))
      (harness-ui-sessions-test--press "m")
      (should (equal "second" (tabulated-list-get-id)))
      (should (equal '("first" "second") (harness-ui-sessions-test--starred)))
      (should-not (eq ?* (char-after (point-min))))
      ;; DEL moves up to the first row, and no further.
      (harness-ui-sessions-test--press "DEL")
      (should (equal "first" (tabulated-list-get-id)))
      (should (equal '("second") (harness-ui-sessions-test--starred)))
      (harness-ui-sessions-test--press "DEL")
      (should (equal "first" (tabulated-list-get-id)))
      (should (equal '("second") (harness-ui-sessions-test--starred)))
      (harness-ui-sessions-test--press "t")
      (should (equal '("first") (harness-ui-sessions-test--starred)))
      (should-not (eq ?* (char-after (point-min)))))))

(ert-deftest harness-ui-sessions-a-list-from-before-marks-takes-them ()
  "A list kept through a reload from before marks existed has no table of marks.
It reads as nothing marked, and the first mark makes the table."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--rows root '("a" "b"))
    (with-current-buffer harness-ui-sessions--buffer-name
      (setq harness-ui-sessions--marked nil)
      (should-not (harness-ui-sessions--marked-ids))
      (should (= 0 (harness-ui-sessions--marked-count)))
      (harness-ui-sessions-test--goto "a")
      (should (equal '("a") (harness-ui-sessions--targets)))
      (harness-ui-sessions--redraw)
      (harness-ui-sessions-test--press "U")
      (should-not harness-ui-sessions--marked)
      (harness-ui-sessions-test--mark "a")
      (should (hash-table-p harness-ui-sessions--marked))
      (should (equal '("a") (harness-ui-sessions-test--starred))))))

(ert-deftest harness-ui-sessions-marking-needs-a-session-on-the-line ()
  "A line with no session is no target of a mark or of any command on sessions.
That is the banner of a list of the sessions waiting for you when none
waits.  m, u, DEL and the commands that act on sessions say so, and
nothing is marked, asked or sent; U and t have nothing to do."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "idle" root)
    (harness-sessions-waiting)
    (with-current-buffer harness-ui-sessions--buffer-name
      (should-not (harness-ui-sessions-test--shown))
      (goto-char (point-min))
      (should-not (tabulated-list-get-id))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) (error "Asked")))
                ((symbol-function 'completing-read) (lambda (&rest _) (error "Asked"))))
        (dolist (keys '("m" "u" "DEL" "d" "k" "x" "+" "-" "p" "M-t" "f" "r" "M"))
          (ert-info (keys)
            (let ((err (should-error (harness-ui-sessions-test--press keys) :type 'user-error)))
              (should (equal "No session on this line" (cadr err)))))))
      (should-not (harness-ui-sessions--marked-ids))
      (harness-ui-sessions-test--press "t")
      (harness-ui-sessions-test--press "U")
      (should-not (harness-ui-sessions-test--answers))
      (should (= 0 (hash-table-count harness-ui-sessions--marked))))))

(ert-deftest harness-ui-sessions-marks-survive-redraws-filters-and-the-pause ()
  "Marks stay through a redraw, the filter, a change of scope, g and the pause.
A marked session the filters hide stays marked, counts in the mode line
and shows its mark again when listed.  Marking works on a filtered list,
and on a paused one, which shows the mark without a redraw.  The next
refresh drops the mark of a session the cache has lost, hidden or not."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "q-one" root :updated 400)
    (harness-ui-sessions-test--add "q-two" root :updated 300)
    (harness-ui-sessions-test--add "r-three" root :updated 200)
    (harness-ui-sessions-test--add "elsewhere" other :updated 100)
    (let ((default-directory root)) (harness-sessions))
    (harness-ui-sessions-test--counting-redraws redraws
      (with-current-buffer harness-ui-sessions--buffer-name
        (harness-ui-sessions-test--mark "q-one" "r-three")
        (should (equal '("q-one" "r-three") (harness-ui-sessions-test--starred)))
        (harness-ui-sessions--redraw)
        (should (equal '("q-one" "r-three") (harness-ui-sessions-test--starred)))
        ;; The filter hides one: its mark stays and counts.
        (harness-ui-sessions-filter "q")
        (should (equal '("q-one" "q-two") (mapcar #'car tabulated-list-entries)))
        (should (equal '("q-one") (harness-ui-sessions-test--starred)))
        (should (equal '("q-one" "r-three") (harness-ui-sessions--marked-ids)))
        (should (equal " [Pause] [project /q] 2 marked" (harness-ui-sessions-test--mode-line)))
        ;; A filtered list takes marks, too.
        (harness-ui-sessions-test--mark "q-two")
        (should (equal '("q-one" "q-two" "r-three") (harness-ui-sessions--marked-ids)))
        (harness-ui-sessions-filter "")
        (should (equal '("q-one" "q-two" "r-three") (harness-ui-sessions-test--starred)))
        ;; The scope: another project's session marked, then out of view.
        (harness-ui-sessions-toggle-scope)
        (harness-ui-sessions-test--mark "elsewhere")
        (should (equal '("q-one" "q-two" "r-three" "elsewhere") (harness-ui-sessions-test--starred)))
        (harness-ui-sessions-toggle-scope)
        (should (equal '("q-one" "q-two" "r-three") (harness-ui-sessions-test--starred)))
        (should (equal '("q-one" "q-two" "r-three" "elsewhere") (harness-ui-sessions--marked-ids)))
        ;; g asks the harness for the sessions again.
        (harness-ui-sessions-test--press "g")
        (should (equal '("q-one" "q-two" "r-three") (harness-ui-sessions-test--starred)))
        (should (= 4 (hash-table-count harness-ui-sessions--marked)))
        ;; A paused list holds still but takes a mark at once.
        (harness-ui-sessions-test--press "P")
        (setq redraws 0)
        (harness-ui-sessions-test--goto "q-one")
        (harness-ui-sessions-test--press "u")
        (should (equal '("q-two" "r-three") (harness-ui-sessions-test--starred)))
        (should (equal " [Paused: resume] [project] 3 marked" (harness-ui-sessions-test--mode-line)))
        (harness-ui-sessions-test--press "t")
        (should (equal '("q-one") (harness-ui-sessions-test--starred)))
        (should (= 0 redraws))
        (harness-ui-sessions-test--press "t")
        (harness-ui-sessions-test--press "P")
        (should (= 1 redraws))
        (should (equal '("q-two" "r-three") (harness-ui-sessions-test--starred)))
        ;; A session the cache has lost is not a target, and loses its mark
        ;; at the next refresh -- the hidden one too.
        (remhash "q-two" harness-ui--sessions)
        (remhash "elsewhere" harness-ui--sessions)
        (should (equal '("r-three") (harness-ui-sessions--marked-ids)))
        (should (= 3 (hash-table-count harness-ui-sessions--marked)))
        (harness-ui-sessions--redraw)
        (should (equal '("r-three") (hash-table-keys harness-ui-sessions--marked)))
        (should (equal " [Pause] [project] 1 marked" (harness-ui-sessions-test--mode-line)))))))

(ert-deftest harness-ui-sessions-targets-are-the-marked-sessions-or-the-one-at-point ()
  "The sessions a command acts on are the marked ones, else the one at point.
The marked ones come in the order of the rows, not of marking, and the
ones the filters hide after them, newest first and by id among those
updated together.  A session the cache lacks is none of them.  Commands
that act on one session refuse while any is marked, whichever."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "d" root :updated 400)
    (harness-ui-sessions-test--add "c" root :updated 300)
    (harness-ui-sessions-test--add "b" root :updated 200)
    (harness-ui-sessions-test--add "a" root :updated 100)
    (harness-ui-sessions-test--add "h-old" root :status "inactive" :updated 10)
    (harness-ui-sessions-test--add "h-b" root :status "inactive" :updated 20)
    (harness-ui-sessions-test--add "h-a" root :status "inactive" :updated 20)
    (harness-ui-sessions-test--add "h-new" root :status "inactive" :updated 30)
    (let ((default-directory root)) (harness-sessions))
    (with-current-buffer harness-ui-sessions--buffer-name
      ;; Nothing marked: the session at point.
      (harness-ui-sessions-test--goto "b")
      (should (equal '("b") (harness-ui-sessions--targets)))
      (should (equal "b" (harness-ui-sessions--one-id "Fork")))
      ;; Marked in another order than the rows are in: a before c, and the
      ;; inactive ones in an order that is neither theirs by time nor by id.
      (harness-ui-sessions-test--mark "a" "c" "h-a" "h-old" "h-b" "h-new")
      (harness-ui-sessions-test--goto "b")
      (should (equal '("c" "a") (seq-take (harness-ui-sessions--marked-ids) 2)))
      (should (equal (cl-remove-if-not #'harness-ui-sessions--marked-p
                                       (mapcar #'car tabulated-list-entries))
                     (harness-ui-sessions--marked-ids)))
      (should (equal (harness-ui-sessions--marked-ids) (harness-ui-sessions--targets)))
      ;; The hidden ones go last: newest first, by id among equals.
      (harness-ui-sessions-test--press "i")
      (should (equal '("c" "a" "h-new" "h-a" "h-b" "h-old") (harness-ui-sessions--marked-ids)))
      (should (= 6 (harness-ui-sessions--marked-count)))
      ;; A session the cache lacks is left out, before any refresh.
      (remhash "c" harness-ui--sessions)
      (should (equal '("a" "h-new" "h-a" "h-b" "h-old") (harness-ui-sessions--targets)))
      ;; Marks keep a command for one session from acting on the one at point.
      (let ((err (should-error (harness-ui-sessions--one-id "Fork") :type 'user-error)))
        (should (string-match-p "\\`Fork acts on one session, but 5 are marked: unmark them first (U)\\'"
                                (cadr err))))
      (harness-ui-sessions-test--press "U")
      (should (equal '("b") (harness-ui-sessions--targets)))
      (harness-ui-sessions-test--goto "b")
      (harness-ui-sessions-test--press "m")
      (let ((err (should-error (harness-ui-sessions--one-id "Rename") :type 'user-error)))
        (should (equal "Rename acts on one session, but one is marked: unmark it first (U)" (cadr err)))))))

(ert-deftest harness-ui-sessions-delete-the-marked-sessions ()
  "Deleting the marked sessions asks once and deletes each of them.
The question counts them, or names the session at point when none is
marked, and says how many of the marked ones the list does not show.
Each goes by `_harness/session/delete' and leaves the cache as its
request is answered; `harness-delete-session', which would ask for each,
is not called.  Once the last is answered the ones deleted are unmarked,
the list is redrawn once and one message says how many went.  One that
cannot be deleted keeps its mark; declining the question deletes
nothing."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--rows root '("a" "b" "c" "d"))
    (let ((asked nil) (answer nil))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (prompt) (push prompt asked) answer))
                ((symbol-function 'harness-delete-session) (lambda (&rest _) (error "Asks again"))))
        (harness-ui-sessions-test--counting-redraws redraws
          (with-current-buffer harness-ui-sessions--buffer-name
            (harness-ui-sessions-test--mark "a" "c")
            (harness-ui-sessions-test--goto "b")
            ;; Declined: nothing is sent, the marks stay.
            (harness-ui-sessions-test--press "d")
            (should (equal '("Delete 2 marked sessions? ") asked))
            (should-not (harness-ui-sessions-test--answers))
            (should (equal '("a" "c") (harness-ui-sessions-test--starred)))
            ;; Accepted: one question and one request for each of the marked.
            (setq asked nil answer t redraws 0)
            (should (equal '("Deleted 2 sessions")
                           (harness-ui-sessions-test--messages
                            (lambda () (harness-ui-sessions-test--press "d")))))
            (should (equal '("Delete 2 marked sessions? ") asked))
            (should (equal '(("_harness/session/delete" (:id "a"))
                             ("_harness/session/delete" (:id "c")))
                           (harness-ui-sessions-test--answers)))
            (should-not (harness-ui-session "a"))
            (should-not (harness-ui-session "c"))
            (should (harness-ui-session "b"))
            (should (= 1 redraws))
            (should (equal '("b" "d") (harness-ui-sessions-test--shown)))
            (should-not (harness-ui-sessions-test--starred))
            (should (= 0 (hash-table-count harness-ui-sessions--marked)))
            (should (equal " [Pause] [project]" (harness-ui-sessions-test--mode-line)))
            ;; Nothing marked: the session at point, named.
            (setq asked nil harness-ui-sessions-test--requests nil)
            (harness-ui-sessions-test--goto "b")
            (should (equal '("Session deleted")
                           (harness-ui-sessions-test--messages
                            (lambda () (harness-ui-sessions-test--press "d")))))
            (should (equal '("Delete session b? ") asked))
            (should (equal '(("_harness/session/delete" (:id "b")))
                           (harness-ui-sessions-test--answers)))
            (should (equal '("d") (harness-ui-sessions-test--shown)))
            ;; One that cannot be deleted says so and keeps its mark.
            (harness-ui-sessions-test--add "e" root :updated 50)
            (harness-ui-sessions-test--add "f" root :updated 40)
            (harness-ui-sessions--redraw)
            (setq asked nil harness-ui-sessions-test--requests nil)
            (let ((harness-ui-sessions-test--refused '("f")))
              (harness-ui-sessions-test--mark "e" "f")
              (harness-ui-sessions-test--goto "d")
              (let ((said (harness-ui-sessions-test--messages
                           (lambda () (harness-ui-sessions-test--press "d")))))
                (should (= 2 (length said)))
                (should (string-match-p "_harness/session/delete failed" (car said)))
                (should (equal "Deleted 1 of 2 sessions" (cadr said)))))
            (should (equal '("d" "f") (harness-ui-sessions-test--shown)))
            (should (equal '("f") (harness-ui-sessions-test--starred)))
            ;; The question says how many marked sessions are out of view.
            (let ((harness-ui-sessions-test--refused nil))
              (harness-ui-sessions-test--add "h" root :status "inactive" :updated 1)
              (harness-ui-sessions--redraw)
              (harness-ui-sessions-test--mark "h")
              (harness-ui-sessions-test--press "i")
              (setq asked nil answer nil)
              (harness-ui-sessions-test--press "d")
              (should (equal '("Delete 2 marked sessions, 1 of them not listed? ") asked)))))))))

(ert-deftest harness-ui-sessions-cancel-the-turns-of-the-marked-sessions ()
  "Cancelling cancels the turn of every marked session that has one.
A session has one when it runs or is blocked.  The others are skipped and keep their marks, the ones cancelled are
unmarked, and several sessions get a message saying how many turns were
cancelled.  A mark outweighs point.  Without marks k acts on the session
at point, which says so when it has no turn."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "busy" root :status "running" :updated 500)
    (harness-ui-sessions-test--blocked "asks" root "permission" :updated 400)
    (harness-ui-sessions-test--add "idle" root :updated 300)
    (harness-ui-sessions-test--add "other" root :updated 200)
    (let ((default-directory root)) (harness-sessions))
    (let ((cancelled nil))
      (cl-letf (((symbol-function 'harness-cancel-turn) (lambda (id) (push id cancelled))))
        (with-current-buffer harness-ui-sessions--buffer-name
          (harness-ui-sessions-test--mark "busy" "asks" "idle")
          (harness-ui-sessions-test--goto "other")
          (should (equal '("Cancelling 2 turns; 1 not running")
                         (harness-ui-sessions-test--messages
                          (lambda () (harness-ui-sessions-test--press "k")))))
          (should (equal '("busy" "asks") (reverse cancelled)))
          (should (equal '("idle") (harness-ui-sessions-test--starred)))
          ;; The session still marked is the target, not the one at point.
          (setq cancelled nil)
          (harness-ui-sessions-test--goto "busy")
          (should (equal '("idle is not running")
                         (harness-ui-sessions-test--messages
                          (lambda () (harness-ui-sessions-test--press "k")))))
          (should-not cancelled)
          (harness-ui-sessions-test--mark "other")
          (should (equal '("None of the 2 sessions is running")
                         (harness-ui-sessions-test--messages
                          (lambda () (harness-ui-sessions-test--press "k")))))
          (should (equal '("idle" "other") (harness-ui-sessions-test--starred)))
          ;; Without marks, the session at point, whose own message is
          ;; harness-cancel-turn's.
          (harness-ui-sessions-test--press "U")
          (harness-ui-sessions-test--goto "asks")
          (should-not (harness-ui-sessions-test--messages
                       (lambda () (harness-ui-sessions-test--press "k"))))
          (should (equal '("asks") cancelled)))))))

(ert-deftest harness-ui-sessions-deactivate-the-marked-sessions ()
  "Deactivating deactivates every marked session, or the session at point.
Each goes by `_harness/session/deactivate'; once the last is answered the
sessions are unmarked, the list is redrawn once and one message says how
many were deactivated."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--rows root '("a" "b" "c"))
    (harness-ui-sessions-test--counting-redraws redraws
      (with-current-buffer harness-ui-sessions--buffer-name
        (harness-ui-sessions-test--mark "a" "c")
        (harness-ui-sessions-test--goto "b")
        (setq redraws 0)
        (should (equal '("Deactivated 2 sessions")
                       (harness-ui-sessions-test--messages
                        (lambda () (harness-ui-sessions-test--press "x")))))
        (should (equal '(("_harness/session/deactivate" (:id "a"))
                         ("_harness/session/deactivate" (:id "c")))
                       (harness-ui-sessions-test--answers)))
        (should (= 1 redraws))
        (should-not (harness-ui-sessions-test--starred))
        (should (= 0 (hash-table-count harness-ui-sessions--marked)))
        ;; Nothing marked: the session at point.
        (setq harness-ui-sessions-test--requests nil)
        (harness-ui-sessions-test--goto "b")
        (should (equal '("Deactivated b")
                       (harness-ui-sessions-test--messages
                        (lambda () (harness-ui-sessions-test--press "x")))))
        (should (equal '(("_harness/session/deactivate" (:id "b")))
                       (harness-ui-sessions-test--answers)))))))

(ert-deftest harness-ui-sessions-set-the-priority-of-the-marked-sessions ()
  "Setting the priority asks for the level once, for every marked session.
They are given it in one request, `_harness/priority/set-all' with their
ids as the filter; one session, marked or at point, is set as for one.
+ and - shift the priority of each, and with a prefix ask once for a
level.  The marks stay after all of them, so more can be given to the
same sessions."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--rows root '("a" "b" "c"))
    (let ((asked nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt &rest _) (push prompt asked) "high")))
        (with-current-buffer harness-ui-sessions--buffer-name
          (harness-ui-sessions-test--mark "a" "b")
          (harness-ui-sessions-test--goto "c")
          ;; p: one question, one request for both, the marks kept.
          (should (equal '("Priority → high for 2 sessions")
                         (harness-ui-sessions-test--messages
                          (lambda () (harness-ui-sessions-test--press "p")))))
          (should (equal '("Priority for the 2 marked sessions: ") asked))
          (should (equal '(("_harness/priority/set-all"
                            (:priority "high" :filter (:ids ("a" "b")))))
                         (harness-ui-sessions-test--answers)))
          (should (equal '("a" "b") (harness-ui-sessions-test--starred)))
          ;; C-u + and C-u - ask once, too, through the same command.
          (setq asked nil harness-ui-sessions-test--requests nil)
          (let ((current-prefix-arg '(4))) (harness-ui-sessions-test--press "+"))
          (let ((current-prefix-arg '(4))) (harness-ui-sessions-test--press "-"))
          (should (= 2 (length asked)))
          (should (equal '("_harness/priority/set-all" "_harness/priority/set-all")
                         (mapcar #'car (harness-ui-sessions-test--answers))))
          (should (equal '("a" "b") (harness-ui-sessions-test--starred)))
          ;; + and - shift each marked session's priority, the marks kept.
          (let (shifted)
            (cl-letf (((symbol-function 'harness-priority-shift-session)
                       (lambda (id step &optional _done) (push (list id step) shifted))))
              (harness-ui-sessions-test--press "+")
              (harness-ui-sessions-test--press "-"))
            (should (equal '(("a" 1) ("b" 1) ("a" -1) ("b" -1)) (reverse shifted))))
          (should (equal '("a" "b") (harness-ui-sessions-test--starred)))
          ;; Unstubbed, each is raised by its own request, and one message
          ;; counts the sessions that reached a new level.
          (setq harness-ui-sessions-test--requests nil)
          (should (equal '("Priority raised for 1 of 2 sessions" "Priority raised for 2 of 2 sessions")
                         (harness-ui-sessions-test--messages
                          (lambda () (harness-ui-sessions-test--press "+")))))
          (should (equal '(("_harness/priority/set" (:sessionId "a" :priority "high"))
                           ("_harness/priority/set" (:sessionId "b" :priority "high")))
                         (harness-ui-sessions-test--answers)))
          (should (equal '("a" "b") (harness-ui-sessions-test--starred)))
          ;; One marked session is set as one is, by the request for one.
          (harness-ui-sessions-test--press "U")
          (harness-ui-sessions-test--mark "c")
          (harness-ui-sessions-test--goto "a")
          (setq asked nil harness-ui-sessions-test--requests nil)
          (harness-ui-sessions-test--press "p")
          (should (equal '("Priority: ") asked))
          (should (equal '(("_harness/priority/set" (:sessionId "c" :priority "high")))
                         (harness-ui-sessions-test--answers))))))))

(ert-deftest harness-ui-sessions-make-tasks-of-the-marked-sessions ()
  "Making tasks adopts every marked session that is no task yet.
One message says how many.  A session that is a task already is skipped
and keeps its mark; the ones adopted are unmarked.  Without marks it is
the session at point, as it was."
  (harness-ui-sessions-test-with-repo
    (setq harness-ui-sessions-test--tasks
          (list (list :id "t-1" :session "a" :state "active" :prompt "Paginate GET /orders")))
    (harness-ui-sessions-test--rows root '("a" "b" "c" "d"))
    (with-current-buffer harness-ui-sessions--buffer-name
      (harness-ui-sessions-test--mark "a" "b" "c")
      (harness-ui-sessions-test--goto "d")
      (let ((said (harness-ui-sessions-test--messages
                   (lambda () (harness-ui-sessions-test--press "M-t")))))
        (should (= 1 (length said)))
        (should (string-match-p "\\`Added 2 sessions to the task board (.*); 1 was a task already\\'"
                                (car said))))
      (should (equal '(("_harness/task/adopt" (:session-id "b"))
                       ("_harness/task/adopt" (:session-id "c")))
                     (harness-ui-sessions-test--answers)))
      (should (equal '("a") (harness-ui-sessions-test--starred)))
      ;; Only tasks marked: nothing to adopt, and nothing sent.
      (setq harness-ui-sessions-test--requests nil)
      (should (equal '("a is a task already")
                     (harness-ui-sessions-test--messages
                      (lambda () (harness-ui-sessions-test--press "M-t")))))
      (should-not (harness-ui-sessions-test--answers))
      (should (equal '("a") (harness-ui-sessions-test--starred)))
      ;; Nothing marked: the session at point.
      (harness-ui-sessions-test--press "U")
      (harness-ui-sessions-test--goto "d")
      (should (string-match-p "\\`Added to the task board ("
                              (car (harness-ui-sessions-test--messages
                                    (lambda () (harness-ui-sessions-test--press "M-t"))))))
      (should (equal '(("_harness/task/adopt" (:session-id "d")))
                     (harness-ui-sessions-test--answers))))))

(ert-deftest harness-ui-sessions-one-session-commands-refuse-marks ()
  "Fork, rename and move refuse while any session is marked.
They act on one session, and say to unmark first (U); they ask for
nothing and send nothing then.  RET still opens the session at point,
marked or not.  Without marks they act on the session at point."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--rows root '("a" "b"))
    (let ((ran nil))
      (cl-letf (((symbol-function 'harness-fork-session) (lambda (id &rest _) (push (list 'fork id) ran)))
                ((symbol-function 'harness-rename-session) (lambda (name id) (push (list 'rename name id) ran)))
                ((symbol-function 'harness-move-session) (lambda (dir id &rest _) (push (list 'move dir id) ran)))
                ((symbol-function 'harness-ui-visit-session) (lambda (id &rest _) (push (list 'open id) ran)))
                ((symbol-function 'read-string) (lambda (&rest _) (error "Asked")))
                ((symbol-function 'read-directory-name) (lambda (&rest _) (error "Asked"))))
        (with-current-buffer harness-ui-sessions--buffer-name
          (harness-ui-sessions-test--mark "a")
          (harness-ui-sessions-test--goto "b")
          (dolist (keys '("f" "r" "M"))
            (ert-info (keys)
              (let ((err (should-error (harness-ui-sessions-test--press keys) :type 'user-error)))
                (should (string-match-p "acts on one session, but one is marked: unmark it first (U)"
                                        (cadr err))))))
          (should-not ran)
          (should (equal '("a") (harness-ui-sessions-test--starred)))
          ;; Opening is the session at point's.
          (harness-ui-sessions-test--press "RET")
          (should (equal '((open "b")) ran))
          ;; Unmarked, they act on the session at point.
          (harness-ui-sessions-test--press "U")
          (harness-ui-sessions-test--goto "b")
          (harness-ui-sessions-test--press "f")
          (should (equal '((fork "b") (open "b")) ran))
          (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "Fresh name")))
            (harness-ui-sessions-test--press "r"))
          (should (equal '(rename "Fresh name" "b") (car ran))))))))

(ert-deftest harness-ui-sessions-menu-offers-the-marks ()
  "The harness menu lists the marking keys beside the commands they feed.
The group says its commands act on the marked sessions too, and move is
at M now that m marks."
  (let* ((group (get 'harness-ui-sessions-mode 'harness-menu-group))
         (column (cl-find "Session at point, or the marked ones" (cdr group)
                          :key (lambda (column) (aref column 0)) :test #'equal))
         (entries (and column (cl-remove-if-not #'consp (append column nil)))))
    (should (equal "Session list" (car group)))
    (should column)
    (dolist (entry '((". m" "Mark" harness-ui-sessions-mark)
                     (". u" "Unmark" harness-ui-sessions-unmark)
                     (". U" "Unmark all" harness-ui-sessions-unmark-all)
                     (". t" "Invert marks" harness-ui-sessions-toggle-marks)
                     (". M" "Move to another directory" harness-ui-sessions-move)
                     (". f" "Fork" harness-ui-sessions-fork)
                     (". d" "Delete" harness-ui-sessions-delete)
                     (". k" "Cancel turn" harness-ui-sessions-cancel)
                     (". x" "Deactivate" harness-ui-sessions-deactivate)
                     ("M-t" "Make it a task" harness-ui-sessions-make-task)
                     (". +" "Raise priority" harness-ui-sessions-raise-priority)
                     (". p" "Set priority…" harness-ui-sessions-set-priority)))
      (ert-info ((format "%S" entry))
        (should (member entry entries))))
    ;; Each key is listed once, and move has only the key M now.
    (let ((keys (mapcar #'car entries)))
      (should (equal keys (delete-dups (copy-sequence keys)))))
    (should (= 1 (cl-count 'harness-ui-sessions-move entries :key #'caddr)))
    (should (equal ". M" (car (cl-find 'harness-ui-sessions-move entries :key #'caddr))))))

;;;; The harness's setting commands

(defun harness-ui-sessions-test--settings-rows (root)
  "Cache three sessions in ROOT that have settings of their own, and open the list.
The sessions a, b and c come in this order.  a and b are on the model
demo:scripted and in the mode auto, c is on demo:other in yolo; a and c
think at high, b at low; a and c are non-interactive, b is not; a and b
supervise, c is hands-on."
  (harness-ui-sessions-test--add "a" root :updated 300 :model "demo:scripted" :thinking "high"
                                 :permission-mode "auto" :non-interactive t
                                 :ext '(:supervisor t))
  (harness-ui-sessions-test--add "b" root :updated 200 :model "demo:scripted" :thinking "low"
                                 :permission-mode "auto" :non-interactive :false
                                 :ext '(:supervisor t))
  (harness-ui-sessions-test--add "c" root :updated 100 :model "demo:other" :thinking "high"
                                 :permission-mode "yolo" :non-interactive t
                                 :ext '(:supervisor :false))
  (let ((default-directory root)) (harness-sessions)))

(defun harness-ui-sessions-test--b-is-a-task ()
  "Have the harness say that session b works on the task t-1."
  (setq harness-ui-sessions-test--tasks
        (list (list :id "t-1" :session "b" :state "active" :prompt "Paginate GET /orders"))))

(ert-deftest harness-ui-sessions-setting-target-is-the-marked-sessions-or-the-one-at-point ()
  "The list tells the setting commands what to change, in the list only.
With no session marked it is the id of the session at point, a string,
so the commands act on that session as in its chat, and nil where point
is on no session, so they ask which.  With sessions marked it is
\(VALUES SET-FN CONTEXT) for them, wherever point is."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--settings-rows root)
    (with-temp-buffer (should-not harness-ui-setting-target-function))
    (with-current-buffer harness-ui-sessions--buffer-name
      (should (local-variable-p 'harness-ui-setting-target-function))
      (should (eq #'harness-ui-sessions--setting-target harness-ui-setting-target-function))
      ;; No mark: the session at point, which is what the commands use.
      (harness-ui-sessions-test--goto "b")
      (should (equal "b" (harness-ui-sessions--setting-target)))
      (should (equal "b" (harness-ui--setting-target nil)))
      ;; Where point is on no session the commands ask, as they do anywhere.
      (goto-char (point-max))
      (should-not (tabulated-list-get-id))
      (should-not (harness-ui-sessions--setting-target))
      (cl-letf (((symbol-function 'harness-ui-current-session-id) (lambda (&rest _) "asked")))
        (should (equal "asked" (harness-ui--setting-target nil))))
      ;; Marked: the marked sessions, whichever row point is on.
      (harness-ui-sessions-test--mark "a" "b")
      (harness-ui-sessions-test--goto "c")
      (let ((target (harness-ui-sessions--setting-target)))
        (should (equal (list #'harness-ui-sessions--set-marked "for the 2 marked sessions")
                       (cdr target)))
        (should (equal target (harness-ui--setting-target nil))))
      (goto-char (point-max))
      (should (consp (harness-ui-sessions--setting-target)))
      ;; One mark is still the marks: the sessions' own checks come with them.
      (harness-ui-sessions-test--press "U")
      (harness-ui-sessions-test--mark "c")
      (should (equal "for the marked session" (nth 2 (harness-ui-sessions--setting-target))))
      ;; A marked session the filters hide counts.
      (harness-ui-sessions-test--press "U")
      (harness-ui-sessions-test--add "h" root :status "inactive" :updated 1)
      (harness-ui-sessions--redraw)
      (harness-ui-sessions-test--mark "a" "h")
      (harness-ui-sessions-test--press "i")
      (should-not (assoc "h" tabulated-list-entries))
      (should (equal "for the 2 marked sessions" (nth 2 (harness-ui-sessions--setting-target)))))))

(ert-deftest harness-ui-sessions-setting-values-are-what-the-marked-sessions-agree-on ()
  "The values the commands read are those all the marked sessions have.
A setting on which the sessions differ is left out, so it reads as none;
one they share is there, a switch that is off as nil and `:false' alike.
The supervisor mode is the `:supervisor' of a session's `:ext'.
`harness-ui--setting-get' reads them, as the menu's label of
non-interactive mode does."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--settings-rows root)
    (harness-ui-sessions-test--add "d" root :updated 50 :non-interactive :false)
    (harness-ui-sessions-test--add "e" root :updated 40 :thinking nil)
    (harness-ui-sessions--redraw)
    (with-current-buffer harness-ui-sessions--buffer-name
      (cl-flet ((agreed (&rest ids)
                  (harness-ui-sessions-test--press "U")
                  (apply #'harness-ui-sessions-test--mark ids)
                  (harness-ui-sessions--setting-target)))
        ;; a and b share the model, the mode and supervising, not the rest.
        (let ((target (agreed "a" "b")))
          (should (equal '(:model "demo:scripted" :permission-mode "auto" :supervisor t)
                         (car target)))
          (should (equal "demo:scripted" (harness-ui--setting-get target :model)))
          (should (equal "auto" (harness-ui--setting-get target :permission-mode)))
          (should (eq t (harness-ui--setting-get target :supervisor)))
          (should-not (harness-ui--setting-get target :thinking))
          (should-not (plist-member (car target) :thinking))
          (should-not (plist-member (car target) :non-interactive)))
        ;; a and c share the level and being non-interactive.
        (let ((target (agreed "a" "c")))
          (should (equal '(:thinking "high" :non-interactive t) (car target)))
          (should (harness-json-true-p (harness-ui--setting-get target :non-interactive)))
          (should (equal "Non-interactive: on" (harness-ui--non-interactive-menu-label))))
        ;; The menu says off where they differ, as the command then turns it on.
        (should (equal "Non-interactive: off"
                       (progn (agreed "a" "b") (harness-ui--non-interactive-menu-label))))
        ;; d and e are off, one explicitly, and think as their models do.
        (let ((target (agreed "d" "e")))
          (should (equal '(:model "demo:scripted" :thinking nil :permission-mode "auto"
                           :non-interactive :false :supervisor nil)
                         (car target)))
          (should-not (harness-json-true-p (harness-ui--setting-get target :non-interactive))))
        ;; Not governed by the supervisor module and hands-on are not alike.
        (should-not (plist-member (car (agreed "c" "d")) :supervisor))
        (should (eq :false (harness-ui--setting-get (agreed "c") :supervisor)))
        ;; Not marked, the label is that of the session at point.
        (harness-ui-sessions-test--press "U")
        (harness-ui-sessions-test--goto "b")
        (should (equal "Non-interactive: off" (harness-ui--non-interactive-menu-label)))
        (harness-ui-sessions-test--goto "a")
        (should (equal "Non-interactive: on" (harness-ui--non-interactive-menu-label)))))))

(ert-deftest harness-ui-sessions-set-a-setting-on-the-marked-sessions-and-their-tasks ()
  "A setting changes the marked sessions together, and the tasks they work on.
The sessions go in one request, `_harness/session/set-all' with their
ids as the filter.  Then the marked sessions that work on a task give one
`_harness/task/set-all' with the ids of those tasks and no project, as
they may be of several, so each task's record keeps the setting for its
next start.  One message says what changed.  The marks stay, and are
read in the list when the change is made, whichever buffer is current."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--b-is-a-task)
    (harness-ui-sessions-test--settings-rows root)
    (with-current-buffer harness-ui-sessions--buffer-name
      (harness-ui-sessions-test--mark "a" "b")
      (harness-ui-sessions-test--goto "c")
      (let* ((target (harness-ui--setting-target nil))
             (said (harness-ui-sessions-test--messages
                    (lambda ()
                      ;; The setting comes from another buffer, as the reply to a
                      ;; question does.
                      (with-temp-buffer
                        (harness-ui--setting-set target :thinking "high" "Thinking → high"))))))
        ;; Both are said, the first when the change is given and the second
        ;; once the harness has answered.
        (should (= 2 (length said)))
        (should (member "Thinking → high (for the 2 marked sessions)" said))
        (should (member "Thinking → high for 2 sessions (1 task)" said)))
      (should (equal '(("_harness/session/set-all"
                        (:settings (:thinking "high") :filter (:ids ("a" "b"))))
                       ("_harness/task/set-all"
                        (:settings (:thinking "high") :filter (:ids ("t-1")))))
                     (harness-ui-sessions-test--answers)))
      (should (equal '("a" "b") (harness-ui-sessions-test--starred)))
      (should (equal '("a" "b") (harness-ui-sessions--marked-ids)))
      ;; The same sessions can be given another setting; with no task among
      ;; them there is no request for tasks.
      (setq harness-ui-sessions-test--requests nil)
      (harness-ui-sessions--forget-task "t-1")
      (harness-ui-sessions--set-marked :permission-mode "yolo")
      (should (equal '(("_harness/session/set-all"
                        (:settings (:permission-mode "yolo") :filter (:ids ("a" "b")))))
                     (harness-ui-sessions-test--answers)))
      (should (equal '("a" "b") (harness-ui-sessions-test--starred))))))

(ert-deftest harness-ui-sessions-say-how-a-setting-change-went ()
  "One message says how many sessions and tasks changed, or why nothing did.
The harness leaves a session that has the setting already alone; a
message says so, and counts the ones it changed.  A task request that
fails is told after what the sessions got, and a session request that
fails ends it there: no task is changed.  Nothing marked changes
nothing."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--b-is-a-task)
    (harness-ui-sessions-test--settings-rows root)
    (with-current-buffer harness-ui-sessions--buffer-name
      (cl-flet ((say (&optional reply (value "high"))
                  (setq harness-ui-sessions-test--requests nil
                        harness-ui-sessions-test--replies reply)
                  (car (last (harness-ui-sessions-test--messages
                              (lambda () (harness-ui-sessions--set-marked :thinking value)))))))
        (harness-ui-sessions-test--mark "a" "b")
        ;; All changed, as the harness answers by itself.
        (should (equal "Thinking → high for 2 sessions (1 task)" (say)))
        ;; One had it already.
        (should (equal "Thinking → high for 1 of 2 sessions (1 task)"
                       (say '(("_harness/session/set-all" . ("a"))))))
        ;; No task changed, or no session.
        (should (equal "Thinking → high for 2 sessions"
                       (say '(("_harness/task/set-all" . nil)))))
        (should (equal "Thinking → high (1 task)"
                       (say '(("_harness/session/set-all" . nil)))))
        (should (equal "Thinking → high: nothing to change in the 2 marked sessions"
                       (say '(("_harness/session/set-all" . nil) ("_harness/task/set-all" . nil)))))
        ;; The tasks' request fails after the sessions' did not.
        (let ((said (say '(("_harness/task/set-all" . fail)))))
          (should (string-match-p
                   "\\`Thinking → high for 2 sessions, but the tasks' settings did not change: .*task/set-all failed"
                   said)))
        ;; The sessions' request fails: the tasks are not asked.
        (let ((said (say '(("_harness/session/set-all" . fail)))))
          (should (string-match-p "\\`Thinking → high failed: .*session/set-all failed" said))
          (should (equal '("_harness/session/set-all")
                         (mapcar #'car (harness-ui-sessions-test--answers)))))
        (should (equal '("a" "b") (harness-ui-sessions-test--starred)))
        ;; No level is the model's default.
        (should (equal "Thinking → default for 2 sessions (1 task)" (say nil nil)))
        (should (equal '(:settings (:thinking nil))
                       (cl-subseq (cadr (car (harness-ui-sessions-test--answers))) 0 2)))
        ;; One session says so in its count.
        (harness-ui-sessions-test--press "U")
        (harness-ui-sessions-test--mark "a")
        (should (equal "Thinking → high for 1 session" (say)))
        ;; Nothing marked: nothing is sent.
        (harness-ui-sessions-test--press "U")
        (setq harness-ui-sessions-test--requests nil)
        (should (equal '("No session is marked")
                       (harness-ui-sessions-test--messages
                        (lambda () (harness-ui-sessions--set-marked :thinking "high")))))
        (should-not (harness-ui-sessions-test--answers))))))

(ert-deftest harness-ui-sessions-set-the-model-of-the-marked-sessions ()
  "A model switch of the marked sessions is checked first, for all of them.
When no session would lose its conversation, they switch together
\(`session/set-all').  When one would, `harness-ui-switch-function' asks
once, as `harness-set-model-all' has it ask, for no session and the list
as its host: the checks of the sessions that lose theirs, the model's
label and how many sessions change in all.  The mode it answers goes to
`handoff/switch-all' with the same sessions; `cancel' sends nothing.  A
harness that cannot check switches them as it always did.  The tasks take
the model after the sessions, and the default model stays."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--b-is-a-task)
    (harness-ui-sessions-test--settings-rows root)
    (let* ((model "demo:other")
           (label (harness-ui-model-label model))
           (asked nil) (answer nil)
           (harness-ui-switch-function
            (lambda (&rest args) (push (butlast args) asked) (setq answer (car (last args)))))
           (lossy (list :id "a" :from "demo:scripted" :lossy t :reason "A provider of its own"
                        :risks '("Context lost: the new model starts again"))))
      (with-current-buffer harness-ui-sessions--buffer-name
        (harness-ui-sessions-test--mark "a" "b")
        (let ((target (harness-ui-sessions--setting-target)))
          (cl-flet ((switch ()
                      (setq harness-ui-sessions-test--requests nil asked nil answer nil)
                      (harness-ui-sessions-test--messages
                       (lambda () (harness-ui--setting-set target :model model (format "Model → %s" label))))))
            ;; Nothing is lost: checked, switched, and the task's record follows.
            (should (member (format "Model → %s for 2 sessions (1 task)" label) (switch)))
            (should (equal `(("_harness/handoff/check-all" (:model ,model :filter (:ids ("a" "b"))))
                             ("_harness/session/set-all"
                              (:settings (:model ,model) :filter (:ids ("a" "b"))))
                             ("_harness/task/set-all"
                              (:settings (:model ,model) :filter (:ids ("t-1")))))
                           (harness-ui-sessions-test--answers)))
            (should-not asked)
            ;; One would lose its conversation: asked once, and nothing sent yet.
            (setq harness-ui-sessions-test--replies
                  `(("_harness/handoff/check-all"
                     . ,(list lossy (list :id "b" :from "demo:scripted" :lossy :false)))))
            (switch)
            ;; For no session, and the list the command ran in as the host.
            (should (equal `(((,lossy) ,label 2 nil ,(get-buffer harness-ui-sessions--buffer-name))) asked))
            (should (equal '("_harness/handoff/check-all")
                           (mapcar #'car (harness-ui-sessions-test--answers))))
            ;; The answer goes to the switch of the same sessions, then to their
            ;; tasks, and the message says how the conversations went over.
            (should (equal (list (format "Model → %s for 2 sessions, summarising the conversations that need it first (1 task)"
                                         label))
                           (harness-ui-sessions-test--messages (lambda () (funcall answer 'compact)))))
            (should (equal `(("_harness/handoff/check-all" (:model ,model :filter (:ids ("a" "b"))))
                             ("_harness/handoff/switch-all"
                              (:model ,model :filter (:ids ("a" "b")) :mode "compact"))
                             ("_harness/task/set-all"
                              (:settings (:model ,model) :filter (:ids ("t-1")))))
                           (harness-ui-sessions-test--answers)))
            ;; Without a handoff they just switch, and the message has nothing to add.
            (switch)
            (should (equal (list (format "Model → %s for 2 sessions (1 task)" label))
                           (harness-ui-sessions-test--messages (lambda () (funcall answer 'none)))))
            (should (equal '(:model "demo:other" :filter (:ids ("a" "b")) :mode "none")
                           (cadr (cadr (harness-ui-sessions-test--answers)))))
            ;; Cancelled: nothing more is sent, and the marks stay.
            (switch)
            (should (equal '("Models unchanged")
                           (harness-ui-sessions-test--messages (lambda () (funcall answer 'cancel)))))
            (should (equal '("_harness/handoff/check-all")
                           (mapcar #'car (harness-ui-sessions-test--answers))))
            (should (equal '("a" "b") (harness-ui-sessions-test--starred)))
            ;; A harness that cannot check switches them at once.
            (setq harness-ui-sessions-test--replies '(("_harness/handoff/check-all" . fail)))
            (switch)
            (should-not asked)
            (should (equal '("_harness/handoff/check-all" "_harness/session/set-all"
                             "_harness/task/set-all")
                           (mapcar #'car (harness-ui-sessions-test--answers))))
            ;; The switch itself failing is said, with why.
            (setq harness-ui-sessions-test--replies '(("_harness/session/set-all" . fail)))
            (should (cl-some (lambda (said)
                               (string-match-p (format "\\`Model → %s failed: .*session/set-all failed"
                                                       (regexp-quote label))
                                               said))
                             (switch)))))))))

(ert-deftest harness-ui-sessions-set-the-switches-and-modes-of-the-marked-sessions ()
  "The other settings go the way the commands send them.
A permission mode and non-interactive mode are session settings, and an
off switch goes as `:false', as it does for one session.  The
supervisor mode is its module's: `_harness/supervisor/set-all' takes it
as `:on' with the sessions' ids as the filter, and the task's record as
`:supervisor'."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--b-is-a-task)
    (harness-ui-sessions-test--settings-rows root)
    (with-current-buffer harness-ui-sessions--buffer-name
      (harness-ui-sessions-test--mark "a" "b")
      (cl-flet ((give (key value)
                  (setq harness-ui-sessions-test--requests nil)
                  (harness-ui-sessions-test--messages
                   (lambda () (harness-ui--setting-set (harness-ui-sessions--setting-target)
                                                       key value "Set")))
                  (harness-ui-sessions-test--answers)))
        (should (equal '(("_harness/session/set-all"
                          (:settings (:non-interactive :false) :filter (:ids ("a" "b"))))
                         ("_harness/task/set-all"
                          (:settings (:non-interactive :false) :filter (:ids ("t-1")))))
                       (give :non-interactive nil)))
        (should (equal '(("_harness/session/set-all"
                          (:settings (:non-interactive t) :filter (:ids ("a" "b"))))
                         ("_harness/task/set-all"
                          (:settings (:non-interactive t) :filter (:ids ("t-1")))))
                       (give :non-interactive t)))
        (should (equal '(("_harness/session/set-all"
                          (:settings (:permission-mode "yolo") :filter (:ids ("a" "b"))))
                         ("_harness/task/set-all"
                          (:settings (:permission-mode "yolo") :filter (:ids ("t-1")))))
                       (give :permission-mode "yolo")))
        (should (equal '(("_harness/supervisor/set-all" (:on t :filter (:ids ("a" "b"))))
                         ("_harness/task/set-all" (:settings (:supervisor t) :filter (:ids ("t-1")))))
                       (give :supervisor t)))
        (should (equal '(("_harness/supervisor/set-all" (:on :false :filter (:ids ("a" "b"))))
                         ("_harness/task/set-all"
                          (:settings (:supervisor :false) :filter (:ids ("t-1")))))
                       (give :supervisor :false)))
        ;; An off switch is never nil on the wire.
        (should (equal :false (plist-get (cadr (car (give :supervisor nil))) :on)))
        (should (equal '("a" "b") (harness-ui-sessions-test--starred)))
        ;; What each says once it is done.
        (should (equal "Supervisor mode off (hands-on) for 2 sessions (1 task)"
                       (car (last (harness-ui-sessions-test--messages
                                   (lambda () (harness-ui-sessions--set-marked :supervisor :false)))))))
        (should (equal "Non-interactive on for 2 sessions (1 task)"
                       (car (last (harness-ui-sessions-test--messages
                                   (lambda () (harness-ui-sessions--set-marked :non-interactive t)))))))
        (should (equal (format "Permission mode → %s for 2 sessions (1 task)"
                               (harness-ui-permission-mode-label "yolo"))
                       (car (last (harness-ui-sessions-test--messages
                                   (lambda () (harness-ui-sessions--set-marked :permission-mode "yolo")))))))))))

(ert-deftest harness-ui-sessions-setting-commands-change-the-marked-sessions ()
  "The commands themselves, run in the list, change the marked sessions.
They read the values the sessions agree on, ask for the new one as
anywhere, and send the change for all of them: the model, the level, the
mode, non-interactive mode and supervisor mode.  The marks stay, so the
same sessions can be given the next.  Unmarked, a command changes the
session at point as in its chat: the model is checked for that session
alone."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--b-is-a-task)
    (harness-ui-sessions-test--settings-rows root)
    (setq harness-ui-sessions-test--replies
          '(("_harness/provider/model" . (:thinking-levels ("low" "high")))))
    (let ((prompts nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt table &rest _)
                   (push prompt prompts)
                   (pcase prompt
                     ("Thinking: " "high")
                     ("Permission mode: " "YOLO")
                     ("Model: " (caar table))
                     (_ (error "Unexpected question %s" prompt)))))
                ((symbol-function 'harness-ui-refresh-models)
                 (lambda (&optional callback)
                   (funcall callback (list (list :id "demo:other" :label "Other" :provider-label "Demo"))))))
        (with-current-buffer harness-ui-sessions--buffer-name
          (cl-flet ((run (command)
                      (setq harness-ui-sessions-test--requests nil)
                      (call-interactively command)
                      (harness-ui-sessions-test--answers)))
            (harness-ui-sessions-test--mark "a" "b")
            (harness-ui-sessions-test--goto "c")
            (should (equal '(("_harness/provider/model" (:model-id "demo:scripted"))
                             ("_harness/session/set-all"
                              (:settings (:thinking "high") :filter (:ids ("a" "b"))))
                             ("_harness/task/set-all"
                              (:settings (:thinking "high") :filter (:ids ("t-1")))))
                           (run #'harness-set-thinking)))
            (should (equal '(("_harness/session/set-all"
                              (:settings (:permission-mode "yolo") :filter (:ids ("a" "b"))))
                             ("_harness/task/set-all"
                              (:settings (:permission-mode "yolo") :filter (:ids ("t-1")))))
                           (run #'harness-set-permission-mode)))
            ;; Their levels differ: toggled, it turns the mode on for all.
            (should (equal '(("_harness/session/set-all"
                              (:settings (:non-interactive t) :filter (:ids ("a" "b"))))
                             ("_harness/task/set-all"
                              (:settings (:non-interactive t) :filter (:ids ("t-1")))))
                           (run #'harness-toggle-non-interactive)))
            (should (equal '(("_harness/supervisor/set-all" (:on :false :filter (:ids ("a" "b"))))
                             ("_harness/task/set-all"
                              (:settings (:supervisor :false) :filter (:ids ("t-1")))))
                           (run #'harness-toggle-supervisor)))
            (should (equal `(("_harness/handoff/check-all"
                              (:model "demo:other" :filter (:ids ("a" "b"))))
                             ("_harness/session/set-all"
                              (:settings (:model "demo:other") :filter (:ids ("a" "b"))))
                             ("_harness/task/set-all"
                              (:settings (:model "demo:other") :filter (:ids ("t-1")))))
                           (run #'harness-set-model)))
            (should (equal '("a" "b") (harness-ui-sessions-test--starred)))
            ;; Both are non-interactive: toggled, it turns the mode off for them.
            (harness-ui-sessions-test--press "U")
            (harness-ui-sessions-test--mark "a" "c")
            (should (equal '(("_harness/session/set-all"
                              (:settings (:non-interactive :false) :filter (:ids ("a" "c")))))
                           (run #'harness-toggle-non-interactive)))
            ;; Not marked: the session at point, as in its chat.
            (harness-ui-sessions-test--press "U")
            (harness-ui-sessions-test--goto "b")
            (should (equal '(("_harness/session/update" (:id "b" :non-interactive t)))
                           (run #'harness-toggle-non-interactive)))
            (should (equal `(("_harness/handoff/check" (:sessionId "b" :model "demo:other"))
                             ("session/set_model" (:sessionId "b" :modelId "demo:other")))
                           (run #'harness-set-model)))
            (should (equal '(("session/set_mode" (:sessionId "b" :modeId "yolo")))
                           (run #'harness-set-permission-mode)))))))))

(ert-deftest harness-ui-sessions-menu-settings-act-on-the-marked-sessions ()
  "The menu's settings, opened from the list, change the marked sessions.
The list binds no key to them, its m, T, p and i being others, so its
menu group does not list them: the menu's own Session settings column
does, and its commands run in the list, where the marks are.  The label
of non-interactive mode says what the marked sessions have."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--b-is-a-task)
    (harness-ui-sessions-test--settings-rows root)
    (save-window-excursion
      (delete-other-windows)
      (switch-to-buffer harness-ui-sessions--buffer-name)
      (cl-flet ((menu (keys)
                  (call-interactively #'harness-menu)
                  (unwind-protect
                      (prog1 (with-current-buffer transient--buffer-name
                               (buffer-substring-no-properties (point-min) (point-max)))
                        (execute-kbd-macro (kbd keys)))
                    (when transient--prefix (execute-kbd-macro (kbd "C-g"))))))
        ;; a and c are non-interactive: the label says so, and i turns it off.
        (harness-ui-sessions-test--mark "a" "c")
        (should (string-match-p " i Non-interactive: on\\(?: \\|$\\)" (menu "i")))
        (should (equal '(("_harness/session/set-all"
                          (:settings (:non-interactive :false) :filter (:ids ("a" "c")))))
                       (harness-ui-sessions-test--answers)))
        ;; b is not, a is: the label says off, and i turns it on for all.
        (harness-ui-sessions-test--press "U")
        (harness-ui-sessions-test--mark "a" "b")
        (setq harness-ui-sessions-test--requests nil)
        (should (string-match-p " i Non-interactive: off\\(?: \\|$\\)" (menu "i")))
        (should (equal '("_harness/session/set-all" "_harness/task/set-all")
                       (mapcar #'car (harness-ui-sessions-test--answers))))
        (should (equal '(:non-interactive t)
                       (plist-get (cadr (car (harness-ui-sessions-test--answers))) :settings)))
        (should (equal '("a" "b") (harness-ui-sessions-test--starred)))))
    (should-not transient--prefix)))

;;;; Priority

(ert-deftest harness-ui-sessions-show-the-priority-of-each-session ()
  "The Priority column shows the level the harness serves a session at.
Medium, the default, goes without saying and leaves its cell empty, as
the chat header does; a session with none of its own shows its
parent's, which is the level the harness serves its work at; and the
column sorts, lowest first."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "high" root :ext '(:priority "high"))
    (harness-ui-sessions-test--add "plain" root)
    (harness-ui-sessions-test--add "low" root :ext '(:priority "low") :updated 400)
    (harness-ui-sessions-test--add "child" root :parent-id "low" :updated 300)
    (let ((default-directory root)) (harness-sessions))
    (should (equal (harness-ui-icon 'harness-icon-priority-high)
                   (harness-ui-sessions-test--cell "high" "Priority")))
    (should (equal "" (harness-ui-sessions-test--cell "plain" "Priority")))
    (should (equal (harness-ui-icon 'harness-icon-priority-low)
                   (harness-ui-sessions-test--cell "low" "Priority")))
    (should (equal (harness-ui-icon 'harness-icon-priority-low)
                   (harness-ui-sessions-test--cell "child" "Priority")))
    (with-current-buffer harness-ui-sessions--buffer-name
      (let* ((columns (cadr (assoc "high" tabulated-list-entries)))
             (at (cl-position "Priority" tabulated-list-format :key #'car :test #'equal))
             (cell (aref columns at)))
        (should (eq 'harness-priority-high-face (get-text-property 0 'face cell)))
        (should (string-match-p "serves this session's commands before lower ones'"
                                (get-text-property 0 'help-echo cell)))
        ;; The arrow is a button of its own, naming the session of its row.
        (should (keymapp (get-text-property 0 'keymap cell)))
        (should (equal "high" (get-text-property 0 'harness-priority-session cell)))))
    ;; The column sorts by the level, lowest first.
    (with-current-buffer harness-ui-sessions--buffer-name
      (should (equal '("low" "child" "plain" "high")
                     (mapcar #'car (sort (copy-sequence tabulated-list-entries)
                                         #'harness-ui-sessions--priority<)))))))

(ert-deftest harness-ui-sessions-click-the-priority-arrow ()
  "A click on a row's arrow asks for that session's priority, not point's.
The arrow carries the session of its row, and the click reads it from
the arrow, whatever row point is on."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--with-init
      (harness-ui-sessions-test--add "high" root :ext '(:priority "high"))
      (harness-ui-sessions-test--add "low" root :ext '(:priority "low") :updated 400)
      (let ((default-directory root)) (harness-sessions))
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "medium")))
        (with-current-buffer harness-ui-sessions--buffer-name
          ;; Point is on the low session; the arrow of the high one is clicked.
          (harness-ui-sessions-test--goto "low")
          (let ((arrow (harness-ui-sessions-test--arrow-position "high"))
                (window (selected-window)))
            (should arrow)
            (should (equal "high" (get-text-property arrow 'harness-priority-session)))
            (harness-ui-priority-click (list 'mouse-1 (list window arrow '(0 . 0) 0)))
            (should (equal '(("_harness/priority/set" (:sessionId "high" :priority "medium")))
                           (harness-ui-sessions-test--answers)))))))))

(ert-deftest harness-ui-sessions-set-the-priority-of-the-session-at-point ()
  "The priority of the session at point: p sets it, + and - step it.
Each asks the harness for the level it reaches
\(`_harness/priority/set'), and a prefix argument on + or - asks for a
level instead."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--with-init
      (harness-ui-sessions-test--add "high" root :ext '(:priority "high"))
      (harness-ui-sessions-test--add "plain" root :updated 300)
      (let ((default-directory root)) (harness-sessions))
      (with-current-buffer harness-ui-sessions--buffer-name
        (harness-ui-sessions-test--goto "plain")
        (should (eq 'harness-ui-sessions-raise-priority (key-binding (kbd "+"))))
        (should (eq 'harness-ui-sessions-lower-priority (key-binding (kbd "-"))))
        (should (eq 'harness-ui-sessions-set-priority (key-binding (kbd "p"))))
        (should (equal "Priority raised to high"
                       (harness-ui-sessions-test--message
                        (lambda () (call-interactively (key-binding (kbd "+")))))))
        (should (equal '(("_harness/priority/set" (:sessionId "plain" :priority "high")))
                       (harness-ui-sessions-test--answers)))
        (setq harness-ui-sessions-test--requests nil)
        ;; Already high: the level does not go above it.
        (harness-ui-sessions-test--goto "high")
        (should (equal "Priority is high already"
                       (harness-ui-sessions-test--message
                        (lambda () (call-interactively (key-binding (kbd "+")))))))
        (should-not (harness-ui-sessions-test--answers))
        ;; p asks for the level, offering the session's own.
        (let (asked)
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (prompt _collection &rest _) (setq asked prompt) "low")))
            (harness-ui-sessions-test--goto "high")
            (should (equal "Priority: low"
                           (harness-ui-sessions-test--message
                            (lambda () (call-interactively (key-binding (kbd "p"))))))))
          (should (equal "Priority: " asked))
          (should (equal '(("_harness/priority/set" (:sessionId "high" :priority "low")))
                         (harness-ui-sessions-test--answers))))))))

;;;; Those waiting for you

(ert-deftest harness-ui-sessions-show-those-waiting-for-you ()
  "b shows only the blocked sessions, under a banner counting them.
The banner's [Show all] shows every session again, as b does.  With
none waiting the banner says so, rows or no rows.  The mode line's
notifier opens the list so for every project, whatever its filter."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "busy" root :status "running")
    (harness-ui-sessions-test--blocked "asks" root "permission")
    (harness-ui-sessions-test--blocked "elsewhere" other "question")
    (let ((default-directory root)) (harness-sessions))
    (with-current-buffer harness-ui-sessions--buffer-name
      (should (equal '("asks" "busy") (harness-ui-sessions-test--shown)))
      (should-not (string-match-p "waits? for you" (harness-ui-sessions-test--text)))
      (should (eq 'harness-ui-sessions-toggle-blocked (key-binding (kbd "b"))))
      (call-interactively #'harness-ui-sessions-toggle-blocked)
      (should (equal '("asks") (harness-ui-sessions-test--shown)))
      (should (equal " [Pause] [project blocked]" (harness-ui-sessions-test--mode-line)))
      ;; The banner first, which is no session's, then the rows.
      (should (string-match-p "\\` .+ 1 session waits for you in this project  \\[Show all\\] b\n"
                              (harness-ui-sessions-test--text)))
      (should (equal "asks" (tabulated-list-get-id)))
      (should-not (tabulated-list-get-id (point-min)))
      ;; Its [Show all] shows every session again.
      (goto-char (point-min))
      (search-forward "[Show all")
      (harness-ui-action-push)
      (should (equal '("asks" "busy") (harness-ui-sessions-test--shown)))
      (should (equal " [Pause] [project]" (harness-ui-sessions-test--mode-line)))
      (should-not (string-match-p "waits? for you" (harness-ui-sessions-test--text)))
      ;; None waiting, or none the filter lets through: the banner says so.
      (harness-ui-sessions-toggle-blocked)
      (harness-ui-sessions-filter "busy")
      (should-not (harness-ui-sessions-test--shown))
      (should (string-match-p
               "\\` .+ No session waits for you in this project matching /busy  \\[Show all\\] b\n\\'"
               (harness-ui-sessions-test--text))))
    ;; The notifier's: every project, whatever the filter was.
    (harness-sessions-waiting)
    (with-current-buffer harness-ui-sessions--buffer-name
      (should (equal '("asks" "elsewhere") (harness-ui-sessions-test--shown)))
      (should (equal " [Pause] [all projects blocked]" (harness-ui-sessions-test--mode-line)))
      (should (string-match-p "\\` .+ 2 sessions wait for you in any project  \\[Show all\\] b\n"
                              (harness-ui-sessions-test--text))))
    ;; The list opened as ever shows them all again.
    (let ((default-directory root)) (harness-sessions))
    (should (equal '("asks" "busy") (harness-ui-sessions-test--shown)))
    (should-not (string-match-p "waits? for you" (harness-ui-sessions-test--text)))))

(ert-deftest harness-ui-sessions-answer-what-a-session-waits-on ()
  "A blocked session's row has a line under it saying what it waits on.
It has the task board's buttons: [Allow] and [Deny] for a permission
request, which y and n push from either line too, and [Answer…] for a
question, which pops it out.  An answer takes the line away at once,
before the session says it waits no more."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--with-init
      (let ((popped nil))
        (harness-ui-sessions-test--add "busy" root :status "running" :updated 400)
        (harness-ui-sessions-test--blocked "asks" root "permission" :updated 300)
        (harness-ui-sessions-test--blocked "risky" root "permission" :updated 200)
        (harness-ui-sessions-test--blocked "child" root "question" :parent-id "busy")
        (let ((default-directory root)) (harness-sessions))
        (with-current-buffer harness-ui-sessions--buffer-name
          ;; Under the name, the buttons, then what it waits on.
          (should (equal "    [Allow] [Deny]  needs your permission · Bash: rm -rf build/"
                         (harness-ui-sessions-test--line "asks")))
          (should (equal "        [Answer…]  has a question for you · Which colour?"
                         (harness-ui-sessions-test--line "child")))
          (should-not (harness-ui-sessions-test--line "busy"))
          (should (string-match-p "y allows it, n denies it"
                                  (harness-ui-sessions--waiting-help (harness-ui-session "asks"))))
          ;; [Allow] answers over the bus, and the line goes at once.
          (harness-ui-sessions-test--goto "asks")
          (forward-line 1)
          (search-forward "[Allow")
          (harness-ui-action-push)
          (should (equal '(("_harness/permission/answer"
                            (:session-id "asks" :pending-id "asks-p" :answer "allow-once")))
                         (harness-ui-sessions-test--answers)))
          (harness-test-wait (lambda () (not (harness-ui-sessions-test--line "asks")))
                             5 "the answered request to leave the list")
          (should (equal "asks" (tabulated-list-get-id)))
          ;; Still blocked until the session says otherwise, it offers nothing.
          (should (equal "blocked" (plist-get (harness-ui-session "asks") :status)))
          (should-error (harness-ui-sessions-allow) :type 'user-error)
          ;; n on the row itself denies.
          (harness-ui-sessions-test--goto "risky")
          (should (eq 'harness-ui-sessions-allow (key-binding (kbd "y"))))
          (should (eq 'harness-ui-sessions-deny (key-binding (kbd "n"))))
          (call-interactively (key-binding (kbd "n")))
          (should (equal '("_harness/permission/answer"
                           (:session-id "risky" :pending-id "risky-p" :answer "deny-once"))
                         (car (last (harness-ui-sessions-test--answers)))))
          ;; A question is not allowed: [Answer…] pops it out to be answered.
          (harness-ui-sessions-test--goto "child")
          (should-not (eq 'harness-ui-sessions-allow (key-binding (kbd "y"))))
          (should-error (harness-ui-sessions-allow) :type 'user-error)
          (forward-line 1)
          (search-forward "[Answer")
          (cl-letf (((symbol-function 'harness-ui-pending-popout) (lambda (sid) (push sid popped) t)))
            (harness-ui-action-push))
          (should (equal '("child") popped))
          (should (= 2 (length (harness-ui-sessions-test--answers)))))))))

(ert-deftest harness-ui-sessions-move-the-session-at-point ()
  "M moves the session at point to another directory, and the list follows it.
The directory is read from the one that holds the session's own, and the
list shows the session under the project there.  m marks the session
now."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--with-init
      (let ((asked nil))
        (harness-ui-sessions-test--add "lost" other)
        (harness-ui-sessions-test--add "home" root)
        (let ((default-directory other)) (harness-sessions))
        (with-current-buffer harness-ui-sessions--buffer-name
          (should (equal '("lost") (harness-ui-sessions-test--shown)))
          (harness-ui-sessions-test--goto "lost")
          (should (eq 'harness-ui-sessions-move (key-binding (kbd "M"))))
          (should (eq 'harness-ui-sessions-mark (key-binding (kbd "m"))))
          (cl-letf (((symbol-function 'read-directory-name)
                     (lambda (prompt dir &rest _) (push (list prompt dir) asked) root)))
            (call-interactively (key-binding (kbd "M"))))
          (should (= 1 (length asked)))
          (should (string-match-p "\\`Move .*lost to directory: \\'" (car (car asked))))
          (should (equal base (cadr (car asked))))
          (should (equal (list (list "_harness/session/move" (list :id "lost" :dir root :keep-old-dir :false :project root)))
                         (harness-ui-sessions-test--answers)))
          (should (equal root (plist-get (harness-ui-session "lost") :project)))
          (harness-test-wait (lambda () (null (harness-ui-sessions-test--shown))) 5 "the list to follow the move"))))))

(ert-deftest harness-ui-sessions-open-in-its-project ()
  "RET opens the session at point in its project, from either of its lines.
The project switched to is the main checkout, a task's worktree's too,
and the session then opens where sessions open -- in the one window of
a workspace showing nothing yet -- and without a switch it replaces the
list, as ever.  A session shown already gets its window selected.  A
remote project, or one gone from disk, is not switched to."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--blocked "task" wt "permission")
    (harness-ui-sessions-test--add "remote" "/ssh:nobody@example.invalid:/srv/project/")
    (harness-ui-sessions-test--add "gone" (expand-file-name "gone/" other))
    (let* ((switched nil) (opened nil) (shown nil) (switch t)
           (chat (get-buffer-create " *harness-ui-sessions-test chat*"))
           (window-buffer (window-buffer))
           (harness-ui-switch-project-function (lambda (dir) (push dir switched) switch))
           (harness-ui-open-session-function (lambda (id) (push id opened) chat)))
      (unwind-protect
          (cl-letf (((symbol-function 'harness-ui-display-buffer)
                     (lambda (buffer &optional position) (push (list buffer position) shown) buffer)))
            (let ((default-directory root)) (harness-sessions))
            (with-current-buffer harness-ui-sessions--buffer-name
              (setq-local harness-ui-position 'full)
              ;; The line of what it waits on is the session's too.
              (harness-ui-sessions-test--goto "task")
              (forward-line 1)
              (should (eq 'harness-ui-sessions-open (key-binding (kbd "RET"))))
              (call-interactively (key-binding (kbd "RET"))))
            (should (equal (list root) switched))
            (should (equal '("task") opened))
            (should (equal (list (list chat nil)) shown))
            ;; In its project already: the session replaces the list.
            (setq switched nil shown nil switch nil)
            (with-current-buffer harness-ui-sessions--buffer-name
              (harness-ui-sessions-test--goto "task")
              (harness-ui-sessions-open))
            (should (equal (list root) switched))
            (should (equal (list (list chat 'full)) shown))
            ;; Shown already: its window is selected, it opens no more.
            (setq switched nil shown nil)
            (set-window-buffer (selected-window) chat)
            (with-current-buffer harness-ui-sessions--buffer-name
              (should (eq chat (harness-ui-visit-session "task"))))
            (should-not shown)
            (should (eq chat (window-buffer (selected-window))))
            ;; Switched to a workspace showing nothing yet: the session
            ;; takes its window, unless a position is asked for.
            (set-window-buffer (selected-window) window-buffer)
            (setq switched nil shown nil switch 'blank)
            (with-current-buffer harness-ui-sessions--buffer-name
              (setq-local harness-ui-position 'left)
              (harness-ui-sessions-test--goto "task")
              (harness-ui-sessions-open)
              (harness-ui-sessions-open 'bottom))
            (should (equal (list root root) switched))
            (should (equal (list (list chat 'bottom) (list chat 'full)) shown))
            (setq switch t)
            ;; Nowhere to switch to.
            (setq switched nil)
            (cl-letf (((symbol-function 'harness-files-owning-checkout) (lambda (&rest _) (error "Looked at"))))
              (should-not (harness-ui-session-project (harness-ui-session "remote"))))
            (should-not (harness-ui-session-project (harness-ui-session "gone")))
            (harness-ui-visit-session "remote")
            (harness-ui-visit-session "gone")
            (should-not switched)
            ;; Nor with switching turned off.
            (let ((harness-ui-switch-project-function nil))
              (harness-ui-visit-session "task"))
            (should-not switched))
        (set-window-buffer (selected-window) window-buffer)
        (kill-buffer chat)))))

(ert-deftest harness-ui-session-link-and-a-list-row-open-through-visit-session ()
  "The shared session link and a session list row open a session the same way.
A click on the text `harness-ui-session-link' draws runs
`harness-ui-visit-session', and so does RET on the list's row: the one
path that switches to the session's project and shows it there.  A
chat's session line and a tool call's block use the same link, so they
open it the same way."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "task" root)
    (let ((visited nil))
      (cl-letf (((symbol-function 'harness-ui-visit-session)
                 (lambda (id &rest _) (push id visited))))
        ;; The link, as the chat's session line and a tool call draw it.
        (with-temp-buffer
          (insert (harness-ui-session-link "task"))
          (goto-char (point-min))
          (let ((command (lookup-key (get-text-property (point) 'keymap) [mouse-1])))
            (should (commandp command))
            (call-interactively command)))
        ;; The list's own row.
        (let ((default-directory root)) (harness-sessions))
        (with-current-buffer harness-ui-sessions--buffer-name
          (harness-ui-sessions-test--goto "task")
          (harness-ui-sessions-open)))
      (should (equal '("task" "task") (reverse visited))))))

(defvar persp-mode)
(defvar +workspaces-switch-project-function)
(defvar doom-fallback-buffer-name)

(defun harness-ui-sessions-test--project (base dir &rest files)
  "Make a project at DIR under BASE, a directory with .git, holding FILES.
Return its root."
  (let ((root (file-name-as-directory (expand-file-name dir base))))
    (make-directory (expand-file-name ".git" root) t)
    (dolist (file files)
      (write-region "" nil (expand-file-name file root)))
    root))

(defmacro harness-ui-sessions-test-with-workspaces (&rest body)
  "Run BODY with Doom Emacs's workspaces faked, in a frame of one window.
In BODY, `workspaces' lists the workspaces in order, each as
\(NAME PROJECT . OPEN): PROJECT is the directory it notes as its
`+workspace-project', as a fork of Doom keeps it (nil for none), OPEN
the files (or buffers) it has open.  `current' names the current one.
`switched' lists the workspaces switched to and `made' Doom's project
switches, as (DIR FUNCTION), FUNCTION the `+workspaces-switch-project-function'
it ran with, newest first.  `base' is a directory for projects
\(`harness-ui-sessions-test--project').  A workspace shows its first
open file in the window, else Doom's fallback buffer; Doom's project
switch makes a workspace named after the project, noting it, as the
fork's does -- \"parent/name\" when the name is taken -- that shows
the fallback buffer."
  (declare (indent 0))
  `(let* ((base (file-name-as-directory (file-truename (harness-test-temp-dir))))
          (workspaces nil) (current nil) (switched nil) (made nil)
          (doom-fallback-buffer-name " *harness-ui-sessions-test doom*")
          (persp-mode t)
          (buffers (lambda (open)
                     (mapcar (lambda (f) (if (bufferp f) f (find-file-noselect f))) open)))
          (show (lambda (name)
                  (setq current name)
                  (set-window-buffer
                   nil (or (car (funcall buffers (cddr (assoc name workspaces))))
                           (get-buffer-create doom-fallback-buffer-name))))))
     (save-window-excursion
       (delete-other-windows)
       (unwind-protect
           (cl-letf (((symbol-function '+workspace-list-names) (lambda () (mapcar #'car workspaces)))
                     ((symbol-function '+workspace-get)
                      (lambda (name &optional _noerror) (assoc name workspaces)))
                     ((symbol-function '+workspace-buffer-list)
                      (lambda (&optional persp) (funcall buffers (cddr persp))))
                     ((symbol-function 'persp-parameter)
                      (lambda (param &optional persp)
                        (and (eq param '+workspace-project) (cadr persp))))
                     ((symbol-function '+workspace-current-name) (lambda () current))
                     ((symbol-function '+workspace-switch)
                      (lambda (name &optional _auto-create)
                        (push name switched)
                        (funcall show name)
                        t))
                     ((symbol-function '+workspace-message) #'ignore)
                     ((symbol-function '+workspaces-switch-to-project-h)
                      (lambda (&optional dir)
                        (push (list dir (symbol-value '+workspaces-switch-project-function)) made)
                        (let* ((name (file-name-nondirectory (directory-file-name dir)))
                               (name (if (assoc name workspaces)
                                         (concat (file-name-nondirectory
                                                  (directory-file-name (file-name-directory
                                                                        (directory-file-name dir))))
                                                 "/" name)
                                       name)))
                          (setq workspaces (append workspaces (list (list name dir))))
                          (funcall show name))))
                     ((symbol-function 'doom-project-name)
                      (lambda (&optional dir) (file-name-nondirectory (directory-file-name dir))))
                     ((symbol-function 'doom-project-p)
                      (lambda (&optional dir) (file-directory-p (expand-file-name ".git" dir)))))
             ,@body)
         (dolist (buffer (buffer-list))
           (when (or (equal (buffer-name buffer) doom-fallback-buffer-name)
                     (string-prefix-p base (or (buffer-file-name buffer) "")))
             (kill-buffer buffer)))
         (delete-directory base t)))))

(ert-deftest harness-ui-sessions-switch-doom-workspaces ()
  "With Doom Emacs's workspaces, a session's project is switched to.
Its workspace, when it has one, comes back as it was left; else Doom
makes one, as switching project does but without asking for a file to
open, which shows nothing yet.  A project whose workspace is current
already is not switched to, nor a directory that is no project, and
without workspaces nothing is."
  (harness-ui-sessions-test-with-workspaces
    (let ((shop (harness-ui-sessions-test--project base "srv/shop/" "README.md"))
          (blog (harness-ui-sessions-test--project base "srv/blog/" "post.md"))
          (lab (harness-ui-sessions-test--project base "srv/lab/"))
          (scratch (file-name-as-directory (expand-file-name "scratch" base))))
      (make-directory scratch)
      (setq workspaces (list (list "blog" nil (expand-file-name "post.md" blog))
                             (list "shop" nil (expand-file-name "README.md" shop)))
            current "blog")
      (should (eq t (harness-ui-switch-project-workspace shop)))
      (should (equal '("shop") switched))
      (should-not made)
      (should (equal (expand-file-name "README.md" shop) (buffer-file-name (window-buffer))))
      ;; Its workspace is current already.
      (should-not (harness-ui-switch-project-workspace shop))
      (should (equal '("shop") switched))
      ;; None yet: Doom makes it, with no file to open, and it is blank.
      (should (eq 'blank (harness-ui-switch-project-workspace lab)))
      (should (equal (list (list lab 'ignore)) made))
      (should (equal "lab" current))
      (should-not (harness-ui-switch-project-workspace lab))
      ;; No project.
      (should-not (harness-ui-switch-project-workspace scratch))
      (let ((persp-mode nil))
        (should-not (harness-ui-switch-project-workspace blog)))
      (should (equal '("shop") switched))
      (should (= 1 (length made)))))
  ;; No Doom at all.
  (let ((persp-mode t))
    (should-not (fboundp '+workspaces-switch-to-project-h))
    (should-not (harness-ui-switch-project-workspace "/srv/blog/"))))

(ert-deftest harness-ui-sessions-switch-to-the-workspace-a-fork-notes ()
  "A fork of Doom notes the project a workspace is for, `+workspace-project'.
A workspace noting the project is the project's whatever its name, and
so is the one named after it noting none: the empty workspace the
project was first opened in, which the fork renames without noting
anything, and whose project the fork's own switch passes over for a
new, empty workspace.  One named after the project noting another is
the other's, unless that is gone, moved say.  A workspace noting a
directory on another host is not looked at, which would connect to it."
  (harness-ui-sessions-test-with-workspaces
    (let ((shop (harness-ui-sessions-test--project base "srv/shop/" "README.md"))
          (old-shop (harness-ui-sessions-test--project base "old/shop/" "main.c"))
          (blog (harness-ui-sessions-test--project base "srv/blog/" "post.md"))
          (lab (harness-ui-sessions-test--project base "srv/lab/"))
          (other-lab (harness-ui-sessions-test--project base "elsewhere/lab/"))
          (wiki (harness-ui-sessions-test--project base "srv/wiki/" "index.org"))
          (looked nil))
      (setq workspaces (list (list "blog" blog (expand-file-name "post.md" blog))
                             (list "shop" nil (expand-file-name "README.md" shop))
                             (list "old/shop" old-shop (expand-file-name "main.c" old-shop))
                             (list "lab" other-lab)
                             (list "wiki" (expand-file-name "gone/wiki/" base)
                                   (expand-file-name "index.org" wiki))
                             (list "far/shop" "/ssh:nobody@example.invalid:/srv/shop/"))
            current "blog")
      (cl-letf* ((directory-p (symbol-function 'file-directory-p))
                 ((symbol-function 'file-directory-p)
                  (lambda (file)
                    (if (file-remote-p file)
                        (ignore (push file looked))
                      (funcall directory-p file))))
                 (equal-p (symbol-function 'file-equal-p))
                 ((symbol-function 'file-equal-p)
                  (lambda (file other)
                    (if (or (file-remote-p file) (file-remote-p other))
                        (ignore (push file looked))
                      (funcall equal-p file other)))))
        ;; Noting the project, from inside: current already.
        (should-not (harness-ui-switch-project-workspace blog))
        ;; Named after it, noting none.
        (should (eq t (harness-ui-switch-project-workspace shop)))
        (should (equal "shop" current))
        ;; Noting it under another name, past "shop", which has none of its files.
        (should (eq t (harness-ui-switch-project-workspace old-shop)))
        (should (equal "old/shop" current))
        (should (eq t (harness-ui-switch-project-workspace blog)))
        (should (equal "blog" current))
        ;; Named after it, noting a directory gone since.
        (should (eq t (harness-ui-switch-project-workspace wiki)))
        (should (equal "wiki" current))
        (should (equal (expand-file-name "index.org" wiki) (buffer-file-name (window-buffer))))
        ;; Named after it, noting another project: Doom makes its own.
        (should (eq 'blank (harness-ui-switch-project-workspace lab)))
        (should (equal (list (list lab 'ignore)) made))
        (should (equal "srv/lab" current))
        (should (equal '("wiki" "blog" "old/shop" "shop") switched))
        (should-not looked)))))

(ert-deftest harness-ui-sessions-switch-past-an-empty-duplicate ()
  "Of two workspaces of a project, the one with its files open is taken.
That is the one named after the project, noting none, rather than the
empty one a fork of Doom made beside it, noting the project -- from
another workspace or from that empty one.  The one with the most of
the project's files open wins; on a tie the one named after the
project.  Remote files are not looked at."
  (harness-ui-sessions-test-with-workspaces
    (let* ((harness (harness-ui-sessions-test--project base "ai/emacs-agent-harness/"
                                                       "README.md" "harness.el" "DESIGN.md"))
           (site (harness-ui-sessions-test--project base "web/site/" "index.html"))
           (file (lambda (name) (expand-file-name name harness)))
           (remote (generate-new-buffer " *harness-ui-sessions-test remote*")))
      (with-current-buffer remote
        (setq buffer-file-name "/ssh:nobody@example.invalid:/srv/x.el"))
      (unwind-protect
          (cl-letf* ((in-directory (symbol-function 'file-in-directory-p))
                     ((symbol-function 'file-in-directory-p)
                      (lambda (file dir)
                        (when (file-remote-p file) (error "Looked at %s" file))
                        (funcall in-directory file dir))))
            (setq workspaces (list (list "emacs-agent-harness" nil
                                         (funcall file "README.md") (funcall file "harness.el"))
                                   (list "site" site (expand-file-name "index.html" site))
                                   (list "ai/emacs-agent-harness" harness remote))
                  current "site")
            (should (eq t (harness-ui-switch-project-workspace harness)))
            (should (equal "emacs-agent-harness" current))
            (should (equal (funcall file "README.md") (buffer-file-name (window-buffer))))
            ;; From the empty one too.
            (setq current "ai/emacs-agent-harness")
            (should (eq t (harness-ui-switch-project-workspace harness)))
            (should (equal "emacs-agent-harness" current))
            ;; More of its files open wins.
            (setcdr (cdr (assoc "ai/emacs-agent-harness" workspaces))
                    (list (funcall file "DESIGN.md") (funcall file "README.md") (funcall file "harness.el")))
            (should (eq t (harness-ui-switch-project-workspace harness)))
            (should (equal "ai/emacs-agent-harness" current))
            ;; A tie: the one named after the project.
            (setcdr (cdr (assoc "emacs-agent-harness" workspaces)) nil)
            (setcdr (cdr (assoc "ai/emacs-agent-harness" workspaces)) nil)
            (should (eq 'blank (harness-ui-switch-project-workspace harness)))
            (should (equal "emacs-agent-harness" current))
            (should-not made))
        (kill-buffer remote)))))

(ert-deftest harness-ui-sessions-notifier-shows-those-waiting ()
  "A click on the mode line's notifier lists the sessions waiting for you.
From every project, as `harness-sessions-waiting'.  With none waiting
it opens the list as ever."
  (require 'harness-ui-notify)
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "busy" root :status "running")
    (harness-ui-sessions-test--blocked "elsewhere" other "question")
    (let* ((segment (harness-ui-notify--segment 1 'harness-icon-blocked 'harness-notify-blocked-face "Waiting"))
           (click (lookup-key (get-text-property 1 'local-map segment) [mode-line mouse-1]))
           (default-directory root))
      (call-interactively click)
      (with-current-buffer harness-ui-sessions--buffer-name
        (should (equal '("elsewhere") (harness-ui-sessions-test--shown)))
        (should (equal " [Pause] [all projects blocked]" (harness-ui-sessions-test--mode-line))))
      ;; Answered: with none waiting, the list as ever.
      (harness-ui-sessions-test--add "elsewhere" other :status "idle")
      (call-interactively click)
      (with-current-buffer harness-ui-sessions--buffer-name
        (should (equal '("busy") (harness-ui-sessions-test--shown)))
        (should (equal " [Pause] [project]" (harness-ui-sessions-test--mode-line)))))))

;;;; Columns

;; Every cell of a row ends in a space that aligns to the start of the
;; next column (`harness-ui-sessions--print-cell'), whether it fills its
;; column or not, and the figures are right-aligned.  A batch Emacs
;; draws nothing, but `current-column' follows integer `:align-to'
;; targets as redisplay does, and a name of double-width characters cut
;; to its column ends a column short of it -- as a glyph that is not as
;; wide as its character count says does on screen -- so these tests
;; read the columns the cells start and end at.

(defun harness-ui-sessions-test--layout ()
  "Return (NAME START WIDTH RIGHT-ALIGN) for each column of the list.
START is the column the cell starts at: the first after the padding,
each next one after the width and the padding of the one before."
  (let ((x tabulated-list-padding)
        layout)
    (dotimes (n (length tabulated-list-format))
      (let* ((spec (aref tabulated-list-format n))
             (props (nthcdr 3 spec)))
        (push (list (nth 0 spec) x (nth 1 spec) (plist-get props :right-align)) layout)
        (setq x (+ x (nth 1 spec) (or (plist-get props :pad-right) 1)))))
    (nreverse layout)))

(defun harness-ui-sessions-test--align-target (pos &optional string)
  "Return the column the character at POS aligns to, or nil if it is no such space.
It is read from STRING, else from the current buffer.  The header's
targets are relative to its indent: `(+ header-line-indent-width N)'."
  (let ((display (get-text-property pos 'display string)))
    (when (eq (car-safe display) 'space)
      (let ((target (plist-get (cdr display) :align-to)))
        (if (consp target) (car (last target)) target)))))

(defun harness-ui-sessions-test--cells (id)
  "Return the cells of session ID's row, as (NAME START END) of their text."
  (with-current-buffer harness-ui-sessions--buffer-name
    (save-excursion
      (goto-char (harness-ui-sessions--position id))
      (let ((pos (line-beginning-position))
            (eol (line-end-position))
            cells)
        (while (< pos eol)
          (let ((name (get-text-property pos 'tabulated-list-column-name))
                (next (next-single-property-change pos 'tabulated-list-column-name nil eol)))
            (when name (push (list name pos next) cells))
            (setq pos next)))
        (nreverse cells)))))

(defun harness-ui-sessions-test--column-at (pos)
  "Return the column POS is at in the list buffer."
  (with-current-buffer harness-ui-sessions--buffer-name
    (save-excursion (goto-char pos) (current-column))))

(defun harness-ui-sessions-test--label-end (cell)
  "Return where the label of CELL, (NAME START END), ends.
That is where its closing space starts; an empty right-aligned cell is
only spaces, so it ends where it starts."
  (with-current-buffer harness-ui-sessions--buffer-name
    (let ((pos (nth 2 cell)))
      (while (and (> pos (nth 1 cell))
                  (harness-ui-sessions-test--align-target (1- pos)))
        (setq pos (1- pos)))
      pos)))

(defun harness-ui-sessions-test--header-labels ()
  "Return (NAME START END) of each label of the header, in columns.
The header is a string of labels and aligning spaces: walk it as
redisplay does, a space only ever moving the position forward."
  (let ((header (nth 2 header-line-format))
        (x 0)
        labels)
    (dotimes (i (length header))
      (if-let* ((target (harness-ui-sessions-test--align-target i header)))
          (setq x (max x target))
        (let ((start x)
              (name (get-text-property i 'tabulated-list-column-name header)))
          (setq x (+ x (char-width (aref header i))))
          (when name
            (if (and labels (equal name (car (car labels))) (= start (nth 2 (car labels))))
                (setcar (nthcdr 2 (car labels)) x)
              (push (list name start x) labels))))))
    (nreverse labels)))

(ert-deftest harness-ui-sessions-every-cell-ends-at-its-column ()
  "Each cell of a row, the last apart, ends in a space aligning to the next column.
A name that fills its column -- exactly as wide, cut to fit, or cut at a
double-width character, which leaves it a column short -- still has that
space, so every cell starts at the column its header gives it on every
row, whatever the cells before it hold: the rows end their cells in the
same targets, which are the columns' own, and nothing follows the last
cell."
  (harness-ui-sessions-test-with-repo
    (let ((full (make-string 28 ?n))
          (ids '("short" "full" "cut" "wide" "arrow" "child" "asks" "unnamed")))
      (harness-ui-sessions-test--add "short" root :name "short")
      (harness-ui-sessions-test--add "full" root :name full)
      (harness-ui-sessions-test--add "cut" root :name (make-string 40 ?c))
      ;; Fifteen double-width characters are 30 columns: cut to thirteen
      ;; and an ellipsis, 27, a column short of the 28 the column has.
      (harness-ui-sessions-test--add "wide" root :name (make-string 15 ?日))
      (harness-ui-sessions-test--add "arrow" root :name full :ext '(:priority "high"))
      (harness-ui-sessions-test--add "child" root :parent-id "short" :name full)
      (harness-ui-sessions-test--blocked "asks" root "permission" :name full)
      (harness-ui-sessions-test--add "unnamed" root :name nil :status "inactive")
      (let ((default-directory root)) (harness-sessions))
      (with-current-buffer harness-ui-sessions--buffer-name
        (let* ((layout (harness-ui-sessions-test--layout))
               (starts (mapcar #'cadr layout))
               (closing (lambda (cell)
                          (harness-ui-sessions-test--align-target (1- (nth 2 cell))))))
          ;; Each cell starts at its column's own column, on every row.
          (dolist (id ids)
            (let ((cells (harness-ui-sessions-test--cells id)))
              (should (equal (mapcar #'car layout) (mapcar #'car cells)))
              (should (equal (list id starts)
                             (list id (mapcar (lambda (cell)
                                                (harness-ui-sessions-test--column-at (nth 1 cell)))
                                              cells))))))
          ;; Each ends in a space aligning to where the next one starts,
          ;; the last in nothing: it has the rest of the line.
          (dolist (id ids)
            (let ((cells (harness-ui-sessions-test--cells id)))
              (should (equal (list id (cdr starts))
                             (list id (mapcar closing (butlast cells)))))
              (should-not (funcall closing (car (last cells)))))))))))

(ert-deftest harness-ui-sessions-figures-are-right-aligned ()
  "Context, Avg tok/s and Cost end at the right edge of their column.
So their ends line up row under row, whatever the figures' widths: the
longest of each fits its column untouched, `$0.0058+Max' in Cost."
  (harness-ui-sessions-test-with-repo
    (let ((harness-ui--rates (make-hash-table :test 'equal))
          (figures '("Context" "Avg tok/s" "Cost")))
      (harness-ui-sessions-test--add "small" root
                                     :usage (list :cost 1.23 :billing "api" :context 1200 :output 300
                                                  :stream-output 17 :stream-seconds 4.0))
      (harness-ui-sessions-test--add "plan" root :context-window 384000
                                     :usage (list :cost 0 :list-cost 2.5 :billing "subscription"
                                                  :plan "max" :context 145000 :output 49900
                                                  :stream-output 12345 :stream-seconds 10.0))
      (harness-ui-sessions-test--add "extra" root
                                     :usage (list :cost 0.0058 :list-cost 1.0 :billing "extra-usage"
                                                  :plan "max" :context 12345 :output 108000))
      (harness-ui-sessions-test--add "big" root :context-window 1000000
                                     :usage (list :cost 12.5 :billing "api" :context 987654
                                                  :output 2500000))
      (harness-ui-sessions-test--add "fresh" root)
      (puthash "small" '(:rate 4.3 :output 17 :seconds 4.0 :calls 1 :at 900.0 :model "demo:scripted")
               harness-ui--rates)
      (puthash "plan" '(:rate 1234.5 :output 600 :seconds 9.8 :calls 2 :at 1000.0 :model "demo:scripted")
               harness-ui--rates)
      (let ((default-directory root)) (harness-sessions))
      (with-current-buffer harness-ui-sessions--buffer-name
        (let ((layout (harness-ui-sessions-test--layout)))
          ;; The four are the right-aligned columns of the list.
          (should (equal figures (mapcar #'car (cl-remove-if-not #'cadddr layout))))
          (dolist (id '("small" "plan" "extra" "big" "fresh"))
            (let ((cells (harness-ui-sessions-test--cells id)))
              (dolist (name figures)
                (let* ((col (assoc name layout))
                       (cell (assoc name cells))
                       (text (harness-ui-sessions-test--cell id name)))
                  ;; A figure that is there ends at its column's right edge.
                  (unless (string-empty-p text)
                    (should (equal (list id name (+ (nth 1 col) (nth 2 col)))
                                   (list id name (harness-ui-sessions-test--column-at
                                                  (harness-ui-sessions-test--label-end cell)))))
                    ;; And it shows whole: no ellipsis stands in for any of it.
                    (should (<= (string-width text) (nth 2 col)))
                    (should-not (cl-loop for pos from (nth 1 cell) below (nth 2 cell)
                                         thereis (stringp (get-text-property pos 'display)))))))))
          ;; The longest cost reads in full, in a column that has room for it.
          (should (equal "$0.0058+Max" (harness-ui-sessions-test--cell "extra" "Cost")))
          (should (>= (nth 2 (assoc "Cost" layout)) (string-width "$0.0058+Max")))
          (should (equal "1.2k/200k" (harness-ui-sessions-test--cell "small" "Context")))
          (should (equal "145k/384k" (harness-ui-sessions-test--cell "plan" "Context")))
          (should (equal "Max" (harness-ui-sessions-test--cell "plan" "Cost")))
          (should (equal "1.2k" (harness-ui-sessions-test--cell "plan" "Avg tok/s"))))))))

(defun harness-ui-sessions-test--check-header-in-step (id)
  "Check that the header's labels start and end where session ID's cells do.
A left-aligned one starts where its cell does, at its column's start; a
right-aligned one ends where its figure does, at the column's right edge."
  (let ((layout (harness-ui-sessions-test--layout))
        (labels (harness-ui-sessions-test--header-labels))
        (cells (harness-ui-sessions-test--cells id)))
    ;; The first column, the status icon, has no label.
    (dolist (col (cdr layout))
      (let* ((name (car col))
             (label (assoc name labels))
             (cell (assoc name cells))
             (right (nth 3 col))
             (edge (if right (+ (nth 1 col) (nth 2 col)) (nth 1 col))))
        (should label)
        (should (equal (list name edge) (list name (if right (nth 2 label) (nth 1 label)))))
        (should (equal (list name edge)
                       (list name (harness-ui-sessions-test--column-at
                                   (if right
                                       (harness-ui-sessions-test--label-end cell)
                                     (nth 1 cell))))))))))

(ert-deftest harness-ui-sessions-header-is-in-step-with-the-rows ()
  "The header's labels start and end where the rows' cells do.
A left-aligned label starts where its cells do, a right-aligned one ends
where its figures end -- also while its column is the one sorted by,
which adds an indicator to the label."
  (harness-ui-sessions-test-with-repo
    ;; A session with every figure, so every right-aligned cell has an end.
    (let ((harness-ui--rates (make-hash-table :test 'equal)))
      (harness-ui-sessions-test--add "one" root
                                     :usage (list :cost 1.23 :billing "api" :context 1200 :output 300
                                                  :stream-output 600 :stream-seconds 9.8))
      (puthash "one" '(:rate 61.4 :output 600 :seconds 9.8 :calls 2 :at 1000.0 :model "demo:scripted")
               harness-ui--rates)
      (let ((default-directory root)) (harness-sessions))
      (with-current-buffer harness-ui-sessions--buffer-name
        (let ((width (lambda ()
                       (let ((label (assoc "Context" (harness-ui-sessions-test--header-labels))))
                         (- (nth 2 label) (nth 1 label))))))
          (harness-ui-sessions-test--check-header-in-step "one")
          (should (= (string-width "Context") (funcall width)))
          ;; Sorted by a right-aligned column, its label carries the
          ;; indicator and still ends where the figures do.
          (tabulated-list-sort (cl-position "Context" tabulated-list-format :key #'car :test #'equal))
          (should (equal "Context" (car tabulated-list-sort-key)))
          (should (> (funcall width) (string-width "Context")))
          (harness-ui-sessions-test--check-header-in-step "one"))))))

(defun harness-ui-sessions-test--in-cell (cell predicate)
  "Return the first position in CELL, (NAME START END), where PREDICATE holds.
PREDICATE gets the position.  Nil when it holds nowhere in the cell."
  (with-current-buffer harness-ui-sessions--buffer-name
    (cl-loop for pos from (nth 1 cell) below (nth 2 cell)
             when (funcall predicate pos) return pos)))

(ert-deftest harness-ui-sessions-rows-keep-what-the-list-printer-keeps ()
  "A row has what `tabulated-list-print-entry' gives one.
The id and the cells of its entry over the whole line, the column of
each cell, a tooltip on a label, the ellipsis of a cut one, and the
buttons inside the cells: the context figure, the priority arrow."
  (harness-ui-sessions-test-with-repo
    (let ((cut (make-string 40 ?c)))
      (harness-ui-sessions-test--add "high" root :name cut :ext '(:priority "high"))
      (let ((default-directory root)) (harness-sessions))
      (with-current-buffer harness-ui-sessions--buffer-name
        (harness-ui-sessions-test--goto "high")
        (let* ((entry (cadr (assoc "high" tabulated-list-entries)))
               (bol (line-beginning-position))
               (eol (line-end-position))
               (cells (harness-ui-sessions-test--cells "high"))
               (name (assoc "Name" cells))
               (context (assoc "Context" cells)))
          ;; Every cell of the entry is a cell of the row, in order, and
          ;; the cells cover the line from its padding to its newline.
          (should (equal (mapcar #'car (harness-ui-sessions-test--layout)) (mapcar #'car cells)))
          (should (= (1+ bol) (nth 1 (car cells))))
          (should (= eol (nth 2 (car (last cells)))))
          ;; The whole line, its padding and newline too, is the entry's.
          (dolist (pos (list bol (1+ bol) (1- eol) eol))
            (should (equal "high" (get-text-property pos 'tabulated-list-id)))
            (should (eq entry (get-text-property pos 'tabulated-list-entry))))
          (should (equal "high" (tabulated-list-get-id)))
          (should (eq entry (tabulated-list-get-entry)))
          ;; A label has its tooltip, naming the column and holding the whole name.
          (should (equal (concat "Name: " cut) (get-text-property (nth 1 name) 'help-echo)))
          ;; A cut label keeps its text and shows an ellipsis in place of its end.
          (should (equal cut (buffer-substring-no-properties (nth 1 name)
                                                             (+ (nth 1 name) (length cut)))))
          (should (harness-ui-sessions-test--in-cell
                   name (lambda (pos) (equal (truncate-string-ellipsis)
                                             (get-text-property pos 'display)))))
          ;; The buttons inside the cells survive being printed.
          (let ((arrow (harness-ui-sessions-test--arrow-position "high")))
            (should arrow)
            (should (equal "high" (get-text-property arrow 'harness-priority-session)))
            (should (keymapp (get-text-property arrow 'keymap))))
          (should (harness-ui-sessions-test--in-cell
                   context (lambda (pos) (equal "high" (get-text-property pos 'harness-context-session)))))
          (should (harness-ui-sessions-test--in-cell
                   context (lambda (pos) (keymapp (get-text-property pos 'keymap))))))))))

;;;; The footer

(defun harness-ui-sessions-test--after-rows ()
  "Return the text of the list buffer after its last line of a session."
  (with-current-buffer harness-ui-sessions--buffer-name
    (let ((end (point-max)))
      (while (and (> end (point-min)) (not (get-text-property (1- end) 'tabulated-list-id)))
        (setq end (1- end)))
      (buffer-substring-no-properties end (point-max)))))

(ert-deftest harness-ui-sessions-footer-goes-under-the-last-row ()
  "What the footer functions return comes once, in order, under the last row.
After the line saying what that session waits on, when it is blocked.
A function that moves point or signals an error spoils nothing, and
the footer is no session's: RET and the row commands find none there."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "busy" root :status "running" :updated 300)
    (harness-ui-sessions-test--add "idle" root :updated 200)
    (let* ((seen nil)
           (harness-ui-sessions-footer-functions
            (list (lambda () "FIRST\n")
                  (lambda () nil)
                  (lambda () "")
                  (lambda () (error "A broken footer"))
                  (lambda () (push (current-buffer) seen) (goto-char (point-min)) "MOVED\n")
                  (lambda () "SECOND"))))
      (let ((default-directory root)) (harness-sessions))
      (with-current-buffer harness-ui-sessions--buffer-name
        ;; Once, whole lines, in order, under the last row.
        (should (equal "FIRST\nMOVED\nSECOND\n" (harness-ui-sessions-test--after-rows)))
        (should (equal '("busy" "idle") (mapcar #'car tabulated-list-entries)))
        ;; Called in the list's buffer, each time it was printed.
        (should seen)
        (should (cl-every (lambda (buffer) (eq buffer (current-buffer))) seen))
        (should (= 1 (save-excursion (goto-char (point-min)) (how-many "FIRST"))))
        (should (get-text-property (- (point-max) (length "FIRST\nMOVED\nSECOND\n") 1) 'tabulated-list-id))
        ;; No session's.
        (goto-char (point-max))
        (forward-line -1)
        (should (looking-at "SECOND"))
        (should-not (tabulated-list-get-id))
        (should-not (get-text-property (point) 'tabulated-list-entry))
        (should-error (harness-ui-sessions-open) :type 'user-error)
        (should-error (harness-ui-sessions-cancel) :type 'user-error))
      ;; A blocked session last: its request line first, then the footer,
      ;; which the permission keys do not reach.
      (harness-ui-sessions-test--blocked "asks" root "permission" :updated 100)
      (harness-ui-sessions--redraw)
      (with-current-buffer harness-ui-sessions--buffer-name
        (should (equal '("busy" "idle" "asks") (mapcar #'car tabulated-list-entries)))
        (should (equal "    [Allow] [Deny]  needs your permission · Bash: rm -rf build/"
                       (harness-ui-sessions-test--line "asks")))
        (should (equal "FIRST\nMOVED\nSECOND\n" (harness-ui-sessions-test--after-rows)))
        (should (= 1 (save-excursion (goto-char (point-min)) (how-many "FIRST"))))
        (let ((footer (- (point-max) (length "FIRST\nMOVED\nSECOND\n"))))
          (should (equal "asks" (tabulated-list-get-id (1- footer))))
          (should-not (get-text-property footer 'keymap))
          (should-not (tabulated-list-get-id footer)))))))

(ert-deftest harness-ui-sessions-footer-follows-the-last-row-of-a-sort ()
  "A column's sort prints the list without `harness-ui-sessions--print'.
The footer is under the last row of the order the rows were sorted
into, each time, and still once."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "alpha" root :updated 100)
    (harness-ui-sessions-test--add "beta" root :updated 300)
    (harness-ui-sessions-test--add "gamma" root :updated 200)
    (let ((harness-ui-sessions-footer-functions (list (lambda () "FOOTER\n"))))
      (let ((default-directory root)) (harness-sessions))
      (with-current-buffer harness-ui-sessions--buffer-name
        (cl-flet ((order ()
                    ;; The rows in the buffer, top to bottom, and what is under the last.
                    (let ((ids nil))
                      (goto-char (point-min))
                      (while (not (eobp))
                        (when-let* ((id (tabulated-list-get-id)))
                          (unless (equal id (car ids)) (push id ids)))
                        (forward-line 1))
                      (nreverse ids))))
          ;; The list's own order: the most recently updated first.
          (should (equal '("beta" "gamma" "alpha") (order)))
          (should (equal "FOOTER\n" (harness-ui-sessions-test--after-rows)))
          ;; Sorted by name, then back to front.
          (tabulated-list-sort 1)
          (should (equal '("alpha" "beta" "gamma") (order)))
          (should (equal "FOOTER\n" (harness-ui-sessions-test--after-rows)))
          (should (= 1 (save-excursion (goto-char (point-min)) (how-many "FOOTER"))))
          (tabulated-list-sort 1)
          (should (equal '("gamma" "beta" "alpha") (order)))
          (should (equal "FOOTER\n" (harness-ui-sessions-test--after-rows)))
          (should (= 1 (save-excursion (goto-char (point-min)) (how-many "FOOTER"))))
          ;; The footer follows the last of a print, not of the one before.
          (should (equal "alpha" (tabulated-list-get-id (- (point-max) (length "FOOTER\n") 1)))))))))

(ert-deftest harness-ui-sessions-footer-shows-with-no-row ()
  "The footer shows when no session does, under the banner of the blocked
filter, if that is on."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "busy" root :status "running")
    (let ((harness-ui-sessions-footer-functions (list (lambda () "FOOTER\n"))))
      (let ((default-directory root)) (harness-sessions))
      (with-current-buffer harness-ui-sessions--buffer-name
        (should (equal "FOOTER\n" (harness-ui-sessions-test--after-rows)))
        ;; Nothing the filter lets through.
        (harness-ui-sessions-filter "nothing like it")
        (should-not (harness-ui-sessions-test--shown))
        (should (equal "FOOTER\n" (harness-ui-sessions-test--text)))
        (should-not (tabulated-list-get-id (point-min)))
        ;; With the banner of the blocked filter above it.
        (harness-ui-sessions-toggle-blocked)
        (should (string-match-p
                 "\\` .+ No session waits for you in this project matching /nothing like it  \\[Show all\\] b\nFOOTER\n\\'"
                 (harness-ui-sessions-test--text)))
        ;; Rows come back, and the footer goes under them.
        (harness-ui-sessions-filter "")
        (harness-ui-sessions-toggle-blocked)
        (should (equal '("busy") (harness-ui-sessions-test--shown)))
        (should (equal "FOOTER\n" (harness-ui-sessions-test--after-rows)))))))

(ert-deftest harness-ui-sessions-redraw-prints-the-list-again ()
  "`harness-ui-sessions-redraw' draws the footer anew, each window keeping
its point on its session, and does nothing while there is no list."
  (harness-ui-sessions-test-with-repo
    (let* ((words "one\n")
           (harness-ui-sessions-footer-functions (list (lambda () words))))
      (harness-ui-sessions-redraw)
      (should-not (get-buffer harness-ui-sessions--buffer-name))
      (harness-ui-sessions-test--add "busy" root :updated 200)
      (harness-ui-sessions-test--add "idle" root :updated 100)
      (let ((default-directory root)) (harness-sessions))
      (with-current-buffer harness-ui-sessions--buffer-name
        (harness-ui-sessions-test--goto "idle")
        (should (equal "one\n" (harness-ui-sessions-test--after-rows)))
        (setq words "two\nlines\n")
        ;; Not by itself: the list is drawn again when asked to be.
        (should (equal "one\n" (harness-ui-sessions-test--after-rows)))
        (harness-ui-sessions-redraw)
        (should (equal "two\nlines\n" (harness-ui-sessions-test--after-rows)))
        (should (equal "idle" (tabulated-list-get-id)))
        (setq words nil)
        (harness-ui-sessions-redraw)
        (should (equal "" (harness-ui-sessions-test--after-rows)))))))

;;;; The fullscreen layout

(ert-deftest harness-ui-sessions-is-an-overview ()
  "The list can take the fullscreen layout: F starts it, q on it ends it.
Beside it shows the session at point, else the newest it lists, a BTW
aside."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "old" root :updated 100)
    (harness-ui-sessions-test--add "new" root :updated 300)
    (harness-ui-sessions-test--add "btw" root :updated 400 :kind "btw")
    (let ((default-directory root)) (harness-sessions))
    (with-current-buffer harness-ui-sessions--buffer-name
      (should (harness-ui-overview-p (current-buffer)))
      (should (eq 'harness-fullscreen (key-binding (kbd "F"))))
      (should (eq 'harness-ui-quit-view (key-binding (kbd "q"))))
      (should (eq 'harness-ui-bury (key-binding (kbd "C-c C-z"))))
      (goto-char (point-min))
      (while (not (equal (tabulated-list-get-id) "old")) (forward-line 1))
      (should (equal "old" (harness-ui-sessions--overview-session)))
      (goto-char (point-max))
      (should-not (tabulated-list-get-id))
      (should (equal "new" (harness-ui-sessions--overview-session))))))

(declare-function harness-ui--fullscreen-overview "harness-ui")

(ert-deftest harness-ui-sessions-fullscreen-opens-sessions-beside-the-list ()
  "In the fullscreen layout RET opens a session beside the list, which stays.
A listed session with no parent could anchor a layout of its own, but
opened from the list it takes the slot, every time.  After C-x 4 4, RET
opens it in another window instead, and the layout stays as it was."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "old" root :updated 100)
    (harness-ui-sessions-test--add "new" root :updated 300)
    (let* ((buffers nil)
           (file (get-buffer-create "*harness-ui-sessions-test file*"))
           (harness-ui-switch-project-function nil)
           (harness-ui-open-session-function
            (lambda (id)
              (or (cdr (assoc id buffers))
                  (let ((buf (get-buffer-create (format "*harness: sessions test %s*" id))))
                    ;; What a chat buffer is to the layout: a session's conversation.
                    (with-current-buffer buf
                      (setq-local harness-ui-session-id id)
                      (setq-local major-mode 'harness-chat-mode))
                    (push (cons id buf) buffers)
                    buf)))))
      (unwind-protect
          (let ((main (progn (delete-other-windows) (switch-to-buffer file) (selected-window)))
                (list (let ((default-directory root)) (harness-sessions) (get-buffer harness-ui-sessions--buffer-name))))
            (with-current-buffer list
              (harness-ui-sessions-test--goto "new")
              (harness-fullscreen))
            (let ((anchor (harness-ui--fullscreen-overview (harness-ui--fullscreen-layout)))
                  (old (funcall harness-ui-open-session-function "old"))
                  (new (funcall harness-ui-open-session-function "new")))
              (should (eq list (window-buffer anchor)))
              (should (eq new (window-buffer main)))
              (should (harness-ui-anchor-p old))
              ;; RET on the other session: it takes the slot.
              (select-window anchor)
              (harness-ui-sessions-test--goto "old")
              (execute-kbd-macro (kbd "RET"))
              (should (eq old (window-buffer main)))
              (should (eq list (window-buffer anchor)))
              (should (eq anchor (harness-ui--fullscreen-overview (harness-ui--fullscreen-layout))))
              ;; And back.
              (select-window anchor)
              (harness-ui-sessions-test--goto "new")
              (execute-kbd-macro (kbd "RET"))
              (should (eq new (window-buffer main)))
              (should (eq list (window-buffer anchor)))
              ;; C-x 4 4 RET: another window, the layout as it was.
              (select-window anchor)
              (harness-ui-sessions-test--goto "old")
              (execute-kbd-macro (kbd "C-x 4 4 RET"))
              (let ((window (get-buffer-window old)))
                (should window)
                (should-not (memq window (list anchor main))))
              (should (eq new (window-buffer main)))
              (should (eq list (window-buffer anchor)))
              ;; The prefix is spent with the command.
              (should-not (car display-buffer-overriding-action))))
        (ignore-errors (harness-ui--fullscreen-leave))
        (ignore-errors (delete-other-windows))
        (mapc (lambda (entry) (kill-buffer (cdr entry))) buffers)
        (kill-buffer file)))))

(ert-deftest harness-ui-sessions-waiting-shows-beside-the-anchor ()
  "With the fullscreen layout on, the waiting list shows in the slot.
It does not take the anchor's place: `harness-sessions-waiting' passes
the `slot' position, which `harness-ui-display-buffer' shows beside the
anchor."
  (harness-ui-sessions-test-with-repo
    (let* ((anchor (get-buffer-create "*harness waiting anchor*"))
           (file (get-buffer-create "*harness waiting file*"))
           (shown nil))
      (unwind-protect
          (progn
            (with-current-buffer anchor
              (setq-local harness-ui-overview-function #'ignore))
            (delete-other-windows)
            (switch-to-buffer file)
            (harness-ui--fullscreen-enter anchor)
            (should (harness-ui--fullscreen-layout))
            ;; Capture what position the list is displayed in.
            (cl-letf (((symbol-function 'harness-ui-display-view)
                       (lambda (buffer &optional position)
                         (setq shown (cons buffer position)))))
              (harness-sessions-waiting))
            (should (eq (get-buffer harness-ui-sessions--buffer-name) (car shown)))
            (should (eq 'slot (cdr shown))))
        (ignore-errors (harness-ui--fullscreen-leave))
        (kill-buffer anchor)
        (kill-buffer file)))))

;;;; Rows for other views

;; The list's columns, cells and rows are what another view that lists
;; sessions draws them with (the task slots page does): none of it reads
;; the list's buffer.

(ert-deftest harness-ui-sessions-format-is-the-format-of-the-columns-it-is-given ()
  (let ((columns (list (harness-ui-sessions-column "Name") (harness-ui-sessions-column "Cost"))))
    (should (equal [("Name" 28 t) ("Cost" 12 harness-ui-sessions--spend< :right-align t)]
                   (harness-ui-sessions-format columns)))
    ;; A column may be another width than its spec's.
    (should (equal '(("Name" 12) ("Cost" 12))
                   (mapcar (lambda (spec) (list (nth 0 spec) (nth 1 spec)))
                           (harness-ui-sessions-format columns '(("Name" . 12))))))
    (should-not (harness-ui-sessions-column "No such column"))
    ;; The list's own format is that of the columns it shows.
    (should (equal (harness-ui-sessions-format (harness-ui-sessions--shown-columns))
                   (harness-ui-sessions--format)))))

(ert-deftest harness-ui-sessions-cells-are-those-of-the-columns ()
  (clrhash harness-ui--sessions)
  (unwind-protect
      (let* ((session (harness-ui-sessions-test--add "a" "/tmp/" :status "running"))
             (columns (mapcar #'harness-ui-sessions-column '("" "Name" "Status")))
             (cells (harness-ui-sessions-cells columns session)))
        (should (= 3 (length cells)))
        (should (equal "a" (substring-no-properties (aref cells 1))))
        (should (equal "running" (substring-no-properties (aref cells 2))))
        ;; A child's name is indented under its parent's.
        (should (string-match-p "\\`  ↳ a\\'" (substring-no-properties
                                              (aref (harness-ui-sessions-cells columns session 1) 1))))
        ;; A column of the caller's own has the same shape.
        (should (equal ["x"] (harness-ui-sessions-cells (list (list :name "X" :width 1 :cell (lambda (_s _d) "x")))
                                                          session))))
    (clrhash harness-ui--sessions)))

(defun harness-ui-sessions-test--cell-start (name)
  "Return where the cell of column NAME starts in the current buffer, a row."
  (save-excursion
    (goto-char (point-min))
    (prop-match-beginning (text-property-search-forward 'tabulated-list-column-name name #'equal))))

(ert-deftest harness-ui-sessions-rows-need-no-list-buffer ()
  ;; A row in a buffer that is no list: each cell starts where its column does,
  ;; the figures end where theirs do, whatever the cells before them hold.
  (let ((format [("" 2 t) ("Name" 6 t) ("Cost" 5 nil :right-align t)]))
    (with-temp-buffer
      (harness-ui-sessions-insert-row format ["x" "abc" "$1"] 1)
      (should (string-suffix-p "\n" (buffer-string)))
      ;; The name starts at column 4: the padding, the icon column and its space.
      (let ((name (harness-ui-sessions-test--cell-start "Name")))
        (should (equal "abc" (buffer-substring-no-properties name (+ name 3))))
        (goto-char name)
        (should (= 4 (current-column))))
      (goto-char (point-min))
      (end-of-line)
      ;; Right-aligned: the figure ends at the end of its column, 4 + 6 + 1 + 5.
      (should (= 16 (current-column))))
    ;; A name that fills its column, or runs over it, leaves the next cell where it is.
    (with-temp-buffer
      (harness-ui-sessions-insert-row format ["x" "a name far too long for it" "$1"] 1)
      (goto-char (harness-ui-sessions-test--cell-start "Cost"))
      (end-of-line)
      (should (= 16 (current-column))))
    ;; The header row has its labels where the cells are, and no tooltip of its own.
    (let ((header (harness-ui-sessions-header-row format 1 'bold)))
      (should (equal " " (substring-no-properties (substring header 0 1))))
      (should (string-match "Name" header))
      (should (= 4 (let ((text (harness-ui-sessions-test--align-visual header))) (string-match "Name" text))))
      (should (= 16 (length (string-trim-right (harness-ui-sessions-test--align-visual header)))))
      (should (eq 'bold (get-text-property (string-match "Name" header) 'face header)))
      (should-not (text-property-not-all 0 (length header) 'help-echo nil header)))))

(defun harness-ui-sessions-test--align-visual (text)
  "Return TEXT, a row, as drawn: each `(space :align-to N)' written out as spaces."
  (let ((column 0) (out nil))
    (dotimes (i (length text))
      (let ((target (harness-ui-sessions-test--align-target i text)))
        (cond (target (when (> target column)
                        (push (make-string (- target column) ?\s) out)
                        (setq column target)))
              ((eq (aref text i) ?\n))
              (t (push (string (aref text i)) out)
                 (setq column (+ column (char-width (aref text i))))))))
    (apply #'concat (nreverse out))))

(ert-deftest harness-ui-sessions-entry-says-what-a-blocked-session-waits-on ()
  (harness-ui-sessions-test-with-repo
    (let* ((columns (mapcar #'harness-ui-sessions-column '("" "Name" "Status")))
           (format (harness-ui-sessions-format columns))
           (entry (lambda (id)
                    (let ((session (harness-ui-session id)))
                      (with-temp-buffer
                        (harness-ui-sessions-insert-entry session (harness-ui-sessions-cells columns session)
                                                          format 1 4)
                        (buffer-string))))))
      (harness-ui-sessions-test--blocked "stuck" root "permission")
      (harness-ui-sessions-test--add "fine" root)
      ;; One line for a session that waits on nothing.
      (should (= 1 (length (split-string (string-trim-right (funcall entry "fine")) "\n"))))
      ;; Two for one that waits on a request: the buttons that answer it, and what it is.
      (let* ((text (funcall entry "stuck"))
             (lines (split-string (string-trim-right text) "\n")))
        (should (= 2 (length lines)))
        (should (string-match-p "\\`    \\[Allow\\].*\\[Deny\\].*Bash: rm -rf build/" (substring-no-properties (nth 1 lines))))
        ;; y and n answer a permission request, on both lines.
        (should (eq #'harness-ui-sessions-allow (lookup-key (get-text-property 5 'keymap text) "y")))
        (should (eq #'harness-ui-sessions-deny (lookup-key (get-text-property 5 'keymap text) "n")))
        (should (get-text-property (1+ (string-match "\n" text)) 'keymap text)))
      ;; A question has no y or n.
      (harness-ui-sessions-test--blocked "asking" root "question")
      (should-not (lookup-key (or (get-text-property 5 'keymap (funcall entry "asking")) (make-sparse-keymap)) "y"))
      ;; Given the width of a window, what it waits on is cut to fit it.
      (harness-ui-sessions-test--add
       "long" root :status "blocked"
       :pending (list (list :id "long-q" :kind "question"
                            :payload (list :question "Which of the two colours would you rather the headings were drawn in?"
                                           :options '("red" "green")))))
      (let ((request (lambda (width)
                       (substring-no-properties
                        (string-trim-right
                         (harness-ui-sessions-request-line "long" (harness-ui-pending-first "long") 4 width))))))
        (should (string-match-p "headings were drawn in\\?\\'" (funcall request nil)))
        (should (string-match-p "headings were drawn in\\?\\'" (funcall request 200)))
        (let ((narrow (funcall request 70)))
          (should (< (string-width narrow) 70))
          (should (string-match-p "…\\'" narrow)))
        ;; Never less than a few characters of it, however narrow the window.
        (should (string-match-p "Which" (funcall request 5)))))))

(ert-deftest harness-ui-sessions-allow-and-deny-answer-for-the-session-at-point-of-any-view ()
  ;; The list finds its session in its rows; another view says it through
  ;; `harness-ui-session-at-point-function', and y and n answer for it too.
  (let (answered)
    (cl-letf (((symbol-function 'harness-ui-pending-answer-first-permission)
               (lambda (id option) (push (list id option) answered))))
      (with-temp-buffer
        (setq-local harness-ui-session-at-point-function (lambda () "s-here"))
        (harness-ui-sessions-allow)
        (harness-ui-sessions-deny))
      (should (equal '(("s-here" "allow-once") ("s-here" "deny-once")) (nreverse answered)))
      ;; With no session at point, no answer.
      (with-temp-buffer
        (should-error (harness-ui-sessions-allow) :type 'user-error)))))

(provide 'harness-ui-sessions-test)
;;; harness-ui-sessions-test.el ends here
