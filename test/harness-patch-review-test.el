;;; harness-patch-review-test.el --- Tests for the threads of a task's review  -*- lexical-binding: t; -*-

;;; Commentary:

;; The harness's half of the threads of a review (harness-patch-review.el)
;; and the tools the agent answers them with (harness-tools-review.el): a
;; task's threads kept in the state directory, the operations a UI sends
;; performed once and announced, the version a hand-in makes, the drafts
;; that go with the feedback that sends the task back, the rounds of
;; feedback from before threads existed, and review_comment and
;; review_threads.  The repositories are throwaway ones, whose commits are
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

(provide 'harness-patch-review-test)
;;; harness-patch-review-test.el ends here
