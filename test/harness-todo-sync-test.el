;;; harness-todo-sync-test.el --- Tests for the todo-sync module  -*- lexical-binding: t; -*-

;;; Commentary:

;; todo-sync keeps a session's todo list true to its work: it counts the
;; steps (model calls) of a transcript, and when the list has gone stale
;; has a cheap model (or the session's own, on a fork) write it again.
;; These tests cover the reading of an answer, the counting of steps, when
;; a sync is due, the two kinds of request, what becomes of an answer, and
;; the per-session switch.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-todo-sync)

(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent--turns)
(defvar harness-todo-sync-steps)
(defvar harness-todo-sync-model)
(defvar harness-todo-sync--steps)
(defvar harness-todo-sync--phase)
(defvar harness-todo-sync--last-node)
(defvar harness-todo-sync--anchor)
(defvar harness-todo-sync--counted)
(defvar harness-todo-sync--running)
(defvar harness-todo-sync--failed)
(declare-function harness-provider-demo--todos "harness-provider-demo" (request))

(defconst harness-todo-sync-test-answer
  '((:type text :delta "[x] Read the code\n[~] Edit it\n") (:type text :delta "[ ] Run the tests")
    (:type usage :input 300 :output 30 :cost 0.0002)
    (:type done :stop-reason end-turn))
  "What the demo provider answers a request for a todo list with.")

