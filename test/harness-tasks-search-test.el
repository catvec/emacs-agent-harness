;;; harness-tasks-search-test.el --- Tests for the task board's search  -*- lexical-binding: t; -*-

;;; Commentary:

;; Drives `search/ask', `task/search-apply' and `search/warm' against the
;; real state layer, the session search and the demo provider, whose
;; replies a test scripts per request: the board the model reads, the
;; plan made of its answer, looking further once, failures, the actions,
;; the model process of each search and what a search costs.

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
  "Load the state layer, tasks and their search with the demo provider; run BODY.
The session search, which searches the transcripts, loads too."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent priority
                          tasks session-search tasks-search acp))
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
  "Search for QUERY favouring tasks, the model answering REPLIES; return the plan."
  (setq harness-tasks-search-test--replies replies)
  (harness-test-await (harness-call 'search/ask default-directory query '(:bias "tasks")) 10))

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

(ert-deftest harness-tasks-search-looks-further-by-the-session-search ()
  "The transcripts are searched for the words in any form, best match
first; when none has every word, the model is told the ones listed have
some of them, and when none has any, that none does."
  (harness-tasks-search-test-with
    (let ((a (harness-tasks-search-test--submit "The parser chokes on nested quotes"))
          (b (harness-tasks-search-test--submit "Speed up the test suite")))
      (harness-tasks-search-test--done a b)
      (let ((plan (harness-tasks-search-test--search
                   "which one was about quoting?" "{\"grep\":\"quoting parsers\"}"
                   (format "{\"show\":[\"%s\"]}" a))))
        (should (equal (list a) (plist-get plan :ids)))
        (let ((text (harness-tasks-search-test--asked (car harness-tasks-search-test--requests))))
          (should (string-match-p "^Task sessions that mention \"quoting parsers\":$" text))
          (should (string-match-p (format "^%s: .*parser chokes on nested quotes" (regexp-quote a)) text))
          (should-not (string-match-p (regexp-quote b) text))))
      (harness-tasks-search-test--search "q" "{\"grep\":\"suite giraffe\"}" "{\"show\":[]}")
      (let ((text (harness-tasks-search-test--asked (car harness-tasks-search-test--requests))))
        (should (string-match-p "^No task session mentions all of \"suite giraffe\"; these mention some of it:$"
                                text))
        (should (string-match-p (format "^%s: .*Speed up the test suite" (regexp-quote b)) text))
        (should-not (string-match-p (regexp-quote a) text)))
      (harness-tasks-search-test--search "q" "{\"grep\":\"giraffe\"}" "{\"show\":[]}")
      (should (string-match-p "^No task session mentions \"giraffe\"\\.$"
                              (harness-tasks-search-test--asked (car harness-tasks-search-test--requests)))))))

;;;; Failures

