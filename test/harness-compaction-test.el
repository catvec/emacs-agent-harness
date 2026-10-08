;;; harness-compaction-test.el --- Tests for compaction  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
(defvar harness-compaction--context-reserve)
(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent--turns)
(defvar harness-compaction--running)
(declare-function harness-define-provider "harness-provider")
(declare-function harness-compaction-needed-p "harness-compaction")
(declare-function harness-compaction-hosted-p "harness-compaction")

(defmacro harness-compaction-test-with (&rest body)
  "Load the state layer with the demo provider and compaction, run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo tools session agent compaction))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-compaction--running)
     (let ((harness-provider-demo--delay 0.005)
           (harness-provider-demo-script-override nil)
           (harness-compaction--context-reserve 1000)
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       ,@body)))

(defconst harness-compaction-test-script
  '((:type text :delta "SUMMARY ") (:type text :delta "TEXT") (:type done :stop-reason end-turn)))

(defun harness-compaction-test-session (&rest plist)
  "Create a demo session (window 8000) with one answered exchange."
  (let ((id (plist-get (apply #'harness-call 'session/create :cwd (harness-test-temp-dir)
                              :model "demo:scripted" :context-window 8000 plist)
                       :id)))
    (harness-call 'session/append id '(:kind user :content "please refactor the parser"))
    (harness-call 'session/append id '(:kind assistant :content "Done: parser.el rewritten"))
    id))

(defun harness-compaction-test-kinds (id)
  (mapcar (lambda (n) (plist-get n :kind)) (harness-call 'session/nodes id)))

(defun harness-compaction-test-hints (id)
  (mapcar (lambda (n) (plist-get n :content))
          (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'hint)) (harness-call 'session/nodes id))))

(defun harness-compaction-test-first-text (id)
  (plist-get (car (plist-get (car (harness-call 'session/messages id)) :content)) :text))

(defun harness-compaction-test-long-session ()
  "Create a demo session with twenty alternating messages."
  (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                     :model "demo:scripted" :context-window 8000)
                       :id)))
    (dotimes (i 20)
      (harness-call 'session/append id (list :kind (if (cl-evenp i) 'user 'assistant)
                                             :content (format "message %d" i))))
    id))

(defun harness-compaction-test-request-text (request)
  "Return all the text of REQUEST's messages, in order."
  (mapconcat (lambda (m)
               (mapconcat (lambda (b) (or (plist-get b :text) "")) (plist-get m :content) "\n"))
             (plist-get request :messages) "\n"))

(ert-deftest harness-compaction-compact-appends-summary-node ()
  (harness-compaction-test-with
    (let* ((id (harness-compaction-test-session))
           (old-head (plist-get (harness-call 'session/get id) :head))
           (harness-provider-demo-script-override harness-compaction-test-script)
           (requests nil) (done nil))
      (harness-on 'compaction/done (lambda (sid node) (push (list sid (plist-get node :id)) done)))
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req) (push req requests) (funcall orig req))))
        (let ((node (harness-await (harness-call 'compaction/compact id))))
          (should (eq 'compaction (plist-get node :kind)))
          (should (equal "SUMMARY TEXT" (plist-get node :content)))
          (should (equal old-head (plist-get (plist-get node :meta) :compacted-head)))
          (should (equal "demo:scripted" (plist-get (plist-get node :meta) :model)))
          (should (eq 'full (plist-get (plist-get node :meta) :context)))
          (should (numberp (plist-get (plist-get node :meta) :input-tokens)))
          (should (equal (list (list id (plist-get node :id))) done))))
      ;; The request: no tools, no provider state, transcript then the ask.
      (should (= 1 (length requests)))
      (let* ((req (car requests))
             (last (car (last (plist-get req :messages)))))
        (should (null (plist-get req :tools)))
        (should (null (plist-get req :provider-state)))
        (should (string-match-p "handoff summary" (plist-get req :system)))
        (should (eq 'user (plist-get last :role)))
        (should (string-match-p "Summarize the conversation above"
                                (plist-get (car (last (plist-get last :content))) :text)))
        (should (= 3 (length (plist-get req :messages)))))
      ;; Transcript: hints around the node, messages restart at the summary.
      (should (equal '(user assistant hint compaction hint) (harness-compaction-test-kinds id)))
      (should (equal "Compacting context…" (car (harness-compaction-test-hints id))))
      (should (string-match-p "\\`Compacted: [0-9.k]+ tokens → summary\\'" (cadr (harness-compaction-test-hints id))))
      (should (= 1 (length (harness-call 'session/messages id))))
      (should (string-prefix-p "Summary of the conversation so far:\n\nSUMMARY TEXT"
                               (harness-compaction-test-first-text id)))
      (should (= (harness-estimate-tokens "SUMMARY TEXT")
                 (plist-get (plist-get (harness-call 'session/get id) :usage) :context)))
      (should (zerop (hash-table-count harness-compaction--running))))))

(ert-deftest harness-compaction-starts-the-cache-over ()
  "A compaction leaves nothing cached: the conversation goes on from its summary.
What the summariser's request read from the cache is counted, but it
stamps no cache, and the old one's stamp goes: the next request sends
the summary uncached, and none of what was cached before."
  (harness-compaction-test-with
    (let* ((id (harness-compaction-test-session))
           (harness-provider-demo-script-override
            '((:type text :delta "SUMMARY")
              (:type usage :input 20 :output 5 :cache-read 400 :cache-at 2000.0 :cache-ttl 3600)
              (:type done :stop-reason end-turn))))
      (harness-call 'session/usage-add id '(:input 10 :output 10 :cache-read 400 :context 420
                                             :cache-at 1000.0))
      (should (plist-get (harness-call 'session/get id) :cache))
      (harness-await (harness-call 'compaction/compact id))
      (let ((s (harness-call 'session/get id)))
        (should-not (plist-get s :cache))
        (should (= 800 (plist-get (plist-get s :usage) :cache-read)))
        (should-not (plist-member (plist-get s :usage) :cache-at))))))

(ert-deftest harness-compaction-hosted-summary-on-a-fork ()
  "A summariser that keeps the conversation itself works on a fork of the session's.
A hosted loop is sent only the newest user messages, so without the
conversation it would summarise nothing; on a fork it has all of it,
and the session's own conversation is left alone.  A state of another
provider is never forked."
  (harness-compaction-test-with
    (let ((requests nil) (forks nil))
      (harness-define-provider 'forky
        :complete (lambda (req)
                    (push req requests)
                    (let ((on-event (plist-get req :on-event)))
                      (run-at-time 0.005 nil (lambda ()
                                               (funcall on-event '(:type text :delta "SUMMARY"))
                                               (funcall on-event '(:type done :stop-reason end-turn)))))
                    (list :cancel #'ignore))
        :fork (lambda (model state)
                (push (list model state) forks)
                (harness-resolved (list :conv (plist-get state :conv) :fork-pending t)))
        :capabilities '(:hosted-loop t :fork t :compaction hosted))
      (let ((id (harness-compaction-test-session)))
        (harness-call 'session/update id :model "forky:m" :silent t)
        (harness-call 'session/set-provider-state id '(:conv "c9" :provider "forky"))
        (should (equal "SUMMARY" (plist-get (harness-await (harness-call 'compaction/compact id)) :content)))
        (should (equal '(("forky:m" (:conv "c9" :provider "forky"))) forks))
        (should (equal '(:conv "c9" :fork-pending t :provider "forky") (plist-get (car requests) :provider-state)))
        (should (equal '(:conv "c9" :provider "forky") (plist-get (harness-call 'session/get id) :provider-state)))
        ;; A sampled context is not forked: the summariser gets the sample.
        (setq forks nil)
        (harness-await (harness-call 'compaction/compact id (list :context "sample")))
        (should-not forks)
        (should-not (plist-get (car requests) :provider-state))
        ;; Another provider's state: no fork, no state.
        (harness-call 'session/set-provider-state id '(:conv "c9" :provider "other"))
        (setq forks nil)
        (harness-await (harness-call 'compaction/compact id))
        (should-not forks)
        (should-not (plist-get (car requests) :provider-state))))))

(ert-deftest harness-compaction-hosted-conversation-keeps-its-cache ()
  "A hosted loop that summarises a fork of its own conversation keeps that cache.
The session's provider goes on with the conversation, which the summary
only joins, so the summariser's request stamps the cache as any request
does.  Summarised from a sample, or by another model, the conversation
starts over instead, and the stamp goes."
  (harness-compaction-test-with
    (harness-define-provider 'forky
      :complete (lambda (req)
                  (let ((on-event (plist-get req :on-event)))
                    (run-at-time 0.005 nil
                                 (lambda ()
                                   (funcall on-event '(:type text :delta "SUMMARY"))
                                   (funcall on-event '(:type usage :input 20 :output 5 :cache-read 400
                                                             :cache-at 2000.0 :cache-ttl 3600))
                                   (funcall on-event '(:type done :stop-reason end-turn)))))
                  (list :cancel #'ignore))
      :fork (lambda (_model state)
              (harness-resolved (list :conv (plist-get state :conv) :fork-pending t)))
      :capabilities '(:hosted-loop t :fork t :compaction hosted))
    (let ((id (harness-compaction-test-session))
          (stamp (lambda (id)
                   (harness-call 'session/usage-add id '(:input 10 :output 10 :cache-read 400 :context 420
                                                          :cache-at 1000.0 :cache-ttl 3600)))))
      (harness-call 'session/update id :model "forky:m" :silent t)
      (harness-call 'session/set-provider-state id '(:conv "c9" :provider "forky"))
      (funcall stamp id)
      (harness-await (harness-call 'compaction/compact id))
      (should (equal '(:at 2000.0 :ttl 3600 :expires 5600.0 :model "forky:m")
                     (plist-get (harness-call 'session/get id) :cache)))
      ;; A sample: the summariser had none of the conversation.
      (funcall stamp id)
      (harness-await (harness-call 'compaction/compact id (list :context "sample")))
      (should-not (plist-get (harness-call 'session/get id) :cache))
      ;; Another model, though on a fork of the same provider's state.
      (funcall stamp id)
      (harness-await (harness-call 'compaction/compact id (list :model "forky:n")))
      (should-not (plist-get (harness-call 'session/get id) :cache)))))

(ert-deftest harness-compaction-sample-keeps-the-start-and-the-end ()
  "A `sample' context sends only the first and last messages, and says what it left out."
  (harness-compaction-test-with
    (let* ((id (harness-compaction-test-long-session))
           (harness-provider-demo-script-override harness-compaction-test-script)
           (requests nil))
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req) (push req requests) (funcall orig req))))
        (let* ((node (harness-await (harness-call 'compaction/compact id (list :context "sample"))))
               (text (harness-compaction-test-request-text (car requests))))
          (should (eq 'sample (plist-get (plist-get node :meta) :context)))
          ;; Four kept from the start, twelve from the end, an elision between.
          (should (= 18 (length (plist-get (car requests) :messages))))
          (dolist (i '(0 3 8 19)) (should (string-match-p (format "message %d" i) text)))
          (dolist (i '(4 5 6 7)) (should-not (string-match-p (format "message %d" i) text)))
          (should (string-match-p "left out the 4 messages" text))
          (should (string-match-p "Summarize the conversation above" text)))))
    ;; An unknown context is refused.
    (should-error (harness-await (harness-call 'compaction/compact
                                               (harness-compaction-test-long-session)
                                               (list :context "sideways"))))))

(ert-deftest harness-compaction-hosted-summariser-without-state-gets-text ()
  "A hosted summariser with no provider state of the session is sent the context as one message.
Claude Code and Copilot are sent only the newest user messages, so
messages carrying the whole transcript would never reach one; the
context goes inside a single message of structured text instead."
  (harness-compaction-test-with
    (let ((requests nil))
      (harness-define-provider 'hostedsum
        :complete (lambda (req)
                    (push req requests)
                    (let ((on-event (plist-get req :on-event)))
                      (run-at-time 0.005 nil (lambda ()
                                               (funcall on-event '(:type text :delta "SUMMARY"))
                                               (funcall on-event '(:type done :stop-reason end-turn)))))
                    (list :cancel #'ignore))
        :capabilities '(:hosted-loop t :compaction hosted))
      (let ((id (harness-compaction-test-long-session)))
        (let ((node (harness-await (harness-call 'compaction/compact id (list :model "hostedsum:m"))))
              (text (harness-compaction-test-request-text (car requests)))
              (messages (plist-get (car requests) :messages)))
          (should (eq 'full (plist-get (plist-get node :meta) :context)))
          (should-not (plist-get (car requests) :provider-state))
          (should (= 1 (length messages)))
          (should (eq 'user (plist-get (car messages) :role)))
          (should (string-match-p "### user" text))
          (should (string-match-p "### assistant" text))
          (dolist (i '(0 4 19)) (should (string-match-p (format "message %d" i) text)))
          (should (string-match-p "Summarize the conversation above" text))))
      ;; The same inlining carries a sampled context.
      (setq requests nil)
      (let* ((id (harness-compaction-test-long-session))
             (node (harness-await (harness-call 'compaction/compact
                                                id (list :model "hostedsum:m" :context "sample"))))
             (text (harness-compaction-test-request-text (car requests))))
        (should (eq 'sample (plist-get (plist-get node :meta) :context)))
        (should (= 1 (length (plist-get (car requests) :messages))))
        (dolist (i '(0 3 8 19)) (should (string-match-p (format "message %d" i) text)))
        (dolist (i '(4 5 6 7)) (should-not (string-match-p (format "message %d" i) text)))
        (should (string-match-p "left out the 4 messages" text))))))

(ert-deftest harness-compaction-compact-error-rejects ()
  (harness-compaction-test-with
    (let* ((id (harness-compaction-test-session))
           (harness-provider-demo-script-override '((:type done :stop-reason error :error "boom")))
           (failed nil))
      (harness-on 'compaction/failed (lambda (sid msg) (push (list sid msg) failed)))
      (should-error (harness-await (harness-call 'compaction/compact id)))
      (should (equal '(user assistant hint hint) (harness-compaction-test-kinds id)))
      (should (equal "Compaction failed: boom" (cadr (harness-compaction-test-hints id))))
      (should (equal (list (list id "boom")) failed))
      (should (zerop (hash-table-count harness-compaction--running))))))

(ert-deftest harness-compaction-compact-runs-once-per-session ()
  (harness-compaction-test-with
    (let* ((id (harness-compaction-test-session))
           (harness-provider-demo-script-override harness-compaction-test-script)
           (calls 0))
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req) (cl-incf calls) (funcall orig req))))
        (let ((p1 (harness-call 'compaction/compact id))
              (p2 (harness-call 'compaction/compact id)))
          (should (eq p1 p2))
          (harness-await p1)))
      (should (= 1 calls))
      (should (= 1 (cl-count 'compaction (harness-compaction-test-kinds id)))))))

(ert-deftest harness-compaction-status-levels ()
  (harness-compaction-test-with
    (let ((id (harness-compaction-test-session)))
      (cl-flet ((status-at (context)
                  (harness-call 'session/usage-add id (list :context context))
                  (harness-call 'compaction/status id)))
        (let ((s (status-at 1000)))
          (should (= 8000 (plist-get s :window)))
          (should (= 1000 (plist-get s :reserve)))
          (should (= 7000 (plist-get s :usable)))
          (should (= 1000 (plist-get s :context)))
          (should (< (abs (- (plist-get s :fraction) (/ 1000.0 7000))) 1e-6))
          (should (eq 'ok (plist-get s :level))))
        (should (eq 'warning (plist-get (status-at 5000) :level)))
        (should (eq 'urgent (plist-get (status-at 6000) :level)))
        (should (eq 'critical (plist-get (status-at 6900) :level)))
        (should (eq 'critical (plist-get (status-at 9000) :level)))))))

(ert-deftest harness-compaction-status-caps-reserve-for-small-windows ()
  (harness-compaction-test-with
    (let* ((harness-compaction--context-reserve 20000)
           (id (harness-compaction-test-session))
           (s (harness-call 'compaction/status id)))
      (should (= 4000 (plist-get s :usable)))
      (should (eq 'ok (plist-get s :level)))
      (should-not (harness-compaction-needed-p (harness-call 'session/get id))))))

(ert-deftest harness-compaction-context-limit-shortens-the-window ()
  "A session capped below its model's window compacts at the cap."
  (harness-compaction-test-with
    (let* ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                        :model "demo:scripted" :context-window-limit 4000)
                          :id))
           (harness-provider-demo-script-override harness-compaction-test-script))
      (harness-call 'session/append id '(:kind user :content "please refactor the parser"))
      (harness-call 'session/append id '(:kind assistant :content "Done: parser.el rewritten"))
      ;; Half of the demo model's 8000, less the test's 1000-token reserve.
      (let ((s (harness-call 'compaction/status id)))
        (should (= 4000 (plist-get s :window)))
        (should (= 3000 (plist-get s :usable))))
      ;; 3500 tokens compacts under the 4000 cap, where a session with
      ;; the whole 8000 window would not.
      (harness-call 'session/usage-add id '(:context 3500))
      (should (harness-compaction-needed-p (harness-call 'session/get id)))
      (harness-await (harness-call 'agent/prompt id "carry on"))
      (should (member 'compaction (harness-compaction-test-kinds id))))))

(ert-deftest harness-compaction-auto-compacts-before-turn ()
  (harness-compaction-test-with
    (let* ((id (harness-compaction-test-session))
           (harness-provider-demo-script-override harness-compaction-test-script)
           (requests nil))
      (harness-call 'session/usage-add id '(:context 7500))
      (should (harness-compaction-needed-p (harness-call 'session/get id)))
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req) (push req requests) (funcall orig req))))
        (should (eq 'end-turn (plist-get (harness-await (harness-call 'agent/prompt id "next question"))
                                         :stop-reason))))
      (setq requests (nreverse requests))
      (should (= 2 (length requests)))
      ;; First the summariser, then the turn, whose transcript starts at the summary
      ;; and still carries the user's new message.
      (should (null (plist-get (car requests) :tools)))
      (let* ((turn (cadr requests))
             (first (car (plist-get turn :messages)))
             (texts (mapcar (lambda (b) (plist-get b :text)) (plist-get first :content))))
        (should (eq 'user (plist-get first :role)))
        (should (string-prefix-p "Summary of the conversation so far:\n\nSUMMARY TEXT" (car texts)))
        (should (member "next question" texts)))
      (should (equal '(user assistant hint compaction hint user assistant)
                     (harness-compaction-test-kinds id)))
      ;; The user's message follows the compaction node exactly once.
      (should (equal "next question" (plist-get (nth 5 (harness-call 'session/nodes id)) :content)))
      (should (eq 'idle (plist-get (harness-call 'session/get id) :status)))
      (should (< (plist-get (plist-get (harness-call 'session/get id) :usage) :context) 7000)))))

(ert-deftest harness-compaction-auto-idle-below-threshold ()
  (harness-compaction-test-with
    (let ((id (harness-compaction-test-session)))
      (harness-call 'session/usage-add id '(:context 6999))
      (harness-await (harness-call 'agent/prompt id "hello"))
      (should-not (memq 'compaction (harness-compaction-test-kinds id))))))

(ert-deftest harness-compaction-auto-skips-hosted-providers ()
  (harness-compaction-test-with
    (let ((completes 0))
      (harness-define-provider 'hostedfake
        :label "Hosted fake"
        :complete (lambda (req)
                    (cl-incf completes)
                    (let ((on-event (plist-get req :on-event)))
                      (run-at-time 0.005 nil
                                   (lambda ()
                                     (funcall on-event '(:type text :delta "ok"))
                                     (funcall on-event '(:type done :stop-reason end-turn)))))
                    (list :cancel #'ignore))
        :capabilities '(:hosted-loop t :compaction hosted))
      (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                         :model "hostedfake:m" :context-window 8000)
                           :id)))
        (harness-call 'session/usage-add id '(:context 7500))
        (should (harness-compaction-needed-p (harness-call 'session/get id)))
        (should (harness-compaction-hosted-p (harness-call 'session/get id)))
        (harness-await (harness-call 'agent/prompt id "hello"))
        (should (= 1 completes))
        (should (equal '(user assistant) (harness-compaction-test-kinds id)))))))

(ert-deftest harness-compaction-auto-proceeds-when-compaction-fails ()
  (harness-compaction-test-with
    (let* ((id (harness-compaction-test-session))
           (harness-provider-demo-script-override '((:type done :stop-reason error :error "boom")))
           (started 0))
      (harness-on 'agent/turn-started (lambda (_) (cl-incf started)))
      (harness-call 'session/usage-add id '(:context 7500))
      (harness-await (harness-call 'agent/prompt id "hello"))
      (should (= 1 started))
      (should (member "Compaction failed: boom" (harness-compaction-test-hints id)))
      (should-not (memq 'compaction (harness-compaction-test-kinds id))))))

(provide 'harness-compaction-test)
;;; harness-compaction-test.el ends here
