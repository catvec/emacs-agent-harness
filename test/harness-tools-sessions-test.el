;;; harness-tools-sessions-test.el --- Tests for the session and task tools  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
(defvar harness-naming-auto)
(defvar harness-sessions)
(defvar harness-agent--turns)
(defvar harness-tools-agent--questions)
(defvar harness-tasks--table)
(defvar harness-tasks--starting)
(defvar harness-tasks--loaded)
(defvar harness-tasks-max-running)
(defvar harness-tasks-require-verification)
(defvar harness-tasks-permission-mode)
(defvar harness-tasks-non-interactive)
(defvar harness-tasks-model)
(defvar harness-tools-sessions--waiters)

(defconst harness-tools-sessions-test-script
  '((:type text :delta "Reply from ") (:type text :delta "the other session.") (:type done :stop-reason end-turn)))

(defmacro harness-tools-sessions-test-with (&rest body)
  "Load the state layer, tasks and the session tools with the demo provider; run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo tools session agent tools-agent tasks tools-sessions))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-agent--turns)
     (clrhash harness-tools-agent--questions)
     (clrhash harness-tasks--table)
     (clrhash harness-tasks--starting)
     (clrhash harness-tools-sessions--waiters)
     (setq harness-tasks--loaded t)
     (let ((harness-provider-demo--delay 0.005)
           (harness-provider-demo-script-override harness-tools-sessions-test-script)
           (harness-naming-auto nil)
           (harness-tasks-max-running 3)
           ;; Finished tasks are done at once unless a test reviews them.
           (harness-tasks-require-verification nil)
           (harness-tasks-permission-mode 'auto)
           (harness-tasks-non-interactive t)
           (harness-tasks-model "demo:scripted")
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       ,@body)))

(defun harness-tools-sessions-test-session (&rest plist)
  "Create a demo session in the state directory and return its id."
  (plist-get (apply #'harness-call 'session/create :cwd default-directory :model "demo:scripted" plist) :id))

(defun harness-tools-sessions-test-run (sid name input)
  "Run tool NAME with INPUT as session SID; return the result plist."
  (harness-test-await (harness-call 'tools/execute sid (list :id (harness-short-id) :name name :input input)) 10))

(defun harness-tools-sessions-test-ok (sid name input)
  "Run tool NAME as SID, assert it succeeded and return its text."
  (let ((r (harness-tools-sessions-test-run sid name input)))
    (should-not (plist-get r :is-error))
    (plist-get r :content)))

(defun harness-tools-sessions-test-idle (sid)
  (harness-test-wait (lambda () (and (not (harness-call 'agent/running sid))
                                     (eq 'idle (plist-get (harness-call 'session/get sid) :status))))
                     5 (format "%s idle" sid)))

(ert-deftest harness-tools-sessions-registers-tools ()
  (harness-tools-sessions-test-with
    (let ((names (mapcar (lambda (s) (plist-get s :name)) (harness-call 'tools/list))))
      (dolist (n '("session_list" "session_search" "session_read" "session_history" "session_send" "session_control"
                   "session_move" "set_non_interactive" "session_wait" "task_list" "task_submit" "task_control"
                   "task_wait"))
        (should (member n names))))
    (dolist (n '("session_list" "session_search" "session_read" "session_history" "session_wait" "task_list" "task_wait"))
      (should (eq 'read (plist-get (harness-call 'tools/get n) :kind))))
    (dolist (n '("session_send" "session_control" "session_move" "set_non_interactive" "task_submit" "task_control"))
      (should (eq 'meta (plist-get (harness-call 'tools/get n) :kind))))))

(ert-deftest harness-tools-sessions-list-and-filters ()
  (harness-tools-sessions-test-with
    (let* ((me (harness-tools-sessions-test-session :name "Me"))
           (other (harness-tools-sessions-test-session :name "Parser fixer"))
           (child (harness-tools-sessions-test-session :name "Child" :parent-id other :kind 'subagent))
           (closed (harness-tools-sessions-test-session :name "Old one"))
           (elsewhere (let ((default-directory (harness-test-temp-dir)))
                        (harness-tools-sessions-test-session :name "Elsewhere"))))
      (harness-call 'session/deactivate closed)
      (let ((text (harness-tools-sessions-test-ok me "session_list" nil)))
        (should (string-match-p (regexp-quote (concat me)) text))
        (should (string-match-p "(this session)" text))
        (should (string-match-p (regexp-quote other) text))
        (should (string-match-p (regexp-quote child) text))
        (should-not (string-match-p (regexp-quote closed) text))
        (should-not (string-match-p (regexp-quote elsewhere) text)))
      (should (string-match-p (regexp-quote closed)
                              (harness-tools-sessions-test-ok me "session_list" '(:include_inactive t))))
      (should (string-match-p (regexp-quote elsewhere)
                              (harness-tools-sessions-test-ok me "session_list" '(:all_projects t))))
      (let ((text (harness-tools-sessions-test-ok me "session_list" (list :parent_id (substring other 0 8)))))
        (should (string-match-p (regexp-quote child) text))
        (should-not (string-match-p (regexp-quote me) text)))
      (should (string-match-p (regexp-quote other)
                              (harness-tools-sessions-test-ok me "session_list" '(:name "parser")))))))

(ert-deftest harness-tools-sessions-search-content ()
  (harness-tools-sessions-test-with
    (let ((me (harness-tools-sessions-test-session :name "Me"))
          (a (harness-tools-sessions-test-session :name "Alpha"))
          (b (harness-tools-sessions-test-session :name "Beta")))
      (harness-call 'session/append a '(:kind user :content "Please look at the \"zebra\" handler in lexer.el"))
      (harness-call 'session/append b '(:kind assistant :content "Nothing to see here."))
      (harness-call 'session/append b '(:kind tool-result :output "line 3: ZEBRA stripes"))
      (harness-call 'session/append me '(:kind user :content "zebra in my own session"))
      (let ((text (harness-tools-sessions-test-ok me "session_search" '(:query "zebra"))))
        (should (string-match-p (regexp-quote a) text))
        (should (string-match-p (regexp-quote b) text))
        (should (string-match-p "\"zebra\" handler" text))
        (should (string-match-p "ZEBRA stripes" text))
        (should-not (string-match-p (regexp-quote me) text)))
      ;; A quote inside the query is matched through the JSON escaping.
      (let ((text (harness-tools-sessions-test-ok me "session_search" '(:query "\"zebra\" handler"))))
        (should (string-match-p (regexp-quote a) text))
        (should-not (string-match-p (regexp-quote b) text)))
      ;; Names match without content.
      (should (string-match-p (regexp-quote b) (harness-tools-sessions-test-ok me "session_search" '(:query "beta"))))
      (should (string-match-p "No session mentions"
                              (harness-tools-sessions-test-ok me "session_search" '(:query "giraffe"))))
      (should (string-match-p (regexp-quote b)
                              (harness-tools-sessions-test-ok me "session_search" '(:query "ZEB+RA s" :regexp t)))))))

(ert-deftest harness-tools-sessions-search-very-long-line ()
  "A node of megabytes neither fails a search nor makes a long snippet.
grep prints the node's whole line of the log, and the regexp that split
the file name off it backtracked over all of it: \"Stack overflow in
regexp matcher\" once a line passed some hundred thousand characters."
  (harness-tools-sessions-test-with
    (let ((me (harness-tools-sessions-test-session :name "Me"))
          (big (harness-tools-sessions-test-session :name "Big output"))
          (small (harness-tools-sessions-test-session :name "Small")))
      ;; The match lies deep in the node, and long runs follow it.
      (harness-call 'session/append big
                    (list :kind 'tool-result
                          :output (concat (make-string 1200000 ?x) " see\n  README.md for details "
                                          (make-string 600000 ?y))))
      (harness-call 'session/append small '(:kind user :content "Update the README.md please"))
      (dolist (input '((:query "README.md")
                       ;; Regexps that overflow the matcher over the whole node.
                       (:query "README.*details" :regexp t)
                       (:query "README.*y" :regexp t)))
        (let ((text (harness-tools-sessions-test-ok
                     me "session_search" (append input '(:max_sessions 40 :max_matches 2)))))
          (should (string-search big text))
          (should (string-match-p "\\] …x+ see README\\.md for details y+…" text))
          (should (< (length text) 1500))
          (unless (plist-get input :regexp)
            (should (string-search small text))
            (should (string-search "Update the README.md please" text))))))))

(ert-deftest harness-tools-sessions-snippet-stays-short ()
  "A snippet shows the match where it is, on one line, cut to a few hundred characters."
  (harness-tools-sessions-test-with
    (let ((text (concat (make-string 1000000 ?x) " see\n\n   README.md   for\tdetails " (make-string 1000000 ?y))))
      (should (equal (concat "…" (make-string 65 ?x) " see README.md for details " (make-string 77 ?y) "…")
                     (harness-tools-sessions--snippet text "readme.md" nil)))
      (should (equal (harness-tools-sessions--snippet text "readme.md" nil)
                     (harness-tools-sessions--snippet text "R[a-z]+ME\\.md" t)))
      ;; A long match, which overflows the matcher over the whole text, is
      ;; cut 300 characters after its start.
      (let ((snippet (harness-tools-sessions--snippet text "README.*y" t)))
        (should (string-prefix-p (concat "…" (make-string 65 ?x) " see README.md for details yyy") snippet))
        (should (= (+ 1 70 300 1) (length snippet))))
      ;; Without a match, the start of the text.
      (should (equal (concat (make-string 159 ?x) "…") (harness-tools-sessions--snippet text "zebra" nil)))
      (should (equal (concat (make-string 159 ?x) "…") (harness-tools-sessions--snippet text "\\(" t)))
      ;; A short text is shown whole.
      (should (equal "line 3: ZEBRA stripes" (harness-tools-sessions--snippet "line 3:\nZEBRA  stripes" "zebra" nil))))))

(ert-deftest harness-tools-sessions-non-ascii-tool-input ()
  ;; A tool call's input is shown as text: session_read gives it as it was
  ;; written, in a result that can go back to the model as JSON, and
  ;; session_search finds it.
  (harness-tools-sessions-test-with
    (let ((me (harness-tools-sessions-test-session :name "Me"))
          (other (harness-tools-sessions-test-session :name "Other"))
          (word "caf\N{U+E9} \N{U+2717}"))
      (harness-call 'session/append other (list :kind 'tool-call :tool "edit_file" :call-id "c1"
                                                :title "edit_file notes.md"
                                                :input (list :path "notes.md" :new_string word)))
      (let ((text (harness-tools-sessions-test-ok me "session_read" '(:session_id "Other"))))
        (should (string-search word text))
        (should (equal text (plist-get (harness-json-parse (harness-json-encode (list :text text))) :text))))
      (let ((text (harness-tools-sessions-test-ok me "session_search" (list :query word))))
        (should (string-search other text))
        (should (string-search word text))))))

(ert-deftest harness-tools-sessions-read-transcript ()
  (harness-tools-sessions-test-with
    (let ((me (harness-tools-sessions-test-session))
          (other (harness-tools-sessions-test-session :name "Other")))
      (dotimes (i 5)
        (harness-call 'session/append other (list :kind 'user :content (format "message %d" i))))
      (harness-call 'session/set-todos other '((:id "t1" :text "write tests" :status done)))
      (let ((text (harness-tools-sessions-test-ok me "session_read" (list :session_id "Other" :limit 2))))
        (should (string-match-p "message 4" text))
        (should (string-match-p "message 3" text))
        (should-not (string-match-p "message 2" text))
        (should (string-match-p "\\[x\\] write tests" text))
        (should (string-match-p "2 of 5 nodes; earlier ones with before=" text))
        (string-match "before=\\([^)]+\\))" text)
        (let ((older (harness-tools-sessions-test-ok me "session_read"
                                                     (list :session_id other :before (match-string 1 text)))))
          (should (string-match-p "message 0" older))
          (should-not (string-match-p "message 3" older))))
      (let ((r (harness-tools-sessions-test-run me "session_read" '(:session_id "nope"))))
        (should (plist-get r :is-error))
        (should (string-match-p "No session matches" (plist-get r :content)))))))

(ert-deftest harness-tools-sessions-history-before-a-compaction ()
  "session_history searches and reads the session's own conversation from
before its last compaction, the part its context holds only as the
compaction tells of it; all=true looks through the whole of it."
  (harness-tools-sessions-test-with
    (let ((sid (harness-tools-sessions-test-session)))
      (harness-call 'session/append sid '(:kind user :content "hello"))
      (should (string-prefix-p "This conversation was never compacted: all 1 nodes are in your context already."
                               (harness-tools-sessions-test-ok sid "session_history" nil)))
      (dotimes (i 6)
        (harness-call 'session/append sid (list :kind 'user :content (format "question %d about the parser" i)))
        (harness-call 'session/append sid (list :kind 'assistant :content (format "answer %d" i))))
      (harness-call 'session/append sid '(:kind hint :content "a hint about the parser"))
      (let* ((compaction (harness-call 'session/append sid '(:kind compaction :content "SUMMARY of the work"
                                                              :meta (:compaction "brief"))))
             (cid (plist-get compaction :id)))
        (harness-call 'session/append sid '(:kind user :content "after the parser compaction"))
        ;; Neither query nor node: the last nodes before the compaction,
        ;; oldest first, hints left out.
        (let ((text (harness-tools-sessions-test-ok sid "session_history" '(:limit 3))))
          (should (string-match-p
                   (format (concat "\\`The conversation before the brief compaction \\[compaction %s, [^]]+\\]:"
                                   " 14 nodes your context holds only as that node tells of them\\.")
                           cid)
                   text))
          (should (string-match-p "3 of 13 nodes, oldest first; earlier ones with before=n-" text))
          (should (string-match-p "answer 4" text))
          (should (string-match-p "question 5 about the parser" text))
          (should (string-match-p "answer 5" text))
          (should-not (string-match-p "question 4" text))
          (should-not (string-match-p "a hint" text))
          (should-not (string-match-p "after the parser compaction" text))
          (should (string-match-p "Read a node whole with node_id; find one with query\\.\\'" text)))
        ;; A query: matches newest first, paging back with before.
        (let ((text (harness-tools-sessions-test-ok sid "session_history" '(:query "PARSER" :limit 2))))
          (should (string-match-p "6 nodes mention \"PARSER\", newest first:" text))
          (should (string-match-p "question 5 about the parser" text))
          (should (string-match-p "question 4 about the parser" text))
          (should-not (string-match-p "question 3" text))
          (should-not (string-match-p "after the parser compaction" text))
          (should (string-match-p "… 4 older; page back with before=\\(n-[a-z0-9]+\\)" text))
          (string-match "before=\\(n-[a-z0-9]+\\)" text)
          (let ((older (harness-tools-sessions-test-ok sid "session_history"
                                                       (list :query "parser" :before (match-string 1 text)))))
            (should (string-match-p "4 nodes mention \"parser\", newest first, before n-" older))
            (should (string-match-p "question 0 about the parser" older))
            (should-not (string-match-p "question 4" older))))
        (should (string-match-p "Nothing mentions \"purple\"\\."
                                (harness-tools-sessions-test-ok sid "session_history" '(:query "purple"))))
        ;; The whole conversation, the part since the compaction included.
        (let ((text (harness-tools-sessions-test-ok sid "session_history" '(:query "parser" :all t))))
          (should (string-match-p (format "\\`The whole conversation, 16 nodes, the brief compaction \\[compaction %s, " cid)
                                  text))
          (should (string-match-p "7 nodes mention \"parser\"" text))
          (should (string-match-p "after the parser compaction" text)))
        ;; Only some kinds.
        (let ((text (harness-tools-sessions-test-ok sid "session_history" '(:kinds ["assistant"] :limit 50))))
          (should (string-match-p "6 of 6 nodes, oldest first:" text))
          (should-not (string-match-p "question" text)))
        ;; One node whole, with the nodes around it.
        (let* ((q2 (cl-find "question 2 about the parser" (harness-call 'session/nodes sid)
                            :key (lambda (n) (plist-get n :content)) :test #'equal))
               (text (harness-tools-sessions-test-ok sid "session_history" (list :node_id (plist-get q2 :id)))))
          (should (string-match-p (format "\\[user %s\\]\\( ([^)]+)\\)?, the node asked for:\nquestion 2 about the parser"
                                          (plist-get q2 :id))
                                  text))
          (dolist (near '("question 1" "answer 1" "answer 2" "question 3"))
            (should (string-match-p near text)))
          (should-not (string-match-p "answer 0" text))
          (should-not (string-match-p "answer 3" text)))
        (let ((r (harness-tools-sessions-test-run sid "session_history" '(:node_id "n-nope"))))
          (should (plist-get r :is-error))
          (should (string-match-p "No node n-nope in this session's conversation" (plist-get r :content))))
        (let ((r (harness-tools-sessions-test-run sid "session_history" '(:before "n-nope"))))
          (should (plist-get r :is-error)))))))

(ert-deftest harness-tools-sessions-history-before-a-handoff ()
  "A handoff from another model starts the conversation over too: what
came before its note is what session_history looks back on."
  (harness-tools-sessions-test-with
    (let ((sid (harness-tools-sessions-test-session)))
      (harness-call 'session/append sid '(:kind user :content "the old model's question"))
      (harness-call 'session/append sid '(:kind assistant :content "the old model's answer"))
      (harness-call 'session/append sid '(:kind compaction :content "an older summary"))
      (harness-call 'session/append sid '(:kind user :content "after the summary"))
      (harness-call 'session/append sid (list :kind 'user :content "Read the transcript"
                                              :meta (list :from (harness-sender-system "handoff")
                                                          :handoff (list :mode "transcript" :file "/tmp/t.md"
                                                                         :from "demo:scripted" :to "demo:other"))))
      (harness-call 'session/append sid '(:kind user :content "the new model's question"))
      (let ((text (harness-tools-sessions-test-ok sid "session_history" nil)))
        (should (string-match-p "\\`The conversation before the handoff from demo:scripted \\[user n-[a-z0-9]+, [^]]+\\]: 4 nodes"
                                text))
        (should (string-match-p "after the summary" text))
        (should (string-match-p "the old model's answer" text))
        (should-not (string-match-p "the new model's question" text))))))

(ert-deftest harness-tools-sessions-send-and-wait-reply ()
  (harness-tools-sessions-test-with
    (let ((me (harness-tools-sessions-test-session :name "Boss"))
          (other (harness-tools-sessions-test-session)))
      (let ((text (harness-tools-sessions-test-ok me "session_send" (list :session_id other :message "status?" :wait t))))
        (should (string-match-p "turn ended: end-turn" text))
        (should (string-match-p "Reply from the other session." text)))
      (let ((user (cl-find 'user (harness-call 'session/nodes other) :key (lambda (n) (plist-get n :kind)))))
        (should (string-match-p (regexp-quote (format "[Message from session %s \"Boss\"]" me)) (plist-get user :content)))
        (should (string-match-p "status\\?" (plist-get user :content))))
      (let ((r (harness-tools-sessions-test-run me "session_send" (list :session_id me :message "hi"))))
        (should (plist-get r :is-error))
        (should (string-match-p "cannot message itself" (plist-get r :content)))))))

(ert-deftest harness-tools-sessions-send-says-who-sent-it ()
  "A message session_send delivers is the sending session's, not the user's.
Its node says so, a queued one too, and session_read and session_search
tell it from the user's messages."
  (harness-tools-sessions-test-with
    (let ((me (harness-tools-sessions-test-session :name "Boss"))
          (other (harness-tools-sessions-test-session :name "Worker"))
          (third (harness-tools-sessions-test-session :name "Onlooker")))
      (harness-tools-sessions-test-ok me "session_send" (list :session_id other :message "status?" :wait t))
      (let ((user (cl-find 'user (harness-call 'session/nodes other) :key (lambda (n) (plist-get n :kind)))))
        (should (equal (list :kind 'session :id me :name "Boss") (harness-node-sender user))))
      (harness-tools-sessions-test-ok me "session_send" (list :session_id other :message "later" :mode "queue"))
      (let ((item (car (plist-get (harness-call 'session/get other) :queue))))
        (should (string-suffix-p "later" (plist-get item :text)))
        (should (equal me (plist-get (plist-get item :from) :id))))
      (harness-call 'session/queue-take other)
      (harness-call 'session/append other '(:kind user :content "from the user"))
      (let ((tag (regexp-quote (format ", from session %s \"Boss\"]" me))))
        (let ((text (harness-tools-sessions-test-ok third "session_read" (list :session_id other))))
          (should (string-match-p (concat tag (regexp-quote " [Message from session")) text))
          (should (string-match-p "\\[user n-[a-z0-9]+\\] from the user" text)))
        (should (string-match-p tag (harness-tools-sessions-test-ok third "session_search" '(:query "status?"))))))))

(defun harness-tools-sessions-test-wakes (sid)
  "Return the wake-up messages `session_wait' sent to SID, oldest first."
  (cl-remove-if-not
   (lambda (node)
     (and (eq (plist-get node :kind) 'user)
          (equal '(:kind system :source "session wait") (harness-node-sender node))))
   (harness-call 'session/nodes sid)))

(ert-deftest harness-tools-sessions-send-then-wait ()
  "session_wait registers at once and wakes the session when the others stop."
  (harness-tools-sessions-test-with
    (let ((harness-provider-demo--delay 0.1)
          (me (harness-tools-sessions-test-session))
          (a (harness-tools-sessions-test-session))
          (b (harness-tools-sessions-test-session)))
      (should (string-match-p "started a turn" (harness-tools-sessions-test-ok me "session_send" (list :session_id a :message "go"))))
      (harness-tools-sessions-test-ok me "session_send" (list :session_id b :message "go"))
      ;; Running at once: a wait right after the send cannot see a stale idle.
      (should (harness-call 'agent/running a))
      ;; The call does not block: it registers while both still run.
      (should (string-match-p "Waiting in the background"
                              (harness-tools-sessions-test-ok me "session_wait" (list :session_ids (list a b)))))
      (should (= 1 (hash-table-count harness-tools-sessions--waiters)))
      (should (string-match-p (regexp-quote (harness-tools-sessions--short a))
                              (harness-call 'agent/outstanding me)))
      ;; The wake-up message arrives when both have stopped.
      (harness-test-wait (lambda () (harness-tools-sessions-test-wakes me)) 10 "the wake-up")
      (let ((text (plist-get (car (harness-tools-sessions-test-wakes me)) :content)))
        (should (string-match-p "Done waiting" text))
        (should (= 2 (cl-count-if (lambda (l) (string-match-p "Reply from the other session" l))
                                  (split-string text "\n")))))
      (should (zerop (hash-table-count harness-tools-sessions--waiters))))))

(ert-deftest harness-tools-sessions-wait-already-met-and-timeout ()
  "A wait that already holds returns the report; a timeout wakes the session."
  (harness-tools-sessions-test-with
    (let ((me (harness-tools-sessions-test-session))
          (idle (harness-tools-sessions-test-session)))
      ;; Already stopped: the report is the call's result, nothing is registered.
      (should (string-match-p "Done waiting" (harness-tools-sessions-test-ok me "session_wait" (list :session_id idle))))
      (should (zerop (hash-table-count harness-tools-sessions--waiters)))
      ;; Never starts running: the call registers, and the timeout wakes it.
      (should (string-match-p
               "Waiting in the background"
               (harness-tools-sessions-test-ok me "session_wait"
                                               (list :session_id idle :until "running" :timeout_seconds 0.2))))
      (should (= 1 (hash-table-count harness-tools-sessions--waiters)))
      (harness-test-wait (lambda () (harness-tools-sessions-test-wakes me)) 5 "the timeout wake-up")
      (let ((text (plist-get (car (harness-tools-sessions-test-wakes me)) :content)))
        (should (string-match-p "Still waiting" text))
        (should (string-match-p (regexp-quote idle) text)))
      (should (zerop (hash-table-count harness-tools-sessions--waiters))))))

(ert-deftest harness-tools-sessions-wait-outlives-its-turn-and-drops-on-cancel ()
  "A registered wait survives the turn that made it, until it fires.
A turn the user cancelled drops its registrations instead: a turn they
stopped is not one to start another on."
  (harness-tools-sessions-test-with
    (let ((me (harness-tools-sessions-test-session))
          (other (harness-tools-sessions-test-session))
          (third (harness-tools-sessions-test-session)))
      (harness-tools-sessions-test-ok me "session_wait" (list :session_id other :until "running"))
      (should (= 1 (hash-table-count harness-tools-sessions--waiters)))
      ;; The turn that registered it ends on its own; the wait stays.
      (harness-emit 'agent/turn-ended me 'end-turn)
      (should (= 1 (hash-table-count harness-tools-sessions--waiters)))
      (should (string-match-p (regexp-quote (harness-tools-sessions--short other))
                              (harness-call 'agent/outstanding me)))
      ;; The other session starts running; the wait fires.
      (harness-tools-sessions-test-ok me "session_send" (list :session_id other :message "go"))
      (harness-test-wait (lambda () (harness-tools-sessions-test-wakes me)) 5 "the wake-up")
      (should (zerop (hash-table-count harness-tools-sessions--waiters)))
      ;; A discarded turn drops what it registered.  Wait for the first
      ;; wake's own turn to be over so the count below is stable.
      (harness-tools-sessions-test-idle me)
      (harness-test-wait (lambda () (not (harness-call 'agent/running other))) 5 "the other turn to end")
      (harness-tools-sessions-test-ok third "session_send" (list :session_id other :message "again"))
      (harness-tools-sessions-test-ok me "session_wait" (list :session_id other))
      (should (= 1 (hash-table-count harness-tools-sessions--waiters)))
      (harness-emit 'agent/turn-ended me 'cancelled)
      (should (zerop (hash-table-count harness-tools-sessions--waiters)))
      ;; Nothing woke for the dropped wait, and none of it is outstanding.
      (should (= 1 (length (harness-tools-sessions-test-wakes me))))
      (should-not (harness-call 'agent/outstanding me)))))

(ert-deftest harness-tools-sessions-wait-until-blocked-and-answer ()
  "A wait until another session blocks wakes the session that registered."
  (harness-tools-sessions-test-with
    (let* ((me (harness-tools-sessions-test-session))
           (other (harness-tools-sessions-test-session))
           (ask nil))
      (should (string-match-p
               "Waiting in the background"
               (harness-tools-sessions-test-ok me "session_wait" (list :session_id other :until "blocked"))))
      (setq ask (harness-call 'tools/execute other (list :id "q" :name "ask_user" :input '(:question "Which colour?"))))
      (harness-test-wait (lambda () (harness-tools-sessions-test-wakes me)) 5 "the wake-up")
      (let ((text (plist-get (car (harness-tools-sessions-test-wakes me)) :content)))
        (should (string-match-p "waiting on the user: question .*Which colour\\?" text)))
      (harness-tools-sessions-test-idle me)
      (should (string-match-p "Answered" (harness-tools-sessions-test-ok me "session_control"
                                                                          (list :session_id other :action "answer" :answer "teal"))))
      (should (equal "teal" (plist-get (harness-test-await ask 5) :content))))))

(ert-deftest harness-tools-sessions-control ()
  (harness-tools-sessions-test-with
    (let ((harness-provider-demo--delay 0.2)
          (me (harness-tools-sessions-test-session))
          (other (harness-tools-sessions-test-session)))
      (harness-tools-sessions-test-ok me "session_control" (list :session_id other :action "rename" :name "Renamed"))
      (should (equal "Renamed" (plist-get (harness-call 'session/get other) :name)))
      (harness-tools-sessions-test-ok me "session_send" (list :session_id other :message "long job"))
      (let ((r (harness-tools-sessions-test-run me "session_control" (list :session_id other :action "close"))))
        (should (plist-get r :is-error)))
      (should (string-match-p "Cancelling" (harness-tools-sessions-test-ok me "session_control" (list :session_id "Renamed" :action "cancel"))))
      (harness-tools-sessions-test-idle other)
      (harness-tools-sessions-test-ok me "session_control" (list :session_id other :action "close"))
      (should (eq 'inactive (plist-get (harness-call 'session/get other) :status)))
      (harness-tools-sessions-test-ok me "session_control" (list :session_id other :action "resume"))
      (should (eq 'idle (plist-get (harness-call 'session/get other) :status)))
      (should (plist-get (harness-tools-sessions-test-run me "session_control" (list :session_id me :action "cancel")) :is-error)))))

(ert-deftest harness-tools-sessions-set-non-interactive ()
  "set_non_interactive changes this session, another one, or with all
every current session and task of every project, as
`harness-set-non-interactive-all' does; the default for new sessions
stays the user's.  (Its permission, the user's confirmation, is the
permission chain's: see the perms tests.)"
  (harness-tools-sessions-test-with
    (let* ((harness-tasks-max-running 0)
           (harness-tasks-non-interactive nil)
           (elsewhere (harness-test-temp-dir))
           (me (harness-tools-sessions-test-session :name "Me"))
           (other (harness-tools-sessions-test-session :name "Other"))
           (there (let ((default-directory elsewhere)) (harness-tools-sessions-test-session :name "There")))
           (waiting (plist-get (harness-call 'task/submit elsewhere "waiting there") :id))
           (spec (harness-call 'tools/get "set_non_interactive")))
      (should (eq 'meta (plist-get spec :kind)))
      (should (equal '("enabled") (plist-get (plist-get spec :schema) :required)))
      (should (string-match-p "always asks the user to confirm" (plist-get spec :description)))
      ;; This session by default.
      (should (equal "Non-interactive mode is now on for this session."
                     (harness-tools-sessions-test-ok me "set_non_interactive" '(:enabled t))))
      (should (plist-get (harness-call 'session/get me) :non-interactive))
      (should (equal "Non-interactive mode was already on for this session."
                     (harness-tools-sessions-test-ok me "set_non_interactive" '(:enabled t))))
      ;; Another one, by name.
      (should (string-match-p "\\`Non-interactive mode is now on for session .* \"Other\"\\.\\'"
                              (harness-tools-sessions-test-ok me "set_non_interactive" '(:enabled t :session_id "Other"))))
      (should (plist-get (harness-call 'session/get other) :non-interactive))
      (should-not (plist-get (harness-call 'session/get there) :non-interactive))
      (should (plist-get (harness-tools-sessions-test-run me "set_non_interactive" '(:enabled t :all t :session_id "Other"))
                         :is-error))
      ;; Everything current, in every project: the session over there and
      ;; the task waiting there.
      (let ((text (harness-tools-sessions-test-ok me "set_non_interactive" '(:enabled t :all t))))
        (should (string-match-p "1 session and 1 task changed" text)))
      (should (plist-get (harness-call 'session/get there) :non-interactive))
      (should (eq t (plist-get (harness-call 'task/get waiting) :non-interactive)))
      ;; Off, with JSON's false.
      (let ((text (harness-tools-sessions-test-ok me "set_non_interactive" '(:enabled :false :all t))))
        (should (string-match-p "\\`Non-interactive mode is off for every current session and task of every project: 3 sessions and 1 task changed" text)))
      (dolist (sid (list me other there))
        (should-not (plist-get (harness-call 'session/get sid) :non-interactive)))
      (should (eq :false (plist-get (harness-call 'task/get waiting) :non-interactive)))
      (harness-call 'task/cancel waiting))))

(declare-function harness-provider-demo--script "harness-provider-demo" (request))

(ert-deftest harness-tools-sessions-demo-away-and-back-scripts ()
  "The demo provider's `away' and `back' scripts call set_non_interactive
for everything, on and off, with input its schema takes, so the user's
confirmation can be tried live without a model."
  (harness-tools-sessions-test-with
    (let ((harness-provider-demo-script-override nil)
          (schema (plist-get (harness-call 'tools/get "set_non_interactive") :schema)))
      (pcase-dolist (`(,text ,enabled) '(("I am going away now" t) ("I am back" :false)))
        (let* ((events (harness-provider-demo--script
                        `(:messages ((:role user :content ((:type "text" :text ,text)))))))
               (calls (cl-remove-if-not (lambda (e) (eq (plist-get e :type) 'tool-call)) events)))
          (should (equal '("set_non_interactive") (mapcar (lambda (e) (plist-get e :name)) calls)))
          (let ((input (plist-get (car calls) :input)))
            (should (eq enabled (plist-get input :enabled)))
            (should (eq t (plist-get input :all)))
            (dolist (key (harness-plist-keys input))
              (should (plist-member (plist-get schema :properties) key)))))))))

;;;; session_move

(defun harness-tools-sessions-test-prompt (sid)
  "Return the permission request SID waits on, once it waits on one."
  (harness-test-wait (lambda () (car (harness-call 'permission/pending sid))) 5 "a permission request"))

(ert-deftest harness-tools-sessions-move-this-session-when-its-turn-ends ()
  "An agent moves its own session: the user confirms, the new directory
is allowed for the rest of the turn, and the session moves as the turn
ends."
  (harness-tools-sessions-test-with
    (harness-test-load-module 'perms)
    (let* ((new (harness-test-temp-dir))
           (me (harness-tools-sessions-test-session :name "Wanderer"))
           (granted nil)
           (harness-provider-demo-script-override
            `((:type tool-call :id "mv" :name "session_move" :input (:directory ,new :reason "the work is there"))
              (:type done :stop-reason end-turn))))
      (harness-on 'permission/dir-allowed (lambda (_ d) (push d granted)))
      (let ((turn (harness-call 'agent/prompt me "Go where the work is")))
        (let* ((request (harness-tools-sessions-test-prompt me))
               (payload (plist-get request :payload)))
          ;; Allow or deny, this call only.
          (should (equal '(allow-once deny-once) (plist-get payload :options)))
          (should (equal (format "Move session: %s" (abbreviate-file-name new))
                         (plist-get payload :title)))
          (should (string-match-p "\\`When this turn ends, this session moves from " (plist-get payload :reason)))
          (should (string-match-p "access to .* is not kept" (plist-get payload :reason)))
          (should (string-match-p "The agent says: the work is there\\'" (plist-get payload :reason)))
          (should (equal (list new) (plist-get payload :paths)))
          (should (equal default-directory (plist-get (harness-call 'session/get me) :cwd)))
          (harness-call 'permission/answer me (plist-get request :id) "allow-once"))
        (harness-test-await turn 10))
      (harness-test-wait (lambda () (equal new (plist-get (harness-call 'session/get me) :cwd))) 5 "the move")
      ;; Allowed for the rest of the turn it asked in.
      (should (member new granted))
      (let ((result (cl-find 'tool-result (harness-call 'session/nodes me) :key (lambda (n) (plist-get n :kind)))))
        (should (string-match-p "This session moves to .* when this turn ends" (plist-get result :output)))))))

(ert-deftest harness-tools-sessions-move-another-session ()
  "Moving another session asks the user; a denial leaves it, an allow
moves it at once, keeping its old directory when asked to."
  (harness-tools-sessions-test-with
    (harness-test-load-module 'perms)
    (let* ((old (harness-test-temp-dir))
           (new (harness-test-temp-dir))
           (me (harness-tools-sessions-test-session :name "Me"))
           (other (let ((default-directory old)) (harness-tools-sessions-test-session :name "Lost")))
           (call (lambda (input)
                   (harness-call 'tools/execute me (list :id (harness-short-id) :name "session_move" :input input)))))
      (let ((p (funcall call (list :session_id "Lost" :directory new))))
        (let ((request (harness-tools-sessions-test-prompt me)))
          (should (equal (format "Move session: Lost → %s" (abbreviate-file-name new))
                         (plist-get (plist-get request :payload) :title)))
          (should (string-match-p "\\`Session Lost moves from " (plist-get (plist-get request :payload) :reason)))
          (harness-call 'permission/answer me (plist-get request :id) "deny-once"))
        (let ((r (harness-test-await p 5)))
          (should (plist-get r :is-error))
          (should (string-match-p "the user said no" (plist-get r :content)))))
      (should (equal old (plist-get (harness-call 'session/get other) :cwd)))
      ;; The directory goes while the user is asked: the move fails, and
      ;; says why plainly.
      (let* ((gone (harness-test-temp-dir))
             (p (funcall call (list :session_id "Lost" :directory gone))))
        (let ((request (harness-tools-sessions-test-prompt me)))
          (delete-directory gone)
          (harness-call 'permission/answer me (plist-get request :id) "allow-once"))
        (let ((r (harness-test-await p 5)))
          (should (plist-get r :is-error))
          (should (string-match-p "is not a directory" (plist-get r :content)))
          (should-not (string-match-p "Harness error" (plist-get r :content)))))
      (should (equal old (plist-get (harness-call 'session/get other) :cwd)))
      (let ((p (funcall call (list :session_id other :directory new :keep_old_directory t))))
        (harness-call 'permission/answer me (plist-get (harness-tools-sessions-test-prompt me) :id) "allow-once")
        (should (string-match-p "Session Lost moved from .* to .* stays allowed"
                                (plist-get (harness-test-await p 5) :content))))
      (let ((s (harness-call 'session/get other)))
        (should (equal new (plist-get s :cwd)))
        (should (equal (list old) (plist-get s :allowed-dirs)))))))

(ert-deftest harness-tools-sessions-move-a-running-session-waits ()
  "A session running a turn moves when it ends; moving it back to where
it works cancels that, without asking."
  (harness-tools-sessions-test-with
    (harness-test-load-module 'perms)
    (let* ((harness-provider-demo--delay 0.5)
           (new (harness-test-temp-dir))
           (me (harness-tools-sessions-test-session :name "Me"))
           (other (harness-tools-sessions-test-session :name "Busy"))
           (move (lambda ()
                   (let ((p (harness-call 'tools/execute me (list :id (harness-short-id) :name "session_move"
                                                                  :input (list :session_id other :directory new)))))
                     (let ((request (harness-tools-sessions-test-prompt me)))
                       (should (string-match-p "when the turn it is running ends"
                                               (plist-get (plist-get request :payload) :reason)))
                       (harness-call 'permission/answer me (plist-get request :id) "allow-once"))
                     (should (string-match-p "Busy is running a turn; it moves to"
                                             (plist-get (harness-test-await p 5) :content)))))))
      (harness-tools-sessions-test-ok me "session_send" (list :session_id other :message "long job"))
      (funcall move)
      (should (equal default-directory (plist-get (harness-call 'session/get other) :cwd)))
      (should (equal new (plist-get (plist-get (harness-call 'session/get other) :move) :cwd)))
      (should (string-match-p "stays in .*cancelled"
                              (harness-tools-sessions-test-ok me "session_move"
                                                              (list :session_id other :directory default-directory))))
      (should-not (plist-get (harness-call 'session/get other) :move))
      (funcall move)
      (harness-tools-sessions-test-idle other)
      (harness-test-wait (lambda () (equal new (plist-get (harness-call 'session/get other) :cwd))) 5 "the move"))))

(ert-deftest harness-tools-sessions-move-refusals-ask-nobody ()
  "A move that cannot be made fails at once, nobody asked: a session in
a worktree, a task's session, a directory that is no directory or the
one the session works in.  A non-interactive session cannot ask, and
the handler moves nothing the user did not confirm."
  (harness-tools-sessions-test-with
    (harness-test-load-module 'perms)
    (let* ((new (harness-test-temp-dir))
           (me (harness-tools-sessions-test-session :name "Me"))
           (wt (harness-tools-sessions-test-session :name "Branch" :worktree (harness-test-temp-dir)))
           (worker (harness-tools-sessions-test-session :name "Worker"))
           (requested nil))
      (harness-on 'permission/requested (lambda (&rest _) (setq requested t)))
      (puthash "t-move" (list :id "t-move" :session worker :cwd default-directory :state 'active
                              :created (float-time))
               harness-tasks--table)
      (cl-flet ((refused (regexp input)
                  (let ((r (harness-tools-sessions-test-run me "session_move" input)))
                    (should (plist-get r :is-error))
                    (should (string-match-p regexp (plist-get r :content)))
                    ;; The reason alone, not Emacs's printed form of the error.
                    (should-not (string-match-p "Harness error" (plist-get r :content))))))
        (refused "worktree" (list :session_id wt :directory new))
        (refused "Worker cannot move: it works on task t-move" (list :session_id worker :directory new))
        (refused "not a directory" (list :directory (expand-file-name "missing" new)))
        (refused "works in .* already" (list :directory default-directory))
        (refused "No session matches" (list :session_id "nobody" :directory new)))
      (should-not requested)
      (harness-call 'session/update me :non-interactive t :silent t)
      (let ((r (harness-tools-sessions-test-run me "session_move" (list :directory new))))
        (should (plist-get r :is-error))
        (should (string-match-p "needs the user's confirmation, and the session is non-interactive"
                                (plist-get r :content))))
      (should-not requested)
      (should (plist-get (harness-tools-sessions--move (list :session_id me :directory new :confirmed t)
                                                       (list :session-id me))
                         :is-error))
      (should (equal default-directory (plist-get (harness-call 'session/get me) :cwd))))))

(ert-deftest harness-tools-sessions-tasks ()
  (harness-tools-sessions-test-with
    (let* ((harness-provider-demo--delay 0.05)
           (me (harness-tools-sessions-test-session))
           (submitted (harness-tools-sessions-test-run me "task_submit" '(:prompt "Fix the lexer")))
           (id (plist-get (plist-get submitted :meta) :task-id)))
      (should-not (plist-get submitted :is-error))
      (should (string-prefix-p "t-" id))
      (should (string-match-p "Fix the lexer" (harness-tools-sessions-test-ok me "task_list" nil)))
      ;; Once its session is named, the title on the board leads the line.
      (harness-call 'session/update (plist-get (harness-call 'task/get id) :session) :name "Lexer fix" :silent t)
      (should (string-match-p (concat (regexp-quote id) " +[a-z-]+ +\"Lexer fix\": Fix the lexer")
                              (harness-tools-sessions-test-ok me "task_list" nil)))
      (let ((text (harness-tools-sessions-test-ok me "task_wait" (list :task_id (substring id 0 4)))))
        (should (string-match-p "Done waiting" text))
        (should (string-match-p "done" text))
        (should (string-match-p "Reply from the other session" text)))
      (should (string-match-p (regexp-quote id) (harness-tools-sessions-test-ok me "task_list" '(:column "done"))))
      (should (string-match-p "No tasks match" (harness-tools-sessions-test-ok me "task_list" '(:column "pending"))))
      ;; A follow-up reopens it; wait for it to settle again.
      (harness-tools-sessions-test-ok me "task_control" (list :task_id id :action "message" :message "and the parser"))
      (harness-tools-sessions-test-ok me "task_wait" (list :task_id id :until "done"))
      (should (= 2 (cl-count 'user (harness-call 'session/nodes (plist-get (harness-call 'task/get id) :session))
                             :key (lambda (n) (plist-get n :kind)))))
      (harness-tools-sessions-test-ok me "task_control" (list :task_id id :action "archive"))
      (should-not (string-match-p (regexp-quote id) (harness-tools-sessions-test-ok me "task_list" nil)))
      (should (string-match-p (regexp-quote id) (harness-tools-sessions-test-ok me "task_list" '(:include_archived t))))
      (harness-tools-sessions-test-ok me "task_control" (list :task_id id :action "delete"))
      (should-not (harness-call 'task/list)))))

(ert-deftest harness-tools-sessions-task-list-titles-waiting-tasks ()
  "A task waiting for a slot is listed with its title: it is named as it is submitted."
  (harness-tools-sessions-test-with
    (harness-test-load-module 'naming)
    (let* ((harness-tasks-max-running 0)
           (harness-naming-auto t)
           (harness-provider-demo-script-override
            '((:type text :delta "Lexer fix") (:type done :stop-reason end-turn)))
           (me (harness-tools-sessions-test-session :name "Me"))
           (submitted (harness-tools-sessions-test-run me "task_submit" '(:prompt "Fix the lexer")))
           (id (plist-get (plist-get submitted :meta) :task-id)))
      (harness-test-wait (lambda () (plist-get (harness-call 'task/get id) :name)) 5 "the task's name")
      (should (eq 'pending (plist-get (harness-call 'task/get id) :state)))
      (should-not (plist-get (harness-call 'task/get id) :session))
      (should (string-match-p (concat (regexp-quote id) " +pending +\"Lexer fix\": Fix the lexer")
                              (harness-tools-sessions-test-ok me "task_list" nil))))))

(ert-deftest harness-tools-sessions-task-list-marks-this-task ()
  "task_list marks the task of the calling session, its times, and keeps the most recent with limit."
  (harness-tools-sessions-test-with
    (let* ((harness-tasks-max-running 0)
           (me (harness-tools-sessions-test-session))
           (mine (plist-get (harness-call 'task/adopt me) :id))
           (listing (harness-tools-sessions-test-ok me "task_list" nil)))
      (should (eq 'needs-input (plist-get (harness-call 'task/get mine) :column)))
      (should (string-match-p (concat (regexp-quote mine) " +needs-input +Adopted session\\s-+(this task)") listing))
      (should (string-match-p ", created " listing))
      ;; limit keeps the most recently created, and says how many it hid.
      (let ((newer (plist-get (plist-get (harness-tools-sessions-test-run me "task_submit" '(:prompt "Second")) :meta)
                              :task-id)))
        (let ((listing (harness-tools-sessions-test-ok me "task_list" '(:limit 1))))
          (should (string-match-p (regexp-quote newer) listing))
          (should-not (string-match-p (regexp-quote mine) listing))
          (should (string-match-p "1 older task not shown" listing)))))))

(ert-deftest harness-tools-sessions-task-list-shows-a-refused-duplicate ()
  "task_list shows the task a write-up refused as a duplicate, and the one it named."
  (harness-tools-sessions-test-with
    (let* ((harness-tasks-max-running 0)
           (me (harness-tools-sessions-test-session))
           (first (plist-get (plist-get (harness-tools-sessions-test-run
                                         me "task_submit" '(:prompt "CSV export for reports"))
                                        :meta)
                             :task-id)))
      (let* ((harness-provider-demo-script-override
              `((:type text :delta ,(format "Duplicate of %s\n\nThe board has it already." first))
                (:type done :stop-reason end-turn)))
             (second (plist-get (plist-get (harness-tools-sessions-test-run
                                            me "task_submit" '(:prompt "export the reports as csv" :refine t))
                                           :meta)
                                :task-id)))
        (harness-test-wait (lambda () (eq 'duplicate (plist-get (harness-call 'task/get second) :outcome)))
                           5 "the refusal")
        (let ((listing (harness-tools-sessions-test-ok me "task_list" nil)))
          (should (string-match-p (concat (regexp-quote second) " +needs-input +export the reports as csv") listing))
          (should (string-match-p (concat "state refining (duplicate), duplicate of " (regexp-quote first)) listing))
          (should (string-match-p (regexp-quote first) listing)))))))

(ert-deftest harness-tools-sessions-pending-task-message-edits-prompt ()
  (harness-tools-sessions-test-with
    (let* ((harness-tasks-max-running 0)
           (me (harness-tools-sessions-test-session))
           (id (plist-get (plist-get (harness-tools-sessions-test-run me "task_submit" '(:prompt "First")) :meta) :task-id)))
      (should (eq 'pending (plist-get (harness-call 'task/get id) :state)))
      (harness-tools-sessions-test-ok me "task_control" (list :task_id id :action "message" :message "Also second"))
      (should (equal "First\n\nAlso second" (plist-get (harness-call 'task/get id) :prompt)))
      (harness-tools-sessions-test-ok me "task_control" (list :task_id id :action "cancel"))
      (should-not (harness-call 'task/list)))))

(ert-deftest harness-tools-sessions-task-for-the-backlog ()
  "task_submit with refine writes a task up; task_wait settles once it waits to be started."
  (harness-tools-sessions-test-with
    (let* ((harness-tasks-max-running nil)
           (harness-provider-demo-script-override
            '((:type text :delta "Fix the lexer\n\nIt drops the last token.") (:type done :stop-reason end-turn)))
           (me (harness-tools-sessions-test-session))
           (submitted (harness-tools-sessions-test-run me "task_submit" '(:prompt "lexer eats a token" :refine t)))
           (id (plist-get (plist-get submitted :meta) :task-id)))
      (should (string-match-p "backlog" (plist-get submitted :content)))
      (let ((text (harness-tools-sessions-test-ok me "task_wait" (list :task_id id))))
        (should (string-match-p "Done waiting" text))
        (should (string-match-p "It drops the last token" text)))
      (let ((task (harness-call 'task/get id)))
        (should (eq 'pending (plist-get task :state)))
        (should (equal "Fix the lexer\n\nIt drops the last token." (plist-get task :prompt))))
      (harness-tools-sessions-test-ok me "task_control" (list :task_id id :action "start"))
      (harness-tools-sessions-test-ok me "task_wait" (list :task_id id :until "done"))
      (should (eq 'done (plist-get (harness-call 'task/get id) :state))))))

(ert-deftest harness-tools-sessions-task-submit-main-tree ()
  "task_submit passes main_tree through; the result and task_list say so."
  (harness-tools-sessions-test-with
    (let* ((harness-tasks-max-running 0)
           (me (harness-tools-sessions-test-session))
           (submitted (harness-tools-sessions-test-run me "task_submit"
                                                       '(:prompt "Clean the checkout" :main_tree t)))
           (id (plist-get (plist-get submitted :meta) :task-id)))
      (should-not (plist-get submitted :is-error))
      (should (string-match-p "main tree" (plist-get submitted :content)))
      (should (harness-json-true-p (plist-get (harness-call 'task/get id) :main-tree)))
      (should (string-match-p (regexp-quote ", main tree (no worktree)")
                              (harness-tools-sessions-test-ok me "task_list" nil)))
      ;; Without the flag nothing says main tree.
      (let ((plain (plist-get (plist-get (harness-tools-sessions-test-run me "task_submit" '(:prompt "Ordinary"))
                                         :meta)
                              :task-id)))
        (should-not (harness-json-true-p (plist-get (harness-call 'task/get plain) :main-tree)))))))

(ert-deftest harness-tools-sessions-task-priority ()
  "task_submit takes a priority, task_control changes it, task_list shows it unless medium."
  (harness-tools-sessions-test-with
    (let* ((harness-tasks-max-running 0)
           (me (harness-tools-sessions-test-session))
           (submitted (harness-tools-sessions-test-run me "task_submit" '(:prompt "Urgent fix" :priority "high")))
           (id (plist-get (plist-get submitted :meta) :task-id))
           (plain (plist-get (plist-get (harness-tools-sessions-test-run me "task_submit" '(:prompt "Ordinary"))
                                        :meta)
                             :task-id)))
      (should-not (plist-get submitted :is-error))
      (should (eq 'high (plist-get (harness-call 'task/get id) :priority)))
      (should (eq 'medium (plist-get (harness-call 'task/get plain) :priority)))
      (let ((listing (harness-tools-sessions-test-ok me "task_list" nil)))
        (should (string-match-p (concat (regexp-quote id) ".*\n    state pending, priority high") listing))
        ;; Medium is the default and goes without saying.
        (should-not (string-match-p "priority medium" listing)))
      (let ((text (harness-tools-sessions-test-ok me "task_control" (list :task_id plain :action "priority" :priority "low"))))
        (should (string-match-p "\\`Priority low\\." text))
        (should (string-match-p ", priority low" text)))
      (should (eq 'low (plist-get (harness-call 'task/get plain) :priority)))
      ;; It needs a priority, and a real one.
      (should (plist-get (harness-tools-sessions-test-run me "task_control" (list :task_id plain :action "priority"))
                         :is-error))
      (should (plist-get (harness-tools-sessions-test-run me "task_control"
                                                          (list :task_id plain :action "priority" :priority "urgent"))
                         :is-error))
      (should (plist-get (harness-tools-sessions-test-run me "task_submit" '(:prompt "Nope" :priority "urgent"))
                         :is-error))
      (should (eq 'low (plist-get (harness-call 'task/get plain) :priority)))
      (should (= 2 (length (harness-call 'task/list)))))))

(ert-deftest harness-tools-sessions-task-review ()
  "task_wait settles when finished work waits for review; task_control sends it back, then verifies it."
  (harness-tools-sessions-test-with
    (let* ((harness-tasks-require-verification t)
           (me (harness-tools-sessions-test-session))
           (id (plist-get (plist-get (harness-tools-sessions-test-run me "task_submit" '(:prompt "Fix the lexer")) :meta)
                          :task-id)))
      (let ((text (harness-tools-sessions-test-ok me "task_wait" (list :task_id id))))
        (should (string-match-p "Done waiting" text))
        (should (string-match-p (concat (regexp-quote id) " +review +Fix the lexer") text)))
      (should (string-match-p (regexp-quote id) (harness-tools-sessions-test-ok me "task_list" '(:column "review"))))
      (should (string-match-p "No tasks match" (harness-tools-sessions-test-ok me "task_list" '(:column "done"))))
      ;; Sending it back needs the feedback.
      (should (plist-get (harness-tools-sessions-test-run me "task_control" (list :task_id id :action "reject")) :is-error))
      (harness-tools-sessions-test-ok me "task_control" (list :task_id id :action "reject" :message "Also the parser."))
      (should (string-match-p "sent back 1 time\\b"
                              (harness-tools-sessions-test-ok me "task_wait" (list :task_id id :until "review"))))
      (should (= 2 (cl-count 'user (harness-call 'session/nodes (plist-get (harness-call 'task/get id) :session))
                             :key (lambda (n) (plist-get n :kind)))))
      (let ((text (harness-tools-sessions-test-ok me "task_control" (list :task_id id :action "verify"))))
        (should (string-match-p "verify done" text))
        (should (string-match-p "state done.*, verified" text)))
      (should (plist-get (harness-tools-sessions-test-run me "task_control" (list :task_id id :action "verify")) :is-error))
      (should (eq 'done (plist-get (harness-call 'task/get id) :state))))))

(defvar harness-tasks--reject-message)
(defvar harness-tasks--aside-message)
(declare-function harness-tasks--reject-text "harness-tasks" (feedback))
(declare-function harness-tasks--aside-text "harness-tasks" (text))

(ert-deftest harness-tools-sessions-message-to-a-task-in-review-is-no-review ()
  "session_send and task_control's message reach a task in review as this session's.
Neither is a review, so neither sends the task back: the message says
who sent it (its header and its node's sender), opens with the aside
text and never the reject text, keeps no round of feedback, and the
task waits for review again once its turn ends.  Only task_control's
reject sends the work back, opened by the reject text."
  (harness-tools-sessions-test-with
    (let* ((harness-tasks-require-verification t)
           (me (harness-tools-sessions-test-session :name "Onboard benito"))
           (id (plist-get (plist-get (harness-tools-sessions-test-run me "task_submit" '(:prompt "Fix the lexer")) :meta)
                          :task-id))
           (header (format "[Message from session %s \"Onboard benito\"]\n\n" me))
           (sender (list :kind 'session :id me :name "Onboard benito")))
      (harness-tools-sessions-test-ok me "task_wait" (list :task_id id))
      (should (eq 'review (plist-get (harness-call 'task/get id) :state)))
      (let* ((sid (plist-get (harness-call 'task/get id) :session))
             (last-user (lambda () (car (last (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'user))
                                                                (harness-call 'session/nodes sid)))))))
        ;; session_send, waiting for the reply.
        (should (string-match-p "turn ended: end-turn"
                                (harness-tools-sessions-test-ok me "session_send"
                                                                (list :session_id sid :message "Applying now." :wait t))))
        (let ((node (funcall last-user)))
          (should (equal (harness-tasks--aside-text (concat header "Applying now.")) (plist-get node :content)))
          (should (string-prefix-p harness-tasks--aside-message (plist-get node :content)))
          (should-not (string-search harness-tasks--reject-message (plist-get node :content)))
          (should (equal sender (harness-node-sender node))))
        (let ((line (harness-tools-sessions-test-ok me "task_wait" (list :task_id id :until "review"))))
          (should (string-match-p (concat (regexp-quote id) " +review ") line))
          (should-not (string-match-p "sent back" line)))
        (should-not (plist-get (harness-call 'task/get id) :feedback))
        ;; task_control's message: no review either, and it says who sent it.
        (harness-tools-sessions-test-ok me "task_control" (list :task_id id :action "message" :message "Traefik checks out."))
        (let ((line (harness-tools-sessions-test-ok me "task_wait" (list :task_id id :until "review"))))
          (should-not (string-match-p "sent back" line)))
        (let ((node (funcall last-user)))
          (should (equal (harness-tasks--aside-text (concat header "Traefik checks out.")) (plist-get node :content)))
          (should-not (string-search harness-tasks--reject-message (plist-get node :content)))
          (should (equal sender (harness-node-sender node))))
        (should-not (plist-get (harness-call 'task/get id) :feedback))
        ;; task_control's reject sends it back, as the user's review.
        (harness-tools-sessions-test-ok me "task_control" (list :task_id id :action "reject" :message "Also the parser."))
        (should (string-match-p "sent back 1 time\\b"
                                (harness-tools-sessions-test-ok me "task_wait" (list :task_id id :until "review"))))
        (should (equal (harness-tasks--reject-text "Also the parser.") (plist-get (funcall last-user) :content)))
        (should (equal '("Also the parser.")
                       (mapcar (lambda (round) (plist-get round :text))
                               (plist-get (harness-call 'task/get id) :feedback))))))))

(ert-deftest harness-tools-sessions-task-message-says-who-sent-it ()
  "task_control's message to a task's session is the calling session's, as session_send's is.
A follow-up to a done task too: its header and its node's sender name
the calling session, not the user."
  (harness-tools-sessions-test-with
    (let* ((me (harness-tools-sessions-test-session :name "Boss"))
           (id (plist-get (plist-get (harness-tools-sessions-test-run me "task_submit" '(:prompt "Fix the lexer")) :meta)
                          :task-id)))
      (harness-tools-sessions-test-ok me "task_wait" (list :task_id id :until "done"))
      (harness-tools-sessions-test-ok me "task_control" (list :task_id id :action "message" :message "and the parser"))
      (harness-tools-sessions-test-ok me "task_wait" (list :task_id id :until "done"))
      (let ((node (car (last (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'user))
                                               (harness-call 'session/nodes (plist-get (harness-call 'task/get id) :session)))))))
        (should (equal (format "[Message from session %s \"Boss\"]\n\nand the parser" me) (plist-get node :content)))
        (should (equal (list :kind 'session :id me :name "Boss") (harness-node-sender node)))))))

(ert-deftest harness-tools-sessions-task-list-merging-column ()
  "A task holding a place in the merge queue lists as merging.
task_list filters on it and task_wait can wait for it."
  (harness-tools-sessions-test-with
    (let* ((harness-tasks-max-running 0)
           (me (harness-tools-sessions-test-session))
           (id (plist-get (plist-get (harness-tools-sessions-test-run me "task_submit" '(:prompt "Fix the lexer")) :meta)
                          :task-id)))
      (harness-tasks--set id :state 'merging :merge-status 'queued :merge-queued (float-time))
      (let ((listing (harness-tools-sessions-test-ok me "task_list" '(:column "merging"))))
        (should (string-match-p (concat (regexp-quote id) " +merging +Fix the lexer") listing))
        (should (string-match-p "merge queued" listing)))
      (should (string-match-p "No tasks match" (harness-tools-sessions-test-ok me "task_list" '(:column "active"))))
      (should (string-match-p "Done waiting"
                              (harness-tools-sessions-test-ok me "task_wait" (list :task_id id :until "merging")))))))

(provide 'harness-tools-sessions-test)
;;; harness-tools-sessions-test.el ends here
