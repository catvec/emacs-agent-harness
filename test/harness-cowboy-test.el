;;; harness-cowboy-test.el --- Tests for what a message does first when the prompt cache went cold  -*- lexical-binding: t; -*-

;;; Commentary:

;; A message to a session whose prompt cache lapsed waits for what goes
;; first (harness-cowboy.el): asked in a session that waits for the
;; user, taken from `harness-cowboy-default' in one that never does.
;; The demo provider answers both the turns and the summaries; a
;; session is made cold by stamping its cache long ago.

;;; Code:

(require 'harness-test-helpers)

(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
(defvar harness-sessions)
(defvar harness-agent--turns)
(defvar harness-compaction--running)
(defvar harness-compaction-brief-model)
(defvar harness-tools-agent--questions)
(defvar harness-cowboy--asking)
(defvar harness-cowboy-default)
(defvar harness-cowboy-ask)
(defvar harness-cowboy-min-context)
(defvar harness-non-interactive)
(defvar harness-session-interrupted-output)
(declare-function harness-cowboy-parse-answer "harness-cowboy" (text))
(declare-function harness-cowboy-cold-p "harness-cowboy" (session &optional now))
(declare-function harness-cowboy-cost-text "harness-cowboy" (estimate choice))
(declare-function harness-session--load-all "harness-session" ())
(declare-function harness-session-flush "harness-session" (&optional id))

(defvar harness-cowboy-test--requests nil
  "The requests of the turns the demo provider answered, newest first.")

(defun harness-cowboy-test--script (request)
  "Answer REQUEST: a summary when it asks for one, else a short reply.
A turn's request is remembered in `harness-cowboy-test--requests'."
  (if (string-match-p "handoff summary" (or (plist-get request :system) ""))
      '((:type text :delta "SUMMARY TEXT")
        (:type usage :input 50 :output 5)
        (:type done :stop-reason end-turn))
    (push request harness-cowboy-test--requests)
    '((:type text :delta "Done.")
      (:type usage :input 30 :output 5 :cache-read 400 :context 430)
      (:type done :stop-reason end-turn))))

