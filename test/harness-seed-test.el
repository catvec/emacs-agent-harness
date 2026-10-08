;;; harness-seed-test.el --- Tests for seed sessions  -*- lexical-binding: t; -*-

;;; Commentary:

;; The demo provider answers every request with "ok" and a usage record
;; that wrote the prompt cache, which is what a real provider does for a
;; seed's priming message.  It also notes each request it gets, so the
;; tests can tell which session asked what, and with which system prompt.

;;; Code:

(require 'harness-test-helpers)

(defvar harness-provider-demo--delay)
(defvar harness-provider-demo-script-override)
(defvar harness-seed--seeds)
(defvar harness-seed--index)
(defvar harness-seed--pending)
(defvar harness-seed--prompts)
(defvar harness-seed--frozen)
(defvar harness-seed--waiters)
(defvar harness-seed-prime-message)
(defvar harness-seed-warm-message)
(defvar harness-session-spawned-output)
(declare-function harness-provider-demo--last-user-text "harness-provider-demo")
(declare-function harness-agent--system-prompt "harness-agent")
(declare-function harness-seed--system-prompt "harness-seed")

(defconst harness-seed-test-model "demo:cheap"
  "The model the forks go onto; the source runs on another.")

(defvar harness-seed-test--requests nil
  "What the demo provider was asked, newest first.
Each is (:session ID :model MODEL :system TEXT :text TEXT).")

(defvar harness-seed-test--turns nil
  "The session ids of the turns that started, newest first.")

(defvar harness-seed-test--fail nil
  "Non-nil makes the demo provider fail every request, with this error text.")

(defvar harness-seed-test--hook nil
  "Function called with each request the demo provider gets, or nil.")

(defvar harness-seed-test--slow-seconds 0.3
  "How long a request whose message says \"slow\" takes before it answers.")

(defun harness-seed-test--script (request)
  "Answer REQUEST as a model that writes the prompt cache would, and note it."
  (let ((text (harness-provider-demo--last-user-text request)))
    (push (list :session (plist-get (plist-get request :session) :id)
                :model (plist-get request :model)
                :system (plist-get request :system)
                :text text)
          harness-seed-test--requests)
    (when harness-seed-test--hook (funcall harness-seed-test--hook request))
    (cond
     (harness-seed-test--fail
      `((:type done :stop-reason error :error ,harness-seed-test--fail)))
     ((string-match-p "fork now" text)
      '((:type text :delta "Forking.")
        (:type tool-call :id "call-fork" :name "fork_workers" :input (:workers 2))
        (:type text :delta "Done.")
        (:type usage :input 40 :output 2 :cache-read 0 :cache-write 5000 :cost 0.001 :context 5042)
        (:type done :stop-reason end-turn)))
     (t
      `(,@(and (string-match-p "slow" text) `((:type wait :seconds ,harness-seed-test--slow-seconds)))
        (:type text :delta "ok")
        (:type usage :input 40 :output 2 :cache-read 0 :cache-write 5000 :cost 0.001
               :context 5042 :cache-ttl 300)
        (:type done :stop-reason end-turn))))))

(defun harness-seed-test--on-turn-started (session-id)
  "Note that a turn of SESSION-ID started."
  (push session-id harness-seed-test--turns))

(defmacro harness-seed-test-with-modules (extra &rest body)
  "Load the state layer with the demo provider, the seed module and EXTRA, run BODY.
EXTRA is a list of further module names.  The demo provider answers
through `harness-seed-test--script'."
  (declare (indent 1))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m (append '(store project config provider provider-demo tools session agent tools-agent seed)
                        ',extra))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-agent--turns)
     (dolist (table (list harness-seed--seeds harness-seed--index harness-seed--pending
                          harness-seed--prompts harness-seed--frozen harness-seed--waiters))
       (clrhash table))
     (harness-on 'agent/turn-started #'harness-seed-test--on-turn-started)
     (let ((harness-provider-demo--delay 0.005)
           (harness-provider-demo-script-override #'harness-seed-test--script)
           (harness-seed-test--requests nil)
           (harness-seed-test--turns nil)
           (harness-seed-test--fail nil)
           (harness-seed-test--hook nil)
           (default-directory dir))
       ,@body)))

(defmacro harness-seed-test-with (&rest body)
  "Load the state layer with the demo provider and the seed module, run BODY."
  (declare (indent 0))
  `(harness-seed-test-with-modules () ,@body))

;;;; Helpers

(defun harness-seed-test-source (&optional name)
  "Create a demo session called NAME with one turn done; return its id."
  (let ((sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted"
                                      :name (or name "Main work"))
                        :id)))
    (harness-test-await (harness-call 'agent/prompt sid "hello there"))
    sid))

(defun harness-seed-test-fork (source &rest plist)
  "Fork SOURCE onto the test model through a seed with PLIST; return the fork."
  (harness-test-await (apply #'harness-call 'seed/fork source harness-seed-test-model plist)))

(defun harness-seed-test-user-texts (session-id)
  "Return the texts of the user messages of SESSION-ID, oldest first."
  (mapcar (lambda (n) (plist-get n :content))
          (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'user))
                            (harness-call 'session/nodes session-id))))

(defun harness-seed-test-count (session-id text)
  "Return how many user messages of SESSION-ID say TEXT."
  (cl-count text (harness-seed-test-user-texts session-id) :test #'equal))

(defun harness-seed-test-turns-of (session-id)
  "Return how many turns SESSION-ID started."
  (cl-count session-id harness-seed-test--turns :test #'equal))

(defun harness-seed-test-requests-of (session-id)
  "Return the requests SESSION-ID made to the provider, oldest first."
  (nreverse (cl-remove-if-not (lambda (r) (equal (plist-get r :session) session-id))
                              (copy-sequence harness-seed-test--requests))))

(defun harness-seed-test-seeds ()
  "Return the ids of the seeds, newest first."
  (mapcar (lambda (s) (plist-get s :id)) (harness-call 'seed/list)))

(defun harness-seed-test-chill (seed-id &optional seconds-left)
  "Make the prompt cache of SEED-ID lapse in SECONDS-LEFT seconds (default -1000)."
  (harness-call 'session/usage-add seed-id
                (list :input 1 :output 1 :cache-read 1 :model harness-seed-test-model
                      :cache-ttl 300 :cache-at (- (+ (float-time) (or seconds-left -1000)) 300))))

(defun harness-seed-test-unfrozen-prompt (session-id)
  "Return the system prompt SESSION-ID would send without the seed filter."
  (harness-remove-filter 'agent/system-prompt #'harness-seed--system-prompt)
  (unwind-protect (harness-agent--system-prompt (harness-call 'session/get session-id))
    (harness-add-filter 'agent/system-prompt #'harness-seed--system-prompt 1000)))

;;;; One seed for every fork

(ert-deftest harness-seed-forks-share-one-seed ()
  "Two forks of one source onto one model make one seed and one priming turn;
both are children of the seed and run on the model."
  (harness-seed-test-with
    (let* ((source (harness-seed-test-source))
           (head (plist-get (harness-call 'session/get source) :head))
           (a (harness-seed-test-fork source :name "worker a"))
           (b (harness-seed-test-fork source :name "worker b"))
           (seed (plist-get a :seed))
           (seeds (harness-call 'seed/list)))
      (should (stringp seed))
      (should (equal seed (plist-get b :seed)))
      (should-not (equal (plist-get a :id) (plist-get b :id)))
      ;; One seed, a fork of the source at its head, on the model.
      (should (= 1 (length seeds)))
      (should (equal (list :id seed :source source :node head :model harness-seed-test-model)
                     (harness-plist-remove (car seeds) :cache)))
      ;; The priming turn wrote the cache, which the list shows as the session does.
      (should (plist-get (plist-get (car seeds) :cache) :expires))
      (should (equal (plist-get (harness-call 'session/get seed) :cache) (plist-get (car seeds) :cache)))
      (let ((s (harness-call 'session/get seed)))
        (should (equal source (plist-get s :parent-id)))
        (should (equal head (plist-get s :fork-node)))
        (should (eq 'subagent (plist-get s :kind)))
        (should (equal harness-seed-test-model (plist-get s :model)))
        (should (equal (format "Shared context for Main work (%s)" harness-seed-test-model)
                       (plist-get s :name))))
      ;; One priming turn, from the harness.
      (should (= 1 (harness-seed-test-turns-of seed)))
      (should (= 1 (harness-seed-test-count seed harness-seed-prime-message)))
      (let ((priming (cl-find harness-seed-prime-message (harness-call 'session/nodes seed)
                              :key (lambda (n) (plist-get n :content)) :test #'equal)))
        (should (equal '(:kind system :source "seed") (harness-node-sender priming))))
      (should (equal (list harness-seed-test-model) (delete-dups (mapcar (lambda (r) (plist-get r :model))
                                                                          (harness-seed-test-requests-of seed)))))
      (should (= 0 (harness-seed-test-turns-of (plist-get a :id))))
      ;; Both forks are children of the seed, on the model, named as asked.
      (dolist (fork (list a b))
        (let ((f (harness-call 'session/get (plist-get fork :id))))
          (should (equal seed (plist-get f :parent-id)))
          (should (equal harness-seed-test-model (plist-get f :model)))
          (should (eq 'subagent (plist-get f :kind)))
          (should (equal seed (plist-get fork :seed)))
          ;; They start from the seed's whole transcript, the priming included.
          (should (equal (mapcar (lambda (n) (plist-get n :id)) (harness-call 'session/nodes seed))
                         (mapcar (lambda (n) (plist-get n :id)) (harness-call 'session/nodes (plist-get fork :id)))))))
      (should (equal "worker a" (plist-get (harness-call 'session/get (plist-get a :id)) :name)))
      (should (equal "worker b" (plist-get (harness-call 'session/get (plist-get b :id)) :name)))
      (should (= 1 (hash-table-count harness-seed--seeds)))
      (should (= 0 (hash-table-count harness-seed--pending))))))

(ert-deftest harness-seed-a-warm-seed-is-forked-without-another-turn ()
  "The priming turn left the cache warm, so later forks wait for nothing."
  (harness-seed-test-with
    (let* ((source (harness-seed-test-source))
           (fork (harness-seed-test-fork source))
           (seed (plist-get fork :seed))
           (cache (plist-get (harness-call 'session/get seed) :cache)))
      (should (equal harness-seed-test-model (plist-get cache :model)))
      (should (> (plist-get cache :expires) (+ (float-time) 200)))
      (harness-seed-test-fork source)
      (harness-seed-test-fork source)
      (should (= 1 (harness-seed-test-turns-of seed)))
      (should (= 0 (harness-seed-test-count seed harness-seed-warm-message)))
      (should (= 1 (length (harness-call 'seed/list)))))))

(ert-deftest harness-seed-the-fork-keeps-the-plist-keys-it-was-given ()
  "The keys of the call reach the fork, and a nil model is the source's.
They are `session/fork' keys: the fork gets them, not the seed.  The kind
defaults to subagent, and the seed's name can be given."
  (harness-seed-test-with
    (let* ((source (harness-seed-test-source))
           (cwd (harness-test-temp-dir))
           (fork (harness-test-await
                  (harness-call 'seed/fork source harness-seed-test-model
                                :name "worker" :cwd cwd :seed-name "Context for workers" :id "fork-with-an-id")))
           (seed (plist-get fork :seed))
           (other (harness-test-await
                   (harness-call 'seed/fork source harness-seed-test-model :kind 'fork))))
      (should (equal "fork-with-an-id" (plist-get fork :id)))
      (should (equal cwd (plist-get fork :cwd)))
      (should (equal "worker" (plist-get fork :name)))
      (should (eq 'subagent (plist-get fork :kind)))
      (should (eq 'fork (plist-get (harness-call 'session/get (plist-get other :id)) :kind)))
      (should (equal "Context for workers" (plist-get (harness-call 'session/get seed) :name)))
      ;; The seed works where the source does; the fork where it was told to.
      (should (equal (plist-get (harness-call 'session/get source) :cwd)
                     (plist-get (harness-call 'session/get seed) :cwd)))
      ;; No model: the source's own, a seed of its own too.
      (let ((same (harness-test-await (harness-call 'seed/fork source nil))))
        (should-not (equal seed (plist-get same :seed)))
        (should (equal "demo:scripted" (plist-get (harness-call 'session/get (plist-get same :id)) :model)))
        (should (equal "demo:scripted" (plist-get (harness-call 'session/get (plist-get same :seed)) :model)))))))

(ert-deftest harness-seed-a-seed-belongs-to-its-node-and-model ()
  "Another node of the source, another model, or another source, is another seed."
  (harness-seed-test-with
    (let* ((source (harness-seed-test-source))
           (first-node (plist-get (car (harness-call 'session/nodes source)) :id))
           (_ (harness-test-await (harness-call 'agent/prompt source "and some more")))
           (at-head (harness-seed-test-fork source))
           (at-first (harness-seed-test-fork source :node first-node))
           (again (harness-seed-test-fork source :node first-node))
           (other-model (harness-test-await (harness-call 'seed/fork source "demo:other")))
           (other-source (harness-seed-test-fork (harness-seed-test-source "Other work"))))
      (should (= 4 (length (delete-dups (mapcar (lambda (f) (plist-get f :seed))
                                                (list at-head at-first other-model other-source))))))
      (should (equal (plist-get at-first :seed) (plist-get again :seed)))
      (should (= 4 (length (harness-call 'seed/list))))
      ;; A seed at an earlier node holds the transcript only up to there.
      (let ((seed (harness-call 'session/get (plist-get at-first :seed))))
        (should (equal first-node (plist-get seed :fork-node)))
        (should (equal first-node (plist-get (car (harness-call 'session/nodes (plist-get seed :id))) :id)))
        (should (= 3 (length (harness-call 'session/nodes (plist-get seed :id))))))
      (should (equal "demo:other" (plist-get (harness-call 'session/get (plist-get other-model :seed)) :model)))
      ;; Newest first, and only a source's own with SOURCE-ID.
      (should (equal (plist-get other-source :seed) (car (harness-seed-test-seeds))))
      (should (equal (list (plist-get other-source :seed))
                     (mapcar (lambda (s) (plist-get s :id))
                             (harness-call 'seed/list (plist-get (harness-call 'session/get (plist-get other-source :seed))
                                                                 :parent-id))))))))

;;;; The system prompt

(ert-deftest harness-seed-forks-send-the-seeds-system-prompt ()
  "A fork sends the seed's final system prompt, every section in it.
Its own would name its own directories."
  (harness-seed-test-with
    ;; A section added after the module's others, to see the filter run last.
    (harness-add-filter 'agent/system-prompt (lambda (prompt _s) (concat prompt "\n## Late section\n")) 900)
    (let* ((source (harness-seed-test-source))
           (a (harness-seed-test-fork source))
           (b (harness-seed-test-fork source))
           (seed (plist-get a :seed))
           (recorded (plist-get (gethash seed harness-seed--prompts) :prompt))
           (priming (plist-get (car (harness-seed-test-requests-of seed)) :system))
           (seed-tmp (harness-call 'session/tmp-dir seed)))
      ;; What the seed sent is what is recorded, sections of every priority in it.
      (should (stringp recorded))
      (should (equal priming recorded))
      (should (string-match-p "## Planning" recorded))
      (should (string-match-p "## Late section" recorded))
      (should (string-search seed-tmp recorded))
      (should (equal recorded (harness-agent--system-prompt (harness-call 'session/get seed))))
      (dolist (fork (list a b))
        (let* ((id (plist-get fork :id))
               (own-tmp (harness-call 'session/tmp-dir id))
               (frozen (harness-agent--system-prompt (harness-call 'session/get id)))
               (unfrozen (harness-seed-test-unfrozen-prompt id)))
          (should (equal recorded frozen))
          (should-not (equal recorded unfrozen))
          (should (string-search own-tmp unfrozen))
          (should-not (string-search own-tmp frozen))
          (should (string-search seed-tmp frozen))
          ;; The model is told it too: the fork's first request sends it.
          (harness-test-await (harness-call 'agent/prompt id (concat (plist-get fork :preamble) "\n\nDo the task.")))
          (should (equal recorded (plist-get (car (harness-seed-test-requests-of id)) :system)))))
      ;; Not a word of the seed's own session was touched by a fork's turn.
      (should (= 1 (harness-seed-test-turns-of seed))))))

(ert-deftest harness-seed-a-fork-keeps-the-prompt-it-was-made-with ()
  "A fork keeps the system prompt it was made with.
A prompt the seed assembles later does not change it, and neither does
the seed being deleted."
  (harness-seed-test-with
    (let* ((source (harness-seed-test-source))
           (a (harness-seed-test-fork source))
           (seed (plist-get a :seed))
           (before (plist-get (gethash seed harness-seed--prompts) :prompt)))
      (harness-add-filter 'agent/system-prompt (lambda (prompt _s) (concat prompt "\n## Changed since\n")) 900)
      (should (equal before (harness-agent--system-prompt (harness-call 'session/get (plist-get a :id)))))
      ;; The seed records its new prompt the next time it asks for one, and
      ;; forks made from then on send that.
      (harness-seed-test-chill seed)
      (let* ((b (harness-seed-test-fork source))
             (after (plist-get (gethash seed harness-seed--prompts) :prompt)))
        (should (string-match-p "## Changed since" after))
        (should (equal after (harness-agent--system-prompt (harness-call 'session/get (plist-get b :id)))))
        (should (equal before (harness-agent--system-prompt (harness-call 'session/get (plist-get a :id)))))
        (harness-call 'session/delete seed)
        (should (equal after (harness-agent--system-prompt (harness-call 'session/get (plist-get b :id)))))
        (should (equal before (harness-agent--system-prompt (harness-call 'session/get (plist-get a :id)))))))))

(ert-deftest harness-seed-without-the-filter-nothing-else-changes ()
  "Without the filter other sessions are as they were, and seeds still work.
Their prompts are the same with the filter and without it; without it the
forks send prompts of their own."
  (harness-seed-test-with
    (let* ((plain (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted") :id))
           (with-filter (harness-agent--system-prompt (harness-call 'session/get plain)))
           (without (harness-seed-test-unfrozen-prompt plain)))
      (should (equal with-filter without))
      (should (string-match-p "## Planning" with-filter)))
    (harness-remove-filter 'agent/system-prompt #'harness-seed--system-prompt)
    (let* ((source (harness-seed-test-source))
           (fork (harness-seed-test-fork source))
           (seed (plist-get fork :seed))
           (id (plist-get fork :id)))
      (should (equal seed (plist-get (harness-call 'session/get id) :parent-id)))
      (should (equal harness-seed-test-model (plist-get (harness-call 'session/get id) :model)))
      (should (= 1 (harness-seed-test-turns-of seed)))
      ;; Nothing was recorded, nothing is frozen, and no environment differs
      ;; from a prompt nobody shares.
      (should (= 0 (hash-table-count harness-seed--prompts)))
      (should (= 0 (hash-table-count harness-seed--frozen)))
      (should-not (plist-get fork :preamble))
      (let ((prompt (harness-agent--system-prompt (harness-call 'session/get id))))
        (should (string-search (harness-call 'session/tmp-dir id) prompt))
        (should-not (string-search (harness-call 'session/tmp-dir seed) prompt))))))

(ert-deftest harness-seed-init-is-idempotent ()
  "Initialising twice hooks in once."
  (harness-seed-test-with
    (harness-seed--init)
    (harness-seed--init)
    (let ((count (lambda (name fn) (cl-count fn (gethash name harness--filters) :key #'cdr))))
      (should (= 1 (funcall count 'agent/system-prompt #'harness-seed--system-prompt)))
      (should (= 1 (funcall count 'agent/before-turn #'harness-seed--before-turn))))
    (should (= 1 (cl-count #'harness-seed--on-deleted (gethash 'session/deleted harness--subscribers) :key #'cdr)))
    (should (= 1 (cl-count #'harness-seed--on-turn-ended (gethash 'agent/turn-ended harness--subscribers) :key #'cdr)))
    ;; The system prompt filter runs last.
    (should (= 1000 (car (cl-find #'harness-seed--system-prompt (gethash 'agent/system-prompt harness--filters)
                                  :key #'cdr))))
    (should (harness-module-ready-p 'seed))))

;;;; The preamble

(ert-deftest harness-seed-preamble-names-the-forks-own-environment ()
  "The preamble tells the fork its own directories.
Its temporary directory, and its working directory when that is not
the one the shared prompt names."
  (harness-seed-test-with
    (let* ((source (harness-seed-test-source))
           (plain (harness-seed-test-fork source))
           (elsewhere (harness-seed-test-fork source :cwd (harness-test-temp-dir)))
           (seed-cwd (plist-get (harness-call 'session/get (plist-get plain :seed)) :cwd)))
      (let ((text (plist-get plain :preamble))
            (tmp (harness-call 'session/tmp-dir (plist-get plain :id))))
        (should (string-prefix-p "Your own environment, which differs from the one your system prompt names" text))
        (should (string-search "you share that prompt with other sessions" text))
        (should (string-search (format "temporary directory %s (yours alone: put scratch files there)" tmp) text))
        ;; The working directory is said with it, though it is the same.
        (should (equal seed-cwd (plist-get plain :cwd)))
        (should (string-search (format "working directory %s; temporary directory" seed-cwd) text))
        (should-not (string-search (harness-call 'session/tmp-dir (plist-get plain :seed)) text)))
      (let ((text (plist-get elsewhere :preamble)))
        (should (string-search (format "working directory %s" (plist-get elsewhere :cwd)) text))
        (should-not (string-search seed-cwd text))
        (should (string-search (harness-call 'session/tmp-dir (plist-get elsewhere :id)) text))
        (should (string-match-p "working directory .*; temporary directory " text))))))

(ert-deftest harness-seed-preamble-is-nil-when-nothing-differs ()
  "A fork without a temporary directory, working where the prompt says, hears nothing."
  (harness-seed-test-with
    (cl-letf (((symbol-function 'harness-method/session/tmp-dir) (lambda (_id) nil)))
      (let* ((source (harness-seed-test-source))
             (fork (harness-seed-test-fork source)))
        (should (plist-member fork :preamble))
        (should-not (plist-get fork :preamble))
        (should (equal (plist-get (gethash (plist-get fork :seed) harness-seed--prompts) :prompt)
                       (harness-agent--system-prompt (harness-call 'session/get (plist-get fork :id)))))))))

;;;; Warming

(ert-deftest harness-seed-a-cold-seed-is-warmed-once-before-the-next-fork ()
  "A seed whose cache lapsed gets one warm-up turn, which the fork waits for."
  (harness-seed-test-with
    (let* ((source (harness-seed-test-source))
           (seed (plist-get (harness-seed-test-fork source) :seed)))
      (should (= 1 (harness-seed-test-turns-of seed)))
      (harness-seed-test-chill seed)
      (should (< (plist-get (plist-get (harness-call 'session/get seed) :cache) :expires) (float-time)))
      (let* ((promise (harness-call 'seed/fork source harness-seed-test-model))
             (fork (harness-test-await promise))
             (nodes (harness-call 'session/nodes (plist-get fork :id))))
        (should (= 2 (harness-seed-test-turns-of seed)))
        (should (= 1 (harness-seed-test-count seed harness-seed-warm-message)))
        (should (= 1 (harness-seed-test-count seed harness-seed-prime-message)))
        (should (equal '(:kind system :source "seed")
                       (harness-node-sender (cl-find harness-seed-warm-message nodes
                                                     :key (lambda (n) (plist-get n :content)) :test #'equal))))
        ;; The fork starts after the answer to the warm-up, which is no
        ;; reason to be running a turn.
        (should (eq 'assistant (plist-get (car (last nodes)) :kind)))
        (should-not (harness-call 'agent/running seed))
        (should (> (plist-get (plist-get (harness-call 'session/get seed) :cache) :expires)
                   (+ (float-time) 200))))
      ;; Warm again: nothing more is sent.
      (harness-seed-test-fork source)
      (should (= 2 (harness-seed-test-turns-of seed))))))

(ert-deftest harness-seed-a-cache-about-to-lapse-counts-as-cold ()
  "The margin: warm-up from 30 seconds before the cache lapses, not before."
  (harness-seed-test-with
    (let* ((source (harness-seed-test-source))
           (seed (plist-get (harness-seed-test-fork source) :seed)))
      (harness-seed-test-chill seed 100)
      (harness-seed-test-fork source)
      (should (= 1 (harness-seed-test-turns-of seed)))
      (harness-seed-test-chill seed 10)
      (harness-seed-test-fork source)
      (should (= 2 (harness-seed-test-turns-of seed)))
      (should (= 1 (harness-seed-test-count seed harness-seed-warm-message))))))

(ert-deftest harness-seed-a-seed-without-cache-is-warmed ()
  "A seed with no `:cache' at all (the provider reported none) is cold."
  (harness-seed-test-with
    (let* ((source (harness-seed-test-source))
           (seed (plist-get (harness-seed-test-fork source) :seed)))
      (cl-letf* ((get (symbol-function 'harness-method/session/get))
                 ((symbol-function 'harness-method/session/get)
                  (lambda (id) (plist-put (funcall get id) :cache nil))))
        (harness-seed-test-fork source))
      (should (= 2 (harness-seed-test-turns-of seed))))))

(ert-deftest harness-seed-a-turn-already-running-is-waited-for ()
  "A turn of the seed in progress, whoever began it, is waited for; no other follows."
  (harness-seed-test-with
    (let* ((source (harness-seed-test-source))
           (seed (plist-get (harness-seed-test-fork source) :seed)))
      (harness-seed-test-chill seed)
      (let* ((turn (harness-call 'agent/prompt seed "something slow"))
             (promise (harness-call 'seed/fork source harness-seed-test-model)))
        (should (harness-call 'agent/running seed))
        (should-not (harness-promise-settled-p promise))
        (let ((fork (harness-test-await promise)))
          (should (harness-promise-settled-p turn))
          (should-not (harness-call 'agent/running seed))
          ;; Priming, and the slow one: nobody added a warm-up.
          (should (= 2 (harness-seed-test-turns-of seed)))
          (should (= 0 (harness-seed-test-count seed harness-seed-warm-message)))
          ;; The fork has the slow turn's answer: it waited for it.
          (should (member "something slow" (harness-seed-test-user-texts (plist-get fork :id))))
          (should (eq 'assistant (plist-get (car (last (harness-call 'session/nodes (plist-get fork :id)))) :kind))))))))

;;;; Concurrent calls

(ert-deftest harness-seed-concurrent-calls-share-one-creation ()
  "Calls made at once for one seed make it once, prime it once, and each fork."
  (harness-seed-test-with
    (let* ((source (harness-seed-test-source))
           (calls (cl-loop for i from 1 to 3
                           collect (harness-call 'seed/fork source harness-seed-test-model
                                                 :name (format "worker %d" i))))
           (forks (mapcar #'harness-test-await calls))
           (seed (plist-get (car forks) :seed)))
      (should (equal (list seed) (delete-dups (mapcar (lambda (f) (plist-get f :seed)) forks))))
      (should (= 3 (length (delete-dups (mapcar (lambda (f) (plist-get f :id)) forks)))))
      (should (= 1 (length (harness-call 'seed/list))))
      (should (= 1 (harness-seed-test-turns-of seed)))
      (should (= 1 (harness-seed-test-count seed harness-seed-prime-message)))
      (should (equal '("worker 1" "worker 2" "worker 3")
                     (mapcar (lambda (f) (plist-get (harness-call 'session/get (plist-get f :id)) :name)) forks)))
      (dolist (f forks)
        (should (equal seed (plist-get (harness-call 'session/get (plist-get f :id)) :parent-id))))
      (should (= 0 (hash-table-count harness-seed--pending))))))

(ert-deftest harness-seed-calls-while-the-seed-is-being-forked-share-it ()
  "Calls made while the seed is being forked wait for that one creation.
A provider that takes its time to fork its state (a hosted loop's) keeps
the seed unknown for a while; the calls do not each make a seed."
  (harness-seed-test-with
    (let* ((source (harness-seed-test-source))
           (fork (symbol-function 'harness-method/session/fork)))
      (cl-letf (((symbol-function 'harness-method/session/fork)
                 (lambda (&rest args)
                   (let ((made (apply fork args))
                         (later (harness-make-promise)))
                     (run-at-time 0.1 nil (lambda () (harness-resolve later made)))
                     later))))
        (let ((p1 (harness-call 'seed/fork source harness-seed-test-model :name "one"))
              (p2 (harness-call 'seed/fork source harness-seed-test-model :name "two")))
          (should (= 1 (hash-table-count harness-seed--pending)))
          (should-not (harness-promise-settled-p p1))
          (let ((forks (list (harness-test-await p1) (harness-test-await p2))))
            (should (= 1 (length (harness-call 'seed/list))))
            (should (equal (plist-get (car forks) :seed) (plist-get (cadr forks) :seed)))
            (should (= 1 (harness-seed-test-turns-of (plist-get (car forks) :seed))))
            (should (equal '("one" "two")
                           (mapcar (lambda (f) (plist-get (harness-call 'session/get (plist-get f :id)) :name))
                                   forks)))
            (should (= 0 (hash-table-count harness-seed--pending)))))))))

(ert-deftest harness-seed-concurrent-calls-share-one-warm-up ()
  "Calls made at once for a cold seed warm it once."
  (harness-seed-test-with
    (let* ((source (harness-seed-test-source))
           (seed (plist-get (harness-seed-test-fork source) :seed)))
      (harness-seed-test-chill seed)
      (let ((forks (mapcar #'harness-test-await
                           (list (harness-call 'seed/fork source harness-seed-test-model)
                                 (harness-call 'seed/fork source harness-seed-test-model)))))
        (should (= 2 (length (delete-dups (mapcar (lambda (f) (plist-get f :id)) forks)))))
        (should (= 2 (harness-seed-test-turns-of seed)))
        (should (= 1 (harness-seed-test-count seed harness-seed-warm-message)))
        (should (= 0 (hash-table-count harness-seed--pending)))))))

(ert-deftest harness-seed-calls-for-other-seeds-do-not-wait-for-each-other ()
  "Two seeds made at once are two seeds."
  (harness-seed-test-with
    (let* ((a (harness-seed-test-source "A"))
           (b (harness-seed-test-source "B"))
           (pa (harness-call 'seed/fork a harness-seed-test-model))
           (pb (harness-call 'seed/fork b harness-seed-test-model))
           (fa (harness-test-await pa))
           (fb (harness-test-await pb)))
      (should-not (equal (plist-get fa :seed) (plist-get fb :seed)))
      (should (= 2 (length (harness-call 'seed/list))))
      (should (= 1 (harness-seed-test-turns-of (plist-get fa :seed))))
      (should (= 1 (harness-seed-test-turns-of (plist-get fb :seed)))))))

;;;; Failures

(ert-deftest harness-seed-a-failed-priming-rejects-and-the-next-call-warms ()
  "A priming turn that fails rejects the call and forks nothing.
The seed stays known, and the next call warms it instead of priming it
again."
  (harness-seed-test-with
    (let* ((source (harness-seed-test-source))
           (harness-seed-test--fail "the model is out to lunch")
           (promise (harness-call 'seed/fork source harness-seed-test-model))
           (err (should-error (harness-test-await promise) :type 'harness-error)))
      (should (string-match-p "the model is out to lunch" (cadr err)))
      (should (= 1 (length (harness-call 'seed/list))))
      (let ((seed (car (harness-seed-test-seeds))))
        (should (null (harness-call 'session/list (list :parent-id seed))))
        (should (= 0 (hash-table-count harness-seed--pending)))
        (should (= 0 (hash-table-count harness-seed--frozen)))
        ;; Still failing: rejected again, the one seed kept.
        (should-error (harness-test-await (harness-call 'seed/fork source harness-seed-test-model))
                      :type 'harness-error)
        (should (= 1 (length (harness-call 'seed/list))))
        (setq harness-seed-test--fail nil)
        (let ((fork (harness-seed-test-fork source)))
          (should (equal seed (plist-get fork :seed)))
          (should (= 1 (harness-seed-test-count seed harness-seed-prime-message)))
          (should (= 2 (harness-seed-test-count seed harness-seed-warm-message)))
          (should (equal seed (plist-get (harness-call 'session/get (plist-get fork :id)) :parent-id)))
          (should (plist-get fork :preamble)))))))

(ert-deftest harness-seed-a-failed-warm-up-rejects-without-a-fork ()
  "A warm-up that fails rejects the call and makes no fork."
  (harness-seed-test-with
    (let* ((source (harness-seed-test-source))
           (seed (plist-get (harness-seed-test-fork source) :seed)))
      (harness-seed-test-chill seed)
      (let ((harness-seed-test--fail "no cache for you"))
        (should (string-match-p "no cache for you"
                                (cadr (should-error (harness-test-await (harness-call 'seed/fork source harness-seed-test-model))
                                                    :type 'harness-error)))))
      (should (= 1 (length (harness-call 'session/list (list :parent-id seed)))))
      (should (= 0 (hash-table-count harness-seed--pending)))
      ;; Later it works.
      (harness-seed-test-fork source)
      (should (= 2 (length (harness-call 'session/list (list :parent-id seed))))))))

(ert-deftest harness-seed-a-seed-moved-to-another-model-rejects ()
  "A seed that ends its turn on another model cached for that model, so the call fails.
The fallback module can move a session whose request failed, and run
the request again there."
  (harness-seed-test-with
    (let* ((source (harness-seed-test-source))
           (first nil))
      (setq harness-seed-test--hook
            (lambda (request)
              (when (string-search "kept as shared context" (harness-provider-demo--last-user-text request))
                (harness-call 'session/update (plist-get (plist-get request :session) :id)
                              :model "demo:elsewhere" :silent t))))
      (should (string-match-p "moved to demo:elsewhere"
                              (cadr (should-error (harness-test-await
                                                   (harness-call 'seed/fork source harness-seed-test-model))
                                                  :type 'harness-error))))
      (setq first (car (harness-seed-test-seeds)))
      (should (null (harness-call 'session/list (list :parent-id first))))
      (should (= 0 (hash-table-count harness-seed--pending)))
      ;; It is not the seed for the model any more: the next call makes another.
      (setq harness-seed-test--hook nil)
      (let ((fork (harness-seed-test-fork source)))
        (should-not (equal first (plist-get fork :seed)))
        (should (equal harness-seed-test-model
                       (plist-get (harness-call 'session/get (plist-get fork :seed)) :model)))))))

(ert-deftest harness-seed-the-call-never-signals ()
  "Whatever is wrong, `seed/fork' returns a rejected promise."
  (harness-seed-test-with
    (let ((source (harness-seed-test-source)))
      (dolist (promise (list (harness-call 'seed/fork "no-such-session" harness-seed-test-model)
                             (harness-call 'seed/fork source harness-seed-test-model :node "n-nowhere")))
        (should (harness-promise-p promise))
        (should (harness-promise-settled-p promise))
        (should-error (harness-test-await promise) :type 'harness-error))
      (should-not (harness-call 'seed/list))
      (should (= 0 (hash-table-count harness-seed--pending)))
      ;; A fork that cannot be made leaves the seed, which is fine.
      (let ((seed (plist-get (harness-seed-test-fork source) :seed)))
        (cl-letf (((symbol-function 'harness-method/session/create)
                   (lambda (&rest _) (error "No room for another session"))))
          (should (string-match-p "No room" (cadr (should-error (harness-test-await
                                                                 (harness-call 'seed/fork source harness-seed-test-model))
                                                                :type 'error)))))
        (should (equal (list seed) (harness-seed-test-seeds)))
        (should (= 0 (hash-table-count harness-seed--pending)))))))

;;;; Forgetting

(ert-deftest harness-seed-deleting-a-seed-forgets-it ()
  "A deleted seed is gone from the list and the records; the next call makes another."
  (harness-seed-test-with
    (let* ((source (harness-seed-test-source))
           (a (harness-seed-test-fork source))
           (seed (plist-get a :seed)))
      (should (gethash seed harness-seed--seeds))
      (should (gethash seed harness-seed--prompts))
      (should (gethash (plist-get a :id) harness-seed--frozen))
      (harness-call 'session/delete seed)
      (should-not (harness-call 'seed/list))
      (should-not (gethash seed harness-seed--seeds))
      (should-not (gethash seed harness-seed--prompts))
      (should (= 0 (hash-table-count harness-seed--index)))
      (let ((b (harness-seed-test-fork source)))
        (should-not (equal seed (plist-get b :seed)))
        (should (= 1 (length (harness-call 'seed/list))))
        (should (= 1 (harness-seed-test-turns-of (plist-get b :seed))))
        ;; A fork that is deleted is forgotten as well.
        (should (gethash (plist-get b :id) harness-seed--frozen))
        (harness-call 'session/delete (plist-get b :id))
        (should-not (gethash (plist-get b :id) harness-seed--frozen))
        (should (gethash (plist-get a :id) harness-seed--frozen))))))

(ert-deftest harness-seed-a-seed-gone-unheard-of-is-made-again ()
  "A seed deleted behind the module's back, or switched to another model, is not used."
  (harness-seed-test-with
    (let* ((source (harness-seed-test-source))
           (first (plist-get (harness-seed-test-fork source) :seed)))
      ;; Switched by hand: its cache is no longer the model's.
      (harness-call 'session/update first :model "demo:scripted" :silent t)
      (let ((second (plist-get (harness-seed-test-fork source) :seed)))
        (should-not (equal first second))
        (should (equal (list second) (harness-seed-test-seeds))))
      ;; Gone without the event.
      (let ((second (car (harness-seed-test-seeds))))
        (remhash second harness-sessions)
        (should-not (harness-call 'seed/list))
        (let ((third (plist-get (harness-seed-test-fork source) :seed)))
          (should-not (equal second third))
          (should (equal (list third) (harness-seed-test-seeds))))))))

(ert-deftest harness-seed-deleting-a-session-rejects-those-waiting-for-it ()
  "Callers waiting for a turn of a seed that is deleted meanwhile are told so."
  (harness-seed-test-with
    (let* ((source (harness-seed-test-source))
           (seed (plist-get (harness-seed-test-fork source) :seed)))
      (harness-seed-test-chill seed)
      (harness-call 'agent/prompt seed "something slow")
      (let ((promise (harness-call 'seed/fork source harness-seed-test-model)))
        (should (gethash seed harness-seed--waiters))
        (harness-call 'session/delete seed)
        (should-error (harness-test-await promise) :type 'harness-error)
        (should-not (gethash seed harness-seed--waiters))))))

;;;; The forking call

(ert-deftest harness-seed-call-id-is-answered-in-the-seed ()
  "The tool call that starts the forks gets its result in the seed, the sub-agent's."
  (harness-seed-test-with
    (let* ((source (harness-seed-test-source)))
      (harness-call 'session/append source (list :kind 'tool-call :tool "spawn_agent" :call-id "call-1" :input nil))
      (let* ((fork (harness-seed-test-fork source :call-id "call-1"))
             (answer (lambda (id)
                       (cl-find-if (lambda (n) (and (eq (plist-get n :kind) 'tool-result)
                                                    (equal (plist-get n :call-id) "call-1")))
                                   (harness-call 'session/nodes id)))))
        (should (equal harness-session-spawned-output (plist-get (funcall answer (plist-get fork :seed)) :output)))
        (should-not (plist-get (funcall answer (plist-get fork :seed)) :is-error))
        ;; The fork inherits it, and the source got no answer from here.
        (should (equal harness-session-spawned-output (plist-get (funcall answer (plist-get fork :id)) :output)))
        (should-not (funcall answer source))))))

;;;; From a tool, in the middle of a turn

(defvar harness-tools)

(ert-deftest harness-seed-forks-from-a-tool-in-the-middle-of-a-turn ()
  "A tool of the source's running turn forks workers through one seed.
That is how the supervisor starts them: the call that forks is still
open in the source, answered in the seed as the sub-agent's, and every
worker's first request is well formed and sends the seed's prompt."
  (harness-seed-test-with
    (harness-add-filter 'permission/decide (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
    (harness-define-tool
     "fork_workers" :label "Fork workers" :description "Fork workers through a seed." :kind 'meta
     :handler (lambda (_input ctx)
                (let ((call (plist-get ctx :call-id)) (source (plist-get ctx :session-id)))
                  (harness-then
                   (harness-all (list (harness-call 'seed/fork source harness-seed-test-model
                                                    :call-id call :name "worker 1")
                                      (harness-call 'seed/fork source harness-seed-test-model
                                                    :call-id call :name "worker 2")))
                   (lambda (forks)
                     (harness-tool-ok (mapconcat (lambda (f) (plist-get f :id)) forks ",")))))))
    (unwind-protect
        (let* ((source (harness-seed-test-source))
               (turn (harness-test-await (harness-call 'agent/prompt source "fork now, please")))
               (result (cl-find-if (lambda (n) (and (eq (plist-get n :kind) 'tool-result)
                                                    (equal (plist-get n :call-id) "call-fork")))
                                   (harness-call 'session/nodes source)))
               (workers (split-string (plist-get result :output) ","))
               (seed (plist-get (car (harness-call 'seed/list)) :id))
               (call-node (cl-find "call-fork" (harness-call 'session/nodes source)
                                   :key (lambda (n) (plist-get n :call-id)) :test #'equal)))
          (should (eq 'end-turn (plist-get turn :stop-reason)))
          (should-not (plist-get result :is-error))
          (should (= 2 (length workers)))
          (should (= 1 (length (harness-call 'seed/list))))
          (should (equal (plist-get call-node :id) (plist-get (car (harness-call 'seed/list)) :node)))
          ;; The seed answers the open call as the sub-agent it started.
          (should (equal harness-session-spawned-output
                         (plist-get (cl-find-if (lambda (n) (and (eq (plist-get n :kind) 'tool-result)
                                                                 (equal (plist-get n :call-id) "call-fork")))
                                                (harness-call 'session/nodes seed))
                                    :output)))
          (dolist (id workers)
            (should (equal seed (plist-get (harness-call 'session/get id) :parent-id)))
            ;; Every call is answered right after it, for strict providers.
            (let* ((messages (harness-call 'session/messages id))
                   (index (cl-position-if (lambda (m)
                                            (cl-some (lambda (b) (equal (plist-get b :id) "call-fork"))
                                                     (plist-get m :content)))
                                          messages)))
              (should index)
              (should (cl-some (lambda (b) (equal (plist-get b :tool_use_id) "call-fork"))
                               (plist-get (nth (1+ index) messages) :content))))
            (harness-test-await (harness-call 'agent/prompt id "Do the task."))
            (should (equal (plist-get (gethash seed harness-seed--prompts) :prompt)
                           (plist-get (car (harness-seed-test-requests-of id)) :system))))
          (should (= 1 (harness-seed-test-turns-of seed))))
      (remhash "fork_workers" harness-tools))))

;;;; Turns of a seed and the stages before them

(ert-deftest harness-seed-its-own-messages-skip-the-stages-that-would-change-the-seed ()
  "The stages up to compaction (20) are left out of the seed's own messages;
the budget check (30) is not, and the user's message to a seed meets them all."
  (harness-seed-test-with
    (let ((early nil) (late nil) (budget-spent nil))
      (harness-add-filter 'agent/before-turn
                          (lambda (value next session)
                            (push (plist-get session :id) early) (funcall next value) nil)
                          15)
      (harness-add-filter 'agent/before-turn
                          (lambda (value next session)
                            (push (plist-get session :id) late)
                            (funcall next (if budget-spent (list :proceed nil :reason "Budget spent") value))
                            nil)
                          30)
      (let* ((source (harness-seed-test-source))
             (seed (plist-get (harness-seed-test-fork source) :seed)))
        ;; The source's own message met both, the seed's priming the later one.
        (should (equal (list source) early))
        (should (= 1 (cl-count seed late :test #'equal)))
        (should (= 1 (cl-count source late :test #'equal)))
        ;; And a warm-up, too.
        (harness-seed-test-chill seed)
        (harness-seed-test-fork source)
        (should (equal (list source) early))
        (should (= 2 (cl-count seed late :test #'equal)))
        ;; The user typing into the seed is not the module's message, nor is
        ;; another part of the harness writing to it.
        (harness-test-await (harness-call 'agent/prompt seed "a word from the user"))
        (should (= 1 (cl-count seed early :test #'equal)))
        (harness-test-await (harness-call 'agent/prompt seed "a word from the tasks"
                                          (list :from (harness-sender-system "tasks"))))
        (should (= 2 (cl-count seed early :test #'equal)))
        ;; A budget that is spent refuses the seed's own message too.
        (setq budget-spent t)
        (let ((other (harness-seed-test-source "Another")))
          (should (string-match-p "blocked" (cadr (should-error
                                                   (harness-test-await (harness-call 'seed/fork other harness-seed-test-model))
                                                   :type 'harness-error))))
          (should (= 1 (length (harness-call 'seed/list other)))))))))

(defvar harness-cowboy-ask)
(defvar harness-cowboy--asking)
(defvar harness-compaction--running)
(defvar harness-non-interactive)

(ert-deftest harness-seed-the-cold-cache-question-is-not-asked-of-a-seed ()
  "The cold-cache question is not asked of a seed's own warm-up.
With the cowboy and compaction stages in the chain, the warm-up of a
seed whose cache lapsed is not held for the question, nor does it
compact the seed; a message of the user's to it is asked about as usual."
  (harness-seed-test-with-modules (compaction cowboy)
    (clrhash harness-compaction--running)
    (clrhash harness-cowboy--asking)
    (let ((harness-cowboy-ask t)
          (harness-non-interactive nil))
      (let* ((source (harness-seed-test-source))
             (seed (plist-get (harness-seed-test-fork source) :seed))
             (kinds (lambda () (mapcar (lambda (n) (plist-get n :kind)) (harness-call 'session/nodes seed)))))
        (harness-seed-test-chill seed)
        ;; The question would hold the warm-up, and this call, for ever.
        (let ((fork (harness-seed-test-fork source)))
          (should (= 1 (harness-seed-test-count seed harness-seed-warm-message)))
          (should-not (harness-call 'question/pending seed))
          (should-not (memq 'compaction (funcall kinds)))
          (should (eq 'assistant (plist-get (car (last (harness-call 'session/nodes (plist-get fork :id)))) :kind))))
        ;; And again, in a seed that never waits for the user: no summary of it.
        (harness-call 'session/update seed :non-interactive t :silent t)
        (harness-seed-test-chill seed)
        (harness-seed-test-fork source)
        (should (= 2 (harness-seed-test-count seed harness-seed-warm-message)))
        (should-not (memq 'compaction (funcall kinds)))
        (harness-call 'session/update seed :non-interactive :false :silent t)
        ;; The user writing to the seed meets the question.
        (harness-seed-test-chill seed)
        (harness-call 'agent/prompt seed "back after a while")
        (harness-test-wait (lambda () (harness-call 'question/pending seed)) 5 "the cold-cache question")
        (should (harness-call 'cowboy/asking seed))
        (harness-call 'question/cancel seed (harness-call 'cowboy/asking seed))
        (harness-test-wait (lambda () (not (harness-call 'agent/running seed))) 5 "the held turn to end")))))

(ert-deftest harness-seed-the-stages-keep-other-sessions-as-they-were ()
  "The module's stage passes a session that is no seed through untouched."
  (harness-seed-test-with
    (let ((seen nil))
      (harness-add-filter 'agent/before-turn
                          (lambda (value next _session) (push (plist-get value :final) seen) (funcall next value) nil)
                          15)
      (let* ((sid (harness-seed-test-source))
             (value (harness-test-await
                     (harness-run-filter-async 'agent/before-turn
                                               (list :proceed t :message (list :text "x" :from (harness-sender-system "seed")))
                                               (harness-call 'session/get sid)))))
        (should (equal '(nil nil) (list (car seen) (plist-get value :final))))
        (should (plist-get value :proceed))
        ;; Two stages saw the source's first message and this one.
        (should (= 2 (length seen)))))))

(provide 'harness-seed-test)
;;; harness-seed-test.el ends here
