;;; harness-patch-review-test.el --- Tests for the threads of a task's review  -*- lexical-binding: t; -*-

;;; Commentary:

;; The harness's half of the threads of a review (harness-patch-review.el)
;; and the tools the agent answers them with (harness-tools-review.el): a
;; task's threads kept in the state directory, the operations a UI sends
;; performed once and announced, the version a hand-in makes, the drafts
;; that go with the feedback that sends the task back, the rounds of
;; feedback from before threads existed and the words the user wrote by
;; hand outside them, the files the reviewer has viewed, and review_comment
;; and review_threads.  The repositories are throwaway ones, whose commits are
;; never signed.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)
(require 'harness-patch-review)
(require 'harness-tools-review)

(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
(defvar harness-naming-auto)
(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent--turns)
(defvar harness-tasks--table)
(defvar harness-tasks--starting)
(defvar harness-tasks--loaded)
(defvar harness-tasks-max-running)
(defvar harness-tasks-require-verification)
(defvar harness-tasks-model)
(defvar harness-tasks-worktrees)
(defvar harness-acp--server-enabled)
(defvar harness-acp--clients)
(defvar harness-acp-token)
(defvar harness-tasks--reject-message)
(declare-function harness-tasks--set "harness-tasks")
(declare-function harness-acp--drop-client "harness-acp")

(defun harness-patch-review-test--git (dir &rest args)
  "Run git with ARGS in DIR and return what it writes, trimmed."
  (with-temp-buffer
    (let* ((default-directory dir)
           (status (apply #'call-process "git" nil t nil args)))
      (unless (eql status 0)
        (error "git %s failed: %s" (string-join args " ") (buffer-string)))
      (string-trim (buffer-string)))))

(defun harness-patch-review-test--repo (dir)
  "Make a repository in DIR whose branch task/fix a task made from main."
  (let ((git (lambda (&rest args) (apply #'harness-patch-review-test--git dir args)))
        (write (lambda (name lines)
                 (with-temp-file (expand-file-name name dir)
                   (dotimes (i lines) (insert (format "(setq %s%d %d)\n" (file-name-base name) (1+ i) (1+ i))))))))
    (funcall git "init" "-q" "-b" "main")
    (funcall git "config" "user.name" "Harness Test")
    (funcall git "config" "user.email" "test@example.invalid")
    (funcall git "config" "commit.gpgsign" "false")
    (funcall write "a.el" 20)
    (funcall git "add" "-A")
    (funcall git "commit" "-q" "-m" "The start")
    (funcall git "checkout" "-q" "-b" "task/fix")
    (with-temp-file (expand-file-name "a.el" dir)
      (insert "(setq a1 1)\n(setq a2 'two)\n")
      (dotimes (i 18) (insert (format "(setq a%d %d)\n" (+ i 3) (+ i 3)))))
    (funcall git "commit" "-q" "-am" "Fix it")))

(defmacro harness-patch-review-test-with (&rest body)
  "Run BODY with the harness's half of the review loaded; bind `repo' and `events'.
`repo' is a repository with a branch task/fix; `events' collects the
\(TASK-ID OP) each `patch-review/changed' announced, newest first."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-patch-review-test--repo dir)
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent tasks acp
                          tools-handin tools-review patch-review))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-tasks--table)
     (clrhash harness-tasks--starting)
     (clrhash harness-patch-review--sets)
     (setq harness-tasks--loaded t harness-acp--clients nil)
     (harness-test-load-module 'tools-handin)
     (harness-test-load-module 'tools-review)
     (let ((harness-provider-demo--delay 0.005)
           (harness-provider-demo-script-override
            '((:type text :delta "All done.\n")
              (:type tool-call :id "h1" :name "hand_in"
                     :input (:problem "The flaky test fails." :summary "Done: fixed." :evidence ("a note")))))
           (harness-naming-auto nil)
           (harness-tasks-max-running 3)
           (harness-tasks-require-verification t)
           (harness-tasks-model "demo:scripted")
           (harness-tasks-worktrees nil)
           (harness-acp-token nil)
           (default-directory dir)
           (repo dir)
           (events nil))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       (harness-on 'patch-review/changed (lambda (id op) (push (list id op) events)))
       (unwind-protect (progn ,@body)
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))))))

(defun harness-patch-review-test--task ()
  "Submit a task, wait for it to come to review, and give it its branch; return its id."
  (let ((id (plist-get (harness-call 'task/submit default-directory "Fix the flaky test") :id)))
    (harness-test-wait (lambda () (eq 'review (plist-get (harness-call 'task/get id) :state)))
                       15 "the task to wait for review")
    (harness-tasks--set id :branch "task/fix" :base "main" :project default-directory)
    id))

(defun harness-patch-review-test--user-comment (id text &rest keys)
  "Add the user's comment TEXT to task ID's review, as a UI does; return its id.
KEYS: :thread, :location (data), :revision, :sent."
  (let* ((comment-id (change-review-new-id "c"))
         (thread (or (plist-get keys :thread) (change-review-new-id "t"))))
    (harness-call 'patch-review/apply id
                  (list :op "add-comment" :thread thread
                        :comment (append (list :id comment-id :thread thread :body text
                                               :time (float-time)
                                               :author '(:kind "user" :name "Noah" :email "noah@example.org"))
                                         (and (plist-get keys :location) (list :location (plist-get keys :location)))
                                         (and (plist-get keys :revision) (list :revision (plist-get keys :revision)))
                                         (and (plist-get keys :sent) (list :sent (plist-get keys :sent))))))
    (cons thread comment-id)))

(defconst harness-patch-review-test--a18
  '(:file "a.el" :line 18 :excerpt "@@ -15,4 +15,4 @@\n (setq a15 15)\n (setq a16 16)\n (setq a17 17)\n-(setq a18 18)\n+(setq a18 'eighteen)")
  "The location of a comment on line 18 of a.el, as data.")

;;;; Keeping the threads

(ert-deftest harness-patch-review-keeps-the-threads-of-a-task ()
  "A task starts with no thread; what a UI sends is kept in the state
directory, announced, and read back after a restart."
  (harness-patch-review-test-with
    (let ((id (harness-patch-review-test--task)))
      (should-not (plist-get (harness-call 'patch-review/get id) :threads))
      (let* ((made (harness-patch-review-test--user-comment id "Why eighteen?"
                                                           :location harness-patch-review-test--a18))
             (result (harness-call 'patch-review/apply id
                                   (list :op "set-status" :thread (car made) :status "closed"
                                         :id "s-1" :time 5 :author '(:kind "user" :name "Noah")))))
        (should (plist-get result :changed))
        ;; Announced, in order, for every UI to perform on its copy.
        (should (equal '("add-comment" "set-status") (mapcar (lambda (e) (plist-get (cadr e) :op)) (reverse events))))
        (should (equal id (car (car events))))
        ;; Kept.
        (let ((data (harness-call 'store/load (format "patch-review/%s.json" id))))
          (should (equal "Why eighteen?" (plist-get (car (plist-get (car (plist-get data :threads)) :comments)) :body)))
          (should (equal "closed" (plist-get (car (plist-get data :threads)) :status))))
        ;; A restart: the table is empty, the document is read.
        (clrhash harness-patch-review--sets)
        (let* ((threads (plist-get (harness-call 'patch-review/get id) :threads))
               (thread (car threads)))
          (should (= 1 (length threads)))
          (should (equal (car made) (plist-get thread :id)))
          (should (equal "closed" (plist-get thread :status)))
          (should (equal "a.el" (plist-get (plist-get (car (plist-get thread :comments)) :location) :file)))
          (should (equal "Noah" (plist-get (plist-get (car (plist-get thread :comments)) :author) :name))))))))

(ert-deftest harness-patch-review-performs-an-operation-once ()
  "The same operation sent twice changes nothing and announces nothing the second time."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (op (list :op "add-comment" :thread "t-1"
                     :comment (list :id "c-1" :thread "t-1" :body "Once" :time 1.0
                                    :author '(:kind "user" :name "Noah")))))
      (should (plist-get (harness-call 'patch-review/apply id op) :changed))
      (should-not (plist-get (harness-call 'patch-review/apply id op) :changed))
      (should (= 1 (length events)))
      (should (= 1 (length (plist-get (car (plist-get (harness-call 'patch-review/get id) :threads)) :comments)))))))

(ert-deftest harness-patch-review-takes-only-the-users-operations-from-a-ui ()
  "A UI cannot mark comments sent, or make up operations: the harness does."
  (harness-patch-review-test-with
    (let ((id (harness-patch-review-test--task)))
      (should-error (harness-call 'patch-review/apply id (list :op "mark-sent" :comments '("c-1")))
                    :type 'harness-error)
      (should-error (harness-call 'patch-review/apply id (list :op "nonsense")) :type 'harness-error)
      (should-not events))))

;;;; The closes the user has looked at

(defun harness-patch-review-test--agent-closes (id)
  "Have the agent of task ID answer a new thread of the user's and close it.
Return (THREAD-ID . STATUS-ID): the thread, and the id of the change of
status that closed it, from the harness's data."
  (let* ((made (harness-patch-review-test--user-comment id "Why eighteen?"
                                                       :location harness-patch-review-test--a18 :sent 5.0)))
    (harness-patch-review-test--tool
     "review_comment" (list :thread (car made) :body "Because the loop needs it." :status "closed") id)
    (cons (car made)
          (plist-get (car (last (plist-get (cl-find (car made) (plist-get (harness-call 'patch-review/get id) :threads)
                                                    :key (lambda (th) (plist-get th :id)) :test #'equal)
                                           :history)))
                     :id))))

(defun harness-patch-review-test--history (id thread-id)
  "Return the history of the thread THREAD-ID of task ID, as the harness keeps it."
  (plist-get (cl-find thread-id (plist-get (harness-call 'patch-review/get id) :threads)
                      :key (lambda (th) (plist-get th :id)) :test #'equal)
             :history))

(ert-deftest harness-patch-review-keeps-the-close-the-user-reviewed ()
  "What the agent closes waits for the user until they say they looked: the
operations that say so are kept with the thread, announced to every UI, read
back after a restart, and heard once.  A close the agent makes again after
the thread was opened is not reviewed."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (closed (harness-patch-review-test--agent-closes id))
           (thread-id (car closed))
           (status-id (cdr closed)))
      (should (stringp status-id))
      (should-not (plist-get (car (harness-patch-review-test--history id thread-id)) :reviewed))
      (setq events nil)
      ;; The user looked: kept, and announced as the operation it was.
      (should (plist-get (harness-call 'patch-review/apply id
                                       (list :op "mark-reviewed" :thread thread-id
                                             :status-id status-id :time 77.0))
                         :changed))
      (should (= 77.0 (plist-get (car (harness-patch-review-test--history id thread-id)) :reviewed)))
      (should (equal '("mark-reviewed") (mapcar (lambda (e) (format "%s" (plist-get (cadr e) :op))) events)))
      (should (equal status-id (plist-get (cadr (car events)) :status-id)))
      ;; Heard once.
      (should-not (plist-get (harness-call 'patch-review/apply id
                                           (list :op "mark-reviewed" :thread thread-id
                                                 :status-id status-id :time 78.0))
                             :changed))
      (should (= 1 (length events)))
      ;; Kept in the state directory: a restart reads it back.
      (clrhash harness-patch-review--sets)
      (should (= 77.0 (plist-get (car (harness-patch-review-test--history id thread-id)) :reviewed)))
      ;; Waiting again, after a slip.
      (should (plist-get (harness-call 'patch-review/apply id
                                       (list :op "unmark-reviewed" :thread thread-id :status-id status-id))
                         :changed))
      (should-not (plist-get (car (harness-patch-review-test--history id thread-id)) :reviewed))
      (should (equal '("unmark-reviewed" "mark-reviewed")
                     (mapcar (lambda (e) (format "%s" (plist-get (cadr e) :op))) events)))
      ;; Reviewed, then opened, then closed by the agent again: that close is new.
      (harness-call 'patch-review/apply id (list :op "mark-reviewed" :thread thread-id
                                                 :status-id status-id :time 79.0))
      (harness-patch-review-test--tool "review_comment" (list :thread thread-id :status "open") id)
      (harness-patch-review-test--tool "review_comment" (list :thread thread-id :body "Again, properly."
                                                              :status "closed") id)
      (let ((history (harness-patch-review-test--history id thread-id)))
        (should (equal '("closed" "open" "closed") (mapcar (lambda (e) (plist-get e :status)) history)))
        (should (= 79.0 (plist-get (car history) :reviewed)))
        (should-not (plist-get (car (last history)) :reviewed))
        (should (equal "agent" (plist-get (plist-get (car (last history)) :author) :kind))))
      ;; A mark meant for a thread that is not there is an error, not a guess.
      (should-error (harness-call 'patch-review/apply id (list :op "mark-reviewed" :thread "t-nope"))
                    :type 'change-review-error))))

(ert-deftest harness-patch-review-tells-the-agent-the-user-looks-at-what-it-closes ()
  "The agent reads, with the feedback and in its tool's description, that the
user looks at every thread it closes, so it says what it changed and where."
  (harness-patch-review-test-with
    (let ((id (harness-patch-review-test--task)))
      ;; A draft to send: the feedback quotes it, after the line that says how to answer.
      (harness-patch-review-test--user-comment id "Why eighteen?"
                                               :location harness-patch-review-test--a18)
      (should (string-search "I look at every thread you close, so say in your answer what you changed and where."
                             (car (harness-patch-review--additions (harness-call 'task/get id) nil))))
      (should (string-search "the user looks at every thread you close"
                             (harness-tool-description (harness-tool-get "review_comment")))))))

(ert-deftest harness-patch-review-records-the-version-a-task-hands-in ()
  "The commit the branch ends at is a version of the task's change set: the
source revision comments are made against, with the commit it was made
from, the report's summary and the agent that handed it in."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (task (harness-call 'task/get id))
           (tip (harness-patch-review-test--git repo "rev-parse" "task/fix"))
           (base (harness-patch-review-test--git repo "merge-base" "main" "task/fix")))
      (harness-test-await (harness-patch-review--record-version task))
      (let* ((versions (plist-get (harness-call 'patch-review/get id) :versions))
             (version (car versions)))
        (should (= 1 (length versions)))
        (should (equal tip (plist-get version :id)))
        (should (equal tip (plist-get version :tip)))
        (should (equal base (plist-get version :base)))
        (should (equal 1 (plist-get version :number)))
        (should (equal "Done: fixed." (plist-get version :description)))
        (should (equal "task/fix" (plist-get (plist-get version :meta) :branch)))
        ;; The agent that handed the work in: its session, and the hand_in call.
        (let ((author (plist-get version :author)))
          (should (equal "agent" (plist-get author :kind)))
          (should (equal (plist-get task :session) (plist-get author :session))))
        (should (plist-get (plist-get task :report) :call-id)))
      ;; Recorded again: the same version.
      (harness-test-await (harness-patch-review--record-version (harness-call 'task/get id)))
      (should (= 1 (length (plist-get (harness-call 'patch-review/get id) :versions))))
      ;; The branch moves on: a second version.
      (harness-patch-review-test--git repo "checkout" "-q" "task/fix")
      (with-temp-file (expand-file-name "b.el" repo) (insert "(setq b 1)\n"))
      (harness-patch-review-test--git repo "add" "-A")
      (harness-patch-review-test--git repo "commit" "-q" "-m" "More")
      (harness-test-await (harness-patch-review--record-version (harness-call 'task/get id)))
      (should (equal '(1 2) (mapcar (lambda (v) (plist-get v :number))
                                    (plist-get (harness-call 'patch-review/get id) :versions)))))))

(ert-deftest harness-patch-review-records-no-version-without-a-branch ()
  "A task that worked in the main checkout has no branch, so no version."
  (harness-patch-review-test-with
    (let* ((id (plist-get (harness-call 'task/submit default-directory "Fix the flaky test") :id)))
      (harness-test-wait (lambda () (eq 'review (plist-get (harness-call 'task/get id) :state))) 15 "review")
      (should-not (harness-patch-review--record-version (harness-call 'task/get id)))
      (should-not (plist-get (harness-call 'patch-review/get id) :versions)))))

;;;; The drafts go with the feedback

(ert-deftest harness-patch-review-sends-the-drafts-with-the-feedback ()
  "The drafts of a task's review go after the words it is sent back with,
quoted from the diff above each comment, each naming its thread, under a
line saying what the quote is; they are sent once the task is."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (task (harness-call 'task/get id))
           (tip (harness-patch-review-test--git repo "rev-parse" "task/fix")))
      (harness-test-await (harness-patch-review--record-version task))
      (let* ((first (harness-patch-review-test--user-comment id "Why eighteen?" :location harness-patch-review-test--a18))
             (sent (harness-patch-review-test--user-comment id "Already said." :sent 10.0)))
        (ignore sent)
        (should (= 1 (length (harness-call 'patch-review/drafts id))))
        (harness-call 'task/reject id "Nearly there.")
        (let ((feedback (plist-get (car (plist-get (harness-call 'task/get id) :feedback)) :text)))
          (should (string-prefix-p (concat "Nearly there.\n\nMy review comments on your branch task/fix (at "
                                           (substring tip 0 7) ") against main (merge base ")
                                   feedback))
          (should (string-search "[thread" feedback))
          (should (string-search (concat "> diff --git a/a.el b/a.el\n> @@ -15,4 +15,4 @@\n"
                                         ">  (setq a15 15)\n>  (setq a16 16)\n>  (setq a17 17)\n"
                                         "> -(setq a18 18)\n> +(setq a18 'eighteen)\n\n"
                                         "Why eighteen?\n[thread " (car first) "]")
                                 feedback))
          (should (string-search "review_comment" feedback)))
        ;; Sent with the round that kept them.
        (let ((drafts (harness-call 'patch-review/drafts id)))
          (should-not drafts))
        ;; The words the round said are a thread of their own, on the change as a whole.
        (let* ((threads (plist-get (harness-call 'patch-review/get id) :threads))
               (words (cl-find-if (lambda (th) (plist-get (plist-get (car (plist-get th :comments)) :meta) :words))
                                  threads))
               (root (car (plist-get words :comments))))
          (should words)
          (should (equal "Nearly there." (plist-get root :body)))
          (should (eql 0 (plist-get (plist-get root :meta) :round)))
          (should (numberp (plist-get root :sent)))
          (should-not (plist-get root :location))
          (should (equal "open" (plist-get words :status))))
        (let* ((data (harness-call 'patch-review/get id))
               (comment (car (plist-get (cl-find (car first) (plist-get data :threads)
                                                 :key (lambda (th) (plist-get th :id)) :test #'equal)
                                        :comments))))
          (should (numberp (plist-get comment :sent)))
          (should (eql 0 (plist-get (plist-get comment :meta) :round))))))))

(ert-deftest harness-patch-review-sends-a-reply-that-quotes-as-it-was-written ()
  "A reply that starts with the part of a comment it answers, quoted as a mail
quotes (C-c > in the views), reaches the agent as it was written: the quote is
not filled into the lines around it, a long line of it is cut with the same
\">\"s, and the answer is under it."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (quoted (concat "the retry loop needs one more than that, because it counts the first "
                           "try as well as the retries that follow it"))
           (first (harness-patch-review-test--user-comment
                   id (concat "Why eighteen? " quoted ".") :location harness-patch-review-test--a18 :sent 10.0)))
      (harness-patch-review-test--user-comment
       id (concat "> " quoted "\n>\n> second paragraph\n\nThen say so in a comment.")
       :thread (car first))
      (harness-call 'task/reject id "Nearly there.")
      (let* ((feedback (plist-get (car (plist-get (harness-call 'task/get id) :feedback)) :text))
             (lines (split-string feedback "\n"))
             (start (cl-position-if (lambda (line) (string-prefix-p " > the retry loop" line)) lines))
             (quote (and start (seq-take-while (lambda (line) (string-prefix-p " >" line)) (nthcdr start lines)))))
        (should start)
        ;; Each line of the quote is a line of its own, a cut of the long one with its \">\".
        (should (> (length quote) 3))
        (should (cl-every (lambda (line) (<= (length line) 72)) quote))
        (should (equal quoted (mapconcat (lambda (line) (string-remove-prefix " > " line))
                                         (butlast quote 2) " ")))
        (should (equal '(" >" " > second paragraph") (last quote 2)))
        ;; The answer follows, a line apart, and the thread is named after it.
        (should (equal '("" "Then say so in a comment." "[thread")
                       (let ((after (nthcdr (+ start (length quote)) lines)))
                         (list (car after) (cadr after) (substring (caddr after) 0 7)))))))))

(ert-deftest harness-patch-review-sends-the-drafts-alone ()
  "A task is sent back with drafts and no words; with neither, it is refused."
  (harness-patch-review-test-with
    (let ((id (harness-patch-review-test--task)))
      (should-error (harness-call 'task/reject id "") :type 'error)
      (should (eq 'review (plist-get (harness-call 'task/get id) :state)))
      (harness-patch-review-test--user-comment id "A word on the whole")
      (harness-call 'task/reject id "")
      ;; No words: no thread of the words, only the draft's.
      (should (= 1 (length (plist-get (harness-call 'patch-review/get id) :threads))))
      (let ((feedback (plist-get (car (plist-get (harness-call 'task/get id) :feedback)) :text)))
        (should (string-prefix-p "My review comments on your branch task/fix" feedback))
        (should (string-search "A word on the whole\n[thread " feedback))))))

(ert-deftest harness-patch-review-sends-the-drafts-with-a-message-to-the-session ()
  "A message the user writes in the session of a task in review is the
feedback that sends it back, and the drafts go with it."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (sid (plist-get (harness-call 'task/get id) :session)))
      (harness-patch-review-test--user-comment id "Why eighteen?" :location harness-patch-review-test--a18)
      (harness-call 'agent/prompt sid "  Also this.  ")
      (let ((feedback (plist-get (car (plist-get (harness-call 'task/get id) :feedback)) :text)))
        (should (string-prefix-p "Also this.\n\nMy review comments on your branch task/fix" feedback))
        (should (string-search "Why eighteen?\n[thread " feedback)))
      (should-not (harness-call 'patch-review/drafts id)))))

(ert-deftest harness-patch-review-sends-nothing-more-than-the-words-without-drafts ()
  "With no draft the feedback is the words, as it was."
  (harness-patch-review-test-with
    (let ((id (harness-patch-review-test--task)))
      (harness-call 'task/reject id "Just this.")
      (should (equal "Just this." (plist-get (car (plist-get (harness-call 'task/get id) :feedback)) :text)))
      ;; Kept as a thread, so the review remembers what the round said.
      (let ((threads (plist-get (harness-call 'patch-review/get id) :threads)))
        (should (equal '("Just this.") (mapcar (lambda (th) (plist-get (car (plist-get th :comments)) :body)) threads)))))))

(ert-deftest harness-patch-review-adds-to-the-feedback-through-a-hook ()
  "What the module does is what any function on
`harness-tasks-feedback-additions-functions' may: its text goes after the
words, its second part is called once the task is sent back, never when the
message is refused, and a function that fails adds nothing."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (calls nil))
      ;; Refused: a function with nothing to say makes no feedback, and what it
      ;; would do once the task is sent back is never done.
      (let ((harness-tasks-feedback-additions-functions
             (list (lambda (_task _words) (cons nil (lambda () (push 'done calls)))))))
        (should-error (harness-call 'task/reject id "") :type 'error)
        (should-not calls))
      (let ((harness-tasks-feedback-additions-functions
             (list (lambda (task words) (push (list (plist-get task :id) words) calls)
                     (cons "From the hook." (lambda () (push 'done calls))))
                   (lambda (_task _words) (error "A broken function"))
                   (lambda (_task _words) nil))))
        (harness-call 'task/reject id "The words.")
        (should (equal (list (list id "The words.") 'done) (reverse calls)))
        (should (equal "The words.\n\nFrom the hook."
                       (plist-get (car (plist-get (harness-call 'task/get id) :feedback)) :text)))))))

(ert-deftest harness-patch-review-is-known-to-a-ui ()
  "A UI may call the module's methods and hears its event."
  (should (member "patch-review/" harness-acp-extension-prefixes))
  (should (memq 'patch-review/changed harness-acp--forwarded-events))
  (dolist (method '(patch-review/get patch-review/apply patch-review/drafts
                                     patch-review/comment patch-review/threads-text))
    (should (harness-method-exists-p method))))

;;;; The earlier rounds

(defconst harness-patch-review-test--round
  "Nearly there.

My comments on the diff of your branch task/fix (at 0123456) against main (merge base 7654321), each under the lines it is about:

> diff --git a/a.el b/a.el
> @@ -1,2 +1,2 @@
>  (setq a1 1)
> -(setq a2 2)
> +(setq a2 'two)

Why two?

And the tests?

> diff --git a/docs/é.txt b/docs/é.txt

Needs a caption
"
  "A round of feedback, as the review once wrote it in the box.")

(ert-deftest harness-patch-review-imports-earlier-rounds-as-closed-threads ()
  "The comments quoted in the rounds of feedback a task was sent back with
before threads existed become closed threads, once, with ids that follow
from where each was."
  (harness-patch-review-test-with
    (let ((id (harness-patch-review-test--task)))
      (harness-tasks--set id :feedback (list (list :text harness-patch-review-test--round :at 1000.0)
                                             (list :text "Plain words." :at 2000.0)))
      (let* ((threads (plist-get (harness-call 'patch-review/get id) :threads))
             (comments (mapcar (lambda (th) (car (plist-get th :comments))) threads)))
        ;; The words before the quote, the two comments on a.el:2, the one on the file, the plain round.
        (should (equal '("Nearly there." "Why two?" "And the tests?" "Needs a caption" "Plain words.")
                       (mapcar (lambda (c) (plist-get c :body)) comments)))
        (should (cl-every (lambda (th) (equal "closed" (plist-get th :status))) threads))
        (should (cl-every (lambda (c) (plist-get c :sent)) comments))
        (should (equal 1000.0 (plist-get (nth 1 comments) :time)))
        (should (equal "0123456" (plist-get (nth 1 comments) :revision)))
        (should (equal "a.el" (plist-get (plist-get (nth 1 comments) :location) :file)))
        (should (eql 2 (plist-get (plist-get (nth 1 comments) :location) :line)))
        (should (equal "docs/é.txt" (plist-get (plist-get (nth 3 comments) :location) :file)))
        (should-not (plist-get (plist-get (nth 3 comments) :location) :line))
        (should-not (plist-get (nth 4 comments) :revision))
        (should-not (plist-get (nth 0 comments) :location))
        (should (equal '(:round 0 :imported t) (plist-get (nth 1 comments) :meta)))
        ;; Made again from the same rounds: the same ids, so nothing is added.
        (let ((ids (mapcar (lambda (th) (plist-get th :id)) threads)))
          (delete-file (harness-store-path (format "patch-review/%s.json" id)))
          (clrhash harness-patch-review--sets)
          (should (equal ids (mapcar (lambda (th) (plist-get th :id))
                                     (plist-get (harness-call 'patch-review/get id) :threads)))))))))

(defconst harness-patch-review-test--inline-round
  "> The proxy image is pinned and live.
> It cost about 7 seconds.

silence

---

> Second, the migration [...]

Let's ship it without that."
  "A round written inline, under quotes of the agent's words, parted by a rule.")

(ert-deftest harness-patch-review-keeps-the-quote-an-inline-reply-answers ()
  "A reply written under a quote of the agent's words keeps the quote above
its text, so it can be read; a rule typed between two replies is no
comment, and the replies after it keep the places they had."
  (harness-patch-review-test-with
    (let ((id (harness-patch-review-test--task)))
      (harness-tasks--set id :feedback (list (list :text harness-patch-review-test--inline-round :at 1000.0)))
      (let* ((threads (plist-get (harness-call 'patch-review/get id) :threads))
             (bodies (mapcar (lambda (th) (plist-get (car (plist-get th :comments)) :body)) threads)))
        (should (equal '("> The proxy image is pinned and live.\n> It cost about 7 seconds.\n\nsilence"
                         "> Second, the migration [...]\n\nLet's ship it without that.")
                       bodies))
        (should (cl-every (lambda (th) (equal "closed" (plist-get th :status))) threads))
        ;; The place of a comment in its round names it: the rule took the
        ;; place the second reply would have had without it.
        (should (equal (change-review-stable-id "t" id 0 0) (plist-get (nth 0 threads) :id)))
        (should (equal (change-review-stable-id "t" id 0 2) (plist-get (nth 1 threads) :id)))
        ;; A set made with the quotes has none to put back.
        (should (equal '(:added 0 :edited 0 :threads nil) (harness-call 'patch-review/import-manual id)))))))

(defun harness-patch-review-test--import-old-style (id comments)
  "Add COMMENTS, (K BODY), of round 0 of task ID's review as an early import did.
They have the plain text of the reply, no quote above it."
  (pcase-dolist (`(,k ,body) comments)
    (let ((thread (change-review-stable-id "t" id 0 k)))
      (harness-call 'patch-review/apply id
                    (list :op "add-comment" :thread thread
                          :comment (list :id (change-review-stable-id "c" id 0 k) :thread thread
                                         :body body :time 1000.0 :sent 1000.0
                                         :author '(:kind "user" :name "Noah")
                                         :meta '(:round 0 :imported t)))))))

(ert-deftest harness-patch-review-puts-the-quote-back-on-an-earlier-import ()
  "A comment imported without its quote gets it; one the user edited since,
or that no import made, is left alone; asking again changes nothing."
  (harness-patch-review-test-with
    (let ((id (harness-patch-review-test--task)))
      ;; The review as it was when the import left the quotes out: made
      ;; before the rounds were there to import, then given their comments.
      (harness-call 'patch-review/get id)
      (harness-patch-review-test--import-old-style
       id '((0 "silence") (2 "Let's ship it without that.")))
      (harness-tasks--set id :feedback (list (list :text harness-patch-review-test--inline-round :at 1000.0)))
      (let ((untouched (harness-patch-review-test--user-comment id "A comment of its own")))
        (harness-call 'patch-review/apply id (list :op "edit-comment"
                                                  :comment (change-review-stable-id "c" id 0 2)
                                                  :body "Let's ship it, edited." :time 2000.0))
        (let ((result (harness-call 'patch-review/import-manual id)))
          (should (equal 1 (plist-get result :edited)))
          (should (equal 0 (plist-get result :added))))
        (let* ((comments (mapcar (lambda (th) (car (plist-get th :comments)))
                                 (plist-get (harness-call 'patch-review/get id) :threads))))
          (should (equal "> The proxy image is pinned and live.\n> It cost about 7 seconds.\n\nsilence"
                         (plist-get (nth 0 comments) :body)))
          (should (numberp (plist-get (nth 0 comments) :edited)))
          (should (equal "Let's ship it, edited." (plist-get (nth 1 comments) :body)))
          (should (equal "A comment of its own" (plist-get (nth 2 comments) :body)))
          (should (equal (car untouched) (plist-get (nth 2 comments) :thread))))
        ;; Announced, to perform on every UI's copy.
        (should (cl-find "edit-comment" events :key (lambda (e) (format "%s" (plist-get (cadr e) :op))) :test #'equal))
        ;; Again: nothing to do.
        (let ((result (harness-call 'patch-review/import-manual id)))
          (should (equal '(:added 0 :edited 0 :threads nil) result)))))))

(defun harness-patch-review-test--type (id text &rest keys)
  "Append a message TEXT the user typed to the session of task ID; return its node.
KEYS: :ts, :meta."
  (harness-call 'session/append (plist-get (harness-call 'task/get id) :session)
                (list :kind 'user :content text
                      :ts (or (plist-get keys :ts) (float-time))
                      :meta (plist-get keys :meta))))

(ert-deftest harness-patch-review-imports-the-replies-typed-in-the-session ()
  "A reply the user typed to the agent while it worked, under a quote of
what it said, is a closed thread of the review, written when it was typed;
what the harness or another session sent, a round, the prompt and words
that answer no quote are not."
  (harness-patch-review-test-with
    (let ((id (harness-patch-review-test--task)))
      (let* ((typed (harness-patch-review-test--type
                     id "> - Requests/limits on every service? No.\n\nis there some more elegant way?\nlike an admission webhook"
                     :ts 3000.5 :meta '(:steering t))))
        ;; Not comments: the harness's own words, another agent's, a round, plain steering.
        (harness-patch-review-test--type id "> quoted\n\nsystem says" :meta '(:from (:kind system :source "non-interactive mode")))
        (harness-patch-review-test--type id "> quoted\n\nanother agent says"
                                         :meta '(:from (:kind session :id "s-2" :name "Other")))
        (harness-patch-review-test--type id (concat harness-tasks--reject-message "\n\n> quoted\n\nsent back"))
        (harness-patch-review-test--type id "Also handle the other case." :meta '(:steering t))
        (let ((result (harness-call 'patch-review/import-manual id)))
          (should (equal 1 (plist-get result :added)))
          (should (equal 0 (plist-get result :edited))))
        (let* ((threads (plist-get (harness-call 'patch-review/get id) :threads))
               (thread (car threads))
               (comment (car (plist-get thread :comments))))
          (should (= 1 (length threads)))
          (should (equal "closed" (plist-get thread :status)))
          (should (equal "> - Requests/limits on every service? No.\n\nis there some more elegant way?\nlike an admission webhook"
                         (plist-get comment :body)))
          (should (equal 3000.5 (plist-get comment :time)))
          (should (equal 3000.5 (plist-get comment :sent)))
          (should (equal "user" (plist-get (plist-get comment :author) :kind)))
          (should-not (plist-get comment :location))
          (should (equal (list :imported t :manual t :node (plist-get typed :id)) (plist-get comment :meta))))
        ;; Announced like any change to the threads.
        (should (equal '("add-comment" "set-status")
                       (mapcar (lambda (e) (format "%s" (plist-get (cadr e) :op))) (reverse events))))
        ;; Again, after a restart: the same thread, once.
        (clrhash harness-patch-review--sets)
        (should (equal '(:added 0 :edited 0 :threads nil) (harness-call 'patch-review/import-manual id)))
        (should (= 1 (length (plist-get (harness-call 'patch-review/get id) :threads))))))))

(ert-deftest harness-patch-review-leaves-a-session-without-replies-alone ()
  "A task whose session has no reply of the kind, or none at all, imports nothing."
  (harness-patch-review-test-with
    (let ((id (harness-patch-review-test--task)))
      (should (equal '(:added 0 :edited 0 :threads nil) (harness-call 'patch-review/import-manual id)))
      (harness-tasks--set id :session "no-such-session")
      (should (equal '(:added 0 :edited 0 :threads nil) (harness-call 'patch-review/import-manual id)))
      (should-error (harness-call 'patch-review/import-manual "t-nope") :type 'harness-error))))

;;;; The files viewed

(defun harness-patch-review-test--commit (repo files message)
  "Write FILES, (NAME TEXT), in REPO, commit them as MESSAGE; return the commit.
Only FILES: the state directory is the repository too, and holds more."
  (pcase-dolist (`(,name ,text) files)
    (with-temp-file (expand-file-name name repo) (insert text)))
  (apply #'harness-patch-review-test--git repo "add" "--" (mapcar #'car files))
  (harness-patch-review-test--git repo "commit" "-q" "-m" message)
  (harness-patch-review-test--git repo "rev-parse" "HEAD"))

(defun harness-patch-review-test--paths (files)
  "Return the paths of FILES, as the review keeps files viewed."
  (mapcar (lambda (file) (plist-get file :path)) files))

(defmacro harness-patch-review-test-with-commits (&rest body)
  "Run BODY in a task whose branch has three commits; bind `id', `first', `second', `third'.
`first' fixes a.el, `second' adds b.el and c.el, `third' changes c.el.
The newest version is recorded, so the review has its tip."
  (declare (indent 0))
  `(harness-patch-review-test-with
     (let* ((id (harness-patch-review-test--task))
            (first (harness-patch-review-test--git repo "rev-parse" "task/fix"))
            (second (harness-patch-review-test--commit
                     repo '(("b.el" "(setq b 1)\n") ("c.el" "(setq c 1)\n")) "Add b and c"))
            (third (harness-patch-review-test--commit repo '(("c.el" "(setq c 2)\n")) "Change c")))
       (ignore id first second third)
       ,@body)))

(ert-deftest harness-patch-review-takes-the-files-before-the-newest-commit-as-viewed ()
  "Every file of the newest version is viewed but those its newest commit
changed; each is kept by its path and the blob it has on the branch."
  (harness-patch-review-test-with-commits
    (harness-test-await (harness-patch-review--record-version (harness-call 'task/get id)))
    (should-not (harness-call 'store/load (format "patch-review-viewed/%s.json" id)))
    (let ((result (harness-test-await (harness-call-async 'patch-review/assume-viewed id))))
      (should (equal third (plist-get result :tip)))
      (should (equal second (plist-get result :revision)))
      (should (equal 2 (plist-get result :seen)))
      (should (equal 1 (plist-get result :unviewed))))
    (let* ((data (harness-test-await (harness-call-async 'patch-review/viewed id)))
           (seen (plist-get data :seen)))
      (should (equal '("a.el" "b.el") (harness-patch-review-test--paths seen)))
      (should (equal (harness-patch-review-test--git repo "rev-parse" "task/fix:b.el")
                     (plist-get (cadr seen) :blob)))
      (should-not (plist-get data :approved))
      (should (equal second (plist-get (plist-get data :assumed) :revision)))
      (should (equal third (plist-get (plist-get data :assumed) :tip))))
    ;; Kept in the state directory, for the next time.
    (should (harness-call 'store/load (format "patch-review-viewed/%s.json" id)))
    ;; From any commit of the branch on: the first one's changes are all but a.el's.
    (let ((result (harness-test-await (harness-call-async 'patch-review/assume-viewed id (substring first 0 7)))))
      (should (equal first (plist-get result :revision)))
      (should (equal 1 (plist-get result :seen)))
      (should (equal 2 (plist-get result :unviewed))))
    (should (equal '("a.el") (harness-patch-review-test--paths
                              (plist-get (harness-test-await (harness-call-async 'patch-review/viewed id)) :seen))))
    ;; A commit the branch does not have is said so.
    (let ((err (should-error (harness-test-await (harness-call-async 'patch-review/assume-viewed id "no-such-commit"))
                             :type 'error)))
      (should (string-search "no-such-commit" (error-message-string err))))))

(ert-deftest harness-patch-review-keeps-the-files-the-reviewer-marks ()
  "Marking a file viewed or approved is kept; approving views it, and a
file no longer viewed is no longer approved; marking twice marks once."
  (harness-patch-review-test-with-commits
    (harness-test-await (harness-patch-review--record-version (harness-call 'task/get id)))
    (let* ((blob (lambda (path) (harness-patch-review-test--git repo "rev-parse" (concat "task/fix:" path))))
           (file (lambda (path) (list :path path :blob (funcall blob path))))
           (mark (lambda (kind files on)
                   (harness-test-await (harness-call-async 'patch-review/set-viewed id kind files on))))
           (state (lambda () (harness-test-await (harness-call-async 'patch-review/viewed id)))))
      (should (equal '(:seen 0 :approved 0) (list :seen (length (plist-get (funcall state) :seen))
                                                  :approved (length (plist-get (funcall state) :approved)))))
      (should (equal '(:seen 2 :approved 0)
                     (funcall mark "seen" (list (funcall file "c.el") (funcall file "a.el")) t)))
      (should (equal '(:seen 2 :approved 0) (funcall mark "seen" (list (funcall file "c.el")) t)))
      (should (equal '(:seen 3 :approved 1) (funcall mark "approved" (list (funcall file "b.el")) t)))
      (should (equal '("c.el" "a.el" "b.el") (harness-patch-review-test--paths (plist-get (funcall state) :seen))))
      (should (equal '("b.el") (harness-patch-review-test--paths (plist-get (funcall state) :approved))))
      ;; Not viewed any more: not approved either.
      (should (equal '(:seen 2 :approved 0) (funcall mark "seen" (list (funcall file "b.el")) :false)))
      (should (equal '(:seen 2 :approved 0) (funcall mark "approved" (list (funcall file "a.el")) :false)))
      ;; A file the branch deleted has no blob, and is kept by its path.
      (funcall mark "seen" (list (list :path "gone.el")) t)
      (should (equal '(:path "gone.el") (car (last (plist-get (funcall state) :seen)))))
      ;; A restart reads them from the state directory; the approved stay with an assumption.
      (funcall mark "approved" (list (funcall file "a.el")) t)
      (harness-test-await (harness-call-async 'patch-review/assume-viewed id))
      (should (equal '("a.el") (harness-patch-review-test--paths (plist-get (funcall state) :approved))))
      (should-error (harness-call 'patch-review/set-viewed id "looked" nil t) :type 'harness-error))))

(ert-deftest harness-patch-review-takes-no-file-as-viewed-on-its-own ()
  "A review whose earlier rounds were imported, and name a commit the
reviewer saw the branch at, still has no file viewed until it is asked for:
what the reviewer saw is theirs to say, and asking for the marks keeps nothing."
  (harness-patch-review-test-with-commits
    (let ((name (format "patch-review-viewed/%s.json" id)))
      (harness-tasks--set id :feedback
                          (list (list :text (format "Why b? (at %s)" (substring second 0 7)) :at 1000.0)))
      (harness-test-await (harness-patch-review--record-version (harness-call 'task/get id)))
      (should (< 0 (length (change-review-set-threads (harness-patch-review--set-for id t)))))
      (let ((data (harness-test-await (harness-call-async 'patch-review/viewed id))))
        (should-not (plist-get data :seen))
        (should-not (plist-get data :approved))
        (should-not (plist-get data :assumed)))
      (should-not (harness-call 'store/load name)))))

(ert-deftest harness-patch-review-says-when-the-repository-is-not-here ()
  "A task whose repository is on another machine cannot have files taken as
viewed, and says why; its marks are still kept."
  (harness-patch-review-test-with-commits
    (harness-test-await (harness-patch-review--record-version (harness-call 'task/get id)))
    (harness-tasks--set id :project "/no/such/dir" :worktree nil)
    (let ((err (should-error (harness-test-await (harness-call-async 'patch-review/assume-viewed id)) :type 'error)))
      (should (string-search "not on this machine" (error-message-string err))))
    (should-not (plist-get (harness-test-await (harness-call-async 'patch-review/viewed id)) :seen))
    (should (equal '(:seen 1 :approved 0)
                   (harness-test-await (harness-call-async 'patch-review/set-viewed id "seen"
                                                           (list (list :path "a.el" :blob "abc")) t))))))

;;;; What the agent reads and writes

(defun harness-patch-review-test--tool (name input id)
  "Call the tool NAME with INPUT as the session of task ID; return its result."
  (let* ((task (harness-call 'task/get id))
         (tool (harness-tool-get name)))
    (harness-test-await
     (harness-resolved
      (funcall (harness-tool-handler tool) input
               (list :session-id (plist-get task :session) :call-id "toolu_77" :cwd default-directory))))))

(ert-deftest harness-patch-review-lets-the-agent-answer-a-thread ()
  "review_comment adds the agent's comment to a thread: its author is the
agent, its session and this tool call; it says which commit the agent was
at; with a status it closes the thread; with none, opens one."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (sid (plist-get (harness-call 'task/get id) :session))
           (head (harness-patch-review-test--git repo "rev-parse" "HEAD"))
           (made (harness-patch-review-test--user-comment id "Why eighteen?"
                                                         :location harness-patch-review-test--a18 :sent 5.0))
           (result (harness-patch-review-test--tool
                    "review_comment" (list :thread (substring (car made) 0 6) :body "Because the loop needs it."
                                           :status "closed")
                    id)))
      (should-not (plist-get result :is-error))
      (should (string-search (car made) (plist-get result :content)))
      (should (string-search "closed" (plist-get result :content)))
      (let* ((thread (car (plist-get (harness-call 'patch-review/get id) :threads)))
             (answer (cadr (plist-get thread :comments)))
             (author (plist-get answer :author)))
        (should (equal "closed" (plist-get thread :status)))
        (should (equal "Because the loop needs it." (plist-get answer :body)))
        (should (equal "agent" (plist-get author :kind)))
        (should (equal sid (plist-get author :session)))
        (should (equal "toolu_77" (plist-get author :tool-call)))
        (should (equal head (plist-get answer :revision)))
        ;; Not a draft: the user sees it at once.
        (should (numberp (plist-get answer :sent)))
        ;; Who closed it, and when.
        (let ((entry (car (plist-get thread :history))))
          (should (equal "closed" (plist-get entry :status)))
          (should (equal sid (plist-get (plist-get entry :author) :session)))))
      ;; Announced.
      (should (equal '("add-comment" "add-comment" "set-status")
                     (mapcar (lambda (e) (format "%s" (plist-get (cadr e) :op))) (reverse events))))
      ;; Only the status.
      (let ((again (harness-patch-review-test--tool "review_comment" (list :thread (car made) :status "open") id)))
        (should-not (plist-get again :is-error))
        (should (equal "open" (plist-get (car (plist-get (harness-call 'patch-review/get id) :threads)) :status))))
      ;; Without a thread: a new one, on a file and line.
      (harness-patch-review-test--tool
       "review_comment" (list :body "This is the cache." :file "a.el" :line 2) id)
      (let ((thread (cadr (plist-get (harness-call 'patch-review/get id) :threads))))
        (should (equal "a.el" (plist-get (plist-get (car (plist-get thread :comments)) :location) :file)))
        (should (eql 2 (plist-get (plist-get (car (plist-get thread :comments)) :location) :line)))))))

(ert-deftest harness-patch-review-tells-the-agent-what-went-wrong ()
  "An unknown thread, or a comment with nothing in it, is an error that says what to do."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (made (harness-patch-review-test--user-comment id "Why?" :sent 5.0))
           (unknown (harness-patch-review-test--tool "review_comment" (list :thread "t-nope" :body "x") id))
           (empty (harness-patch-review-test--tool "review_comment" (list :thread (car made)) id))
           (bad (harness-patch-review-test--tool "review_comment" (list :thread (car made) :status "done") id)))
      (should (plist-get unknown :is-error))
      (should (string-search (car made) (plist-get unknown :content)))
      (should (plist-get empty :is-error))
      (should (string-search "status" (plist-get empty :content)))
      (should (plist-get bad :is-error)))))

(ert-deftest harness-patch-review-lists-the-threads-for-the-agent ()
  "review_threads lists the threads with ids, status, place and the comments
the user sent; the drafts are the user's, and stay out."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (sent (harness-patch-review-test--user-comment id "Why eighteen?"
                                                         :location harness-patch-review-test--a18 :sent 5.0))
           (draft (harness-patch-review-test--user-comment id "A secret draft")))
      (harness-patch-review-test--tool "review_comment" (list :thread (car sent) :body "Because." :status "closed") id)
      (let ((all (plist-get (harness-patch-review-test--tool "review_threads" nil id) :content))
            (open (plist-get (harness-patch-review-test--tool "review_threads" (list :status "open") id) :content))
            (closed (plist-get (harness-patch-review-test--tool "review_threads" (list :status "closed") id) :content)))
        (should (string-search (format "[%s] closed · a.el:18" (car sent)) all))
        (should (string-search "Why eighteen?" all))
        (should (string-search "Because." all))
        (should (string-search "(agent)" all))
        (should-not (string-search (car draft) all))
        (should-not (string-search "A secret draft" all))
        (should (string-search "No open threads" open))
        (should (string-search (car sent) closed))))))

(ert-deftest harness-patch-review-folds-the-reading-tool-and-not-the-writing-one ()
  "In the chat review_threads folds with the reads around it; review_comment stays in view.
The first only lists what is there.  Without its flag the call stood as
a line of its own between two summaries of reads, cutting their run
in two; the second writes what the user reads next, and a summary line
would hide it."
  (harness-patch-review-test-with
    (should (eq t (plist-get (harness-call 'tools/get "review_threads") :coalescable)))
    (should-not (plist-get (harness-call 'tools/get "review_comment") :coalescable))))

(ert-deftest harness-patch-review-offers-its-tools-to-task-sessions-only ()
  "A session that is no task's has no review to read or answer."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (task-session (harness-call 'session/get (plist-get (harness-call 'task/get id) :session)))
           (other (harness-call 'session/create :cwd default-directory)))
      (should (equal '("review_threads" "review_comment" "read_file")
                     (harness-run-filter 'agent/tools '("review_threads" "review_comment" "read_file") task-session)))
      (should (equal '("read_file")
                     (harness-run-filter 'agent/tools '("review_threads" "review_comment" "read_file")
                                         (harness-call 'session/get (if (listp other) (plist-get other :id) other)))))
      (let ((result (harness-patch-review-test--tool "review_threads" nil id)))
        (should-not (plist-get result :is-error))))))

;;;; Links to a thread

(ert-deftest harness-patch-review-finds-a-thread-for-a-link ()
  "review/find-thread names a thread by its id or the start of it, and makes nothing."
  (harness-patch-review-test-with
    (let ((id (harness-patch-review-test--task)))
      (harness-patch-review-test--user-comment id "Why eighteen?" :thread "t-1a2b3c4d"
                                              :location harness-patch-review-test--a18 :sent 5.0)
      (harness-patch-review-test--user-comment id "And the rest?" :thread "t-1a2b9999" :sent 6.0)
      (let ((found (harness-call 'review/find-thread id "t-1a2b3c4d")))
        (should (equal "t-1a2b3c4d" (plist-get found :id)))
        (should (equal "open" (plist-get found :status)))
        (should (equal "a.el:18" (plist-get found :where)))
        (should (= 1 (plist-get found :comments))))
      (should (equal "the change as a whole" (plist-get (harness-call 'review/find-thread id "t-1a2b9") :where)))
      (should (equal "t-1a2b3c4d" (plist-get (harness-call 'review/find-thread id "t-1a2b3") :id)))
      ;; Two threads start so.
      (let ((err (should-error (harness-call 'review/find-thread id "t-1a2b") :type 'harness-error)))
        (should (string-search "starts the ids of 2 threads" (cadr err))))
      ;; None, or too little to go by, or nothing.
      (should-not (harness-call 'review/find-thread id "t-zzz"))
      (should-not (harness-call 'review/find-thread id "t-"))
      (should-not (harness-call 'review/find-thread id nil))
      ;; A task with no review has no thread, and asking makes none.
      (should-not (harness-call 'review/find-thread "t-no-task" "t-1a2b3c4d"))
      (should-not (harness-call 'store/load "patch-review/t-no-task.json")))))

(ert-deftest harness-patch-review-gives-the-agent-a-link-to-each-thread ()
  "review_threads shows, on each thread's line, the link to put in a message."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (sent (harness-patch-review-test--user-comment id "Why eighteen?"
                                                         :location harness-patch-review-test--a18 :sent 5.0))
           (all (plist-get (harness-patch-review-test--tool "review_threads" nil id) :content)))
      (should (string-search (format "[%s] open · a.el:18 · harness:task/%s/thread/%s" (car sent) id (car sent)) all))
      ;; The link reads as the library reads one.
      (should (equal (list :kind 'thread :task id :thread (car sent))
                     (harness-links-parse (format "harness:task/%s/thread/%s" id (car sent))))))))

(ert-deftest harness-patch-review-a-link-to-a-thread-is-resolved ()
  "The linking module finds a thread of the review of a task, from the session of
the task, from any session with the task named, and the task itself."
  (harness-patch-review-test-with
    (harness-test-load-module 'linking)
    (let* ((id (harness-patch-review-test--task))
           (sid (plist-get (harness-call 'task/get id) :session))
           (sent (harness-patch-review-test--user-comment id "Why eighteen?"
                                                         :location harness-patch-review-test--a18 :sent 5.0))
           (thread (car sent)))
      (dolist (case (list (list (format "harness:thread/%s" thread) sid)
                          (list (format "harness:thread/%s" (substring thread 0 5)) sid)
                          (list (format "harness:task/%s/thread/%s" id thread) nil)
                          (list (format "harness:session/%s/thread/%s" sid thread) nil)))
        (ert-info ((car case))
          (let ((r (harness-call 'link/resolve (car case) (cadr case))))
            (should-not (plist-get r :error))
            (should (equal "thread" (plist-get r :kind)))
            (should (equal (format "harness:task/%s/thread/%s" id thread) (plist-get r :url)))
            (should (equal (format "thread %s on a.el:18" thread) (plist-get r :label)))
            (should (equal id (plist-get r :task)))
            (should (equal thread (plist-get r :thread)))
            (should (equal sid (plist-get r :session))))))
      (let ((r (harness-call 'link/resolve (format "harness:task/%s" (substring id 0 5)))))
        (should (equal "task" (plist-get r :kind)))
        (should (equal (format "harness:task/%s" id) (plist-get r :url)))
        (should (equal sid (plist-get r :session))))
      (should (string-match-p "No thread t-nope in the review of the task"
                              (plist-get (harness-call 'link/resolve "harness:thread/t-nope" sid) :error)))
      ;; A session that is no task's has no review.
      (let ((plain (plist-get (harness-call 'session/create :cwd default-directory :model "demo:scripted") :id)))
        (should (string-match-p "is no task's"
                                (plist-get (harness-call 'link/resolve (format "harness:thread/%s" thread) plain)
                                           :error)))))))

(ert-deftest harness-patch-review-hand-in-writes-the-links-of-its-report-out ()
  "The report a task hands in links the calls that ran in terms of that session, so it
means the same whenever the review is read; a link that names nothing is said in the result."
  (harness-patch-review-test-with
    (harness-test-load-module 'linking)
    (let* ((id (harness-patch-review-test--task))
           (sid (plist-get (harness-call 'task/get id) :session))
           (call (plist-get (harness-call 'session/append
                                          sid '(:kind tool-call :tool "bash" :call-id "toolu_b"
                                                :input (:command "make test") :title "Run command: make test"))
                            :id))
           (link (format "harness:session/%s/call/%s" sid call))
           (r (harness-patch-review-test--tool
               "hand_in"
               (list :problem "Check [the run](harness:call/bash)."
                     :summary "Done: [the tests](harness:call/last), [nothing](harness:call/zzz#3)."
                     :reproduction "Run [it](harness:call/bash#1)."
                     :evidence (list "A note [n](harness:call/bash)"
                                     (list :note "Note [n2](harness:call/last)" :caption "Cap [c](harness:call/last)")
                                     (list :code "[not](harness:call/last)" :language "text")))
               id))
           (report (plist-get (harness-call 'task/get id) :report)))
      (should-not (plist-get r :is-error))
      (should (equal (format "Check [the run](%s)." link) (plist-get report :problem)))
      (should (equal (format "Done: [the tests](%s), [nothing](harness:call/zzz#3)." link) (plist-get report :summary)))
      (should (equal (format "Run [it](%s)." link) (plist-get report :reproduction)))
      (let ((items (plist-get report :evidence)))
        (should (equal (format "A note [n](%s)" link) (plist-get (nth 0 items) :text)))
        (should (equal (format "Note [n2](%s)" link) (plist-get (nth 1 items) :text)))
        (should (equal (format "Cap [c](%s)" link) (plist-get (nth 1 items) :caption)))
        ;; Code is code.
        (should (equal "[not](harness:call/last)" (plist-get (nth 2 items) :code))))
      ;; The result says which link named nothing, after the usual words.
      (should (string-match-p "\\`Handed in: Done: [^\n]*\n\n3 pieces of evidence[^\n]*\n\nLinks that name nothing, left as you wrote them: harness:call/zzz#3: No tool call matches"
                              (plist-get r :content))))))

(ert-deftest harness-patch-review-a-comment-has-its-links-written-out ()
  "review_comment writes the links of the comment out in full, and says which named nothing."
  (harness-patch-review-test-with
    (harness-test-load-module 'linking)
    (let* ((id (harness-patch-review-test--task))
           (sid (plist-get (harness-call 'task/get id) :session))
           (made (harness-patch-review-test--user-comment id "Why?" :location harness-patch-review-test--a18 :sent 5.0))
           (call (plist-get (harness-call 'session/append
                                          sid '(:kind tool-call :tool "bash" :call-id "toolu_b"
                                                :input (:command "make test") :title "Run command: make test"))
                            :id))
           (r (harness-patch-review-test--tool
               "review_comment"
               (list :thread (car made) :body "Fixed: see [the run](harness:call/bash#1) and [x](harness:call/zzz)."
                     :status "closed")
               id))
           (comments (plist-get (car (plist-get (harness-call 'patch-review/get id) :threads)) :comments)))
      (should-not (plist-get r :is-error))
      (should (equal (format "Fixed: see [the run](harness:session/%s/call/%s) and [x](harness:call/zzz)." sid call)
                     (plist-get (cadr comments) :body)))
      (should (string-match-p "\\`Added comment .* to thread .*, which is now closed\\.\n\nLinks that name nothing, left as you wrote them: harness:call/zzz"
                              (plist-get r :content))))))

;;;; Threads started in the chat

(ert-deftest harness-patch-review-reads-the-quotes-and-the-answers-under-them ()
  "A message is read as quotes with the answers under them: parts of a quote
parted by a blank line are one, text before the first quote answers
nothing, a quote with nothing under it is no reply, and an answer goes on
to the next quote."
  (let ((segments (harness-patch-review--segments
                   (concat "Re: the build\n\n"
                           "> The build is green.\n"
                           ">\n"
                           "> The deploy is pending.\n\n"
                           "> And the logs are clean.\n\n"
                           "Good.\n\nKeep going.\n\n"
                           "> One decision is yours.\n\n"
                           "Only logged.\n\n"
                           "> Last words.\n"))))
    (should (= 2 (length segments)))
    (should (equal '("> The build is green." ">" "> The deploy is pending." "> And the logs are clean.")
                   (plist-get (car segments) :quote)))
    (should (equal "Good.\n\nKeep going." (plist-get (car segments) :answer)))
    (should (equal '("> One decision is yours.") (plist-get (cadr segments) :quote)))
    (should (equal "Only logged." (plist-get (cadr segments) :answer)))
    ;; Where they are, to cut the message there.
    (let ((text "intro\n\n> q\n\nanswer\n\nmore\n\n> q2\n\nsecond"))
      (should (equal "> q\n\nanswer\n\nmore"
                     (substring text (plist-get (car (harness-patch-review--segments text)) :from)
                                (plist-get (car (harness-patch-review--segments text)) :to)))))
    (should-not (harness-patch-review--segments "no quote at all"))
    (should-not (harness-patch-review--segments "> only a quote"))
    (should-not (harness-patch-review--segments "an answer before\n\n> and a quote"))))

(defun harness-patch-review-test--agent-says (id text)
  "Add the agent's message TEXT to the session of task ID; return its node."
  (harness-call 'session/append (plist-get (harness-call 'task/get id) :session)
                (list :kind 'assistant :content text)))

(defun harness-patch-review-test--reply (node response &optional quote)
  "Return the block of a reply, RESPONSE, to NODE, a message of the agent's.
The reference names the node and QUOTE, by default what the node says."
  (harness-thread-block
   (list :refs (list (list :kind "chat" :node (plist-get node :id) :who "agent"
                           :text (or quote (plist-get node :content)))))
   response))

(defun harness-patch-review-test--sends (id &rest blocks)
  "Pass BLOCKS, the user's message to the session of task ID, to the review's filter.
Return the blocks that go on.  Only this module's filter runs: the task of
the test waits for review, and the tasks module's reads a message to it as
the feedback that sends it back."
  (harness-patch-review--on-message
   blocks (plist-get (harness-call 'task/get id) :session) '(:from nil)))

(defun harness-patch-review-test--threads (id)
  "Return the threads of task ID's review, as the harness keeps them."
  (plist-get (harness-call 'patch-review/get id) :threads))

(ert-deftest harness-patch-review-makes-a-reply-with-thread-data-a-thread ()
  "A reply with the data of a thread is a comment in a new thread of the task's
review: the user's, sent, with the quote above the response, the references in
its meta, and, in the block that goes on, the thread's id and a marker after
the response that names the thread and says how to answer it.  The thread is
announced to every UI like any other."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (agent (harness-patch-review-test--agent-says
                   id "The build is green. The deploy is pending.\n\nThe rollback is ready."))
           (blocks (harness-patch-review-test--sends
                    id
                    (harness-patch-review-test--reply agent "Good." "The build is green.")
                    (harness-patch-review-test--reply agent "Watch it." "The rollback is ready."))))
      (let* ((threads (harness-patch-review-test--threads id))
             (first (car threads)) (second (cadr threads))
             (comment (car (plist-get first :comments)))
             (data (plist-get (car blocks) :thread)))
        (should (= 2 (length threads)))
        (should (equal "open" (plist-get first :status)))
        (should (equal "> The build is green.\n\nGood." (plist-get comment :body)))
        (should (equal "> The rollback is ready.\n\nWatch it."
                       (plist-get (car (plist-get second :comments)) :body)))
        (should (equal "user" (plist-get (plist-get comment :author) :kind)))
        ;; Sent at once, not a draft, on the change as a whole.
        (should (numberp (plist-get comment :sent)))
        (should-not (plist-get comment :location))
        ;; And says where it came from: the references, as data.
        (should (plist-get (plist-get comment :meta) :chat))
        (should (equal (plist-get agent :id)
                       (plist-get (car (plist-get (plist-get comment :meta) :refs)) :node)))
        ;; The blocks that go on know their threads, and end with the markers.
        (should (equal (plist-get first :id) (plist-get data :id)))
        (should (equal (plist-get comment :id) (plist-get data :comment)))
        (should (equal (concat "> The build is green.\n\nGood.\n\n" (harness-thread-marker (plist-get first :id)))
                       (plist-get (car blocks) :text)))
        (should (equal (list (plist-get second :id)) (harness-thread-marker-ids (plist-get (cadr blocks) :text))))
        (should (equal "Good." (harness-thread-response (car blocks)))))
      (should (equal '("add-comment" "add-comment")
                     (mapcar (lambda (e) (format "%s" (plist-get (cadr e) :op))) (reverse events)))))))

(ert-deftest harness-patch-review-puts-a-reply-to-lines-of-a-diff-on-those-lines ()
  "A reply to lines of a diff is a thread on them, at the revision the reference
names: the location is the file, the side and the lines, with the lines
themselves as its excerpt, and the comment says what was written, with no
quote of lines the review shows with the thread."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (ref (list :kind "diff" :file "a.el" :side "new" :line 18 :end 19 :revision "abc1234"
                      :text "(setq a18 'eighteen)\n(setq a19 19)"))
           (blocks (harness-patch-review-test--sends
                    id (harness-thread-block (list :refs (list ref)) "Why a symbol?")))
           (thread (car (harness-patch-review-test--threads id)))
           (comment (car (plist-get thread :comments)))
           (location (plist-get comment :location)))
      (should (equal "Why a symbol?" (plist-get comment :body)))
      (should (equal "abc1234" (plist-get comment :revision)))
      (should (equal "a.el" (plist-get location :file)))
      (should (equal 18 (plist-get location :line)))
      (should (equal 19 (plist-get location :end-line)))
      (should (equal "(setq a18 'eighteen)\n(setq a19 19)" (plist-get location :excerpt)))
      ;; What the agent reads says where the lines are.
      (should (string-prefix-p "> In a.el, lines 18-19 (after the change, at abc1234):" (plist-get (car blocks) :text)))
      (should (string-suffix-p (harness-thread-marker (plist-get thread :id)) (plist-get (car blocks) :text))))))

(ert-deftest harness-patch-review-makes-a-thread-of-nothing-it-guesses ()
  "Only a reply with thread data is a thread: words that quote the agent's, even to
the letter, are none.  Nor is a message of the harness or of another session's
agent, an attachment's text, one in a session that is no task's, or one that
was a thread already."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (sid (plist-get (harness-call 'task/get id) :session))
           (agent (harness-patch-review-test--agent-says id "The build is green."))
           (reply (harness-patch-review-test--reply agent "Good.")))
      (dolist (text '("> The build is green.\n\nGood."
                      "> some text of a file\n\nplease refactor this"
                      "The build is green, I think\n\nso go on"))
        (let ((blocks (list (list :type "text" :text text))))
          (should (equal blocks (harness-patch-review-test--sends id (car blocks))))))
      ;; Not the user's.
      (dolist (from (list '(:kind system :source "tasks") (list :kind 'session :id "s-2" :name "Other")))
        (should (equal (list reply) (harness-patch-review--on-message (list reply) sid (list :from from)))))
      ;; The agent's words in a session that is no task's: no review holds a thread.
      (let ((plain (plist-get (harness-call 'session/create :cwd default-directory :model "demo:scripted") :id)))
        (should (equal (list reply) (harness-patch-review--on-message (list reply) plain '(:from nil)))))
      (should-not (harness-patch-review-test--threads id))
      (should-not events))))

(ert-deftest harness-patch-review-keeps-a-thread-together-when-its-answer-is-referenced ()
  "The agent answers a thread with review_comment; a reply that refers to that
answer, or to an earlier reply of the user's in the thread, makes a comment in
the same thread, a reply to the one it follows, whatever the status: the thread
is open again.  A reference to a plain message of the agent's starts a thread of
its own."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (sid (plist-get (harness-call 'task/get id) :session))
           (agent (harness-patch-review-test--agent-says id "The build is green. The deploy is pending."))
           (first (car (harness-patch-review-test--sends
                        id (harness-patch-review-test--reply agent "Since when?" "The deploy is pending."))))
           (thread (plist-get (plist-get first :thread) :id))
           (body "Since the nightly job: it waits for the migration to finish.\n\nIt should be done within the hour.")
           (call (harness-call 'session/append sid
                               (list :kind 'tool-call :tool "review_comment" :call-id "toolu_77"
                                     :input (list :thread thread :body body :status "closed")))))
      ;; The agent answers in the thread, closing it.
      (harness-patch-review-test--tool "review_comment" (list :thread thread :body body :status "closed") id)
      (should (equal "closed" (plist-get (car (harness-patch-review-test--threads id)) :status)))
      ;; The user refers to a part of that answer.
      (let ((blocks (harness-patch-review-test--sends
                     id (harness-thread-block
                         (list :refs (list (list :kind "chat" :node (plist-get call :id) :who "agent"
                                                 :text "It should be done within the hour.")))
                         "Then I wait."))))
        (should (equal thread (plist-get (plist-get (car blocks) :thread) :id))))
      (let* ((threads (harness-patch-review-test--threads id))
             (comments (plist-get (car threads) :comments)))
        (should (= 1 (length threads)))
        (should (= 3 (length comments)))
        (should (equal "> It should be done within the hour.\n\nThen I wait." (plist-get (nth 2 comments) :body)))
        (should (equal (plist-get (nth 1 comments) :id) (plist-get (nth 2 comments) :reply-to)))
        (should (equal "open" (plist-get (car threads) :status)))
        (should (equal '("closed" "open") (mapcar (lambda (e) (plist-get e :status))
                                                (plist-get (car threads) :history)))))
      ;; A reference to the user's own reply in the thread follows it too.
      (let* ((user (harness-call 'session/append sid (list :kind 'user :content (plist-get first :text)
                                                           :blocks (list first))))
             (blocks (harness-patch-review-test--sends
                      id (harness-thread-block
                          (list :refs (list (list :kind "chat" :node (plist-get user :id) :who "you" :text "Since when?")))
                          "I meant the other one."))))
        (should (equal thread (plist-get (plist-get (car blocks) :thread) :id)))
        (should (= 4 (length (plist-get (car (harness-patch-review-test--threads id)) :comments)))))
      ;; A plain message of the agent's is a new thread.
      (let ((merged (harness-patch-review-test--agent-says id "Merged.")))
        (should (harness-thread-marker-ids
                 (plist-get (car (harness-patch-review-test--sends
                                  id (harness-patch-review-test--reply merged "Thanks")))
                            :text)))
        (should (= 2 (length (harness-patch-review-test--threads id))))))))

(ert-deftest harness-patch-review-makes-a-reply-a-thread-once ()
  "A reply that has its thread already is not made one again: the same blocks
passed through the filters twice make nothing more.  A reply put back into the
box and sent again, its response changed, edits its comment instead of making
another."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (agent (harness-patch-review-test--agent-says id "Rolled back."))
           (blocks (harness-patch-review-test--sends id (harness-patch-review-test--reply agent "Why?"))))
      (should (string-search "[thread t-" (plist-get (car blocks) :text)))
      (should (equal blocks (apply #'harness-patch-review-test--sends id blocks)))
      (should (= 1 (length (harness-patch-review-test--threads id))))
      ;; Put back, the thread's id gone with the box's token and its comment kept.
      (let* ((data (plist-get (car blocks) :thread))
             (again (harness-patch-review-test--sends
                     id (harness-thread-block (cl-loop for (k v) on data by #'cddr
                                                       unless (eq k :id) append (list k v))
                                              "Why was it rolled back?"))))
        (should (equal (plist-get data :id) (plist-get (plist-get (car again) :thread) :id)))
        (let ((threads (harness-patch-review-test--threads id)))
          (should (= 1 (length threads)))
          (should (= 1 (length (plist-get (car threads) :comments))))
          (should (equal "> Rolled back.\n\nWhy was it rolled back?"
                         (plist-get (car (plist-get (car threads) :comments)) :body))))))))

(ert-deftest harness-patch-review-does-not-keep-a-thread-reply-as-feedback-twice ()
  "The words of a message that sends a task back, which are a thread already, are
not kept again as a thread on the change as a whole; what is left of them is.
The import of the words typed by hand does not make them again either."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (agent (harness-patch-review-test--agent-says id "Rolled back."))
           (blocks (harness-patch-review-test--sends
                    id (list :type "text" :text "Quick note first.")
                    (harness-patch-review-test--reply agent "Why?")))
           (text (harness-blocks-text blocks))
           (task (harness-call 'task/get id))
           (additions (harness-patch-review--additions task (harness-tasks--words blocks))))
      ;; The text of the blocks: the note, then the reply with its marker.
      (should (string-prefix-p "Quick note first.\n\n> Rolled back.\n\nWhy?\n\n[thread t-" text))
      ;; The words are the note: the reply is a thread, no words.
      (should (equal "Quick note first." (harness-tasks--words blocks)))
      (should additions)
      (funcall (cdr additions))
      (let* ((threads (harness-patch-review-test--threads id))
             (bodies (mapcar (lambda (th) (plist-get (car (plist-get th :comments)) :body)) threads)))
        (should (= 2 (length threads)))
        (should (member "Quick note first." bodies))
        (should (member "> Rolled back.\n\nWhy?" bodies)))
      ;; Only the reply: nothing of the words is left to keep.
      (let* ((blocks (harness-patch-review-test--sends id (harness-patch-review-test--reply agent "And again?")))
             (text (harness-blocks-text blocks)))
        (should (equal "" (harness-tasks--words blocks)))
        (should-not (harness-patch-review--additions (harness-call 'task/get id) (harness-tasks--words blocks)))
        ;; Typed in the session and sent back: the replies of the rounds and
        ;; of the messages are not imported a second time.
        (harness-patch-review-test--type id text)
        (harness-tasks--set id :feedback (list (list :text text :at 1.0)))
        (let ((before (length (harness-patch-review-test--threads id))))
          (should (equal '(:added 0 :edited 0 :threads nil) (harness-call 'patch-review/import-manual id)))
          (should (= before (length (harness-patch-review-test--threads id)))))))))

(defvar harness-patch-review-test--requests nil
  "The requests the scripted agent of a test was sent, newest first.")

(defun harness-patch-review-test--answers-in-threads (request)
  "The events of an agent that answers each thread its newest message is a comment in.
It calls `review_comment' once for the first thread the marker of the
message names, `Since the nightly job.' in it, and says nothing more;
a request that carries the result of the call ends the turn."
  (push request harness-patch-review-test--requests)
  (let* ((messages (plist-get request :messages))
         (last (car (last messages)))
         (continuing (cl-some (lambda (b) (equal (plist-get b :type) "tool_result")) (plist-get last :content)))
         (ids (harness-thread-marker-ids (harness-provider-demo--last-user-text request))))
    (if (or continuing (null ids))
        '((:type text :delta "Done.") (:type done :stop-reason end-turn))
      `((:type tool-call :id "toolu_demo_rc" :name "review_comment"
               :input (:thread ,(car ids) :body "Since the nightly job.\n\nIt waits for the migration."))
        (:type done :stop-reason tool-use)))))

(ert-deftest harness-patch-review-the-agent-answers-a-reply-in-its-thread ()
  "A reply with a thread's data sent to the session of a task is a comment in a
thread, which the agent answers with review_comment, the thread's marker in
what it read and no note to answer inline; what the answer returned is kept
on its node, for the chat; and a reply that refers to that answer is a comment
in the same thread."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (sid (plist-get (harness-call 'task/get id) :session))
           (harness-provider-demo-script-override #'harness-patch-review-test--answers-in-threads)
           (agent (harness-patch-review-test--agent-says id "The build is green. The deploy is pending.")))
      (setq harness-patch-review-test--requests nil)
      (harness-test-await
       (harness-call 'agent/prompt sid (list (harness-patch-review-test--reply agent "Since when?"
                                                                              "The deploy is pending."))))
      (let* ((nodes (harness-call 'session/nodes sid))
             (user (car (last (cl-remove-if-not (lambda (n) (eq 'user (plist-get n :kind))) nodes))))
             (call (cl-find "review_comment" nodes :key (lambda (n) (plist-get n :tool)) :test #'equal))
             (result (cl-find "toolu_demo_rc" nodes :key (lambda (n) (and (eq 'tool-result (plist-get n :kind))
                                                                          (plist-get n :call-id)))
                              :test #'equal))
             (threads (harness-patch-review-test--threads id))
             (thread (plist-get (car threads) :id))
             (read (harness-provider-demo--last-user-text (car (last harness-patch-review-test--requests)))))
        ;; What the agent read: the reply, the marker, and not the note.
        (should (string-search (harness-thread-marker thread) read))
        (should (string-search "> The deploy is pending." read))
        (should-not (string-search harness-agent--inline-reply-note read))
        (should (member "review_comment" (mapcar (lambda (spec) (plist-get spec :name))
                                                 (plist-get (car (last harness-patch-review-test--requests)) :tools))))
        ;; What the transcript keeps: the thread's data with the message, and,
        ;; on the result of the call, what the chat draws it from.
        (let ((block (cl-find-if #'harness-thread-block-p (plist-get user :blocks))))
          (should block)
          (should (equal thread (plist-get (plist-get block :thread) :id)))
          (should (equal "Since when?" (harness-thread-response block))))
        (should (equal thread (plist-get (plist-get call :input) :thread)))
        (should (equal thread (plist-get (plist-get result :meta) :thread)))
        (should (equal "Since when?" (plist-get (plist-get (plist-get result :meta) :parent) :excerpt)))
        ;; What the review keeps: the user's comment and the agent's, in one thread.
        (should (= 1 (length threads)))
        (let ((comments (plist-get (car threads) :comments)))
          (should (equal '("user" "agent") (mapcar (lambda (c) (plist-get (plist-get c :author) :kind)) comments)))
          (should (equal "toolu_demo_rc" (plist-get (plist-get (cadr comments) :author) :tool-call)))
          (should (equal sid (plist-get (plist-get (cadr comments) :author) :session))))
        ;; The user refers to the answer, and replies: the same thread, the
        ;; agent answering again in it.
        (harness-test-await
         (harness-call 'agent/prompt sid
                       (list (harness-thread-block
                              (list :refs (list (list :kind "chat" :node (plist-get call :id) :who "agent"
                                                      :text "It waits for the migration.")))
                              "Then I wait."))))
        (let* ((threads (harness-patch-review-test--threads id))
               (comments (plist-get (car threads) :comments)))
          (should (= 1 (length threads)))
          (should (equal '("user" "agent" "user" "agent")
                         (mapcar (lambda (c) (plist-get (plist-get c :author) :kind)) comments)))
          (should (equal (plist-get (nth 1 comments) :id) (plist-get (nth 2 comments) :reply-to))))))))

(ert-deftest harness-patch-review-a-reply-to-a-task-in-review-is-a-thread-and-feedback ()
  "A reply with a thread's data, sent to the session of a task that waits for
review, is a thread, and still the feedback that sends the task back: the agent
reads it under the line that says so, with the marker of the thread, and the
words are not kept a second time as a thread of their own."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (sid (plist-get (harness-call 'task/get id) :session))
           (agent (harness-patch-review-test--agent-says id "Rolled back.")))
      (should (eq 'review (plist-get (harness-call 'task/get id) :state)))
      (let* ((blocks (harness-run-filter 'agent/message (list (harness-patch-review-test--reply agent "Why?"))
                                         sid '(:from nil)))
             (threads (harness-patch-review-test--threads id)))
        (should (eq 'active (plist-get (harness-call 'task/get id) :state)))
        ;; The opening goes in a block of its own: the reply keeps its text.
        (should (equal harness-tasks--reject-message (plist-get (car blocks) :text)))
        (should-not (plist-get (car blocks) :thread))
        (should (harness-thread-block-p (cadr blocks)))
        (should (string-suffix-p (harness-thread-marker (plist-get (car threads) :id)) (plist-get (cadr blocks) :text)))
        (should (= 1 (length threads)))
        (should (equal "> Rolled back.\n\nWhy?" (plist-get (car (plist-get (car threads) :comments)) :body)))
        ;; The round keeps what was sent, markers and all.
        (should (string-search "[thread t-" (plist-get (car (plist-get (harness-call 'task/get id) :feedback)) :text)))))))

(ert-deftest harness-patch-review-the-demo-agent-answers-each-thread-of-a-reply ()
  "The demo provider, which a live harness is tried out with, answers a message
that names threads with review_comment, once in each, as an agent is told to."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (sid (plist-get (harness-call 'task/get id) :session))
           (harness-provider-demo-script-override nil)
           (agent (harness-patch-review-test--agent-says id "The build is green. The deploy is pending.")))
      (harness-test-await
       (harness-call 'agent/prompt sid
                     (list (harness-patch-review-test--reply agent "Good." "The build is green.")
                           (harness-patch-review-test--reply agent "Since when?" "The deploy is pending."))))
      (let ((threads (harness-patch-review-test--threads id)))
        (should (= 2 (length threads)))
        (dolist (thread threads)
          (should (equal '("user" "agent")
                         (mapcar (lambda (c) (plist-get (plist-get c :author) :kind)) (plist-get thread :comments))))
          (should (equal "open" (plist-get thread :status)))))
      (should (= 2 (cl-count "review_comment" (harness-call 'session/nodes sid)
                             :key (lambda (n) (plist-get n :tool)) :test #'equal))))))

(ert-deftest harness-patch-review-sends-a-task-back-with-a-reply-as-one-thread ()
  "Feedback sent from the report's box, with a reply in a thread among its
attachments, makes the reply a thread once as it goes out: the round does not
keep it as a thread of its own as well, what is left of the words is, and the
import by hand makes none of the round's reply again."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (sid (plist-get (harness-call 'task/get id) :session))
           (harness-provider-demo-script-override #'harness-patch-review-test--answers-in-threads)
           (agent (harness-patch-review-test--agent-says id "The build is green. The deploy is pending.")))
      (setq harness-patch-review-test--requests nil)
      (harness-call 'task/reject id "A word first."
                    (list (list :label "reply 1" :response "Since when?"
                                :thread (list :refs (list (list :kind "chat" :node (plist-get agent :id) :who "agent"
                                                                :text "The deploy is pending."))))))
      (harness-test-wait (lambda () (eq 'review (plist-get (harness-call 'task/get id) :state)))
                         15 "the task to come back for review")
      (let* ((threads (harness-patch-review-test--threads id))
             (bodies (mapcar (lambda (th) (plist-get (car (plist-get th :comments)) :body)) threads))
             (reply (cl-find "> The deploy is pending.\n\nSince when?" threads
                             :key (lambda (th) (plist-get (car (plist-get th :comments)) :body)) :test #'equal)))
        ;; The reply once, the words around it once.
        (should (equal '("> The deploy is pending.\n\nSince when?" "A word first.")
                       (sort (copy-sequence bodies) #'string<)))
        ;; What the agent read names the thread, and it answered there.
        (should (string-search (harness-thread-marker (plist-get reply :id))
                               (harness-provider-demo--last-user-text
                                (car (last harness-patch-review-test--requests)))))
        (should (equal '("user" "agent")
                       (mapcar (lambda (c) (plist-get (plist-get c :author) :kind)) (plist-get reply :comments))))
        (should (equal sid (plist-get (plist-get (cadr (plist-get reply :comments)) :author) :session))))
      ;; The round kept the words as they were sent, quote, answer and the
      ;; marker of the thread: the import by hand makes no second thread
      ;; of the reply.
      (should (cl-some (lambda (round) (string-search "[thread t-" (plist-get round :text)))
                       (plist-get (harness-call 'task/get id) :feedback)))
      (harness-call 'patch-review/import-manual id)
      (should (= 1 (cl-count-if (lambda (th)
                                  (string-search "Since when?" (plist-get (car (plist-get th :comments)) :body)))
                                (harness-patch-review-test--threads id)))))))

(ert-deftest harness-patch-review-keeps-a-reply-waiting-for-a-slot-as-one-thread ()
  "Feedback with a reply in a thread that waits for a slot has made the thread
already: the message kept for the task's start carries its id, and goes out as
that thread, the agent answering in it, with no second thread made on the way."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (sid (plist-get (harness-call 'task/get id) :session))
           (harness-provider-demo-script-override #'harness-patch-review-test--answers-in-threads)
           (agent (harness-patch-review-test--agent-says id "The build is green. The deploy is pending.")))
      (setq harness-patch-review-test--requests nil)
      (let ((harness-tasks-max-running 0))
        (harness-call 'task/reject id ""
                      (list (list :label "reply 1" :response "Since when?"
                                  :thread (list :refs (list (list :kind "chat" :node (plist-get agent :id) :who "agent"
                                                                  :text "The deploy is pending.")))))))
      (should (eq 'pending (plist-get (harness-call 'task/get id) :state)))
      ;; Made when the feedback was given, once, and the kept message knows it.
      (let* ((threads (harness-patch-review-test--threads id))
             (queued (car (plist-get (harness-tasks--get id) :queued)))
             (att (car (plist-get queued :attachments))))
        (should (= 1 (length threads)))
        (should (equal (plist-get (car threads) :id) (plist-get (plist-get att :thread) :id)))
        (should (string-search "[thread t-" (plist-get (car (plist-get (harness-tasks--get id) :feedback)) :text)))
        (should-not harness-patch-review-test--requests))
      ;; It starts: the message goes out with the thread's marker, and the
      ;; agent answers there.
      (harness-call 'task/start id)
      (harness-test-wait (lambda ()
                           (and (eq 'review (plist-get (harness-call 'task/get id) :state))
                                (= 2 (length (plist-get (car (harness-patch-review-test--threads id)) :comments)))))
                         15 "the agent to answer in the thread and the task to come back for review")
      (let* ((threads (harness-patch-review-test--threads id))
             (thread (car threads)))
        (should (= 1 (length threads)))
        ;; The message that was kept reached the agent with the marker.
        (should (cl-some (lambda (request)
                           (string-search (harness-thread-marker (plist-get thread :id))
                                          (harness-provider-demo--last-user-text request)))
                         harness-patch-review-test--requests))
        (should (equal '("user" "agent")
                       (mapcar (lambda (c) (plist-get (plist-get c :author) :kind)) (plist-get thread :comments))))
        (should (equal sid (plist-get (plist-get (cadr (plist-get thread :comments)) :author) :session)))))))

(ert-deftest harness-patch-review-answers-a-thread-in-the-chat-with-the-meta-the-chat-draws ()
  "review_comment records what the chat draws: the thread, the comment, the
status and who wrote the comment it follows, a line of it."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (made (harness-patch-review-test--user-comment id "Since when is the deploy pending?\nAnd why?" :sent 5.0))
           (result (harness-patch-review-test--tool
                    "review_comment" (list :thread (substring (car made) 0 6) :body "Since noon." :status "closed") id))
           (meta (plist-get result :meta)))
      (should-not (plist-get result :is-error))
      (should (equal (car made) (plist-get meta :thread)))
      (should (equal "closed" (plist-get meta :status)))
      (should (stringp (plist-get meta :comment)))
      (should (equal (list :id (cdr made) :author "Noah" :kind "user" :excerpt "Since when is the deploy pending?")
                     (plist-get meta :parent)))
      ;; Only the status: no comment, and the one it follows is the last there is.
      (let ((again (plist-get (harness-patch-review-test--tool "review_comment" (list :thread (car made) :status "open") id)
                              :meta)))
        (should-not (plist-get again :comment))
        (should (equal "open" (plist-get again :status))))
      ;; A new thread follows nothing.
      (let ((fresh (plist-get (harness-patch-review-test--tool "review_comment" (list :body "A new one.") id) :meta)))
        (should-not (plist-get fresh :parent))
        (should (stringp (plist-get fresh :thread))))
      ;; A reply made in the chat starts with the quote it answers: the line
      ;; the chat shows is the answer's, or the quote's when it is all there is.
      (let* ((quoted (harness-patch-review-test--user-comment id "> The deploy is pending.\n>\n> Since noon?\n\nNo, since the nightly job." :sent 6.0))
             (only (harness-patch-review-test--user-comment id "> Just the quote, nothing under it." :sent 7.0)))
        (should (equal "No, since the nightly job."
                       (plist-get (plist-get (plist-get (harness-patch-review-test--tool
                                                         "review_comment" (list :thread (car quoted) :body "Right.") id)
                                                        :meta)
                                             :parent)
                                  :excerpt)))
        (should (equal "Just the quote, nothing under it."
                       (plist-get (plist-get (plist-get (harness-patch-review-test--tool
                                                         "review_comment" (list :thread (car only) :body "Yes.") id)
                                                        :meta)
                                             :parent)
                                  :excerpt)))))))

(provide 'harness-patch-review-test)
;;; harness-patch-review-test.el ends here
