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
(defvar harness-compaction-kind)
(defvar harness-compaction-brief-model)
(defvar harness-compaction--request-text)
(defvar harness-compaction--summary-output)
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
        ;; The summary replaced the conversation the session's provider held.
        (should-not (plist-get (harness-call 'session/get id) :provider-state))
        ;; A sampled context is not forked: the summariser gets the sample.
        (harness-call 'session/set-provider-state id '(:conv "c9" :provider "forky"))
        (setq forks nil)
        (harness-await (harness-call 'compaction/compact id (list :context "sample")))
        (should-not forks)
        (should-not (plist-get (car requests) :provider-state))
        ;; Another provider's state: no fork, no state, and it stays.
        (harness-call 'session/set-provider-state id '(:conv "c9" :provider "other"))
        (setq forks nil)
        (harness-await (harness-call 'compaction/compact id))
        (should-not forks)
        (should-not (plist-get (car requests) :provider-state))
        (should (equal '(:conv "c9" :provider "other")
                       (plist-get (harness-call 'session/get id) :provider-state)))))))

(ert-deftest harness-compaction-hosted-conversation-starts-over ()
  "A hosted loop's compacted conversation starts over from the compaction.
Kept, it would take the summary as one more message of the whole
conversation, read back uncached once its cache lapsed: its provider
state goes, which tells its provider to let its process go too, and so
does the cache stamp, however the summary was made."
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
          (changed nil)
          (stamp (lambda (id)
                   (harness-call 'session/set-provider-state id '(:conv "c9" :provider "forky"))
                   (harness-call 'session/usage-add id '(:input 10 :output 10 :cache-read 400 :context 420
                                                          :cache-at 1000.0 :cache-ttl 3600)))))
      (harness-call 'session/update id :model "forky:m" :silent t)
      (harness-on 'session/provider-state-changed (lambda (sid state) (push (list sid state) changed)))
      (dolist (opts (list nil (list :kind "brief") (list :model "forky:n") (list :kind "transcript")))
        (funcall stamp id)
        (should (plist-get (harness-call 'session/get id) :cache))
        (setq changed nil)
        (harness-await (harness-call 'compaction/compact id opts))
        (should-not (plist-get (harness-call 'session/get id) :provider-state))
        (should (equal (list (list id nil)) changed))
        (should-not (plist-get (harness-call 'session/get id) :cache))))))

(defun harness-compaction-test-tiered-provider (&optional capabilities complete)
  "Define provider `tiered': a dear \"big\" model and a cheap \"small\" one.
CAPABILITIES are its capabilities; COMPLETE its completion function,
by default one that answers SUMMARY."
  (harness-define-provider 'tiered
    :label "Tiered"
    :models (lambda ()
              (harness-resolved
               (list (list :name "big" :label "Big" :context-window 200000
                           :pricing '(:input 10.0 :output 50.0 :cache-read 1.0 :cache-write 12.5))
                     (list :name "small" :label "Small" :context-window 200000
                           :pricing '(:input 1.0 :output 5.0 :cache-read 0.1 :cache-write 1.25)))))
    :complete (or complete
                  (lambda (req)
                    (let ((on-event (plist-get req :on-event)))
                      (run-at-time 0.005 nil (lambda ()
                                               (funcall on-event '(:type text :delta "SUMMARY"))
                                               (funcall on-event '(:type done :stop-reason end-turn)))))
                    (list :cancel #'ignore)))
    :capabilities capabilities))

(ert-deftest harness-compaction-brief-summary ()
  "A brief summary is the cheap model's, of a sample, and ends saying what it lacks.
It is a handoff's `compact-new' on the session's own provider: the
cheap tier of the session's provider writes it from the first and last
messages, whatever the session's model is."
  (harness-compaction-test-with
    (let ((requests nil))
      (harness-compaction-test-tiered-provider
       nil (lambda (req)
             (push req requests)
             (let ((on-event (plist-get req :on-event)))
               (run-at-time 0.005 nil (lambda ()
                                        (funcall on-event '(:type text :delta "BRIEF"))
                                        (funcall on-event '(:type done :stop-reason end-turn)))))
             (list :cancel #'ignore)))
      (let* ((id (harness-compaction-test-long-session))
             (_ (harness-call 'session/update id :model "tiered:big" :silent t))
             (node (harness-await (harness-call 'compaction/compact id (list :kind "brief"))))
             (meta (plist-get node :meta)))
        (should (equal "tiered:small" (plist-get (car requests) :model)))
        (should (= 18 (length (plist-get (car requests) :messages))))
        (should (equal "brief" (plist-get meta :compaction)))
        (should (equal "brief" (harness-node-compaction-kind node)))
        (should (eq 'sample (plist-get meta :context)))
        (should (equal "tiered:small" (plist-get meta :model)))
        (should (string-prefix-p "BRIEF\n\nHarness note: Small wrote this summary from only the first and the most recent messages"
                                 (plist-get node :content)))
        (should (equal "Compacting context: a brief summary by Small…" (car (harness-compaction-test-hints id))))
        (should (string-match-p "\\`Compacted: [0-9.k]+ tokens → brief summary\\'"
                                (cadr (harness-compaction-test-hints id))))
        (should (string-prefix-p "Summary of the conversation so far:\n\nBRIEF\n\nHarness note:"
                                 (harness-compaction-test-first-text id))))
      ;; A sample alone is a brief summary too, and the caveat can go.
      (setq requests nil)
      (let* ((id (harness-compaction-test-long-session))
             (_ (harness-call 'session/update id :model "tiered:big" :silent t))
             (node (harness-await (harness-call 'compaction/compact id (list :context "sample" :caveat nil)))))
        (should (equal "brief" (plist-get (plist-get node :meta) :compaction)))
        (should (equal "BRIEF" (plist-get node :content))))
      ;; The setting picks the model: the session's own, or one named.
      (dolist (case '((nil . "tiered:big") ("tiered:big" . "tiered:big") (auto . "tiered:small")))
        (setq requests nil)
        (let ((harness-compaction-brief-model (car case))
              (id (harness-compaction-test-long-session)))
          (harness-call 'session/update id :model "tiered:big" :silent t)
          (harness-await (harness-call 'compaction/compact id (list :kind 'brief)))
          (should (equal (cdr case) (plist-get (car requests) :model)))))
      ;; A provider with no cheaper model writes it with the session's.
      (setq requests nil)
      (let ((id (harness-compaction-test-long-session))
            (harness-provider-demo-script-override harness-compaction-test-script))
        (should (string-prefix-p "SUMMARY TEXT\n\nHarness note: Demo scripted wrote"
                                 (plist-get (harness-await (harness-call 'compaction/compact id (list :kind "brief")))
                                            :content)))))
    ;; An unknown kind is refused.
    (should-error (harness-await (harness-call 'compaction/compact (harness-compaction-test-session)
                                               (list :kind "sideways"))))))

(ert-deftest harness-compaction-by-hand-waits-for-the-turn ()
  "Compacting by hand (OPTS `:idle') refuses a session running a turn,
which would go on writing after the conversation the compaction
replaces.  Automatic compaction runs inside the turn, and does not ask."
  (harness-compaction-test-with
    (let ((id (harness-compaction-test-session)))
      (puthash id (list :fake-turn t) harness-agent--turns)
      (unwind-protect
          (progn
            (should (harness-call 'agent/running id))
            (let ((err (should-error (harness-call 'compaction/compact id (list :kind "transcript" :idle t))
                                     :type 'harness-error)))
              (should (string-match-p "running a turn" (harness-error-message err))))
            (should-not (memq 'compaction (harness-compaction-test-kinds id)))
            (should-not (gethash id harness-compaction--running)))
        (remhash id harness-agent--turns))
      ;; Once the turn is over it goes ahead.
      (should (equal "transcript"
                     (harness-node-compaction-kind
                      (harness-await (harness-call 'compaction/compact id (list :kind "transcript" :idle t))))))
      ;; Without it, the turn's own compaction does.
      (let ((other (harness-compaction-test-session))
            (harness-provider-demo-script-override harness-compaction-test-script))
        (puthash other (list :fake-turn t) harness-agent--turns)
        (unwind-protect
            (should (equal "SUMMARY TEXT" (plist-get (harness-await (harness-call 'compaction/compact other))
                                                     :content)))
          (remhash other harness-agent--turns))))))

(ert-deftest harness-compaction-transcript ()
  "A transcript compaction writes the conversation to a file and leaves a note.
No model is asked anything; the note opens the conversation from then
on, as it is, and an unanswered message still follows it."
  (harness-compaction-test-with
    (let* ((id (harness-compaction-test-session))
           (cwd (plist-get (harness-call 'session/get id) :cwd))
           (requests 0) (done nil))
      (harness-call 'session/append id '(:kind user :content "and now the lexer"))
      (harness-call 'session/usage-add id '(:input 10 :output 10 :cache-read 400 :context 420 :cache-at 1000.0))
      (harness-on 'compaction/done (lambda (sid node) (push (list sid (plist-get node :id)) done)))
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req) (cl-incf requests) (funcall orig req))))
        (let* ((node (harness-await (harness-call 'compaction/compact id (list :kind "transcript"))))
               (meta (plist-get node :meta))
               (file (plist-get meta :file)))
          (should (= 0 requests))
          (should (equal "transcript" (plist-get meta :compaction)))
          (should (equal "transcript" (harness-node-compaction-kind node)))
          (should (= 420 (plist-get meta :input-tokens)))
          (should (file-in-directory-p file (expand-file-name ".harness/transcripts/" cwd)))
          (should (equal "*\n" (with-temp-buffer
                                 (insert-file-contents (expand-file-name ".harness/transcripts/.gitignore" cwd))
                                 (buffer-string))))
          (let ((text (with-temp-buffer (insert-file-contents file) (buffer-string))))
            (should (string-prefix-p "# Compacted conversation\n" text))
            (should (string-match-p "\\[user\\] please refactor the parser" text))
            (should (string-match-p "\\[assistant\\] Done: parser.el rewritten" text)))
          (should (string-match-p (regexp-quote file) (plist-get node :content)))
          (should (string-match-p "read its end" (plist-get node :content)))
          (should (equal (list (list id (plist-get node :id))) done))
          ;; The note opens the conversation as it is, the open message after it.
          (let ((messages (harness-call 'session/messages id)))
            (should (= 1 (length messages)))
            (should (equal (list (plist-get node :content) "and now the lexer")
                           (mapcar (lambda (b) (plist-get b :text)) (plist-get (car messages) :content)))))
          (should (equal (format "Compacted: 420 tokens → transcript in %s" (abbreviate-file-name file))
                         (car (last (harness-compaction-test-hints id)))))
          (let ((s (harness-call 'session/get id)))
            (should-not (plist-get s :cache))
            (should (= (harness-estimate-tokens (plist-get node :content))
                       (plist-get (plist-get s :usage) :context)))))))
    ;; A session whose directory is gone has nowhere to write it.
    (let* ((id (harness-compaction-test-session))
           (failed nil))
      (harness-on 'compaction/failed (lambda (sid msg) (push (list sid msg) failed)))
      (delete-directory (plist-get (harness-call 'session/get id) :cwd) t)
      (should-error (harness-await (harness-call 'compaction/compact id (list :kind 'transcript))))
      (should (string-match-p "does not exist" (cadr (car failed))))
      (should-not (memq 'compaction (harness-compaction-test-kinds id)))
      (should (zerop (hash-table-count harness-compaction--running))))))

(ert-deftest harness-compaction-estimate ()
  "The estimate prices each kind of compaction against carrying on.
A summary on an API model reads all of the context uncached, whatever
the cache: it is a prompt of its own.  On a fork of a hosted loop's
conversation it reads it from the cache while that lasts.  A brief one
is the cheap model's, of a sample; a transcript costs nothing."
  (harness-compaction-test-with
    (harness-compaction-test-tiered-provider)
    (let* ((id (harness-compaction-test-long-session))
           (ask (harness-estimate-tokens harness-compaction--request-text))
           (near (lambda (a b) (< (abs (- a b)) 1e-9))))
      (harness-call 'session/update id :model "tiered:big" :silent t)
      (harness-call 'session/usage-add id '(:input 10 :output 10 :cache-read 100000 :context 100000 :cache-at 1000.0))
      (let* ((e (harness-call 'compaction/estimate id))
             (kinds (plist-get e :kinds))
             (summary (cl-find 'summary kinds :key (lambda (k) (plist-get k :kind))))
             (brief (cl-find 'brief kinds :key (lambda (k) (plist-get k :kind))))
             (transcript (cl-find 'transcript kinds :key (lambda (k) (plist-get k :kind)))))
        (should (= 100000 (plist-get e :context)))
        (should (equal "tiered:big" (plist-get e :model)))
        (should (equal "Big" (plist-get e :model-label)))
        (should (eq 'summary (plist-get e :kind)))
        (should-not (plist-get e :cached))
        (should-not (plist-get e :compacting))
        ;; Cache writes are the dearer: 100k at 12.5, against 1.0 read.
        (should (funcall near 1.25 (plist-get e :carry-on)))
        (should (funcall near 0.1 (plist-get e :carry-on-cached)))
        (should (equal '(summary brief transcript) (mapcar (lambda (k) (plist-get k :kind)) kinds)))
        (should (equal "tiered:big" (plist-get summary :model)))
        (should-not (plist-get summary :cached))
        (should (funcall near (/ (+ (* (+ 100000 ask) 12.5) (* harness-compaction--summary-output 50.0)) 1e6)
                         (plist-get summary :cost)))
        (should (equal "tiered:small" (plist-get brief :model)))
        (should (equal "Small" (plist-get brief :model-label)))
        (should (< (plist-get brief :input) 3000))
        (should (funcall near (/ (+ (* (plist-get brief :input) 1.25) (* harness-compaction--summary-output 5.0)) 1e6)
                         (plist-get brief :cost)))
        (should (< (plist-get brief :cost) 0.02))
        (should (eql 0.0 (plist-get transcript :cost)))
        (should-not (plist-get transcript :model))
        (should (< (plist-get transcript :after) 200)))
      ;; While the cache lasts, carrying on reads it.  A summary on an API
      ;; model still reads none of it.
      (harness-call 'session/usage-add id (list :input 10 :output 10 :cache-read 100000 :context 100000
                                                :cache-at (float-time) :cache-ttl 3600))
      (let* ((e (harness-call 'compaction/estimate id))
             (summary (car (plist-get e :kinds))))
        (should (plist-get e :cached))
        (should (funcall near 0.1 (plist-get e :carry-on)))
        (should-not (plist-get summary :cached))
        (should (> (plist-get summary :cost) 1.25))))
    ;; A hosted loop with the session's conversation summarises a fork of
    ;; it, which reads the cache while it lasts.
    (harness-compaction-test-tiered-provider '(:hosted-loop t :fork t :compaction hosted))
    (let ((id (harness-compaction-test-long-session))
          (ask (harness-estimate-tokens harness-compaction--request-text)))
      (harness-call 'session/update id :model "tiered:big" :silent t)
      (harness-call 'session/set-provider-state id '(:conv "c9" :provider "tiered"))
      (harness-call 'session/usage-add id (list :input 10 :output 10 :cache-read 100000 :context 100000
                                                :cache-at (float-time) :cache-ttl 3600))
      (let ((summary (car (plist-get (harness-call 'compaction/estimate id) :kinds))))
        (should (plist-get summary :cached))
        (should (< (abs (- (/ (+ (* 100000 1.0) (* ask 10.0) (* harness-compaction--summary-output 50.0)) 1e6)
                           (plist-get summary :cost)))
                   1e-9))))
    ;; No catalogue prices: no costs, but the transcript's.
    (harness-define-provider 'unpriced
      :models (lambda () (harness-resolved (list (list :name "m" :context-window 100000))))
      :complete #'ignore)
    (let ((id (harness-compaction-test-long-session)))
      (harness-call 'session/update id :model "unpriced:m" :silent t)
      (let ((e (harness-call 'compaction/estimate id)))
        (should (> (plist-get e :context) 0))
        (should-not (plist-get e :carry-on))
        (should-not (plist-get (car (plist-get e :kinds)) :cost))
        (should-not (plist-get (cadr (plist-get e :kinds)) :cost))
        (should (eql 0.0 (plist-get (nth 2 (plist-get e :kinds)) :cost)))))))

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

(ert-deftest harness-compaction-auto-makes-the-configured-kind ()
  "Automatic compaction makes `harness-compaction-kind': here a transcript, no summary."
  (harness-compaction-test-with
    (let* ((id (harness-compaction-test-session))
           (harness-compaction-kind 'transcript)
           (harness-provider-demo-script-override '((:type text :delta "ok") (:type done :stop-reason end-turn)))
           (requests nil))
      (harness-call 'session/usage-add id '(:context 7500))
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req) (push req requests) (funcall orig req))))
        (harness-await (harness-call 'agent/prompt id "next question")))
      ;; The turn only: a transcript asks no model.
      (should (= 1 (length requests)))
      (let* ((first (car (plist-get (car requests) :messages)))
             (texts (mapcar (lambda (b) (plist-get b :text)) (plist-get first :content))))
        (should (string-prefix-p "The conversation so far was compacted into a file" (car texts)))
        (should (member "next question" texts)))
      (should (equal "transcript" (harness-node-compaction-kind
                                   (cl-find 'compaction (harness-call 'session/nodes id)
                                            :key (lambda (n) (plist-get n :kind)))))))))

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