(ert-deftest harness-tasks-search-fails-without-an-answer ()
  "JSON that breaks off before any answer in words, an error from the
model, a model that takes too long and an empty query fail the search,
saying why."
  (harness-tasks-search-test-with
    (cl-flet ((fails (pattern &rest replies)
                (setq harness-tasks-search-test--replies replies)
                (let ((err (should-error (harness-test-await
                                          (harness-call 'search/ask default-directory "q" '(:bias "tasks"))
                                          10))))
                  (should (string-match-p pattern (harness-error-message err))))))
      (fails "JSON did not parse: {\"show\":" "{\"show\":[\"t-1\",")
      (fails "gave no answer" "  ")
      (fails "The model failed: overloaded"
             '((:type text :delta "{") (:type done :stop-reason error :error "overloaded")))
      (let ((harness-tasks-search--timeout 0.3))
        (fails "took longer than" '((:type text :delta "{\"show\":"))))
      ;; It looks further once only.
      (fails "asked to look further again" "{\"grep\":\"x\"}" "{\"grep\":\"y\"}"))
    (should-error (harness-test-await (harness-call 'search/ask default-directory "   " '(:bias "tasks"))))))

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

(ert-deftest harness-tasks-search-sets-priorities ()
  "The model reads the priorities that are not medium, and may set one:
a priority action names low, medium or high, runs at once, and its undo
gives the task the priority it had.  One that changes nothing, names no
priority or is for a done task is dropped."
  (harness-tasks-search-test-with
    (let ((done (harness-tasks-search-test--submit "Finished work")))
      (harness-tasks-search-test--done done)
      (let* ((harness-tasks-max-running 0)
             (docs (harness-tasks-search-test--submit "Write the docs"))
             (bug (plist-get (harness-call 'task/submit default-directory "Fix the login bug"
                                           (list :priority "high"))
                             :id))
             (later (harness-tasks-search-test--submit "Tidy the changelog"))
             (plan (harness-tasks-search-test--search
                    "the docs first, the changelog whenever"
                    (harness-json-encode-text
                     (list :show (list docs later)
                           :do (list (list :task docs :action "prioritize" :text " High ")
                                     (list :task bug :action "priority" :text "high")
                                     (list :task later :action "priority" :text "urgent")
                                     (list :task later :action "priority")
                                     (list :task done :action "priority" :text "low")
                                     (list :task later :action "priority" :text "low"))))))
             (actions (plist-get plan :actions)))
        ;; The board the model read says which tasks are not medium.
        (let ((text (harness-tasks-search-test--asked (car harness-tasks-search-test--requests))))
          (should (string-match-p (format "^%s | .*\n  priority high; created " (regexp-quote bug)) text))
          (should-not (string-match-p "priority \\(medium\\|low\\)" text)))
        (should (equal (list (list docs "priority" "high" :false) (list later "priority" "low" :false))
                       (mapcar (lambda (a) (list (plist-get a :task) (plist-get a :action)
                                                 (plist-get a :text) (plist-get a :confirm)))
                               actions)))
        (let ((results (harness-test-await (harness-call 'task/search-apply actions) 10)))
          (should (equal '(t t) (mapcar (lambda (r) (plist-get r :ok)) results)))
          (should (equal '("high" "low") (mapcar (lambda (r) (plist-get r :text)) results)))
          (should (equal (list (list :task docs :action "priority" :text "medium")
                               (list :task later :action "priority" :text "medium"))
                         (mapcar (lambda (r) (plist-get r :undo)) results)))
          (should (eq 'high (plist-get (harness-tasks-search-test--task docs) :priority)))
          (should (eq 'low (plist-get (harness-tasks-search-test--task later) :priority)))
          ;; Nothing starts: a priority only orders the queue.
          (should (eq 'pending (plist-get (harness-tasks-search-test--task docs) :state)))
          ;; The undo puts the old priority back.
          (harness-test-await (harness-call 'task/search-apply (mapcar (lambda (r) (plist-get r :undo)) results)) 10)
          (should (eq 'medium (plist-get (harness-tasks-search-test--task docs) :priority)))
          (should (eq 'medium (plist-get (harness-tasks-search-test--task later) :priority))))
        ;; Run without a priority it names, it fails and changes nothing.
        (let ((results (harness-test-await
                        (harness-call 'task/search-apply
                                      (list (list :task docs :action "priority" :text "urgent")
                                            (list :task docs :action "priority")))
                        10)))
          (should (equal '(:false :false) (mapcar (lambda (r) (plist-get r :ok)) results)))
          (should (string-match-p "unknown priority urgent" (plist-get (car results) :error)))
          (should (eq 'medium (plist-get (harness-tasks-search-test--task docs) :priority))))))))

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
              (should (equal '(:model "test-search:m" :warm t) (harness-call 'search/warm default-directory)))
              ;; Ready already.
              (should (equal '(:model "test-search:m" :warm t) (harness-call 'search/warm default-directory)))
              (should (= 1 (length warmed)))
              ;; The process serves a search whatever it favours.
              (harness-test-await (harness-call 'search/ask default-directory "q" '(:bias "commands")))
              (should (equal warmed asked))
              (should (equal warmed closed))
              ;; Not warmed: a new id, closed too.
              (harness-test-await (harness-call 'search/ask default-directory "q" '(:bias "tasks")))
              (should (= 2 (length (delete-dups (copy-sequence asked)))))
              (should (equal asked closed))
              ;; Warmed and never used.
              (let ((harness-tasks-search--warm-idle 0.2))
                (harness-call 'search/warm default-directory)
                (harness-test-wait (lambda () (member (car warmed) closed)) 3 "the idle process to close"))))
        (remhash 'test-search harness-providers)
        (harness-provider--forget 'test-search)))))

(ert-deftest harness-tasks-search-records-what-it-costs ()
  "Each call of the search model is an internal session of the board's
project, \"Task search\", which carries its usage: the search records
none itself, so nothing is counted twice.  Without internal sessions,
each call is a usage record of the board's project."
  (harness-tasks-search-test-with
    (let ((rows nil))
      (harness-register-method 'usage/record (lambda (row) (push row rows) row))
      (harness-tasks-search-test--search "q" "{\"grep\":\"x\"}" "{\"show\":[]}")
      (should-not rows)
      (let ((calls (harness-call 'session/list (list :kind 'internal))))
        (should (= 2 (length calls)))
        (dolist (s calls)
          (should (equal "Task search" (plist-get s :name)))
          (should (equal "demo:scripted" (plist-get s :model)))
          (should (equal (harness-call 'project/root default-directory) (plist-get s :project)))
          (should (eq 'idle (plist-get s :status)))
          (should (= 1200 (plist-get (plist-get s :usage) :input)))
          (should (= 0.0015 (plist-get (plist-get s :usage) :cost)))))
      (remhash 'session/internal-start harness--methods)
      (harness-tasks-search-test--search "q" "{\"grep\":\"x\"}" "{\"show\":[]}")
      (should (= 2 (length rows)))
      (should (= 2 (length (harness-call 'session/list (list :kind 'internal)))))
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
          (cl-flet ((search (q) (harness-test-await (harness-call 'search/ask default-directory q '(:bias "tasks")) 10)))
            (should (equal (list button) (plist-get (search "did I have a task about adding the question button") :ids)))
            (let ((plan (search "get rid of mq land task")))
              (should (equal (list land) (plist-get plan :ids)))
              (should (equal '("archive") (mapcar (lambda (a) (plist-get a :action)) (plist-get plan :actions)))))
            (let ((plan (search "restart errored tasks")))
              (should (equal (list failed) (plist-get plan :ids)))
              (should (equal '("retry") (mapcar (lambda (a) (plist-get a :action)) (plist-get plan :actions)))))
            (let* ((docs (let ((harness-tasks-max-running 0))
                           (harness-tasks-search-test--submit "Write the parser docs")))
                   (plan (search "prioritize the parser docs")))
              (should (equal (list docs) (plist-get plan :ids)))
              (should (equal '(("priority" "high"))
                             (mapcar (lambda (a) (list (plist-get a :action) (plist-get a :text)))
                                     (plist-get plan :actions)))))))))))

(declare-function harness-provider-demo--search "harness-provider-demo")

;;;; Searching the whole harness

(declare-function harness-tasks-search--words "harness-tasks-search")
(declare-function harness-tasks-search--score "harness-tasks-search")
(declare-function harness-tasks-search--resolve-session "harness-tasks-search")
(declare-function harness-tasks-search--resolve-command "harness-tasks-search")
(declare-function harness-tasks-search--rank-commands "harness-tasks-search")
(declare-function harness-tasks-search--catalogue "harness-tasks-search")
(declare-function harness-tasks-search--looked "harness-tasks-search")
(declare-function harness-acp--call-extension "harness-acp")

(defconst harness-tasks-search-test--catalogue
  '((:command "harness-compose-add-attachment" :keys "C-c C-a" :where "Chat" :label "Attach file"
     :doc "Attach PATH to the next message." :here t)
    (:command "harness-ui-sessions" :keys "C-c h l" :where "menu" :label "List sessions"
     :doc "List every session, newest first." :here :false)
    (:command "harness-tasks-search" :keys "/" :where "Board" :label "Search tasks"
     :doc "Find or act on tasks in words." :here :false)
    (:command "harness-new-session" :keys "C-c h n" :where "menu" :label "New session"
     :doc "Start a session in a directory." :here :false))
  "Commands as a UI sends them to a search.")

(defun harness-tasks-search-test--ask (query opts &rest replies)
  "Run `search/ask' of QUERY with OPTS; return its plan.
The model answers REPLIES in turn."
  (setq harness-tasks-search-test--replies replies
        harness-tasks-search-test--requests nil)
  (harness-test-await (harness-call 'search/ask default-directory query opts) 10))

(defun harness-tasks-search-test--first ()
  "The first message the model got in the last search."
  (harness-tasks-search-test--asked (car (last harness-tasks-search-test--requests))))

(defun harness-tasks-search-test--session (name &rest plist)
  "Make a session called NAME, with PLIST, that works on no task; return its id."
  (plist-get (apply #'harness-call 'session/create :cwd default-directory :name name plist) :id))

(defun harness-tasks-search-test--ids (things)
  "The ids of THINGS, plists."
  (mapcar (lambda (thing) (plist-get thing :id)) things))

(defmacro harness-tasks-search-test-with-session-search (fn &rest body)
  "Run BODY with FN standing in for `session/search'."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'harness-method/session/search) ,fn))
     ,@body))

(ert-deftest harness-tasks-search-ask-favours-tasks-on-the-board ()
  "On the board the search favours tasks: the model is told so, reads the
board, and the plan shows the task, with what a view without the board
shows of it."
  (harness-tasks-search-test-with
    (let ((button (harness-tasks-search-test--submit "Add a question button to the chat"))
          (land (harness-tasks-search-test--submit "Remove the mq land skill")))
      (harness-tasks-search-test--done button land)
      (let ((plan (harness-tasks-search-test--ask
                   "did I have a task about the question button?"
                   (list :context (list :view "board") :commands harness-tasks-search-test--catalogue)
                   (format "{\"show\":[\"%s\"]}" button)))
            (text (harness-tasks-search-test--first)))
        (should (equal "tasks" (plist-get plan :bias)))
        (should (equal (list button) (plist-get plan :ids)))
        (should (equal (list (list :id button :title "Add a question button to the chat" :status "done: completed"
                                   :session (plist-get (harness-tasks-search-test--task button) :session)))
                       (plist-get plan :tasks)))
        (should (eq :false (plist-get plan :widened)))
        (should-not (plist-get plan :note))
        (should-not (plist-get plan :sessions))
        (should (string-match-p "^Project: .*Now: .*\nContext: the task board of project [^ ]+\\. Favour tasks; sessions and commands count too\\.$"
                                text))
        (should (string-match-p "^2 tasks, newest first" text))
        (should (string-match-p (format "^%s | done: completed | Add a question button to the chat$"
                                        (regexp-quote button))
                                text))
        (should (string-match-p "^Query: did I have a task about the question button\\?$" text))
        ;; Commands are not what it favours: only those the words match.
        (should-not (string-match-p "^Commands" text))))))

(ert-deftest harness-tasks-search-ask-opens-a-session-off-the-board ()
  "Away from the board the search reaches every session: the model asks
to search them, and the plan names the session it picks by the start of
its id, with what the search found in it.  The session the engineer is
in stays out of it."
  (harness-tasks-search-test-with
    (let* ((here (harness-tasks-search-test--session "Write the release notes"))
           (merge (harness-tasks-search-test--session "Land the queue fix" :kind 'btw))
           (calls nil))
      (harness-tasks-search-test-with-session-search
          (lambda (query opts)
            (push (list query opts) calls)
            (harness-resolved
             (list :query query :mode 'text :engine "fts" :loose nil
                   :sessions (and (string-match-p "merge queue" query)
                                  (list (append (harness-call 'session/get merge)
                                                (list :hits (list (list :snippet "…why the merge queue dropped a commit…")))))))))
        (let ((plan (harness-tasks-search-test--ask
                     "open the session where I debugged the merge queue"
                     (list :context (list :view "chat" :title "Write the release notes" :session here))
                     "{\"sessions\":\"merge queue\"}"
                     (format "{\"sessions\":[\"%s\"]}" (substring merge 0 8))))
              (here8 (substring here 0 8))
              (merge8 (substring merge 0 8)))
          (should (equal "commands" (plist-get plan :bias)))
          (should (equal "searched the sessions for \"merge queue\"" (plist-get plan :looked)))
          (pcase-let ((`(,session) (plist-get plan :sessions)))
            (should (equal merge (plist-get session :id)))
            (should (equal "Land the queue fix" (plist-get session :name)))
            (should (equal "btw" (plist-get session :kind)))
            (should (equal "idle" (plist-get session :status)))
            (should (equal "…why the merge queue dropped a commit…" (plist-get session :snippet)))
            (should-not (plist-get session :task)))
          (should (eq :false (plist-get plan :widened)))
          ;; Every session was searched but the engineer's.
          (should (equal '("merge queue") (mapcar #'car calls)))
          (should (equal (list here) (plist-get (cadr (car calls)) :exclude)))
          (let ((first (harness-tasks-search-test--first))
                (again (harness-tasks-search-test--asked (car harness-tasks-search-test--requests))))
            (should (string-match-p
                     (format "^Context: the chat of session “Write the release notes” (%s)\\. Favour commands, then sessions; tasks count too\\. Leave session %s out of \"sessions\": the engineer is in it\\.$"
                             here8 here8)
                     first))
            (should (string-match-p "^Sessions besides the board's tasks (chats, side conversations, sub-agents, forks), best match first:$"
                                    first))
            (should (string-match-p (format "^%s | btw | idle | [^|]+ | updated [^|]+ | Land the queue fix$" merge8) first))
            (should-not (string-match-p (format "^%s | " here8) first))
            (should (string-match-p "^Sessions that mention \"merge queue\", best first:$" again))
            (should (string-match-p (format "^%s | btw | idle | [^|]+ | Land the queue fix: …why the merge queue dropped a commit…$"
                                            merge8)
                                    again))
            (should (string-match-p "Now answer the query" again))))))))

(defun harness-tasks-search-test--count (regexp text)
  "How many times REGEXP matches in TEXT."
  (let ((n 0) (start 0))
    (while (string-match regexp text start)
      (setq n (1+ n) start (match-end 0)))
    n))

(ert-deftest harness-tasks-search-ask-says-where-a-session-matched ()
  "A session a look at the transcripts found says where it matched: the
node its first match is in, the passage around it and where the words
are in that passage.  One the model named from the list, which no look
found, says nothing of the kind."
  (harness-tasks-search-test-with
    (let* ((merge (harness-tasks-search-test--session "Fix a thing"))
           (notes (harness-tasks-search-test--session "Write the release notes"))
           (node (plist-get (harness-call 'session/append merge
                                          (list :kind 'user :content "Why did the merge queue drop a commit?"))
                            :id))
           (plan (harness-tasks-search-test--ask
                  "the queue that dropped a commit"
                  (list :context (list :view "chat"))
                  "{\"sessions\":\"merge queue\"}"
                  (format "{\"sessions\":[\"%s\",\"%s\"]}" (substring merge 0 8) (substring notes 0 8)))))
      (should (equal (list merge notes) (harness-tasks-search-test--ids (plist-get plan :sessions))))
      (pcase-let ((`(,found ,named) (plist-get plan :sessions)))
        (let ((snippet (plist-get found :snippet))
              (ranges (plist-get found :ranges)))
          (should (equal node (plist-get found :node)))
          (should (string-match-p "merge queue drop a commit" snippet))
          ;; The words, one range each or one for both.
          (should ranges)
          (should (equal "merge queue" (downcase (substring snippet (car (car ranges)) (cadr (car (last ranges))))))))
        (should (equal "Write the release notes" (plist-get named :name)))
        (should-not (plist-get named :node))
        (should-not (plist-get named :snippet))
        (should-not (plist-get named :ranges))))))

(ert-deftest harness-tasks-search-ask-says-what-the-sessions-were-searched-for ()
  "The plan carries the text the transcripts were searched with, or would
be, which a view that shows every match in them searches for: what the
model asked the transcripts for when it looked, else the words of the
query that say something, and none when the query has none."
  (harness-tasks-search-test-with
    (harness-tasks-search-test--session "Debug the merge queue")
    (cl-flet ((sought (query view &rest replies)
                (plist-get (apply #'harness-tasks-search-test--ask
                                  query (list :context (list :view view)) replies)
                           :session-query)))
      ;; No look: the words that say something, not "where did I" --
      ;; the ones an up-front search and widening search for.
      (should (equal "debug merge queue"
                     (sought "where did I debug the merge queue?" "chat" "{\"show\":[]}")))
      (should (equal "debug merge queue"
                     (sought "where did I debug the merge queue?" "sessions" "{\"show\":[]}")))
      (should (equal "debug merge queue"
                     (sought "where did I debug the merge queue?" "board" "{\"show\":[]}")))
      ;; A look at the sessions' transcripts, or the tasks': what the model asked for.
      (should (equal "merge queue"
                     (sought "that queue thing" "chat" "{\"sessions\":\"merge queue\"}" "{\"show\":[]}")))
      (should (equal "queue merge"
                     (sought "that queue thing" "board" "{\"grep\":\"queue merge\"}" "{\"show\":[]}")))
      ;; Both: every session's.
      (should (equal "merge queue"
                     (sought "that queue thing" "chat"
                             "{\"grep\":\"queue\",\"sessions\":\"merge queue\"}" "{\"show\":[]}")))
      ;; A look at something else says nothing of the transcripts.
      (should (equal "queue thing"
                     (sought "that queue thing" "chat" "{\"commands\":\"queue\"}" "{\"show\":[]}")))
      ;; Nothing in the query says anything to look for.
      (should-not (sought "open the session please" "chat" "{\"show\":[]}")))))

(ert-deftest harness-tasks-search-ask-searches-the-transcripts-first-for-sessions ()
  "Favouring sessions, the search searches every transcript for the
query's words before the model reads anything: a session whose
transcript mentions them, not its name, is in the first message with
what it says, and not again among the sessions ranked by name; the
model names it at once.  A query of nothing but words that say nothing
searches no transcript, and no other bias does."
  (harness-tasks-search-test-with
    (let* ((merge (harness-tasks-search-test--session "Fix a thing"))
           (notes (harness-tasks-search-test--session "Write the release notes"))
           (merge8 (substring merge 0 8))
           (calls 0))
      (harness-call 'session/append merge (list :kind 'user :content "Why did the merge queue drop a commit?"))
      (let ((plan (harness-tasks-search-test--ask
                   "where did the merge queue drop a commit?"
                   (list :context (list :view "sessions"))
                   (format "{\"sessions\":[\"%s\"]}" merge8)))
            (first (harness-tasks-search-test--first)))
        (should (equal "sessions" (plist-get plan :bias)))
        (should (equal (list merge) (harness-tasks-search-test--ids (plist-get plan :sessions))))
        (should (plist-get (car (plist-get plan :sessions)) :node))
        (should-not (plist-get plan :looked))
        ;; The words the transcripts were searched for, which a view that
        ;; shows every match searches too.
        (should (equal "merge queue drop commit" (plist-get plan :session-query)))
        (should (= 1 (length harness-tasks-search-test--requests)))
        (should (string-match-p "^Context: the session list\\. Favour sessions, then commands; tasks count too\\.$"
                                first))
        (should (string-match-p
                 (format "^Sessions that mention \"merge queue drop commit\", best first:\n%s | chat | idle | [^|]+ | Fix a thing: .*merge queue drop a commit"
                         merge8)
                 first))
        ;; Listed once: the sessions ranked by name leave it out.
        (should (= 1 (harness-tasks-search-test--count (format "^%s | " merge8) first)))
        (should (string-match-p (format "^Sessions besides the board's tasks .*:\n%s | chat | idle | " (substring notes 0 8))
                                first))
        ;; What the transcripts say comes before the sessions ranked by name.
        (should (< (string-search "Sessions that mention" first) (string-search "Sessions besides" first))))
      (harness-tasks-search-test-with-session-search
          (lambda (&rest _) (cl-incf calls) (harness-resolved (list :engine "fts" :sessions nil)))
        (harness-tasks-search-test--ask "open the session please" (list :context (list :view "sessions"))
                                        "{\"sessions\":[]}")
        (should-not (string-match-p "mention" (harness-tasks-search-test--first)))
        (harness-tasks-search-test--ask "the merge queue" (list :context (list :view "board")) "{\"show\":[]}")
        (should-not (string-match-p "mention" (harness-tasks-search-test--first)))
        ;; Only the board's search looked for what comes nearest, once its
        ;; model answered with nothing: the other query has no word to
        ;; look for.
        (should (= 1 calls))))))

(ert-deftest harness-tasks-search-ask-says-when-the-session-search-fails ()
  "A session search that fails fails no search: the model is told so, up
front and when it looks further, and answers from the rest."
  (harness-tasks-search-test-with
    (harness-tasks-search-test-with-session-search
        (lambda (&rest _) (harness-rejected (list 'error "The index is gone.")))
      (let ((plan (harness-tasks-search-test--ask
                   "the merge queue" (list :context (list :view "sessions"))
                   "{\"sessions\":\"merge queue\"}" "{\"sessions\":[]}")))
        (should (eq t (plist-get plan :widened)))
        (should (equal "searched the sessions for \"merge queue\"" (plist-get plan :looked)))
        (should (string-match-p "^The session search failed: The index is gone\\.$" (harness-tasks-search-test--first)))
        (should (string-match-p "^The session search failed: The index is gone\\.$"
                                (harness-tasks-search-test--asked (car harness-tasks-search-test--requests))))))))

(ert-deftest harness-tasks-search-ask-finds-commands ()
  "Asked how to do something, the search shows the model the commands
whose words match, and the menu's, and the plan holds the commands it
names that there are.  A UI asks over ACP."
  (harness-tasks-search-test-with
    (setq harness-tasks-search-test--replies
          '("{\"commands\":[\"harness-compose-add-attachment\",\"no-such-command\"]}")
          harness-tasks-search-test--requests nil)
    (let ((plan (harness-test-await
                 (harness-acp--call-extension
                  "search/ask"
                  ;; As the JSON of a request reads.
                  (list :cwd default-directory :query "how do I attach a file?"
                        :opts (list :context (list :view "buffer" :title "notes.org" :mode "org-mode")
                                    :commands harness-tasks-search-test--catalogue)))
                 10))
          (text (harness-tasks-search-test--first)))
      (should (equal "commands" (plist-get plan :bias)))
      (should (equal (list (car harness-tasks-search-test--catalogue)) (plist-get plan :commands)))
      (should (eq :false (plist-get plan :widened)))
      (should (string-match-p "^Context: Emacs buffer “notes\\.org” (org-mode)\\. Favour commands, then sessions; tasks count too\\.$"
                              text))
      (should (string-match-p "^The board has no tasks\\.$" text))
      (should (string-match-p "^Commands (name | keys | where | what it does):
harness-compose-add-attachment | C-c C-a | Chat | Attach file — Attach PATH to the next message\\.$"
                              text))
      ;; Few match: the menu's come too, so the model knows what there is.
      (should (string-match-p "^harness-ui-sessions | C-c h l | menu | List sessions — List every session, newest first\\.$" text))
      (should (string-match-p "^harness-new-session | C-c h n | menu | " text))
      (should-not (string-match-p "^harness-tasks-search | " text)))))

(defconst harness-tasks-search-test--phone-request
  (concat
   "{\"cwd\":\"%s\",\"query\":\"how do I attach an image to a task?\","
   "\"opts\":{\"bias\":\"commands\","
   "\"context\":{\"view\":\"buffer\",\"title\":\"Usage\",\"mode\":\"phone app\","
   "\"session\":null,\"project\":\"%s\",\"client\":\"phone app\"},"
   "\"commands\":["
   "{\"command\":\"new-task\",\"keys\":\"Tasks › +\",\"where\":\"menu\","
   "\"label\":\"Submit a new task\","
   "\"doc\":\"Describe the work, attach pictures with the image button, send.\","
   "\"here\":true},"
   "{\"command\":\"open-usage\",\"keys\":null,\"where\":\"menu\","
   "\"label\":\"Open usage\",\"doc\":\"Spend, tokens and plan quota.\",\"here\":true}]}}")
  "What the harness's phone app sends `search/ask', as its JSON reads.
Its \"commands\" are the app's own actions, with the taps that reach them
where Emacs commands have keys.")

(ert-deftest harness-tasks-search-ask-serves-the-phone-app ()
  "The phone app asks over ACP in JSON, with its own catalogue and `:client':
the model is told the engineer is on a phone app and the commands are the
app's own, with the taps that reach them; the plan names the app's
commands, whole, and encodes as the app reads it."
  (harness-tasks-search-test-with
    (setq harness-tasks-search-test--replies
          '("{\"commands\":[\"new-task\"],\"answer\":\"Tap **+** on the Tasks screen, then the image button.\"}")
          harness-tasks-search-test--requests nil)
    (let* ((params (harness-json-parse
                    (format harness-tasks-search-test--phone-request default-directory default-directory)))
           (plan (harness-test-await (harness-acp--call-extension "search/ask" params) 10))
           (text (harness-tasks-search-test--first)))
      (should (equal "commands" (plist-get plan :bias)))
      (should (equal "Tap **+** on the Tasks screen, then the image button." (plist-get plan :answer)))
      (should (equal (list (list :command "new-task" :keys "Tasks › +" :where "menu"
                                 :label "Submit a new task"
                                 :doc "Describe the work, attach pictures with the image button, send."
                                 :here t))
                     (plist-get plan :commands)))
      ;; Where it was asked, who asks, and what the commands are.
      (should (string-match-p
               "^Context: the phone app, on its “Usage” screen\\. Favour commands, then sessions; tasks count too\\. The engineer is on the harness's phone app, not in Emacs: the commands are that app's own actions (screens to open, things to do), and a command's keys are the taps that reach it\\.$"
               text))
      (should (string-match-p "^Commands (name | keys | where | what it does):
new-task | Tasks › \\+ | menu | Submit a new task — Describe the work, attach pictures with the image button, send\\.$"
                              text))
      (should (string-match-p "^open-usage | menu | Open usage — Spend, tokens and plan quota\\.$" text))
      ;; The plan goes back as JSON, which the app reads.
      (let ((wire (harness-json-parse (harness-json-encode plan))))
        (should (equal "new-task" (plist-get (car (plist-get wire :commands)) :command)))
        (should (equal "Tasks › +" (plist-get (car (plist-get wire :commands)) :keys)))
        (should (eq :false (plist-get wire :widened)))))))

(ert-deftest harness-tasks-search-ask-says-which-screen-of-the-app ()
  "A client says the same of the places the search has views for: the
board, the session list and a chat read as they do in Emacs, then the
sentence about the app's own commands, and a client's name never opens
the door to a second line."
  (harness-tasks-search-test-with
    (let* ((here (harness-tasks-search-test--session "Write the release notes"))
           (here8 (substring here 0 8))
           (client "phone app"))
      (cl-flet ((line (context bias)
                  (harness-tasks-search-test--ask "anything" (list :bias bias :context context) "{\"show\":[]}")
                  (cadr (split-string (harness-tasks-search-test--first) "\n"))))
        (let ((sentence " The engineer is on the harness's phone app, not in Emacs: the commands are that app's own actions (screens to open, things to do), and a command's keys are the taps that reach it."))
          (should (string-match-p
                   (concat "^Context: the task board of project [^ ]+\\. Favour tasks; sessions and commands count too\\."
                           (regexp-quote sentence) "$")
                   (line (list :view "board" :client client) "tasks")))
          (should (equal (concat "Context: the session list. Favour sessions, then commands; tasks count too." sentence)
                         (line (list :view "sessions" :client client) "sessions")))
          (should (equal (concat (format "Context: the chat of session “Write the release notes” (%s). Favour commands, then sessions; tasks count too."
                                         here8)
                                 sentence
                                 (format " Leave session %s out of \"sessions\": the engineer is in it." here8))
                         (line (list :view "chat" :title "Write the release notes" :session here :client client)
                               "commands")))
          ;; Nothing but the name: no screen to say.
          (should (equal (concat "Context: the phone app. Favour commands, then sessions; tasks count too." sentence)
                         (line (list :view "buffer" :client client) "commands")))
          ;; A client's name is one short line.
          (should (string-match-p
                   "^Context: the phone app on a very long name[^\n]*…, on its “Usage” screen\\."
                   (line (list :view "buffer" :title "Usage"
                               :client "phone app on a very long name that goes on and on and on\nand on and on and on and on")
                         "commands"))))
        ;; Without a client, nothing changes: Emacs says so as ever.
        (should (equal "Context: Emacs buffer “Usage” (some-mode). Favour commands, then sessions; tasks count too."
                       (line (list :view "buffer" :title "Usage" :mode "some-mode") "commands")))))))

(ert-deftest harness-tasks-search-system-prompt-knows-the-phone-app ()
  "The one system prompt, which a warm process serves whatever asks, says
what the commands are when the context line names a phone app."
  (should (string-match-p "context line says the engineer is on a phone app" harness-tasks-search--system))
  (should (string-match-p "never with Emacs keys or commands" harness-tasks-search--system)))

(ert-deftest harness-tasks-search-ask-widens-when-nothing-matches ()
  "A search the model answers with nothing adds the sessions and commands
that come nearest the query itself, and says so; a model that widens the
search itself says so in its note, which the plan passes on."
  (harness-tasks-search-test-with
    (let ((suite (harness-tasks-search-test--submit "Speed up the test suite")))
      (harness-tasks-search-test--done suite)
      (let* ((flaky (harness-tasks-search-test--session "Debug the flaky login test"))
             (flaky8 (substring flaky 0 8))
             (plan (harness-tasks-search-test--ask
                    "the flaky login"
                    (list :context (list :view "board") :commands harness-tasks-search-test--catalogue)
                    "{\"show\":[]}")))
        (should (equal "tasks" (plist-get plan :bias)))
        (should (eq t (plist-get plan :widened)))
        (should (equal "Nothing matched exactly; these come nearest." (plist-get plan :note)))
        (should (equal (list flaky) (harness-tasks-search-test--ids (plist-get plan :sessions))))
        (should-not (plist-get plan :ids))
        (should-not (plist-get plan :commands))
        ;; Favouring tasks, the model sees the sessions whose names match.
        (should (string-match-p (format "^Sessions besides the board's tasks .*:\n%s | chat | idle | " flaky8)
                                (harness-tasks-search-test--first)))
        ;; One model call only.
        (should (= 1 (length harness-tasks-search-test--requests)))
        ;; The model widens the search itself: its note goes through.
        (let ((plan (harness-tasks-search-test--ask
                     "the flaky login"
                     (list :context (list :view "board"))
                     "{\"sessions\":\"flaky login\"}"
                     (format "{\"show\":[],\"sessions\":[\"%s\"],\"note\":\" No task matched; this session mentions it. \"}"
                             flaky8))))
          (should (eq :false (plist-get plan :widened)))
          (should (equal "No task matched; this session mentions it." (plist-get plan :note)))
          (should (equal (list flaky) (harness-tasks-search-test--ids (plist-get plan :sessions))))
          (should (equal "searched the sessions for \"flaky login\"" (plist-get plan :looked))))))))

(ert-deftest harness-tasks-search-ask-finds-nothing-without-failing ()
  "A query nothing matches, not even once widened, ends in an empty plan
that says so, not in an error."
  (harness-tasks-search-test-with
    (let ((suite (harness-tasks-search-test--submit "Speed up the test suite"))
          (calls nil))
      (harness-tasks-search-test--done suite)
      (harness-tasks-search-test--session "Write the release notes")
      (harness-tasks-search-test-with-session-search
          (lambda (query opts)
            (push (list query opts) calls)
            (harness-resolved (list :query query :mode 'text :engine "fts" :sessions nil)))
        (let ((plan (harness-tasks-search-test--ask
                     "zxqv blorp"
                     (list :context (list :view "board") :commands harness-tasks-search-test--catalogue)
                     "{\"show\":[],\"sessions\":[],\"commands\":[],\"do\":[]}")))
          (should (eq t (plist-get plan :widened)))
          (should (equal "Nothing matched: no task, session or command." (plist-get plan :note)))
          (should-not (plist-get plan :ids))
          (should-not (plist-get plan :actions))
          (should-not (plist-get plan :sessions))
          (should-not (plist-get plan :commands))
          ;; The search looked for the nearest sessions itself; the model
          ;; was asked once.
          (should (equal '("zxqv blorp") (mapcar #'car calls)))
          (should (= 1 (length harness-tasks-search-test--requests))))))))

(ert-deftest harness-tasks-search-matches-words-by-their-stems ()
  "Names and commands match a query's words by their stems, leaving out
the words that say nothing; a session is named by its whole id or a
start of it six characters long or more, a command by its name or its
name without \"harness-\"."
  (harness-tasks-search-test-with
    (should (equal '("debugged" "merge" "queue")
                   (harness-tasks-search--words "Open the session where I debugged the merge queue?")))
    (should (= 3 (harness-tasks-search--score '("debugged" "merge" "queue") "Debug the Merge-Queue")))
    (should (= 1 (harness-tasks-search--score '("attach" "zebra") "Attachments go here")))
    (let ((ids '("abcdef12-0000" "abcdef13-0000" "x")))
      (should (equal "abcdef12-0000" (harness-tasks-search--resolve-session "abcdef12" ids)))
      (should (equal "abcdef12-0000" (harness-tasks-search--resolve-session " ABCDEF12 " ids)))
      (should-not (harness-tasks-search--resolve-session "abcdef1" ids))
      (should-not (harness-tasks-search--resolve-session "abcde" '("abcdef12-0000")))
      (should (equal "x" (harness-tasks-search--resolve-session "x" ids))))
    (let ((catalogue (harness-tasks-search--catalogue harness-tasks-search-test--catalogue)))
      (should (equal catalogue harness-tasks-search-test--catalogue))
      (should (equal "harness-compose-add-attachment"
                     (plist-get (harness-tasks-search--resolve-command "compose-add-attachment" catalogue) :command)))
      (should-not (harness-tasks-search--resolve-command "compose-add" catalogue))
      (should-not (harness-tasks-search--resolve-command "find-file" catalogue))
      (should (equal '("harness-compose-add-attachment")
                     (mapcar (lambda (c) (plist-get c :command))
                             (harness-tasks-search--rank-commands catalogue "how do I attach a file?"))))
      ;; In the label, the name and the doc beats in the doc alone
      ;; ("newest"); "session" says nothing.
      (should (equal '("harness-new-session" "harness-ui-sessions")
                     (mapcar (lambda (c) (plist-get c :command))
                             (harness-tasks-search--rank-commands catalogue "start a new session")))))
    (should (equal "searched the transcripts for \"x\", searched the sessions for \"y\" and looked up commands for \"z\""
                   (harness-tasks-search--looked '(:grep "x" :sessions "y" :commands "z"))))))

(ert-deftest harness-tasks-search-demo-answers-sessions-and-commands ()
  "Offline, the demo provider picks the commands and the sessions whose
lines hold the query's words, as it picks tasks."
  (harness-tasks-search-test-with
    (let ((harness-provider-demo-script-override
           (lambda (request)
             (if (harness-tasks-search-test--search-p request)
                 (harness-provider-demo--search request)
               (harness-tasks-search-test--script request))))
          (merge (harness-tasks-search-test--session "Debug the merge queue")))
      (harness-tasks-search-test--session "Write the release notes")
      (cl-flet ((ask (query opts) (harness-test-await (harness-call 'search/ask default-directory query opts) 10)))
        (let ((plan (ask "how do I attach a file?"
                         (list :context (list :view "chat") :commands harness-tasks-search-test--catalogue))))
          (should (equal '("harness-compose-add-attachment")
                         (mapcar (lambda (c) (plist-get c :command)) (plist-get plan :commands))))
          (should-not (plist-get plan :sessions))
          (should (eq :false (plist-get plan :widened)))
          ;; A "how" question is answered in words too, naming the command.
          (should (equal "Use `harness-compose-add-attachment` (C-c C-a, Chat): Attach file — Attach PATH to the next message."
                         (plist-get plan :answer))))
        (let ((plan (ask "open the session where I debugged the merge queue" (list :context (list :view "sessions")))))
          (should (equal (list merge) (harness-tasks-search-test--ids (plist-get plan :sessions))))
          (should-not (plist-get plan :answer))
          (should (eq :false (plist-get plan :widened))))))))

;;;; Answers in words

(declare-function harness-tasks-search--read-reply "harness-tasks-search")
(declare-function harness-tasks-search--escape-controls "harness-tasks-search")
(defvar harness-tasks-search--broke-off)

(defconst harness-tasks-search-test--long-answer
  (concat "To attach a file, put point in the compose box and press `C-c C-a`: "
          (mapconcat (lambda (i) (format "word%d" i)) (number-sequence 1 120) " ")
          ".\n\n"
          (mapconcat (lambda (i)
                       (format "%d. Step %d of attaching: pick the file, check its chip, and send the message with it once it is ready."
                               i i))
                     (number-sequence 1 12) "\n")
          "\n\nThe last line of the answer.")
  "An answer in words longer than any line, or quote, that used to cut one.")

(ert-deftest harness-tasks-search-answers-in-words ()
  "A question words answer gets its answer whole, Markdown and all, with
the commands it names, even when the model breaks the lines of its JSON
string as they are.  The model is told it may answer so, and has the
room to.  An answer in words is something: the search adds nothing
nearest to one that comes alone, and one that also asks to look further
has answered."
  (harness-tasks-search-test-with
    (let ((plan (harness-tasks-search-test--ask
                 "how do I attach a file?"
                 (list :context (list :view "chat") :commands harness-tasks-search-test--catalogue)
                 ;; Its line breaks as they are, not as \n.
                 (concat "{\"commands\":[\"harness-compose-add-attachment\"],\"answer\":\""
                         harness-tasks-search-test--long-answer "\"}"))))
      (should (equal harness-tasks-search-test--long-answer (plist-get plan :answer)))
      (should (equal '("harness-compose-add-attachment")
                     (mapcar (lambda (c) (plist-get c :command)) (plist-get plan :commands))))
      (should (eq :false (plist-get plan :widened)))
      (let ((request (car harness-tasks-search-test--requests)))
        (should (string-match-p "\"answer\" answers the query in words" (plist-get request :system)))
        (should (string-match-p "\"answer\":\"...\"" (plist-get request :system)))
        (should (>= (plist-get request :max-tokens) 4000))))
    ;; An answer alone, escaped as JSON should be: nothing is added to it.
    (let ((plan (harness-tasks-search-test--ask
                 "what does verify do?" (list :context (list :view "chat"))
                 "{\"show\":[],\"sessions\":[],\"commands\":[],\"do\":[],\"answer\":\"It accepts a task in review:\\nits work merges.\"}")))
      (should (equal "It accepts a task in review:\nits work merges." (plist-get plan :answer)))
      (should (eq :false (plist-get plan :widened)))
      (should-not (plist-get plan :note))
      (should-not (plist-get plan :sessions))
      (should-not (plist-get plan :commands)))
    ;; Answered, and asking to look further too: answered.
    (let ((plan (harness-tasks-search-test--ask
                 "where is the guide?" (list :context (list :view "chat"))
                 "{\"grep\":\"guide\",\"answer\":\"It is `docs/guide.md`.\"}"
                 "{\"show\":[]}")))
      (should (= 1 (length harness-tasks-search-test--requests)))
      (should (equal "It is `docs/guide.md`." (plist-get plan :answer)))
      (should-not (plist-get plan :looked)))
    ;; A plain find has no answer in words.
    (should-not (plist-get (harness-tasks-search-test--ask
                            "the attach command" (list :commands harness-tasks-search-test--catalogue)
                            "{\"commands\":[\"harness-compose-add-attachment\"]}")
                           :answer))))

(ert-deftest harness-tasks-search-takes-prose-as-the-answer ()
  "A model that answers in prose rather than JSON answered in words: its
reply, whole, is the answer, braces and all, where it used to fail the
search with the reply cut to a line."
  (harness-tasks-search-test-with
    (let* ((prose (concat "Press `C-c C-a` in the compose box, then pick the file.\n\n"
                          "- It shows as a chip above the box.\n"
                          "- A path in `{braces}` such as (let ((x {})) x) is fine too.\n\n"
                          (make-string 300 ?x)))
           (plan (harness-tasks-search-test--ask "how do I attach a file?" (list :context (list :view "chat"))
                                                 prose)))
      (should (equal prose (plist-get plan :answer)))
      (should-not (plist-get plan :commands))
      (should (eq :false (plist-get plan :widened))))
    (should (equal "Sure! Here are your tasks."
                   (plist-get (harness-tasks-search-test--search "q" "Sure! Here are your tasks.") :answer)))))

(ert-deftest harness-tasks-search-keeps-what-came-of-a-broken-answer ()
  "JSON that breaks off in its answer in words -- the model ran out of
tokens, or left a quote unescaped -- keeps the answer as far as it came,
an escape cut in half left out, with a note that says it broke off."
  (harness-tasks-search-test-with
    (let ((plan (harness-tasks-search-test--ask
                 "how do I attach a file?" (list :context (list :view "chat"))
                 "{\"show\":[],\"answer\":\"Press `C-c C-a`,\\nthen pick the fi\\u00")))
      (should (equal "Press `C-c C-a`,\nthen pick the fi" (plist-get plan :answer)))
      (should (equal harness-tasks-search--broke-off (plist-get plan :note)))
      (should (eq :false (plist-get plan :widened))))))

(ert-deftest harness-tasks-search-reads-replies-leniently ()
  "What a reply gives: the first object with the search's keys, whatever
text is around it; one that is nothing but an object, whatever its keys;
line breaks inside its strings as they are; prose, braces and all, as the
answer; nothing for a blank reply or JSON broken before any answer."
  (harness-tasks-search-test-with
    (dolist (case '(("{\"show\":[],\"answer\":\"one\ntwo\tthree\"}" (:show nil :answer "one\ntwo\tthree"))
                    ("```json\n{\"answer\":\"Use `C-c C-a`.\"}\n```\nThat is all {really}." (:answer "Use `C-c C-a`."))
                    ("Here: {not json} and {\"show\":[\"t-2\"],\"answer\":\"ok\"} after" (:show ("t-2") :answer "ok"))
                    ("{\"grep\":\"x\"}\n{\"show\":[]}" (:grep "x"))
                    ("{}" (:show nil))
                    ("```json\n{}\n```" (:show nil))
                    ("{\"foo\": 1}" (:foo 1))
                    ("Use {braces}: (let ((x {})) x)" (:answer "Use {braces}: (let ((x {})) x)"))
                    ("Set {\"model\": \"x\"} in your config." (:answer "Set {\"model\": \"x\"} in your config."))
                    ("{\"commands\":[\"a\"" nil)
                    ("  \n" nil)))
      (should (equal (cadr case) (harness-tasks-search--read-reply (car case)))))
    (should (equal "{\"a\":\"x\\ny\",\n\"b\":1}" (harness-tasks-search--escape-controls "{\"a\":\"x\ny\",\n\"b\":1}")))
    (should (equal "{\"a\":\"\\\"q\\\"\\t\"}" (harness-tasks-search--escape-controls "{\"a\":\"\\\"q\\\"\t\"}")))))

(provide 'harness-tasks-search-test)
;;; harness-tasks-search-test.el ends here
