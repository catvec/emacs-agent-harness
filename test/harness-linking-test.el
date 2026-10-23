;;; harness-linking-test.el --- Tests for links in what agents write  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; The linking module (harness-linking.el) finds what a link to a
;; session, a message, a tool call, a task or a thread names, writes the
;; links of a text out in full, and teaches agents to write them.  The
;; sessions here are the demo provider's, with a conversation written into
;; them node by node; the task and its review are stood in for by methods
;; of the tests' own, which the real ones answer to in the suites of those
;; modules (harness-patch-review-test.el).

;;; Code:

(require 'harness-test-helpers)
(require 'harness-links)
(require 'harness-linking)
(require 'harness-acp)

(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
(defvar harness-naming-auto)
(defvar harness-sessions)
(defvar harness-agent--turns)
(defvar harness-tools-question--questions)
(defvar harness-acp--server-enabled)
(defvar harness-acp-extension-prefixes)
(declare-function harness-acp--extension-allowed-p "harness-acp" (name))
(declare-function harness-acp--map-params "harness-acp" (fn params))

(defmacro harness-linking-test-with (&rest body)
  "Load the state layer, the demo provider, the tools and the linking module; run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo tools session agent tools-agent
                        tools-question tools-plan tools-session-info priority linking))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-agent--turns)
     (clrhash harness-tools-question--questions)
     (let ((harness-provider-demo--delay 0.005)
           (harness-naming-auto nil)
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       ,@body)))

(defun harness-linking-test-session (&rest plist)
  "Create a demo session with PLIST's keys and return its id."
  (plist-get (apply #'harness-call 'session/create :cwd default-directory :model "demo:scripted" plist) :id))

(defun harness-linking-test-node (sid kind &rest plist)
  "Append a node of KIND with PLIST to session SID; return its id."
  (plist-get (harness-call 'session/append sid (append (list :kind kind) plist)) :id))

(defun harness-linking-test-story (sid)
  "Write a short conversation into session SID; return its nodes' ids as a plist.
A user asks, the agent runs bash and reads a file, the user asks again,
the agent runs bash again and answers, and hands in."
  (let* ((u1 (harness-linking-test-node sid 'user :content "Please run the tests"))
         (a1 (harness-linking-test-node sid 'assistant :content "On it."))
         (c1 (harness-linking-test-node sid 'tool-call :tool "bash" :call-id "toolu_1"
                                        :input '(:command "scripts/test.sh\nsecond line")
                                        :title "Run command: scripts/test.sh"))
         (r1 (harness-linking-test-node sid 'tool-result :call-id "toolu_1" :output "ok"))
         (c2 (harness-linking-test-node sid 'tool-call :tool "read_file" :call-id "toolu_2"
                                        :input '(:path "a.el") :title "Read file: a.el"))
         (r2 (harness-linking-test-node sid 'tool-result :call-id "toolu_2" :output "(a)"))
         (u2 (harness-linking-test-node sid 'user :content "And the lint?"))
         (c3 (harness-linking-test-node sid 'tool-call :tool "bash" :call-id "toolu_3"
                                        :input '(:command "scripts/lint.sh") :title "Run command: scripts/lint.sh"))
         (r3 (harness-linking-test-node sid 'tool-result :call-id "toolu_3" :output "ok"))
         (a2 (harness-linking-test-node sid 'assistant :content "Both pass."))
         (h1 (harness-linking-test-node sid 'tool-call :tool "hand_in" :call-id "toolu_4"
                                        :input '(:summary "Done") :title "Hand in")))
    (list :u1 u1 :a1 a1 :c1 c1 :r1 r1 :c2 c2 :r2 r2 :u2 u2 :c3 c3 :r3 r3 :a2 a2 :h1 h1)))

(defmacro harness-linking-test-with-story (&rest body)
  "Run BODY with `sid' a session holding the story, and `n' its nodes' ids (a plist)."
  (declare (indent 0))
  `(harness-linking-test-with
     (let* ((sid (harness-linking-test-session :name "Fix the build"))
            (n (harness-linking-test-story sid)))
       ,@body)))

(defun harness-linking-test-n (n key)
  "Return the id of node KEY in the story N."
  (plist-get n key))

;;;; A session

(ert-deftest harness-linking-resolves-a-session ()
  "A session is named by its id, a unique start of it or its name in any case."
  (harness-linking-test-with
    (let* ((sid (harness-linking-test-session :name "Fix the build"))
           (other (harness-linking-test-session :name "Fix the lint")))
      (dolist (ref (list sid (substring sid 0 10) "Fix the build" "fix THE build"))
        (ert-info (ref)
          (let ((r (harness-linking-resolve (harness-links-session-url ref))))
            (should-not (plist-get r :error))
            (should (equal "session" (plist-get r :kind)))
            (should (equal (concat "harness:session/" sid) (plist-get r :url)))
            (should (equal "Fix the build" (plist-get r :label)))
            (should (equal sid (plist-get r :session)))
            (should (equal "Fix the build" (plist-get r :session-name))))))
      ;; A name with blanks reads as it is written in a URL.
      (should (equal sid (plist-get (harness-linking-resolve "harness:session/Fix%20the%20build") :session)))
      (should (equal other (plist-get (harness-linking-resolve "harness:session/Fix the lint") :session))))))

(ert-deftest harness-linking-says-why-a-session-is-not-found ()
  (harness-linking-test-with
    (let ((a (harness-linking-test-session :name "Twin"))
          (b (harness-linking-test-session :name "Twin")))
      (let ((r (harness-linking-resolve "harness:session/twin")))
        (should-not (plist-get r :kind))
        (should (string-match-p "matches 2 sessions" (plist-get r :error)))
        (should (string-search (substring a 0 8) (plist-get r :error)))
        (should (string-search (substring b 0 8) (plist-get r :error))))
      (should (string-match-p "No session matches nothing-here"
                              (plist-get (harness-linking-resolve "harness:session/nothing-here") :error)))
      ;; A link that is none.
      (should (string-match-p "is no link to a session"
                              (plist-get (harness-linking-resolve "harness:session") :error)))
      (should (string-match-p "is no link to a session"
                              (plist-get (harness-linking-resolve "https://example.org") :error)))
      (should (plist-get (harness-linking-resolve nil) :error)))))

(ert-deftest harness-linking-an-internal-session-answers-only-when-nothing-else-does ()
  "The record of a model call the harness made on its own is named only by its name."
  (harness-linking-test-with
    (let* ((me (harness-linking-test-session :name "Me"))
           (judge (harness-call 'session/internal-start :job "Permission judge" :parent-id me
                                :model "demo:scripted" :prompt "May it?")))
      (should (equal judge (plist-get (harness-linking-resolve "harness:session/permission judge") :session)))
      (let ((normal (harness-linking-test-session :name "Permission judge")))
        (should (equal normal (plist-get (harness-linking-resolve "harness:session/permission judge") :session)))))))

;;;; A tool call

(ert-deftest harness-linking-resolves-a-call-by-its-ids ()
  "A call is named by its node's id, the id its provider gave it, or its result's node."
  (harness-linking-test-with-story
    (let ((c1 (harness-linking-test-n n :c1)))
      (dolist (ref (list c1 "toolu_1" (harness-linking-test-n n :r1)))
        (ert-info (ref)
          (let ((r (harness-linking-resolve (format "harness:session/%s/call/%s" sid ref))))
            (should-not (plist-get r :error))
            (should (equal "call" (plist-get r :kind)))
            (should (equal (format "harness:session/%s/call/%s" sid c1) (plist-get r :url)))
            (should (equal "Run command: scripts/test.sh" (plist-get r :label)))
            (should (equal sid (plist-get r :session)))
            (should (equal "Fix the build" (plist-get r :session-name)))
            (should (equal c1 (plist-get r :node)))
            (should (equal "toolu_1" (plist-get r :call-id)))
            (should (equal "bash" (plist-get r :tool))))))
      ;; Without a session in the link, the one the text is in.
      (should (equal c1 (plist-get (harness-linking-resolve (format "harness:call/%s" c1) :session sid) :node)))
      ;; A hand_in call is named by its id, though handles skip it.
      (should (equal (harness-linking-test-n n :h1)
                     (plist-get (harness-linking-resolve "harness:call/toolu_4" :session sid) :node))))))

(ert-deftest harness-linking-resolves-the-handles-of-a-call ()
  "last, #N, NAME#N and a tool's name count the calls of the session, newest first, hand_in left out."
  (harness-linking-test-with-story
    (pcase-dolist (`(,ref ,key) '(("last" :c3) ("newest" :c3) ("#1" :c3) ("#2" :c2) ("#3" :c1)
                                  ("bash#1" :c3) ("bash#2" :c1) ("BASH#2" :c1) ("read_file#1" :c2)
                                  ("bash" :c3) ("read_file" :c2) ("Read_File" :c2) ("first" :c1)))
      (ert-info (ref)
        (let ((r (harness-linking-resolve (format "harness:call/%s" ref) :session sid)))
          (should-not (plist-get r :error))
          (should (equal (harness-linking-test-n n key) (plist-get r :node)))
          (should (equal (format "harness:session/%s/call/%s" sid (harness-linking-test-n n key))
                         (plist-get r :url))))))
    ;; Of another session, named in the link, with no session holding the text.
    (should (equal (harness-linking-test-n n :c3)
                   (plist-get (harness-linking-resolve (format "harness:session/%s/call/last" sid)) :node)))))

(ert-deftest harness-linking-handles-count-only-the-nodes-before ()
  "The call that holds the words, and what follows it, is none of the calls a handle means."
  (harness-linking-test-with-story
    ;; Before the node of the third call: the second is the newest.
    (should (equal (harness-linking-test-n n :c2)
                   (plist-get (harness-linking-resolve "harness:call/last" :session sid
                                                       :before (harness-linking-test-n n :c3))
                              :node)))
    ;; Or before it by the id its provider gave it.
    (should (equal (harness-linking-test-n n :c2)
                   (plist-get (harness-linking-resolve "harness:call/last" :session sid :before "toolu_3")
                              :node)))
    (should (equal (harness-linking-test-n n :c1)
                   (plist-get (harness-linking-resolve "harness:call/bash#1" :session sid :before "toolu_3")
                              :node)))
    ;; An exact id is exact, whatever comes before.
    (should (equal (harness-linking-test-n n :c3)
                   (plist-get (harness-linking-resolve "harness:call/toolu_3" :session sid
                                                       :before (harness-linking-test-n n :c1))
                              :node)))
    ;; A node that is none of the session's changes nothing.
    (should (equal (harness-linking-test-n n :c3)
                   (plist-get (harness-linking-resolve "harness:call/last" :session sid :before "n-nowhere")
                              :node)))))

(ert-deftest harness-linking-says-which-calls-there-are-when-one-is-not-found ()
  (harness-linking-test-with-story
    (dolist (ref '("#9" "bash#9" "zzz" "grep#1"))
      (ert-info (ref)
        (let ((r (harness-linking-resolve (format "harness:call/%s" ref) :session sid)))
          (should-not (plist-get r :kind))
          (should (string-match-p (format "No tool call matches %s in Fix the build" (regexp-quote ref))
                                  (plist-get r :error)))
          ;; The recent ones, with their handles and ids, newest first; not hand_in's.
          (should (string-match-p "#1 n-[a-z0-9]+ (Run command: scripts/lint.sh), #2 n-[a-z0-9]+ (Read file: a.el)"
                                  (plist-get r :error)))
          (should-not (string-search "Hand in" (plist-get r :error))))))
    ;; No call to name at all.
    (let ((empty (harness-linking-test-session)))
      (should (string-match-p "there are none"
                              (plist-get (harness-linking-resolve "harness:call/last" :session empty) :error))))
    ;; No session to look in.
    (should (string-match-p "names no session"
                            (plist-get (harness-linking-resolve "harness:call/last") :error)))
    (should (string-match-p "No session matches"
                            (plist-get (harness-linking-resolve "harness:session/zzz/call/last") :error)))))

;;;; A message

(ert-deftest harness-linking-tells-where-a-node-of-another-session-is-linked ()
  "A node id copied from another session's transcript, with no session, says how to name it."
  (harness-linking-test-with-story
    (let ((elsewhere (harness-linking-test-session :name "Elsewhere")))
      (dolist (kind '("message" "call"))
        (let* ((node (harness-linking-test-node elsewhere 'assistant :content "Over there"))
               (error (plist-get (harness-linking-resolve (format "harness:%s/%s" kind node) :session sid) :error)))
          (should (string-search (format "a node of another session is linked with its session: harness:session/ID/%s/%s"
                                         kind node)
                                 error))))
      ;; Not for a handle.
      (should-not (string-search "another session"
                                 (plist-get (harness-linking-resolve "harness:call/bash#9" :session sid) :error))))))

(ert-deftest harness-linking-resolves-a-message-by-its-id ()
  (harness-linking-test-with-story
    (let* ((a2 (harness-linking-test-n n :a2))
           (r (harness-linking-resolve (format "harness:session/%s/message/%s" sid a2))))
      (should-not (plist-get r :error))
      (should (equal "message" (plist-get r :kind)))
      (should (equal (format "harness:session/%s/message/%s" sid a2) (plist-get r :url)))
      (should (equal (format "message %s of Fix the build" a2) (plist-get r :label)))
      (should (equal sid (plist-get r :session)))
      (should (equal a2 (plist-get r :node)))
      (should-not (plist-get r :call-id))
      ;; In the session the text is in.
      (should (equal a2 (plist-get (harness-linking-resolve (format "harness:message/%s" a2) :session sid) :node)))
      ;; Any node has an id, not messages alone.
      (should (equal (harness-linking-test-n n :c1)
                     (plist-get (harness-linking-resolve (format "harness:message/%s" (harness-linking-test-n n :c1))
                                                         :session sid)
                                :node)))
      (should (string-match-p "No message matches n-nowhere"
                              (plist-get (harness-linking-resolve "harness:message/n-nowhere" :session sid) :error))))))

(ert-deftest harness-linking-resolves-the-handles-of-a-message ()
  "last is the newest assistant message, first the first user message, #N the Nth
newest of either, user#N and assistant#N the Nth newest of that kind."
  (harness-linking-test-with-story
    (pcase-dolist (`(,ref ,key) '(("last" :a2) ("newest" :a2) ("#1" :a2) ("#2" :u2) ("#3" :a1) ("#4" :u1)
                                  ("user#1" :u2) ("user#2" :u1) ("assistant#1" :a2) ("assistant#2" :a1)
                                  ("USER#1" :u2) ("user" :u2) ("assistant" :a2) ("first" :u1) ("oldest" :u1)))
      (ert-info (ref)
        (let ((r (harness-linking-resolve (format "harness:message/%s" ref) :session sid)))
          (should-not (plist-get r :error))
          (should (equal (harness-linking-test-n n key) (plist-get r :node))))))
    ;; The message that holds the words is not one of them.
    (should (equal (harness-linking-test-n n :a1)
                   (plist-get (harness-linking-resolve "harness:message/last" :session sid
                                                       :before (harness-linking-test-n n :a2))
                              :node)))
    (should (equal (harness-linking-test-n n :u1)
                   (plist-get (harness-linking-resolve "harness:message/user#1" :session sid
                                                       :before (harness-linking-test-n n :u2))
                              :node)))))

(ert-deftest harness-linking-says-which-messages-there-are-when-one-is-not-found ()
  (harness-linking-test-with-story
    (dolist (ref '("#9" "user#3" "assistant#3"))
      (ert-info (ref)
        (let ((r (harness-linking-resolve (format "harness:message/%s" ref) :session sid)))
          (should (string-match-p (format "No message matches %s in Fix the build" (regexp-quote ref))
                                  (plist-get r :error)))
          (should (string-match-p "#1 n-[a-z0-9]+ (assistant: Both pass\\.), #2 n-[a-z0-9]+ (user: And the lint\\?)"
                                  (plist-get r :error))))))
    (should (string-match-p "names no session"
                            (plist-get (harness-linking-resolve "harness:message/last") :error)))))

;;;; A task and a thread

(defconst harness-linking-test--threads
  '(("t-1a2b3c4d" . "a.el:18") ("t-1a2b9999" . "the change as a whole") ("t-ffff0000" . "b.el:3"))
  "The threads of the task the tests stand in for: their ids and where they are.")

(defmacro harness-linking-test-with-review (&rest body)
  "Run BODY with `sid' the session of a task, `plain' one that is no task's, `task-id' the task's id.
Methods of the tests' own stand in for the tasks module and the module
that keeps the review of a task's changes."
  (declare (indent 0))
  `(harness-linking-test-with
     (let* ((sid (harness-linking-test-session :name "Fix the flaky test"))
            (plain (harness-linking-test-session :name "Plain"))
            (task-id "t-abcd1234")
            (task (list :id task-id :name "Fix the flaky test" :prompt "Fix it" :session sid)))
       (harness-register-method 'task/get (lambda (id)
                                            (if (equal id task-id) task
                                              (signal 'harness-error (list (format "No task %s" id))))))
       (harness-register-method 'task/list (lambda (&optional _cwd) (list task)))
       (harness-register-method 'task/for-session (lambda (s) (and (equal s sid) task)))
       (harness-register-method
        'review/find-thread
        (lambda (id ref)
          (when (equal id task-id)
            (let ((hits (cl-remove-if-not (lambda (th) (string-prefix-p ref (car th)))
                                          harness-linking-test--threads)))
              (when (cdr hits) (signal 'harness-error (list (format "%s starts the ids of %d threads" ref (length hits)))))
              (when hits (list :id (caar hits) :status "open" :where (cdar hits) :comments 2))))))
       ,@body)))

(ert-deftest harness-linking-resolves-a-thread ()
  "A thread is named by its id, or the start of it, in the review of a task the link
names, the task of the session it names, or the task of the session the text is in."
  (harness-linking-test-with-review
    (dolist (case (list (list "harness:thread/t-1a2b3c4d" sid)
                        (list (format "harness:task/%s/thread/t-1a2b3c4d" task-id) nil)
                        (list (format "harness:session/%s/thread/t-1a2b3c4d" sid) nil)
                        (list "harness:thread/t-1a2b3" sid)))
      (ert-info ((car case))
        (let ((r (harness-linking-resolve (car case) :session (cadr case))))
          (should-not (plist-get r :error))
          (should (equal "thread" (plist-get r :kind)))
          (should (equal (format "harness:task/%s/thread/t-1a2b3c4d" task-id) (plist-get r :url)))
          (should (equal "thread t-1a2b3c4d on a.el:18" (plist-get r :label)))
          (should (equal task-id (plist-get r :task)))
          (should (equal "t-1a2b3c4d" (plist-get r :thread)))
          (should (equal "open" (plist-get r :status)))
          (should (equal sid (plist-get r :session)))
          (should (equal "Fix the flaky test" (plist-get r :session-name))))))
    ;; A task named by the start of its id.
    (should (equal "t-1a2b3c4d" (plist-get (harness-linking-resolve "harness:task/t-abcd/thread/t-1a2b3c" :session plain)
                                            :thread)))))

(ert-deftest harness-linking-says-why-a-thread-is-not-found ()
  (harness-linking-test-with-review
    (let ((error-of (lambda (url &optional session)
                      (plist-get (harness-linking-resolve url :session session) :error))))
      ;; Which of the threads is meant.
      (should (string-match-p "starts the ids of 2 threads" (funcall error-of "harness:thread/t-1a2b" sid)))
      (should (string-match-p "No thread t-nope in the review of the task Fix the flaky test"
                              (funcall error-of "harness:thread/t-nope" sid)))
      ;; Which task.
      (should (string-match-p "names no task" (funcall error-of "harness:thread/t-1a2b3c4d")))
      (should (string-match-p "Plain is no task's" (funcall error-of "harness:thread/t-1a2b3c4d" plain)))
      (should (string-match-p "No task matches t-zzzz"
                              (funcall error-of "harness:task/t-zzzz/thread/t-1a2b3c4d")))
      (should (string-match-p "No session matches zzz" (funcall error-of "harness:session/zzz/thread/t-1a2b3c4d")))
      ;; Without the module that keeps a review.
      (harness-unregister-method 'review/find-thread)
      (should (string-match-p "Review threads are not available" (funcall error-of "harness:thread/t-1a2b3c4d" sid))))))

(ert-deftest harness-linking-resolves-a-task ()
  (harness-linking-test-with-review
    (dolist (ref (list task-id "t-abcd" "t-ab"))
      (ert-info (ref)
        (let ((r (harness-linking-resolve (harness-links-task-url ref))))
          (should-not (plist-get r :error))
          (should (equal "task" (plist-get r :kind)))
          (should (equal (concat "harness:task/" task-id) (plist-get r :url)))
          (should (equal "task Fix the flaky test" (plist-get r :label)))
          (should (equal task-id (plist-get r :task)))
          (should (equal "Fix the flaky test" (plist-get r :task-name)))
          (should (equal sid (plist-get r :session))))))
    (should (string-match-p "No task matches t-zz" (plist-get (harness-linking-resolve "harness:task/t-zz") :error)))
    ;; Too short a start names nothing.
    (should (string-match-p "No task matches t-" (plist-get (harness-linking-resolve "harness:task/t-") :error)))
    (harness-unregister-method 'task/get)
    (should (string-match-p "tasks module is not loaded"
                            (plist-get (harness-linking-resolve (harness-links-task-url task-id)) :error)))))

;;;; The method

(ert-deftest harness-linking-the-method-answers-a-ui ()
  "`link/resolve' is `harness-linking-resolve' with the url and the session, and a UI may call it."
  (harness-linking-test-with-story
    (let ((r (harness-call 'link/resolve "harness:call/last" sid)))
      (should (equal (format "harness:session/%s/call/%s" sid (harness-linking-test-n n :c3)) (plist-get r :url))))
    (should (plist-get (harness-call 'link/resolve "harness:call/last") :error))
    (should (plist-get (harness-call 'link/resolve "harness:call/last" nil) :error))
    (let ((harness-acp--server-enabled nil))
      (harness-test-load-module 'acp))
    (should (harness-acp--extension-allowed-p "link/resolve"))
    (should (harness-acp--extension-allowed-p "link/canonicalize"))
    ;; Params by name, as a client sends them.
    (let ((args (harness-acp--map-params (harness-method-fn (gethash 'link/resolve harness--methods))
                                         (list :url "harness:call/last" :session sid))))
      (should (equal (list "harness:call/last" sid) args)))))

;;;; Writing links out in full

(ert-deftest harness-linking-writes-a-link-out-in-full ()
  "A handle, a name or a prefix becomes the ids it stood for, in every form a link has."
  (harness-linking-test-with-story
    (let* ((c1 (harness-linking-test-n n :c1)) (c3 (harness-linking-test-n n :c3))
           (a1 (harness-linking-test-n n :a1))
           (explorer (harness-linking-test-session :name "explorer"))
           (done (harness-linking-canonicalize
                  (concat "The run [tests](harness:call/bash#2), again [it](harness:call/last), "
                          "<harness:session/explorer> and [its answer](harness:message/assistant#2).")
                  :session sid)))
      (should-not (cdr done))
      (should (equal (format (concat "The run [tests](harness:session/%s/call/%s), again [it](harness:session/%s/call/%s), "
                                     "<harness:session/%s> and [its answer](harness:session/%s/message/%s).")
                             sid c1 sid c3 explorer sid a1)
                     (car done))))))

(ert-deftest harness-linking-writing-out-is-done-once ()
  "A link in full stays as it is, so doing it again changes nothing."
  (harness-linking-test-with-story
    (let* ((text (concat "See [the run](harness:call/last), harness:call/#2, <harness:session/" sid ">"
                         " and [this](harness:message/first)."))
           (once (car (harness-linking-canonicalize text :session sid)))
           (twice (harness-linking-canonicalize once :session sid)))
      (should-not (string= text once))
      (should (equal once (car twice)))
      (should-not (cdr twice))
      ;; And away from the session the text was in: nothing relative is left.
      (let ((elsewhere (harness-linking-test-session :name "Elsewhere")))
        (should (equal once (car (harness-linking-canonicalize once :session elsewhere))))
        (should-not (cdr (harness-linking-canonicalize once :session elsewhere)))))))

(ert-deftest harness-linking-writes-a-session-name-out-as-its-id ()
  "A name with blanks is a name in a Markdown link, and the link is the session's id after."
  (harness-linking-test-with-story
    (let ((done (harness-linking-canonicalize "Ask [the other one](harness:session/Fix the build) and [x](harness:session/fix%20THE%20build)."
                                              :session "elsewhere")))
      (should-not (cdr done))
      (should (equal (format "Ask [the other one](harness:session/%s) and [x](harness:session/%s)." sid sid)
                     (car done))))))

(ert-deftest harness-linking-writes-a-bare-link-as-a-markdown-one ()
  "A bare link reads as what it names; an autolink keeps its form."
  (harness-linking-test-with-story
    (let ((done (harness-linking-canonicalize "Look at harness:call/last. And <harness:call/bash#2>!" :session sid)))
      (should-not (cdr done))
      (should (equal (format "Look at [Run command: scripts/lint.sh](harness:session/%s/call/%s). And <harness:session/%s/call/%s>!"
                             sid (harness-linking-test-n n :c3) sid (harness-linking-test-n n :c1))
                     (car done))))
    ;; A bare link to a session reads as its name.
    (should (equal (format "Ask [Fix the build](harness:session/%s) now." sid)
                   (car (harness-linking-canonicalize (format "Ask harness:session/%s now." sid)))))))

(ert-deftest harness-linking-leaves-code-alone ()
  "What a Markdown renderer shows as code holds no link."
  (harness-linking-test-with-story
    (let ((text "Write `[x](harness:call/last)`:\n\n```\n[x](harness:call/last)\nharness:call/last\n```\n\n~~~md\n<harness:call/last>\n~~~\n"))
      (should (eq text (car (harness-linking-canonicalize text :session sid))))
      (should-not (cdr (harness-linking-canonicalize text :session sid))))
    ;; Beside code, a link counts.
    (should (string-match-p "\\[y\\](harness:session/[-0-9a-f]+/call/n-"
                            (car (harness-linking-canonicalize "`[x](harness:call/last)` and [y](harness:call/last)"
                                                               :session sid))))))

(ert-deftest harness-linking-leaves-a-link-that-names-nothing-as-written ()
  "It stays, and says why, one sentence each; the others are written out."
  (harness-linking-test-with-story
    (let ((done (harness-linking-canonicalize
                 "Bad [a](harness:call/bash#9), good [b](harness:call/last), bad [c](harness:session/zzz) and harness:message/user#9."
                 :session sid)))
      (should (string-match-p (format "Bad \\[a\\](harness:call/bash#9), good \\[b\\](harness:session/%s/call/n-[a-z0-9]+), bad \\[c\\](harness:session/zzz) and harness:message/user#9\\."
                                      sid)
                              (car done)))
      (should (= 3 (length (cdr done))))
      (should (string-match-p "\\`harness:call/bash#9: No tool call matches bash#9" (nth 0 (cdr done))))
      (should (string-match-p "\\`harness:session/zzz: No session matches zzz" (nth 1 (cdr done))))
      (should (string-match-p "\\`harness:message/user#9: No message matches user#9" (nth 2 (cdr done)))))
    ;; The same link twice says so once.
    (should (= 1 (length (cdr (harness-linking-canonicalize "[a](harness:call/bash#9) [b](harness:call/bash#9)"
                                                            :session sid)))))))

(ert-deftest harness-linking-writing-out-counts-the-nodes-before-the-text ()
  "The words of the second call do not mean that call by `last'."
  (harness-linking-test-with-story
    (should (equal (format "[x](harness:session/%s/call/%s)" sid (harness-linking-test-n n :c2))
                   (car (harness-linking-canonicalize "[x](harness:call/last)" :session sid
                                                      :before (harness-linking-test-n n :c3)))))))

(ert-deftest harness-linking-writing-out-does-nothing-to-a-text-without-links ()
  "The text itself comes back, no work done, whatever it is."
  (harness-linking-test-with-story
    (dolist (text '("Plain words." "" "A harness: it is. And harness:foo/bar, harness:8080." "[web](https://x.org)"))
      (let ((done (harness-linking-canonicalize text :session sid)))
        (should (eq text (car done)))
        (should-not (cdr done))))
    (should (equal '(nil) (harness-linking-canonicalize nil)))
    (should (equal '(42) (harness-linking-canonicalize 42)))))

(ert-deftest harness-linking-the-method-writes-links-out ()
  (harness-linking-test-with-story
    (let ((r (harness-call 'link/canonicalize "[x](harness:call/last) [y](harness:call/bash#9)" sid)))
      (should (string-prefix-p (format "[x](harness:session/%s/call/%s) [y](harness:call/bash#9)"
                                       sid (harness-linking-test-n n :c3))
                               (plist-get r :text)))
      (should (= 1 (length (plist-get r :problems)))))
    ;; The node the words are in, by its id.
    (let ((r (harness-call 'link/canonicalize "[x](harness:call/last)" sid (harness-linking-test-n n :c3))))
      (should (equal (format "[x](harness:session/%s/call/%s)" sid (harness-linking-test-n n :c2))
                     (plist-get r :text))))))

(ert-deftest harness-linking-a-text-that-cannot-be-worked-on-comes-back ()
  "A failure inside never reaches the caller: the text is what it was."
  (harness-linking-test-with-story
    (cl-letf (((symbol-function 'harness-links-rewrite) (lambda (&rest _) (error "Boom"))))
      (let ((done (harness-linking-canonicalize "[x](harness:call/last)" :session sid)))
        (should (equal "[x](harness:call/last)" (car done)))
        (should-not (cdr done))))
    (cl-letf (((symbol-function 'harness-linking--resolve) (lambda (&rest _) (error "Boom"))))
      (let ((r (harness-linking-resolve "harness:call/last" :session sid)))
        (should (string-match-p "Resolving harness:call/last failed: Boom" (plist-get r :error)))))))

;;;; Words a tool carries

(ert-deftest harness-tools-written-writes-the-words-of-a-call-out ()
  "A tool that carries an agent's words has the links in them written out, in the
terms of the session that made the call and before the call."
  (harness-linking-test-with-story
    (let* ((ctx (list :session-id sid :call-id "toolu_3"))
           (done (harness-tools-written "[x](harness:call/last) [y](harness:call/bash#9)" ctx)))
      (should (string-prefix-p (format "[x](harness:session/%s/call/%s) [y](harness:call/bash#9)"
                                       sid (harness-linking-test-n n :c2))
                               (car done)))
      (should (string-match-p "\\`Links that name nothing, left as you wrote them: harness:call/bash#9: No tool call matches"
                              (cdr done))))
    ;; No link, no work.
    (let ((text "Plain."))
      (should (eq text (car (harness-tools-written text (list :session-id sid)))))
      (should-not (cdr (harness-tools-written text (list :session-id sid)))))
    (should (equal '(nil) (harness-tools-written nil nil)))
    ;; Without the linking module the text is what it was.
    (harness-unregister-method 'link/canonicalize)
    (should (equal '("[x](harness:call/last)")
                   (harness-tools-written "[x](harness:call/last)" (list :session-id sid))))
    (should (equal "Done." (harness-tools-with-note "Done." nil)))
    (should (equal "Done.\n\nNote." (harness-tools-with-note "Done." "Note.")))))

;;;; The system prompt

(ert-deftest harness-linking-teaches-agents-to-link-in-the-system-prompt ()
  (harness-linking-test-with
    (let* ((sid (harness-linking-test-session))
           (prompt (harness-run-filter 'agent/system-prompt "BASE" (harness-call 'session/get sid))))
      (should (string-prefix-p "BASE" prompt))
      ;; After Planning, which tools-agent adds first.
      (should (< (string-search "## Planning" prompt) (string-search "## Links" prompt)))
      (should (string-suffix-p "\n" prompt))
      (dolist (text '("harness:session/ID" "harness:session/ID/message/NODE" "harness:call/last"
                      "harness:message/last" "harness:thread/ID" "harness:task/TASK/thread/ID"
                      "session_read, session_search and session_history" "bash#2" "user#1"
                      "A link that names nothing is left as you wrote it"))
        (should (string-search text prompt)))
      ;; Every link the section shows reads as a link of the library.
      (with-temp-buffer
        (insert harness-linking-prompt-section)
        (goto-char (point-min))
        (let ((n 0))
          (while (re-search-forward "(\\(harness:[^)]+\\))" nil t)
            (cl-incf n)
            (should (harness-links-parse (match-string 1))))
          (should (>= n 4)))))
    ;; The record of a model call the harness made on its own writes no message.
    (let* ((me (harness-linking-test-session))
           (judge (harness-call 'session/internal-start :job "Judge" :parent-id me
                                :model "demo:scripted" :prompt "May it?")))
      (should-not (string-search "## Links" (harness-run-filter 'agent/system-prompt "BASE" (harness-call 'session/get judge))))
      (should-not (string-search "## Links" (harness-run-filter 'agent/system-prompt "BASE" nil)))
      ;; A session of any other kind has it.
      (dolist (kind '(main subagent btw fork))
        (should (string-search "## Links" (harness-run-filter 'agent/system-prompt "BASE" (list :id "x" :kind kind))))))))

(ert-deftest harness-linking-the-section-reaches-the-model ()
  "A turn's request carries the Links section in its system prompt."
  (harness-linking-test-with
    (let ((sid (harness-linking-test-session))
          (seen nil)
          (harness-provider-demo-script-override '((:type text :delta "ok") (:type done :stop-reason end-turn))))
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req) (setq seen (plist-get req :system)) (funcall orig req))))
        (harness-test-await (harness-call 'agent/prompt sid "hello")))
      (should (string-search "## Links" seen))
      (should (< (string-search "## Planning" seen) (string-search "## Links" seen))))))

(ert-deftest harness-linking-a-naming-request-does-not-get-the-section ()
  "The request that titles a conversation is no turn: its system prompt is its own."
  (harness-linking-test-with
    (harness-test-load-module 'naming)
    (let ((sid (harness-linking-test-session))
          (harness-provider-demo-script-override '((:type text :delta "A title") (:type done :stop-reason end-turn)))
          (systems nil))
      (harness-linking-test-node sid 'user :content "Fix the parser")
      (harness-linking-test-node sid 'assistant :content "Done")
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req) (push (plist-get req :system) systems) (funcall orig req))))
        (harness-await (harness-call 'naming/name sid)))
      (should systems)
      (dolist (system systems)
        (should-not (string-search "## Links" system))))))

(ert-deftest harness-linking-is-in-the-core-and-known-to-a-ui ()
  (should (memq 'linking harness-core-modules))
  (should (member "link/" harness-acp-extension-prefixes)))

;;;; The turn writes the links of its messages out

(ert-deftest harness-linking-an-assistant-message-has-its-links-written-out ()
  "The call the model made last is the call `last' means in the words it writes
after it, whatever the session does next; the node keeps the ids."
  (harness-linking-test-with
    (let* ((sid (harness-linking-test-session))
           (harness-provider-demo-script-override
            '((:type tool-call :id "toolu_a" :name "session_info" :input nil)
              (:type text :delta "Done: [the info](harness:call/last), ")
              (:type text :delta "[the first](harness:call/session_info#1), and [plain](https://x.org).")
              (:type done :stop-reason end-turn))))
      (harness-test-await (harness-call 'agent/prompt sid "go") 30)
      (let* ((nodes (harness-call 'session/nodes sid))
             (call (cl-find 'tool-call nodes :key (lambda (n) (plist-get n :kind))))
             (message (cl-find 'assistant nodes :key (lambda (n) (plist-get n :kind)))))
        (should (equal "toolu_a" (plist-get call :call-id)))
        (should (equal (format "Done: [the info](harness:session/%s/call/%s), [the first](harness:session/%s/call/%s), and [plain](https://x.org)."
                               sid (plist-get call :id) sid (plist-get call :id))
                       (plist-get message :content)))))))

(ert-deftest harness-linking-a-message-is-kept-as-written-without-the-module ()
  "Nothing about the links changes how a model's words reach the transcript."
  (harness-linking-test-with
    (harness-unregister-method 'link/canonicalize)
    (let ((sid (harness-linking-test-session))
          (harness-provider-demo-script-override
           '((:type text :delta "See [it](harness:call/last).") (:type done :stop-reason end-turn))))
      (harness-test-await (harness-call 'agent/prompt sid "go") 30)
      (should (equal "See [it](harness:call/last)."
                     (plist-get (cl-find 'assistant (harness-call 'session/nodes sid)
                                         :key (lambda (n) (plist-get n :kind)))
                                :content))))))

(ert-deftest harness-linking-a-message-with-a-broken-link-is-kept ()
  "A link that names nothing is left, and the message reaches the transcript all the same."
  (harness-linking-test-with
    (let ((sid (harness-linking-test-session))
          (harness-provider-demo-script-override
           '((:type text :delta "See [it](harness:call/last), no call yet.") (:type done :stop-reason end-turn))))
      (harness-test-await (harness-call 'agent/prompt sid "go") 30)
      (should (equal "See [it](harness:call/last), no call yet."
                     (plist-get (cl-find 'assistant (harness-call 'session/nodes sid)
                                         :key (lambda (n) (plist-get n :kind)))
                                :content))))))

;;;; The tools

(ert-deftest harness-linking-spawn-agent-writes-the-prompt-out-in-the-parents-terms ()
  "The child reads the prompt in a session of its own, where `last' means another call."
  (harness-linking-test-with-story
    (let* ((result (harness-test-await
                    (harness-call 'tools/execute sid
                                  (list :id "toolu_5" :name "spawn_agent"
                                        :input '(:prompt "Check [that run](harness:call/bash#2) and [none](harness:call/zzz#4)."
                                                 :name "checker")))))
           (cid (plist-get (plist-get result :meta) :child-id))
           (first (cl-find 'user (harness-call 'session/nodes cid) :key (lambda (x) (plist-get x :kind)))))
      (should-not (plist-get result :is-error))
      (should (string-search (format "Check [that run](harness:session/%s/call/%s)" sid (harness-linking-test-n n :c1))
                             (plist-get first :content)))
      (should (string-search "[none](harness:call/zzz#4)" (plist-get first :content)))
      ;; The one that names nothing is said in the result.
      (should (string-match-p "Links that name nothing, left as you wrote them: harness:call/zzz#4"
                              (plist-get result :content))))))

(ert-deftest harness-linking-plan-writes-its-links-out ()
  (harness-linking-test-with-story
    (let ((result (harness-test-await
                   (harness-call 'tools/execute sid
                                 (list :id "toolu_6" :name "plan"
                                       :input '(:plan "1. Rerun [the lint](harness:call/last)\n2. See [x](harness:message/user#9)"))))))
      (should-not (plist-get result :is-error))
      (let ((plan (plist-get (harness-call 'session/get sid) :plan)))
        (should (string-search (format "Rerun [the lint](harness:session/%s/call/%s)" sid (harness-linking-test-n n :c3))
                               plan))
        (should (string-search "[x](harness:message/user#9)" plan)))
      (should (string-match-p "Plan recorded\\..*\n\nLinks that name nothing, left as you wrote them: harness:message/user#9"
                              (plist-get result :content)))
      (should (string-match-p (format "harness:session/%s/call/" sid)
                              (plist-get (cl-find 'plan (harness-call 'session/nodes sid) :key (lambda (x) (plist-get x :kind)))
                                         :content))))))

(ert-deftest harness-linking-ask-user-writes-its-question-out ()
  (harness-linking-test-with-story
    (let* ((promise (harness-call 'tools/execute sid
                                  (list :id "toolu_7" :name "ask_user"
                                        :input '(:question "Is [this run](harness:call/bash#1) what you meant?"
                                                 :options ("yes" "no")))))
           (pending (progn (harness-test-wait (lambda () (harness-call 'question/pending sid)) 5 "the question")
                           (car (harness-call 'question/pending sid)))))
      (should (equal (format "Is [this run](harness:session/%s/call/%s) what you meant?" sid (harness-linking-test-n n :c3))
                     (plist-get (plist-get pending :payload) :question)))
      (harness-call 'question/answer sid (plist-get pending :id) "yes")
      (should-not (plist-get (harness-test-await promise) :is-error)))))

(provide 'harness-linking-test)
;;; harness-linking-test.el ends here
