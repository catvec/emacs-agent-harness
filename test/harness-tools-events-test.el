;;; harness-tools-events-test.el --- watch_events: harness events, a cheap model deciding  -*- lexical-binding: t; -*-

;;; Commentary:

;; watch_events puts the harness events a session watches to a
;; classifier, a cheap model, and brings its decisions to the session.
;; The classifier here is a stub provider, `classifier', whose cheap
;; tier is classifier:small: it answers each one-off question (an
;; ephemeral request) as the test says, and each turn of a session (a
;; woken session's) with a word.  The events are emitted on the bus as
;; the harness emits them.

;;; Code:

(require 'harness-test-helpers)

(defvar harness-providers)
(defvar harness-sessions)
(defvar harness-agent--turns)
(defvar harness-tools-agent--questions)
(defvar harness-tasks--table)
(defvar harness-tasks--starting)
(defvar harness-tasks--loaded)
(defvar harness-tasks-require-verification)
(defvar harness-naming-auto)
(defvar harness-tools-sessions--waiters)
(defvar harness-tools-events--watches)
(defvar harness-tools-events--outbox)
(defvar harness-tools-events--roots)
(defvar harness-tools-events--batch-delay)
(defvar harness-tools-events--rate-window)
(defvar harness-tools-events--queue-max)
(defvar harness-tools-events--classifier-timeout)
(defvar harness-tools-events-max-calls-per-minute)
(defvar harness-tools-events--classifier-system)
(defvar harness-tools-events-kinds)
(declare-function harness-define-provider "harness-provider")
(declare-function harness-provider--forget "harness-provider")
(declare-function harness-tools-events--watch-timer "harness-tools-events")
(declare-function harness-tools-events--watch-pump "harness-tools-events")
(declare-function harness-tools-events--watch-classified "harness-tools-events")
(declare-function harness-tools-events--watch-decisions "harness-tools-events")
(declare-function harness-tools-events--watch-dropped-total "harness-tools-events")
(declare-function harness-tools-events--watch-coalesced-total "harness-tools-events")
(declare-function harness-tools-events--watch-seen "harness-tools-events")
(declare-function harness-tools-events--parse-decision "harness-tools-events" (text choices))
(declare-function harness-tools-events--record "harness-tools-events" (kind time args))
(declare-function harness-tools-events--event-text "harness-tools-events" (record))
(declare-function harness-tools-events--flush "harness-tools-events" (session-id))
(declare-function harness-tools-events--outstanding "harness-tools-events" (value session-id))

;;;; The classifier, a stub

(defvar harness-tools-events-test--answer nil
  "How the stub answers a classifier's question.
A function of the request returning the reply's text, or nil for no
reply at all.")

(defvar harness-tools-events-test--questions nil
  "The classifier's questions the stub got, newest first, as (TIME . REQUEST).")

(defun harness-tools-events-test--answers (&rest texts)
  "Have the classifier answer TEXTS, one per question, in order; then nothing.
A text that is nil gets no reply."
  (setq harness-tools-events-test--answer (lambda (_request) (pop texts))))

(defun harness-tools-events-test--always (text)
  "Have the classifier answer every question with TEXT."
  (setq harness-tools-events-test--answer (lambda (_request) text)))

(defun harness-tools-events-test--decide (action &optional note)
  "Return a classifier's reply deciding ACTION, with NOTE."
  (format "{\"action\":\"%s\",\"note\":\"%s\"}" action (or note "It happened.")))

(defun harness-tools-events-test--define-classifier ()
  "Define the provider `classifier', whose cheap tier is classifier:small.