(defmacro harness-cowboy-test-with (&rest body)
  "Load the state layer, compaction, the session tools and cowboy; run BODY.
Asking is on and the default is the brief summary, whatever the user's
settings say."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo tools session agent compaction
                  tools-agent tools-sessions cowboy))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-agent--turns)
     (clrhash harness-compaction--running)
     (clrhash harness-tools-agent--questions)
     (clrhash harness-cowboy--asking)
     (setq harness-cowboy-test--requests nil)
     (let ((harness-provider-demo--delay 0.005)
           (harness-provider-demo-script-override #'harness-cowboy-test--script)
           (harness-compaction-brief-model "demo:scripted")
           (harness-cowboy-default 'brief)
           (harness-cowboy-ask t)
           (harness-cowboy-min-context 0)
           (harness-non-interactive nil)
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       ,@body)))

(defun harness-cowboy-test-session (&rest plist)
  "Create a demo session with an answered exchange whose prompt cache lapsed.
PLIST goes to `session/create'.  The cache was last used at 1000, the
first seconds of 1970."
  (let ((sid (plist-get (apply #'harness-call 'session/create :cwd (harness-test-temp-dir)
                               :model "demo:scripted" plist)
                        :id)))
    (harness-call 'session/append sid '(:kind user :content "please refactor the parser"))
    (harness-call 'session/append sid '(:kind assistant :content "Done: parser.el rewritten"))
    ;; Under half of the demo model's 8000-token window: no automatic
    ;; compaction on top.
    (harness-call 'session/usage-add sid '(:input 10 :output 10 :cache-read 3000 :context 3020 :cache-at 1000.0))
    sid))

(defun harness-cowboy-test--question (sid)
  "Wait for the question SID's cold cache asks; return its pending item."
  (harness-test-wait (lambda () (harness-call 'question/pending sid)) 5 "the cold-cache question")
  (car (harness-call 'question/pending sid)))

(defun harness-cowboy-test--answer (sid text)
  "Answer the question SID waits on with TEXT."
  (harness-call 'question/answer sid (plist-get (harness-cowboy-test--question sid) :id) (list :answer text)))

(defun harness-cowboy-test--kinds (sid)
  (mapcar (lambda (n) (plist-get n :kind)) (harness-call 'session/nodes sid)))

(defun harness-cowboy-test--hints (sid)
  (delq nil (mapcar (lambda (n) (and (eq (plist-get n :kind) 'hint) (plist-get n :content)))
                    (harness-call 'session/nodes sid))))

(defun harness-cowboy-test--compactions (sid)
  (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'compaction)) (harness-call 'session/nodes sid)))

(defun harness-cowboy-test--request-text (request)
  "Return the text of all of REQUEST's messages."
  (mapconcat (lambda (m) (mapconcat (lambda (b) (or (plist-get b :text) "")) (plist-get m :content) "\n"))
             (plist-get request :messages) "\n"))

;;;; When to ask

(ert-deftest harness-cowboy-cold-only-once-the-cache-lapsed ()
  "A session is cold once the cache its requests last used lapsed, and it
has a conversation to lose; one that never cached, or started over, is not."
  (let ((harness-cowboy-min-context 0)
        (cold '(:head "n1" :cache (:at 1000.0 :ttl 300 :expires 1300.0 :model "m") :usage (:context 5000))))
    (should (harness-cowboy-cold-p cold 2000.0))
    (should-not (harness-cowboy-cold-p cold 1299.0))
    (should-not (harness-cowboy-cold-p (plist-put (copy-sequence cold) :cache nil) 2000.0))
    (should-not (harness-cowboy-cold-p (plist-put (copy-sequence cold) :head nil) 2000.0))
    ;; A small conversation can be left to go uncached.
    (let ((harness-cowboy-min-context 10000))
      (should-not (harness-cowboy-cold-p cold 2000.0)))
    (let ((harness-cowboy-min-context 5000))
      (should (harness-cowboy-cold-p cold 2000.0)))))

(ert-deftest harness-cowboy-warm-cache-goes-on ()
  "A message while the cache lasts goes on at once, asking nothing."
  (harness-cowboy-test-with
    (let ((sid (harness-cowboy-test-session)))
      (harness-call 'session/usage-add sid (list :input 10 :output 10 :cache-read 3000 :context 3020
                                                 :cache-at (float-time)))
      (should (eq 'end-turn (plist-get (harness-test-await (harness-call 'agent/prompt sid "go on") 10)
                                       :stop-reason)))
      (should-not (harness-cowboy-test--compactions sid))
      (should-not (harness-call 'question/pending sid))
      (should (string-match-p "please refactor the parser"
                              (harness-cowboy-test--request-text (car harness-cowboy-test--requests)))))))

;;;; Asking

(ert-deftest harness-cowboy-asks-what-goes-first ()
  "A message to a session whose cache lapsed waits on a question: the
session is blocked on it and the message is not in the transcript yet.
The question offers every choice with its cost; the answer's compaction
comes before the message, which then goes as usual, without the old
conversation."
  (harness-cowboy-test-with
    (let* ((sid (harness-cowboy-test-session))
           (decided nil)
           (asked nil)
           (p (progn (harness-on 'cowboy/decided (lambda (&rest args) (push args decided)))
                     (harness-on 'cowboy/asked (lambda (&rest args) (push args asked)))
                     (harness-call 'agent/prompt sid "now add tests")))
           (item (harness-cowboy-test--question sid))
           (payload (plist-get item :payload))
           (info (plist-get payload :cowboy)))
      (should (eq 'blocked (plist-get (harness-call 'session/get sid) :status)))
      (should (equal (plist-get item :id) (harness-call 'cowboy/asking sid)))
      (should (equal (list (list sid (plist-get item :id))) asked))
      ;; The message waits outside the transcript.
      (should-not (member "now add tests" (mapcar (lambda (n) (plist-get n :content))
                                                  (harness-call 'session/nodes sid))))
      (should (equal "now add tests" (plist-get (plist-get payload :waiting-message) :text)))
      (should (string-match-p (concat "\\`Your message waits: this session's prompt cache lapsed at .*, [0-9]+ days ago\\."
                                      "  Carrying on sends the whole conversation, ~3\\.0k tokens, uncached.*"
                                      "  What goes first\\?  Answer \"always\"")
                              (plist-get payload :question)))
      ;; Every choice, with its cost; the default says so.
      (let ((options (plist-get payload :options)))
        (should (= 6 (length options)))
        (should (string-match-p "\\`Brief summary (~\\$[0-9.]+, the default)\\'" (nth 0 options)))
        (should (string-match-p "\\`Summary (~\\$[0-9.]+)\\'" (nth 1 options)))
        (should (equal "Transcript file (free)" (nth 2 options)))
        (should (equal "Start afresh (free)" (nth 3 options)))
        (should (string-match-p "\\`Carry on (~\\$[0-9.]+ uncached)\\'" (nth 4 options)))
        (should (equal "Not now" (nth 5 options))))
      (should (plist-get payload :allow-free-text))
      ;; What a client draws more than the question with.
      (should (equal "brief" (plist-get info :default)))
      (should (equal '("brief" "summary" "transcript" "fresh" "carry-on" "hold")
                     (mapcar (lambda (c) (plist-get c :choice)) (plist-get info :choices))))
      (should (equal "free" (plist-get (nth 2 (plist-get info :choices)) :cost-text)))
      (should (eq t (plist-get info :history)))
      (should (equal "now add tests" (plist-get info :preview)))
      (should (= 3020 (plist-get info :context)))
      (should (= 1300.0 (plist-get info :expires)))
      (should-not (harness-promise-settled-p p))
      ;; Answered with an option as offered: the transcript file first.
      (harness-cowboy-test--answer sid "Transcript file (free)")
      (should (eq 'end-turn (plist-get (harness-test-await p 10) :stop-reason)))
      (should (equal (list (list sid 'transcript 'user)) decided))
      (should-not (harness-call 'cowboy/asking sid))
      (let* ((nodes (harness-call 'session/nodes sid))
             (compaction (cl-position 'compaction nodes :key (lambda (n) (plist-get n :kind))))
             (message (cl-position "now add tests" nodes :key (lambda (n) (plist-get n :content)) :test #'equal))
             (node (nth compaction nodes)))
        (should (< compaction message))
        (should (equal "transcript" (harness-node-compaction-kind node)))
        (should (equal '(:choice "transcript" :by "user") (plist-get (plist-get node :meta) :cowboy)))
        ;; The note points at the conversation's history too.
        (should (string-match-p "session_history" (plist-get node :content))))
      (should (member (format "Prompt cache cold since %s: writing the conversation to a transcript file first, as you chose"
                              (format-time-string "%b %-d %H:%M" 1300.0))
                      (harness-cowboy-test--hints sid)))
      ;; The provider got the note and the message, not the old conversation.
      (let ((text (harness-cowboy-test--request-text (car harness-cowboy-test--requests))))
        (should (string-match-p "now add tests" text))
        (should-not (string-match-p "please refactor the parser" text))))))

(ert-deftest harness-cowboy-names-who-sent-the-message ()
  "A message another session's agent or the harness sent says so."
  (harness-cowboy-test-with
    (let ((sid (harness-cowboy-test-session)))
      (harness-call 'agent/prompt sid "[Message from session abc]\n\nreview this"
                    (list :from (list :kind 'session :id "abc12345" :name "Reviewer")))
      (let ((payload (plist-get (harness-cowboy-test--question sid) :payload)))
        (should (string-prefix-p "A message from session \"Reviewer\" waits:" (plist-get payload :question)))
        (should (equal "abc12345" (plist-get (plist-get (plist-get payload :cowboy) :from) :id)))
        ;; The preview skips the header that says no more than the sender.
        (should (equal "review this" (plist-get (plist-get payload :cowboy) :preview))))
      (harness-cowboy-test--answer sid "carry on")
      (harness-test-wait (lambda () (not (harness-call 'agent/running sid))) 10 "the turn"))))

(ert-deftest harness-cowboy-brief-summary-and-carrying-on ()
  "A brief summary is the cheap model's; carrying on sends it all again."
  (harness-cowboy-test-with
    (let ((sid (harness-cowboy-test-session)))
      (let ((p (harness-call 'agent/prompt sid "first")))
        (harness-cowboy-test--answer sid "b")
        (harness-test-await p 10))
      (let ((node (car (harness-cowboy-test--compactions sid))))
        (should (equal "brief" (harness-node-compaction-kind node)))
        (should (string-prefix-p "SUMMARY TEXT" (plist-get node :content)))
        (should (string-match-p "session_history" (plist-get node :content))))
      (should (string-match-p "SUMMARY TEXT" (harness-cowboy-test--request-text (car harness-cowboy-test--requests))))
      ;; Cold again: carry on, the whole conversation as it is.
      (harness-call 'session/usage-add sid '(:input 10 :output 10 :cache-read 400 :context 430 :cache-at 1000.0))
      (let ((p (harness-call 'agent/prompt sid "second")))
        (harness-cowboy-test--answer sid "carry on")
        (harness-test-await p 10))
      (should (= 1 (length (harness-cowboy-test--compactions sid))))
      (should (cl-some (lambda (h) (string-match-p ": carrying on with the whole conversation, ~430 tokens uncached, as you chose\\'" h))
                       (harness-cowboy-test--hints sid)))
      (let ((text (harness-cowboy-test--request-text (car harness-cowboy-test--requests))))
        (should (string-match-p "first" text))
        (should (string-match-p "second" text))))))

(ert-deftest harness-cowboy-fresh-start ()
  "Starting afresh carries nothing over but a note pointing at the history."
  (harness-cowboy-test-with
    (let ((sid (harness-cowboy-test-session)))
      (let ((p (harness-call 'agent/prompt sid "next step")))
        (harness-cowboy-test--answer sid "start afresh")
        (harness-test-await p 10))
      (let ((node (car (harness-cowboy-test--compactions sid))))
        (should (equal "fresh" (harness-node-compaction-kind node)))
        (should (string-match-p "not carried over" (plist-get node :content)))
        (should (string-match-p "session_history tool" (plist-get node :content))))
      (let ((text (harness-cowboy-test--request-text (car harness-cowboy-test--requests))))
        (should (string-match-p "next step" text))
        (should-not (string-match-p "refactor the parser" text))))))

(ert-deftest harness-cowboy-an-answer-that-names-nothing-asks-again ()
  "An answer naming no choice asks again, saying so; the next one counts."
  (harness-cowboy-test-with
    (let* ((sid (harness-cowboy-test-session))
           (p (harness-call 'agent/prompt sid "go"))
           (first (harness-cowboy-test--question sid)))
      (harness-call 'question/answer sid (plist-get first :id) '(:answer "purple, please"))
      (harness-test-wait (lambda () (let ((q (car (harness-call 'question/pending sid))))
                                      (and q (not (equal (plist-get q :id) (plist-get first :id))))))
                         5 "the question again")
      (let ((again (harness-cowboy-test--question sid)))
        (should (string-prefix-p "“purple, please” is not one of the choices.  Your message waits:"
                                 (plist-get (plist-get again :payload) :question)))
        (should (equal (plist-get again :id) (harness-call 'cowboy/asking sid))))
      (harness-cowboy-test--answer sid "3")
      (harness-test-await p 10)
      (should (equal "transcript" (harness-node-compaction-kind (car (harness-cowboy-test--compactions sid))))))))

;;;; Holding the message

(ert-deftest harness-cowboy-not-now-keeps-the-message ()
  "Not now: no turn starts, the message stays in the transcript, and the
next message, asked about again, sends it too."
  (harness-cowboy-test-with
    (let* ((sid (harness-cowboy-test-session))
           (p (harness-call 'agent/prompt sid "the held one")))
      (harness-cowboy-test--answer sid "not now")
      (let ((result (harness-test-await p 10)))
        (should (eq 'blocked (plist-get result :stop-reason))))
      (should-not harness-cowboy-test--requests)
      (should-not (harness-cowboy-test--compactions sid))
      (should (member "the held one" (mapcar (lambda (n) (plist-get n :content)) (harness-call 'session/nodes sid))))
      (should (member "Turn not started: not now: the prompt cache is cold, and the message waits; the next one sends it too"
                      (harness-cowboy-test--hints sid)))
      (should (eq 'idle (plist-get (harness-call 'session/get sid) :status)))
      ;; Asked again with the next message; carrying on sends both.
      (let ((p (harness-call 'agent/prompt sid "and this one")))
        (harness-cowboy-test--answer sid "c")
        (should (eq 'end-turn (plist-get (harness-test-await p 10) :stop-reason))))
      (let ((text (harness-cowboy-test--request-text (car harness-cowboy-test--requests))))
        (should (string-match-p "the held one" text))
        (should (string-match-p "and this one" text))))))

(ert-deftest harness-cowboy-cancel-dismisses-the-question ()
  "Cancelling the turn while the question waits dismisses it at once, and
the turn ends cancelled, not held; the message stays."
  (harness-cowboy-test-with
    (let* ((sid (harness-cowboy-test-session))
           (p (harness-call 'agent/prompt sid "never mind")))
      (harness-cowboy-test--question sid)
      (should (harness-call 'agent/cancel sid))
      ;; Well before the agent's grace period of 3 seconds.
      (should (eq 'cancelled (plist-get (harness-test-await p 1) :stop-reason)))
      (should-not (harness-call 'question/pending sid))
      (should-not (cl-some (lambda (h) (string-prefix-p "Turn not started" h)) (harness-cowboy-test--hints sid)))
      (should-not (harness-call 'cowboy/asking sid))
      (should-not (harness-call 'agent/running sid))
      (should-not (harness-cowboy-test--compactions sid))
      (should-not harness-cowboy-test--requests)
      (should (memq (plist-get (harness-call 'session/get sid) :status) '(idle)))
      (should (member "never mind" (mapcar (lambda (n) (plist-get n :content)) (harness-call 'session/nodes sid)))))))

(ert-deftest harness-cowboy-a-restart-queues-the-message-again ()
  "A harness that stops while the question waits loses the turn, not the
message: the next start puts it back in the session's queue."
  (harness-cowboy-test-with
    (let ((sid (harness-cowboy-test-session)))
      (harness-call 'agent/prompt sid "keep me" (list :from (harness-sender-system "tasks")))
      (harness-cowboy-test--question sid)
      ;; The process dies: whatever was only in memory is gone.
      (harness-session-flush)
      (clrhash harness-sessions)
      (clrhash harness-agent--turns)
      (clrhash harness-tools-agent--questions)
      (clrhash harness-cowboy--asking)
      (harness-session--load-all)
      (let ((s (harness-call 'session/get sid)))
        (should (eq 'inactive (plist-get s :status)))
        (should-not (plist-get s :pending))
        (should (equal '("keep me") (mapcar (lambda (q) (plist-get q :text)) (plist-get s :queue))))
        (should (equal "tasks" (plist-get (plist-get (car (plist-get s :queue)) :from) :source))))
      (should (member (concat "Interrupted: the harness stopped before you said what goes first, the prompt cache"
                              " being cold; the message that waited is back in the queue")
                      (harness-cowboy-test--hints sid))))))

;;;; Not asking

(ert-deftest harness-cowboy-non-interactive-takes-the-default ()
  "A session that never waits for the user is not asked: the default, the
brief summary, goes first, and says why."
  (harness-cowboy-test-with
    (let ((sid (harness-cowboy-test-session :non-interactive t))
          (asked nil))
      (harness-on 'question/asked (lambda (&rest _) (setq asked t)))
      (should (eq 'end-turn (plist-get (harness-test-await (harness-call 'agent/prompt sid "feedback: fix it") 10)
                                       :stop-reason)))
      (should-not asked)
      (let ((node (car (harness-cowboy-test--compactions sid))))
        (should (equal "brief" (harness-node-compaction-kind node)))
        (should (equal '(:choice "brief" :by "non-interactive") (plist-get (plist-get node :meta) :cowboy))))
      (should (cl-some (lambda (h) (string-match-p (concat ": compacting into a brief summary first, the default for a"
                                                           " session that does not wait for you (harness-cowboy-default)\\'")
                                                   h))
                       (harness-cowboy-test--hints sid))))))

(ert-deftest harness-cowboy-asking-off-takes-the-default ()
  "With asking off every session takes the default, whatever it is."
  (harness-cowboy-test-with
    (let ((harness-cowboy-ask nil)
          (harness-cowboy-default 'transcript)
          (sid (harness-cowboy-test-session)))
      (harness-test-await (harness-call 'agent/prompt sid "go") 10)
      (should-not (harness-call 'question/pending sid))
      (should (equal "transcript" (harness-node-compaction-kind (car (harness-cowboy-test--compactions sid)))))
      (should (cl-some (lambda (h) (string-match-p "first, the default, as asking is off (harness-cowboy-ask)\\'" h))
                       (harness-cowboy-test--hints sid))))))

(ert-deftest harness-cowboy-always-makes-it-the-default ()
  "\"always\" with a choice does it now and from then on, without asking."
  (harness-cowboy-test-with
    (let ((sid (harness-cowboy-test-session)))
      (let ((p (harness-call 'agent/prompt sid "one")))
        (harness-cowboy-test--answer sid "always start afresh")
        (harness-test-await p 10))
      (should (eq 'fresh harness-cowboy-default))
      (should-not harness-cowboy-ask)
      (should (equal '(:choice "fresh" :by "always")
                     (plist-get (plist-get (car (harness-cowboy-test--compactions sid)) :meta) :cowboy)))
      (should (cl-some (lambda (h) (string-match-p "as you chose, from now on without asking" h))
                       (harness-cowboy-test--hints sid)))
      ;; Cold again: nobody is asked.
      (harness-call 'session/usage-add sid '(:input 10 :output 10 :cache-read 400 :context 430 :cache-at 1000.0))
      (harness-test-await (harness-call 'agent/prompt sid "two") 10)
      (should-not (harness-call 'question/pending sid))
      (should (= 2 (length (harness-cowboy-test--compactions sid)))))))

(ert-deftest harness-cowboy-a-summary-that-fails-falls-back ()
  "A summary that cannot be made gives way to the transcript file; the
message goes all the same."
  (harness-cowboy-test-with
    (let ((harness-compaction-brief-model "nowhere:none")
          (sid (harness-cowboy-test-session :non-interactive t)))
      (should (eq 'end-turn (plist-get (harness-test-await (harness-call 'agent/prompt sid "go") 10) :stop-reason)))
      (let ((node (car (harness-cowboy-test--compactions sid))))
        (should (equal "transcript" (harness-node-compaction-kind node)))
        (should (equal "brief" (plist-get (plist-get (plist-get node :meta) :cowboy) :choice)))
        (should (plist-get (plist-get (plist-get node :meta) :cowboy) :fallback)))
      (should (cl-some (lambda (h) (string-match-p "\\`No brief summary (.*): writing the conversation to a transcript file instead\\'" h))
                       (harness-cowboy-test--hints sid))))))

;;;; Compacting unasked

(defun harness-cowboy-test-fork ()
  "Create a demo session with an answered exchange and no prompt cache of its own.
That is what a fork of a long session starts as: the gate never finds
it cold."
  (let ((sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted") :id)))
    (harness-call 'session/append sid '(:kind user :content "please refactor the parser"))
    (harness-call 'session/append sid '(:kind assistant :content "Done: parser.el rewritten"))
    sid))

(defun harness-cowboy-test-decisions ()
  "Start noting the `cowboy/decided' events; return the cell their args collect in.
The newest comes first."
  (let ((cell (list nil)))
    (harness-on 'cowboy/decided (lambda (&rest args) (push args (car cell))))
    cell))

(ert-deftest harness-cowboy-compact-takes-the-default-and-compacts ()
  "cowboy/compact does, unasked, what the gate does for a session nobody is asked about."
  (harness-cowboy-test-with
    (let ((sid (harness-cowboy-test-fork)))
      (let ((promise (harness-call 'cowboy/compact sid)))
        ;; There is no turn: the session is not shown at work, as the gate shows it.
        (should-not (eq 'running (plist-get (harness-call 'session/get sid) :status)))
        (should (eq 'brief (harness-test-await promise 10))))
      (let ((node (car (harness-cowboy-test--compactions sid))))
        (should (equal "brief" (harness-node-compaction-kind node)))
        (should (string-prefix-p "SUMMARY TEXT" (plist-get node :content)))
        (should (string-match-p "session_history" (plist-get node :content)))
        (should (equal '(:choice "brief" :by "cold-start") (plist-get (plist-get node :meta) :cowboy))))
      (should-not (harness-call 'question/pending sid))
      ;; A session with no cache has no clock to say: the hint opens without one.
      (should (cl-some (lambda (h)
                         (string-match-p
                          (concat "\\`No warm prompt cache holds this conversation: compacting into a brief summary"
                                  " first, the default for a session no warm cache holds (harness-cowboy-default)\\'")
                          h))
                       (harness-cowboy-test--hints sid))))
    ;; A session whose cache did lapse keeps the gate's opening.
    (let ((sid (harness-cowboy-test-session)))
      (should (eq 'brief (harness-test-await (harness-call 'cowboy/compact sid) 10)))
      (should (cl-some (lambda (h) (string-match-p "\\`Prompt cache cold since [^:]*:[0-9][0-9]: compacting into a brief summary first, the default for a session no warm cache holds (harness-cowboy-default)\\'" h))
                       (harness-cowboy-test--hints sid))))))

(ert-deftest harness-cowboy-compact-takes-the-default-whatever-it-is ()
  "The default is `harness-cowboy-default', whichever of the choices; never `hold'."
  (harness-cowboy-test-with
    (let ((harness-cowboy-default 'fresh)
          (sid (harness-cowboy-test-fork)))
      (should (eq 'fresh (harness-test-await (harness-call 'cowboy/compact sid) 10)))
      (should (equal "fresh" (harness-node-compaction-kind (car (harness-cowboy-test--compactions sid)))))
      (should (cl-some (lambda (h) (string-match-p ": starting afresh, the default for a session no warm cache holds" h))
                       (harness-cowboy-test--hints sid))))
    ;; `hold' is only ever an answer: it is not a default, so the brief summary is.
    (let ((harness-cowboy-default 'hold)
          (sid (harness-cowboy-test-fork)))
      (should (eq 'brief (harness-test-await (harness-call 'cowboy/compact sid) 10)))
      (should (equal "brief" (harness-node-compaction-kind (car (harness-cowboy-test--compactions sid))))))))

(ert-deftest harness-cowboy-compact-honours-the-minimum-context ()
  "A context under `harness-cowboy-min-context' goes as it is: no decision, no hint."
  (harness-cowboy-test-with
    (let ((sid (harness-cowboy-test-session))
          (decisions (harness-cowboy-test-decisions))
          (hints nil))
      (setq hints (harness-cowboy-test--hints sid))
      ;; The session's context is 3020 tokens.
      (let ((harness-cowboy-min-context 3021))
        (should-not (harness-test-await (harness-call 'cowboy/compact sid) 10)))
      (should-not (harness-cowboy-test--compactions sid))
      (should-not (car decisions))
      (should (equal hints (harness-cowboy-test--hints sid)))
      (let ((harness-cowboy-min-context 3020))
        (should (eq 'brief (harness-test-await (harness-call 'cowboy/compact sid) 10))))
      (should (= 1 (length (harness-cowboy-test--compactions sid))))
      (should (= 1 (length (car decisions)))))
    ;; With no usage to read the context is the transcript's own estimate.
    (let ((sid (harness-cowboy-test-fork))
          (harness-cowboy-min-context 100000))
      (should-not (harness-test-await (harness-call 'cowboy/compact sid) 10))
      (should-not (harness-cowboy-test--compactions sid)))))

(ert-deftest harness-cowboy-compact-opens-its-hint-with-why ()
  "WHY replaces the clock that a session with no cache of its own cannot give."
  (harness-cowboy-test-with
    (dolist (maker '(harness-cowboy-test-fork harness-cowboy-test-session))
      (let ((sid (funcall maker)))
        (should (eq 'brief (harness-test-await
                            (harness-call 'cowboy/compact sid
                                          :why "No prompt cache on demo:frontier holds this conversation")
                            10)))
        (let ((hints (harness-cowboy-test--hints sid)))
          (should (member (concat "No prompt cache on demo:frontier holds this conversation: compacting into a brief"
                                  " summary first, the default for a session no warm cache holds"
                                  " (harness-cowboy-default)")
                          hints))
          (should-not (cl-some (lambda (h) (string-match-p "Prompt cache cold since" h)) hints)))))))

(ert-deftest harness-cowboy-compact-announces-what-it-decided ()
  "cowboy/decided fires with `cold-start', or with whom the caller names."
  (harness-cowboy-test-with
    (let ((decisions (harness-cowboy-test-decisions))
          (sid (harness-cowboy-test-fork))
          (other (harness-cowboy-test-fork)))
      (harness-test-await (harness-call 'cowboy/compact sid) 10)
      (should (equal (list (list sid 'brief 'cold-start)) (car decisions)))
      (setcar decisions nil)
      (harness-test-await (harness-call 'cowboy/compact other :by 'restart) 10)
      (should (equal (list (list other 'brief 'restart)) (car decisions)))
      (should (equal '(:choice "brief" :by "restart")
                     (plist-get (plist-get (car (harness-cowboy-test--compactions other)) :meta) :cowboy)))
      ;; The decision is the default for a session no warm cache holds, whoever named it.
      (should (cl-some (lambda (h) (string-match-p "the default for a session no warm cache holds (harness-cowboy-default)\\'" h))
                       (harness-cowboy-test--hints other))))))

(ert-deftest harness-cowboy-compact-falls-back-as-the-gate-does ()
  "A summary that cannot be made gives way to the transcript, and that to carrying on."
  (harness-cowboy-test-with
    (let ((harness-compaction-brief-model "nowhere:none")
          (sid (harness-cowboy-test-fork)))
      (should (eq 'brief (harness-test-await (harness-call 'cowboy/compact sid) 10)))
      (let* ((node (car (harness-cowboy-test--compactions sid)))
             (cowboy (plist-get (plist-get node :meta) :cowboy)))
        (should (equal "transcript" (harness-node-compaction-kind node)))
        (should (equal "brief" (plist-get cowboy :choice)))
        (should (equal "cold-start" (plist-get cowboy :by)))
        (should (plist-get cowboy :fallback)))
      (should (cl-some (lambda (h) (string-match-p "\\`No brief summary (.*): writing the conversation to a transcript file instead\\'" h))
                       (harness-cowboy-test--hints sid))))
    ;; Nothing can be made: the conversation stays as it is, and the caller goes on.
    (harness-register-method 'compaction/compact (lambda (&rest _) (harness-rejected '(harness-error "no way"))))
    (let ((sid (harness-cowboy-test-fork)))
      (should (eq 'brief (harness-test-await (harness-call 'cowboy/compact sid) 10)))
      (should-not (harness-cowboy-test--compactions sid))
      (let ((hints (harness-cowboy-test--hints sid)))
        (should (cl-some (lambda (h) (string-match-p "\\`No brief summary (.*no way.*): writing the conversation to a transcript" h))
                         hints))
        (should (cl-some (lambda (h) (string-match-p "\\`No compaction (.*no way.*): carrying on with the whole conversation\\'" h))
                         hints))))))

(ert-deftest harness-cowboy-compact-carry-on-compacts-nothing ()
  "With carrying on the default there is a decision and a hint, and no compaction."
  (harness-cowboy-test-with
    (let ((harness-cowboy-default 'carry-on)
          (decisions (harness-cowboy-test-decisions))
          (sid (harness-cowboy-test-session)))
      (should (eq 'carry-on (harness-test-await (harness-call 'cowboy/compact sid) 10)))
      (should-not (harness-cowboy-test--compactions sid))
      (should (equal (list (list sid 'carry-on 'cold-start)) (car decisions)))
      (should (cl-some (lambda (h) (string-match-p ": carrying on with the whole conversation, ~[0-9.]+k? tokens uncached, the default for a session no warm cache holds (harness-cowboy-default)\\'" h))
                       (harness-cowboy-test--hints sid))))))

(ert-deftest harness-cowboy-compact-never-rejects ()
  "Whatever goes wrong the promise resolves, with nil when nothing was done."
  (harness-cowboy-test-with
    ;; A session that is not there.
    (should-not (harness-test-await (harness-call 'cowboy/compact "no-such-session") 10))
    ;; No estimate: the session's own usage says how large the context is.
    (let ((sid (harness-cowboy-test-fork)))
      (harness-register-method 'compaction/estimate (lambda (&rest _) (error "no estimate")))
      (should (eq 'brief (harness-test-await (harness-call 'cowboy/compact sid) 10)))
      (should (= 1 (length (harness-cowboy-test--compactions sid)))))
    ;; A compaction that signals instead of rejecting.
    (harness-register-method 'compaction/compact (lambda (&rest _) (error "boom")))
    (let ((sid (harness-cowboy-test-fork)))
      (should (eq 'brief (harness-test-await (harness-call 'cowboy/compact sid) 10)))
      (should-not (harness-cowboy-test--compactions sid)))
    ;; A session that cannot take a hint: nothing is done.
    (harness-register-method 'session/hint (lambda (&rest _) (error "no hints")))
    (let ((sid (harness-cowboy-test-fork)))
      (should-not (harness-test-await (harness-call 'cowboy/compact sid) 10))
      (should-not (harness-cowboy-test--compactions sid)))))

;;;; Reading answers

(ert-deftest harness-cowboy-reads-typed-answers ()
  "An answer names a choice by name, label, option, number, key or words,
with \"always\" or without."
  (dolist (case '(("brief" brief) ("b" brief) ("Brief summary (~$0.01, the default)" brief)
                  ("a brief summary please" brief) ("1" brief) ("cheap" brief)
                  ("summary" summary) ("S" summary) ("2" summary) ("summarise it" summary)
                  ("transcript" transcript) ("t" transcript) ("Transcript file (free)" transcript)
                  ("write it to a file" transcript)
                  ("fresh" fresh) ("Start afresh (free)" fresh) ("from scratch" fresh) ("f" fresh)
                  ("carry on" carry-on) ("carry-on" carry-on) ("c" carry-on) ("continue" carry-on)
                  ("Carry on (~$0.42 uncached)" carry-on) ("5" carry-on)
                  ("not now" hold) ("q" hold) ("hold" hold) ("6" hold) ("Not now" hold) ("later" hold)))
    (should (equal (cons (cadr case) nil) (harness-cowboy-parse-answer (car case)))))
  (should (equal '(fresh . t) (harness-cowboy-parse-answer "always fresh")))
  (should (equal '(brief . t) (harness-cowboy-parse-answer "Always: brief")))
  (should (equal '(carry-on . t) (harness-cowboy-parse-answer "always carry on")))
  (should (equal '(transcript . t) (harness-cowboy-parse-answer "\"always transcript\"")))
  (should (equal '(transcript . t) (harness-cowboy-parse-answer "transcript, always")))
  (should-not (harness-cowboy-parse-answer "purple"))
  (should-not (harness-cowboy-parse-answer ""))
  (should-not (harness-cowboy-parse-answer "9"))
  (should-not (harness-cowboy-parse-answer nil)))

(ert-deftest harness-cowboy-cost-texts ()
  "What asks no model is free; carrying on says it is uncached."
  (let ((estimate '(:carry-on 0.42 :kinds ((:kind summary :cost 0.5) (:kind brief :cost 0.01)
                                           (:kind transcript :cost 0.0) (:kind fresh :cost 0.0)))))
    (should (equal "free" (harness-cowboy-cost-text estimate 'transcript)))
    (should (equal "free" (harness-cowboy-cost-text nil 'fresh)))
    (should (equal "~$0.010" (harness-cowboy-cost-text estimate 'brief)))
    (should (string-suffix-p " uncached" (harness-cowboy-cost-text estimate 'carry-on)))
    (should-not (harness-cowboy-cost-text estimate 'hold))
    (should-not (harness-cowboy-cost-text nil 'summary))))

;;;; Other agents

(ert-deftest harness-cowboy-other-agents-cannot-answer ()
  "What a cold cache is worth spending is left to the user: session_control
will not answer the question for them."
  (harness-cowboy-test-with
    (let* ((sid (harness-cowboy-test-session))
           (other (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted") :id))
           (p (harness-call 'agent/prompt sid "go")))
      (harness-cowboy-test--question sid)
      (let ((r (harness-test-await (harness-call 'tools/execute other
                                                 (list :id "c1" :name "session_control"
                                                       :input (list :session_id sid :action "answer" :answer "carry on")))
                                   10)))
        (should (plist-get r :is-error))
        (should (string-match-p "left to the user" (plist-get r :content))))
      (should (harness-call 'question/pending sid))
      (harness-cowboy-test--answer sid "hold")
      (harness-test-await p 10))))

(provide 'harness-cowboy-test)
;;; harness-cowboy-test.el ends here