(defmacro harness-todo-sync-test-with (&rest body)
  "Load the state layer with the demo provider and todo-sync; run BODY.
A sync is due after three steps and asks the demo provider; the
answer is `harness-todo-sync-test-answer'."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo tools session agent tools-todo tools-fs
                  todo-sync))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (dolist (table (list harness-todo-sync--steps harness-todo-sync--phase harness-todo-sync--last-node
                          harness-todo-sync--anchor harness-todo-sync--counted harness-todo-sync--running
                          harness-todo-sync--failed))
       (clrhash table))
     (let ((harness-provider-demo--delay 0.005)
           (harness-provider-demo-script-override harness-todo-sync-test-answer)
           (harness-todo-sync-steps 3)
           (harness-todo-sync-model "demo:scripted")
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       ,@body)))

(defun harness-todo-sync-test-session (&rest plist)
  "Create a demo session, PLIST overriding its settings; return its id."
  (plist-get (apply #'harness-call 'session/create
                    (append plist (list :cwd (harness-test-temp-dir) :model "demo:scripted")))
             :id))

(defun harness-todo-sync-test-step (sid &optional text)
  "Append one step to SID's transcript: TEXT and a tool call, answered.
TEXT defaults to a few words."
  (let ((call (harness-short-id 6)))
    (harness-call 'session/append sid (list :kind 'assistant :content (or text "Looking at it.")))
    (harness-call 'session/append sid (list :kind 'tool-call :tool "read_file" :call-id call
                                            :title (format "Read %s" call)))
    (harness-call 'session/append sid (list :kind 'tool-result :call-id call :output "contents"))))

(defun harness-todo-sync-test-todos (sid)
  "Return the todo list of session SID."
  (plist-get (harness-call 'session/get sid) :todos))

(defun harness-todo-sync-test-summary (todos)
  "Return TODOS as ((TEXT . STATUS) ...)."
  (mapcar (lambda (todo) (cons (plist-get todo :text) (plist-get todo :status))) todos))

(defmacro harness-todo-sync-test-requests (var &rest body)
  "Run BODY with every `provider/complete' request pushed on the list VAR."
  (declare (indent 1))
  (let ((orig (make-symbol "orig")))
    `(let ((,var nil)
           (,orig (symbol-function 'harness-method/provider/complete)))
       (cl-letf (((symbol-function 'harness-method/provider/complete)
                  (lambda (req) (push req ,var) (funcall ,orig req))))
         ,@body))))

(defun harness-todo-sync-test-pause (&optional seconds)
  "Let the event loop run for SECONDS (default 0.2): time for what would happen to happen."
  (let ((deadline (+ (float-time) (or seconds 0.2))))
    (while (< (float-time) deadline)
      (accept-process-output nil 0.02)
      (sit-for 0.005))))

(defun harness-todo-sync-test-request-text (request)
  "Return the text of the last message of REQUEST."
  (mapconcat (lambda (block) (or (plist-get block :text) ""))
             (plist-get (car (last (plist-get request :messages))) :content) "\n"))

;;;; Reading an answer

(ert-deftest harness-todo-sync-parse-reads-a-checklist ()
  (should (equal '(:todos ((:text "Read the code" :status done)
                           (:text "Edit it" :status in-progress)
                           (:text "Run the tests" :status pending)))
                 (harness-todo-sync-parse "[x] Read the code\n[~] Edit it\n[ ] Run the tests")))
  ;; Bullets, numbers, capitals and no space after the bracket.
  (should (equal '(:todos ((:text "One" :status done) (:text "Two" :status in-progress)
                           (:text "Three" :status pending) (:text "Four" :status pending)))
                 (harness-todo-sync-parse "- [X] One\n* [~] Two\n1. [ ] Three\n2) []Four"))))

(ert-deftest harness-todo-sync-parse-is-lenient-about-what-surrounds-the-list ()
  "A model that cannot help talking is still understood."
  (should (equal '(:todos ((:text "Write the parser" :status done) (:text "Test it" :status pending)))
                 (harness-todo-sync-parse
                  "Sure! Here is the updated list:\n\n- [x] **Write the parser**.\n- [ ] `Test it`\n\nLet me know."))))

(ert-deftest harness-todo-sync-parse-keeps-one-item-in-hand ()
  (should (equal '((:text "A" :status in-progress) (:text "B" :status pending) (:text "C" :status done))
                 (cadr (harness-todo-sync-parse "[~] A\n[~] B\n[x] C")))))

(ert-deftest harness-todo-sync-parse-limits-the-list ()
  (let* ((many (mapconcat (lambda (i) (format "[ ] item %d" i)) (number-sequence 1 40) "\n"))
         (items (cadr (harness-todo-sync-parse many)))
         (long (cadr (harness-todo-sync-parse (concat "[ ] " (make-string 300 ?x))))))
    (should (= harness-todo-sync--max-items (length items)))
    (should (equal "item 1" (plist-get (car items) :text)))
    (should (= harness-todo-sync--item-chars (length (plist-get (car long) :text))))
    (should (string-suffix-p "…" (plist-get (car long) :text)))))

(ert-deftest harness-todo-sync-parse-reads-the-two-words ()
  (should (equal '(:unchanged) (harness-todo-sync-parse "UNCHANGED")))
  (should (equal '(:unchanged) (harness-todo-sync-parse "**Unchanged.**\nThe list is right.")))
  (should (equal '(:none) (harness-todo-sync-parse "NONE")))
  (should (equal '(:none) (harness-todo-sync-parse "  none.\n")))
  ;; Items win over a word, and a sentence is no word.
  (should (eq :todos (car (harness-todo-sync-parse "UNCHANGED\n[ ] but this")))))

(ert-deftest harness-todo-sync-parse-gives-nothing-for-anything-else ()
  (should-not (harness-todo-sync-parse ""))
  (should-not (harness-todo-sync-parse nil))
  (should-not (harness-todo-sync-parse "None of the items changed"))
  (should-not (harness-todo-sync-parse "The agent is making progress."))
  ;; Brackets that are no checkbox.
  (should-not (harness-todo-sync-parse "[1] a reference\n[note] something\n[ ]"))
  (should-not (harness-todo-sync-parse "- plain bullet\n- another")))

(ert-deftest harness-todo-sync-todos-keep-the-ids-of-items-whose-words-stay ()
  (let* ((old '((:id "a" :text "Read the code" :status done)
                (:id "t2" :text "Edit it" :status in-progress)))
         (todos (harness-todo-sync--todos
                 '((:text "Add a test" :status pending) (:text "read the CODE" :status done)
                   (:text "Edit it" :status in-progress) (:text "Ship it" :status pending))
                 old)))
    (should (equal '("t1" "a" "t2" "t3") (mapcar (lambda (todo) (plist-get todo :id)) todos)))
    (should (equal '("Add a test" "read the CODE" "Edit it" "Ship it")
                   (mapcar (lambda (todo) (plist-get todo :text)) todos)))))

;;;; What the model is asked

(ert-deftest harness-todo-sync-activity-is-what-followed-the-anchor ()
  (let* ((nodes (list (list :id "n1" :kind 'user :content "build the widget")
                      (list :id "n2" :kind 'assistant :content "I will look first.")
                      (list :id "n3" :kind 'thinking :content "hmm, quietly")
                      (list :id "n4" :kind 'tool-call :tool "bash" :title "Run the tests")
                      (list :id "n5" :kind 'hint :content "a note of the harness")
                      (list :id "n6" :kind 'tool-result :output "3 tests failed\n  at line 4" :is-error t)
                      ;; A call the harness recorded is not the model's work.
                      (list :id "n7" :kind 'tool-call :tool "spawn_agent" :title "Resolve a conflict"
                            :meta (list :from (list :kind 'system :source "merge queue")))))
         (all (harness-todo-sync--activity nodes nil)))
    (should (equal (concat "[engineer] build the widget\n[agent] I will look first.\n"
                           "[tool bash] Run the tests\n[failed] 3 tests failed at line 4")
                   all))
    (should (equal "[failed] 3 tests failed at line 4" (harness-todo-sync--activity nodes "n4")))
    ;; An anchor that is the last node leaves nothing; one that is gone, everything.
    (should (equal "" (harness-todo-sync--activity nodes "n7")))
    (should (equal all (harness-todo-sync--activity nodes "n-gone")))))

(ert-deftest harness-todo-sync-activity-keeps-the-newest-that-fit ()
  (let* ((harness-todo-sync--activity-chars 200)
         (nodes (cl-loop for i from 1 to 20
                         collect (list :id (format "n%d" i) :kind 'assistant
                                       :content (format "step %02d %s" i (make-string 30 ?.)))))
         (text (harness-todo-sync--activity nodes nil)))
    (should (string-match-p "\\`\\[[0-9]+ earlier entries left out\\]\n" text))
    (should (string-suffix-p (format "step 20 %s" (make-string 30 ?.)) text))
    (should-not (string-match-p "step 01 " text))
    (should (< (length text) 300))))

