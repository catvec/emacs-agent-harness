;;; harness-insights.el --- How the work went, from the harness's own records  -*- lexical-binding: t; -*-

;;; Commentary:

;; The Insights report: what a period of work with the agents looked
;; like, in figures and, when a model may be asked, in words (a summary,
;; themes, friction, suggestions), as Claude Code's /insights has it.
;; It is made from what the harness keeps itself: the sessions and their
;; transcripts, the usage records, the task board and a log of
;; permission decisions.  So it reads the same whatever the provider --
;; Claude, OpenAI, Copilot, Bedrock, DeepSeek or an ACP agent -- and no
;; provider's own history is read.  The UI shows it in a buffer of its
;; own (lisp/ui/harness-ui-insights.el).
;;
;; `insights/compute' gathers a period's figures.  The period runs from
;; `:since' (nil: the start) to `:until' (nil: now); the scope is
;; `:project', a main checkout, or nil for every project:
;;
;;   usage        `usage/totals', `usage/summary' by model and by
;;                project and `usage/series': the usage dashboard's own
;;                queries with its filters, so the figures are the
;;                dashboard's.  A project counts with its git worktrees,
;;                where its tasks work (`:projects'), as the dashboard
;;                folds them into the project's line.
;;   sessions     the sessions that worked in the period, by kind (a
;;                task's session counts as a task), their turns, the
;;                messages the user wrote and the time they were active
;;   tools        the calls of each tool, how many failed, were denied
;;                or interrupted, and the time they took
;;   permissions  denials, from the transcripts; from the decision log,
;;                how often the user was asked and what they answered
;;   tasks        submitted, completed, merged, sent back, failed; how
;;                many the user accepted the first time, and how many
;;                merges met a conflict
;;   activity     the messages the user wrote by hour of day and by
;;                weekday, the days they wrote any, and their streaks
;;
;; The transcripts are read by a child `emacs --batch' running
;; `harness-insights-scan-main', never by the harness process: a
;; period's node logs can be large, and the harness keeps serving its
;; sessions meanwhile.  The child gets the sessions to read from the
;; harness, whose records are current where their files may lag; it
;; counts only the nodes a session wrote itself (a fork's log repeats
;; its parent's path, with the parent's `:session') and reports
;; figures, not transcripts.  A session belongs to the main checkout of
;; its project, worked out as the usage dashboard works it out
;; (`harness-files-owning-checkout').
;;
;; `insights/narrative' writes the words.  The figures, and the names
;; and first requests of the sessions, go to a cheap model of the user's
;; own provider (`harness-insights-model': the cheap tier of
;; `harness-model' by default; no provider is named here) as a one-off
;; call, like the task board's search.  The model answers in JSON: a
;; summary, themes, patterns, friction and suggestions.  The answer is
;; kept per period and scope (insights/narratives.json) and shown for
;; `harness-insights-narrative-max-age' seconds.  A failed call -- no
;; network, no provider -- leaves the report without words, and is not
;; tried again on its own for `harness-insights--narrative-retry'
;; seconds.  `harness-insights-narrative' turns the words off, or to
;; being written only when asked.
;;
;; The decision log: a transcript says when a call was denied, not
;; whether the user was asked.  The module listens to
;; `permission/requested' and `permission/decided' and appends a line
;; per decision to insights/permissions-YYYY-MM.jsonl: the time, the
;; session, the tool, allow or deny, and whether the user was asked.
;; `harness-insights-record-permissions' turns it off.  Months older
;; than `harness-insights--permission-months' go when the module starts.
;;
;; Load order: modules load alphabetically and this one comes before
;; session, tasks and usage, so nothing here uses them at load time.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-files)

(defvar harness-state-directory)
(defvar harness-model)
(defvar harness-elisp-emacs)
(defvar harness-directory)

;;;; Settings

(defcustom harness-insights-narrative 'auto
  "Whether the Insights report has a written summary from a model.
`auto' writes one when the report opens without a recent one (see
`harness-insights-narrative-max-age'); `manual' only when asked (n in
the report); nil never, and the report then has figures only: nothing
of it leaves the harness."
  :type '(choice (const :tag "When the report opens" auto)
                 (const :tag "Only when asked" manual)
                 (const :tag "Never" nil))
  :group 'harness)

(defcustom harness-insights-model 'auto
  "Model that writes the Insights summary, as PROVIDER:NAME, or `auto'.
`auto' (the default) asks the provider of `harness-model' for its
`cheap' tier (see `harness-provider-tier-model'), as the task board's
search does: the summary reads figures and a list, which a quick,
cheap model does well.  A PROVIDER:NAME forces that model, and nil
uses `harness-model' itself."
  :type '(choice (const :tag "Your provider's cheap model" auto)
                 (const :tag "Your default model" nil)
                 (string :tag "Model" :names model))
  :group 'harness)

(defcustom harness-insights-narrative-max-age 86400
  "Seconds a written summary is shown before `auto' writes a new one.
n in the report writes a new one whenever you like."
  :type 'integer :group 'harness)

(defcustom harness-insights-record-permissions t
  "Whether permission decisions are logged for the Insights report.
The log, insights/permissions-YYYY-MM.jsonl in the state directory,
says for each tool call whether it was allowed and whether you were
asked.  Without it the report counts denials only."
  :type 'boolean :group 'harness)

;;;; Internals

(defconst harness-insights--scan-timeout 300
  "Seconds the child Emacs that reads the transcripts may run.")

(defconst harness-insights--idle-gap 600
  "Seconds between two nodes of a session beyond which it was idle.
Its active time adds up the shorter gaps.")

(defconst harness-insights--session-rows 12
  "Most sessions the report lists as the busiest.")

(defconst harness-insights--prompt-chars 200
  "Characters of a session's first request kept for the report.")

(defconst harness-insights--narrative-sessions 60
  "Most sessions the model writing the summary reads about.")

(defconst harness-insights--narrative-timeout 120
  "Seconds the model may take to write the summary.")

(defconst harness-insights--narrative-max-tokens 1500
  "Most tokens the summary may take.")

(defconst harness-insights--narrative-retry 600
  "Seconds after a failed summary before `auto' tries again.")

(defconst harness-insights--narratives-kept 24
  "Most summaries kept, one per period and scope.")

(defconst harness-insights--memo-age 600
  "Seconds a computed report stays at hand for writing its summary.")

(defconst harness-insights--permission-months 24
  "Months of permission decisions kept.")

(defconst harness-insights--narratives-name "insights/narratives.json"
  "Store file of the written summaries.")

(defconst harness-insights--permission-file-re
  "\\`permissions-\\([0-9]\\{4\\}-[0-9]\\{2\\}\\)\\.jsonl\\'"
  "Names of the monthly decision logs; the group is the month.")

(defconst harness-insights--conflict-re
  "\\`\\(?:Merge into .* has conflicts in \\|Merging your branch .* would conflict\\)"
  "What the merge queue tells a session whose merge met a conflict.")

(defconst harness-insights--merged-re "\\`Merge into .* finished: merged"
  "What the merge queue tells a session whose branch merged.")

(defconst harness-insights--merge-failed-re "\\`Merge into .* finished: \\(?:failed\\|aborted\\)"
  "What the merge queue tells a session whose merge failed or was given up.")

(defvar harness-insights--running (make-hash-table :test 'equal)
  "Report key -> promise of the report being computed.")

(defvar harness-insights--memo nil
  "Recent reports: a list of (KEY TIME . REPORT), newest first.")

(defvar harness-insights--narrating (make-hash-table :test 'equal)
  "Report key -> promise of the summary being written.")

(defvar harness-insights--failed (make-hash-table :test 'equal)
  "Report key -> (TIME . MESSAGE) of its last failed summary.")

(defvar harness-insights--asked (make-hash-table :test 'equal)
  "\"SESSION CALL-ID\" -> when the user was asked about that tool call.")

;;;; Small helpers (both processes)

(defun harness-insights--in-p (ts since until)
  "Non-nil when time TS falls in the period from SINCE to UNTIL.
SINCE nil is the start of time; UNTIL is exclusive."
  (and (numberp ts) (or (null since) (>= ts since)) (< ts until)))

(defun harness-insights--squash (text max)
  "Return TEXT on one line, its whitespace collapsed, at most MAX characters.
TEXT may be a string or a list of content blocks."
  (let* ((s (cond ((stringp text) text)
                  ((consp text)
                   (mapconcat (lambda (b) (let ((tx (and (consp b) (plist-get b :text))))
                                            (if (stringp tx) tx "")))
                              text " "))
                  (t "")))
         (s (substring s 0 (min (length s) (* 4 max)))))
    (harness-truncate-end (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " s)) max)))

(defun harness-insights--root (dir)
  "Return DIR as a directory name, expanded, or nil when it is not a name."
  (and (stringp dir) (not (string-empty-p dir))
       (file-name-as-directory (expand-file-name dir))))

(defun harness-insights--scope (project)
  "Return the main checkout a report narrowed to PROJECT covers, or nil.
A git worktree's report is its repository's: the work of its tasks is
the project's work."
  (let ((main (harness-insights--main project (make-hash-table :test 'equal))))
    (unless (string-empty-p main) main)))

(defun harness-insights--main (root memo)
  "Return the main checkout project ROOT belongs to, \"\" for none.
As the usage dashboard says it (`harness-files-owning-checkout').  MEMO,
a hash table, keeps the answers of one run."
  (let ((root (harness-insights--root root)))
    (if (null root)
        ""
      (or (gethash root memo)
          (puthash root (or (ignore-errors (harness-files-owning-checkout root)) root) memo)))))

;;;; Reading the transcripts (in the child Emacs)

(defun harness-insights--read-log (file)
  "Return the records of JSONL FILE in order; lines that do not parse are skipped."
  (let (out)
    (when (file-readable-p file)
      (with-temp-buffer
        (let ((coding-system-for-read 'utf-8)) (insert-file-contents file))
        (goto-char (point-min))
        (while (not (eobp))
          (let ((next (min (point-max) (1+ (line-end-position)))))
            (unless (= (point) (line-end-position))
              (let ((rec (condition-case nil
                             (json-parse-buffer :object-type 'plist :array-type 'list
                                                :null-object nil :false-object :false)
                           (error nil))))
                (when (consp rec) (push rec out))))
            (goto-char next)))))
    (nreverse out)))

(defun harness-insights--own-nodes (file sid seen)
  "Return the nodes session SID wrote, from its node log FILE, by time.
A line updating a node is merged into it.  Nodes of another session,
the parent's path a fork starts with, are left out, and so are nodes
whose id SEEN (a hash table) has; SEEN gets every node returned."
  (let ((table (make-hash-table :test 'equal)) order out)
    (dolist (rec (harness-insights--read-log file))
      (let ((id (plist-get rec :id)))
        (cond ((null id))
              ((equal (plist-get rec :_op) "update")
               (when-let* ((old (gethash id table)))
                 (puthash id (harness-plist-merge old (harness-plist-remove rec :_op)) table)))
              (t (unless (gethash id table) (push id order))
                 (puthash id rec table)))))
    (dolist (id (nreverse order))
      (let* ((n (gethash id table))
             (owner (plist-get n :session)))
        (when (and (or (null owner) (equal owner sid))
                   (not (gethash id seen)))
          (puthash id t seen)
          (push n out))))
    (sort (nreverse out) (lambda (a b) (< (or (plist-get a :ts) 0) (or (plist-get b :ts) 0))))))

(defun harness-insights--merge-queue-p (from)
  "Non-nil when FROM, a message's sender, is the merge queue."
  (and (eq (harness-sender-kind from) 'system)
       (equal (plist-get from :source) "merge queue")))

(defun harness-insights--streaks (days today)
  "Return (LONGEST END CURRENT) for the active DAYS.
DAYS is a hash table keyed by day numbers (`time-to-days'); TODAY is
today's.  LONGEST is the longest run of consecutive days, END the day
it ended, CURRENT the run that ends today, or yesterday when today has
nothing yet."
  (let ((longest 0) (end nil) (run 0) (prev nil))
    (dolist (d (sort (hash-table-keys days) #'<))
      (setq run (if (and prev (= d (1+ prev))) (1+ run) 1))
      (when (> run longest) (setq longest run end d))
      (setq prev d))
    (let ((current 0)
          (d (cond ((gethash today days) today)
                   ((gethash (1- today) days) (1- today)))))
      (while (and d (gethash d days))
        (cl-incf current)
        (setq d (1- d)))
      (list longest end current))))

(defun harness-insights--count-list (table key-name fields &optional sort-key)
  "Return TABLE, KEY -> vector of FIELDS' values, as a list of plists.
Each plist has KEY-NAME and FIELDS, sorted by SORT-KEY (default the
first field) descending."
  (let (out)
    (maphash (lambda (k v)
               (push (append (list key-name k)
                             (cl-loop for f in fields for i from 0 append (list f (aref v i))))
                     out))
             table)
    (let ((sort-key (or sort-key (car fields))))
      (sort out (lambda (a b) (> (plist-get a sort-key) (plist-get b sort-key)))))))

(defun harness-insights-scan (input)
  "Return the figures of the transcripts INPUT names.
INPUT is what `harness-insights--scan-input' makes: the sessions to
read, the period, the scope, the decision logs.  The result has
`:sessions', `:session-list', `:tools', `:tool-totals',
`:permissions', `:activity', `:projects', `:merges' and `:scan'; see
`insights/compute'."
  (let* ((dir (plist-get input :sessions-dir))
         (since (plist-get input :since))
         (until (or (plist-get input :until) (float-time)))
         (project (plist-get input :project))
         (gap (or (plist-get input :idle-gap) harness-insights--idle-gap))
         (chars (or (plist-get input :prompt-chars) harness-insights--prompt-chars))
         (now (or (plist-get input :now) (float-time)))
         (started (float-time))
         (mains (make-hash-table :test 'equal))
         (seen (make-hash-table :test 'equal))
         (scope (make-hash-table :test 'equal))
         ;; Tool -> [calls errors denied interrupted seconds unanswered].
         (tools (make-hash-table :test 'equal))
         ;; Kind -> [sessions turns messages active].
         (kinds (make-hash-table :test 'equal))
         ;; Main checkout -> [sessions turns messages active].
         (projects (make-hash-table :test 'equal))
         ;; Day number -> [messages date].
         (days (make-hash-table :test 'eql))
         (hours (make-vector 24 0))
         (weekdays (make-vector 7 0))
         (rows nil) (merges nil)
         (files 0) (node-count 0)
         (t-turns 0) (t-messages 0) (t-active 0.0)
         (t-calls 0) (t-errors 0) (t-denied 0) (t-interrupted 0))
    (dolist (s (plist-get input :sessions))
      (let* ((sid (plist-get s :id))
             (main (harness-insights--main (plist-get s :project) mains))
             (file (and (stringp sid) (expand-file-name (concat sid ".nodes.jsonl") dir))))
        (when (and file (or (null project) (equal main project)))
          (puthash sid main scope)
          (when (file-readable-p file)
            (cl-incf files)
            (let ((nodes (harness-insights--own-nodes file sid seen))
                  (results (make-hash-table :test 'equal))
                  (calls nil) (prompt nil) (live nil) (prev nil) (first nil) (last nil)
                  (turns 0) (messages 0) (active 0.0)
                  (s-calls 0) (s-errors 0) (s-denied 0)
                  (conflicts 0) (merged 0) (failed 0))
              (cl-incf node-count (length nodes))
              (dolist (n nodes)
                (when (equal (plist-get n :kind) "tool-result")
                  (puthash (plist-get n :call-id) n results)))
              (dolist (n nodes)
                (let* ((kind (plist-get n :kind))
                       (ts (plist-get n :ts))
                       (meta (plist-get n :meta))
                       (in (harness-insights--in-p ts since until)))
                  (pcase kind
                    ("user"
                     (let ((from (plist-get meta :from))
                           (text (plist-get n :content)))
                       (unless prompt (setq prompt (harness-insights--squash text chars)))
                       (when (and (harness-insights--merge-queue-p from) (stringp text)
                                  (string-match-p harness-insights--conflict-re text))
                         (cl-incf conflicts))
                       (when in
                         (unless (harness-json-true-p (plist-get meta :steering)) (cl-incf turns))
                         (unless (harness-sender-kind from)
                           (cl-incf messages)
                           (let* ((time (decode-time ts))
                                  (day (time-to-days ts))
                                  (cell (or (gethash day days)
                                            (puthash day (vector 0 (format-time-string "%Y-%m-%d" ts)) days))))
                             (cl-incf (aref hours (decoded-time-hour time)))
                             ;; Monday first.
                             (cl-incf (aref weekdays (mod (+ (decoded-time-weekday time) 6) 7)))
                             (cl-incf (aref cell 0)))))))
                    ("tool-call"
                     ;; A call the harness wrote itself, not the model's, says who did.
                     (when (and in (not (plist-get meta :from)))
                       (push n calls)))
                    ("hint"
                     (let ((text (plist-get n :content)))
                       (when (stringp text)
                         (cond ((string-match-p harness-insights--conflict-re text) (cl-incf conflicts))
                               ((string-match-p harness-insights--merged-re text) (cl-incf merged))
                               ((string-match-p harness-insights--merge-failed-re text) (cl-incf failed)))))))
                  ;; A fork answers the calls it copied unanswered when it
                  ;; is made: no work of its own.
                  (when (and in (member kind '("user" "assistant" "thinking" "tool-call" "tool-result"))
                             (not (harness-json-true-p (plist-get meta :forked))))
                    (setq live t)
                    (when (and prev (> ts prev) (<= (- ts prev) gap))
                      (cl-incf active (- ts prev)))
                    (setq prev ts
                          first (or first ts)
                          last ts))))
              (dolist (c calls)
                (let* ((name (format "%s" (or (plist-get c :tool) "?")))
                       (r (gethash (plist-get c :call-id) results))
                       (rmeta (plist-get r :meta))
                       (v (or (gethash name tools) (puthash name (make-vector 6 0) tools))))
                  (unless (harness-json-true-p (plist-get rmeta :forked))
                    (cl-incf (aref v 0))
                    (cl-incf s-calls)
                    (cond ((null r) (cl-incf (aref v 5)))
                          ((harness-json-true-p (plist-get rmeta :denied))
                           (cl-incf (aref v 2)) (cl-incf s-denied))
                          ((harness-json-true-p (plist-get rmeta :interrupted))
                           (cl-incf (aref v 3)) (cl-incf t-interrupted))
                          ((harness-json-true-p (plist-get r :is-error))
                           (cl-incf (aref v 1)) (cl-incf s-errors)))
                    (when (numberp (plist-get rmeta :duration))
                      (cl-incf (aref v 4) (plist-get rmeta :duration))))))
              (when live
                (let* ((kind (if (plist-get s :task) "task" (format "%s" (or (plist-get s :kind) "main"))))
                       (k (or (gethash kind kinds) (puthash kind (vector 0 0 0 0.0) kinds)))
                       (p (or (gethash main projects) (puthash main (vector 0 0 0 0.0) projects))))
                  (dolist (v (list k p))
                    (cl-incf (aref v 0))
                    (cl-incf (aref v 1) turns)
                    (cl-incf (aref v 2) messages)
                    (cl-incf (aref v 3) active))
                  (cl-incf t-turns turns)
                  (cl-incf t-messages messages)
                  (cl-incf t-active active)
                  (cl-incf t-calls s-calls)
                  (cl-incf t-errors s-errors)
                  (cl-incf t-denied s-denied)
                  (push (list :id sid :name (plist-get s :name) :kind kind :main main
                              :model (plist-get s :model) :prompt prompt
                              :turns turns :messages messages :tools s-calls :errors s-errors
                              :denied s-denied :active active :first first :last last
                              :task (plist-get s :task))
                        rows)))
              (when (> (+ conflicts merged failed) 0)
                (push (list :session sid :conflicts conflicts :merged merged :failed failed) merges)))))))
    ;; The decision log.
    (let ((ptools (make-hash-table :test 'equal))
          (decisions 0) (allowed 0) (denied 0) (asked 0) (asked-allowed 0) (asked-denied 0) (p-first nil))
      (dolist (f (plist-get input :permission-files))
        (dolist (rec (harness-insights--read-log f))
          (let ((ts (plist-get rec :ts)))
            (when (and (harness-insights--in-p ts since until)
                       (or (null project) (gethash (plist-get rec :session) scope)))
              (let* ((allow (equal (plist-get rec :behavior) "allow"))
                     (was-asked (harness-json-true-p (plist-get rec :asked)))
                     (tool (format "%s" (or (plist-get rec :tool) "?")))
                     ;; [decisions asked denied asked-denied]
                     (v (or (gethash tool ptools) (puthash tool (make-vector 4 0) ptools))))
                (setq p-first (if p-first (min p-first ts) ts))
                (cl-incf decisions)
                (cl-incf (aref v 0))
                (if allow (cl-incf allowed) (cl-incf denied) (cl-incf (aref v 2)))
                (when was-asked
                  (cl-incf asked)
                  (cl-incf (aref v 1))
                  (if allow (cl-incf asked-allowed) (cl-incf asked-denied) (cl-incf (aref v 3)))))))))
      (let* ((streaks (harness-insights--streaks days (time-to-days now)))
             (busiest (let (best)
                        (maphash (lambda (_ v) (when (or (null best) (> (aref v 0) (aref best 0))) (setq best v)))
                                 days)
                        best)))
        (list
         :sessions (list :active (length rows) :turns t-turns :messages t-messages :active-seconds t-active
                         :by-kind (harness-insights--count-list kinds :kind '(:sessions :turns :messages :active)))
         :session-list (sort rows (lambda (a b) (> (or (plist-get a :last) 0) (or (plist-get b :last) 0))))
         :tools (harness-insights--count-list
                 tools :tool '(:calls :errors :denied :interrupted :seconds :unanswered))
         :tool-totals (list :calls t-calls :errors t-errors :denied t-denied :interrupted t-interrupted)
         :permissions (list :decisions decisions :allowed allowed :denied denied
                            :asked asked :asked-allowed asked-allowed :asked-denied asked-denied
                            :first p-first
                            :tools (harness-insights--count-list
                                    ptools :tool '(:decisions :asked :denied :asked-denied)))
         :activity (list :hours (append hours nil) :weekdays (append weekdays nil)
                         :active-days (hash-table-count days)
                         :longest-streak (nth 0 streaks)
                         :longest-streak-end (and (nth 1 streaks) (aref (gethash (nth 1 streaks) days) 1))
                         :current-streak (nth 2 streaks)
                         :busiest-day (and busiest (list :day (aref busiest 1) :messages (aref busiest 0))))
         :projects (harness-insights--count-list projects :main '(:sessions :turns :messages :active) :active)
         :merges merges
         :scan (list :sessions (length (plist-get input :sessions)) :files files :nodes node-count
                     :seconds (- (float-time) started)))))))

(defun harness-insights-scan-main ()
  "Read the transcripts for an Insights report, in a child `emacs --batch'.
The harness writes the request as JSON to the file named by
$HARNESS_INSIGHTS_INPUT (see `harness-insights--scan-input'), and the
figures go as JSON to the file named by $HARNESS_INSIGHTS_OUTPUT, or
\(:error MESSAGE) when reading failed."
  (setq gc-cons-threshold (* 256 1024 1024))
  (let* ((in (getenv "HARNESS_INSIGHTS_INPUT"))
         (out (getenv "HARNESS_INSIGHTS_OUTPUT"))
         (result (condition-case err
                     (harness-insights-scan (harness-json-parse (harness-read-file in)))
                   (error (list :error (error-message-string err))))))
    (let ((coding-system-for-write 'utf-8-unix))
      (write-region (harness-json-encode result) nil out nil 'silent))
    (kill-emacs 0)))

;;;; Running the child (in the harness)

(defun harness-insights--permission-files (since until)
  "Return the decision logs that may hold decisions from SINCE to UNTIL."
  (let ((dir (expand-file-name "insights/" harness-state-directory))
        (from (and since (format-time-string "%Y-%m" since)))
        (to (format-time-string "%Y-%m" until)))
    (when (file-directory-p dir)
      (cl-loop for f in (directory-files dir t harness-insights--permission-file-re)
               for month = (and (string-match harness-insights--permission-file-re (file-name-nondirectory f))
                                (match-string 1 (file-name-nondirectory f)))
               when (and month (or (null from) (not (string< month from))) (not (string< to month)))
               collect f))))

(defun harness-insights--all-tasks (&optional project)
  "Return every task the task board has loaded, or nil without a board.
With PROJECT, its repository's store is read first if it was not, as
the board does for a project it shows."
  (when (harness-method-exists-p 'task/list)
    (when project (ignore-errors (harness-call 'task/list project)))
    (ignore-errors (harness-call 'task/list))))

(defun harness-insights--scan-input (since until project tasks)
  "Return what the child reads for the period SINCE to UNTIL in PROJECT.
TASKS are the board's tasks, which say whose sessions are tasks'.  The
sessions are those whose life overlaps the period, from the harness's
records, which are current where their files may lag."
  (let ((task-of (make-hash-table :test 'equal)))
    (dolist (task tasks)
      (when-let* ((sid (plist-get task :session)))
        (puthash sid (plist-get task :id) task-of)))
    (list :sessions-dir (expand-file-name "sessions/" harness-state-directory)
          :since since :until until :project project :now (float-time)
          :idle-gap harness-insights--idle-gap
          :prompt-chars harness-insights--prompt-chars
          :permission-files (harness-insights--permission-files since until)
          :sessions
          (and (harness-method-exists-p 'session/list)
               (cl-loop for s in (harness-call 'session/list)
                        for created = (or (plist-get s :created) 0)
                        for updated = (or (plist-get s :updated) created)
                        when (and (or (null since) (>= updated since)) (< created until))
                        collect (list :id (plist-get s :id) :name (plist-get s :name)
                                      :kind (format "%s" (or (plist-get s :kind) "main"))
                                      :project (plist-get s :project) :model (plist-get s :model)
                                      :task (gethash (plist-get s :id) task-of)))))))

(defun harness-insights--scan-file ()
  "Return the file the child loads: this module, as the harness loaded it.
That is its compiled file, the transcripts being many; the source when
the compiled one is gone."
  (let ((loaded (symbol-file 'harness-insights-scan-main 'defun))
        (source (expand-file-name "lisp/modules/harness-insights.el" harness-directory)))
    (if (and loaded (file-readable-p loaded)) loaded source)))

(defun harness-insights--stderr-tail (text)
  "Return the last line of TEXT worth showing, or a placeholder."
  (let ((lines (split-string (or text "") "\n" t "[ \t]+")))
    (if lines (harness-truncate-end (car (last lines)) 200) "no output")))

(defun harness-insights--run-scan (input)
  "Return a promise of the figures a child Emacs reads for INPUT."
  (let* ((dir (make-temp-file "harness-insights-" t))
         (in (expand-file-name "input.json" dir))
         (out (expand-file-name "output.json" dir))
         (clean (lambda () (ignore-errors (delete-directory dir t)))))
    (let ((coding-system-for-write 'utf-8-unix))
      (write-region (harness-json-encode input) nil in nil 'silent))
    (harness-then
     (harness-run-command
      (list (if (boundp 'harness-elisp-emacs)
                harness-elisp-emacs
              (expand-file-name invocation-name invocation-directory))
            "--batch" "-Q"
            "-L" harness-directory
            "-L" (expand-file-name "lisp" harness-directory)
            "-l" (harness-insights--scan-file)
            "-f" "harness-insights-scan-main")
      :cwd dir :timeout harness-insights--scan-timeout :name "harness-insights"
      :env (list (cons "HARNESS_INSIGHTS_INPUT" in) (cons "HARNESS_INSIGHTS_OUTPUT" out)))
     (lambda (r)
       (let ((result (and (file-readable-p out)
                          (ignore-errors (harness-json-parse (harness-read-file out))))))
         (funcall clean)
         (cond
          ((eq (plist-get r :exit) 'timeout)
           (signal 'harness-error (list (format "reading the transcripts took longer than %s"
                                                (harness-format-duration harness-insights--scan-timeout)))))
          ((plist-get result :error)
           (signal 'harness-error (list (format "reading the transcripts failed: %s" (plist-get result :error)))))
          ((null result)
           (signal 'harness-error (list (format "reading the transcripts failed: %s"
                                                (harness-insights--stderr-tail (plist-get r :stderr))))))
          (t result))))
     (lambda (err)
       (funcall clean)
       (harness-rejected err)))))

;;;; Usage

(defun harness-insights--row-main (row)
  "Return the main checkout of usage ROW by project, \"\" for none."
  (let ((main (plist-get row :main)))
    (if (and (stringp main) (not (string-empty-p main))) main (or (plist-get row :key) ""))))

(defun harness-insights--sum-rows (key rows &rest extra)
  "Return usage ROWS summed into one row keyed KEY, with EXTRA added."
  (let ((sum (lambda (k) (apply #'+ (mapcar (lambda (r) (or (plist-get r k) 0)) rows)))))
    (append (list :key key
                  :input (funcall sum :input) :output (funcall sum :output)
                  :cache-read (funcall sum :cache-read) :cache-write (funcall sum :cache-write)
                  :cost (funcall sum :cost)
                  :list-cost (apply #'+ (mapcar #'harness-usage-list-cost rows))
                  :calls (funcall sum :calls))
            extra)))

(defun harness-insights--costlier-p (a b)
  "Non-nil when usage row A is worth more than B at API prices."
  (> (harness-usage-list-cost a) (harness-usage-list-cost b)))

(defun harness-insights--fold-projects (rows)
  "Return usage ROWS by project gathered under their main checkouts.
Each group is a row keyed by the main checkout, summed, with
`:worktrees', how many of its rows are git worktrees; costliest first."
  (let ((table (make-hash-table :test 'equal)) order)
    (dolist (r rows)
      (let ((main (harness-insights--row-main r)))
        (unless (gethash main table) (push main order))
        (push r (gethash main table))))
    (sort (mapcar (lambda (main)
                    (let ((members (gethash main table)))
                      (harness-insights--sum-rows
                       main members
                       :worktrees (cl-count-if-not (lambda (r) (equal (plist-get r :key) main)) members))))
                  order)
          #'harness-insights--costlier-p)))

(defun harness-insights--by-provider (by-model)
  "Return the usage rows BY-MODEL summed per provider, costliest first."
  (let ((table (make-hash-table :test 'equal)) order)
    (dolist (r by-model)
      (let ((p (format "%s" (or (harness-model-provider (plist-get r :key)) "other"))))
        (unless (gethash p table) (push p order))
        (push r (gethash p table))))
    (sort (mapcar (lambda (p) (harness-insights--sum-rows p (gethash p table))) order)
          #'harness-insights--costlier-p)))

(defun harness-insights--zero-totals ()
  "Return usage totals of nothing."
  (list :input 0 :output 0 :cache-read 0 :cache-write 0 :cost 0 :list-cost 0 :calls 0))

(defun harness-insights--usage (since until project bucket)
  "Return the usage of the period SINCE to UNTIL in PROJECT, nil for all.
The figures come from the usage dashboard's queries with its filters:
`usage/totals', `usage/summary' and `usage/series' per BUCKET (day or
hour).  A project's rows are its main checkout's and its git
worktrees' (`:projects'), as the dashboard folds them.  The result has
`:totals', `:by-model', `:by-provider', `:projects' (by main checkout
for every project, else the project's checkouts), `:series' and
`:bucket'."
  (if (not (harness-method-exists-p 'usage/totals))
      (list :totals (harness-insights--zero-totals) :bucket bucket :missing t)
    (let* ((filters (append (and since (list :since since)) (and until (list :until until))))
           (by-project (apply #'harness-call 'usage/summary :group-by 'project filters))
           (members (if project
                        (cl-remove-if-not (lambda (r) (equal (harness-insights--row-main r) project)) by-project)
                      by-project))
           (roots (and project (delete "" (mapcar (lambda (r) (plist-get r :key)) members)))))
      (if (and project (null roots))
          (list :totals (harness-insights--zero-totals) :by-model nil :by-provider nil
                :projects nil :series nil :bucket bucket)
        (let* ((f (append filters (and roots (list :projects roots))))
               (by-model (apply #'harness-call 'usage/summary :group-by 'model f)))
          (list :totals (apply #'harness-call 'usage/totals f)
                :by-model by-model
                :by-provider (harness-insights--by-provider by-model)
                :projects (if project
                              (sort (copy-sequence members) #'harness-insights--costlier-p)
                            (harness-insights--fold-projects members))
                :series (apply #'harness-call 'usage/series :bucket bucket f)
                :bucket bucket))))))

;;;; Tasks

(defun harness-insights--task-title (task)
  "Return the title of TASK: its session's name, else its prompt's first line."
  (let* ((sid (plist-get task :session))
         (session (and sid (harness-method-exists-p 'session/get)
                       (ignore-errors (harness-call 'session/get sid))))
         (name (plist-get session :name)))
    (if (and (stringp name) (not (string-blank-p name)))
        name
      (harness-first-line (plist-get task :prompt) 80))))

(defun harness-insights--task-done-at (task)
  "Return when done TASK was completed, or nil when it is not done."
  (when (equal (format "%s" (plist-get task :state)) "done")
    (let ((at (max (or (plist-get task :finished) 0) (or (plist-get task :verified-at) 0))))
      (and (> at 0) at))))

(defun harness-insights--median (numbers)
  "Return the median of NUMBERS, or nil when there are none."
  (when numbers
    (let* ((v (vconcat (sort (copy-sequence numbers) #'<)))
           (n (length v)))
      (if (cl-oddp n)
          (aref v (/ n 2))
        (/ (+ (aref v (1- (/ n 2))) (aref v (/ n 2))) 2.0)))))

(defun harness-insights--tasks (tasks since until project merges)
  "Return the figures of TASKS for the period SINCE to UNTIL in PROJECT.
MERGES maps a session id to its merge counts from the transcripts:
the merge queue clears a task's conflicts when it merges, so its
session's hints are what remembers them."
  (let* ((tasks (if project
                    (cl-remove-if-not (lambda (task) (equal (harness-insights--root (plist-get task :project)) project))
                                      tasks)
                  tasks))
         (in (lambda (ts) (harness-insights--in-p ts since until)))
         (submitted 0) (completed 0) (merged 0) (first-try 0) (sent-back 0) (rounds 0)
         (failed 0) (cancelled 0) (duplicates 0) (conflicted 0) (durations nil)
         (columns (make-hash-table :test 'equal)) (notable nil))
    (dolist (task tasks)
      (let* ((state (format "%s" (plist-get task :state)))
             (outcome (and (plist-get task :outcome) (format "%s" (plist-get task :outcome))))
             (feedback (plist-get task :feedback))
             (period-rounds (cl-count-if (lambda (f) (funcall in (plist-get f :at))) feedback))
             (done-at (harness-insights--task-done-at task))
             (begun (or (plist-get task :started) (plist-get task :created)))
             (m (gethash (plist-get task :session) merges))
             (had-conflict (or (and m (> (or (plist-get m :conflicts) 0) 0))
                               (and (plist-get task :conflicts) t)))
             (column (format "%s" (or (plist-get task :column) state)))
             (why nil))
        (unless (or (equal state "done") (harness-json-true-p (plist-get task :archived)))
          (puthash column (1+ (gethash column columns 0)) columns))
        (when (funcall in (plist-get task :created)) (cl-incf submitted))
        (when (> period-rounds 0)
          (cl-incf sent-back)
          (cl-incf rounds period-rounds)
          (setq why 'sent-back))
        (when (and done-at (funcall in done-at))
          (cl-incf completed)
          (unless feedback (cl-incf first-try))
          (when (harness-json-true-p (plist-get task :merged))
            (cl-incf merged)
            (when had-conflict (cl-incf conflicted)))
          (when (numberp begun) (push (max 0 (- done-at begun)) durations))
          (setq why (or why 'done)))
        (when (and (not done-at) (funcall in begun))
          (pcase outcome
            ((or "error" "merge-failed") (cl-incf failed) (setq why 'failed))
            ("cancelled" (cl-incf cancelled))
            ("duplicate" (cl-incf duplicates))))
        (when (and (not why) (equal column "review")) (setq why 'review))
        (when why
          (push (list :id (plist-get task :id) :task task
                      :session (plist-get task :session) :state state :column column :outcome outcome
                      :why (symbol-name why) :feedback (length feedback) :conflict (and had-conflict t)
                      :created (plist-get task :created) :done-at done-at)
                notable))))
    (let ((order '("failed" "sent-back" "review" "done")))
      (setq notable (sort notable
                          (lambda (a b)
                            (let ((ia (cl-position (plist-get a :why) order :test #'equal))
                                  (ib (cl-position (plist-get b :why) order :test #'equal)))
                              (or (< ia ib)
                                  (and (= ia ib)
                                       (> (or (plist-get a :done-at) (plist-get a :created) 0)
                                          (or (plist-get b :done-at) (plist-get b :created) 0)))))))))
    (list :submitted submitted :completed completed :merged merged
          :first-try first-try :sent-back sent-back :feedback-rounds rounds
          :failed failed :cancelled cancelled :duplicates duplicates
          :conflicted conflicted
          :mean-time (and durations (/ (apply #'+ durations) (float (length durations))))
          :median-time (harness-insights--median durations)
          :open (let (out)
                  (maphash (lambda (k v) (push (list :column k :count v) out)) columns)
                  (sort out (lambda (a b) (> (plist-get a :count) (plist-get b :count)))))
          :notable (mapcar (lambda (n)
                             (append (list :title (harness-insights--task-title (plist-get n :task)))
                                     (harness-plist-remove n :task)))
                           (seq-take notable 10)))))

;;;; The report

(defun harness-insights--key (period since project)
  "Return the key of the report of PERIOD (or SINCE) in PROJECT."
  (format "%s|%s"
          (cond (period (format "%s" period))
                (since (format-time-string "%Y-%m-%dT%H:%M" since))
                (t "all"))
          (or project "*")))

(defun harness-insights--remember (key report)
  "Keep REPORT, of KEY, at hand for writing its summary."
  (setq harness-insights--memo
        (seq-take (cons (cons key (cons (float-time) report))
                        (cl-remove key harness-insights--memo :key #'car :test #'equal))
                  6)))

(defun harness-insights--recent (key)
  "Return the report of KEY computed in the last few minutes, or nil."
  (let ((entry (assoc key harness-insights--memo)))
    (and entry (< (- (float-time) (cadr entry)) harness-insights--memo-age)
         (cddr entry))))

(defun harness-insights--empty-scan (message)
  "Return the transcripts' figures when they could not be read, saying MESSAGE."
  (list :sessions (list :active 0 :turns 0 :messages 0 :active-seconds 0 :by-kind nil)
        :tool-totals (list :calls 0 :errors 0 :denied 0 :interrupted 0)
        :permissions (list :decisions 0)
        :activity (list :hours (make-list 24 0) :weekdays (make-list 7 0) :active-days 0
                        :longest-streak 0 :current-streak 0)
        :scan-error message))

(defun harness-insights--merge-table (merges)
  "Return MERGES, the transcripts' merge counts, as a table by session."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (m merges table)
      (puthash (plist-get m :session) m table))))

(harness-defmethod insights/compute (&rest opts)
  "Return a promise of the Insights report for OPTS.
OPTS: `:since' and `:until' (floats; nil: from the start, until now),
`:project' (a main checkout; nil: every project) and `:period' (a
name for the period, such as `7d', which keys the written summary).
The report is a plist:

  :since :until :project :period :generated  what it covers, and when
  :usage        `:totals', `:by-model', `:by-provider', `:projects',
                `:series' and `:bucket' (see `harness-insights--usage')
  :sessions     (:active N :turns N :messages N :active-seconds F
                :by-kind ((:kind K :sessions N :turns N :messages N
                :active F) ...)), kinds main, task, fork, subagent, btw
  :session-list the sessions that worked, newest first, at most
                `harness-insights--narrative-sessions': (:id :name
                :kind :main :model :prompt :turns :messages :tools
                :errors :denied :active :first :last :task)
  :busiest-sessions  the same, the most active first, at most
                `harness-insights--session-rows'
  :tools        ((:tool NAME :calls :errors :denied :interrupted
                :seconds :unanswered) ...), most called first
  :tool-totals  (:calls :errors :denied :interrupted)
  :permissions  (:decisions :allowed :denied :asked :asked-allowed
                :asked-denied :first :tools), from the decision log
  :activity     (:hours (24 counts) :weekdays (7, Monday first)
                :active-days :longest-streak :longest-streak-end
                :current-streak :busiest-day (:day :messages)), of the
                messages the user wrote
  :projects     ((:main ROOT :sessions :turns :messages :active) ...)
  :tasks        see `harness-insights--tasks'
  :narrative    the written summary kept for this period and scope, or
                nil; `:stale' when older than
                `harness-insights-narrative-max-age'
  :narrative-mode  `harness-insights-narrative'
  :scan         what reading the transcripts took; `:scan-error' says
                why they could not be read, the rest of the report
                standing

A report asked for again while it is computed shares its promise."
  (let* ((now (float-time))
         (since (plist-get opts :since))
         (until (or (plist-get opts :until) now))
         (project (harness-insights--scope (plist-get opts :project)))
         (period (plist-get opts :period))
         (key (harness-insights--key period since project)))
    (or (gethash key harness-insights--running)
        (let* ((tasks (harness-insights--all-tasks project))
               (bucket (if (equal (format "%s" period) "today") 'hour 'day))
               (scan (harness-insights--run-scan (harness-insights--scan-input since until project tasks)))
               ;; The usage queries run while the child reads.
               (usage (condition-case err
                          (harness-insights--usage since (plist-get opts :until) project bucket)
                        (error
                         (harness-log 'warn "insights: reading usage failed: %s" (harness-error-message err))
                         (list :totals (harness-insights--zero-totals) :bucket bucket
                               :error (harness-error-message err)))))
               (promise
                (harness-then
                 (harness-catch scan (lambda (err) (harness-insights--empty-scan (harness-error-message err))))
                 (lambda (figures)
                   (remhash key harness-insights--running)
                   (let* ((rows (plist-get figures :session-list))
                          (report
                           (append
                            (list :since since :until until :project project :period period :generated (float-time)
                                  :usage usage
                                  :tasks (harness-insights--tasks tasks since until project
                                                                  (harness-insights--merge-table (plist-get figures :merges)))
                                  :session-list (seq-take rows harness-insights--narrative-sessions)
                                  :busiest-sessions
                                  (seq-take (sort (copy-sequence rows)
                                                  (lambda (a b) (> (or (plist-get a :active) 0)
                                                                   (or (plist-get b :active) 0))))
                                            harness-insights--session-rows)
                                  :narrative (harness-insights--cached key)
                                  :narrative-mode harness-insights-narrative)
                            (harness-plist-remove figures :merges :session-list))))
                     (harness-insights--remember key report)
                     report))
                 (lambda (err)
                   (remhash key harness-insights--running)
                   (harness-rejected err)))))
          (puthash key promise harness-insights--running)
          promise))))

(harness-defmethod insights/projects ()
  "Return the main checkouts an Insights report can be narrowed to, sorted.
They are the projects of the sessions and of the tasks, each as the
main checkout it belongs to."
  (let ((mains (make-hash-table :test 'equal))
        (memo (make-hash-table :test 'equal)))
    (when (harness-method-exists-p 'session/list)
      (dolist (s (harness-call 'session/list))
        (let ((main (harness-insights--main (plist-get s :project) memo)))
          (unless (string-empty-p main) (puthash main t mains)))))
    (dolist (task (harness-insights--all-tasks))
      (when-let* ((root (harness-insights--root (plist-get task :project))))
        (puthash root t mains)))
    (sort (hash-table-keys mains) #'string<)))

;;;; The written summary

(defconst harness-insights--system-prompt
  "You write the Insights report of an agent harness: a short, honest reading of how one person has been working with AI coding agents over a period, from the figures and the list of their sessions below.  The figures are exact; do not restate them, interpret them.  Write to the person (\"you\"), plainly and specifically, without flattery or filler, naming projects, tools and tasks where they matter.

Answer with one JSON object and nothing else, no markdown fences:
{\"summary\": \"two or three sentences on what the period was about and how it went\",
 \"themes\": [\"what the work was about: 2 to 5 items naming projects, features or kinds of work\"],
 \"patterns\": [\"how you work with the agents: 2 to 4 items, such as when you work, chats against tasks, how much you steer\"],
 \"friction\": [\"what went wrong or slowed you down: 0 to 4 items grounded in the figures, such as failing tools, denials, tasks sent back, merge conflicts\"],
 \"suggestions\": [\"concrete things to try next: 2 to 4 items, each one something you can do in the harness or in the projects\"]}
Each item is one sentence of at most 30 words."
  "System prompt of the call that writes an Insights summary.")

(defun harness-insights--model (project)
  "Return the model that writes the summary for PROJECT, or nil.
See `harness-insights-model'; the base model is `harness-model' as
configured for PROJECT."
  (let* ((base (or (and project (harness-method-exists-p 'config/get)
                        (ignore-errors (harness-call 'config/get 'harness-model project)))
                   (and (boundp 'harness-model) harness-model)))
         (choice harness-insights-model))
    (cond ((or (eq choice 'auto) (equal choice "auto"))
           (or (and base (harness-method-exists-p 'provider/tier-model)
                    (ignore-errors (harness-call 'provider/tier-model base 'cheap)))
               base))
          ((and (stringp choice) (not (string-empty-p choice))) choice)
          (t base))))

(defun harness-insights--directory ()
  "The directory the summary's model calls run in: one of their own."
  (harness-ensure-directory (expand-file-name "insights/" harness-state-directory)))

(defun harness-insights--record-usage (model project event)
  "Record the usage EVENT of the summary's call of MODEL under PROJECT."
  (when (harness-method-exists-p 'usage/record)
    (condition-case err
        (let* ((cost (plist-get event :cost))
               (cost (if (numberp cost) cost
                       (or (and (harness-method-exists-p 'usage/price)
                                (ignore-errors (harness-call 'usage/price model event)))
                           0)))
               (list-cost (plist-get event :list-cost))
               (billing (harness-billing-of event)))
          (when (cl-some (lambda (k) (numberp (plist-get event k))) '(:input :output :cache-read :cache-write))
            (harness-call 'usage/record
                          (list :session nil :project project :model model
                                :input (plist-get event :input) :output (plist-get event :output)
                                :cache-read (plist-get event :cache-read)
                                :cache-write (plist-get event :cache-write)
                                :cost cost
                                :list-cost (cond ((numberp list-cost) list-cost)
                                                 ((eq billing 'subscription)
                                                  (or (ignore-errors (harness-call 'usage/price model event)) cost))
                                                 (t cost))
                                :billing billing))))
      (error (harness-log 'warn "insights: recording usage failed: %S" err)))))

(defun harness-insights--ask (model text project)
  "Ask MODEL to write the summary of TEXT; return a promise of its reply.
A one-off call (`:ephemeral'), without thinking or tools, under a
session id of its own closed when it ends; its cost is recorded under
PROJECT.  It fails after `harness-insights--narrative-timeout' seconds
and when the provider ends it with an error."
  (let* ((sid (format "insights-%s" (harness-short-id 10)))
         (promise
          (harness-with-promise (resolve reject)
            (let* ((reply "") (settled nil) (timer nil) (handle nil)
                   (finish (lambda (ok value)
                             (unless settled
                               (setq settled t)
                               (when timer (cancel-timer timer))
                               (funcall (if ok resolve reject) value)))))
              (setq timer (run-at-time harness-insights--narrative-timeout nil
                                       (lambda ()
                                         (funcall finish nil (list 'error "the model took too long"))
                                         (when handle (ignore-errors (funcall (plist-get handle :cancel)))))))
              (setq handle
                    (harness-call
                     'provider/complete
                     (list :model model
                           :session (list :id sid :cwd (file-name-as-directory (harness-insights--directory)))
                           :ephemeral t
                           :system harness-insights--system-prompt
                           :messages (list (list :role 'user :content (list (list :type "text" :text text))))
                           :tools nil
                           :no-thinking t
                           :max-tokens harness-insights--narrative-max-tokens
                           :on-event
                           (lambda (ev)
                             (pcase (plist-get ev :type)
                               ('text (setq reply (concat reply (or (plist-get ev :delta) ""))))
                               ('usage (harness-insights--record-usage model project ev))
                               ('done
                                (let ((reason (plist-get ev :stop-reason)))
                                  (if (memq reason '(error cancelled))
                                      (funcall finish nil (list 'error (format "the model failed: %s"
                                                                               (or (plist-get ev :error) reason))))
                                    (funcall finish t reply))))))))))))
         (close (lambda () (ignore-errors (harness-call 'provider/close model sid)))))
    (harness-then promise
                  (lambda (reply) (funcall close) reply)
                  (lambda (err) (funcall close) (harness-rejected err)))))

(defun harness-insights--json (text)
  "Return the JSON object TEXT holds, as a plist, or nil."
  (when (stringp text)
    (let ((start (string-search "{" text))
          (end (cl-position ?} text :from-end t)))
      (when (and start end (< start end))
        (let ((obj (ignore-errors (harness-json-parse (substring text start (1+ end))))))
          (and (keywordp (car-safe obj)) obj))))))

(defun harness-insights--items (value)
  "Return VALUE, a model's list of items, as a list of one-line strings."
  (delq nil
        (mapcar (lambda (item)
                  (let ((s (cond ((stringp item) item)
                                 ((and (consp item) (keywordp (car item)))
                                  (mapconcat #'identity
                                             (cl-loop for (_k v) on item by #'cddr
                                                      when (stringp v) collect v)
                                             ": "))
                                 (t nil))))
                    (and s (not (string-blank-p s)) (string-trim s))))
                (if (listp value) value (list value)))))

(defun harness-insights--parse-narrative (reply)
  "Return the summary REPLY holds, or nil when it holds nothing.
The summary is (:summary :themes :patterns :friction :suggestions); a
reply that is not the JSON asked for becomes the summary as it is."
  (let ((obj (harness-insights--json reply)))
    (if (and obj (cl-some (lambda (k) (plist-get obj k)) '(:summary :themes :friction :suggestions)))
        (list :summary (let ((s (plist-get obj :summary))) (and (stringp s) (string-trim s)))
              :themes (harness-insights--items (plist-get obj :themes))
              :patterns (harness-insights--items (plist-get obj :patterns))
              :friction (harness-insights--items (plist-get obj :friction))
              :suggestions (harness-insights--items (plist-get obj :suggestions)))
      (let ((plain (string-trim (or reply ""))))
        (unless (string-empty-p plain) (list :summary plain))))))

(defun harness-insights--narratives ()
  "Return the kept summaries, newest first."
  (and (harness-method-exists-p 'store/load)
       (plist-get (ignore-errors (harness-call 'store/load harness-insights--narratives-name)) :entries)))

(defun harness-insights--cached (key)
  "Return the summary kept for report KEY, or nil; `:stale' when it is old."
  (when-let* ((entry (cl-find key (harness-insights--narratives)
                              :key (lambda (e) (plist-get e :key)) :test #'equal)))
    (if (> (- (float-time) (or (plist-get entry :at) 0)) harness-insights-narrative-max-age)
        (append entry (list :stale t))
      entry)))

(defun harness-insights--keep (entry)
  "Keep the summary ENTRY, replacing the one of its key."
  (let ((others (cl-remove (plist-get entry :key) (harness-insights--narratives)
                           :key (lambda (e) (plist-get e :key)) :test #'equal)))
    (harness-call 'store/save harness-insights--narratives-name
                  (list :entries (seq-take (cons entry others) harness-insights--narratives-kept)))))

(defun harness-insights--count (n singular &optional plural)
  "Return N with SINGULAR or PLURAL (default SINGULAR plus s)."
  (format "%s %s" n (if (eql n 1) singular (or plural (concat singular "s")))))

(defun harness-insights--percent (part whole)
  "Return PART of WHOLE as a rounded percentage string."
  (if (and (numberp whole) (> whole 0))
      (format "%d%%" (round (* 100.0 (/ (float (or part 0)) whole))))
    "0%"))

(defun harness-insights--period-text (report)
  "Describe the period of REPORT in words."
  (let ((since (plist-get report :since))
        (until (plist-get report :until)))
    (if since
        (format "from %s to %s (%d days)"
                (format-time-string "%Y-%m-%d" since) (format-time-string "%Y-%m-%d" until)
                (1+ (- (time-to-days until) (time-to-days since))))
      (format "everything recorded until %s" (format-time-string "%Y-%m-%d" until)))))

(defun harness-insights--busiest (counts labels n)
  "Return the labels of the N largest COUNTS, by LABELS, busiest first."
  (let ((pairs (cl-loop for c in counts for l in labels when (> c 0) collect (cons c l))))
    (mapcar #'cdr (seq-take (sort pairs (lambda (a b) (> (car a) (car b)))) n))))

(defconst harness-insights--weekdays '("Monday" "Tuesday" "Wednesday" "Thursday" "Friday" "Saturday" "Sunday")
  "Weekday names, in the order of the report's weekday counts.")

(defun harness-insights--digest (report)
  "Return the figures of REPORT as the text the summary's model reads."
  (let* ((usage (plist-get report :usage))
         (totals (plist-get usage :totals))
         (sessions (plist-get report :sessions))
         (tools (plist-get report :tool-totals))
         (perms (plist-get report :permissions))
         (tasks (plist-get report :tasks))
         (activity (plist-get report :activity))
         (project (plist-get report :project))
         (lines nil))
    (cl-flet ((add (fmt &rest args) (push (apply #'format fmt args) lines)))
      (add "Period: %s; %s." (harness-insights--period-text report)
           (if project (format "project %s" (abbreviate-file-name project)) "all projects"))
      (add "Sessions: %d worked in the period (%s); %d turns; %d messages written by you; about %s active."
           (or (plist-get sessions :active) 0)
           (mapconcat (lambda (k) (format "%s %s" (plist-get k :sessions) (plist-get k :kind)))
                      (plist-get sessions :by-kind) ", ")
           (or (plist-get sessions :turns) 0) (or (plist-get sessions :messages) 0)
           (harness-format-duration (or (plist-get sessions :active-seconds) 0)))
      (add "Usage: %s billed%s; %d model calls; %s input and %s output tokens."
           (harness-format-cost (plist-get totals :cost))
           (let ((covered (harness-usage-covered totals)))
             (if (> covered 0) (format ", plus %s at API prices covered by a subscription" (harness-format-cost covered)) ""))
           (or (plist-get totals :calls) 0)
           (harness-format-tokens (plist-get totals :input)) (harness-format-tokens (plist-get totals :output)))
      (when-let* ((models (seq-take (plist-get usage :by-model) 5)))
        (let ((all (apply #'+ (mapcar #'harness-usage-list-cost (plist-get usage :by-model)))))
          (add "Models: %s." (mapconcat (lambda (r) (format "%s %s of usage, %d calls" (plist-get r :key)
                                                            (harness-insights--percent (harness-usage-list-cost r) all)
                                                            (or (plist-get r :calls) 0)))
                                        models "; "))))
      (when-let* ((projects (seq-take (plist-get report :projects) 6)))
        (add "Projects: %s." (mapconcat (lambda (p) (format "%s (%s, %s active)"
                                                            (abbreviate-file-name (plist-get p :main))
                                                            (harness-insights--count (plist-get p :sessions) "session")
                                                            (harness-format-duration (or (plist-get p :active) 0))))
                                        projects "; ")))
      (let ((calls (or (plist-get tools :calls) 0)))
        (when (> calls 0)
          (add "Tools: %d calls, %s failed, %s denied. Most used: %s."
               calls (harness-insights--percent (plist-get tools :errors) calls)
               (harness-insights--percent (plist-get tools :denied) calls)
               (mapconcat (lambda (tl) (format "%s %d (%s failed)" (plist-get tl :tool) (plist-get tl :calls)
                                               (harness-insights--percent (plist-get tl :errors) (plist-get tl :calls))))
                          (seq-take (plist-get report :tools) 8) ", "))
          (when-let* ((failing (seq-take (sort (cl-remove-if-not (lambda (tl) (> (plist-get tl :errors) 0))
                                                                 (copy-sequence (plist-get report :tools)))
                                               (lambda (a b) (> (plist-get a :errors) (plist-get b :errors))))
                                         4)))
            (add "Most failing: %s." (mapconcat (lambda (tl) (format "%s %d of %d" (plist-get tl :tool)
                                                                     (plist-get tl :errors) (plist-get tl :calls)))
                                                failing ", ")))))
      (when (> (or (plist-get perms :decisions) 0) 0)
        (add "Permissions: %d decisions; you were asked %d times and allowed %d; %d calls were denied without asking."
             (plist-get perms :decisions) (plist-get perms :asked) (plist-get perms :asked-allowed)
             (- (plist-get perms :denied) (plist-get perms :asked-denied))))
      (when (and tasks (cl-some (lambda (k) (> (or (plist-get tasks k) 0) 0))
                                '(:submitted :completed :sent-back :failed)))
        (add "Tasks: %d submitted, %d completed (%d merged), %d sent back for %d rounds of feedback, %d stopped with an error; %s of completed tasks accepted the first time; %d of %d merges met a conflict."
             (plist-get tasks :submitted) (plist-get tasks :completed) (plist-get tasks :merged)
             (plist-get tasks :sent-back) (plist-get tasks :feedback-rounds) (plist-get tasks :failed)
             (harness-insights--percent (plist-get tasks :first-try) (plist-get tasks :completed))
             (plist-get tasks :conflicted) (plist-get tasks :merged)))
      (when (> (or (plist-get sessions :messages) 0) 0)
        (add "Activity: busiest hours %s; busiest days %s; active on %d days; longest streak %d days; current streak %d days."
             (mapconcat (lambda (h) (format "%02d:00" h))
                        (harness-insights--busiest (plist-get activity :hours) (number-sequence 0 23) 3) ", ")
             (string-join (harness-insights--busiest (plist-get activity :weekdays) harness-insights--weekdays 2) ", ")
             (or (plist-get activity :active-days) 0) (or (plist-get activity :longest-streak) 0)
             (or (plist-get activity :current-streak) 0)))
      (when-let* ((rows (seq-take (plist-get report :session-list) harness-insights--narrative-sessions)))
        (add "\nSessions, newest first (kind, name: first request):")
        (dolist (r rows)
          (add "- %s, %s: %s" (plist-get r :kind)
               (or (plist-get r :name) "unnamed")
               (or (plist-get r :prompt) "")))))
    (string-join (nreverse lines) "\n")))

(defun harness-insights--quiet-p (report)
  "Non-nil when nothing happened in REPORT's period."
  (and (zerop (or (plist-get (plist-get report :sessions) :active) 0))
       (zerop (or (plist-get (plist-get (plist-get report :usage) :totals) :calls) 0))))

(defun harness-insights--write (key report)
  "Return a promise of the summary of REPORT, kept under KEY.
It resolves with the kept entry, or with (:skipped MESSAGE :error t)
when the model could not write it."
  (let* ((project (plist-get report :project))
         (model (harness-insights--model project)))
    (cond
     ((harness-insights--quiet-p report)
      (harness-resolved (list :skipped "Nothing happened in this period to write about.")))
     ((null model)
      (harness-resolved (list :skipped "No model is set to write the summary." :error t)))
     ((not (harness-method-exists-p 'provider/complete))
      (harness-resolved (list :skipped "No provider is loaded to write the summary." :error t)))
     (t
      (harness-then
       (harness-insights--ask model (harness-insights--digest report) project)
       (lambda (reply)
         (let ((parsed (harness-insights--parse-narrative reply)))
           (if (null parsed)
               (signal 'harness-error (list "the model wrote nothing"))
             (let ((entry (append (list :key key :at (float-time) :model model
                                        :period (plist-get report :period) :project project)
                                  parsed)))
               (remhash key harness-insights--failed)
               (harness-insights--keep entry)
               entry)))))))))

(harness-defmethod insights/narrative (&rest opts)
  "Return a promise of the written summary of the report OPTS select.
OPTS are those of `insights/compute', and `:refresh' to write a new
summary even when a recent one is kept.  The promise resolves with the
summary: (:key :at :model :period :project :summary :themes :patterns
:friction :suggestions), `:stale' when it is old and kept; or with
\(:skipped MESSAGE) when none is written: summaries are off, nothing
happened, or the model could not be reached (then also `:error' t; it
is not tried again for a while unless `:refresh')."
  (let* ((since (plist-get opts :since))
         (project (harness-insights--scope (plist-get opts :project)))
         (period (plist-get opts :period))
         (refresh (harness-json-true-p (plist-get opts :refresh)))
         (key (harness-insights--key period since project))
         (kept (harness-insights--cached key))
         (failed (gethash key harness-insights--failed)))
    (cond
     ((null harness-insights-narrative)
      (harness-resolved (list :skipped "Written summaries are off (harness-insights-narrative).")))
     ((and kept (not refresh) (not (plist-get kept :stale))) (harness-resolved kept))
     ((gethash key harness-insights--narrating))
     ((and failed (not refresh)
           (< (- (float-time) (car failed)) harness-insights--narrative-retry))
      (harness-resolved (list :skipped (cdr failed) :error t)))
     (t
      (let ((promise
             (harness-then
              (harness-then
               (if-let* ((report (harness-insights--recent key)))
                   (harness-resolved report)
                 (apply #'harness-call 'insights/compute opts))
               (lambda (report) (harness-insights--write key report)))
              (lambda (entry)
                (remhash key harness-insights--narrating)
                entry)
              (lambda (err)
                (remhash key harness-insights--narrating)
                (let ((message (format "The summary could not be written: %s" (harness-error-message err))))
                  (puthash key (cons (float-time) message) harness-insights--failed)
                  (harness-log 'warn "insights: %s" message)
                  (list :skipped message :error t))))))
        (puthash key promise harness-insights--narrating)
        promise)))))

;;;; The decision log

(defun harness-insights--permissions-name (ts)
  "Return the store name of the decision log of TS's month."
  (format "insights/permissions-%s.jsonl" (format-time-string "%Y-%m" ts)))

(defun harness-insights--ask-key (sid call-id)
  "Return the key of tool call CALL-ID of session SID."
  (format "%s %s" sid call-id))

(defun harness-insights--on-requested (sid pending)
  "Note that the user of session SID is asked about the call of PENDING.
`permission/requested' handler."
  (when-let* ((call-id (plist-get (plist-get pending :payload) :call-id)))
    (when (> (hash-table-count harness-insights--asked) 1000)
      (let ((old (- (float-time) 86400)))
        (maphash (lambda (k v) (when (< v old) (remhash k harness-insights--asked)))
                 harness-insights--asked)))
    (puthash (harness-insights--ask-key sid call-id) (float-time) harness-insights--asked)))

(defun harness-insights--on-decided (sid request decision)
  "Log DECISION on REQUEST, a tool call of session SID.
`permission/decided' handler; see `harness-insights-record-permissions'."
  (let* ((call-id (plist-get request :call-id))
         (key (and call-id (harness-insights--ask-key sid call-id)))
         (asked (and key (gethash key harness-insights--asked))))
    (when key (remhash key harness-insights--asked))
    (when harness-insights-record-permissions
      (let ((now (float-time)))
        (condition-case err
            (harness-call 'store/append (harness-insights--permissions-name now)
                          (list :ts now :session sid :tool (format "%s" (plist-get request :tool))
                                :behavior (format "%s" (plist-get decision :behavior))
                                :asked (if asked t :false)))
          (error (harness-log 'warn "insights: logging a permission decision failed: %s"
                              (harness-error-message err))))))))

(defun harness-insights--prune-permissions ()
  "Delete the decision logs older than `harness-insights--permission-months'."
  (let ((dir (expand-file-name "insights/" harness-state-directory))
        (oldest (format-time-string "%Y-%m" (- (float-time) (* harness-insights--permission-months 31 86400)))))
    (when (file-directory-p dir)
      (dolist (f (directory-files dir t harness-insights--permission-file-re))
        (let ((name (file-name-nondirectory f)))
          (when (and (string-match harness-insights--permission-file-re name)
                     (string< (match-string 1 name) oldest))
            (ignore-errors (delete-file f))))))))

;;;; Init and reload

(defun harness-insights--init ()
  "Log permission decisions, and forget old ones."
  (harness-on 'permission/requested #'harness-insights--on-requested)
  (harness-on 'permission/decided #'harness-insights--on-decided)
  (ignore-errors (harness-insights--prune-permissions)))

;; A reload does not initialise a running module again: subscribe now.
(when (harness-module-ready-p 'insights)
  (harness-insights--init))

(harness-define-module 'insights
		       :doc "The Insights report: figures and a written summary of the work, for any provider."
		       :requires '(store)
		       :init #'harness-insights--init)

(provide 'harness-insights)
;;; harness-insights.el ends here
