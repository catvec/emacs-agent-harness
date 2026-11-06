;;; harness-patch-review-test.el --- Tests for the threads of a task's review  -*- lexical-binding: t; -*-

;;; Commentary:

;; The harness's half of the threads of a review (harness-patch-review.el),
;; the reply form in a message and its correction (harness-thread-reply.el),
;; and the tools the agent answers them with (harness-tools-review.el): a
;; task's threads kept in the state directory, the operations a UI sends
;; performed once and announced, the version a hand-in makes, the drafts
;; that go with the feedback that sends the task back, the rounds of
;; feedback from before threads existed and the words the user wrote by
;; hand outside them, the files the reviewer has viewed, and the
;; review_threads tool with the <thread> blocks the agent answers in.  The
;; repositories are throwaway ones, whose commits are
;; never signed.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)
(require 'harness-patch-review)
(require 'harness-thread-reply)
(require 'harness-tools-review)
(require 'harness-judge)

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
(defvar harness-tools-handin-require-closed-threads)
(defvar harness-tools-handin-block-functions)
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
\(TASK-ID OP) each `patch-review/changed' announced, newest first;
`last-closes' collects the (TASK-ID DRAFT) each `patch-review/last-close'
announced."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-patch-review-test--repo dir)
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent tasks acp
                          tools-handin tools-review thread-reply patch-review))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-tasks--table)
     (clrhash harness-tasks--starting)
     (clrhash harness-patch-review--sets)
     (clrhash harness-patch-review--last-close-drafts)
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
           (events nil)
           (last-closes nil))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       (harness-on 'patch-review/changed (lambda (id op) (push (list id op) events)))
       (harness-on 'patch-review/last-close (lambda (id draft) (push (list id draft) last-closes)))
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

(defun harness-patch-review-test--working-task ()
  "Submit a task whose first turn only talks, leaving it at work; return its id.
It is active in the working phase, with branch task/fix.  The turn after it
runs the script the test bound, not this one."
  (let* ((harness-provider-demo-script-override
          '((:type text :delta "One thing first: which parser?\n")
            (:type done :stop-reason end-turn)))
         (id (plist-get (harness-call 'task/submit default-directory "Fix the flaky test") :id)))
    (harness-test-wait
     (lambda ()
       (let ((task (harness-call 'task/get id)))
         (and (eq 'active (plist-get task :state))
              (equal "working" (plist-get task :phase))
              (eq 'conversing (plist-get task :outcome)))))
     15 "the task to be left at work")
    (harness-tasks--set id :branch "task/fix" :base "main" :project default-directory)
    id))

(defun harness-patch-review-test--spin (&optional seconds)
  "Run timers and process output for SECONDS, so a wake would show."
  (let ((end (+ (float-time) (or seconds 0.2))))
    (while (< (float-time) end)
      (accept-process-output nil 0.01)
      (sit-for 0.005))))

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

(defun harness-patch-review-test--say (session-id text)
  "Append TEXT as an assistant message of SESSION-ID; return its node id."
  (plist-get (harness-call 'session/append session-id
                           (list :kind 'assistant :content text))
             :id))

(defconst harness-patch-review-test--a18
  '(:file "a.el" :line 18 :excerpt "@@ -15,4 +15,4 @@\n (setq a15 15)\n (setq a16 16)\n (setq a17 17)\n-(setq a18 18)\n+(setq a18 'eighteen)")
  "The location of a comment on line 18 of a.el, as data.")

;;;; Keeping the threads

(ert-deftest harness-patch-review-keeps-the-media-a-reply-names ()
  "The pictures and videos whose tokens are in a reply's words go with it.
One attached to the message's own words, or named nowhere, stays out."
  (let* ((image (list :type "image" :path "/tmp/shot.png" :mime "image/png"
                      :label "image 1"))
         (other (list :type "image" :path "/tmp/other.png" :mime "image/png"
                      :label "image 2"))
         (video (list :type "file" :path "/tmp/clip.mp4" :mime "video/mp4"
                      :name "clip.mp4"))
         (unused (list :type "image" :path "/tmp/unused.png" :mime "image/png"
                       :label "image 3")))
    (should (equal (list (list :path "/tmp/shot.png" :mime "image/png"
                               :name "shot.png" :size nil)
                         (list :path "/tmp/clip.mp4" :mime "video/mp4"
                               :name "clip.mp4" :size nil))
                   (harness-patch-review--media-of-reply
                    (list image other video unused)
                    "See [image 1] and @clip.mp4, not the other.")))
    ;; The message's own words name image 2, the reply's do not.
    (should (equal (list (list :path "/tmp/shot.png" :mime "image/png"
                               :name "shot.png" :size nil))
                   (harness-patch-review--media-of-reply
                    (list image other) "Only [image 1] here.")))
    (should-not (harness-patch-review--media-of-reply (list image other) nil))))

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

(ert-deftest harness-thread-reply-a-user-block-in-a-message-is-a-reply ()
  "A <thread> block the user writes in a message is a reply in that thread.
It becomes a thread block, the prose around it stays, and the comment is
a draft until the feedback sends the task back; a block naming no thread
starts one."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (made (harness-patch-review-test--user-comment id "Why two?"))
           (thread (car made))
           (blocks (harness-patch-review-test--sends
                    id
                    (list :type "text"
                          :text (format "Before.\n\n<thread id=\"%s\">\n<quote>Why two?</quote>\nBecause.\n</thread>\n\nAfter."
                                        thread)))))
      (should (= 3 (length blocks)))
      (should (equal "Before." (plist-get (car blocks) :text)))
      (should (harness-thread-block-p (cadr blocks)))
      (should (equal "After." (plist-get (caddr blocks) :text)))
      (let* ((threads (harness-patch-review-test--threads id))
             (comment (car (last (plist-get (car threads) :comments)))))
        (should (= 2 (length (plist-get (car threads) :comments))))
        (should (equal "> Why two?\n\nBecause." (plist-get comment :body)))
        (should (equal "user" (plist-get (plist-get comment :author) :kind)))
        ;; A draft until the feedback that sends the task back.
        (should-not (plist-get comment :sent))
        (should (equal thread (plist-get (plist-get (cadr blocks) :thread) :id))))
      ;; A block that names no thread starts one.
      (let ((new-blocks (harness-patch-review-test--sends
                         id
                         (list :type "text"
                               :text "<thread>\n<quote>The deploy is pending.</quote>\nWatch it.\n</thread>"))))
        (should (harness-thread-block-p (car new-blocks)))
        (let* ((threads (harness-patch-review-test--threads id))
               (new (car (last threads)))
               (comment (car (plist-get new :comments))))
          (should (= 2 (length threads)))
          (should (equal "open" (plist-get new :status)))
          (should (equal "> The deploy is pending.\n\nWatch it." (plist-get comment :body)))
          (should (equal (plist-get new :id) (plist-get (plist-get (car new-blocks) :thread) :id))))))))

(ert-deftest harness-thread-reply-an-agent-block-in-a-message-is-a-comment ()
  "An agent's <thread> block in its message is its comment in that thread.
The message stays as the agent wrote it -- the chat draws its blocks --
and a block that says status=\"closed\" closes the thread."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (made (harness-patch-review-test--user-comment id "Why two?"))
           (thread (car made))
           (sid (plist-get (harness-call 'task/get id) :session))
           (text (format "Answering.\n\n<thread id=\"%s\">\n<quote>Why two?</quote>\nBecause the loop needs it.\n</thread>\n"
                         thread)))
      ;; The filter is what the agent runs on its final message.
      (should (equal text (harness-run-filter 'agent/assistant-message text sid "n-answer")))
      (let* ((threads (harness-patch-review-test--threads id))
             (comments (plist-get (car threads) :comments))
             (answer (car (last comments))))
        (should (= 2 (length comments)))
        (should (equal "> Why two?\n\nBecause the loop needs it." (plist-get answer :body)))
        (should (equal "agent" (plist-get (plist-get answer :author) :kind)))
        (should (equal sid (plist-get (plist-get answer :author) :session))))
      ;; Closing it in the block closes the thread, with the words kept.
      (harness-thread-reply--on-assistant-message
       (format "<thread id=\"%s\" status=\"closed\">\n<quote>Why two?</quote>\nDone.\n</thread>" thread)
       sid "n-answer-2")
      (let* ((threads (harness-patch-review-test--threads id))
             (comments (plist-get (car threads) :comments)))
        (should (equal "closed" (plist-get (car threads) :status)))
        (should (equal "> Why two?\n\nDone." (plist-get (car (last comments)) :body)))))))

(defun harness-patch-review-test--turn-message (id text)
  "Append a message TEXT the agent says to task ID's session; return its node."
  (harness-call 'session/append
                (plist-get (harness-call 'task/get id) :session)
                (list :kind 'assistant :content text)))

(defun harness-patch-review-test--turn-begins (id text)
  "Append a message TEXT of the user's to task ID's session; return its node."
  (harness-call 'session/append
                (plist-get (harness-call 'task/get id) :session)
                (list :kind 'user :content text)))

(defun harness-patch-review-test--thread-block (thread body &optional status quote)
  "Return a <thread> block for THREAD with BODY, STATUS and QUOTE.
THREAD nil starts a new thread; STATUS closes or opens it; QUOTE is what
the block answers, when there is one."
  (format "<thread%s%s>\n%s%s\n</thread>"
          (if (and (stringp thread) (not (string-empty-p thread)))
              (format " id=\"%s\"" thread)
            "")
          (if (and (stringp status) (not (string-empty-p status)))
              (format " status=\"%s\"" status)
            "")
          (if (and (stringp quote) (not (string-empty-p quote)))
              (format "<quote>%s</quote>\n" quote)
            "")
          body))

(defun harness-patch-review-test--agent-answers (id text)
  "Append TEXT, the agent's message, to task ID's session, and pass it to the review.
Return the node the message is.  This is what the `agent/assistant-message'
filter does with the agent's final words."
  (let* ((node (harness-patch-review-test--turn-message id text))
         (sid (plist-get (harness-call 'task/get id) :session)))
    (harness-thread-reply--on-assistant-message text sid (plist-get node :id))
    node))

(ert-deftest harness-patch-review-the-reply-tool-is-gone ()
  "An agent answers a thread in a <thread> block, and there is no reply tool.
The task's session is offered review_threads, which only reads, and
nothing that writes a comment."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (task-session (harness-call 'session/get (plist-get (harness-call 'task/get id) :session)))
           (names (mapcar (lambda (spec) (plist-get spec :name))
                          (harness-call 'tools/list (plist-get task-session :id)))))
      (should-not (harness-call 'tools/get "review_comment"))
      (should (harness-call 'tools/get "review_threads"))
      (should (member "review_threads" names))
      (should-not (member "review_comment" names)))))

(ert-deftest harness-patch-review-keeps-two-replies-in-a-thread ()
  "An agent may say two things in one thread, or three: every <thread> block is a
comment, and all of them are kept in the order the agent wrote them.  A block
with words makes a comment; one with no words but status=\"closed\" only
closes the thread."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (made (harness-patch-review-test--user-comment id "Why two?" :sent 5.0))
           (thread (car made)))
      (harness-patch-review-test--turn-begins id "Please answer the thread.")
      ;; Two blocks in one message, in the same thread: two comments.
      (harness-patch-review-test--agent-answers
       id (concat (harness-patch-review-test--thread-block thread "Because the loop needs it.")
                  "\n\n"
                  (harness-patch-review-test--thread-block thread "And for the cache.")))
      (let ((comments (plist-get (harness-patch-review-test--thread id thread) :comments)))
        (should (= 3 (length comments)))
        (should (equal '("Why two?" "Because the loop needs it." "And for the cache.")
                       (mapcar (lambda (comment) (plist-get comment :body)) comments))))
      ;; Another block of the next message of the turn: a third reply.
      (harness-patch-review-test--agent-answers
       id (harness-patch-review-test--thread-block thread "And a third thing."))
      (should (= 4 (length (plist-get (harness-patch-review-test--thread id thread) :comments))))
      ;; Closing it needs no words: the block says so.
      (harness-patch-review-test--agent-answers
       id (harness-patch-review-test--thread-block thread "" "closed"))
      (let ((th (harness-patch-review-test--thread id thread)))
        (should (= 4 (length (plist-get th :comments))))
        (should (equal "closed" (plist-get th :status)))))))

(ert-deftest harness-patch-review-refuses-hand-in-while-a-thread-is-open ()
  "A sent thread that is still open refuses hand_in, naming the thread.
Closing it lets the work in.  A draft is no thread yet, the custom turns
the check off, and a harness that did not load the module adds no check."
  (harness-patch-review-test-with
    (cl-flet ((hand-in (sid)
                (harness-test-await
                 (harness-call-async 'tools/execute sid
                                     (list :id "h-gate" :name "hand_in"
                                           :input (list :problem "The tests pass"
                                                        :summary "Done."
                                                        :evidence '("a note"))))))
              (open-thread (id text)
                (car (harness-patch-review-test--user-comment id text :sent (float-time)))))
      (let* ((id (harness-patch-review-test--task))
             (sid (plist-get (harness-call 'task/get id) :session))
             (thread (open-thread id "Why eighteen?")))
        (let ((result (hand-in sid)))
          (should (plist-get result :is-error))
          (should-not (plist-get result :end-turn))
          (should (string-match-p thread (plist-get result :content)))
          (should (string-match-p "still open" (plist-get result :content)))
          ;; The refusal says what the threads are: the user's questions,
          ;; not a check to get past, and never closed in a batch.
          (should (string-match-p "the user's questions" (plist-get result :content)))
          (should (string-match-p "never in a batch" (plist-get result :content)))
          (should (string-match-p "Then call hand_in" (plist-get result :content))))
        ;; Nothing was recorded: the report of the hand-in that made the
        ;; review stands, and the task still waits for it.
        (should (eq 'review (plist-get (harness-call 'task/get id) :state)))
        (should (equal "Done: fixed." (plist-get (plist-get (harness-call 'task/get id) :report) :summary)))
        ;; Closed, the same hand-in goes through.
        (harness-call 'patch-review/apply id (list :op "set-status" :thread thread :status "closed"
                                                   :id "s-gate" :time 5
                                                   :author '(:kind "user" :name "Noah")))
        (let ((result (hand-in sid)))
          (should-not (plist-get result :is-error))
          (should (plist-get result :end-turn))
          (should (equal "Done." (plist-get (plist-get (harness-call 'task/get id) :report) :summary)))))
      ;; A draft is no thread the agent has to answer yet.
      (let* ((id (harness-patch-review-test--task))
             (sid (plist-get (harness-call 'task/get id) :session)))
        (harness-patch-review-test--user-comment id "Not sent yet")
        (let ((result (hand-in sid)))
          (should-not (plist-get result :is-error))))
      ;; Turned off, the open thread gates nothing.
      (let* ((id (harness-patch-review-test--task))
             (sid (plist-get (harness-call 'task/get id) :session))
             (harness-tools-handin-require-closed-threads nil))
        (open-thread id "Still open, but allowed")
        (let ((result (hand-in sid)))
          (should-not (plist-get result :is-error))))
      ;; Without the module's check, a harness has no gate at all.
      (let* ((id (harness-patch-review-test--task))
             (sid (plist-get (harness-call 'task/get id) :session)))
        (open-thread id "Open, and no module to care")
        (remove-hook 'harness-tools-handin-block-functions #'harness-patch-review--hand-in-blocker)
        (let ((result (hand-in sid)))
          (should-not (plist-get result :is-error)))))))

(ert-deftest harness-patch-review-the-last-close-offers-a-message-for-the-user-to-send ()
  "The user closing the last open thread of a task at work leaves the
harness's message as a draft: no turn starts until the user sends the
drafts, and sending them sends it by itself, which starts the turn that
hands in.  The message says what changed, not to hand in."
  (harness-patch-review-test-with
    (let ((harness-tasks-working-phase t))
      (let* ((id (harness-patch-review-test--working-task))
             (sid (plist-get (harness-call 'task/get id) :session))
             (thread (car (harness-patch-review-test--user-comment id "Why eighteen?" :sent 5.0))))
        ;; Its turn ended talking to the user: the task waits for their
        ;; reply, and its session says so (`blocked'), with no request
        ;; pending (`harness-tasks--sync-reply-block').
        (should (eq 'blocked (plist-get (harness-call 'session/get sid) :status)))
        (should-not (plist-get (harness-call 'session/get sid) :pending))
        (should (harness-session-waiting-on-user-p (harness-call 'session/get sid)))
        (should (plist-get (harness-call 'patch-review/apply id
                                         (list :op "set-status" :thread thread :status "closed"
                                               :id "s-last" :time 6.0
                                               :author '(:kind "user" :name "Noah")))
                           :changed))
        ;; The message waits for the user: nothing is sent, no turn starts.
        (harness-patch-review-test--spin)
        (should (eq 'active (plist-get (harness-call 'task/get id) :state)))
        (should (eq 'blocked (plist-get (harness-call 'session/get sid) :status)))
        (should-not (cl-find-if (lambda (node)
                                  (equal harness-patch-review-last-close-message
                                         (plist-get node :content)))
                                (harness-call 'session/nodes sid)))
        (let* ((draft (harness-call 'patch-review/last-close id))
               (from (plist-get draft :from)))
          (should draft)
          (should (equal harness-patch-review-last-close-message (plist-get draft :text)))
          (should (equal id (plist-get draft :task)))
          (should (equal sid (plist-get draft :session)))
          (should (eq 'system (harness-sender-kind from)))
          (should (equal "review" (plist-get from :source)))
          ;; What changed, not what to do: the task's prompt says to hand in.
          (should-not (string-match-p "hand_in\\|hand in"
                                      harness-patch-review-last-close-message))
          ;; The UI heard it wait, and not go.
          (should (equal (list id draft) (car last-closes))))
        ;; The user sends the drafts -- there is only the message -- and
        ;; the turn that hands in runs.
        (should (equal (list :sent 0 :last-close t)
                       (harness-call 'patch-review/send-replies id)))
        (should-not (harness-call 'patch-review/last-close id))
        (should (equal (list id nil) (car last-closes)))
        (harness-test-wait (lambda () (eq 'review (plist-get (harness-call 'task/get id) :state)))
                           15 "the agent to hand in after the last close")
        (let* ((node (cl-find-if (lambda (node)
                                   (equal harness-patch-review-last-close-message
                                          (plist-get node :content)))
                                 (harness-call 'session/nodes sid)))
               (sender (and node (harness-node-sender node))))
          (should node)
          (should (eq 'system (harness-sender-kind sender)))
          (should (equal "review" (plist-get sender :source))))))))

(ert-deftest harness-patch-review-the-last-close-goes-with-the-replies ()
  "The message of the last close is one of the drafts: one send sends the
replies together, then the message as the harness's own, and neither
waits afterwards."
  (harness-patch-review-test-with
    (let ((harness-tasks-working-phase t))
      (let* ((id (harness-patch-review-test--working-task))
             (sid (plist-get (harness-call 'task/get id) :session))
             (thread (car (harness-patch-review-test--user-comment id "Why eighteen?" :sent 5.0))))
        ;; A reply waits in the thread, and the user closes it: the reply
        ;; and the harness's message wait together.
        (harness-patch-review-test--user-comment id "Because the loop counts from one." :thread thread)
        (harness-call 'patch-review/apply id
                      (list :op "set-status" :thread thread :status "closed"
                            :id "s-both" :time 6.0 :author '(:kind "user" :name "Noah")))
        (should (harness-call 'patch-review/last-close id))
        (should (= 1 (length (harness-call 'patch-review/drafts id))))
        (should (equal (list :sent 1 :last-close t)
                       (harness-call 'patch-review/send-replies id)))
        ;; Both went, and no draft waits.
        (should-not (harness-call 'patch-review/last-close id))
        (should-not (harness-call 'patch-review/drafts id))
        (harness-test-wait
         (lambda ()
           (cl-some (lambda (node)
                      (equal harness-patch-review-last-close-message
                             (plist-get node :content)))
                    (harness-call 'session/nodes sid)))
         15 "the harness's message to reach the session")
        (let* ((nodes (harness-call 'session/nodes sid))
               (replies (cl-find-if (lambda (node)
                                      (and (eq 'user (plist-get node :kind))
                                           (cl-some #'harness-thread-block-p
                                                    (plist-get node :blocks))))
                                    nodes))
               (close (cl-find-if (lambda (node)
                                    (equal harness-patch-review-last-close-message
                                           (plist-get node :content)))
                                  nodes))
               (reply (cl-find-if #'harness-thread-block-p
                                  (plist-get replies :blocks))))
          ;; The replies went first, as the user's one message, each in
          ;; its thread.
          (should (equal "I wrote replies in the threads of the review of your work. Answer each in its thread with a <thread id=\"THREAD_ID\"> block in your message."
                         (plist-get (car (plist-get replies :blocks)) :text)))
          (should (equal "Because the loop counts from one." (harness-thread-response reply)))
          (should (equal thread (plist-get (plist-get reply :thread) :id)))
          (should-not (harness-node-sender replies))
          ;; And then the harness's message, from "review".
          (should (eq 'system (harness-sender-kind (harness-node-sender close))))
          (should (equal "review" (plist-get (harness-node-sender close) :source)))
          (should (< (cl-position replies nodes :test #'equal)
                     (cl-position close nodes :test #'equal))))))))

(ert-deftest harness-patch-review-sending-a-new-open-thread-drops-the-last-close ()
  "A new thread is only a draft until the batch is sent.  Once sent, it
is an open question, so the earlier last-close message must not go."
  (harness-patch-review-test-with
    (let ((harness-tasks-working-phase t))
      (let* ((id (harness-patch-review-test--working-task))
             (thread (car (harness-patch-review-test--user-comment id "Why eighteen?" :sent 5.0)))
             sent)
        (harness-call 'patch-review/apply id
                      (list :op "set-status" :thread thread :status "closed"
                            :id "s-new-draft" :time 6.0 :author '(:kind "user" :name "Noah")))
        (harness-patch-review-test--user-comment id "One more question, on a new thread.")
        (should (harness-call 'patch-review/last-close id))
        (cl-letf (((symbol-function 'harness-method/agent/prompt)
                   (lambda (_session blocks &optional opts)
                     (push (list blocks opts) sent)
                     (harness-resolved nil))))
          (should (equal (list :sent 1 :last-close nil)
                         (harness-call 'patch-review/send-replies id))))
        (should (= 1 (length sent)))
        (should-not (plist-get (cadar sent) :from))
        (should-not (harness-call 'patch-review/last-close id))
        (should (equal (list id nil) (car last-closes)))
        (should (= 1 (length (harness-call 'patch-review/open-threads id))))))))

(ert-deftest harness-patch-review-a-new-chat-thread-drops-the-last-close ()
  "Sending a new thread from the chat makes the last-close message stale
and tells the UI immediately, without another read of the message."
  (harness-patch-review-test-with
    (let ((harness-tasks-working-phase t))
      (let* ((id (harness-patch-review-test--working-task))
             (sid (plist-get (harness-call 'task/get id) :session))
             (thread (car (harness-patch-review-test--user-comment id "Why eighteen?" :sent 5.0)))
             (harness-provider-demo-script-override
              '((:type text :delta "I will look at the other question.")
                (:type done :stop-reason end-turn))))
        (harness-call 'patch-review/apply id
                      (list :op "set-status" :thread thread :status "closed"
                            :id "s-new-chat" :time 6.0 :author '(:kind "user" :name "Noah")))
        (should (harness-call 'patch-review/last-close id))
        (harness-test-await
         (harness-call 'agent/prompt sid
                       (list (harness-thread-block (list :response "One more question.")))))
        ;; The event came without an explicit last-close read to clean up.
        (should (equal (list id nil) (car last-closes)))
        (should-not (gethash id harness-patch-review--last-close-drafts))
        (should-not (harness-call 'patch-review/last-close id))))))

(ert-deftest harness-patch-review-a-failed-last-close-send-keeps-the-draft ()
  "A rejected prompt must not consume the unsent last-close draft."
  (harness-patch-review-test-with
    (let ((harness-tasks-working-phase t))
      (let* ((id (harness-patch-review-test--working-task))
             (thread (car (harness-patch-review-test--user-comment id "Why eighteen?" :sent 5.0))))
        (harness-call 'patch-review/apply id
                      (list :op "set-status" :thread thread :status "closed"
                            :id "s-failed" :time 6.0 :author '(:kind "user" :name "Noah")))
        (let ((draft (harness-call 'patch-review/last-close id)))
          (cl-letf (((symbol-function 'harness-method/agent/prompt)
                     (lambda (&rest _) (signal 'harness-error '("Not sent")))))
            (should-error (harness-call 'patch-review/send-replies id) :type 'harness-error))
          (should (equal draft (harness-call 'patch-review/last-close id))))))))

(ert-deftest harness-patch-review-only-the-last-close-offers-a-message ()
  "A close that leaves a sent thread open, the agent's own close and a
thread of drafts offer no message; the user's last close of a task at
work does, and opening a thread again takes it away."
  (harness-patch-review-test-with
    (let ((harness-tasks-working-phase t))
      (let* ((id (harness-patch-review-test--working-task))
             (first (car (harness-patch-review-test--user-comment id "Why one?" :sent 5.0)))
             (second (car (harness-patch-review-test--user-comment id "Why two?" :sent 5.0))))
        ;; One sent thread is still open: nothing to tell the user yet.
        (harness-call 'patch-review/apply id
                      (list :op "set-status" :thread first :status "closed"
                            :id "s-first" :time 6.0 :author '(:kind "user" :name "Noah")))
        (should-not (harness-call 'patch-review/last-close id))
        (should-not (cl-some #'cadr last-closes))
        ;; The last one: the message waits.
        (harness-call 'patch-review/apply id
                      (list :op "set-status" :thread second :status "closed"
                            :id "s-second" :time 7.0 :author '(:kind "user" :name "Noah")))
        (let ((draft (harness-call 'patch-review/last-close id)))
          (should draft)
          (should (equal (list id draft) (car last-closes))))
        ;; Opening a thread again gives the review something to answer:
        ;; the message no longer says what it said.
        (harness-call 'patch-review/apply id
                      (list :op "set-status" :thread first :status "open"
                            :id "s-open" :time 8.0 :author '(:kind "user" :name "Noah")))
        (should-not (harness-call 'patch-review/last-close id))
        (should (equal (list id nil) (car last-closes)))
        ;; Closed again: the message waits again, a new draft.
        (harness-call 'patch-review/apply id
                      (list :op "set-status" :thread first :status "closed"
                            :id "s-first-again" :time 9.0 :author '(:kind "user" :name "Noah")))
        (should (harness-call 'patch-review/last-close id))
        ;; The agent closing a thread itself offers no message.
        (harness-call 'patch-review/discard-last-close id)
        (harness-call 'patch-review/apply id
                      (list :op "set-status" :thread first :status "open"
                            :id "s-open-2" :time 10.0 :author '(:kind "user" :name "Noah")))
        (harness-call 'patch-review/apply id
                      (list :op "set-status" :thread first :status "closed"
                            :id "s-agent" :time 11.0 :author '(:kind "agent" :name "Claude")))
        (should-not (harness-call 'patch-review/last-close id))
        ;; A thread of drafts was no question the work had to answer.
        (let ((draft (car (harness-patch-review-test--user-comment id "Still writing this"))))
          (harness-call 'patch-review/apply id
                        (list :op "set-status" :thread draft :status "closed"
                              :id "s-draft" :time 12.0 :author '(:kind "user" :name "Noah"))))
        (should-not (harness-call 'patch-review/last-close id))))))

(ert-deftest harness-patch-review-a-close-in-review-offers-no-message ()
  "A task waiting for review needs no turn when its threads are closed: the
last close there offers no message to send."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (thread (car (harness-patch-review-test--user-comment id "Why eighteen?" :sent 5.0))))
      (harness-call 'patch-review/apply id
                    (list :op "set-status" :thread thread :status "closed"
                          :id "s-review" :time 6.0 :author '(:kind "user" :name "Noah")))
      (should-not (harness-call 'patch-review/last-close id))
      (should-not (cl-remove-if-not #'cadr last-closes)))))

(ert-deftest harness-patch-review-the-last-close-offers-a-message-only-when-asked ()
  "With `harness-patch-review-draft-on-last-close' off, the last close of a
task at work offers no message."
  (harness-patch-review-test-with
    (let ((harness-tasks-working-phase t)
          (harness-patch-review-draft-on-last-close nil))
      (let* ((id (harness-patch-review-test--working-task))
             (thread (car (harness-patch-review-test--user-comment id "Why eighteen?" :sent 5.0))))
        (harness-call 'patch-review/apply id
                      (list :op "set-status" :thread thread :status "closed"
                            :id "s-off" :time 6.0 :author '(:kind "user" :name "Noah")))
        (should-not (harness-call 'patch-review/last-close id))
        (should-not (cl-remove-if-not #'cadr last-closes))))))

(ert-deftest harness-patch-review-the-last-close-message-can-be-dropped ()
  "The user drops the message of the last close: it goes unsent, and the
harness has none left to give."
  (harness-patch-review-test-with
    (let ((harness-tasks-working-phase t))
      (let* ((id (harness-patch-review-test--working-task))
             (thread (car (harness-patch-review-test--user-comment id "Why eighteen?" :sent 5.0))))
        (harness-call 'patch-review/apply id
                      (list :op "set-status" :thread thread :status "closed"
                            :id "s-drop" :time 6.0 :author '(:kind "user" :name "Noah")))
        (should (harness-call 'patch-review/last-close id))
        (should (plist-get (harness-call 'patch-review/discard-last-close id) :discarded))
        (should-not (harness-call 'patch-review/last-close id))
        (should-not (plist-get (harness-call 'patch-review/discard-last-close id) :discarded))
        (should (equal (list id nil) (car last-closes)))
        ;; And nothing was sent: the agent still waits.
        (should (eq 'active (plist-get (harness-call 'task/get id) :state)))
        (should-not (cl-find-if (lambda (node)
                                  (equal harness-patch-review-last-close-message
                                         (plist-get node :content)))
                                (harness-call 'session/nodes
                                              (plist-get (harness-call 'task/get id) :session))))))))

(ert-deftest harness-patch-review-a-last-close-message-survives-a-reload ()
  "The draft of the last close is kept in the state directory.
A harness that reloads while the user has not sent it has it still,
and sending the drafts sends it."
  (harness-patch-review-test-with
    (let ((harness-tasks-working-phase t))
      (let* ((id (harness-patch-review-test--working-task))
             (thread (car (harness-patch-review-test--user-comment id "Why eighteen?" :sent 5.0))))
        (harness-call 'patch-review/apply id
                      (list :op "set-status" :thread thread :status "closed"
                            :id "s-keep" :time 6.0 :author '(:kind "user" :name "Noah")))
        (let ((draft (harness-call 'patch-review/last-close id)))
          (should draft)
          ;; A reload forgets the table, not the message.
          (clrhash harness-patch-review--last-close-drafts)
          (should (equal draft (harness-call 'patch-review/last-close id)))
          ;; And it goes, once, from what was kept.
          (clrhash harness-patch-review--last-close-drafts)
          (should (equal (list :sent 0 :last-close t)
                         (harness-call 'patch-review/send-replies id)))
          (should-not (harness-call 'patch-review/last-close id))
          (harness-test-wait
           (lambda () (eq 'review (plist-get (harness-call 'task/get id) :state)))
           15 "the agent to hand in after the message was sent"))))))

(ert-deftest harness-patch-review-a-sent-last-close-needs-a-draft-to-send ()
  "With the message gone and no reply waiting, sending the drafts signals,
and nothing reaches the agent."
  (harness-patch-review-test-with
    (let ((harness-tasks-working-phase t))
      (let* ((id (harness-patch-review-test--working-task))
             (thread (car (harness-patch-review-test--user-comment id "Why eighteen?" :sent 5.0))))
        (harness-call 'patch-review/apply id
                      (list :op "set-status" :thread thread :status "closed"
                            :id "s-none" :time 6.0 :author '(:kind "user" :name "Noah")))
        (harness-call 'patch-review/discard-last-close id)
        (should-error (harness-call 'patch-review/send-replies id) :type 'harness-error)
        (should-not (cl-find-if (lambda (node)
                                  (equal harness-patch-review-last-close-message
                                         (plist-get node :content)))
                                (harness-call 'session/nodes
                                              (plist-get (harness-call 'task/get id) :session))))))))

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
    (harness-patch-review-test--agent-answers
     id (harness-patch-review-test--thread-block (car made) "Because the loop needs it." "closed"))
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
      (harness-patch-review-test--agent-answers
       id (harness-patch-review-test--thread-block thread-id "" "open"))
      (harness-patch-review-test--agent-answers
       id (harness-patch-review-test--thread-block thread-id "Again, properly." "closed"))
      (let ((history (harness-patch-review-test--history id thread-id)))
        (should (equal '("closed" "open" "closed") (mapcar (lambda (e) (plist-get e :status)) history)))
        (should (= 79.0 (plist-get (car history) :reviewed)))
        (should-not (plist-get (car (last history)) :reviewed))
        (should (equal "agent" (plist-get (plist-get (car (last history)) :author) :kind))))
      ;; A mark meant for a thread that is not there is an error, not a guess.
      (should-error (harness-call 'patch-review/apply id (list :op "mark-reviewed" :thread "t-nope"))
                    :type 'change-review-error))))

(ert-deftest harness-patch-review-tells-the-agent-the-user-looks-at-what-it-closes ()
  "The agent reads, with the feedback and in its working-phase prompt, that
the user looks at every thread it closes, so it says what it changed and where."
  (harness-patch-review-test-with
    (let ((id (harness-patch-review-test--task)))
      ;; A draft to send: the feedback quotes it, after the line that says how to answer.
      (harness-patch-review-test--user-comment id "Why eighteen?"
                                               :location harness-patch-review-test--a18)
      (should (string-search "I look at every thread you close, so say in your answer what you changed and where."
                             (car (harness-patch-review--additions (harness-call 'task/get id) nil))))
      (should (string-search "The user looks at every thread you close"
                             (let ((harness-tasks-working-phase t))
                               (harness-run-filter
                                'agent/system-prompt "Base."
                                (harness-call 'session/get (plist-get (harness-call 'task/get id) :session)))))))))

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

(ert-deftest harness-patch-review-uses-the-tasks-declared-merge-base ()
  "A version's base is the branch the task named at hand-in, not the project's main.
The task's branch starts from a release branch main has moved past, so
its review diff must be read against release, and its file list holds
only the task's own change."
  (harness-patch-review-test-with
    (let ((id (harness-patch-review-test--task)))
      ;; Main moves on, release starts there and moves on too, and the
      ;; task's branch is based on release.
      (harness-patch-review-test--git dir "checkout" "-q" "main")
      (with-temp-file (expand-file-name "main.txt" dir) (insert "main\n"))
      (harness-patch-review-test--git dir "add" "main.txt")
      (harness-patch-review-test--git dir "commit" "-q" "-m" "main work")
      (harness-patch-review-test--git dir "checkout" "-q" "-b" "release")
      (with-temp-file (expand-file-name "release.txt" dir) (insert "release\n"))
      (harness-patch-review-test--git dir "add" "release.txt")
      (harness-patch-review-test--git dir "commit" "-q" "-m" "release work")
      (let ((release (string-trim (harness-patch-review-test--git dir "rev-parse" "release"))))
        (harness-patch-review-test--git dir "checkout" "-q" "task/fix")
        (harness-patch-review-test--git dir "rebase" "-q" "release")
        ;; The task hands in again, naming the branch its work belongs on.
        (harness-call 'task/hand-in id (list :summary "# Done" :problem "The flaky test"
                                             :evidence '("looks good") :merge-base "release"))
        (should (equal "release" (plist-get (harness-call 'task/get id) :base)))
        (harness-test-await (harness-patch-review--record-version (harness-call 'task/get id)))
        (let ((version (car (plist-get (harness-call 'patch-review/get id) :versions))))
          (should (equal release (plist-get version :base)))
          (should (equal "release" (plist-get (plist-get version :meta) :base-branch))))))))

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
          ;; The words are a thread of their own, whose tag the feedback names.
          (should (string-prefix-p "Nearly there.\n\n<thread id=\"t-" feedback))
          (should (string-search (concat "My review comments on your branch task/fix (at "
                                         (substring tip 0 7) ") against main (merge base ")
                                 feedback))
          (should (string-search "<thread id=\"" feedback))
          (should (string-search (concat "> diff --git a/a.el b/a.el\n> @@ -15,4 +15,4 @@\n"
                                         ">  (setq a15 15)\n>  (setq a16 16)\n>  (setq a17 17)\n"
                                         "> -(setq a18 18)\n> +(setq a18 'eighteen)\n\n"
                                         "Why eighteen?\n<thread id=\"" (car first) "\">")
                                 feedback))
          (should (string-search "<thread id=" feedback)))
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
        (should (equal '("" "Then say so in a comment." "<thread")
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
        (should (string-search "A word on the whole\n<thread id=\"" feedback))))))

(ert-deftest harness-patch-review-the-replies-of-a-working-task-go-together ()
  "In the working phase the user's replies wait as drafts and go together
when they send them: one message to the agent, each in its thread, marked
sent.  A blank draft is no reply and stays behind."
  (harness-patch-review-test-with
    (let ((harness-tasks-working-phase t))
      (let* ((id (harness-patch-review-test--task))
             (eighteen (harness-patch-review-test--user-comment
                        id "Why eighteen?" :location harness-patch-review-test--a18 :sent 10.0))
             (cache (harness-patch-review-test--user-comment id "Why the cache?" :sent 10.0))
             (sid (plist-get (harness-call 'task/get id) :session))
             sent)
        (harness-call 'task/return-to-work id)
        (should (equal "working" (plist-get (harness-call 'task/get id) :phase)))
        (harness-patch-review-test--user-comment
         id "Because the loop counts from one." :thread (car eighteen))
        (harness-patch-review-test--user-comment
         id "Because the key is minute." :thread (car cache))
        (harness-patch-review-test--user-comment id "  " :thread (car eighteen))
        ;; They are drafts: nothing went to the agent yet.
        (should (= 3 (length (harness-call 'patch-review/drafts id))))
        (should-not sent)
        (cl-letf (((symbol-function 'harness-method/agent/prompt)
                   (lambda (session blocks &optional _opts)
                     (setq sent (list session blocks))
                     (harness-resolved nil))))
          (should (equal (list :sent 2 :last-close nil)
                         (harness-call 'patch-review/send-replies id))))
        ;; One message, a block for each thread, in the order written.
        (should (equal sid (car sent)))
        (let* ((blocks (cadr sent))
               (replies (cl-remove-if-not #'harness-thread-block-p blocks)))
          (should (= 2 (length replies)))
          (should (equal (list (car eighteen) (car cache))
                         (mapcar (lambda (block) (plist-get (plist-get block :thread) :id)) replies)))
          (should (equal (list "Because the loop counts from one." "Because the key is minute.")
                         (mapcar #'harness-thread-response replies)))
          ;; Neither quotes anything: no <quote> tag is made.
          (dolist (block replies)
            (should (string-search "<thread id=" (plist-get block :text)))
            (should-not (string-search "<quote>" (plist-get block :text))))
          (should (string-search "<thread id=" (plist-get (car blocks) :text))))
        ;; The replies are sent, with the mark of the working phase.
        (let* ((thread (car (harness-patch-review-test--threads id)))
               (reply (cl-find "Because the loop counts from one."
                               (plist-get thread :comments)
                               :key (lambda (comment) (plist-get comment :body)) :test #'equal)))
          (should reply)
          (should (numberp (plist-get reply :sent)))
          (should (plist-get (plist-get reply :meta) :working)))
        ;; The blank draft is no reply, and waits.
        (let ((drafts (harness-call 'patch-review/drafts id)))
          (should (= 1 (length drafts)))
          (should (harness-string-blank-p (plist-get (car drafts) :body))))
        ;; It was the conversation, not a round of feedback.
        (should (eq 'active (plist-get (harness-call 'task/get id) :state)))
        (should-not (plist-get (harness-call 'task/get id) :feedback))))))

(ert-deftest harness-patch-review-a-quoted-reply-goes-in-a-quote-tag ()
  "A reply the user wrote under a quote of a comment, as C-c > makes it in
the review, goes to the agent as a <thread> block whose quote is the
<quote> tag: the Markdown \">\" lines it has in the review are no thread
XML.  The quote keeps the line that says whose comment it is, and the
thread data names that comment, as the review draws it."
  (harness-patch-review-test-with
    (let ((harness-tasks-working-phase t))
      (let* ((id (harness-patch-review-test--task))
             (parent (harness-patch-review-test--user-comment
                      id "Why eighteen?" :location harness-patch-review-test--a18 :sent 10.0))
             (thread (car parent))
             (ref (list :kind "comment" :who "comment" :author "Noah"
                        :thread thread :task id :file "a.el" :side "new" :line 18))
             (header (harness-thread-ref-header (append ref (list :text "Why eighteen?"))))
             (body (concat (harness-thread-quote
                            (list :refs (list (append ref (list :text "Why eighteen?")))))
                           "\n\nBecause the first pass needs one."))
             sent)
        (harness-call 'task/return-to-work id)
        (should (equal "working" (plist-get (harness-call 'task/get id) :phase)))
        ;; The reply as the review keeps it: the quote in Markdown, as a
        ;; comment is, under the line that says whose comment it answers.
        (harness-call 'patch-review/apply id
                      (list :op "add-comment" :thread thread
                            :comment (list :id "c-reply" :thread thread :body body
                                           :time (float-time) :reply-to (cdr parent)
                                           :author '(:kind "user" :name "Noah"
                                                     :email "noah@example.org"))))
        (should (string-prefix-p (concat "> " header) body))
        (cl-letf (((symbol-function 'harness-method/agent/prompt)
                   (lambda (session blocks &optional _opts)
                     (setq sent (list session blocks))
                     (harness-resolved nil))))
          (should (equal (list :sent 1 :last-close nil)
                         (harness-call 'patch-review/send-replies id))))
        (let* ((block (cl-find-if #'harness-thread-block-p (cadr sent)))
               (text (plist-get block :text)))
          ;; The quote is a <quote> tag, and no line of the XML is Markdown.
          (should (equal (format "<thread id=\"%s\">\n<quote>%s\n\nWhy eighteen?</quote>\nBecause the first pass needs one.\n</thread>"
                                 thread header)
                         text))
          (should-not (string-match-p "^>" text))
          ;; The agent reads it back as the one <thread> form: the quote in
          ;; its tag and the words under it.
          (let ((parsed (car (harness-thread-parse-blocks text))))
            (should (equal thread (plist-get parsed :id)))
            (should (string-search "Why eighteen?" (plist-get parsed :quote)))
            (should (equal "Because the first pass needs one." (plist-get parsed :body))))
          ;; The thread data names the comment answered, so the reply draws
          ;; as any reply with a quote does, in the thread it is in.
          (let ((got (car (harness-thread-refs (plist-get block :thread)))))
            (should (equal "comment" (harness-thread-ref-kind got)))
            (should (equal "Noah" (plist-get got :author)))
            (should (equal thread (plist-get got :thread)))
            (should (equal id (plist-get got :task)))
            (should (equal "a.el" (plist-get got :file)))
            (should (equal "new" (plist-get got :side)))
            (should (eql 18 (plist-get got :line)))
            (should (equal "Why eighteen?" (plist-get got :text))))
          (should (equal "Because the first pass needs one."
                         (harness-thread-response block))))
        ;; The review keeps the comment as it was written: Markdown, for a
        ;; person to read.
        (let ((reply (car (harness-call 'patch-review/drafts id))))
          (should-not reply)
          (should (string-search "Because the first pass needs one."
                                 (change-review-comment-body
                                  (cdr (change-review-find-comment
                                        (harness-patch-review--set-for id) "c-reply"))))))))))

(ert-deftest harness-patch-review-a-task-in-review-sends-no-replies ()
  "A task waiting for review has no send-replies: its drafts go with the
feedback that sends it back, and sending them as replies is an error."
  (harness-patch-review-test-with
    (let ((id (harness-patch-review-test--task)))
      (harness-patch-review-test--user-comment id "Not yet.")
      (should (harness-call 'patch-review/drafts id))
      (should-error (harness-call 'patch-review/send-replies id) :type 'harness-error)
      (should (harness-call 'patch-review/drafts id)))))

(ert-deftest harness-patch-review-sending-no-replies-is-an-error ()
  "A task at work with nothing written has no reply to send."
  (harness-patch-review-test-with
    (let ((harness-tasks-working-phase t)
          (id (harness-patch-review-test--task)))
      (harness-call 'task/return-to-work id)
      (should-error (harness-call 'patch-review/send-replies id) :type 'harness-error))))

(ert-deftest harness-patch-review-sends-the-drafts-with-a-message-to-the-session ()
  "A message the user writes in the session of a task in review is the
feedback that sends it back, and the drafts go with it."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (sid (plist-get (harness-call 'task/get id) :session)))
      (harness-patch-review-test--user-comment id "Why eighteen?" :location harness-patch-review-test--a18)
      (harness-call 'agent/prompt sid "  Also this.  ")
      (let ((feedback (plist-get (car (plist-get (harness-call 'task/get id) :feedback)) :text)))
        (should (string-prefix-p "Also this.\n\n<thread id=\"t-" feedback))
        (should (string-search "My review comments on your branch task/fix" feedback))
        (should (string-search "Why eighteen?\n<thread id=\"" feedback)))
      (should-not (harness-call 'patch-review/drafts id)))))

(ert-deftest harness-patch-review-sends-nothing-more-than-the-words-without-drafts ()
  "With no draft the feedback is the words and the marker of their thread."
  (harness-patch-review-test-with
    (let ((id (harness-patch-review-test--task)))
      (harness-call 'task/reject id "Just this.")
      (let ((feedback (plist-get (car (plist-get (harness-call 'task/get id) :feedback)) :text)))
        (should (string-match-p "\\`Just this\\.\n\n<thread id=\"t-[^\"]+\">\\'" feedback)))
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
  "A UI may call the module's methods and hears its events."
  (should (member "patch-review/" harness-acp-extension-prefixes))
  (should (memq 'patch-review/changed harness-acp--forwarded-events))
  (should (memq 'patch-review/last-close harness-acp--forwarded-events))
  (dolist (method '(patch-review/get patch-review/apply patch-review/drafts
                                     patch-review/comment patch-review/send-replies
                                     patch-review/threads-text
                                     patch-review/last-close
                                     patch-review/discard-last-close))
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

(defun harness-patch-review-test--tool (name input id &optional call-id)
  "Call the tool NAME with INPUT as the session of task ID; return its result.
CALL-ID is the id of the call, \"toolu_77\" by default."
  (let* ((task (harness-call 'task/get id))
         (tool (harness-tool-get name)))
    (harness-test-await
     (harness-resolved
      (funcall (harness-tool-handler tool) input
               (list :session-id (plist-get task :session)
                     :call-id (or call-id "toolu_77") :cwd default-directory))))))

(ert-deftest harness-patch-review-a-block-records-the-agents-comment ()
  "A <thread> block is the agent's comment in a thread: its author is the agent
and the session, the block it was written in is kept in its author's meta, it
says which revision it was made against, and status=\"closed\" closes the thread."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (sid (plist-get (harness-call 'task/get id) :session))
           (made (harness-patch-review-test--user-comment id "Why eighteen?"
                                                         :location harness-patch-review-test--a18 :sent 5.0)))
      (harness-test-await (harness-patch-review--record-version (harness-call 'task/get id)))
      (setq events nil)
      (let* ((node (harness-patch-review-test--agent-answers
                    id (harness-patch-review-test--thread-block
                        (substring (car made) 0 6) "Because the loop needs it." "closed")))
             (thread (car (plist-get (harness-call 'patch-review/get id) :threads)))
             (answer (cadr (plist-get thread :comments)))
             (author (plist-get answer :author))
             (version (car (plist-get (harness-call 'patch-review/get id) :versions))))
        (should (equal "closed" (plist-get thread :status)))
        (should (equal "Because the loop needs it." (plist-get answer :body)))
        (should (equal "agent" (plist-get author :kind)))
        (should (equal sid (plist-get author :session)))
        (should-not (plist-get author :tool-call))
        (should (equal (plist-get node :id) (plist-get (plist-get author :meta) :message)))
        (should (equal 0 (plist-get (plist-get author :meta) :block-start)))
        (should (equal (plist-get version :id) (plist-get answer :revision)))
        ;; Not a draft: the user sees it at once.
        (should (numberp (plist-get answer :sent)))
        ;; Who closed it, and when.
        (let ((entry (car (plist-get thread :history))))
          (should (equal "closed" (plist-get entry :status)))
          (should (equal sid (plist-get (plist-get entry :author) :session)))))
      ;; Announced.
      (should (equal '("add-comment" "set-status")
                     (mapcar (lambda (e) (format "%s" (plist-get (cadr e) :op))) (reverse events))))
      ;; A block with only a status changes it.
      (harness-patch-review-test--agent-answers
       id (harness-patch-review-test--thread-block (car made) "" "open"))
      (should (equal "open" (plist-get (car (plist-get (harness-call 'patch-review/get id) :threads)) :status)))
      ;; A block with no thread starts one, on the change as a whole.
      (harness-patch-review-test--agent-answers
       id (harness-patch-review-test--thread-block nil "This is the cache."))
      (let* ((thread (cadr (plist-get (harness-call 'patch-review/get id) :threads)))
             (comment (car (plist-get thread :comments))))
        (should (equal "This is the cache." (plist-get comment :body)))
        (should-not (plist-get comment :location))))))

(ert-deftest harness-patch-review-reads-a-message-once ()
  "The same <thread> block of the same message, read again, makes no second
comment; two blocks of the message are still two comments."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (sid (plist-get (harness-call 'task/get id) :session))
           (made (harness-patch-review-test--user-comment id "Why two?" :sent 5.0))
           (thread (car made))
           (text (concat (harness-patch-review-test--thread-block thread "One reason.")
                         "\n\n"
                         (harness-patch-review-test--thread-block thread "And another.")))
           (node (harness-patch-review-test--agent-answers id text)))
      (harness-thread-reply--on-assistant-message text sid (plist-get node :id))
      (should (= 3 (length (plist-get (harness-patch-review-test--thread id thread) :comments))))
      (should (equal '("Why two?" "One reason." "And another.")
                     (mapcar (lambda (comment) (plist-get comment :body))
                             (plist-get (harness-patch-review-test--thread id thread) :comments)))))))

(ert-deftest harness-patch-review-an-answer-with-no-status-leaves-the-thread-as-it-is ()
  "A <thread> block with words and no status changes nothing of the thread's
status: the agent's answer in a thread it closed leaves it closed.  What opens
a closed thread is the reviewer's reply, in the review's views and in the chat."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (made (harness-patch-review-test--user-comment id "Why eighteen?"
                                                         :location harness-patch-review-test--a18 :sent 5.0)))
      (harness-patch-review-test--agent-answers
       id (harness-patch-review-test--thread-block (car made) "Because." "closed"))
      (harness-patch-review-test--agent-answers
       id (harness-patch-review-test--thread-block (car made) "And also this."))
      (let ((thread (car (plist-get (harness-call 'patch-review/get id) :threads))))
        (should (equal "closed" (plist-get thread :status)))
        (should (equal '("Why eighteen?" "Because." "And also this.")
                       (mapcar (lambda (comment) (plist-get comment :body)) (plist-get thread :comments))))
        (should (equal '("closed")
                       (mapcar (lambda (entry) (plist-get entry :status)) (plist-get thread :history))))))))

(ert-deftest harness-patch-review-the-comment-writer-checks-its-thread-and-status ()
  "The writer of a comment says what is wrong: a thread the review does not have,
a comment with no words and no status, or a status that is not open or closed."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (sid (plist-get (harness-call 'task/get id) :session))
           (made (harness-patch-review-test--user-comment id "Why?" :sent 5.0))
           (unknown (should-error (harness-call 'patch-review/comment id "x"
                                                :thread "t-nope" :session sid)
                                  :type 'harness-error))
           (empty (should-error (harness-call 'patch-review/comment id ""
                                              :thread (car made) :session sid)
                                :type 'harness-error))
           (bad (should-error (harness-call 'patch-review/comment id "x"
                                            :thread (car made) :status "done" :session sid)
                              :type 'harness-error)))
      (should (string-search (car made) (error-message-string unknown)))
      (should (string-search "status" (error-message-string empty)))
      (should (string-search "open or closed" (error-message-string bad))))))

(ert-deftest harness-patch-review-lists-the-threads-for-the-agent ()
  "review_threads lists the threads with ids, status, place and the comments
the user sent; the drafts are the user's, and stay out."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (sent (harness-patch-review-test--user-comment id "Why eighteen?"
                                                         :location harness-patch-review-test--a18 :sent 5.0))
           (draft (harness-patch-review-test--user-comment id "A secret draft")))
      (harness-patch-review-test--agent-answers
       id (harness-patch-review-test--thread-block (car sent) "Because." "closed"))
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

(ert-deftest harness-patch-review-the-reading-tool-folds-with-the-reads ()
  "In the chat review_threads folds with the reads around it.
It only lists what is there; without its flag the call stood as a line of
its own between two summaries of reads, cutting their run in two.  There
is no writing tool left to keep in view."
  (harness-patch-review-test-with
    (should (eq t (plist-get (harness-call 'tools/get "review_threads") :coalescable)))
    (should-not (harness-call 'tools/get "review_comment"))))

(ert-deftest harness-patch-review-offers-its-tool-to-task-sessions-only ()
  "A session that is no task's has no review to read."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (task-session (harness-call 'session/get (plist-get (harness-call 'task/get id) :session)))
           (other (harness-call 'session/create :cwd default-directory)))
      (should (equal '("review_threads" "read_file")
                     (harness-run-filter 'agent/tools '("review_threads" "read_file") task-session)))
      (should (equal '("read_file")
                     (harness-run-filter 'agent/tools '("review_threads" "read_file")
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
  "Pass BLOCKS, the user's message to the session of task ID, to the filters that read it.
Return the blocks that go on.  The thread-reply module's filter runs
first, then the review's; not the tasks module's, which reads a message
to a task in review as the feedback that sends it back."
  (let* ((sid (plist-get (harness-call 'task/get id) :session))
         (blocks (harness-thread-reply--on-message blocks sid '(:from nil))))
    (harness-patch-review--on-message blocks sid '(:from nil))))

(defun harness-patch-review-test--threads (id)
  "Return the threads of task ID's review, as the harness keeps them."
  (plist-get (harness-call 'patch-review/get id) :threads))

(defun harness-patch-review-test--thread (id thread-id)
  "Return thread THREAD-ID of task ID's review, or nil."
  (cl-find thread-id (harness-patch-review-test--threads id)
           :key (lambda (thread) (plist-get thread :id)) :test #'equal))

(ert-deftest harness-patch-review-makes-a-reply-with-thread-data-a-thread ()
  "A reply with the data of a thread is a comment in a new thread of the task's
review: the user's, sent, with the quote above the response, the references in
its meta, and, in the block that goes on, the thread's id in the tag of its
<thread> block.  The thread is announced to every UI like any other."
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
        ;; The blocks that go on know their threads, and name them in the tag.
        (should (equal (plist-get first :id) (plist-get data :id)))
        (should (equal (plist-get comment :id) (plist-get data :comment)))
        (should (equal (concat "<thread id=\"" (plist-get first :id) "\">\n"
                               "<quote>Your earlier message (" (harness-links-message-url nil (plist-get agent :id))
                               "):\n\nThe build is green.</quote>\nGood.\n</thread>")
                       (plist-get (car blocks) :text)))
        (should (equal (list (plist-get second :id)) (harness-thread-marker-ids (plist-get (cadr blocks) :text))))
        (should (equal "Good." (harness-thread-response (car blocks)))))
      (should (equal '("add-comment" "add-comment")
                     (mapcar (lambda (e) (format "%s" (plist-get (cadr e) :op))) (reverse events)))))))

(ert-deftest harness-patch-review-keeps-a-reply-s-picture-with-it ()
  "A picture the message attached, whose token is in the reply's words,
is kept in the comment's meta for the thread to draw."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (agent (harness-patch-review-test--agent-says id "The button is fixed."))
           (file (expand-file-name "shot.png" default-directory))
           (coding-system-for-write 'no-conversion))
      (write-region harness-test-png nil file nil 'silent)
      (harness-patch-review-test--sends
       id
       (harness-patch-review-test--reply agent "See this: [image 1].")
       (list :type "image" :path file :mime "image/png" :label "image 1"
             :name "shot.png"))
      (let* ((thread (car (harness-patch-review-test--threads id)))
             (comment (car (plist-get thread :comments))))
        (should (equal (list (list :path file :mime "image/png"
                                   :name "shot.png" :size nil))
                       (plist-get (plist-get comment :meta) :attachments))))
      (delete-file file))))

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
      ;; What the agent reads says where the lines are, in the one <thread> block.
      (should (string-prefix-p (concat "<thread id=\"" (plist-get thread :id) "\">")
                               (plist-get (car blocks) :text)))
      (should (string-search "In a.el, lines 18-19 (after the change, at abc1234):" (plist-get (car blocks) :text)))
      (should (string-suffix-p "</thread>" (plist-get (car blocks) :text))))))

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
  "The agent answers a thread in a <thread> block; a reply that refers to that
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
           (answer (harness-patch-review-test--agent-answers
                    id (harness-patch-review-test--thread-block
                        thread body "closed" "The deploy is pending."))))
      ;; The agent answers in the thread, closing it.
      (should (equal "closed" (plist-get (car (harness-patch-review-test--threads id)) :status)))
      ;; The user refers to a part of that answer, in the agent's message.
      (let ((blocks (harness-patch-review-test--sends
                     id (harness-thread-block
                         (list :refs (list (list :kind "chat" :node (plist-get answer :id) :who "agent"
                                                 :part "body" :from 0 :to 8
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
      (should (string-search "<thread id=\"t-" (plist-get (car blocks) :text)))
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
      ;; The text of the blocks: the note, then the <thread> block of the reply.
      (should (equal (concat "Quick note first.\n\n" (plist-get (cadr blocks) :text)) text))
      (should (string-search (harness-links-message-url nil (plist-get agent :id))
                             (plist-get (cadr blocks) :text)))
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

(ert-deftest harness-patch-review-the-words-of-the-feedback-name-their-thread ()
  "The feedback that sends a task back names the thread its words are in.
The agent reads the id in the <thread id=\"...\"> tag of its message,
answers it in a message of its own, and the thread closes; a message
that is never sent makes no thread."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (sid (plist-get (harness-call 'task/get id) :session))
           (words "Say which unit the threshold is in.")
           (additions (harness-patch-review--additions (harness-call 'task/get id) words)))
      (should additions)
      (should (string-match "\\`<thread id=\"\\(t-[A-Za-z0-9]+\\)\">\\'" (car additions)))
      (let ((thread (match-string 1 (car additions))))
        ;; The agent's message names the thread, after the words it is in.
        (let ((feedback (harness-tasks--add-to-feedback words additions)))
          (should (string-prefix-p words feedback))
          (should (string-match-p (regexp-quote (format "<thread id=\"%s\">" thread)) feedback)))
        ;; Nothing is made until the message is sent.
        (should-not (harness-call 'patch-review/open-threads id))
        (funcall (cdr additions))
        (should (equal (list thread)
                       (mapcar (lambda (th) (plist-get th :id))
                               (harness-call 'patch-review/open-threads id))))
        ;; The agent answers and closes it in its message.
        (harness-thread-reply--on-assistant-message
         (format "<thread id=\"%s\" status=\"closed\">\n<quote>%s</quote>\nSeconds.\n</thread>" thread words)
         sid "n-answer")
        (should-not (harness-call 'patch-review/open-threads id))
        (let ((threads (harness-patch-review-test--threads id)))
          (should (= 1 (length threads)))
          (should (equal "closed" (plist-get (car threads) :status))))))))

(defvar harness-patch-review-test--requests nil
  "The requests the scripted agent of a test was sent, newest first.")

(defun harness-patch-review-test--answers-in-threads (request)
  "The events of an agent that answers the first thread its newest message names.
It answers in a <thread> block of its message, `Since the nightly job.' in
it, and leaves the thread open."
  (push request harness-patch-review-test--requests)
  (let ((ids (harness-thread-marker-ids (harness-provider-demo--last-user-text request))))
    (if (null ids)
        '((:type text :delta "Done.") (:type done :stop-reason end-turn))
      `((:type text :delta ,(format "<thread id=\"%s\">\nSince the nightly job.\n\nIt waits for the migration.\n</thread>"
                                    (car ids)))
        (:type done :stop-reason end-turn)))))

(ert-deftest harness-patch-review-the-agent-answers-a-reply-in-its-thread ()
  "A reply with a thread's data sent to the session of a task is a comment in a
thread, which the agent answers in a <thread> block, the thread's marker in
what it read and no note to answer inline; the comment is the agent's, in its
session; and a reply that refers to that answer is a comment in the same thread."
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
             (answer (car (last (cl-remove-if-not
                                 (lambda (n) (and (eq 'assistant (plist-get n :kind))
                                                  (string-search "<thread" (or (plist-get n :content) ""))))
                                 nodes))))
             (threads (harness-patch-review-test--threads id))
             (thread (plist-get (car threads) :id))
             (read (harness-provider-demo--last-user-text (car (last harness-patch-review-test--requests)))))
        ;; What the agent read: the reply's <thread> block, and not the note.
        (should (string-search (harness-thread-marker thread) read))
        (should (string-search "<quote>" read))
        (should (string-search "The deploy is pending." read))
        (should-not (string-search harness-agent--inline-reply-note read))
        (should-not (member "review_comment" (mapcar (lambda (spec) (plist-get spec :name))
                                                    (plist-get (car (last harness-patch-review-test--requests)) :tools))))
        (should (member "review_threads" (mapcar (lambda (spec) (plist-get spec :name))
                                                (plist-get (car (last harness-patch-review-test--requests)) :tools))))
        ;; What the transcript keeps: the user's block, and the agent's answer.
        (let ((block (cl-find-if #'harness-thread-block-p (plist-get user :blocks))))
          (should block)
          (should (equal thread (plist-get (plist-get block :thread) :id)))
          (should (equal "Since when?" (harness-thread-response block))))
        (should (string-search (format "<thread id=\"%s\">" thread) (plist-get answer :content)))
        ;; What the review keeps: the user's comment and the agent's, in one thread.
        (should (= 1 (length threads)))
        (let ((comments (plist-get (car threads) :comments)))
          (should (equal '("user" "agent") (mapcar (lambda (c) (plist-get (plist-get c :author) :kind)) comments)))
          (should-not (plist-get (plist-get (cadr comments) :author) :tool-call))
          (should (equal sid (plist-get (plist-get (cadr comments) :author) :session))))
        ;; The user refers to the answer, and replies: the same thread, the
        ;; agent answering again in it.
        (harness-test-await
         (harness-call 'agent/prompt sid
                       (list (harness-thread-block
                              (list :refs (list (list :kind "chat" :node (plist-get answer :id) :who "agent"
                                                      :from 0 :to 8
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
        (should (string-prefix-p (harness-thread-marker (plist-get (car threads) :id)) (plist-get (cadr blocks) :text)))
        (should (= 1 (length threads)))
        (should (equal "> Rolled back.\n\nWhy?" (plist-get (car (plist-get (car threads) :comments)) :body)))
        ;; The round keeps what was sent, markers and all.
        (should (string-search "<thread id=\"t-" (plist-get (car (plist-get (harness-call 'task/get id) :feedback)) :text)))))))

(ert-deftest harness-patch-review-the-demo-agent-answers-each-thread-of-a-reply ()
  "The demo provider, which a live harness is tried out with, answers a message
that names threads in a <thread> block in each, as an agent is told to."
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
      (let ((answers (cl-remove-if-not
                      (lambda (node)
                        (and (eq 'assistant (plist-get node :kind))
                             (string-search "<thread" (or (plist-get node :content) ""))))
                      (harness-call 'session/nodes sid))))
        (should (= 1 (length answers)))
        (should (= 2 (length (harness-thread-parse-blocks (plist-get (car answers) :content)))))
        (should-not (cl-find "review_comment" (harness-call 'session/nodes sid)
                             :key (lambda (n) (plist-get n :tool)) :test #'equal))))))

(ert-deftest harness-patch-review-keeps-a-picture-with-a-feedback-reply ()
  "A picture among the feedback whose token is in a reply's words is kept
with the thread the reply makes, for the review to draw."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (file (expand-file-name "shot.png" default-directory))
           (coding-system-for-write 'no-conversion))
      (write-region harness-test-png nil file nil 'silent)
      (let* ((task (harness-call 'task/get id))
             (image (list :path file :mime "image/png" :name "shot.png"
                          :label "image 1"))
             (reply (list :label "reply 1" :response "Here: [image 1]"
                          :thread (list :refs nil)))
             (result (harness-patch-review--on-feedback-attachments
                      (list image reply) task))
             (data (plist-get (cadr result) :thread)))
        (should (plist-get data :id))
        (should (equal (list (list :path file :mime "image/png"
                                   :name "shot.png" :size nil))
                       (plist-get data :attachments))))
      (delete-file file))))

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
      (should (cl-some (lambda (round) (string-search "<thread id=\"t-" (plist-get round :text)))
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
        (should (string-search "<thread id=\"t-" (plist-get (car (plist-get (harness-tasks--get id) :feedback)) :text)))
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

(ert-deftest harness-patch-review-a-comment-says-what-the-chat-draws ()
  "The writer of a comment returns what the chat draws: the thread, the comment,
the status and who wrote the comment it follows, a line of it."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (sid (plist-get (harness-call 'task/get id) :session))
           (made (harness-patch-review-test--user-comment id "Since when is the deploy pending?\nAnd why?" :sent 5.0))
           (result (harness-call 'patch-review/comment id "Since noon."
                                 :thread (substring (car made) 0 6) :status "closed" :session sid)))
      (should (equal (car made) (plist-get result :thread)))
      (should (equal "closed" (plist-get result :status)))
      (should (stringp (plist-get (plist-get result :comment) :id)))
      (should (equal (list :id (cdr made) :author "Noah" :kind "user" :excerpt "Since when is the deploy pending?")
                     (plist-get result :parent)))
      ;; Only the status: no comment, and the one it follows is the last there is.
      (let ((again (harness-call 'patch-review/comment id "" :thread (car made) :status "open" :session sid)))
        (should-not (plist-get again :comment))
        (should (equal "open" (plist-get again :status))))
      ;; A new thread follows nothing.
      (let ((fresh (harness-call 'patch-review/comment id "A new one." :session sid)))
        (should-not (plist-get fresh :parent))
        (should (stringp (plist-get fresh :thread))))
      ;; A reply made in the chat starts with the quote it answers: the line
      ;; the chat shows is the answer's, or the quote's when it is all there is.
      (let* ((quoted (harness-patch-review-test--user-comment id "> The deploy is pending.\n>\n> Since noon?\n\nNo, since the nightly job." :sent 6.0))
             (only (harness-patch-review-test--user-comment id "> Just the quote, nothing under it." :sent 7.0)))
        (should (equal "No, since the nightly job."
                       (plist-get (plist-get
                                   (harness-call 'patch-review/comment id "Right." :thread (car quoted) :session sid)
                                   :parent)
                                  :excerpt)))
        (should (equal "Just the quote, nothing under it."
                       (plist-get (plist-get
                                   (harness-call 'patch-review/comment id "Yes." :thread (car only) :session sid)
                                   :parent)
                                  :excerpt)))))))

;;;; A malformed reply in a thread

(ert-deftest harness-thread-reply-sends-a-malformed-reply-back ()
  "A malformed <thread> block in the agent's last message is answered with a
message of the harness's, which names what is wrong and shows the block a
judge suggests.  The answer is `agent/stop''s: (:stop nil :message ...)."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (sid (plist-get (harness-call 'task/get id) :session))
           (thread (car (harness-patch-review-test--user-comment id "Why two?")))
           (fixed (format "<thread id=\"%s\" status=\"closed\">\n<quote>Why two?</quote>\nBecause.\n</thread>"
                          thread))
           (judge-args nil)
           (answer nil))
      (should (harness-patch-review-test--say
               sid (format "<thread id=%s>\n<quote>Why two?</quote>\nBecause.\n</thread>" thread)))
      (cl-letf (((symbol-function 'harness-judge-ask)
                 (lambda (&rest args)
                   (setq judge-args args)
                   (harness-resolved (list :value fixed :text fixed :lookups 0)))))
        (setq answer (harness-test-await
                      (harness-thread-reply--repair-answer
                       (harness-call 'session/get sid)) 15)))
      (should answer)
      (should-not (harness-json-true-p (plist-get answer :stop)))
      (should (equal (harness-sender-system "thread replies") (plist-get answer :from)))
      (let ((message (plist-get answer :message)))
        (should (string-match-p "strict <thread> form" message))
        (should (string-match-p "double quotes" message))
        (should (string-match-p "A model suggests this corrected block" message))
        (should (string-match-p (regexp-quote fixed) message)))
      ;; The judge saw the malformed block and the findings, on the cheap model.
      (should judge-args)
      (should (equal "thread reply repair" (plist-get judge-args :label)))
      (should (string-match-p (format "id=%s" thread) (plist-get judge-args :prompt)))
      (should (string-match-p "double quotes" (plist-get judge-args :prompt)))
      (should (eq (plist-get judge-args :session) sid)))))

(ert-deftest harness-thread-reply-leaves-a-strict-reply-alone ()
  "A strict block, prose, and a session that is no task's get no message, and
no judge is asked."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (sid (plist-get (harness-call 'task/get id) :session))
           (thread (car (harness-patch-review-test--user-comment id "Why two?")))
           (asked nil))
      (cl-letf (((symbol-function 'harness-judge-ask)
                 (lambda (&rest _) (setq asked t) (harness-resolved (list :value nil)))))
        (harness-patch-review-test--say
         sid (format "<thread id=\"%s\" status=\"closed\">\n<quote>Why two?</quote>\nDone.\n</thread>" thread))
        (should-not (harness-test-await
                     (harness-thread-reply--repair-answer
                      (harness-call 'session/get sid)) 15))
        (should-not asked)
        (harness-patch-review-test--say sid "All done, and no block.")
        (should-not (harness-test-await
                     (harness-thread-reply--repair-answer
                      (harness-call 'session/get sid)) 15))
        (should-not asked))
      ;; A session that is no task's has no review threads to repair.
      (should-not (harness-test-await
                   (harness-thread-reply--repair-answer '(:id "s-no-task")) 15)))))

(ert-deftest harness-thread-reply-asks-the-judge-for-a-closed-block-only ()
  "Only a malformed block with its closing tag is put to the judge, and only
the strict block it answers with is shown to the agent."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (sid (plist-get (harness-call 'task/get id) :session))
           (asked 0)
           (answer nil))
      (harness-patch-review-test--say sid "<thread id=\"t-1\">\nThe answer, but no closing tag.\n")
      (cl-letf (((symbol-function 'harness-judge-ask)
                 (lambda (&rest _) (cl-incf asked) (harness-resolved (list :value nil)))))
        (setq answer (harness-test-await
                      (harness-thread-reply--repair-answer
                       (harness-call 'session/get sid)) 15)))
      (should (string-match-p "never closed" (plist-get answer :message)))
      (should-not (string-match-p "A model suggests" (plist-get answer :message)))
      (should (zerop asked)))
    ;; No judge, and an answer that is no strict block, leave the message
    ;; to what the harness found.
    (let* ((id (harness-patch-review-test--task))
           (sid (plist-get (harness-call 'task/get id) :session))
           (answer nil))
      (harness-patch-review-test--say sid "<thread id=t-1>A</thread>")
      (cl-letf (((symbol-function 'harness-judge-ask)
                 (lambda (&rest _) (harness-resolved (list :value "<thread id=t-1>A</thread>")))))
        (setq answer (harness-test-await
                      (harness-thread-reply--repair-answer
                       (harness-call 'session/get sid)) 15)))
      (should (string-match-p "What is wrong" (plist-get answer :message)))
      (should-not (string-match-p "A model suggests" (plist-get answer :message))))))

(ert-deftest harness-thread-reply-tells-the-agent-a-placeholder-is-no-thread ()
  "A block that copies the format's THREAD_ID is sent back with what to do,
without asking a judge that cannot know the thread the agent means."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (sid (plist-get (harness-call 'task/get id) :session))
           (asked nil)
           (answer nil))
      (harness-patch-review-test--say
       sid "<thread id=\"THREAD_ID\">\n<quote>Why?</quote>\nBecause.\n</thread>")
      (cl-letf (((symbol-function 'harness-judge-ask)
                 (lambda (&rest _) (setq asked t) (harness-resolved (list :value nil)))))
        (setq answer (harness-test-await
                      (harness-thread-reply--repair-answer
                       (harness-call 'session/get sid)) 15)))
      (should (string-match-p "placeholder THREAD_ID" (plist-get answer :message)))
      (should-not asked))))

(ert-deftest harness-thread-reply-stops-sending-back-after-the-maximum ()
  "A turn gets `harness-thread-reply-attempts' corrections, then
a hint and no more: a model that cannot write the form is not sent round
forever.  A new turn starts its own count."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (sid (plist-get (harness-call 'task/get id) :session))
           (harness-thread-reply-attempts 2)
           (asked 0))
      (cl-letf (((symbol-function 'harness-judge-ask)
                 (lambda (&rest _) (harness-resolved (list :value nil)))))
        (dotimes (i 2)
          (harness-patch-review-test--say sid "<thread id=t-bad>A</thread>")
          (let ((answer (harness-test-await
                         (harness-thread-reply--repair-answer
                          (harness-call 'session/get sid)) 15)))
            (should (plist-get answer :message))
            (cl-incf asked)))
        (harness-patch-review-test--say sid "<thread id=t-bad>A</thread>")
        (should-not (harness-test-await
                     (harness-thread-reply--repair-answer
                      (harness-call 'session/get sid)) 15))
        (should (= 2 asked))
        (should (= 2 (plist-get (gethash sid harness-thread-reply--repairs) :count)))
        (should (plist-get (gethash sid harness-thread-reply--repairs) :exhausted))
        ;; The user is told why the reply stays as written.
        (let* ((nodes (harness-call 'session/nodes sid))
               (hint (car (last (cl-remove-if-not (lambda (node) (eq (plist-get node :kind) 'hint))
                                                  nodes)))))
          (should hint)
          (should (string-match-p "malformed" (plist-get hint :content))))
        ;; The turn ends, and the next turn is sent back again.
        (harness-thread-reply--on-turn-ended sid 'end-turn)
        (harness-patch-review-test--say sid "<thread id=t-bad>A</thread>")
        (should (plist-get (harness-test-await
                            (harness-thread-reply--repair-answer
                             (harness-call 'session/get sid)) 15)
                           :message))))))

(ert-deftest harness-thread-reply-corrections-can-be-turned-off ()
  "With no attempts the reply is left alone, and not even a hint is added."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (sid (plist-get (harness-call 'task/get id) :session))
           (harness-thread-reply-attempts nil))
      (harness-patch-review-test--say sid "<thread id=t-bad>A</thread>")
      (should-not (harness-test-await
                   (harness-thread-reply--repair-answer
                    (harness-call 'session/get sid)) 15))
      (should-not (cl-remove-if-not
                   (lambda (node)
                     (and (eq (plist-get node :kind) 'hint)
                          (string-match-p "malformed" (or (plist-get node :content) ""))))
                   (harness-call 'session/nodes sid))))))

(ert-deftest harness-thread-reply-readable-judge-answer-is-one-strict-block ()
  "The judge's corrected block is taken only when it is exactly one strict
block, between <fixed> and </fixed>, and it keeps the thread the agent
named, or the absence of one."
  (let ((block "<thread id=\"t-1\">\n<quote>Q</quote>\nA\n</thread>"))
    (should (equal block (harness-thread-reply--repair-parse
                          (format "Here it is:\n<fixed>\n%s\n</fixed>\n" block))))
    (should-not (harness-thread-reply--repair-parse
                 "<fixed><thread id=t-1>A</thread></fixed>"))
    (should-not (harness-thread-reply--repair-parse
                 (format "<fixed>%s\n\n%s</fixed>" block block)))
    (should-not (harness-thread-reply--repair-parse "No block.")))
  (should (equal "t-1" (harness-thread-reply--repair-id "<thread id=\"t-1\">")))
  (should (equal "t-1" (harness-thread-reply--repair-id "<thread id=t-1>A</thread>")))
  (should-not (harness-thread-reply--repair-id "<thread>A</thread>")))

(ert-deftest harness-thread-reply-a-judge-may-not-change-the-thread-id ()
  "A corrected block that names another thread is no suggestion: the id the
agent named stays, and a new thread gets none."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (sid (plist-get (harness-call 'task/get id) :session))
           (answer nil))
      (harness-patch-review-test--say sid "<thread id=t-original>\n<quote>Why?</quote>\nBecause.\n</thread>")
      (cl-letf (((symbol-function 'harness-judge-ask)
                 (lambda (&rest _)
                   (harness-resolved
                    (list :value "<thread id=\"t-other\">\n<quote>Why?</quote>\nBecause.\n</thread>")))))
        (setq answer (harness-test-await
                      (harness-thread-reply--repair-answer
                       (harness-call 'session/get sid)) 15)))
      (should (string-match-p "What is wrong" (plist-get answer :message)))
      (should-not (string-match-p "A model suggests" (plist-get answer :message))))))

(ert-deftest harness-thread-reply-the-stop-filter-carries-the-correction ()
  "The `agent/stop' filter hands the correction on, and leaves a value that
is not a model's own stop alone without checking anything."
  (let* ((value '(:stop t))
         (answer (list :stop nil :message "Fix it."
                       :from (harness-sender-system "thread replies")))
         (seen nil))
    (cl-letf (((symbol-function 'harness-thread-reply--repair-answer)
               (lambda (_session) (harness-resolved answer))))
      (harness-thread-reply--repair-stop value (lambda (v) (setq seen v)) '(:id "s1"))
      (harness-test-wait (lambda () seen) 2 "the stop filter")
      (should (equal answer seen))))
  (let ((seen nil) (checked nil))
    (cl-letf (((symbol-function 'harness-thread-reply--repair-answer)
               (lambda (_session) (setq checked t) (harness-resolved nil))))
      (harness-thread-reply--repair-stop '(:stop nil :message "mine")
                                                (lambda (v) (setq seen v)) '(:id "s1"))
      (should-not checked)
      (should (equal '(:stop nil :message "mine") seen)))))

(ert-deftest harness-thread-reply-a-malformed-reply-is-sent-back-in-the-turn ()
  "The `agent/stop' chain sends a model that wrote a malformed block back:
the next request ends with a message of the harness's, from \"thread
replies\", and the model takes a step more to correct it."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (sid (plist-get (harness-call 'task/get id) :session))
           (thread (car (harness-patch-review-test--user-comment id "Why two?")))
           (fixed (format "<thread id=\"%s\" status=\"closed\">\n<quote>Why two?</quote>\nBecause.\n</thread>"
                          thread))
           (requests nil)
           (turn 0)
           (judge-asked nil)
           (harness-provider-demo-script-override
            (lambda (request)
              (push request requests)
              (if (= 1 (cl-incf turn))
                  `((:type text :delta ,(format "<thread id=%s>\n<quote>Why two?</quote>\nBecause.\n</thread>" thread))
                    (:type done :stop-reason end-turn))
                '((:type text :delta "Corrected.")
                  (:type done :stop-reason end-turn))))))
      (cl-letf (((symbol-function 'harness-judge-ask)
                 (lambda (&rest _)
                   (setq judge-asked t)
                   (harness-resolved (list :value fixed)))))
        (harness-test-await (harness-call 'agent/prompt sid "Answer the thread.") 20))
      (should (= 2 (length requests)))
      (should judge-asked)
      ;; The correction is a steering message of the harness's in the turn.
      (let* ((nodes (harness-call 'session/nodes sid))
             (correction (cl-find-if
                          (lambda (node)
                            (and (eq (plist-get node :kind) 'user)
                                 (harness-json-true-p (plist-get (plist-get node :meta) :steering))))
                          nodes)))
        (should correction)
        (should (equal (harness-sender-system "thread replies")
                       (harness-node-sender correction)))
        (should (string-match-p "strict <thread> form" (plist-get correction :content)))
        (should (string-match-p (regexp-quote fixed) (plist-get correction :content))))
      ;; The second request read the correction as its last user message.
      (let* ((second (car requests))
             (last (car (last (plist-get second :messages)))))
        (should (eq 'user (plist-get last :role)))
        (should (string-match-p "strict <thread> form"
                                (plist-get (car (last (plist-get last :content))) :text))))
      ;; The turn is over, and its count goes with it.
      (should-not (gethash sid harness-thread-reply--repairs)))))

(defun harness-thread-reply-test--typed-media (mime name token)
  "Check that a typed reply keeps only its own attachment, MIME, NAME, TOKEN."
  (harness-patch-review-test-with
    (let* ((id (harness-patch-review-test--task))
           (sid (plist-get (harness-call 'task/get id) :session))
           (thread (car (harness-patch-review-test--user-comment id "The button is fixed.")))
           (file (expand-file-name name default-directory))
           (attachment (append (list :type (if (string-prefix-p "image/" mime) "image" "file")
                                     :path file :mime mime :name name :size 17)
                               (and (string-prefix-p "image/" mime) (list :label "image 1"))))
           (blocks
            (harness-run-filter
             'agent/message
             (list (list :type "text"
                         :text (format
                                (concat "A message attachment: [image 2] and @message.mp4.\n\n"
                                        "<thread id=\"%s\">\n"
                                        "<quote>Earlier: [image 2] and @message.mp4.</quote>\n"
                                        "Here: %s\n</thread>\n\n"
                                        "<thread id=\"%s\">\n<quote>Here: %s</quote>\n"
                                        "No attachment in this reply.\n</thread>")
                                thread token thread token))
                   attachment
                   (list :type "image" :path (expand-file-name "message.png" default-directory)
                         :mime "image/png" :label "image 2")
                   (list :type "file" :path (expand-file-name "message.mp4" default-directory)
                         :mime "video/mp4" :name "message.mp4"))
             sid '(:from nil)))
           (threads (harness-patch-review-test--threads id))
           (comments (plist-get (cl-find thread threads
                                        :key (lambda (item) (plist-get item :id)) :test #'equal)
                                :comments))
           (reply (cadr comments))
           (unattached (caddr comments)))
      ;; The real filters register typed replies before the task sends them.
      (should (eq 'active (plist-get (harness-call 'task/get id) :state)))
      (should (= 3 (length comments)))
      (should (equal (list (list :path file :mime mime :name name :size 17))
                     (plist-get (plist-get reply :meta) :attachments)))
      (should (plist-get (plist-get reply :meta) :tag))
      (should (equal sid (plist-get (plist-get reply :meta) :session)))
      (should (numberp (plist-get reply :sent)))
      ;; Neither the quote, the surrounding prose, nor another reply owns it.
      (should-not (plist-get (plist-get unattached :meta) :attachments))
      (should (equal "No attachment in this reply."
                     (harness-thread-response
                      (cadr (cl-remove-if-not #'harness-thread-block-p blocks)))))
      (should (member attachment blocks))
      ;; Re-reading the typed reply blocks keeps them unchanged.  The task's
      ;; generated feedback also contains example <thread> markup; it is not
      ;; another user message to run through the filters.
      (let ((replies (cl-remove-if-not #'harness-thread-block-p blocks)))
        (should (equal replies (harness-run-filter 'agent/message replies sid '(:from nil)))))
      (should (= 3 (length (plist-get
                           (cl-find thread (harness-patch-review-test--threads id)
                                    :key (lambda (item) (plist-get item :id)) :test #'equal)
                           :comments)))))))

(ert-deftest harness-thread-reply-keeps-a-typed-reply-s-picture ()
  "An image token in a typed reply keeps that image with only that comment."
  (harness-thread-reply-test--typed-media "image/png" "shot.png" "[image 1]"))

(ert-deftest harness-thread-reply-keeps-a-typed-reply-s-video ()
  "A file reference in a typed reply keeps that video with only that comment."
  (harness-thread-reply-test--typed-media "video/mp4" "clip.mp4" "@clip.mp4"))

(provide 'harness-patch-review-test)
;;; harness-patch-review-test.el ends here
