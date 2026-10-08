;;; harness-tasks-search-test.el --- Tests for the task board's search  -*- lexical-binding: t; -*-

;;; Commentary:

;; Drives `task/search', `task/search-apply' and `task/search-warm'
;; against the real state layer and the demo provider, whose replies a
;; test scripts per request: the board the model reads, the plan made of
;; its answer, looking further once, failures, the actions, the model
;; process of each search and what a search costs.

;;; Code:

(require 'harness-test-helpers)

(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
(defvar harness-naming-auto)
(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent--turns)
(defvar harness-tasks--table)
(defvar harness-tasks--starting)
(defvar harness-tasks--loaded)
(defvar harness-tasks--dirty)
(defvar harness-tasks-max-running)
(defvar harness-tasks-require-verification)
(defvar harness-tasks-permission-mode)
(defvar harness-tasks-non-interactive)
(defvar harness-tasks-model)
(defvar harness-tasks-search-model)
(defvar harness-tasks-search--timeout)
(defvar harness-tasks-search--warm-idle)
(defvar harness-tasks-search--warm)
(defvar harness-tasks-search--system)
(defvar harness-providers)
(defvar harness-acp--server-enabled)
(defvar harness-acp--clients)
(defvar harness-acp-token)
(declare-function harness-tasks--forget-stores "harness-tasks")
(declare-function harness-acp--drop-client "harness-acp")
(declare-function harness-define-provider "harness-provider")
(declare-function harness-provider--forget "harness-provider")

(defconst harness-tasks-search-test--work
  '((:type text :delta "Working on it.") (:type done :stop-reason end-turn))
  "What a task's session answers.")

(defvar harness-tasks-search-test--replies nil
  "What the search model answers next: strings, or event lists, in turn.
The last one answers every request after it.")

(defvar harness-tasks-search-test--requests nil
  "The requests the search model got, newest first.")

(defun harness-tasks-search-test--search-p (request)
  "Non-nil when REQUEST is a search's."
  (equal harness-tasks-search--system (plist-get request :system)))

(defun harness-tasks-search-test--script (request)
  "The demo provider's script: a search answers from the replies, a task works.
A task asked to stay busy never ends its turn; one asked to fail fails."
  (if (harness-tasks-search-test--search-p request)
      (let ((reply (if (cdr harness-tasks-search-test--replies)
                       (pop harness-tasks-search-test--replies)
                     (car harness-tasks-search-test--replies))))
        (push request harness-tasks-search-test--requests)
        (if (stringp reply)
            `((:type text :delta ,reply)
              (:type usage :input 1200 :output 40 :cache-read 300 :cost 0.0015)
              (:type done :stop-reason end-turn))
          reply))
    (let ((text (harness-provider-demo--last-user-text request)))
      (cond ((string-match-p "stay busy" text) '((:type text :delta "Busy.")))
            ((string-match-p "fail now" text) '((:type text :delta "oops") (:type done :stop-reason error :error "boom")))
            (t harness-tasks-search-test--work)))))

(declare-function harness-provider-demo--last-user-text "harness-provider-demo")

(defmacro harness-tasks-search-test-with (&rest body)
  "Load the state layer, tasks and their search with the demo provider; run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent tasks tasks-search acp))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-tasks--table)
     (clrhash harness-tasks--starting)
     (clrhash harness-tasks-search--warm)
     (harness-tasks--forget-stores)
     (setq harness-tasks--loaded t
           harness-tasks--dirty nil
           harness-acp--clients nil
           harness-tasks-search-test--replies '("{\"show\":[],\"do\":[]}")
           harness-tasks-search-test--requests nil)
     (let ((harness-provider-demo--delay 0.005)
           (harness-provider-demo-script-override #'harness-tasks-search-test--script)
           (harness-naming-auto nil)
           (harness-tasks-max-running nil)
           (harness-tasks-require-verification nil)
           (harness-tasks-permission-mode 'auto)
           (harness-tasks-non-interactive t)
           (harness-tasks-model "demo:scripted")
           (harness-tasks-search-model 'auto)
           (harness-acp-token nil)
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       (unwind-protect (progn ,@body)
         (dolist (task (harness-call 'task/list))
           (ignore-errors (harness-call 'task/cancel (plist-get task :id))))
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))))))

(defun harness-tasks-search-test--submit (prompt)
  "Submit PROMPT as a task; return its id."
  (plist-get (harness-call 'task/submit default-directory prompt) :id))

(defun harness-tasks-search-test--task (id) (harness-call 'task/get id))

(defun harness-tasks-search-test--wait (id pred what)
  "Wait until task ID satisfies PRED, a function of the task."
  (harness-test-wait (lambda () (funcall pred (harness-tasks-search-test--task id))) 5
                     (format "task %s %s" id what)))

(defun harness-tasks-search-test--done (&rest ids)
  "Wait until every task of IDS is done."
  (dolist (id ids)
    (harness-tasks-search-test--wait id (lambda (task) (eq 'done (plist-get task :state))) "done")))

(defun harness-tasks-search-test--search (query &rest replies)
  "Run a search of QUERY whose model answers REPLIES; return its plan."
  (setq harness-tasks-search-test--replies replies)
  (harness-test-await (harness-call 'task/search default-directory query) 10))

(defun harness-tasks-search-test--asked (request)
  "The text of the last message REQUEST sent the model."
  (let ((msg (car (last (plist-get request :messages)))))
    (mapconcat (lambda (b) (or (plist-get b :text) "")) (plist-get msg :content) "")))

;;;; The plan

(ert-deftest harness-tasks-search-plans-what-the-model-answers ()
  "The model reads the board, newest first, and the query; its answer is
the plan: the tasks to show, best first, and the actions it proposes."
  (harness-tasks-search-test-with
    (let ((a (harness-tasks-search-test--submit "Add a question button to the chat"))
          (b (harness-tasks-search-test--submit "Remove the mq land skill")))
      (harness-tasks-search-test--done a b)
      (let ((c (harness-tasks-search-test--submit "fail now: fix the flaky parser test")))
        (harness-tasks-search-test--wait c (lambda (task) (eq 'error (plist-get task :outcome))) "failed")
        (let ((plan (harness-tasks-search-test--search
                     "  question button, and get rid of mq land  "
                     ;; In a fence, with an id short of its "t-".
                     (format "```json\n{\"show\":[\"%s\"],\"do\":[{\"task\":\"%s\",\"action\":\"archive\"}]}\n```"
                             a (substring b 2)))))
          (should (equal (list a b) (plist-get plan :ids)))
          (should (equal "question button, and get rid of mq land" (plist-get plan :query)))
          (should (equal "demo:scripted" (plist-get plan :model)))
          (should-not (plist-get plan :looked))
          (pcase-let ((`(,action) (plist-get plan :actions)))
            (should (equal b (plist-get action :task)))
            (should (equal "archive" (plist-get action :action)))
            (should (equal "Remove the mq land skill" (plist-get action :title)))
            ;; It undoes easily: the board runs it at once.
            (should (eq :false (plist-get action :confirm)))))
        (let* ((request (car harness-tasks-search-test--requests))
               (text (harness-tasks-search-test--asked request)))
          (should (string-prefix-p "task-search-" (plist-get (plist-get request :session) :id)))
          (should (string-match-p "^Project: .*Now: " text))
          (should (string-match-p "^3 tasks, newest first" text))
          (should (string-match-p (format "^%s | done: completed | Add a question button to the chat$"
                                          (regexp-quote a))
                                  text))
          (should (string-match-p (format "^%s | needs input: stopped (error) | fail now: fix the flaky parser test$"
                                          (regexp-quote c))
                                  text))
          (should (< (string-search c text) (string-search b text) (string-search a text)))
          (should (string-match-p "^Query: question button, and get rid of mq land$" text)))))))

(ert-deftest harness-tasks-search-keeps-only-what-means-something ()
  "Ids that name no task, unknown actions, actions that would do nothing
and words-carrying actions without words are dropped; a task acted on is
always shown; names an action goes by are understood."
  (harness-tasks-search-test-with
    (let ((a (harness-tasks-search-test--submit "First task"))
          (b (harness-tasks-search-test--submit "Second task"))
          (c (harness-tasks-search-test--submit "Third task")))
      (harness-tasks-search-test--done a b c)
      (let* ((plan (harness-tasks-search-test--search
                    "anything"
                    (harness-json-encode-text
                     (list :show (list "t-nothing" a a)
                           :do (list (list :task "t-nothing" :action "archive")
                                     (list :task a :action "explode")
                                     (list :task a :action "message")
                                     (list :task a :action "restore")
                                     (list :task b :action "Delete")
                                     (list :task c :action "tell" :text "  add a test  "))))))
             (actions (plist-get plan :actions)))
        (should (equal (list a b c) (plist-get plan :ids)))
        (should (equal '("archive" "message") (mapcar (lambda (x) (plist-get x :action)) actions)))
        (should (equal (list b c) (mapcar (lambda (x) (plist-get x :task)) actions)))
        (should (equal "add a test" (plist-get (nth 1 actions) :text)))
        (should-not (plist-get (car actions) :text))
        ;; Words to an agent wait for the user's OK.
        (should (eq t (plist-get (nth 1 actions) :confirm)))))))

(ert-deftest harness-tasks-search-waits-for-ok-where-it-stops-work ()
  "Stopping, archiving a task at work, verifying, completing and sending
words wait for the user's OK; retrying and starting do not."
  (harness-tasks-search-test-with
    (let ((busy (harness-tasks-search-test--submit "stay busy for a while"))
          (failed (harness-tasks-search-test--submit "fail now please")))
      (harness-tasks-search-test--wait busy (lambda (task) (eq 'active (plist-get task :column))) "at work")
      (harness-test-wait (lambda () (eq 'running (plist-get (harness-call 'session/get (plist-get (harness-tasks-search-test--task busy) :session)) :status)))
                         5 "running")
      (harness-tasks-search-test--wait failed (lambda (task) (plist-get task :outcome)) "failed")
      (let* ((plan (harness-tasks-search-test--search
                    "manage"
                    (harness-json-encode-text
                     (list :show nil
                           :do (list (list :task busy :action "archive")
                                     (list :task busy :action "stop")
                                     (list :task failed :action "retry")
                                     (list :task failed :action "stop")
                                     (list :task failed :action "complete"))))))
             (confirm (mapcar (lambda (x) (cons (plist-get x :action) (plist-get x :confirm)))
                              (plist-get plan :actions))))
        ;; Stopping a task that is not at work does nothing: dropped.
        (should (equal '(("archive" . t) ("stop" . t) ("retry" . :false) ("complete" . t)) confirm))))))

;;;; Looking further

(ert-deftest harness-tasks-search-looks-further-once ()
  "A model that asks to search the transcripts gets what they say, and
then answers; the plan says what it looked at."
  (harness-tasks-search-test-with
    (let ((a (harness-tasks-search-test--submit "The parser chokes on nested quotes"))
          (b (harness-tasks-search-test--submit "Speed up the test suite")))
      (harness-tasks-search-test--done a b)
      (let ((plan (harness-tasks-search-test--search
                   "which one was about quoting?"
                   "{\"grep\":\"NESTED quotes\"}"
                   (format "{\"read\":[\"%s\"],\"show\":[\"%s\"]}" b a))))
        (should (equal (list a) (plist-get plan :ids)))
        (should (equal "searched the transcripts for \"NESTED quotes\"" (plist-get plan :looked)))
        (should (= 2 (length harness-tasks-search-test--requests)))
        (let* ((again (car harness-tasks-search-test--requests))
               (text (harness-tasks-search-test--asked again)))
          (should (string-match-p (format "^%s: .*chokes on nested quotes" (regexp-quote a)) text))
          (should-not (string-match-p (regexp-quote b) text))
          (should (string-match-p "Now answer the query" text))
          ;; The conversation so far goes with it: the board, the request to look.
          (should (= 3 (length (plist-get again :messages))))
          (should (equal "{\"grep\":\"NESTED quotes\"}"
                         (plist-get (car (plist-get (nth 1 (plist-get again :messages)) :content)) :text))))
        ;; Reading transcripts, then answering.
        (setq harness-tasks-search-test--requests nil)
        (let ((plan (harness-tasks-search-test--search
                     "what is the suite one doing?"
                     (format "{\"read\":[\"%s\", \"t-none\"]}" b)
                     (format "{\"show\":[\"%s\"]}" b))))
          (should (equal (list b) (plist-get plan :ids)))
          (should (equal "read 1 transcript" (plist-get plan :looked)))
          (should (string-match-p (format "^%s, its latest transcript:\n  \\[user\\] Speed up the test suite"
                                          (regexp-quote b))
                                  (harness-tasks-search-test--asked (car harness-tasks-search-test--requests)))))))))

(ert-deftest harness-tasks-search-greps-very-long-lines ()
  "A node of megabytes does not fail a search of the transcripts.
grep prints the node's whole line of the log, and the regexp that split
the file name off it backtracked over all of it: \"Stack overflow in
regexp matcher\" once a line passed some hundred thousand characters."
  (harness-tasks-search-test-with
    (let ((a (harness-tasks-search-test--submit "Document the parser"))
          (b (harness-tasks-search-test--submit "Speed up the test suite")))
      (harness-tasks-search-test--done a b)
      (harness-call 'session/append (plist-get (harness-tasks-search-test--task a) :session)
                    (list :kind 'tool-result
                          :output (concat (make-string 1000 ?x) " see README.md for details "
                                          (make-string 1500000 ?y))))
      (let ((plan (harness-tasks-search-test--search
                   "which one touched the readme?"
                   "{\"grep\":\"readme.md\"}"
                   (format "{\"show\":[\"%s\"]}" a))))
        (should (equal (list a) (plist-get plan :ids)))
        (let ((text (harness-tasks-search-test--asked (car harness-tasks-search-test--requests))))
          (should (string-match-p (format "^%s: …x+ see README\\.md for details y+…$" (regexp-quote a)) text))
          (should-not (string-match-p (regexp-quote b) text))
          (should (< (length text) 1000)))))))

;;;; Failures

(ert-deftest harness-tasks-search-fails-without-an-answer ()
  "Prose, an error from the model, a model that takes too long and an
empty query fail the search, saying why."
  (harness-tasks-search-test-with
    (cl-flet ((fails (pattern &rest replies)
                (setq harness-tasks-search-test--replies replies)
                (let ((err (should-error (harness-test-await (harness-call 'task/search default-directory "q") 10))))
                  (should (string-match-p pattern (harness-error-message err))))))
      (fails "did not answer in JSON: Sure! Here are" "Sure! Here are your tasks.")
      (fails "gave no answer" "  ")
      (fails "The model failed: overloaded"
             '((:type text :delta "{") (:type done :stop-reason error :error "overloaded")))
      (let ((harness-tasks-search--timeout 0.3))
        (fails "took longer than" '((:type text :delta "{\"show\":"))))
      ;; It looks further once only.
      (fails "asked to look further again" "{\"grep\":\"x\"}" "{\"grep\":\"y\"}"))
    (should-error (harness-test-await (harness-call 'task/search default-directory "   ")))))

;;;; Acting

(ert-deftest harness-tasks-search-apply-runs-the-actions ()
  "Each action does what the search model was told it does, in order,
and says how it went; archive and restore undo each other."
  (harness-tasks-search-test-with
    (let ((done (harness-tasks-search-test--submit "Finished work"))
          (failed (harness-tasks-search-test--submit "fail now please"))
          (busy (harness-tasks-search-test--submit "stay busy for a while")))
      (harness-tasks-search-test--done done)
      (harness-tasks-search-test--wait failed (lambda (task) (plist-get task :outcome)) "failed")
      (harness-tasks-search-test--wait busy (lambda (task) (eq 'active (plist-get task :column))) "at work")
      (let ((harness-tasks-max-running 0))
        (let ((pending (harness-tasks-search-test--submit "Waits for a slot")))
          (let ((results (harness-test-await
                          (harness-call 'task/search-apply
                                        (list (list :task done :action "archive")
                                              (list :task pending :action "stop")
                                              (list :task done :action "verify")
                                              (list :task failed :action "retry")))
                          10)))
            (should (equal '(t :false :false t) (mapcar (lambda (r) (plist-get r :ok)) results)))
            (should (equal "Finished work" (plist-get (car results) :title)))
            (should (equal (list :task done :action "restore") (plist-get (car results) :undo)))
            (should (equal "it is not working" (plist-get (nth 1 results) :error)))
            (should (string-match-p "not waiting for review" (plist-get (nth 2 results) :error)))
            (should (harness-tasks-search-test--task done))
            (should (plist-get (harness-tasks-search-test--task done) :archived))
            ;; Stopping never drops a pending task.
            (should (harness-tasks-search-test--task pending))
            (harness-tasks-search-test--wait failed (lambda (task) (null (plist-get task :outcome))) "at work again"))
          ;; Restore undoes archive; a task at work is stopped, then archived.
          (let ((results (harness-test-await
                          (harness-call 'task/search-apply
                                        (list (list :task done :action "restore")
                                              (list :task busy :action "archive")
                                              (list :task done :action "message" :text "One more thing")))
                          30)))
            (should (equal '(t t t) (mapcar (lambda (r) (plist-get r :ok)) results)))
            (should (equal (list :task done :action "archive") (plist-get (car results) :undo)))
            (let ((task (harness-tasks-search-test--task busy)))
              (should (plist-get task :archived))
              (should (eq 'cancelled (plist-get task :outcome))))
            (should (equal "One more thing"
                           (plist-get (car (last (cl-remove-if-not
                                                  (lambda (n) (eq 'user (plist-get n :kind)))
                                                  (harness-call 'session/nodes
                                                                (plist-get (harness-tasks-search-test--task done) :session)))))
                                      :content)))))))))

;;;; The model's process and the cost

(ert-deftest harness-tasks-search-runs-each-search-in-a-process-of-its-own ()
  "A search takes the process warmed for it, under its own session id,
and closes it when done; one not warmed gets a new id; a process warmed
and never used is closed after a while."
  (harness-tasks-search-test-with
    (let ((warmed nil) (closed nil) (asked nil))
      (unwind-protect
          (progn
            (harness-define-provider 'test-search
              :models (lambda () (harness-resolved (list (list :name "m"))))
              :warm (lambda (request) (push (plist-get (plist-get request :session) :id) warmed) t)
              :close (lambda (sid) (push sid closed) t)
              :complete (lambda (request)
                          (push (plist-get (plist-get request :session) :id) asked)
                          (let ((on-event (plist-get request :on-event)))
                            (run-at-time 0.01 nil
                                         (lambda ()
                                           (funcall on-event '(:type text :delta "{\"show\":[]}"))
                                           (funcall on-event '(:type done :stop-reason end-turn)))))
                          (list :cancel #'ignore)))
            (let ((harness-tasks-search-model "test-search:m"))
              (should (equal '(:model "test-search:m" :warm t) (harness-call 'task/search-warm default-directory)))
              ;; Ready already.
              (should (equal '(:model "test-search:m" :warm t) (harness-call 'task/search-warm default-directory)))
              (should (= 1 (length warmed)))
              (harness-test-await (harness-call 'task/search default-directory "q"))
              (should (equal warmed asked))
              (should (equal warmed closed))
              ;; Not warmed: a new id, closed too.
              (harness-test-await (harness-call 'task/search default-directory "q"))
              (should (= 2 (length (delete-dups (copy-sequence asked)))))
              (should (equal asked closed))
              ;; Warmed and never used.
              (let ((harness-tasks-search--warm-idle 0.2))
                (harness-call 'task/search-warm default-directory)
                (harness-test-wait (lambda () (member (car warmed) closed)) 3 "the idle process to close"))))
        (remhash 'test-search harness-providers)
        (harness-provider--forget 'test-search)))))

(ert-deftest harness-tasks-search-records-what-it-costs ()
  "Each call of the search model is a usage record of the board's project."
  (harness-tasks-search-test-with
    (let ((rows nil))
      (harness-register-method 'usage/record (lambda (row) (push row rows) row))
      (harness-tasks-search-test--search "q" "{\"grep\":\"x\"}" "{\"show\":[]}")
      (should (= 2 (length rows)))
      (let ((row (car rows)))
        (should (equal "demo:scripted" (plist-get row :model)))
        (should (equal (harness-call 'project/root default-directory) (plist-get row :project)))
        (should-not (plist-get row :session))
        (should (= 1200 (plist-get row :input)))
        (should (= 0.0015 (plist-get row :cost)))))))

(ert-deftest harness-tasks-search-demo-answers-from-the-words ()
  "The demo provider answers a search from the words of the query, so
the board's search works offline: topics, states and orders."
  (harness-tasks-search-test-with
    (let ((harness-provider-demo-script-override
           (lambda (request)
             (if (harness-tasks-search-test--search-p request)
                 (harness-provider-demo--search request)
               (harness-tasks-search-test--script request)))))
      (let ((button (harness-tasks-search-test--submit "Add a question button to the chat"))
            (land (harness-tasks-search-test--submit "Get rid of the mq land skill")))
        (harness-tasks-search-test--done button land)
        (let ((failed (harness-tasks-search-test--submit "fail now: the parser")))
          (harness-tasks-search-test--wait failed (lambda (task) (plist-get task :outcome)) "failed")
          (cl-flet ((search (q) (harness-test-await (harness-call 'task/search default-directory q) 10)))
            (should (equal (list button) (plist-get (search "did I have a task about adding the question button") :ids)))
            (let ((plan (search "get rid of mq land task")))
              (should (equal (list land) (plist-get plan :ids)))
              (should (equal '("archive") (mapcar (lambda (a) (plist-get a :action)) (plist-get plan :actions)))))
            (let ((plan (search "restart errored tasks")))
              (should (equal (list failed) (plist-get plan :ids)))
              (should (equal '("retry") (mapcar (lambda (a) (plist-get a :action)) (plist-get plan :actions)))))))))))

(declare-function harness-provider-demo--search "harness-provider-demo")

(provide 'harness-tasks-search-test)
;;; harness-tasks-search-test.el ends here
