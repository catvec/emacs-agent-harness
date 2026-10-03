;;; harness-handoff-test.el --- Tests for handing conversations over between providers  -*- lexical-binding: t; -*-

;;; Commentary:

;; A fake hosted-loop provider stands in for Claude Code (whose CLI the
;; provider tests drive): like it, it keeps the conversation, reports a
;; provider state and is only meant to get the newest user messages.
;; The demo provider stands in for an API provider, sent everything.

;;; Code:

(require 'harness-test-helpers)

(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent--turns)
(defvar harness-compaction--running)
(defvar harness-handoff--pending)
(defvar harness-handoff-risks)
(defvar harness-acp--server-enabled)
(defvar harness-acp--clients)
(declare-function harness-define-provider "harness-provider")
(declare-function harness-define-tool "harness-tools")
(declare-function harness-acp-connect "harness-acp")
(declare-function harness-acp-request "harness-acp")
(declare-function harness-acp--drop-client "harness-acp")

(defvar harness-handoff-test--requests nil
  "Requests the fake hosted provider got, newest first.")

(defun harness-handoff-test--define-providers ()
  "Define `hosted', a fake hosted loop, and `api', a provider sent everything."
  (harness-define-provider 'hosted
    :label "Hosted"
    :models (lambda ()
              (harness-resolved
               (list (list :name "m" :label "Hosted M"
                           :pricing '(:input 4.0 :output 20.0 :cache-read 0.2 :cache-write 5.0)))))
    :complete (lambda (req)
                (push req harness-handoff-test--requests)
                (let ((on-event (plist-get req :on-event)))
                  (run-at-time 0.005 nil
                               (lambda ()
                                 (funcall on-event '(:type provider-state :state (:conv "c1")))
                                 (funcall on-event '(:type text :delta "ok"))
                                 (funcall on-event '(:type done :stop-reason end-turn)))))
                (list :cancel #'ignore))
    :fork (lambda (_model state) (harness-resolved (list :conv (plist-get state :conv) :forked t)))
    :capabilities '(:hosted-loop t :resume t :fork t))
  (harness-define-provider 'api
    :label "API"
    :models (lambda () (harness-resolved (list (list :name "m" :label "API M"))))
    :complete (lambda (req)
                (let ((on-event (plist-get req :on-event)))
                  (run-at-time 0.005 nil
                               (lambda ()
                                 (funcall on-event '(:type text :delta "api"))
                                 (funcall on-event '(:type done :stop-reason end-turn)))))
                (list :cancel #'ignore))))

(defmacro harness-handoff-test-with (&rest body)
  "Load the state layer with the demo and fake providers and the handoff module, run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo tools session agent compaction handoff))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-compaction--running)
     (clrhash harness-handoff--pending)
     (harness-handoff-test--define-providers)
     (setq harness-handoff-test--requests nil)
     (let ((harness-provider-demo--delay 0.005)
           (harness-provider-demo-script-override nil)
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       ,@body)))

(defun harness-handoff-test--session (&optional history)
  "Return a new demo session; with HISTORY, one with an answered exchange."
  (let ((sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted") :id)))
    (when history
      (should (eq 'end-turn (plist-get (harness-test-await (harness-call 'agent/prompt sid "fix the parser"))
                                       :stop-reason))))
    sid))

(defun harness-handoff-test--kinds (sid)
  (mapcar (lambda (n) (plist-get n :kind)) (harness-call 'session/nodes sid)))

(defun harness-handoff-test--last-user-texts (request)
  "Return the texts of REQUEST's last message, a user message."
  (let ((last (car (last (plist-get request :messages)))))
    (should (eq 'user (plist-get last :role)))
    (delq nil (mapcar (lambda (b) (plist-get b :text)) (plist-get last :content)))))

;;;; Checking

(ert-deftest harness-handoff-check-tells-lossy-switches ()
  "Only a switch to another provider's hosted loop that cannot continue the session's history is lossy."
  (harness-handoff-test-with
    (let ((sid (harness-handoff-test--session t))
          (bare (harness-handoff-test--session)))
      (let ((check (harness-call 'handoff/check sid "hosted:m")))
        (should (plist-get check :lossy))
        (should (plist-get check :history))
        (should-not (plist-get check :running))
        (should (equal "demo:scripted" (plist-get check :from)))
        (should (equal "Hosted M" (plist-get check :to-label)))
        (should (string-match-p "\\`Hosted keeps its own conversation" (plist-get check :reason)))
        (should (equal harness-handoff-risks (plist-get check :risks)))
        ;; The four risks: cache, fidelity, provider state, next step.
        (should (= 4 (length (plist-get check :risks))))
        (should (cl-every #'stringp (plist-get check :risks)))
        ;; The cold cache priced at the new model's list prices.
        (should (string-match-p "tokens of context cost about .* to write to the cache" (plist-get check :cache-cost))))
      ;; Same provider, an API provider, the same model: no warning.
      (dolist (model '("demo:other" "api:m" "demo:scripted"))
        (let ((check (harness-call 'handoff/check sid model)))
          (should-not (plist-get check :lossy))
          (should (stringp (plist-get check :reason)))
          (should-not (plist-get check :risks))))
      ;; Nothing the new model would miss.
      (harness-call 'session/append bare '(:kind user :content "an unanswered question"))
      (should-not (plist-get (harness-call 'handoff/check bare "hosted:m") :lossy))
      ;; The new model's provider still holds the conversation: it resumes it.
      (harness-call 'session/set-provider-state sid '(:conv "c0" :provider "hosted"))
      (let ((check (harness-call 'handoff/check sid "hosted:m")))
        (should-not (plist-get check :lossy))
        (should (string-match-p "still holds" (plist-get check :reason))))
      ;; A state of another provider is no help.
      (harness-call 'session/set-provider-state sid '(:conv "c0" :provider "copilot"))
      (should (plist-get (harness-call 'handoff/check sid "hosted:m") :lossy)))))

(ert-deftest harness-handoff-check-all-skips-what-does-not-change ()
  (harness-handoff-test-with
    (let* ((old (harness-handoff-test--session t))
           (bare (harness-handoff-test--session))
           (there (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "hosted:m") :id))
           (checks (harness-call 'handoff/check-all "hosted:m")))
      (should (equal (sort (list old bare) #'string<)
                     (sort (mapcar (lambda (c) (plist-get c :id)) checks) #'string<)))
      (should-not (member there (mapcar (lambda (c) (plist-get c :id)) checks)))
      (should (equal (list old) (mapcar (lambda (c) (plist-get c :id))
                                        (cl-remove-if-not (lambda (c) (plist-get c :lossy)) checks))))
      ;; The filter is `session/set-all''s.
      (should (equal (list bare) (mapcar (lambda (c) (plist-get c :id))
                                         (harness-call 'handoff/check-all "hosted:m" (list :except (list old)))))))))

;;;; Handing over

(ert-deftest harness-handoff-none-only-switches ()
  (harness-handoff-test-with
    (let* ((sid (harness-handoff-test--session t))
           (before (harness-handoff-test--kinds sid))
           (result (harness-test-await (harness-call 'handoff/switch sid "hosted:m" 'none))))
      (should (eq 'none (plist-get result :mode)))
      (should (plist-get result :lossy))
      (should (equal "hosted:m" (plist-get (harness-call 'session/get sid) :model)))
      ;; Only the hint that says so.
      (should (equal (append before '(hint)) (harness-handoff-test--kinds sid))))))

(ert-deftest harness-handoff-transcript-file-and-note ()
  "The transcript goes to a file in the session's directory; a note at the end points at it."
  (harness-handoff-test-with
    (let* ((sid (harness-handoff-test--session t))
           (cwd (plist-get (harness-call 'session/get sid) :cwd))
           (result (harness-test-await (harness-call 'handoff/switch sid "hosted:m" "transcript")))
           (file (plist-get result :file))
           (note (car (last (harness-call 'session/nodes sid)))))
      (should (eq 'transcript (plist-get result :mode)))
      (should (file-in-directory-p file (expand-file-name ".harness/handoff/" cwd)))
      (should (equal "*\n" (harness-read-file (expand-file-name ".harness/handoff/.gitignore" cwd))))
      (let ((text (harness-read-file file)))
        (should (string-match-p "\\`# Conversation handoff" text))
        (should (string-match-p "from demo:scripted to hosted:m" text))
        (should (string-match-p "^\\[user\\] fix the parser$" text)))
      ;; The note: a message of the harness, marked as the handoff.
      (should (eq 'user (plist-get note :kind)))
      (should (equal (plist-get note :id) (plist-get result :node)))
      (should (equal "model handoff" (plist-get (harness-node-sender note) :source)))
      (should (equal (list "transcript" file "demo:scripted" "hosted:m")
                     (let ((h (harness-node-handoff note)))
                       (list (plist-get h :mode) (plist-get h :file) (plist-get h :from) (plist-get h :to)))))
      (should (string-match-p (concat "read " (regexp-quote file)) (plist-get note :content)))
      ;; The handoff is lossy, and the model is told so.
      (should (string-match-p "Harness note: this conversation was handed over from Demo scripted"
                              (plist-get note :content)))
      (should (string-match-p "re-investigate" (plist-get note :content)))
      ;; It is what the new model is sent first, with the user's message after it.
      (harness-test-await (harness-call 'agent/prompt sid "go on"))
      (let ((texts (harness-handoff-test--last-user-texts (car harness-handoff-test--requests))))
        (should (= 2 (length texts)))
        (should (string-match-p (regexp-quote file) (car texts)))
        (should (equal "go on" (cadr texts))))
      ;; The new provider's state is its own, and nothing waits any more.
      (should (equal '(:conv "c1" :provider "hosted") (plist-get (harness-call 'session/get sid) :provider-state)))
      (should (zerop (hash-table-count harness-handoff--pending))))))

(ert-deftest harness-handoff-compact-first ()
  "The summary is made on the old model; the new one starts from it."
  (harness-handoff-test-with
    (let* ((sid (harness-handoff-test--session t))
           (demo-requests nil)
           (result (let ((harness-provider-demo-script-override
                          '((:type text :delta "SUMMARY: fix the parser") (:type done :stop-reason end-turn))))
                     (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                                ((symbol-function 'harness-method/provider/complete)
                                 (lambda (req)
                                   (when (equal "demo:scripted" (plist-get req :model)) (push req demo-requests))
                                   (funcall orig req))))
                       (harness-test-await (harness-call 'handoff/switch sid "hosted:m" 'compact))))))
      (should (eq 'compact (plist-get result :mode)))
      ;; Summarised by the old model, which got the whole conversation.
      (should (= 1 (length demo-requests)))
      (should (string-match-p "handoff summary" (plist-get (car demo-requests) :system)))
      (let ((compaction (cl-find 'compaction (harness-call 'session/nodes sid) :key (lambda (n) (plist-get n :kind)))))
        (should (equal (plist-get compaction :id) (plist-get result :node)))
        (should (equal "hosted:m" (plist-get (harness-node-handoff compaction) :to)))
        (should (equal "compact" (plist-get (harness-node-handoff compaction) :mode)))
        (should (equal "demo:scripted" (plist-get (harness-node-handoff compaction) :summarizer)))
        (should (equal "full" (plist-get (harness-node-handoff compaction) :context)))
        ;; The summary says it is a lossy handoff and to re-investigate.
        (should (string-match-p "Harness note: this conversation was handed over from Demo scripted"
                                (plist-get compaction :content)))
        (should (string-match-p "re-investigate" (plist-get compaction :content))))
      ;; The new model's first message: the summary, then the user's.
      (harness-test-await (harness-call 'agent/prompt sid "go on"))
      (let ((request (car harness-handoff-test--requests)))
        (should (= 1 (length (plist-get request :messages))))
        (let ((texts (harness-handoff-test--last-user-texts request)))
          (should (string-prefix-p "Summary of the conversation so far:\n\nSUMMARY: fix the parser" (car texts)))
          (should (string-match-p "re-investigate" (car texts)))
          (should (equal "go on" (car (last texts)))))))))

(ert-deftest harness-handoff-compact-new-summarises-on-the-new-model ()
  "The new model writes the summary when the old one cannot, from a bounded context.
Only the first and last messages of the session go to it, and the
summary it writes opens the new conversation with a lossy-handoff note."
  (harness-handoff-test-with
    (let ((sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                        :model "demo:scripted")
                          :id)))
      (dotimes (i 20)
        (harness-call 'session/append sid (list :kind (if (cl-evenp i) 'user 'assistant)
                                                :content (format "message %d" i))))
      (let ((result (harness-test-await (harness-call 'handoff/switch sid "hosted:m" 'compact-new))))
        (should (eq 'compact-new (plist-get result :mode)))
        (should (equal "hosted:m" (plist-get result :summarizer)))
        (should (eq 'sample (plist-get result :context)))
        (should (equal "hosted:m" (plist-get (harness-call 'session/get sid) :model)))
        ;; The new model got one message of text: the start and end of the
        ;; conversation, with what was left out said so.
        (should (= 1 (length harness-handoff-test--requests)))
        (let* ((request (car harness-handoff-test--requests))
               (texts (harness-handoff-test--last-user-texts request)))
          (should (equal "hosted:m" (plist-get request :model)))
          (should-not (plist-get request :provider-state))
          (should (= 2 (length texts)))
          (let ((text (car texts)))
            (dolist (i '(0 3 8 19)) (should (string-match-p (format "message %d" i) text)))
            (dolist (i '(4 5 6 7)) (should-not (string-match-p (format "message %d" i) text)))
            (should (string-match-p "left out the 4 messages" text)))
          (should (string-match-p "Summarize the conversation above" (cadr texts))))
        ;; Its summary opens the session, marked as a lossy handoff.
        (let ((compaction (cl-find 'compaction (harness-call 'session/nodes sid)
                                   :key (lambda (n) (plist-get n :kind)))))
          (should (string-prefix-p "ok" (plist-get compaction :content)))
          (should (string-match-p "Harness note: this conversation was handed over from Demo scripted"
                                  (plist-get compaction :content)))
          (should (string-match-p "re-investigate" (plist-get compaction :content)))
          (let ((handoff (harness-node-handoff compaction)))
            (should (equal "compact-new" (plist-get handoff :mode)))
            (should (equal "sample" (plist-get handoff :context)))
            (should (equal "hosted:m" (plist-get handoff :summarizer)))))))))

(ert-deftest harness-handoff-compact-falls-back-to-the-transcript ()
  "When the old model cannot summarise -- its plan ran out, say -- the transcript goes over."
  (harness-handoff-test-with
    (let* ((sid (harness-handoff-test--session t))
           (result (let ((harness-provider-demo-script-override
                          '((:type done :stop-reason error :error "quota exhausted"))))
                     (harness-test-await (harness-call 'handoff/switch sid "hosted:m" 'compact)))))
      (should (eq 'transcript (plist-get result :mode)))
      (should (equal "quota exhausted" (plist-get result :fallback)))
      (should (file-exists-p (plist-get result :file)))
      (should-not (memq 'compaction (harness-handoff-test--kinds sid)))
      (should (cl-some (lambda (n) (string-match-p "No summary from Demo scripted (quota exhausted)"
                                                   (or (plist-get n :content) "")))
                       (harness-call 'session/nodes sid)))
      (should (harness-node-handoff (car (last (harness-call 'session/nodes sid))))))))

(ert-deftest harness-handoff-waits-for-the-next-step-of-a-running-turn ()
  "Switched while a turn runs, the handoff lands after that step's tool results.
The new model takes over at the next step, whose trailing user message
is the note: a hosted loop sent only tool results starts with nothing."
  (harness-handoff-test-with
    (let* ((sid (harness-handoff-test--session t))
           (switched nil))
      (harness-define-tool "look" :label "Look" :description "Look." :handler (lambda (_i _c) "looked"))
      (harness-on 'agent/tool-call
                  (lambda (id _node)
                    (unless switched
                      (setq switched (harness-call 'handoff/switch id "hosted:m" 'transcript)))))
      (let ((harness-provider-demo-script-override
             '((:type text :delta "Looking.") (:type tool-call :id "c1" :name "look" :input nil))))
        (should (eq 'end-turn (plist-get (harness-test-await (harness-call 'agent/prompt sid "look again"))
                                         :stop-reason))))
      (let ((result (harness-test-await switched)))
        (should (plist-get result :deferred))
        (should (eq 'transcript (plist-get result :mode))))
      (let* ((nodes (harness-call 'session/nodes sid))
             (note (cl-find-if #'harness-node-handoff nodes))
             (result (cl-find 'tool-result nodes :key (lambda (n) (plist-get n :kind)) :from-end t)))
        (should note)
        (should (< (cl-position result nodes) (cl-position note nodes)))
        ;; The hosted model's first step got the note last, after the result.
        (let* ((request (car (last harness-handoff-test--requests)))
               (last (car (last (plist-get request :messages)))))
          (should (= 1 (length harness-handoff-test--requests)))
          (should (equal "tool_result" (plist-get (car (plist-get last :content)) :type)))
          (should (equal (plist-get note :content) (plist-get (car (last (plist-get last :content))) :text))))
        ;; The step the switch came in was the old model's.
        (should (equal "demo:scripted"
                       (plist-get (plist-get (cl-find "Looking." nodes :key (lambda (n) (plist-get n :content))
                                                      :test #'equal)
                                             :meta)
                                  :model)))))))

(ert-deftest harness-handoff-compact-mid-turn ()
  "A summary asked for during a turn is made at its next step, before the new model's."
  (harness-handoff-test-with
    (let* ((sid (harness-handoff-test--session t))
           (switched nil))
      (harness-define-tool "look" :label "Look" :description "Look." :handler (lambda (_i _c) "looked"))
      (harness-on 'agent/tool-call
                  (lambda (id _node)
                    (unless switched
                      (setq switched (harness-call 'handoff/switch id "hosted:m" 'compact))
                      ;; The summariser's script, for the step boundary.
                      (setq harness-provider-demo-script-override
                            '((:type text :delta "SUMMARY: looked") (:type done :stop-reason end-turn))))))
      (let ((harness-provider-demo-script-override
             '((:type text :delta "Looking.") (:type tool-call :id "c1" :name "look" :input nil))))
        (harness-test-await (harness-call 'agent/prompt sid "look again"))
        (should (plist-get (harness-test-await switched) :deferred))
        (let* ((request (car (last harness-handoff-test--requests)))
               (messages (plist-get request :messages)))
          (should (= 1 (length messages)))
          (should (string-prefix-p "Summary of the conversation so far:\n\nSUMMARY: looked"
                                   (car (harness-handoff-test--last-user-texts request)))))
        (should (memq 'compaction (harness-handoff-test--kinds sid)))))))

(ert-deftest harness-handoff-pending-goes-with-a-switch-elsewhere ()
  "A handoff waiting for a model the session has left again is dropped."
  (harness-handoff-test-with
    (let* ((sid (harness-handoff-test--session t))
           (done nil))
      (harness-define-tool "look" :label "Look" :description "Look." :handler (lambda (_i _c) "looked"))
      (harness-on 'agent/tool-call
                  (lambda (id _node)
                    (unless done
                      (setq done t)
                      (harness-call 'handoff/switch id "hosted:m" 'transcript)
                      (harness-call 'handoff/switch id "api:m"))))
      (let ((harness-provider-demo-script-override
             '((:type text :delta "Looking.") (:type tool-call :id "c1" :name "look" :input nil))))
        (harness-test-await (harness-call 'agent/prompt sid "look again")))
      (should-not (cl-find-if #'harness-node-handoff (harness-call 'session/nodes sid)))
      (should-not harness-handoff-test--requests)
      (should (zerop (hash-table-count harness-handoff--pending)))
      (should (equal "api" (plist-get (car (last (harness-call 'session/nodes sid))) :content))))))

(ert-deftest harness-handoff-switch-all-hands-over-the-lossy-ones ()
  (harness-handoff-test-with
    (let* ((old (harness-handoff-test--session t))
           (bare (harness-handoff-test--session))
           (ids (harness-call 'handoff/switch-all "hosted:m" nil 'transcript)))
      (should (equal (sort (list old bare) #'string<) (sort (copy-sequence ids) #'string<)))
      (dolist (id ids)
        (should (equal "hosted:m" (plist-get (harness-call 'session/get id) :model))))
      (harness-test-wait (lambda () (zerop (hash-table-count harness-handoff--pending))) 5 "the handoffs")
      (should (harness-node-handoff (car (last (harness-call 'session/nodes old)))))
      (should-not (cl-find-if #'harness-node-handoff (harness-call 'session/nodes bare)))
      ;; Nothing left to change.
      (should-not (harness-call 'handoff/switch-all "hosted:m")))))

(ert-deftest harness-handoff-over-acp ()
  "A client checks and switches with string arguments, as the UI does."
  (harness-handoff-test-with
    (let ((harness-acp--server-enabled nil))
      (harness-test-load-module 'acp))
    (let* ((conn (harness-acp-connect))
           (sid (harness-handoff-test--session t)))
      (unwind-protect
          (let ((check (harness-test-await (harness-acp-request conn "_harness/handoff/check"
                                                                (list :sessionId sid :model "hosted:m")))))
            (should (harness-json-true-p (plist-get check :lossy)))
            (should (= 4 (length (plist-get check :risks))))
            (let ((result (harness-test-await (harness-acp-request conn "_harness/handoff/switch"
                                                                   (list :sessionId sid :model "hosted:m"
                                                                         :mode "transcript")))))
              (should (equal "transcript" (plist-get result :mode)))
              (should (file-exists-p (plist-get result :file)))))
        (dolist (c (copy-sequence harness-acp--clients))
          (harness-acp--drop-client c))))))

(provide 'harness-handoff-test)
;;; harness-handoff-test.el ends here