A question (an ephemeral request) gets what
`harness-tools-events-test--answer' says, a session's turn \"Noted.\";
each from a timer, as a provider's events come."
  (harness-define-provider 'classifier
    :label "Classifier"
    :models (lambda () (harness-resolved (list (list :name "big" :pricing '(:input 10.0 :output 50.0))
                                               (list :name "small" :pricing '(:input 1.0 :output 5.0)))))
    :tiers '(:cheap "small")
    :complete (lambda (req)
                (let* ((on-event (plist-get req :on-event))
                       (done nil)
                       (text (if (plist-get req :ephemeral)
                                 (progn (push (cons (float-time) req) harness-tools-events-test--questions)
                                        (funcall harness-tools-events-test--answer req))
                               "Noted.")))
                  (when text
                    (run-at-time 0.01 nil
                                 (lambda ()
                                   (unless done
                                     (setq done t)
                                     (funcall on-event '(:type start))
                                     (funcall on-event (list :type 'text :delta text))
                                     (funcall on-event '(:type done :stop-reason end-turn))))))
                  (list :cancel (lambda ()
                                  (unless done
                                    (setq done t)
                                    (funcall on-event '(:type done :stop-reason cancelled)))))))))

(defun harness-tools-events-test--question (request)
  "Return the text of REQUEST, a classifier's question."
  (plist-get (car (plist-get (car (plist-get request :messages)) :content)) :text))

(defun harness-tools-events-test--asked ()
  "Return the texts of the classifier's questions, oldest first."
  (mapcar (lambda (q) (harness-tools-events-test--question (cdr q)))
          (reverse harness-tools-events-test--questions)))

;;;; Setting up

(defun harness-tools-events-test--forget-watches ()
  "Forget every event watch and what waits to wake a session, timers too."
  (maphash (lambda (_ w)
             (dolist (timer (list (harness-tools-events--watch-timer w) (harness-tools-events--watch-pump w)))
               (when (timerp timer) (cancel-timer timer))))
           harness-tools-events--watches)
  (clrhash harness-tools-events--watches)
  (maphash (lambda (_ entry) (when (timerp (car entry)) (cancel-timer (car entry))))
           harness-tools-events--outbox)
  (clrhash harness-tools-events--outbox)
  (clrhash harness-tools-events--roots))

(defmacro harness-tools-events-test-with (&rest body)
  "Load the state layer, tasks and the event tools with the stub classifier; run BODY.
Every call is allowed, the classifier decides wake, and a decision
wakes its session within 0.05s."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider tools session agent tools-agent priority tasks
                  tools-sessions tools-events))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-agent--turns)
     (clrhash harness-tools-agent--questions)
     (clrhash harness-tasks--table)
     (clrhash harness-tasks--starting)
     (clrhash harness-tools-sessions--waiters)
     (harness-tools-events-test--forget-watches)
     (setq harness-tasks--loaded t
           harness-tools-events-test--questions nil)
     (harness-tools-events-test--always (harness-tools-events-test--decide "wake"))
     (harness-tools-events-test--define-classifier)
     (let ((harness-naming-auto nil)
           (harness-tools-events--batch-delay 0.05)
           (harness-tools-events--rate-window 60)
           (harness-tools-events--queue-max 20)
           (harness-tools-events--classifier-timeout 5)
           (harness-tools-events-max-calls-per-minute 12)
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       (unwind-protect (progn ,@body)
         (harness-tools-events-test--forget-watches)
         (remhash 'classifier harness-providers)
         (harness-provider--forget 'classifier)))))

(defun harness-tools-events-test--session (&rest plist)
  "Create a session on classifier:big in the state directory; return its id.
PLIST is passed on to `session/create'."
  (plist-get (apply #'harness-call 'session/create :cwd default-directory :model "classifier:big" plist) :id))

(defun harness-tools-events-test--call (sid name input)
  "Call tool NAME with INPUT as session SID; return the promise of its result."
  (harness-call 'tools/execute sid (list :id (harness-short-id) :name name :input input)))

(defun harness-tools-events-test--run (sid name input)
  "Run tool NAME with INPUT as session SID; return the result plist."
  (harness-test-await (harness-tools-events-test--call sid name input) 10))

(defun harness-tools-events-test--ok (sid name input)
  "Run tool NAME as SID, assert it succeeded and return its text."
  (let ((r (harness-tools-events-test--run sid name input)))
    (should-not (plist-get r :is-error))
    (plist-get r :content)))

(defun harness-tools-events-test--watch (sid &rest input)
  "Register an event watch for SID with INPUT; return its id."
  (let ((text (harness-tools-events-test--ok sid "watch_events" input)))
    (should (string-match "watch \\(w-[a-z0-9]+\\)" text))
    (match-string 1 text)))

(defun harness-tools-events-test--wakes (sid)
  "Return the messages event watches sent SID, oldest first."
  (cl-remove-if-not
   (lambda (node)
     (and (eq (plist-get node :kind) 'user)
          (equal '(:kind system :source "event watch") (harness-node-sender node))))
   (harness-call 'session/nodes sid)))

(defun harness-tools-events-test--wake-texts (sid)
  "Return the texts of the messages event watches sent SID, oldest first."
  (mapcar (lambda (node) (plist-get node :content)) (harness-tools-events-test--wakes sid)))

(defun harness-tools-events-test--json (text)
  "Return the first line of TEXT, parsed as JSON."
  (harness-json-parse (car (split-string text "\n"))))

(defun harness-tools-events-test--settle (&optional seconds)
  "Let the timers run for SECONDS (default 0.2): what is to happen, happens."
  (let ((end (+ (float-time) (or seconds 0.2))))
    (while (< (float-time) end)
      (accept-process-output nil 0.02))))

(defun harness-tools-events-test--live ()
  "Return the watches that live."
  (let (out)
    (maphash (lambda (_ w) (push w out)) harness-tools-events--watches)
    out))

(defun harness-tools-events-test--send-now (sid)
  "Send what waits in the outbox to wake SID now, as its timer would.
A test that looks at a message on its way gives it a long delay and
sends it with this: on a slow machine a timer of a few tenths of a
second could fire before the test had looked."
  (let ((entry (gethash sid harness-tools-events--outbox)))
    (should entry)
    (when (timerp (car entry)) (cancel-timer (car entry)))
    (harness-tools-events--flush sid)))

;;;; Registering

(ert-deftest harness-tools-events-registers-read-tools ()
  "Both tools are of kind read, and the kinds they name are the table's."
  (harness-tools-events-test-with
    (dolist (name '("watch_events" "unwatch_events"))
      (should (eq 'read (plist-get (harness-call 'tools/get name) :kind))))
    (let* ((spec (harness-call 'tools/get "watch_events"))
           (events (plist-get (plist-get (plist-get spec :schema) :properties) :events)))
      (should (equal (mapcar #'car harness-tools-events-kinds)
                     (append (plist-get (plist-get events :items) :enum) nil)))
      (should (equal '("events" "prompt") (append (plist-get (plist-get spec :schema) :required) nil)))
      (dolist (kind (mapcar #'car harness-tools-events-kinds))
        (should (string-match-p (regexp-quote kind) (plist-get spec :description)))))))

(ert-deftest harness-tools-events-refuses-a-watch-it-cannot-keep ()
  "A watch needs known kinds, a prompt, short lowercase actions, and room."
  (harness-tools-events-test-with
    (let ((me (harness-tools-events-test--session)))
      (cl-flet ((refused (input pattern)
                  (let ((r (harness-tools-events-test--run me "watch_events" input)))
                    (should (plist-get r :is-error))
                    (should (string-match-p pattern (plist-get r :content))))))
        (refused '(:events ("session/exploded") :prompt "x") "No kind of event session/exploded; the kinds are session/status")
        (refused '(:events () :prompt "x") "needs events")
        (refused '(:events ("task/done") :prompt "  ") "needs a prompt")
        (refused '(:events ("task/done") :prompt "x" :actions ("Wake Up")) "not a short lowercase word")
        (refused '(:events ("task/done") :prompt "x" :actions ("ignore")) "at least one action besides ignore")
        (refused '(:events ("task/done") :prompt "x" :session_id "nobody-here") "No session matches")
        (dotimes (_ 10)
          (harness-tools-events-test--watch me :events '("task/done") :prompt "x"))
        (refused '(:events ("task/done") :prompt "x") "has 10 event watches already"))
      (should (= 10 (hash-table-count harness-tools-events--watches))))))

;;;; Records

(ert-deftest harness-tools-events-reads-every-kind-of-event ()
  "Each kind of event becomes a record of the sessions and task it is
about, a one-line summary and a few small details, which encode as the
classifier reads them."
  (harness-tools-events-test-with
    (let* ((parent (harness-tools-events-test--session :name "Parent"))
           (child (harness-tools-events-test--session :name "Child"))
           (task (harness-call 'task/adopt child))
           (tid (plist-get task :id))
           (long (mapconcat (lambda (i) (format "line %d %s" i (make-string 200 ?x))) (number-sequence 1 50) "\n"))
           (records
            (list
             (list "session/status" parent 'blocked)
             (list "agent/turn-ended" parent 'error)
             (list "question/asked" child (list :id "q1" :kind 'question
                                                :payload (list :question "Which way?" :options '("Left" "Right"))))
             (list "permission/requested" child (list :id "p1" :kind 'permission
                                                      :payload (list :tool "bash" :input '(:command "rm -rf build")
                                                                     :kind 'exec)))
             (list "tools/finished" child '(:id "c1" :name "bash" :input (:command "make"))
                   (list :content long :is-error nil))
             (list "agent/spawned" parent child)
             (list "task/changed" task)
             (list "task/review" task)
             (list "task/done" task 'merged)
             (list "merge/conflict" child parent '("a.el" "b.el"))
             (list "merge/finished" child default-directory 'merged))))
      (dolist (spec records)
        (ert-info ((car spec))
          (let* ((record (harness-tools-events--record (car spec) (float-time) (cdr spec)))
                 (summary (plist-get record :summary)))
            (should (string-prefix-p "e-" (plist-get record :id)))
            (should (equal (car spec) (plist-get record :kind)))
            (should (stringp summary))
            (should-not (string-match-p "\n" summary))
            (should (plist-get record :project))
            ;; It encodes, short, as the classifier reads it.
            (should (< (length (harness-tools-events--event-text record)) 2000))
            (pcase (car spec)
              ("session/status" (should (string-match-p "\"Parent\" is now blocked, waiting on the user" summary)))
              ("agent/turn-ended" (should (string-match-p "ended its turn (error)" summary)))
              ("question/asked"
               (should (string-match-p "\"Child\" asks the user: Which way\\?" summary))
               (should (equal tid (plist-get record :task)))
               (should (equal '("Left" "Right") (plist-get (plist-get record :details) :options))))
              ("permission/requested" (should (string-match-p "asks the user for permission: bash: rm -rf build" summary)))
              ("tools/finished"
               (should (string-match-p "bash: make finished\\." summary))
               (should (equal "c1" (plist-get record :call)))
               (should (<= (length (plist-get (plist-get record :details) :result)) 300)))
              ("agent/spawned"
               (should (equal parent (plist-get record :session)))
               (should (equal (list parent child) (plist-get record :sessions)))
               (should (string-match-p "started sub-agent session [^ ]+ \"Child\"" summary)))
              ((or "task/changed" "task/review" "task/done")
               (should (equal tid (plist-get record :task)))
               (should (equal child (plist-get record :session)))
               (should (string-match-p (format "\\`Task %s \"Child\"" (regexp-quote tid)) summary))
               (when (equal (car spec) "task/done") (should (string-match-p "is done (merged)" summary))))
              ("merge/conflict"
               (should (equal (list child parent) (plist-get record :sessions)))
               (should (string-match-p "conflicts in 2 files: a.el, b.el" summary)))
              ("merge/finished"
               (should (equal (list child) (plist-get record :sessions)))
               (should (string-match-p "finished: merged" summary))))))))))

;;;; Deciding

(ert-deftest harness-tools-events-a-decision-wakes-the-session ()
  "A matching event goes to the classifier, and its decision wakes the
session with a message whose first line is the decision as JSON.  The
classifier is asked as a judge is: once, ephemeral, on the cheap tier of
the session's model, without tools or thinking, with the prompt and the
event fenced by a tag of the question's own.  A watch for one decision
ends with it."
  (harness-tools-events-test-with
    (let* ((me (harness-tools-events-test--session :name "Boss"))
           (worker (harness-tools-events-test--session :name "Worker"))
           (id (harness-tools-events-test--watch me :events '("session/status")
                                                 :prompt "Wake me when the worker waits on the user.")))
      (should (string-prefix-p "w-" id))
      (should (= 1 (hash-table-count harness-tools-events--watches)))
      (harness-emit 'session/status worker 'blocked)
      (harness-test-wait (lambda () (harness-tools-events-test--wakes me)) 5 "the wake-up")
      (let* ((text (car (harness-tools-events-test--wake-texts me)))
             (decision (harness-tools-events-test--json text)))
        (should (equal id (plist-get decision :watch)))
        (should (equal "wake" (plist-get decision :action)))
        (should (equal "It happened." (plist-get decision :note)))
        (should (equal "session/status" (plist-get decision :kind)))
        (should (equal worker (plist-get decision :session)))
        (should (string-match-p "\\`e-[a-z0-9]\\{8\\}\\'" (plist-get decision :event)))
        (should (string-match-p "\\`[0-9]\\{4\\}-[0-9][0-9]-[0-9][0-9]T" (plist-get decision :time)))
        (should (string-match-p "Session [^ ]+ \"Worker\" is now blocked, waiting on the user\\." text))
        (should (string-match-p "has ended: it was for one decision" text)))
      ;; One decision, and the watch is over.
      (should (zerop (hash-table-count harness-tools-events--watches)))
      (should-not (harness-call 'agent/outstanding me))
      (should (= 1 (length harness-tools-events-test--questions)))
      (let* ((request (cdar harness-tools-events-test--questions))
             (question (harness-tools-events-test--question request)))
        (should (plist-get request :ephemeral))
        (should (plist-get request :no-thinking))
        (should-not (plist-get request :tools))
        (should (equal "classifier:small" (plist-get request :model)))
        (should (equal (concat me "-events") (plist-get (plist-get request :session) :id)))
        (should (equal harness-tools-events--classifier-system (plist-get request :system)))
        (should (string-match "<instructions-\\([a-z0-9]+\\)>\nWake me when the worker waits on the user.\n</instructions-\\([a-z0-9]+\\)>"
                              question))
        (let ((tag (match-string 1 question)))
          (should (equal tag (match-string 2 question)))
          (should (string-match-p (format "<event-%s>\n{.*\"kind\":\"session/status\".*}\n</event-%s>" tag tag)
                                  question)))
        (should (string-match-p (regexp-quote worker) question))
        (should (string-match-p "blocked" question))
        (should (string-match-p "The actions: wake, ignore\\." question))))))

(ert-deftest harness-tools-events-ignore-leaves-the-watch-watching ()
  "An event the classifier ignores wakes nobody, and the watch goes on;
the next one it decides on wakes the session, and a watch that is not
for one decision goes on after that too."
  (harness-tools-events-test-with
    (let* ((me (harness-tools-events-test--session))
           (worker (harness-tools-events-test--session))
           (id (harness-tools-events-test--watch me :events '("agent/turn-ended") :prompt "Tell me about errors."
                                                 :actions '("retry" "wake") :once :false)))
      (harness-tools-events-test--answers (harness-tools-events-test--decide "ignore" "A clean end.")
                                          (harness-tools-events-test--decide "retry" "It failed."))
      (harness-emit 'agent/turn-ended worker 'end-turn)
      (harness-test-wait (lambda () (cl-some (lambda (w) (= 1 (harness-tools-events--watch-classified w)))
                                             (harness-tools-events-test--live)))
                         5 "the first decision")
      (harness-tools-events-test--settle)
      (should-not (harness-tools-events-test--wakes me))
      (should (= 1 (hash-table-count harness-tools-events--watches)))
      (harness-emit 'agent/turn-ended worker 'error)
      (harness-test-wait (lambda () (harness-tools-events-test--wakes me)) 5 "the wake-up")
      (let* ((text (car (harness-tools-events-test--wake-texts me)))
             (decision (harness-tools-events-test--json text)))
        (should (equal "retry" (plist-get decision :action)))
        (should (equal "agent/turn-ended" (plist-get decision :kind)))
        (should (string-match-p "ended its turn (error)" text))
        (should (string-match-p "The watch goes on; end it with unwatch_events" text)))
      (let ((w (gethash id harness-tools-events--watches)))
        (should w)
        (should (= 2 (harness-tools-events--watch-classified w)))
        (should (= 1 (harness-tools-events--watch-decisions w))))
      (should (string-match-p "The actions: retry, wake, ignore\\."
                              (car (last (harness-tools-events-test--asked))))))))

(ert-deftest harness-tools-events-parses-only-a-decision-it-allows ()
  "The first JSON object that names an action decides; an action the
watch did not name, or none, is no decision."
  (harness-tools-events-test-with
    (should (equal '(:action "wake" :note "Done.")
                   (harness-tools-events--parse-decision
                    "Sure.\n{\"action\":\"Wake \",\"note\":\" Done. \"}" '("wake" "ignore"))))
    (should (equal '(:action "ignore" :note nil)
                   (harness-tools-events--parse-decision "{\"action\":\"ignore\"}" '("wake" "ignore"))))
    (should-not (harness-tools-events--parse-decision "{\"action\":\"merge\"}" '("wake" "ignore")))
    (should-not (harness-tools-events--parse-decision "{\"verdict\":\"wake\"}" '("wake" "ignore")))
    (should-not (harness-tools-events--parse-decision "wake" '("wake" "ignore")))
    ;; Braces in the note: read from the first brace to the last.
    (should (equal '(:action "wake" :note "a {b} c")
                   (harness-tools-events--parse-decision "{\"action\":\"wake\",\"note\":\"a {b} c\"}"
                                                         '("wake" "ignore"))))))

;;;; Matching

(ert-deftest harness-tools-events-other-kinds-and-sessions-never-reach-it ()
  "A watch that names a session is shown events of its kinds about that
session, and nothing else."
  (harness-tools-events-test-with
    (harness-tools-events-test--always (harness-tools-events-test--decide "ignore"))
    (let* ((me (harness-tools-events-test--session))
           (worker (harness-tools-events-test--session))
           (bystander (harness-tools-events-test--session)))
      (harness-tools-events-test--watch me :events '("session/status") :prompt "x" :session_id worker)
      (harness-emit 'agent/turn-ended worker 'end-turn)
      (harness-emit 'session/status bystander 'blocked)
      (harness-emit 'session/status worker 'idle)
      (harness-test-wait (lambda () harness-tools-events-test--questions) 5 "the question")
      (harness-tools-events-test--settle)
      (let ((asked (harness-tools-events-test--asked)))
        (should (= 1 (length asked)))
        (should (string-match-p (regexp-quote worker) (car asked)))
        (should-not (string-match-p (regexp-quote bystander) (car asked)))))))

(ert-deftest harness-tools-events-a-task-watch-sees-the-task-and-its-session ()
  "A watch that names a task is shown the task's events and its
session's, and not another task's."
  (harness-tools-events-test-with
    (harness-tools-events-test--always (harness-tools-events-test--decide "ignore"))
    (let* ((me (harness-tools-events-test--session))
           (worker (harness-tools-events-test--session :name "Worker"))
           (other (harness-tools-events-test--session :name "Other"))
           (task (harness-call 'task/adopt worker))
           (other-task (harness-call 'task/adopt other)))
      ;; Whatever adopting them sets off happens before the watch.
      (harness-tools-events-test--settle)
      (harness-tools-events-test--watch me :events '("task/changed" "session/status") :prompt "x"
                                        :task_id (substring (plist-get task :id) 0 6))
      (harness-emit 'task/changed other-task)
      (harness-emit 'session/status other 'blocked)
      (harness-emit 'session/status worker 'blocked)
      (harness-emit 'task/changed task)
      (harness-test-wait (lambda () (= 2 (length harness-tools-events-test--questions))) 5 "the questions")
      (harness-tools-events-test--settle)
      (let ((asked (harness-tools-events-test--asked)))
        (should (= 2 (length asked)))
        (should (string-match-p "\"kind\":\"session/status\"" (nth 0 asked)))
        (should (string-match-p (regexp-quote (plist-get task :id)) (nth 0 asked)))
        (should (string-match-p "\"kind\":\"task/changed\"" (nth 1 asked)))
        (should (string-match-p "Worker" (nth 1 asked)))
        (dolist (text asked)
          (should-not (string-match-p (regexp-quote (plist-get other-task :id)) text)))))))

(ert-deftest harness-tools-events-a-watch-keeps-to-its-project ()
  "A watch takes the events of its session's project, unless it watches
every project."
  (harness-tools-events-test-with
    (harness-tools-events-test--always (harness-tools-events-test--decide "ignore"))
    (let* ((me (harness-tools-events-test--session))
           (neighbour (harness-tools-events-test--session))
           (elsewhere (let ((default-directory (harness-test-temp-dir)))
                        (harness-tools-events-test--session))))
      (harness-tools-events-test--watch me :events '("session/status") :prompt "here")
      (harness-tools-events-test--watch me :events '("session/status") :prompt "anywhere" :all_projects t)
      (harness-emit 'session/status elsewhere 'blocked)
      (harness-emit 'session/status neighbour 'blocked)
      (harness-test-wait (lambda () (= 3 (length harness-tools-events-test--questions))) 5 "the questions")
      (harness-tools-events-test--settle)
      (let ((asked (harness-tools-events-test--asked)))
        (should (= 3 (length asked)))
        ;; The project's watch saw only the neighbour.
        (let ((here (cl-remove-if-not (lambda (q) (string-match-p "\nhere\n" q)) asked)))
          (should (= 1 (length here)))
          (should (string-match-p (regexp-quote neighbour) (car here))))
        (should (= 2 (cl-count-if (lambda (q) (string-match-p "\nanywhere\n" q)) asked)))))))

(ert-deftest harness-tools-events-skips-its-own-sessions-events ()
  "A watch is not shown its own session's events, unless it names that
session itself."
  (harness-tools-events-test-with
    (harness-tools-events-test--always (harness-tools-events-test--decide "ignore"))
    (let* ((me (harness-tools-events-test--session))
           (worker (harness-tools-events-test--session)))
      (harness-tools-events-test--watch me :events '("session/status" "tools/finished") :prompt "others")
      (harness-emit 'session/status me 'blocked)
      (harness-emit 'tools/finished me '(:id "c1" :name "read_file" :input (:path "x.el")) '(:content "x" :is-error nil))
      (harness-emit 'session/status worker 'blocked)
      (harness-test-wait (lambda () harness-tools-events-test--questions) 5 "the question")
      (harness-tools-events-test--settle)
      (should (= 1 (length harness-tools-events-test--questions)))
      (should-not (string-match-p (regexp-quote me) (car (harness-tools-events-test--asked))))
      ;; Named: its own events are what it watches.
      (harness-tools-events-test--watch me :events '("tools/finished") :prompt "mine" :session_id me)
      (harness-emit 'tools/finished me '(:id "c2" :name "bash" :input (:command "make")) '(:content "error: no rule\nmore\nmore\nand more" :is-error t))
      (harness-test-wait (lambda () (= 2 (length harness-tools-events-test--questions))) 5 "the second question")
      (let ((question (car (last (harness-tools-events-test--asked)))))
        (should (string-match-p "\nmine\n" question))
        (should (string-match-p (regexp-quote me) question))
        (should (string-match-p "\"error\":true" question))
        (should (string-match-p "error: no rule" question))
        (should-not (string-match-p "and more" question))))))

;;;; Waiting

(ert-deftest harness-tools-events-wait-returns-the-decision ()
  "With wait, the call returns the first decision, with the decision as
its `:meta'; the watch ends with it, and no message is sent."
  (harness-tools-events-test-with
    (let* ((me (harness-tools-events-test--session))
           (worker (harness-tools-events-test--session))
           (promise (harness-tools-events-test--call
                     me "watch_events" (list :events '("merge/finished") :prompt "Tell me when it merged."
                                             :session_id worker :wait t :timeout_seconds 5))))
      (harness-test-wait (lambda () (= 1 (hash-table-count harness-tools-events--watches))) 5 "the watch")
      ;; Waiting in the call is not something left to do after the turn.
      (should-not (harness-call 'agent/outstanding me))
      (harness-emit 'merge/finished worker default-directory 'merged)
      (let* ((result (harness-test-await promise 5))
             (meta (plist-get result :meta)))
        (should-not (plist-get result :is-error))
        (should (equal "wake" (plist-get meta :action)))
        (should (equal "merge/finished" (plist-get meta :kind)))
        (should (equal worker (plist-get meta :session)))
        (should (equal meta (harness-tools-events-test--json (plist-get result :content))))
        (should (string-match-p "finished: merged" (plist-get result :content)))
        (should (string-match-p "The watch has ended\\." (plist-get result :content))))
      (should (zerop (hash-table-count harness-tools-events--watches)))
      (harness-tools-events-test--settle)
      (should-not (harness-tools-events-test--wakes me)))))

(ert-deftest harness-tools-events-wait-times-out ()
  "With wait, a call that sees no decision in time says so, and ends."
  (harness-tools-events-test-with
    (harness-tools-events-test--always (harness-tools-events-test--decide "ignore"))
    (let* ((me (harness-tools-events-test--session))
           (worker (harness-tools-events-test--session))
           (promise (harness-tools-events-test--call
                     me "watch_events" (list :events '("session/status") :prompt "x"
                                             :wait t :timeout_seconds 1))))
      (harness-emit 'session/status worker 'idle)
      (let ((result (harness-test-await promise 5)))
        (should-not (plist-get result :is-error))
        (should (equal "timeout" (plist-get (plist-get result :meta) :ended)))
        (should (string-match-p "No decision within 1s from event watch w-" (plist-get result :content)))
        (should (string-match-p "1 event seen, 1 classified, 0 decisions (1 ignored)" (plist-get result :content))))
      (should (zerop (hash-table-count harness-tools-events--watches))))))

(ert-deftest harness-tools-events-registration-times-out-with-a-wake ()
  "A registration with a timeout ends then, and wakes its session to say so."
  (harness-tools-events-test-with
    (let ((me (harness-tools-events-test--session)))
      (let ((text (harness-tools-events-test--ok me "watch_events" '(:events ("task/done") :prompt "x"
                                                                    :timeout_seconds 0.2))))
        (should (string-match-p "It ends after 0.2s" text))
        (should (string-match-p "do not poll" text)))
      (harness-test-wait (lambda () (harness-tools-events-test--wakes me)) 5 "the timeout")
      (let ((text (car (harness-tools-events-test--wake-texts me))))
        (should (equal "timeout" (plist-get (harness-tools-events-test--json text) :ended)))
        (should (string-match-p "ended after 0.2s without a decision" text)))
      (should (zerop (hash-table-count harness-tools-events--watches))))))

;;;; Floods

(ert-deftest harness-tools-events-a-flood-is-bounded ()
  "A watch asks one question at a time and no more than its rate allows;
its queue keeps the newest events, a newer event about the same session
replaces an older one, and its next decision counts both."
  (harness-tools-events-test-with
    (let* ((harness-tools-events-max-calls-per-minute 2)
           (harness-tools-events--queue-max 3)
           (harness-tools-events--rate-window 1.0)
           (me (harness-tools-events-test--session))
           (others (cl-loop repeat 9 collect (harness-tools-events-test--session)))
           (id (harness-tools-events-test--watch me :events '("session/status") :prompt "x" :once :false)))
      ;; Nine sessions, and the last one twice: ten events at once.
      (dolist (sid others) (harness-emit 'session/status sid 'idle))
      (harness-emit 'session/status (car (last others)) 'blocked)
      (harness-test-wait (lambda () (= 2 (length harness-tools-events-test--questions))) 5 "two questions")
      ;; No more within the window.
      (harness-tools-events-test--settle 0.5)
      (should (= 2 (length harness-tools-events-test--questions)))
      (harness-test-wait (lambda () (= 4 (length harness-tools-events-test--questions))) 5 "four questions")
      (harness-tools-events-test--settle 0.3)
      (let* ((times (reverse (mapcar #'car harness-tools-events-test--questions)))
             (asked (harness-tools-events-test--asked))
             (w (gethash id harness-tools-events--watches)))
        (should (= 4 (length times)))
        (should (>= (- (nth 2 times) (nth 0 times)) 0.9))
        ;; The first, then the three newest; the last session's newer event.
        (should (string-match-p (regexp-quote (nth 0 others)) (nth 0 asked)))
        (should (string-match-p (regexp-quote (nth 6 others)) (nth 1 asked)))
        (should (string-match-p (regexp-quote (nth 7 others)) (nth 2 asked)))
        (should (string-match-p (regexp-quote (nth 8 others)) (nth 3 asked)))
        (should (string-match-p "blocked" (nth 3 asked)))
        (should (= 10 (harness-tools-events--watch-seen w)))
        (should (= 5 (harness-tools-events--watch-dropped-total w)))
        (should (= 1 (harness-tools-events--watch-coalesced-total w)))
        (should (= 4 (harness-tools-events--watch-decisions w))))
      (harness-test-wait (lambda () (= 4 (cl-count-if (lambda (text) (string-match-p "\"action\":\"wake\"" text))
                                                      (mapcan (lambda (text) (split-string text "\n\n"))
                                                              (harness-tools-events-test--wake-texts me)))))
                         5 "four decisions")
      (let ((texts (string-join (harness-tools-events-test--wake-texts me) "\n")))
        (should (= 1 (cl-count-if (lambda (line) (string-match-p "^Meanwhile" line)) (split-string texts "\n"))))
        (should (string-match-p "Meanwhile 5 events were dropped, the oldest of a full queue, and 1 event was replaced by a newer one about the same session or task\\." texts))))))

(ert-deftest harness-tools-events-three-failures-end-the-watch ()
  "A question that gets no decision skips its event; three in a row end
the watch, and its session is told why."
  (harness-tools-events-test-with
    (let* ((harness-tools-events--classifier-timeout 0.3)
           (me (harness-tools-events-test--session))
           (others (cl-loop repeat 3 collect (harness-tools-events-test--session))))
      (harness-tools-events-test--answers "I cannot say."
                                          (harness-tools-events-test--decide "merge")
                                          nil)
      (harness-tools-events-test--watch me :events '("session/status") :prompt "x" :once :false)
      (dolist (sid others) (harness-emit 'session/status sid 'idle))
      (harness-test-wait (lambda () (harness-tools-events-test--wakes me)) 5 "the failure")
      (let ((text (car (harness-tools-events-test--wake-texts me))))
        (should (equal "failed" (plist-get (harness-tools-events-test--json text) :ended)))
        (should (string-match-p "gave no decision 3 times in a row" text))
        (should (string-match-p "took longer than 0.3s" text)))
      (should (= 3 (length harness-tools-events-test--questions)))
      (should (zerop (hash-table-count harness-tools-events--watches))))))

;;;; Ending

(ert-deftest harness-tools-events-unwatch-stops-a-watch ()
  "unwatch_events ends the watch it names, or every one, and says what
each saw; it ends only the calling session's."
  (harness-tools-events-test-with
    (harness-tools-events-test--always (harness-tools-events-test--decide "ignore"))
    (let* ((me (harness-tools-events-test--session))
           (worker (harness-tools-events-test--session))
           (id (harness-tools-events-test--watch me :events '("session/status") :prompt "x" :once :false))
           (theirs (harness-tools-events-test--watch worker :events '("task/done") :prompt "y")))
      (harness-emit 'session/status worker 'idle)
      (harness-test-wait (lambda () harness-tools-events-test--questions) 5 "the question")
      (harness-tools-events-test--settle)
      (let ((r (harness-tools-events-test--run me "unwatch_events" (list :watch_id theirs))))
        (should (plist-get r :is-error))
        (should (string-match-p (regexp-quote id) (plist-get r :content))))
      (should (string-match-p
               (format "Stopped event watch %s (session/status): 1 event seen, 1 classified, 0 decisions (1 ignored)"
                       (regexp-quote id))
               (harness-tools-events-test--ok me "unwatch_events" (list :watch_id (substring id 2)))))
      (should-not (gethash id harness-tools-events--watches))
      (harness-emit 'session/status worker 'blocked)
      (harness-tools-events-test--settle)
      (should (= 1 (length harness-tools-events-test--questions)))
      (should (equal "This session watches no events."
                     (harness-tools-events-test--ok me "unwatch_events" nil)))
      ;; Without an id, every watch of the session.
      (should (string-match-p (regexp-quote theirs) (harness-tools-events-test--ok worker "unwatch_events" nil)))
      (should (zerop (hash-table-count harness-tools-events--watches))))))

(ert-deftest harness-tools-events-a-registration-is-outstanding ()
  "While a registration lives, the session has something outstanding."
  (harness-tools-events-test-with
    (let* ((me (harness-tools-events-test--session))
           (id (harness-tools-events-test--watch me :events '("task/done" "merge/finished") :prompt "x")))
      (should (equal (format "Watching events: %s (task/done, merge/finished)" id)
                     (harness-call 'agent/outstanding me)))
      (harness-tools-events-test--ok me "unwatch_events" nil)
      (should-not (harness-call 'agent/outstanding me)))))

(ert-deftest harness-tools-events-a-message-on-its-way-is-outstanding ()
  "A decision still waiting to wake its session counts as outstanding,
though its watch has ended, until the message goes; a watch that goes
on is reported with it."
  (harness-tools-events-test-with
    (let* ((harness-tools-events--batch-delay 30)
           (waiting "A message from an event watch waits to be sent")
           (me (harness-tools-events-test--session :name "Boss"))
           (worker (harness-tools-events-test--session :name "Worker")))
      (harness-tools-events-test--watch me :events '("session/status") :prompt "x")
      (harness-emit 'session/status worker 'blocked)
      (harness-test-wait (lambda () (gethash me harness-tools-events--outbox)) 5 "the decision")
      ;; The watch is over, but its message has not gone yet.
      (should (zerop (hash-table-count harness-tools-events--watches)))
      (should-not (harness-tools-events-test--wakes me))
      (should (equal waiting (harness-call 'agent/outstanding me)))
      ;; It adds to what other modules report, and is the whole of it otherwise.
      (should (equal (concat "Other work; " waiting) (harness-tools-events--outstanding "Other work" me)))
      (should (equal waiting (harness-tools-events--outstanding nil me)))
      ;; Once it has gone there is nothing to wait for.
      (harness-tools-events-test--send-now me)
      (harness-test-wait (lambda () (harness-tools-events-test--wakes me)) 5 "the wake-up")
      (should-not (gethash me harness-tools-events--outbox))
      (should-not (harness-call 'agent/outstanding me))
      (should (equal "Other work" (harness-tools-events--outstanding "Other work" me)))
      (should-not (harness-tools-events--outstanding nil me))
      ;; A watch that goes on after its decision is reported with the message.
      (let ((id (harness-tools-events-test--watch me :events '("session/status") :prompt "x" :once :false)))
        (harness-emit 'session/status worker 'idle)
        (harness-test-wait (lambda () (gethash me harness-tools-events--outbox)) 5 "the second decision")
        (should (gethash id harness-tools-events--watches))
        (should (equal (format "Watching events: %s (session/status); %s" id waiting)
                       (harness-call 'agent/outstanding me)))))))

(ert-deftest harness-tools-events-a-task-stays-active-while-a-message-is-on-its-way ()
  "A task whose session's turn ends while a decision waits to wake the
session stays active, and says why; the turn the message starts ends
it as usual, in review, instead of the task going to review just before
the wake-up reopens it."
  (harness-tools-events-test-with
    (let* ((harness-tools-events--batch-delay 30)
           (harness-tasks-require-verification t)
           (waiting "A message from an event watch waits to be sent")
           (me (harness-tools-events-test--session :name "Boss"))
           (worker (harness-tools-events-test--session :name "Worker"))
           (tid (plist-get (harness-call 'task/adopt me) :id)))
      ;; Whatever adopting it sets off happens before the watch.
      (harness-tools-events-test--settle)
      (harness-tools-events-test--watch me :events '("session/status") :prompt "x")
      (harness-emit 'session/status worker 'blocked)
      (harness-test-wait (lambda () (gethash me harness-tools-events--outbox)) 5 "the decision")
      (should (zerop (hash-table-count harness-tools-events--watches)))
      ;; The turn ends before the message goes: the task stays at work.
      (harness-emit 'agent/turn-ended me 'end-turn)
      (let ((task (harness-call 'task/get tid)))
        (should (eq 'active (plist-get task :state)))
        (should (equal waiting (plist-get task :waiting))))
      ;; The message goes; the turn it starts ends the task as usual.
      (harness-tools-events-test--send-now me)
      (harness-test-wait (lambda () (eq 'review (plist-get (harness-call 'task/get tid) :state)))
                         10 "the task in review")
      (should (harness-tools-events-test--wakes me))
      (should-not (plist-get (harness-call 'task/get tid) :waiting)))))

(ert-deftest harness-tools-events-a-cancelled-turn-drops-registrations ()
  "A registration outlives the turn that made it, but not a turn the user
cancelled; a call that waits goes with any end of its turn."
  (harness-tools-events-test-with
    (let ((me (harness-tools-events-test--session)))
      (harness-tools-events-test--watch me :events '("task/done") :prompt "x")
      (harness-emit 'agent/turn-ended me 'end-turn)
      (should (= 1 (hash-table-count harness-tools-events--watches)))
      (harness-emit 'agent/turn-ended me 'cancelled)
      (should (zerop (hash-table-count harness-tools-events--watches)))
      (should-not (harness-call 'agent/outstanding me))
      (let ((promise (harness-tools-events-test--call me "watch_events"
                                                      '(:events ("task/done") :prompt "x" :wait t))))
        (harness-test-wait (lambda () (= 1 (hash-table-count harness-tools-events--watches))) 5 "the watch")
        (harness-emit 'agent/turn-ended me 'error)
        (should (string-match-p "interrupted" (plist-get (harness-test-await promise 5) :content)))
        (should (zerop (hash-table-count harness-tools-events--watches)))))))

(ert-deftest harness-tools-events-a-deleted-session-ends-its-watches ()
  "A session's watches end with it, quietly; a watch of a deleted
session ends too, and its own session hears of it."
  (harness-tools-events-test-with
    (let* ((me (harness-tools-events-test--session))
           (worker (harness-tools-events-test--session))
           (gone (harness-tools-events-test--session)))
      (harness-tools-events-test--watch me :events '("session/status") :prompt "x" :session_id worker)
      (harness-tools-events-test--watch gone :events '("task/done") :prompt "y")
      (harness-call 'session/delete gone)
      (should (= 1 (hash-table-count harness-tools-events--watches)))
      (harness-call 'session/delete worker)
      (should (zerop (hash-table-count harness-tools-events--watches)))
      (harness-test-wait (lambda () (harness-tools-events-test--wakes me)) 5 "the news")
      (let ((text (car (harness-tools-events-test--wake-texts me))))
        (should (equal "gone" (plist-get (harness-tools-events-test--json text) :ended)))
        (should (string-match-p "the session it watched, [^ ]+, was deleted" text))))))

(provide 'harness-tools-events-test)
;;; harness-tools-events-test.el ends here