(ert-deftest harness-todo-sync-the-dumb-agent-is-asked-on-its-own ()
  "The question stands alone: the request, the list, the work since; no tools, no session state."
  (harness-todo-sync-test-with
    (let ((sid (harness-todo-sync-test-session)))
      (harness-call 'session/append sid '(:kind user :content "Make the widget faster"))
      (harness-call 'session/set-todos sid '((:id "a" :text "Profile it" :status done)
                                             (:id "b" :text "Cache the lookup" :status in-progress)))
      (harness-todo-sync-test-step sid "Profiled: the lookup dominates.")
      (harness-todo-sync-test-requests requests
        (should (eq 'updated (plist-get (harness-test-await (harness-call 'todo-sync/run sid)) :status)))
        (should (= 1 (length requests)))
        (let* ((req (car requests))
               (text (harness-todo-sync-test-request-text req)))
          (should (equal "demo:scripted" (plist-get req :model)))
          (should (eq t (plist-get req :ephemeral)))
          (should (eq t (plist-get req :no-thinking)))
          (should-not (plist-get req :tools))
          (should-not (plist-get req :provider-state))
          (should-not (plist-member (plist-get req :session) :provider-state))
          (should (equal sid (plist-get (plist-get req :session) :id)))
          ;; Recorded as an internal session made for the session.
          (should (equal "Todo sync" (plist-get req :job)))
          (should (equal sid (plist-get req :job-parent)))
          (should (string-prefix-p "You keep the todo list" (plist-get req :system)))
          (should (= 1 (length (plist-get req :messages))))
          (should (string-match-p "The engineer's request:\n<message>\nMake the widget faster\n</message>" text))
          (should (string-match-p "The todo list now:\n\\[x\\] Profile it\n\\[~\\] Cache the lookup\n" text))
          (should (string-match-p "<activity>\n\\[agent\\] Profiled: the lookup dominates\\." text))
          (should (string-match-p "\\[tool read_file\\] Read " text))
          (should (string-suffix-p harness-todo-sync--ask text)))))))

