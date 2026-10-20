;;; harness-patch-review.el --- The threads of a task's review: kept, delivered, answered  -*- lexical-binding: t; -*-

;;; Commentary:

;; The harness's half of reviewing a task's changes with threads.  The
;; library change-review (lisp/vendor/change-review) knows the data of a
;; review -- change sets with versions, threads of comments, and the
;; operations that change them -- and nothing of the harness; this module
;; is the adapter that gives it a task to review and a place to keep its
;; threads.  Its UI half is `ui-patch-review', which draws them.
;;
;; A task is a CHANGE SET.  Each time its agent hands the work in -- the
;; task comes to review -- the branch's tip is a VERSION of it: the
;; first hand-in, the second after the review sent it back.  The
;; version is named by the tip commit, the source revision every comment
;; made against it records; it comes with the commit the branch was made
;; from, the report's summary as its description, and, as its author,
;; the agent, with the session and the `hand_in' call that handed it in.
;;
;; The module is the single writer of a task's threads, so the user's
;; Emacs and the agent's tools never disagree: the UI sends the
;; operations the user makes (`patch-review/apply'), the tools send the
;; agent's (`review_comment'), the module performs them on the set it
;; keeps in the state directory, one document a task
;; (patch-review/TASK.json), and announces each in `patch-review/changed'
;; for every UI to perform on its own copy.  An operation names what it
;; adds by id, so performing one twice is harmless.
;;
;; THE AUTHORS.  The user writes as themselves, by name and address.  An
;; agent's comment records the agent, the session and the tool call that
;; made it (`review_comment'), the link back to that point of the
;; conversation.
;;
;; THE DRAFTS.  What the user writes in the review is a draft until the
;; task is sent back.  Whatever sends it back -- the report's box, a
;; message typed in its session, another client -- gets the drafts with
;; it: `harness-tasks-feedback-additions-functions' asks this module for
;; the text, which quotes the diff above each comment as a reply on a
;; mailing list does and names each comment's thread, and the drafts are
;; marked sent once the task is.  The agent answers a thread with
;; `review_comment', closing it when its point is done; the user closes
;; it in turn, once they agree.
;;
;; THE EARLIER ROUNDS.  A task sent back before there were threads kept
;; its feedback as text.  The first time a task's set is made, the
;; comments quoted in those rounds become closed threads of the set, with
;; ids that follow from where they were, so that they are made once.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'harness-core)
(require 'harness-util)

;; change-review is in lisp/vendor/change-review, which the harness puts
;; on `load-path' (`harness--setup-load-path').  A harness older than
;; that directory, reloading after an update, first checks that this
;; file compiles with the `load-path' it has, before it loads the
;; harness.el that adds the directory.  So when the library is not found,
;; look for it beside the file being compiled or loaded.
(defvar byte-compile-current-file)
(eval-and-compile
  (unless (or (featurep 'change-review) (locate-library "change-review"))
    (when-let* ((file (or (and (boundp 'byte-compile-current-file)
                               (stringp byte-compile-current-file)
                               byte-compile-current-file)
                          load-file-name
                          buffer-file-name))
                (dir (expand-file-name "../vendor/change-review/" (file-name-directory file)))
                ((file-directory-p dir)))
      (add-to-list 'load-path dir))))
(require 'change-review)
(require 'change-review-mail)

(defvar harness-tasks-feedback-additions-functions)

;;;; The set of a task

(cl-defstruct (harness-patch-review--set
               (:include change-review-set)
               (:constructor harness-patch-review--make-set
                             (&key id title description versions threads meta))
               (:copier nil))
  "The threads of one task's review, kept in the state directory.")

(defvar harness-patch-review--sets (make-hash-table :test 'equal)
  "Task id -> the `harness-patch-review--set' of its review, once read.")

(defun harness-patch-review--store-name (id)
  "Return the name of the document that keeps the set of task ID."
  (format "patch-review/%s.json" (replace-regexp-in-string "[^A-Za-z0-9._-]" "_" id)))

(defun harness-patch-review--save (set)
  "Write SET to the store."
  (when (harness-method-exists-p 'store/save)
    (condition-case err
        (harness-call 'store/save (harness-patch-review--store-name (change-review-set-id set))
                      (change-review-set-to-data set nil))
      (error (harness-log 'warn "patch-review: saving the threads of %s failed: %s"
                          (change-review-set-id set) (harness-error-message err))))))

(cl-defmethod change-review-save ((set harness-patch-review--set))
  (harness-patch-review--save set))

(cl-defmethod change-review-current-author ((_set harness-patch-review--set))
  (harness-patch-review--user))

(defun harness-patch-review--user ()
  "Return the user, as the author of what the user writes."
  (change-review-user (if (and (stringp user-full-name) (not (string-empty-p user-full-name)))
                          user-full-name
                        (user-login-name))
                      (and (stringp user-mail-address) (not (string-empty-p user-mail-address))
                           user-mail-address)))

(defun harness-patch-review--model-name (model)
  "Return how to call the agent that runs MODEL, such as \"claude:sonnet\"."
  (cond ((not (and (stringp model) (not (string-empty-p model)))) "Agent")
        ((string-match "\\`\\([^:]+\\):\\(.+\\)\\'" model)
         (format "%s (%s)" (capitalize (match-string 1 model)) (match-string 2 model)))
        (t model)))

(defun harness-patch-review--agent (session-id &optional call-id)
  "Return the agent of SESSION-ID as an author.
CALL-ID is the tool call that made the comment, if any."
  (let ((session (and (stringp session-id) (harness-method-exists-p 'session/get)
                      (ignore-errors (harness-call 'session/get session-id)))))
    (change-review-agent (harness-patch-review--model-name (plist-get session :model))
                         :session session-id :tool-call call-id)))

(defun harness-patch-review--task (id)
  "Return the task ID, or signal an error when there is none."
  (or (and (harness-method-exists-p 'task/get) (harness-call 'task/get id))
      (signal 'harness-error (list (format "No task %s" id)))))

(defun harness-patch-review--task-title (task)
  "Return what to call TASK."
  (or (let ((name (plist-get task :name))) (and (stringp name) (not (string-blank-p name)) name))
      (harness-first-line (or (plist-get task :prompt) "task") 72)))

;;;; The earlier rounds

(defun harness-patch-review--import-rounds (set task)
  "Make the comments quoted in TASK's rounds of feedback closed threads of SET.
The rounds were kept as text before threads existed.  Each comment the
reply format finds in one is a thread of its own, written by the user at
the time the round was sent, closed, against the commit the round names
when it does.  The ids follow from the task, the round and the place of
the comment in it, so a round imported twice adds nothing."
  (let ((id (change-review-set-id set))
        (author (harness-patch-review--user)))
    (cl-loop
     for round in (plist-get task :feedback)
     for index from 0
     for text = (let ((text (plist-get round :text))) (if (stringp text) text ""))
     for at = (plist-get round :at)
     for tip = (change-review-mail-parse-tip text)
     do (cl-loop
         for block in (change-review-mail-parse-reply text :split t)
         for k from 0
         for thread = (change-review-stable-id "t" id index k)
         for path = (plist-get block :path)
         do (change-review-apply
             set (list :op 'add-comment :thread thread
                       :comment (change-review-comment-to-data
                                 (change-review-make-comment
                                  :id (change-review-stable-id "c" id index k)
                                  :thread thread :author author
                                  :body (plist-get block :body)
                                  :time at :sent at :revision tip
                                  :location (and path
                                                 (change-review-make-location
                                                  :file path :old-file (plist-get block :old-path)
                                                  :side (or (plist-get block :side) 'new)
                                                  :line (plist-get block :line)
                                                  :end-line (plist-get block :end-line)
                                                  :excerpt (plist-get block :excerpt)))
                                  :meta (list :round index :imported t))))
             t)
         (change-review-apply
          set (list :op 'set-status :thread thread :status "closed"
                    :id (change-review-stable-id "s" id index k) :time at
                    :author (change-review-author-to-data author) :revision tip)
          t)))))

(defun harness-patch-review--set-for (id &optional create)
  "Return the set of task ID, read from the store; with CREATE, made if none.
A set made for a task that was sent back before threads existed starts
with the comments of its rounds of feedback."
  (or (gethash id harness-patch-review--sets)
      (let ((set (or (when-let* ((data (and (harness-method-exists-p 'store/load)
                                            (harness-call 'store/load
                                                          (harness-patch-review--store-name id)))))
                       (change-review-set-from-data data (harness-patch-review--make-set :id id)))
                     (when create
                       (let* ((task (harness-patch-review--task id))
                              (set (harness-patch-review--make-set
                                    :id id :title (harness-patch-review--task-title task))))
                         (harness-patch-review--import-rounds set task)
                         (harness-patch-review--save set)
                         set)))))
        (when set (puthash id set harness-patch-review--sets))
        set)))

;;;; The versions

(defun harness-patch-review--git (dir &rest args)
  "Return a promise of what git, run in DIR with ARGS, writes, trimmed.
It rejects when git fails."
  (harness-then
   (harness-run-command (append '("git" "--no-pager") args) :cwd dir :timeout 60
                        :name "harness-patch-review"
                        :env '(("GIT_OPTIONAL_LOCKS" . "0")))
   (lambda (result)
     (if (eql (plist-get result :exit) 0)
         (string-trim (or (plist-get result :stdout) ""))
       (harness-rejected (list 'error (format "git %s failed: %s" (car args)
                                              (harness-first-line (or (plist-get result :stderr) "") 120))))))))

(defun harness-patch-review--repository (task)
  "Return the directory TASK's branch can be read in, or nil."
  (cl-loop for dir in (list (plist-get task :project) (plist-get task :worktree))
           when (and (stringp dir) (not (string-empty-p dir))
                     (not (file-remote-p dir)) (file-directory-p dir))
           return dir))

(defun harness-patch-review--merge-base (dir base tip)
  "Return a promise of the commit TIP and BASE, a branch, have in common in DIR.
BASE that is blank or no longer there is what DIR has checked out."
  (harness-catch
   (if (and (stringp base) (not (string-empty-p base)))
       (harness-catch (harness-patch-review--git dir "merge-base" base tip)
                      (lambda (_) (harness-patch-review--git dir "merge-base" "HEAD" tip)))
     (harness-patch-review--git dir "merge-base" "HEAD" tip))
   (lambda (_) (harness-resolved nil))))

(defun harness-patch-review--version-op (task tip merge-base)
  "Return the operation that adds the version of TASK that ends at TIP.
MERGE-BASE is the commit its branch was made from, or nil."
  (let* ((report (plist-get task :report))
         (summary (plist-get report :summary))
         (round (length (plist-get task :feedback))))
    (list :op 'add-version
          :version (change-review-version-to-data
                    (change-review-make-version
                     :id tip :tip tip :base merge-base
                     :time (or (plist-get task :report-at) (plist-get report :at) (float-time))
                     :title (harness-patch-review--task-title task)
                     :description (and (stringp summary) (not (string-blank-p summary))
                                       (harness-truncate-end summary 4000))
                     :author (harness-patch-review--agent (plist-get task :session)
                                                          (plist-get report :call-id))
                     :meta (list :round round :branch (plist-get task :branch)
                                 :base-branch (plist-get task :base)))))))

(defun harness-patch-review--record-version (task)
  "Record the version TASK handed in: where its branch ends now.
Read in the task's repository.  Return a promise of the set, or nil
when the task has no branch of its own or its repository is not here."
  (let ((dir (harness-patch-review--repository task))
        (branch (plist-get task :branch)))
    (when (and dir (stringp branch) (not (string-blank-p branch)))
      (harness-catch
       (harness-then
        (harness-patch-review--git dir "rev-parse" "--verify" "--quiet" (concat branch "^{commit}"))
        (lambda (tip)
          (harness-then
           (harness-patch-review--merge-base dir (plist-get task :base) tip)
           (lambda (merge-base)
             (let ((set (harness-patch-review--set-for (plist-get task :id) t)))
               (change-review-dispatch set (harness-patch-review--version-op task tip merge-base))
               set)))))
       (lambda (err)
         (harness-log 'info "patch-review: no version recorded for %s: %s"
                      (plist-get task :id) (harness-error-message err))
         (harness-resolved nil))))))

(defun harness-patch-review--on-review (task)
  "Record the version of TASK, which comes to review: the work handed in."
  (when (and (plist-get task :id) (harness-patch-review--repository task))
    (harness-patch-review--record-version task)))

;;;; Methods

(harness-defmethod patch-review/get (task-id)
  "Return the review of task TASK-ID as plain data: its versions and threads.
The data is that of `change-review-set-to-data', without the versions'
files: the UI reads those from the repository.  The set is made when
the task has none yet, with the comments of the task's earlier rounds
of feedback as closed threads."
  (let ((set (harness-patch-review--set-for task-id t)))
    (change-review-set-to-data set nil)))

(harness-defmethod patch-review/apply (task-id op)
  "Perform OP, an operation of change-review, on the review of task TASK-ID.
The UI sends the operations the user makes: `add-comment', `set-status',
`edit-comment', `delete-comment' and `add-version'.  Return (:changed
BOOL).  `patch-review/changed' announces what changed to every UI, so
that each performs it on its own copy."
  (let ((kind (let ((value (plist-get op :op)))
                (cond ((symbolp value) value)
                      ((stringp value) (intern value))))))
    (unless (memq kind '(add-comment set-status edit-comment delete-comment add-version))
      (signal 'harness-error (list (format "The review does not take %S operations from a UI" kind))))
    (let ((set (harness-patch-review--set-for task-id t)))
      (list :changed (and (change-review-dispatch set op) t)))))

(harness-defmethod patch-review/threads-text (task-id &optional status)
  "Return the threads of task TASK-ID's review as text for its agent.
STATUS is \"open\", \"closed\" or nil for all.  Only the comments sent are
in it: the drafts are the user's until they send the task back."
  (harness-patch-review-threads-text
   (harness-patch-review--set-for task-id t)
   (and (stringp status) (member status '("open" "closed")) (intern status))))

(harness-defmethod patch-review/drafts (task-id)
  "Return the draft comments of task TASK-ID's review, those not sent yet, as data."
  (when-let* ((set (harness-patch-review--set-for task-id)))
    (mapcar #'change-review-comment-to-data (change-review-drafts set))))

(harness-defmethod patch-review/comment (task-id body &rest opts)
  "Add the agent's comment BODY to the review of task TASK-ID.
Return (:thread ID :status STATUS :comment DATA), DATA being the
comment as plain data, or nil when only the status changed.
OPTS: `:thread' answers that thread (an id, or a prefix of one that is
unique), else the comment starts a thread; `:status' closes or opens
the thread afterwards; `:session' and `:call-id' say which session and
tool call wrote it; `:file', `:line' and `:side' say where in the change
a new thread is; `:revision' the commit the agent was at.  With no BODY
`:status' alone changes the thread's status.  Signal an error naming
the threads there are when `:thread' names none."
  (let* ((set (harness-patch-review--set-for task-id t))
         (thread (and (plist-get opts :thread)
                      (or (change-review-find-thread set (plist-get opts :thread))
                          (signal 'harness-error
                                  (list (format "No thread %s in this review; threads: %s"
                                                (plist-get opts :thread)
                                                (mapconcat (lambda (th) (change-review-thread-id th))
                                                           (change-review-set-threads set) ", ")))))))
         (author (harness-patch-review--agent (plist-get opts :session) (plist-get opts :call-id)))
         (status (let ((value (plist-get opts :status)))
                   (and value (intern (format "%s" value)))))
         (time (float-time))
         comment)
    (when (and status (not (memq status '(open closed))))
      (signal 'harness-error (list "A thread's status is open or closed")))
    (when (and (harness-string-blank-p body) (not (and thread status)))
      (signal 'harness-error (list "A comment needs text; to only open or close a thread, name the thread and a status")))
    (unless (harness-string-blank-p body)
      (setq comment
            (change-review-comment
             set (string-trim body)
             :thread thread :author author :time time :sent time
             :revision (or (plist-get opts :revision)
                           (when-let* ((version (change-review-latest-version set)))
                             (change-review-version-id version)))
             :location (and (not thread) (plist-get opts :file)
                            (change-review-make-location
                             :file (plist-get opts :file)
                             :side (if (member (format "%s" (plist-get opts :side)) '("old" "before")) 'old 'new)
                             :line (plist-get opts :line))))))
    (when (and status (or thread comment))
      (change-review-update-status
       set (or thread (change-review-comment-thread comment)) status
       :author author :time (+ time 0.001)))
    (let ((thread (or thread (change-review-find-thread set (change-review-comment-thread comment)))))
      (list :thread (change-review-thread-id thread)
            :status (symbol-name (change-review-thread-status thread))
            :comment (and comment (change-review-comment-to-data comment))))))

;;;; The drafts go with the feedback

(defun harness-patch-review--attribution (task set)
  "Return the line before the first quote of the drafts of TASK's review in SET."
  (let ((version (change-review-latest-version set)))
    (format "My review comments on your branch %s%s%s. Each is quoted from the diff, with my comment under the lines it is about; [thread ...] names the thread it belongs to. Answer a thread with the review_comment tool, giving its id, and close it (status \"closed\") once what it raises is done: a thread left open is not done."
            (or (plist-get task :branch) "")
            (if version (format " (at %s)" (change-review-short-revision (change-review-version-tip version))) "")
            (if (and version (change-review-version-base version))
                (format " against %s (merge base %s)"
                        (or (plist-get task :base) "its base")
                        (change-review-short-revision (change-review-version-base version)))
              ""))))

(defun harness-patch-review--render (task set drafts)
  "Return the text of DRAFTS, comments of TASK's review in SET, as feedback.
It opens with the line that says what the quotes are and how to answer
the threads, also when no comment is on a file and so quotes nothing."
  (let ((attribution (harness-patch-review--attribution task set))
        (text (change-review-mail-render-comments
               set drafts
               :attribution (harness-patch-review--attribution task set)
               :history t
               :markers (lambda (comment) (format "[thread %s]" (change-review-comment-thread comment))))))
    (if (string-search attribution text)
        text
      (concat attribution "\n\n" text))))

(defun harness-patch-review--additions (task words)
  "Return the drafts of TASK's review as text to add to its feedback, or nil.
On `harness-tasks-feedback-additions-functions'.  WORDS are what the user
sends the task back with.  The text is the drafts, if there are any,
quoted from the diff; the function marks them sent once the task is sent
back, and keeps WORDS, if there are any, as a thread on the change as a
whole, sent: the review has a record of what each round said."
  (let* ((id (plist-get task :id))
         (words (and (stringp words) (not (string-blank-p words)) (string-trim words)))
         (set (harness-patch-review--set-for id (and words t)))
         (drafts (and set (change-review-drafts set))))
    (when (or drafts words)
      (let ((round (length (plist-get task :feedback))))
        (cons (and drafts (harness-patch-review--render task set drafts))
              (lambda ()
                (let ((time (float-time)))
                  (when drafts
                    (change-review-mark-sent set drafts :time time :meta (list :round round)))
                  (when words
                    (change-review-comment set words :author (harness-patch-review--user)
                                           :time time :sent time
                                           :meta (list :round round :words t))))))))))

;;;; What the agent reads

(defun harness-patch-review--where (thread)
  "Return where THREAD is, for the agent to read."
  (let ((location (change-review-thread-location thread)))
    (if location (change-review-location-label location t) "the change as a whole")))

(defun harness-patch-review-threads-text (set &optional status)
  "Return the sent comments of SET's threads as text for the agent.
STATUS is `open', `closed' or nil for all.  A comment that is still a
draft is not shown: the user has not sent it."
  (let* ((seen (cl-remove-if-not
                (lambda (thread)
                  (cl-some (lambda (c) (not (change-review-comment-draft-p c)))
                           (change-review-thread-comments thread)))
                (change-review-set-threads set)))
         (threads (if status
                      (cl-remove-if-not (lambda (thread) (eq (change-review-thread-status thread) status)) seen)
                    seen)))
    (if (null threads)
        (format "No %sthreads in this review." (if status (format "%s " status) ""))
      (concat
       (format "%d open, %d closed.\n\n"
               (cl-count-if #'change-review-thread-open-p seen)
               (cl-count-if-not #'change-review-thread-open-p seen))
       (mapconcat
        (lambda (thread)
          (concat
           (format "[%s] %s · %s\n" (change-review-thread-id thread)
                   (if (change-review-thread-open-p thread) "open" "closed")
                   (harness-patch-review--where thread))
           (mapconcat
            (lambda (comment)
              (let ((author (change-review-comment-author comment)))
                (format "  %s %s (%s): %s\n"
                        (change-review-comment-id comment)
                        (change-review-author-label author)
                        (change-review-author-kind author)
                        (string-replace "\n" "\n      " (change-review-comment-body comment)))))
            (cl-remove-if #'change-review-comment-draft-p (change-review-thread-comments thread))
            "")))
        threads "\n")))))

;;;; Events and the module

(harness-declare-event 'patch-review/changed
                       "(TASK-ID OP) after an operation changed the threads of a task's review: OP, to perform on a copy.")

(defun harness-patch-review--changed (set op)
  "Announce operation OP, which changed SET, if SET is a task's review.
On `change-review-changed-functions'."
  (when (harness-patch-review--set-p set)
    (harness-emit 'patch-review/changed (change-review-set-id set) op)))

(defun harness-patch-review--on-deleted (id)
  "Forget the review of task ID, which was deleted."
  (remhash id harness-patch-review--sets))

(defun harness-patch-review--init ()
  "Follow the tasks, and put the drafts in the feedback that sends one back."
  (add-hook 'change-review-changed-functions #'harness-patch-review--changed)
  (harness-on 'task/review #'harness-patch-review--on-review)
  (harness-on 'task/deleted #'harness-patch-review--on-deleted)
  (add-hook 'harness-tasks-feedback-additions-functions #'harness-patch-review--additions))

(defun harness-patch-review--shutdown ()
  "Stop following the tasks."
  (remove-hook 'change-review-changed-functions #'harness-patch-review--changed)
  (remove-hook 'harness-tasks-feedback-additions-functions #'harness-patch-review--additions)
  (harness-off (cons 'task/review #'harness-patch-review--on-review))
  (harness-off (cons 'task/deleted #'harness-patch-review--on-deleted))
  (clrhash harness-patch-review--sets))

(harness-define-module 'patch-review
  :doc "The threads of a task's review: kept in the state directory, delivered with the feedback, answered by the agent."
  :requires '(store tasks tools-review)
  :init #'harness-patch-review--init
  :shutdown #'harness-patch-review--shutdown)

(provide 'harness-patch-review)
;;; harness-patch-review.el ends here