(ert-deftest harness-todo-sync-the-simple-tier-is-the-default-model ()
  (harness-todo-sync-test-with
    (let ((harness-todo-sync-model 'auto)
          (session (list :model "demo:scripted")))
      ;; The demo provider names no tiers: the session's own model stands in.
      (should (equal "demo:scripted" (harness-todo-sync--model session)))
      (cl-letf (((symbol-function 'harness-method/provider/tier-model)
                 (lambda (model &optional tier) (and (equal model "demo:scripted") (eq tier 'simple) "demo:small"))))
        (should (equal "demo:small" (harness-todo-sync--model session)))
        (let ((harness-todo-sync-model "demo:other"))
          (should (equal "demo:other" (harness-todo-sync--model session))))
        (let ((harness-todo-sync-model nil))
          (should (equal "demo:scripted" (harness-todo-sync--model session))))))))

;;;; Counting steps

(ert-deftest harness-todo-sync-counts-the-steps-the-model-takes ()
  "A step is what the model writes or asks for between two tool results."
  (harness-todo-sync-test-with
    (let ((harness-todo-sync-steps nil)
          (sid (harness-todo-sync-test-session)))
      (cl-flet ((steps () (gethash sid harness-todo-sync--steps 0))
                (add (kind &rest more) (harness-call 'session/append sid (append (list :kind kind) more))))
        (add 'user :content "go")
        (should (= 0 (steps)))
        ;; Words, thinking and two calls are one step.
        (add 'thinking :content "plan")
        (add 'assistant :content "Let me look.")
        (add 'tool-call :tool "glob" :call-id "c1" :title "Find")
        (add 'tool-call :tool "grep" :call-id "c2" :title "Search")
        (should (= 1 (steps)))
        (add 'tool-result :call-id "c1" :output "x")
        (add 'tool-result :call-id "c2" :output "y")
        (should (= 1 (steps)))
        ;; A hint is nothing; the model speaking after a result is a step.
        (add 'hint :content "a note")
        (add 'assistant :content "Found it.")
        (should (= 2 (steps)))
        ;; Not the model's: a call the harness recorded, and its result.
        (add 'tool-call :tool "spawn_agent" :call-id "c3" :title "Resolve"
             :meta (list :from (list :kind 'system :source "merge queue")))
        (add 'tool-result :call-id "c3" :output "z"
             :meta (list :from (list :kind 'system :source "merge queue")))
        (should (= 2 (steps)))
        ;; The user steering the model ends a step too.
        (add 'user :content "also this")
        (add 'assistant :content "On it.")
        (should (= 3 (steps)))))))

(ert-deftest harness-todo-sync-leaves-internal-and-btw-sessions-alone ()
  (harness-todo-sync-test-with
    (let ((btw (harness-todo-sync-test-session :kind 'btw))
          (internal (harness-call 'session/internal-start :job "Recap" :model "demo:scripted" :prompt "x"))
          (main (harness-todo-sync-test-session)))
      (dolist (sid (list btw internal main))
        (harness-call 'session/append sid '(:kind assistant :content "words")))
      (should (= 1 (gethash main harness-todo-sync--steps 0)))
      (should (= 0 (gethash btw harness-todo-sync--steps 0)))
      (should (= 0 (gethash internal harness-todo-sync--steps 0))))))

(ert-deftest harness-todo-sync-any-update-of-the-list-starts-the-count-over ()
  "The model's own todo_write counts: a model that keeps its list is left alone."
  (harness-todo-sync-test-with
    (let ((harness-todo-sync-steps 9)
          (sid (harness-todo-sync-test-session)))
      (harness-todo-sync-test-step sid)
      (harness-todo-sync-test-step sid)
      (should (= 2 (gethash sid harness-todo-sync--steps)))
      (let ((last (plist-get (harness-call 'session/get sid) :head)))
        (harness-call 'session/set-todos sid '((:id "t1" :text "A" :status pending)))
        (should (= 0 (gethash sid harness-todo-sync--steps)))
        (should (equal last (gethash sid harness-todo-sync--anchor)))))))

(ert-deftest harness-todo-sync-forgets-a-deleted-session ()
  (harness-todo-sync-test-with
    (let ((sid (harness-todo-sync-test-session)))
      (harness-todo-sync-test-step sid)
      (should (gethash sid harness-todo-sync--steps))
      (harness-call 'session/delete sid)
      (should-not (gethash sid harness-todo-sync--steps))
      (should-not (gethash sid harness-todo-sync--counted))
      (should-not (gethash sid harness-todo-sync--last-node)))))

;;;; When a sync is due

(ert-deftest harness-todo-sync-writes-the-list-after-enough-steps ()
  (harness-todo-sync-test-with
    (let ((sid (harness-todo-sync-test-session))
          (done nil))
      (harness-on 'todo-sync/done (lambda (id todos) (push (cons id todos) done)))
      (harness-call 'session/append sid '(:kind user :content "do the thing"))
      (harness-todo-sync-test-requests requests
        (harness-todo-sync-test-step sid)
        (harness-todo-sync-test-step sid)
        (harness-todo-sync-test-pause)
        ;; Two steps are too few.
        (should-not requests)
        (should-not (harness-todo-sync-test-todos sid))
        (harness-todo-sync-test-step sid)
        (harness-test-wait (lambda () (harness-todo-sync-test-todos sid)) 5 "the list")
        (should (= 1 (length requests))))
      (should (equal '(("Read the code" . done) ("Edit it" . in-progress) ("Run the tests" . pending))
                     (harness-todo-sync-test-summary (harness-todo-sync-test-todos sid))))
      (should (equal '("t1" "t2" "t3") (mapcar (lambda (todo) (plist-get todo :id))
                                               (harness-todo-sync-test-todos sid))))
      (should (equal (list sid) (mapcar #'car done)))
      ;; The count starts over, and nothing is running.
      (should (= 0 (gethash sid harness-todo-sync--steps)))
      (should (zerop (hash-table-count harness-todo-sync--running)))
      (should (equal (list (list "Todo sync" sid 'idle))
                     (mapcar (lambda (s) (list (plist-get s :name) (plist-get s :parent-id) (plist-get s :status)))
                             (harness-call 'session/select '(:kind internal))))))))

(ert-deftest harness-todo-sync-steps-are-counted-across-turns ()
  "The unit is the step, not the turn: a new turn does not start the count over."
  (harness-todo-sync-test-with
    (let ((harness-todo-sync-steps 4)
          (sid (harness-todo-sync-test-session))
          (ended nil))
      (harness-on 'agent/turn-ended (lambda (id _reason) (push id ended)))
      (harness-todo-sync-test-requests requests
        ;; Three steps and the turn ends: no list yet, so nothing is made
        ;; from nothing, and the three steps are still counted.
        (harness-call 'session/append sid '(:kind user :content "do the thing"))
        (dotimes (_ 3) (harness-todo-sync-test-step sid))
        (harness-emit 'agent/turn-ended sid 'end-turn)
        (harness-todo-sync-test-pause)
        (should (equal (list sid) ended))
        (should-not requests)
        (should (= 3 (gethash sid harness-todo-sync--steps)))
        ;; The first step of the next turn is the fourth.
        (harness-call 'session/append sid '(:kind user :content "and now this"))
        (harness-todo-sync-test-step sid)
        (harness-test-wait (lambda () (harness-todo-sync-test-todos sid)) 5 "the list")
        (should (= 1 (length requests)))))))

(ert-deftest harness-todo-sync-a-long-turn-is-synced-every-n-steps-before-it-ends ()
  "Steps are what is counted: one turn of many steps gets a sync at each N, not one at its end."
  (harness-todo-sync-test-with
    (let ((sid (harness-todo-sync-test-session))
          (ended nil))
      (harness-on 'agent/turn-ended (lambda (id _reason) (push id ended)))
      (harness-call 'session/append sid '(:kind user :content "a long job"))
      (harness-todo-sync-test-requests requests
        (dotimes (round 3)
          (dotimes (_ 3) (harness-todo-sync-test-step sid))
          (harness-test-wait (lambda () (= (1+ round) (length requests))) 5
                             (format "sync number %d" (1+ round)))
          ;; Let the answer land: the count starts over once it has.
          (harness-test-wait (lambda () (zerop (hash-table-count harness-todo-sync--running))) 5
                             "the request to finish")
          (should (= 0 (gethash sid harness-todo-sync--steps))))
        (should (= 3 (length requests)))
        (should-not ended)))))

(ert-deftest harness-todo-sync-does-nothing-without-an-interval ()
  (harness-todo-sync-test-with
    (let ((harness-todo-sync-steps nil)
          (sid (harness-todo-sync-test-session)))
      (harness-todo-sync-test-requests requests
        (dotimes (_ 8) (harness-todo-sync-test-step sid))
        (harness-todo-sync-test-pause)
        (should-not requests)
        (should-not (harness-todo-sync--maybe sid))))))

(ert-deftest harness-todo-sync-a-model-that-keeps-its-list-is-not-second-guessed ()
  (harness-todo-sync-test-with
    (let ((sid (harness-todo-sync-test-session)))
      (harness-todo-sync-test-requests requests
        (dotimes (i 9)
          (harness-todo-sync-test-step sid)
          ;; The model's own todo_write, every other step.
          (when (cl-evenp i)
            (harness-call 'session/set-todos sid (list (list :id "t1" :text (format "Step %d" i) :status 'pending)))))
        (harness-todo-sync-test-pause)
        (should-not requests)
        (should (equal "Step 8" (plist-get (car (harness-todo-sync-test-todos sid)) :text)))))))

(ert-deftest harness-todo-sync-a-turn-that-ends-gets-its-open-list-looked-at-early ()
  "After half the steps, and only for a list with something left to do."
  (harness-todo-sync-test-with
    (let ((sid (harness-todo-sync-test-session)))
      (harness-todo-sync-test-requests requests
        ;; Two steps of three, an open list: it is due when the turn ends.
        (harness-call 'session/set-todos sid '((:id "t1" :text "Do it" :status in-progress)))
        (harness-todo-sync-test-step sid)
        (harness-emit 'agent/turn-ended sid 'end-turn)
        (harness-todo-sync-test-pause)
        (should-not requests)
        (harness-todo-sync-test-step sid)
        (harness-emit 'agent/turn-ended sid 'end-turn)
        (harness-test-wait (lambda () requests) 5 "the sync")
        (should (= 1 (length requests)))))))

(ert-deftest harness-todo-sync-a-turn-that-ends-makes-no-list-from-nothing ()
  (harness-todo-sync-test-with
    (let ((sid (harness-todo-sync-test-session)))
      (harness-todo-sync-test-requests requests
        (let ((harness-todo-sync-steps 4))
          ;; Three steps, past half of four: but there is no list, and a
          ;; finished one has nothing left to close out.
          (dotimes (_ 3) (harness-todo-sync-test-step sid))
          (harness-emit 'agent/turn-ended sid 'end-turn)
          (harness-call 'session/set-todos sid '((:id "t1" :text "Done" :status done)))
          (dotimes (_ 3) (harness-todo-sync-test-step sid))
          (harness-emit 'agent/turn-ended sid 'end-turn)
          (harness-todo-sync-test-pause)
          (should-not requests))))))

;;;; What becomes of an answer

(ert-deftest harness-todo-sync-run-writes-the-list-now ()
  (harness-todo-sync-test-with
    (let* ((sid (harness-todo-sync-test-session))
           (promise (harness-call 'todo-sync/run sid)))
      ;; A request under way is the one returned.
      (should (eq promise (harness-call 'todo-sync/run sid)))
      (let ((outcome (harness-test-await promise)))
        (should (eq 'updated (plist-get outcome :status)))
        (should (= 3 (length (plist-get outcome :todos))))
        (should (equal (harness-todo-sync-test-todos sid) (plist-get outcome :todos)))))))

(ert-deftest harness-todo-sync-refuses-an-internal-session ()
  (harness-todo-sync-test-with
    (let ((internal (harness-call 'session/internal-start :job "Recap" :model "demo:scripted" :prompt "x")))
      (should-error (harness-call 'todo-sync/run internal))
      (should-error (harness-call 'todo-sync/run "no-such-session")))))

(ert-deftest harness-todo-sync-unchanged-and-none-leave-the-list-and-start-the-count-over ()
  (harness-todo-sync-test-with
    (let ((sid (harness-todo-sync-test-session))
          (list '((:id "t1" :text "Only item" :status in-progress))))
      (harness-call 'session/set-todos sid list)
      (dolist (word '("UNCHANGED" "NONE"))
        (let ((harness-provider-demo-script-override
               `((:type text :delta ,word) (:type done :stop-reason end-turn))))
          (harness-todo-sync-test-step sid)
          (let ((outcome (harness-test-await (harness-call 'todo-sync/run sid))))
            (should (eq (if (equal word "NONE") 'none 'unchanged) (plist-get outcome :status)))
            (should (equal list (harness-todo-sync-test-todos sid)))
            (should (= 0 (gethash sid harness-todo-sync--steps)))))))))

(ert-deftest harness-todo-sync-an-answer-that-reads-the-same-changes-nothing ()
  (harness-todo-sync-test-with
    (let ((sid (harness-todo-sync-test-session))
          (events nil))
      (harness-call 'session/set-todos sid '((:id "x" :text "Read the code" :status done)
                                             (:id "y" :text "Edit it" :status in-progress)
                                             (:id "z" :text "Run the tests" :status pending)))
      (harness-on 'session/todos (lambda (&rest args) (push args events)))
      (should (eq 'unchanged (plist-get (harness-test-await (harness-call 'todo-sync/run sid)) :status)))
      (should-not events)
      (should (equal '("x" "y" "z") (mapcar (lambda (todo) (plist-get todo :id))
                                            (harness-todo-sync-test-todos sid)))))))

(ert-deftest harness-todo-sync-replaces-a-list-when-the-work-changed-course ()
  (harness-todo-sync-test-with
    (let ((sid (harness-todo-sync-test-session))
          (harness-provider-demo-script-override
           '((:type text :delta "[x] Read the code\n[~] Port it to the new API\n[ ] Delete the old module")
             (:type done :stop-reason end-turn))))
      (harness-call 'session/set-todos sid '((:id "t1" :text "Read the code" :status done)
                                             (:id "t2" :text "Patch the old API" :status in-progress)))
      (harness-test-await (harness-call 'todo-sync/run sid))
      (should (equal '(("Read the code" . done) ("Port it to the new API" . in-progress)
                       ("Delete the old module" . pending))
                     (harness-todo-sync-test-summary (harness-todo-sync-test-todos sid))))
      ;; The words that stayed kept their id.
      (should (equal "t1" (plist-get (car (harness-todo-sync-test-todos sid)) :id))))))

(ert-deftest harness-todo-sync-drops-an-answer-the-model-wrote-over ()
  "A list the model wrote while the cheap model was asked wins."
  (harness-todo-sync-test-with
    (let* ((sid (harness-todo-sync-test-session))
           (promise (harness-call 'todo-sync/run sid)))
      (harness-call 'session/set-todos sid '((:id "m" :text "The model's own" :status pending)))
      (let ((outcome (harness-test-await promise)))
        (should (eq 'stale (plist-get outcome :status))))
      (should (equal '(("The model's own" . pending))
                     (harness-todo-sync-test-summary (harness-todo-sync-test-todos sid)))))))

(ert-deftest harness-todo-sync-a-deleted-session-is-left-alone ()
  (harness-todo-sync-test-with
    (let* ((sid (harness-todo-sync-test-session))
           (promise (harness-call 'todo-sync/run sid)))
      (harness-call 'session/delete sid)
      (should (eq 'gone (plist-get (harness-test-await promise) :status))))))

(ert-deftest harness-todo-sync-a-failure-says-so-and-backs-off ()
  (harness-todo-sync-test-with
    (let ((sid (harness-todo-sync-test-session))
          (failed nil)
          (harness-provider-demo-script-override '((:type done :stop-reason error :error "the model is down"))))
      (harness-on 'todo-sync/failed (lambda (id message) (push (list id message) failed)))
      (harness-todo-sync-test-requests requests
        (should-error (harness-test-await (harness-call 'todo-sync/run sid)))
        (should (equal (list (list sid "the model is down")) failed))
        (should-not (harness-todo-sync-test-todos sid))
        (should (zerop (hash-table-count harness-todo-sync--running)))
        ;; It is not asked again at once, for all the steps.
        (dotimes (_ 4) (harness-todo-sync-test-step sid))
        (harness-todo-sync-test-pause)
        (should (= 1 (length requests)))
        ;; Once the time is up, it is.
        (puthash sid (- (float-time) 1) harness-todo-sync--failed)
        (let ((harness-provider-demo-script-override harness-todo-sync-test-answer))
          (harness-todo-sync-test-step sid)
          (harness-test-wait (lambda () (harness-todo-sync-test-todos sid)) 5 "the list"))
        (should (= 2 (length requests)))))))

(ert-deftest harness-todo-sync-an-answer-with-no-list-is-a-failure ()
  (harness-todo-sync-test-with
    (let ((sid (harness-todo-sync-test-session))
          (harness-provider-demo-script-override
           '((:type text :delta "I could not tell what to do.") (:type done :stop-reason end-turn))))
      (should-error (harness-test-await (harness-call 'todo-sync/run sid)))
      (should (gethash sid harness-todo-sync--failed))
      (should-not (harness-todo-sync-test-todos sid)))))

(ert-deftest harness-todo-sync-a-request-that-never-answers-is-cancelled ()
  (harness-todo-sync-test-with
    (let ((sid (harness-todo-sync-test-session))
          (harness-todo-sync--timeout 0.1)
          (cancelled nil))
      (cl-letf (((symbol-function 'harness-method/provider/complete)
                 (lambda (_req) (list :cancel (lambda () (setq cancelled t))))))
        (should-error (harness-test-await (harness-call 'todo-sync/run sid) 3))
        (should cancelled)))))

;;;; The session's own agent

(ert-deftest harness-todo-sync-the-own-agent-is-asked-on-a-fork-of-its-conversation ()
  (harness-todo-sync-test-with
    (let ((harness-todo-sync-model nil)
          (sid (harness-todo-sync-test-session))
          (forked nil))
      (harness-call 'session/append sid '(:kind user :content "Make the widget faster"))
      (harness-todo-sync-test-step sid "Profiled it.")
      (harness-call 'session/set-provider-state sid '(:provider "demo" :marker "live"))
      (cl-letf (((symbol-function 'harness-method/provider/capabilities)
                 (lambda (_model) '(:fork t)))
                ((symbol-function 'harness-method/provider/fork)
                 (lambda (_model state &optional _checkpoint)
                   (push state forked)
                   (harness-resolved '(:provider "demo" :marker "fork")))))
        (harness-todo-sync-test-requests requests
          (should (eq 'updated (plist-get (harness-test-await (harness-call 'todo-sync/run sid)) :status)))
          (let ((req (car requests)))
            (should (equal '((:provider "demo" :marker "live")) forked))
            (should (equal '(:provider "demo" :marker "fork") (plist-get req :provider-state)))
            ;; The session's record, state and all, so the provider tells the fork from its own.
            (should (equal '(:provider "demo" :marker "live")
                           (plist-get (plist-get req :session) :provider-state)))
            (should (equal "demo:scripted" (plist-get req :model)))
            (should-not (plist-get req :tools))
            (should (equal "Todo sync" (plist-get req :job)))
            ;; The whole conversation, with the question at its end.
            (let* ((messages (plist-get req :messages))
                   (last (car (last messages)))
                   (blocks (plist-get last :content)))
              (should (eq 'user (plist-get last :role)))
              (should (string-match-p "Make the widget faster" (format "%S" messages)))
              (should (string-prefix-p "The todo list now:\n(empty)" (plist-get (car (last blocks)) :text)))
              (should (string-match-p "Stop the work for a moment" (plist-get (car (last blocks)) :text))))))))))

(ert-deftest harness-todo-sync-the-own-agent-of-an-api-provider-is-sent-the-conversation ()
  "No fork to be had, and no loop of the provider's to disturb: the transcript goes again."
  (harness-todo-sync-test-with
    (let ((harness-todo-sync-model nil)
          (sid (harness-todo-sync-test-session)))
      (harness-call 'session/append sid '(:kind user :content "Make the widget faster"))
      (harness-todo-sync-test-step sid)
      (cl-letf (((symbol-function 'harness-method/provider/capabilities) (lambda (_model) '(:vision t))))
        (harness-todo-sync-test-requests requests
          (should (eq 'updated (plist-get (harness-test-await (harness-call 'todo-sync/run sid)) :status)))
          (let ((req (car requests)))
            (should-not (plist-get req :provider-state))
            (should-not (plist-get req :ephemeral))
            (should (equal "demo:scripted" (plist-get req :model)))
            (should (string-match-p "Make the widget faster" (format "%S" (plist-get req :messages))))))))))

(ert-deftest harness-todo-sync-a-hosted-loop-without-a-fork-is-asked-as-a-dumb-agent-is ()
  "The process that runs the turn must never be written into by a side question."
  (harness-todo-sync-test-with
    (let ((harness-todo-sync-model nil)
          (sid (harness-todo-sync-test-session)))
      (harness-call 'session/append sid '(:kind user :content "Make the widget faster"))
      (harness-todo-sync-test-step sid)
      (cl-letf (((symbol-function 'harness-method/provider/capabilities)
                 (lambda (_model) '(:hosted-loop t :fork t)))
                ((symbol-function 'harness-method/provider/fork)
                 (lambda (&rest _) (harness-resolved nil))))
        (harness-todo-sync-test-requests requests
          (should (eq 'updated (plist-get (harness-test-await (harness-call 'todo-sync/run sid)) :status)))
          (let ((req (car requests)))
            (should (eq t (plist-get req :ephemeral)))
            (should-not (plist-get req :provider-state))
            (should-not (plist-member (plist-get req :session) :provider-state))
            (should (equal "demo:scripted" (plist-get req :model)))
            (should (= 1 (length (plist-get req :messages))))))))))

;;;; A session's own switch

(ert-deftest harness-todo-sync-a-session-can-turn-it-off-for-itself ()
  (harness-todo-sync-test-with
    (let ((sid (harness-todo-sync-test-session)))
      (let ((state (harness-call 'todo-sync/set sid "off")))
        (should (equal "off" (plist-get state :setting)))
        (should-not (plist-get state :every)))
      (should (eq :false (plist-get (plist-get (harness-call 'session/get sid) :ext) :todo-sync)))
      (harness-todo-sync-test-requests requests
        (dotimes (_ 5) (harness-todo-sync-test-step sid))
        (harness-todo-sync-test-pause)
        (should-not requests))
      ;; Back to what the option says.
      (let ((state (harness-call 'todo-sync/set sid nil)))
        (should (equal "default" (plist-get state :setting)))
        (should (= 3 (plist-get state :every))))
      (should-not (plist-member (plist-get (harness-call 'session/get sid) :ext) :todo-sync)))))

(ert-deftest harness-todo-sync-a-session-can-turn-it-on-for-itself ()
  (harness-todo-sync-test-with
    (let ((harness-todo-sync-steps nil)
          (on (harness-todo-sync-test-session))
          (other (harness-todo-sync-test-session)))
      (should (equal "on" (plist-get (harness-call 'todo-sync/set on t) :setting)))
      (should (= harness-todo-sync--default-steps (plist-get (harness-call 'todo-sync/state on) :every)))
      (should-not (plist-get (harness-call 'todo-sync/state other) :every))
      (harness-todo-sync-test-requests requests
        (dotimes (_ harness-todo-sync--default-steps)
          (harness-todo-sync-test-step other)
          (harness-todo-sync-test-step on))
        (harness-test-wait (lambda () (harness-todo-sync-test-todos on)) 5 "the list")
        (should (= 1 (length requests)))
        (should-not (harness-todo-sync-test-todos other))))))

(ert-deftest harness-todo-sync-the-switch-is-read-the-way-a-client-sends-it ()
  (should (eq t (harness-todo-sync--setting-value t)))
  (should (eq t (harness-todo-sync--setting-value "On")))
  (should (eq :false (harness-todo-sync--setting-value :false)))
  (should (eq :false (harness-todo-sync--setting-value "off")))
  (should-not (harness-todo-sync--setting-value nil))
  (should-not (harness-todo-sync--setting-value "default"))
  (should-error (harness-todo-sync--setting-value "maybe"))
  (should-error (harness-todo-sync--setting-value 3)))

(ert-deftest harness-todo-sync-state-says-how-a-session-stands ()
  (harness-todo-sync-test-with
    (let ((sid (harness-todo-sync-test-session)))
      (harness-todo-sync-test-step sid)
      (let ((state (harness-call 'todo-sync/state sid)))
        (should (equal "default" (plist-get state :setting)))
        (should (= 3 (plist-get state :every)))
        (should (= 1 (plist-get state :steps)))
        (should-not (plist-get state :running))
        (should (equal "demo:scripted" (plist-get state :model)))
        (should (eq :false (plist-get state :own))))
      (let ((harness-todo-sync-model nil))
        (should (eq t (plist-get (harness-call 'todo-sync/state sid) :own)))))))

;;;; Through a turn of the agent

(ert-deftest harness-todo-sync-keeps-a-list-through-a-real-turn ()
  "The agent runs tools without a word of a todo list; the list appears all the same."
  (harness-todo-sync-test-with
    (let* ((sid (harness-todo-sync-test-session))
           (dir (plist-get (harness-call 'session/get sid) :cwd))
           (harness-todo-sync-steps 2)
           (harness-provider-demo-script-override
            (lambda (request)
              (if (string-prefix-p "You keep the todo list" (or (plist-get request :system) ""))
                  (harness-provider-demo--todos request)
                `((:type text :delta "Looking around.\n")
                  (:type tool-call :id "c1" :name "list_dir" :input (:path ,dir))
                  (:type text :delta "Found it.")
                  (:type tool-call :id "c2" :name "list_dir" :input (:path ,dir))
                  (:type text :delta "That is that.")
                  (:type done :stop-reason end-turn))))))
      (harness-test-await (harness-call 'agent/prompt sid '((:type "text" :text "Tidy up the widget"))) 20)
      (harness-test-wait (lambda () (harness-todo-sync-test-todos sid)) 10 "the list")
      (should (equal '(("Survey the project" . done) ("Tidy up the widget" . in-progress)
                       ("Check the result" . pending))
                     (harness-todo-sync-test-summary (harness-todo-sync-test-todos sid)))))))

(provide 'harness-todo-sync-test)
;;; harness-todo-sync-test.el ends here
