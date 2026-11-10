;;; harness-workspace-test.el --- Tests for workspace mode  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defvar harness-acp--server-enabled)
(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
(defvar harness-naming-auto)
(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent--turns)
(defvar harness-workspace--table)
(defvar harness-workspace-model)
(defvar harness-workspace-permission-mode)
(defvar harness-workspace-non-interactive)
(defvar harness-workspace-episode-context)
(defvar harness-workspace-episode-turns)
(defvar harness-workspace--loaded)
(defvar harness-workspace--subscribed)
(defvar harness-logseq-directory)
(defvar harness-workspace-knowledge--pages)
(defvar harness-workspace-knowledge--pending)
(defvar harness-workspace-knowledge--status-cache)
(defvar harness-workspace-knowledge--vectors)
(defvar harness-workspace-knowledge--subscribed)
(defvar harness-workspace-knowledge-dream)
(defvar harness-workspace-knowledge-dream-report)
(defvar harness-workspace-knowledge--dream-timer)

(declare-function harness-session--load-all "harness-session" ())

(defconst harness-workspace-test-script
  '((:type text :delta "Noted.")
    (:type done :stop-reason end-turn)))

(defconst harness-workspace-test-stream-script
  '((:type thinking :delta "The user asked about the quote. ")
    (:type thinking :delta "I will answer briefly.")
    (:type text :delta "The ")
    (:type text :delta "quote ")
    (:type text :delta "is open.")
    (:type done :stop-reason end-turn))
  "A multi-chunk answer with thinking before it.")

(defmacro harness-workspace-test-with (&rest body)
  "Load the workspace state layer with the demo provider, run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil)
           (harness-provider-demo--delay 0.002)
           (harness-provider-demo-script-override harness-workspace-test-script)
           (harness-workspace-model "demo:scripted")
           (harness-workspace-permission-mode 'auto)
           (harness-workspace-non-interactive t)
           (harness-naming-auto nil)
           (harness-workspace-episode-context 0.6)
           (harness-workspace-episode-turns 120)
           (harness-workspace-knowledge-dream nil)
           (harness-workspace-knowledge-dream-report nil)
           (harness-logseq-directory (expand-file-name "graph/" dir))
           (default-directory dir))
       ;; The module subscribes only while this is nil, and the bus is
       ;; reset for every test: forget the last test's subscription too.
       (setq harness-workspace--subscribed nil)
       (dolist (module '(store project config provider provider-demo tools session agent
                               acp logseq memory workspace-knowledge workspace-box workspace))
         (harness-test-load-module module))
       (clrhash harness-sessions)
       (clrhash harness-agent--turns)
       (clrhash harness-workspace--table)
       (setq harness-workspace--loaded nil
             harness-workspace-knowledge--subscribed nil)
       (clrhash harness-workspace-knowledge--pages)
       (clrhash harness-workspace-knowledge--pending)
       (clrhash harness-workspace-knowledge--status-cache)
       ;; The vectors are cached by model and text, and a test's fake
       ;; model must not read the last test's answer for the same text.
       (clrhash harness-workspace-knowledge--vectors)
       (harness-add-filter 'permission/decide
                           (lambda (_details next &rest _)
                             (funcall next (list :behavior 'allow)))
                           10)
       (unwind-protect (progn ,@body)
         (harness-call 'store/sqlite-close)))))

(defun harness-workspace-test-workspace (&optional plist)
  "Create a workspace for the test."
  (apply #'harness-call 'workspace/create
         (append (list :name "Home"
                       :root (expand-file-name "workspace/" harness-state-directory)
                       :model "demo:scripted")
                 plist)))

(defun harness-workspace-test-messages (id)
  "Return the message entries of workspace ID."
  (cl-remove-if-not
   (lambda (entry)
     (equal "message" (format "%s" (plist-get entry :kind))))
   (harness-call 'workspace/timeline id)))

(defun harness-workspace-test-assistant-messages (id)
  "Return the assistant message entries of workspace ID."
  (cl-remove-if-not
   (lambda (entry)
     (and (equal "message" (format "%s" (plist-get entry :kind)))
          (equal "assistant" (format "%s" (plist-get entry :role)))))
   (harness-call 'workspace/timeline id)))

(defun harness-workspace-test-wait-for (pred &optional timeout)
  "Wait for PRED, a function, or fail after TIMEOUT seconds."
  (harness-test-wait pred (or timeout 20) "the workspace turn"))

(defun harness-workspace-test-wait-idle (session)
  "Wait for SESSION's turn to end."
  (harness-test-wait (lambda () (not (harness-call 'agent/running session)))
                     20 "the end of the workspace turn"))

(ert-deftest harness-workspace-create-and-first-turn ()
  "A workspace starts a thread and an episode, and records the turn."
  (harness-workspace-test-with
    (let* ((workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id)))
      (should (equal "Home" (plist-get workspace :name)))
      (should (equal id (plist-get (harness-call 'workspace/get id) :id)))
      (should (null (plist-get (harness-call 'workspace/get id) :threads)))
      (harness-call 'workspace/prompt id "Remember that the tile is matte.")
      (harness-workspace-test-wait-for
       (lambda () (harness-workspace-test-assistant-messages id)))
      (let* ((view (harness-call 'workspace/get id))
             (threads (plist-get view :threads))
             (thread (car threads))
             (session (plist-get thread :live))
             (entries (harness-call 'workspace/timeline id)))
        (harness-workspace-test-wait-idle session)
        (setq view (harness-call 'workspace/get id)
              thread (car (plist-get view :threads)))
        (should (= 1 (length threads)))
        (should (equal "live" (plist-get thread :state)))
        (should (equal "idle" (plist-get thread :episode-status)))
        (should (null (plist-get thread :pending)))
        (should session)
        (should (equal "workspace"
                       (format "%s" (plist-get (harness-call 'session/get session) :kind))))
        (should (equal (plist-get thread :id)
                       (plist-get (plist-get (harness-call 'session/get session) :ext) :thread)))
        (should (cl-find-if (lambda (entry)
                              (equal "divider" (format "%s" (plist-get entry :kind))))
                            entries))
        (should (cl-find-if (lambda (entry)
                              (equal "brief" (format "%s" (plist-get entry :kind))))
                            entries))
        (should (= 2 (length (harness-workspace-test-messages id))))
        (should (equal "user"
                       (format "%s" (plist-get (car (harness-workspace-test-messages id)) :role))))
        (should (string-match-p "Remember that the tile is matte"
                                (plist-get (car (harness-workspace-test-messages id)) :text)))))))

(ert-deftest harness-workspace-episode-status-and-pending ()
  "A thread says running, blocked, idle, failed or stopped, and what it waits on.
The fine status is the session's, with the reason its last turn ended
kept on the thread; the pending list is the session's own, so a client
reads what the episode waits on without opening it."
  (harness-workspace-test-with
    (let* ((workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id)))
      (harness-call 'workspace/prompt id "The tile is matte.")
      (harness-workspace-test-wait-for
       (lambda () (harness-workspace-test-assistant-messages id)))
      (let* ((thread (car (plist-get (harness-call 'workspace/get id) :threads)))
             (session (plist-get thread :live)))
        (harness-workspace-test-wait-idle session)
        (setq thread (car (plist-get (harness-call 'workspace/get id) :threads)))
        (should (equal "idle" (plist-get thread :episode-status)))
        (should (null (plist-get thread :pending)))
        ;; A question holds the episode blocked, and is in what it waits on.
        (let ((pid (harness-call 'session/pending-add
                                 session
                                 (list :kind "question"
                                       :payload (list :question "Which database?"
                                                      :options (list "sqlite" "postgres"))))))
          (setq thread (car (plist-get (harness-call 'workspace/get id) :threads)))
          (should (equal "blocked" (plist-get thread :episode-status)))
          (should (equal "waiting" (plist-get thread :state)))
          (should (equal pid (plist-get (car (plist-get thread :pending)) :id)))
          (should (equal "question" (format "%s" (plist-get (car (plist-get thread :pending)) :kind))))
          (harness-call 'session/pending-resolve session pid "sqlite")
          (setq thread (car (plist-get (harness-call 'workspace/get id) :threads)))
          (should (equal "idle" (plist-get thread :episode-status)))
          (should (null (plist-get thread :pending))))
        ;; A turn that failed stays failed until the episode starts another.
        (harness-emit 'agent/turn-ended session 'error)
        (should (equal "failed"
                       (plist-get (car (plist-get (harness-call 'workspace/get id) :threads))
                                  :episode-status)))
        (harness-emit 'agent/turn-started session)
        (should (equal "idle"
                       (plist-get (car (plist-get (harness-call 'workspace/get id) :threads))
                                  :episode-status)))
        (harness-emit 'agent/turn-ended session 'cancelled)
        (should (equal "stopped"
                       (plist-get (car (plist-get (harness-call 'workspace/get id) :threads))
                                  :episode-status)))
        (harness-emit 'agent/turn-started session)
        (should (equal "idle"
                       (plist-get (car (plist-get (harness-call 'workspace/get id) :threads))
                                  :episode-status)))))))

(ert-deftest harness-workspace-skills-are-inherited-by-its-episodes ()
  "A workspace's skill selection is intent its episodes inherit.
It is kept as references, never as a grant: each episode resolves them
afresh, and `workspace/update' changes them for the episodes after."
  (harness-workspace-test-with
    (let* ((workspace (harness-workspace-test-workspace
                       '(:skills ("harness/review" "?cmp-box/deploy"))))
           (id (plist-get workspace :id)))
      (should (equal '("harness/review" "?cmp-box/deploy")
                     (plist-get (harness-call 'workspace/get id) :skills)))
      (harness-call 'workspace/prompt id "The tile is matte.")
      (harness-workspace-test-wait-for
       (lambda () (harness-workspace-test-assistant-messages id)))
      (let* ((thread (car (plist-get (harness-call 'workspace/get id) :threads)))
             (session (plist-get thread :live)))
        (harness-workspace-test-wait-idle session)
        (should (equal '("harness/review" "?cmp-box/deploy")
                       (plist-get (plist-get (harness-call 'session/get session) :ext)
                                  :skill-selection-inherited)))
        (harness-call 'workspace/update id :skills '("harness/commit"))
        (should (equal '("harness/commit")
                       (plist-get (harness-call 'workspace/get id) :skills)))))))

(ert-deftest harness-workspace-view-names-the-model-and-activity ()
  "A thread carries the model and activity of its live episode.
A parked thread carries the defaults its next episode would start with,
so a client names the model before the first message."
  (harness-workspace-test-with
    (let* ((workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id))
           (thread (harness-call 'workspace/thread/create id "Kitchen renovation")))
      ;; The workspace itself names the defaults its first thread starts on.
      (let ((view (harness-call 'workspace/get id)))
        (should (equal "demo:scripted" (plist-get view :model)))
        (should (equal "auto" (format "%s" (plist-get view :permission-mode)))))
      ;; No episode yet: the workspace's defaults, as the next one starts.
      (let ((shown (car (plist-get (harness-call 'workspace/get id) :threads))))
        (should (equal "demo:scripted" (plist-get shown :model)))
        (should (equal "auto" (format "%s" (plist-get shown :permission-mode))))
        (should (plist-get shown :non-interactive))
        (should (null (plist-get shown :activity))))
      (harness-call 'workspace/prompt id "The tile is matte.")
      (harness-workspace-test-wait-for
       (lambda () (harness-workspace-test-assistant-messages id)))
      (let ((live (plist-get (car (plist-get (harness-call 'workspace/get id) :threads))
                             :live)))
        (harness-workspace-test-wait-idle live)
        (let ((shown (car (plist-get (harness-call 'workspace/get id) :threads))))
          (should (equal "demo:scripted" (plist-get shown :model)))
          (should (equal "auto" (format "%s" (plist-get shown :permission-mode))))
          (should (null (plist-get shown :activity))))
        ;; What the running turn does now rides with the view.
        (let ((orig (symbol-function 'harness-call))
              (orig-exists (symbol-function 'harness-method-exists-p)))
          (cl-letf (((symbol-function 'harness-call)
                     (lambda (method &rest args)
                       (if (eq method 'agent/activity)
                           (list :phase "waiting" :since 1.0)
                         (apply orig method args))))
                    ((symbol-function 'harness-method-exists-p)
                     (lambda (method) (or (eq method 'agent/activity)
                                          (funcall orig-exists method)))))
            (harness-call 'session/set-status live 'running)
            (let ((running (car (plist-get (harness-call 'workspace/get id) :threads))))
              (should (equal "waiting"
                             (plist-get (plist-get running :activity) :phase))))))
        ;; The episode's own setting wins over the workspace's default.
        (harness-call 'session/update live :model "demo:other")
        (should (equal "demo:other"
                       (plist-get (car (plist-get (harness-call 'workspace/get id) :threads))
                                  :model)))
        (harness-call 'session/set-status live 'idle)))))

(ert-deftest harness-workspace-new-episode-clears-the-last-stop ()
  "A new episode starts idle, though the one before it failed."
  (harness-workspace-test-with
    (let* ((workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id))
           (thread (harness-call 'workspace/thread/create id "Kitchen renovation"))
           (internal (harness-workspace--get id))
           (record (harness-workspace--thread internal (plist-get thread :id)))
           (session (harness-workspace--start-episode internal record 'new-thread)))
      (harness-emit 'agent/turn-ended session 'error)
      (should (equal "failed"
                     (plist-get (car (plist-get (harness-call 'workspace/get id) :threads))
                                :episode-status)))
      (harness-workspace--start-episode internal record 'revived)
      (let ((shown (car (plist-get (harness-call 'workspace/get id) :threads))))
        (should (equal "live" (plist-get shown :state)))
        (should (equal "idle" (plist-get shown :episode-status)))
        (should-not (plist-get (harness-workspace--thread internal (plist-get shown :id))
                               :last-stop))))))

(ert-deftest harness-workspace-second-turn-continues-same-episode ()
  "A second message in the same thread keeps the live episode."
  (harness-workspace-test-with
    (let* ((workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id)))
      (harness-call 'workspace/prompt id "The tile is matte.")
      (harness-workspace-test-wait-for
       (lambda () (harness-workspace-test-assistant-messages id)))
      (let* ((view (harness-call 'workspace/get id))
             (episode (plist-get (car (plist-get view :threads)) :live)))
        (harness-call 'workspace/prompt id "And the grout is light.")
        (harness-workspace-test-wait-for
         (lambda () (= 2 (length (harness-workspace-test-assistant-messages id)))))
        (setq view (harness-call 'workspace/get id))
        (should (equal episode
                       (plist-get (car (plist-get view :threads)) :live)))
        (should (= 1 (length (plist-get (car (plist-get view :threads)) :episodes))))))))

(ert-deftest harness-workspace-new-thread-and-revive ()
  "`/new' starts a thread; a parked thread is revived in a new episode."
  (harness-workspace-test-with
    (let* ((workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id)))
      (harness-call 'workspace/prompt id "The tile is matte.")
      (harness-workspace-test-wait-for
       (lambda () (harness-workspace-test-assistant-messages id)))
      (let* ((view (harness-call 'workspace/get id))
             (first (car (plist-get view :threads)))
             (first-id (plist-get first :id)))
        (harness-workspace-test-wait-idle (plist-get first :live))
        (harness-call 'workspace/prompt id "/new A different topic")
        (harness-workspace-test-wait-for
         (lambda () (= 2 (length (plist-get (harness-call 'workspace/get id) :threads)))))
        (should (= 2 (length (plist-get (harness-call 'workspace/get id) :threads))))
        (harness-call 'workspace/thread/park id first-id)
        (should (null (plist-get (harness-call 'workspace/thread id first-id) :live)))
        (harness-call 'workspace/prompt id "Back to the tile." (list :thread first-id))
        (harness-workspace-test-wait-for
         (lambda ()
           (let ((thread (harness-call 'workspace/thread id first-id)))
             (and (plist-get thread :live)
                  (= 2 (length (plist-get thread :episodes)))))))
        (let ((thread (harness-call 'workspace/thread id first-id)))
          (should (= 2 (length (plist-get thread :episodes))))
          (should (cl-find-if (lambda (entry)
                                (and (equal "divider" (format "%s" (plist-get entry :kind)))
                                     (equal first-id (plist-get entry :thread))))
                              (harness-call 'workspace/timeline id))))))))

(ert-deftest harness-workspace-long-context-starts-a-new-episode ()
  "A full episode is continued in a new one, and the old transcript stays."
  (harness-workspace-test-with
    (let* ((harness-workspace-episode-turns 1)
           (workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id)))
      (harness-call 'workspace/prompt id "The tile is matte.")
      (harness-workspace-test-wait-for
       (lambda () (harness-workspace-test-assistant-messages id)))
      (let* ((view (harness-call 'workspace/get id))
             (first (plist-get (car (plist-get view :threads)) :episodes))
             (first-session (car first)))
        (harness-workspace-test-wait-idle first-session)
        (harness-call 'workspace/prompt id "And the grout is light.")
        (harness-workspace-test-wait-for
         (lambda ()
           (= 2 (length (plist-get (car (plist-get (harness-call 'workspace/get id) :threads))
                                   :episodes)))))
        (let* ((thread (car (plist-get (harness-call 'workspace/get id) :threads)))
               (episodes (plist-get thread :episodes)))
          (should (= 2 (length episodes)))
          (should-not (equal first-session (cadr episodes)))
          (should (harness-call 'session/exists-p first-session))
          (should (cl-find-if (lambda (entry)
                                (and (equal "divider" (format "%s" (plist-get entry :kind)))
                                     (equal "long-context"
                                            (format "%s" (plist-get entry :reason)))))
                              (harness-call 'workspace/timeline id))))))))

(ert-deftest harness-workspace-knowledge-recalls-a-turn ()
  "A turn is captured in the Logseq graph and a later search finds it."
  (harness-workspace-test-with
    (let* ((workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id)))
      (harness-call 'workspace/prompt id "Remember that the grout is warm grey.")
      (harness-workspace-test-wait-for
       (lambda () (harness-workspace-test-assistant-messages id)))
      (let ((thread (car (plist-get (harness-call 'workspace/get id) :threads))))
        (harness-workspace-test-wait-idle (plist-get thread :live)))
      (let* ((thread (car (plist-get (harness-call 'workspace/get id) :threads)))
             (status (harness-call 'knowledge/status id))
            (found (harness-call 'knowledge/search id "warm grey")))
        (should (plist-get status :available))
        (should (>= (plist-get status :notes) 2))
        (should (plist-get status :pages))
        (should found)
        (should (string-match-p "warm grey" (plist-get (car found) :text)))
        (should (equal "user" (format "%s" (plist-get (car found) :role))))
        ;; The capture is a journal block that links the thread's page.
        (should (file-exists-p
                 (harness-logseq-journal-file (harness-logseq-journal-name)
                                              harness-logseq-directory)))
        (let ((page (harness-call 'knowledge/thread-page id (plist-get thread :id))))
          (should (string-prefix-p "Threads/" page))
          (should (file-exists-p (harness-logseq-page-file page
                                                          harness-logseq-directory))))))))

(ert-deftest harness-workspace-a-turn-asks-no-second-model ()
  "A workspace turn is one model call: the agent's own.
No pass reads the finished turn again, so two turns cost two requests,
a note is on the graph only when the agent writes it with
`knowledge_write', and a next action a client set is left alone."
  (harness-workspace-test-with
    (let* ((requests 0)
           (harness-provider-demo-script-override
            (lambda (request)
              (cl-incf requests)
              ;; Answer as the demo would, with no override in the way.
              (let ((harness-provider-demo-script-override nil))
                (harness-provider-demo--script request))))
           (workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id)))
      (harness-call 'workspace/prompt id "The tile is matte.")
      (harness-workspace-test-wait-for
       (lambda () (harness-workspace-test-assistant-messages id)))
      (let* ((thread (harness-workspace-test-graph-thread id))
             (thread-id (plist-get thread :id)))
        (harness-call 'workspace/thread/update id thread-id
                      :next-action "Wait for the Stone Co sample.")
        (harness-call 'workspace/prompt id "The grout is warm grey.")
        (harness-workspace-test-wait-for
         (lambda () (= 2 (length (harness-workspace-test-assistant-messages id)))))
        (harness-workspace-test-wait-idle (plist-get (harness-workspace-test-graph-thread id) :live))
        ;; One request per turn, the agent's: nothing follows it.
        (should (= 2 requests))
        ;; The agent wrote no note, so the graph has none: the turns are
        ;; the journal's captures.
        (should-not (cl-find-if
                     (lambda (block)
                       (equal "note" (cdr (assoc "role" (plist-get block :properties)))))
                     (plist-get (harness-call 'knowledge/page
                                              id (plist-get thread :page))
                                :blocks)))
        (should (cl-find-if (lambda (block)
                              (string-match-p "matte" (plist-get block :text)))
                            (harness-call 'knowledge/search id "matte")))
        ;; A next action a client set is not overwritten by a turn.
        (should (equal "Wait for the Stone Co sample."
                       (plist-get (harness-call 'workspace/thread id thread-id)
                                  :next-action)))))))

(ert-deftest harness-workspace-a-note-is-written-once ()
  "Writing the same statement twice leaves one block, and answers with it."
  (harness-workspace-test-with
    (let* ((workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id))
           (thread (harness-call 'workspace/thread/create id "Kitchen renovation"))
           (thread-id (plist-get thread :id))
           (page (plist-get thread :page))
           (first (harness-call 'knowledge/write id thread-id 'note
                                "The grout is warm grey."
                                (list :session "s-1" :node "n-1")))
           ;; The same statement with its whitespace runs and case moved.
           (again (harness-call 'knowledge/write id thread-id 'note
                                "  the grout  is warm grey. "
                                (list :session "s-2" :node "n-2")))
           (other (harness-call 'knowledge/write id thread-id 'note
                                "The tile is matte."
                                (list :session "s-3" :node "n-3")))
           (blocks (plist-get (harness-call 'knowledge/page id page) :blocks)))
      (should (equal (plist-get first :id) (plist-get again :id)))
      (should-not (equal (plist-get first :id) (plist-get other :id)))
      (should (= 2 (length (cl-remove-if
                            (lambda (block) (string-blank-p (plist-get block :text)))
                            blocks))))
      (should (= 1 (cl-count-if
                    (lambda (block) (string-match-p "grout" (plist-get block :text)))
                    blocks)))
      ;; The first copy keeps the turn that taught it.
      (should (equal "s-1" (cdr (assoc "source-session"
                                       (plist-get first :properties))))))))

(ert-deftest harness-workspace-a-note-holds-no-secret ()
  "A statement the secrets module would mask is written masked, not whole."
  (harness-workspace-test-with
    (let* ((workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id))
           (thread (harness-call 'workspace/thread/create id "Kitchen renovation"))
           (thread-id (plist-get thread :id))
           (page (plist-get thread :page))
           (value "sk-live-0123456789abcdef")
           (block (progn
                    (cl-letf (((symbol-function 'harness-secrets-mask-text)
                               (lambda (text)
                                 (cons (replace-regexp-in-string
                                        (regexp-quote value) "[redacted: key a1b2]" text)
                                       nil))))
                      (harness-call 'knowledge/write id thread-id 'note
                                    (format "The vendor key is %s." value)
                                    (list :session "s-1")))))
           (text (harness-read-file
                  (harness-logseq-page-file page harness-logseq-directory))))
      (should (plist-get block :id))
      (should-not (string-match-p (regexp-quote value) text))
      (should (string-match-p "redacted: key" text)))))

(ert-deftest harness-workspace-dream-keeps-one-note-and-refreshes-the-page ()
  "The dream removes a duplicate note, writes the page's state and reports it."
  (harness-workspace-test-with
    (let* ((harness-workspace-knowledge-dream-report t)
           (workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id))
           (thread (harness-call 'workspace/thread/create id "Notes"))
           (thread-id (plist-get thread :id))
           (page (plist-get thread :page)))
      (harness-call 'knowledge/write id thread-id 'note "The grout is warm grey."
                    (list :session "s-1" :node "n-1"))
      ;; The write path keeps one copy, so the duplicate is put on the page
      ;; the way an older graph or a hand edit would leave it.
      (harness-call 'logseq/page-add page "The grout is warm grey."
                    (list :root harness-logseq-directory
                          :properties (list (cons "workspace-id" id)
                                            (cons "role" "note"))))
      (harness-call 'knowledge/write id thread-id 'note "The tile is matte."
                    (list :session "s-3" :node "n-3"))
      (harness-call 'workspace/thread/update id thread-id
                    :summary "The kitchen renovation is underway."
                    :next-action "Wait for the Stone Co sample.")
      ;; A dry run reports the duplicate and writes nothing.
      (let ((report (harness-call 'knowledge/dream id (list :dry-run t))))
        (should (= 1 (plist-get report :removed)))
        (should (plist-get report :dry-run))
        (should (= 2 (cl-count-if
                      (lambda (block) (string-match-p "grout" (plist-get block :text)))
                      (plist-get (harness-call 'knowledge/page id page) :blocks)))))
      ;; The run itself keeps the first note, the other note and the page state.
      (let ((report (harness-call 'knowledge/dream id)))
        (should (= 1 (plist-get report :removed)))
        (should (= 1 (plist-get report :pages)))
        (should (plist-get report :report-page)))
      (let* ((blocks (plist-get (harness-call 'knowledge/page id page) :blocks))
             (content (harness-read-file (harness-logseq-page-file page harness-logseq-directory))))
        (should (= 1 (cl-count-if
                      (lambda (block) (string-match-p "grout" (plist-get block :text)))
                      blocks)))
        (should (cl-find-if (lambda (block) (string-match-p "tile" (plist-get block :text)))
                            blocks))
        (should (string-match-p "summary:: The kitchen renovation is underway" content))
        (should (string-match-p "next-action:: Wait for the Stone Co sample" content)))
      (let ((report-page (expand-file-name
                          (format "pages/Dreams/%s.md" (format-time-string "%Y-%m-%d"))
                          harness-logseq-directory)))
        (should (file-exists-p report-page))
        (let ((content (harness-read-file report-page)))
          (should (string-match-p "Dream over Home" content))
          (should (string-match-p "removed a duplicate note" content))
          (should (string-match-p "Notes" content))))
      ;; A second dream finds nothing and writes no second report.
      (let ((report (harness-call 'knowledge/dream id)))
        (should (= 0 (plist-get report :removed)))
        (should-not (plist-get report :report-page))))))

(ert-deftest harness-workspace-dream-is-scheduled-once-a-day ()
  "The nightly dream is due at the configured hour, records its run and repeats."
  (harness-workspace-test-with
    (let* ((harness-workspace-knowledge-dream 'auto)
           (workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id))
           (today (format-time-string "%Y-%m-%d")))
      ;; The next dream is within the day and in the future.
      (let ((next (harness-workspace-knowledge--next-dream-time)))
        (should (> next (float-time)))
        (should (<= (- next (float-time)) 86401)))
      ;; A workspace dreamed today is left alone; one dreamed before runs.
      (harness-workspace-knowledge--dream-record id "2000-01-01")
      (should (equal "2000-01-01"
                     (cdr (assoc id (harness-workspace-knowledge--dreams)))))
      (harness-workspace-knowledge--dream-tick)
      (should (equal today (cdr (assoc id (harness-workspace-knowledge--dreams)))))
      (should (timerp harness-workspace-knowledge--dream-timer))
      ;; A second tick keeps the record and writes no second report.
      (let ((dreams (harness-workspace-knowledge--dreams)))
        (harness-workspace-knowledge--dream-tick)
        (should (equal dreams (harness-workspace-knowledge--dreams))))
      (cancel-timer harness-workspace-knowledge--dream-timer)
      (setq harness-workspace-knowledge--dream-timer nil))))

(ert-deftest harness-workspace-survives-a-restart ()
  "A workspace, its threads and its knowledge survive a fresh load."
  (harness-workspace-test-with
    (let* ((workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id)))
      (harness-call 'workspace/prompt id "The tile is matte.")
      (harness-workspace-test-wait-for
       (lambda () (harness-workspace-test-assistant-messages id)))
      (let ((thread (car (plist-get (harness-call 'workspace/get id) :threads))))
        (clrhash harness-workspace--table)
        (setq harness-workspace--loaded nil)
        (let ((again (harness-call 'workspace/get id)))
          (should (equal "Home" (plist-get again :name)))
          (should (= 1 (length (plist-get again :threads))))
          (should (equal (plist-get thread :id)
                         (plist-get (car (plist-get again :threads)) :id))))
        (should (harness-call 'knowledge/search id "matte"))))))

(ert-deftest harness-workspace-brief-names-the-thread-and-knowledge ()
  "The digest a chat or a call asks for names the workspace and its thread."
  (harness-workspace-test-with
    (let* ((workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id)))
      (harness-call 'workspace/prompt id "The tile is matte.")
      (harness-workspace-test-wait-for
       (lambda () (harness-workspace-test-assistant-messages id)))
      (let ((brief (harness-call 'workspace/brief id)))
        (should (equal "Home" (plist-get brief :workspace)))
        (should (= 1 (plist-get brief :threads)))
        (should (equal "live" (plist-get brief :last-state)))
        (should (plist-get brief :knowledge))))))

(ert-deftest harness-workspace-routes-by-title-and-topic-cue ()
  "A thread named in the message is revived; a topic cue starts a new one."
  (harness-workspace-test-with
    (let* ((workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id))
           (thread (harness-call 'workspace/thread/create id "Kitchen renovation")))
      (harness-call 'workspace/prompt id "Let's talk about the kitchen renovation.")
      (harness-workspace-test-wait-for
       (lambda () (harness-workspace-test-assistant-messages id)))
      (harness-workspace-test-wait-idle
       (plist-get (harness-call 'workspace/thread id (plist-get thread :id)) :live))
      (should (plist-get (harness-call 'workspace/thread id (plist-get thread :id)) :live))
      (harness-call 'workspace/prompt id "new topic: taxes")
      (harness-workspace-test-wait-for
       (lambda () (= 2 (length (plist-get (harness-call 'workspace/get id) :threads)))))
      (should (= 2 (length (plist-get (harness-call 'workspace/get id) :threads)))))))

(ert-deftest harness-workspace-knowledge-tools-answer-in-an-episode ()
  "knowledge_search and knowledge_write work with an episode's context."
  (harness-workspace-test-with
    (let* ((workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id)))
      (harness-call 'workspace/prompt id "The tile is matte.")
      (harness-workspace-test-wait-for
       (lambda () (harness-workspace-test-assistant-messages id)))
      (let* ((thread (car (plist-get (harness-call 'workspace/get id) :threads)))
             (session (plist-get thread :live))
             (ctx (list :session-id session))
             (searched (harness-workspace-knowledge--tool-search '(:query "matte") ctx))
             (written (harness-workspace-knowledge--tool-write
                       '(:text "The grout is warm grey.") ctx)))
        (harness-workspace-test-wait-idle session)
        (should-not (plist-get searched :is-error))
        (should (string-match-p "matte" (plist-get searched :content)))
        (should-not (plist-get written :is-error))
        (should (harness-call 'knowledge/search id "warm grey"))
        (let ((page (plist-get thread :page)))
          (should page)
          (should (string-match-p
                   (regexp-quote "The grout is warm grey.")
                   (harness-read-file (harness-logseq-page-file page
                                                               harness-logseq-directory)))))))))

(ert-deftest harness-workspace-semantic-search-ranks-by-meaning ()
  "With an embedding model, the semantic mode ranks by meaning and the tool takes it."
  (harness-workspace-test-with
    (harness-register-method
     'provider/embed
     (lambda (_model texts &optional _opts)
       (harness-resolved
        (list :vectors (mapcar (lambda (text)
                                 (let ((text (downcase text)))
                                   (list (if (string-match-p
                                              "grout\|grey\|warm\|shade\|colour\|color"
                                              text)
                                             1.0 0.0)
                                         (if (string-match-p "tile\|matte\|finish" text)
                                             1.0 0.0))))
                               texts)
              :usage (list :input 1)))))
    (let* ((harness-workspace-knowledge-embedding-model "test:embed")
           (workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id)))
      (harness-call 'workspace/prompt id "The tile is matte.")
      (harness-workspace-test-wait-for
       (lambda () (harness-workspace-test-assistant-messages id)))
      (let* ((thread (car (plist-get (harness-call 'workspace/get id) :threads)))
             (thread-id (plist-get thread :id))
             (session (plist-get thread :live)))
        (harness-call 'knowledge/write id thread-id 'note "The grout is warm grey."
                      (list :session "s-1" :node "n-1"))
        (harness-call 'knowledge/write id thread-id 'note "The tile is matte."
                      (list :session "s-2" :node "n-2"))
        ;; No word matches "shade"; the meaning does.
        (should-not (harness-call 'knowledge/search id "shade"
                                  (list :thread thread-id)))
        (let ((by-meaning (harness-test-await
                           (harness-call 'knowledge/search id "shade"
                                         (list :semantic t :thread thread-id)))))
          (should (equal "The grout is warm grey."
                         (plist-get (car by-meaning) :text))))
        ;; The tool's semantic mode answers with the same block.
        (let ((answer (harness-test-await
                       (harness-workspace-knowledge--tool-search
                        '(:query "shade" :mode "semantic")
                        (list :session-id session)))))
          (should-not (plist-get answer :is-error))
          (should (string-match-p "grout is warm grey" (plist-get answer :content))))
        ;; Without a model, the mode says what is missing instead of guessing.
        (let ((harness-workspace-knowledge-embedding-model nil))
          (should-error (harness-call 'knowledge/search id "shade"
                                      (list :semantic t :thread thread-id))
                        :type 'harness-error))
        (harness-workspace-test-wait-idle session)))))

(ert-deftest harness-workspace-resources-answer-what-the-computer-has ()
  "The resources methods exist and never carry a value; without a running
computer they say so, and a browser mutation refuses rather than pretending."
  (harness-workspace-test-with
    (let* ((workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id))
           (status (harness-call 'workspace/resources/status id))
           (create (harness-call 'workspace/wallet/authorization/create id
                                 :card "card-1" :amount 1000 :currency "USD"
                                 :cap-kind "cumulative"))
           (revoke (harness-call 'workspace/wallet/authorization/revoke id "auth-1"))
           (decide (harness-call 'workspace/wallet/purchase/decide id "buy-1" "allow")))
      (dolist (method '(workspace/resources/status workspace/browser/clear
                                                workspace/browser/login/forget
                                                workspace/wallet/authorization/create
                                                workspace/wallet/authorization/revoke
                                                workspace/wallet/purchase/decide))
        (should (harness-method-exists-p method)))
      (should (equal "unavailable" (plist-get status :status)))
      (should (member (plist-get status :reason)
                      '("box-not-running" "box-tools-missing" "backend-unavailable")))
      (should (eq t (plist-get status :metadata-only)))
      (should-not (plist-get status :browser))
      (should-not (plist-get status :wallet))
      (should-not (plist-get status :access))
      (should-not (plist-get status :audit))
      (should (equal "unavailable" (plist-get status :browser-status)))
      (should (equal "unavailable" (plist-get status :wallet-status)))
      (dolist (answer (list create revoke decide))
        (should (equal "unavailable" (plist-get answer :status)))
        (should (equal "wallet-unavailable" (plist-get answer :reason)))
        (should (eq t (plist-get answer :metadata-only)))
        (should-not (plist-get answer :changed))
        (dolist (forbidden '(:value :secret :token :password :pan :cvv :number))
          (should-not (plist-get answer forbidden))))
      (should (equal "auth-1" (plist-get revoke :authorization)))
      (should (equal "buy-1" (plist-get decide :purchase)))
      (should (equal "allow" (plist-get decide :decision)))
      (should-not (plist-get create :plist))
      ;; A browser mutation on a stopped computer refuses, with the reason.
      (should-error (harness-call 'workspace/browser/clear id "site"
                                  "https://stoneco.example" '("cookies"))
                    :type 'harness-error)
      (should-error (harness-call 'workspace/browser/login/forget id "lg-1")
                    :type 'harness-error)
      ;; A blocked mutation changes nothing.
      (should (null (plist-get (harness-call 'workspace/get id) :threads))))))

(ert-deftest harness-workspace-resources-list-declared-secrets-as-credentials ()
  "The resources answer lists secrets through secret-sandbox, without values."
  (harness-workspace-test-with
    (dolist (module '(secrets perms sandbox secret-sandbox))
      (harness-test-load-module module))
    (let* ((workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id))
           (file (expand-file-name "creds.json" harness-state-directory))
           (harness-secrets-sources
            (list (list :label "deploy-key" :file file :json-path "token"))))
      (with-temp-file file
        (insert (json-encode '(("token" . "s3cr3t-VALUE-0123456789")))))
      (harness-secrets-forget)
      (let* ((answer (harness-call 'workspace/resources/status id))
             (credentials (plist-get answer :credentials))
             (first (car credentials)))
        (should (equal "ready" (plist-get answer :status)))
        (should (eq t (plist-get answer :metadata-only)))
        (should (= 1 (length credentials)))
        (should (equal "deploy-key" (plist-get first :label)))
        (should (stringp (plist-get first :fingerprint)))
        (should (not (plist-get first :value)))
        (dolist (forbidden '(:value :secret :token :password :pan :cvv :number))
          (should-not (plist-get first forbidden)))
        (should (= 1 (plist-get (plist-get answer :credentials-status) :count)))
        ;; The browser and wallet are still off, and say so.
        (should-not (plist-get answer :browser))
        (should-not (plist-get answer :wallet))
        (should (equal "unavailable" (plist-get answer :browser-status)))
        (should (member (plist-get (plist-get answer :browser-reason) :code)
                        '("box-not-running" "box-tools-missing"
                          "backend-unavailable")))))))

(ert-deftest harness-workspace-thread-merge-keeps-both-timelines ()
  "A merged thread is parked, names its target, and its entries stay in
the target's timeline."
  (harness-workspace-test-with
    (let* ((workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id))
           (source (harness-call 'workspace/thread/create id "Kitchen"))
           (target (harness-call 'workspace/thread/create id "Quote")))
      (harness-call 'workspace/prompt id "The tile is matte."
                    (list :thread (plist-get source :id)))
      (harness-workspace-test-wait-for
       (lambda () (harness-workspace-test-assistant-messages id)))
      (let ((merged (harness-call 'workspace/thread/merge
                                  id (plist-get source :id) (plist-get target :id))))
        (should (equal (plist-get target :id) (plist-get merged :id)))
        (should (member (plist-get source :id) (plist-get merged :merged-from))))
      (let* ((source-now (harness-call 'workspace/thread id (plist-get source :id)))
             (timeline (harness-call 'workspace/timeline
                                     id (list :thread (plist-get target :id)))))
        (should (equal "merged" (plist-get source-now :state)))
        (should (equal (plist-get target :id) (plist-get source-now :merged-into)))
        (should (cl-find-if (lambda (entry)
                              (equal (plist-get source :id)
                                     (plist-get entry :thread)))
                            timeline))))))

(ert-deftest harness-workspace-knowledge-reads-and-pages-the-graph ()
  "Knowledge can be written, read by page, paged by thread and recalled."
  (harness-workspace-test-with
    (let* ((workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id))
           (thread (harness-call 'workspace/thread/create id "Notes"))
           (page (plist-get thread :page)))
      (should page)
      (harness-call 'knowledge/write id (plist-get thread :id) 'assistant
                    "The grout is warm grey."
                    (list :session "s-test" :node "n-test"))
      (let ((read (harness-call 'knowledge/page id page))
            (pages (harness-call 'knowledge/pages id))
            (recall (harness-call 'knowledge/recall id (plist-get thread :id) "grout"))
            (status (harness-call 'knowledge/status id))
            (file (harness-logseq-page-file page harness-logseq-directory)))
        (should (cl-find-if (lambda (block)
                              (string-match-p "warm grey" (plist-get block :text)))
                            (plist-get read :blocks)))
        (should (cl-find-if (lambda (item) (equal page (plist-get item :page))) pages))
        (should (cl-find-if (lambda (block)
                              (string-match-p "warm grey" (plist-get block :text)))
                            recall))
        (should (>= (plist-get status :notes) 1))
        (let ((content (harness-read-file file)))
          ;; The block is a Logseq bullet with provenance, and a note:
          ;; a block on its own thread's page does not link the page.
          (should (string-match-p "^- The grout is warm grey" content))
          (should (string-match-p "workspace-id:: " content))
          (should (string-match-p "role:: note" content))
          (should-not (string-match-p "thread:: " content))
          (should (string-match-p "source-session:: s-test" content))
          (should-not (string-match-p "^#\|^---" content)))))))

(defun harness-workspace-test-assistant-text (id)
  "Return the text of the newest assistant entry of workspace ID."
  (let ((entries (harness-workspace-test-assistant-messages id)))
    (if entries (or (plist-get (car (last entries)) :text) "") "")))

(ert-deftest harness-workspace-streams-a-multi-chunk-reply ()
  "A streamed reply grows in the timeline and is kept whole.
Thinking chunks are not answer text, and the timeline is the
source of truth again after a fresh harness process reads it."
  (harness-workspace-test-with
    (let* ((harness-provider-demo-script-override
            harness-workspace-test-stream-script)
           (harness-provider-demo--delay 0.02)
           (workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id))
           (snapshots nil))
      (let ((handle (harness-on
                     'agent/stream
                     (lambda (_session _node kind delta)
                       (when (eq kind 'assistant)
                         (push (list delta
                                     (harness-workspace-test-assistant-text id))
                               snapshots))))))
        (unwind-protect
            (progn
              (harness-call 'workspace/prompt id "How is the quote?")
              (harness-workspace-test-wait-for
               (lambda () (= 3 (length snapshots))))
              (let ((thread (car (plist-get (harness-call 'workspace/get id) :threads))))
                (harness-workspace-test-wait-idle (plist-get thread :live))))
          (harness-off handle)))
      (setq snapshots (nreverse snapshots))
      ;; Each delta is its own chunk; the timeline read at that moment
      ;; already holds the words so far, never only the newest chunk and
      ;; never the accumulated text twice.
      (should (equal '("The " "quote " "is open.")
                     (mapcar #'car snapshots)))
      (should (equal '("The " "The quote " "The quote is open.")
                     (mapcar #'cadr snapshots)))
      (let* ((messages (harness-workspace-test-assistant-messages id))
             (thread (car (plist-get (harness-call 'workspace/get id) :threads))))
        (should (= 1 (length messages)))
        (should (equal "The quote is open." (plist-get (car messages) :text)))
        (should (equal "The quote is open." (plist-get thread :summary)))
        (should-not (cl-some (lambda (entry)
                               (string-match-p "asked about the quote"
                                               (or (plist-get entry :text) "")))
                             (harness-call 'workspace/timeline id))))
      ;; Replay: a fresh process has the session's nodes and the workspace
      ;; timeline, and still reads one complete answer, not the first chunk.
      (clrhash harness-sessions)
      (harness-session--load-all)
      (let ((messages (harness-workspace-test-assistant-messages id)))
        (should (= 1 (length messages)))
        (should (equal "The quote is open." (plist-get (car messages) :text)))))))

(ert-deftest harness-workspace-streaming-keeps-threads-apart ()
  "A reply in one thread changes only that thread's entries."
  (harness-workspace-test-with
    (let ((harness-provider-demo-script-override
           harness-workspace-test-stream-script)
          (harness-provider-demo--delay 0.01))
      (let* ((workspace (harness-workspace-test-workspace))
             (id (plist-get workspace :id))
             (first (harness-call 'workspace/thread/create id "Kitchen"))
             (second (harness-call 'workspace/thread/create id "Taxes")))
        (harness-call 'workspace/prompt id "How is the kitchen quote?"
                      (list :thread (plist-get first :id)))
        (harness-workspace-test-wait-for
         (lambda ()
           (let ((thread (harness-call 'workspace/thread id (plist-get first :id))))
             (and (plist-get thread :live)
                  (equal "The quote is open."
                         (harness-workspace-test-assistant-text id))))))
        (let ((first-text (harness-workspace-test-assistant-text id)))
          (harness-call 'workspace/prompt id "How are the taxes?"
                        (list :thread (plist-get second :id)))
          (harness-workspace-test-wait-for
           (lambda ()
             (let ((entries (harness-workspace-test-assistant-messages id)))
               (and (= 2 (length entries))
                    (equal "The quote is open."
                           (plist-get
                            (cl-find (plist-get second :id) entries
                                     :key (lambda (entry)
                                            (plist-get entry :thread))
                                     :test #'equal)
                            :text))))))
          (let ((entries (harness-workspace-test-assistant-messages id)))
            (should (= 2 (length entries)))
            (should (equal first-text
                           (plist-get (cl-find (plist-get first :id) entries
                                               :key (lambda (entry)
                                                      (plist-get entry :thread))
                                               :test #'equal)
                                      :text)))
            (should (equal "The quote is open."
                           (plist-get (cl-find (plist-get second :id) entries
                                               :key (lambda (entry)
                                                      (plist-get entry :thread))
                                               :test #'equal)
                                      :text)))
            (let ((filtered (harness-call 'workspace/timeline id
                                          (list :thread (plist-get first :id)))))
              (should (cl-every (lambda (entry)
                                  (equal (plist-get first :id)
                                         (plist-get entry :thread)))
                                filtered))
              (should (cl-find-if
                       (lambda (entry)
                         (and (equal "message" (format "%s" (plist-get entry :kind)))
                              (equal "assistant" (format "%s" (plist-get entry :role)))))
                       filtered)))))
        (dolist (thread (list first second))
          (let ((live (plist-get (harness-call 'workspace/thread id
                                               (plist-get thread :id))
                                 :live)))
            (when live (harness-workspace-test-wait-idle live))))))))

(ert-deftest harness-workspace-knowledge-does-not-take-the-memory-names ()
  "The workspace's graph methods are its own; memory/search stays the memory's.
Both modules are loaded, as a dev harness loads every module, and the
generic search keeps its one-argument contract while the workspace's
knowledge search takes a workspace."
  (harness-workspace-test-with
    (let* ((workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id)))
      ;; The methods are different names and both exist.
      (should (harness-method-exists-p 'memory/search))
      (should (harness-method-exists-p 'knowledge/search))
      (should-not (equal (symbol-function 'harness-method/memory/search)
                         (symbol-function 'harness-method/knowledge/search)))
      ;; A generic memory saved for the project is found by the generic search,
      ;; not by the workspace's knowledge search.
      (harness-call 'memory/add "The user prefers short answers."
                    (list :kind "preference" :scope "project"
                          :project (expand-file-name "workspace/" harness-state-directory)))
      (let ((memories (harness-call 'memory/search "short answers"
                                    (list :project (expand-file-name
                                                    "workspace/" harness-state-directory)))))
        (should (cl-find-if (lambda (memory)
                              (string-match-p "short answers"
                                              (plist-get memory :text)))
                            memories)))
      (harness-call 'workspace/prompt id "The tile is matte.")
      (harness-workspace-test-wait-for
       (lambda () (harness-workspace-test-assistant-messages id)))
      (harness-workspace-test-wait-idle
       (plist-get (car (plist-get (harness-call 'workspace/get id) :threads)) :live))
      (let ((found (harness-call 'knowledge/search id "matte")))
        (should (cl-find-if (lambda (block)
                              (string-match-p "matte" (plist-get block :text)))
                            found)))
      ;; The knowledge tools belong to the workspace episode, not to a plain
      ;; session, and the memory tools stay in both.
      (let* ((thread (car (plist-get (harness-call 'workspace/get id) :threads)))
             (episode (plist-get thread :live))
             (plain (harness-call 'session/create :kind 'chat
                                  :cwd (expand-file-name "workspace/" harness-state-directory))))
        (let ((episode-tools (harness-tools--names
                              (harness-call 'session/get episode)))
              (plain-tools (harness-tools--names
                            (harness-call 'session/get (plist-get plain :id)))))
          (dolist (name '("knowledge_search" "knowledge_write"
                          "knowledge_read" "knowledge_status"))
            (should (member name episode-tools))
            (should-not (member name plain-tools)))
          (should (member "memory_save" episode-tools))
          (should (member "memory_save" plain-tools)))))))

(ert-deftest harness-workspace-knowledge-answers-the-apps-memory-calls ()
  "The app's `memory/...' calls with a workspace reach the knowledge methods.
Without a workspace they still reach the harness's own memory tools, and
the method catalogue offers the aliases the app checks for."
  (harness-workspace-test-with
    (let* ((workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id)))
      (harness-call 'workspace/prompt id "Remember that the grout is warm grey.")
      (harness-workspace-test-wait-for
       (lambda () (harness-workspace-test-assistant-messages id)))
      (harness-workspace-test-wait-idle
       (plist-get (car (plist-get (harness-call 'workspace/get id) :threads)) :live))
      (should (equal "knowledge/search"
                     (harness-acp--method-alias
                      "memory/search" (list :workspace id :query "grout"))))
      (should-not (harness-acp--method-alias "memory/search" (list :query "grout")))
      (should (member "memory/status" (harness-acp--extension-methods)))
      (let ((found (harness-acp--call-extension
                    "memory/search" (list :workspace id :query "grout"))))
        (should (cl-find-if (lambda (block)
                              (string-match-p "grout" (plist-get block :text)))
                            found)))
      (let ((status (harness-acp--call-extension "memory/status" (list :workspace id))))
        (should (>= (plist-get status :notes) 2))))))

(ert-deftest harness-workspace-an-idle-thread-starts-a-new-episode ()
  "A live thread idle past `harness-workspace-thread-idle-hours' is revived."
  (harness-workspace-test-with
    (let* ((workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id)))
      (harness-call 'workspace/prompt id "The tile is matte.")
      (harness-workspace-test-wait-for
       (lambda () (harness-workspace-test-assistant-messages id)))
      (let* ((thread (harness-workspace-test-graph-thread id))
             (internal (harness-workspace--thread
                        (harness-workspace--get id) (plist-get thread :id))))
        ;; The episode was live, but the person came back much later.
        (setf (plist-get internal :last-at)
              (- (harness-workspace--now)
                 (* 3600 (1+ harness-workspace-thread-idle-hours))))
        (harness-workspace--save (harness-workspace--get id))
        (harness-call 'workspace/prompt id "And the grout is light.")
        (harness-workspace-test-wait-for
         (lambda () (= 2 (length (harness-workspace-test-assistant-messages id)))))
        (let* ((thread (car (plist-get (harness-call 'workspace/get id) :threads)))
               (dividers (cl-remove-if-not
                          (lambda (entry)
                            (eq (harness-workspace--entry-kind entry) 'divider))
                          (harness-call 'workspace/timeline id))))
          (should (= 2 (length (plist-get thread :episodes))))
          (should (equal "revived"
                         (format "%s" (plist-get (car (last dividers)) :reason)))))))))

(ert-deftest harness-workspace-slash-continue-keeps-the-thread ()
  "`/continue' keeps the message in the current thread, whatever it says."
  (harness-workspace-test-with
    (let* ((workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id)))
      (harness-call 'workspace/prompt id "The tile is matte.")
      (harness-workspace-test-wait-for
       (lambda () (harness-workspace-test-assistant-messages id)))
      (harness-workspace-test-wait-idle
       (plist-get (car (plist-get (harness-call 'workspace/get id) :threads)) :live))
      ;; The words alone would start a thread: the cue says so.
      (harness-call 'workspace/prompt id
                    "/continue new topic: my sister's wedding is in June")
      (harness-workspace-test-wait-for
       (lambda () (= 2 (length (harness-workspace-test-assistant-messages id)))))
      (should (= 1 (length (plist-get (harness-call 'workspace/get id) :threads)))))))


(ert-deftest harness-workspace-selected-thread-does-not-bind-a-new-topic ()
  "The thread a client selected is a preference: a topic cue still splits."
  (harness-workspace-test-with
    (let* ((workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id))
           (thread (harness-call 'workspace/thread/create id "Kitchen renovation")))
      (harness-call 'workspace/prompt id "The tile is matte."
                    (list :thread (plist-get thread :id)))
      (harness-workspace-test-wait-for
       (lambda () (harness-workspace-test-assistant-messages id)))
      (harness-workspace-test-wait-idle
       (plist-get (harness-call 'workspace/thread id (plist-get thread :id)) :live))
      (harness-call 'workspace/prompt id "new topic: taxes"
                    (list :thread (plist-get thread :id)))
      (harness-workspace-test-wait-for
       (lambda () (= 2 (length (plist-get (harness-call 'workspace/get id) :threads)))))
      (let ((threads (plist-get (harness-call 'workspace/get id) :threads)))
        (should (= 2 (length threads)))
        (should (member "taxes" (mapcar (lambda (thread) (plist-get thread :title)) threads)))))))


(ert-deftest harness-workspace-force-thread-keeps-the-message-there ()
  "\`:force-thread' binds the thread whatever the message says."
  (harness-workspace-test-with
    (let* ((workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id))
           (thread (harness-call 'workspace/thread/create id "Kitchen renovation")))
      (harness-call 'workspace/prompt id "new topic: taxes"
                    (list :force-thread (plist-get thread :id)))
      (harness-workspace-test-wait-for
       (lambda () (harness-workspace-test-assistant-messages id)))
      (let ((view (harness-call 'workspace/get id)))
        (should (= 1 (length (plist-get view :threads))))
        (should (equal (plist-get thread :id)
                       (plist-get (car (plist-get view :threads)) :id)))))))


(ert-deftest harness-workspace-a-switch-to-a-named-thread-revives-it ()
  "\"Switch to the kitchen renovation\" goes to that thread, not a new one."
  (harness-workspace-test-with
    (let* ((workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id))
           (kitchen (harness-call 'workspace/thread/create id "Kitchen renovation")))
      (harness-call 'workspace/prompt id "The tile is matte."
                    (list :thread (plist-get kitchen :id)))
      (harness-workspace-test-wait-for
       (lambda () (harness-workspace-test-assistant-messages id)))
      (harness-workspace-test-wait-idle
       (plist-get (harness-call 'workspace/thread id (plist-get kitchen :id)) :live))
      (harness-call 'workspace/prompt id "new topic: taxes"
                    (list :thread (plist-get kitchen :id)))
      (harness-workspace-test-wait-for
       (lambda () (= 2 (length (plist-get (harness-call 'workspace/get id) :threads)))))
      (harness-call 'workspace/prompt id "Switch to the kitchen renovation.")
      (harness-workspace-test-wait-for
       (lambda ()
         (let ((view (harness-call 'workspace/get id)))
           (and (= 2 (length (plist-get view :threads)))
                (equal (plist-get kitchen :id) (plist-get view :last-thread))))))
      (should (= 2 (length (plist-get (harness-call 'workspace/get id) :threads)))))))


(ert-deftest harness-workspace-a-fresh-subject-starts-a-thread ()
  "Three new words with nothing of the thread's in them start a new thread."
  (harness-workspace-test-with
    (let* ((workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id)))
      (harness-call 'workspace/prompt id "The tile is matte.")
      (harness-workspace-test-wait-for
       (lambda () (harness-workspace-test-assistant-messages id)))
      (harness-workspace-test-wait-idle
       (plist-get (car (plist-get (harness-call 'workspace/get id) :threads)) :live))
      (harness-call 'workspace/prompt id "My sister's wedding is in June.")
      (harness-workspace-test-wait-for
       (lambda () (= 2 (length (plist-get (harness-call 'workspace/get id) :threads)))))
      (should (= 2 (length (plist-get (harness-call 'workspace/get id) :threads)))))))


(ert-deftest harness-workspace-a-message-for-an-older-thread-goes-back-to-it ()
  "A message whose words belong to an older thread revives it."
  (harness-workspace-test-with
    (let* ((workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id))
           (kitchen (harness-call 'workspace/thread/create id
                                  "Kitchen renovation plans for spring"))
           (kitchen-id (plist-get kitchen :id)))
      (harness-call 'workspace/prompt id
                    "The kitchen renovation plans need a new sink."
                    (list :force-thread kitchen-id))
      (harness-workspace-test-wait-for
       (lambda () (harness-workspace-test-assistant-messages id)))
      (harness-workspace-test-wait-idle
       (plist-get (harness-call 'workspace/thread id kitchen-id) :live))
      (harness-call 'workspace/prompt id "new topic: the tax return for last year")
      (harness-workspace-test-wait-for
       (lambda () (= 2 (length (plist-get (harness-call 'workspace/get id) :threads)))))
      (harness-workspace-test-wait-idle
       (plist-get (car (plist-get (harness-call 'workspace/get id) :threads)) :live))
      ;; The words are the kitchen thread's, though the message names no
      ;; thread: it goes back there rather than starting a third.
      (harness-call 'workspace/prompt id "The kitchen renovation budget is tight.")
      (harness-workspace-test-wait-for
       (lambda () (equal kitchen-id
                         (plist-get (harness-call 'workspace/get id) :last-thread))))
      (should (equal kitchen-id
                     (plist-get (harness-call 'workspace/get id) :last-thread)))
      (should (= 2 (length (plist-get (harness-call 'workspace/get id) :threads)))))))


(ert-deftest harness-workspace-a-continuation-keeps-the-thread ()
  "A message tied to the one before it, or about the thread, keeps it."
  (harness-workspace-test-with
    (let* ((workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id)))
      (harness-call 'workspace/prompt id "The tile is matte.")
      (harness-workspace-test-wait-for
       (lambda () (harness-workspace-test-assistant-messages id)))
      (harness-workspace-test-wait-idle
       (plist-get (car (plist-get (harness-call 'workspace/get id) :threads)) :live))
      (harness-call 'workspace/prompt id "And the grout is light.")
      (harness-workspace-test-wait-for
       (lambda () (= 2 (length (harness-workspace-test-assistant-messages id)))))
      (should (= 1 (length (plist-get (harness-call 'workspace/get id) :threads))))
      (harness-call 'workspace/prompt id "What about the tile colour?")
      (harness-workspace-test-wait-for
       (lambda () (= 3 (length (harness-workspace-test-assistant-messages id)))))
      (should (= 1 (length (plist-get (harness-call 'workspace/get id) :threads)))))))


(ert-deftest harness-workspace-ranker-places-a-message-by-its-words ()
  "The router ranks a message against the threads' own words, with no model.
A title's word outweighs a passing one, a subject no thread holds starts
a thread, and a message another thread holds goes back to it."
  (harness-workspace-test-with
    (let* ((workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id))
           (kitchen (harness-call 'workspace/thread/create id "Kitchen renovation"))
           (taxes (harness-call 'workspace/thread/create id "Tax return")))
      (harness-workspace--append
       workspace
       (list :kind 'message :thread (plist-get kitchen :id)
             :role 'user :text "The sink is leaking under the window."))
      (harness-workspace--append
       workspace
       (list :kind 'message :thread (plist-get taxes :id)
             :role 'user :text "The tax return for last year is filed."))
      ;; Creating a thread saved a newer record than the one in hand.
      (setq workspace (harness-workspace--get id))
      (setf (plist-get workspace :last-thread) (plist-get taxes :id))
      (harness-workspace--save workspace)
      (let* ((workspace (harness-call 'workspace/get id))
             (route (lambda (text) (harness-workspace--route workspace text nil))))
        ;; A message about the kitchen goes back to that thread.
        (let ((answer (funcall route "The kitchen counter needs sealing.")))
          (should (equal (plist-get kitchen :id) (plist-get (car answer) :id)))
          (should (eq 'revive (cadr answer)))
          (should (eq 'ranked (nth 2 answer))))
        ;; A message about the current thread's own subject keeps it.
        (let ((answer (funcall route "The tax return is filed.")))
          (should (equal (plist-get taxes :id) (plist-get (car answer) :id)))
          (should (eq 'continue (cadr answer))))
        ;; Three words no thread holds start a thread.
        (let ((answer (funcall route "My sister's wedding is in June.")))
          (should-not (car answer))
          (should (eq 'new (cadr answer)))
          (should (eq 'fresh (nth 2 answer))))
        ;; A soft cue naming another thread's subject goes there.
        (let ((answer (funcall route "What about the sink?")))
          (should (equal (plist-get kitchen :id) (plist-get (car answer) :id))))
        ;; A soft cue about nothing any thread holds starts one.
        (let ((answer (funcall route "What about lunch?")))
          (should-not (car answer))
          (should (eq 'cue (nth 2 answer))))
        ;; A soft cue the current thread hardly holds goes to the thread
        ;; that holds it, not to the thread the person was writing in.
        (setf (plist-get workspace :last-thread) (plist-get taxes :id))
        (harness-workspace--save workspace)
        (let* ((workspace (harness-call 'workspace/get id))
               (answer (harness-workspace--route workspace "What about the sink?" nil)))
          (should (equal (plist-get kitchen :id) (plist-get (car answer) :id))))
        ;; A continuation word does not tie a message to a thread that
        ;; holds none of it: the thread that holds its subject takes it.
        (let ((answer (funcall route "The tax colour is still undecided.")))
          (should (equal (plist-get taxes :id) (plist-get (car answer) :id)))
          (should (eq 'continue (cadr answer))))))))


(ert-deftest harness-workspace-router-meaning-places-a-paraphrase ()
  "With an embedding model, a thread the words do not match is found by meaning.
Another meaning still starts a thread."
  (harness-workspace-test-with
    (harness-register-method
     'provider/embed
     (lambda (_model texts &optional _opts)
       (harness-resolved
        (list :vectors
              (mapcar (lambda (text)
                        (let ((text (downcase text)))
                          (cond
                           ((string-match-p "tile\\|grout\\|shade\\|matte\\|colour\\|finish\\|warm" text)
                            (list 1.0 0.0 0.0))
                           ((string-match-p "wedding\\|sister\\|june" text)
                            (list 0.0 1.0 0.0))
                           ;; Nothing shares a direction with either topic.
                           (t (list 0.0 0.0 1.0)))))
                      texts)
              :usage (list :input 1)))))
    (let* ((harness-workspace-knowledge-embedding-model "test:embed")
           (workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id)))
      (harness-call 'workspace/prompt id "The tile is matte.")
      (harness-workspace-test-wait-for
       (lambda () (harness-workspace-test-assistant-messages id)))
      (harness-workspace-test-wait-idle
       (plist-get (car (plist-get (harness-call 'workspace/get id) :threads)) :live))
      ;; No word of the message is the thread's; the meaning is.
      (harness-call 'workspace/prompt id "What shade of grout suits the wall?")
      (harness-workspace-test-wait-for
       (lambda () (= 2 (length (harness-workspace-test-assistant-messages id)))))
      (should (= 1 (length (plist-get (harness-call 'workspace/get id) :threads))))
      ;; A different meaning starts a thread.
      (harness-call 'workspace/prompt id "My sister's wedding is in June.")
      (harness-workspace-test-wait-for
       (lambda () (= 2 (length (plist-get (harness-call 'workspace/get id) :threads)))))
      (should (= 2 (length (plist-get (harness-call 'workspace/get id) :threads)))))))


;;;; The graph explorer

(defun harness-workspace-test-graph-thread (id)
  "Return the live thread of workspace ID after its turn."
  (let ((thread (car (plist-get (harness-call 'workspace/get id) :threads))))
    (harness-workspace-test-wait-idle (plist-get thread :live))
    (car (plist-get (harness-call 'workspace/get id) :threads))))

(ert-deftest harness-workspace-knowledge-graph-explorer-reads-the-thread ()
  "The explorer answers the thread's page, its notes and its captures.
The page's identity bullet is not a node; the conversation's journal
captures link the page and are its backlinks."
  (harness-workspace-test-with
    (let* ((workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id)))
      (harness-call 'workspace/prompt id
                    "The tile is matte. Ask [[Stone Co]] for a sample.")
      (harness-workspace-test-wait-for
       (lambda () (harness-workspace-test-assistant-messages id)))
      (let* ((thread (harness-workspace-test-graph-thread id))
             (thread-id (plist-get thread :id)))
        (harness-call 'knowledge/write id thread-id 'assistant
                      "The grout is warm grey. Ask [[Stone Co]] again.")
        (let* ((graph (harness-call 'knowledge/graph id (list :thread thread-id)))
               (page (plist-get graph :page))
               (blocks (plist-get graph :blocks))
               (note (cl-find-if (lambda (block)
                                   (string-match-p "warm grey"
                                                   (plist-get block :text)))
                                 blocks))
               (backlink-texts (mapcar (lambda (block) (plist-get block :text))
                                       (plist-get graph :backlinks))))
          (should (equal "ready" (plist-get graph :status)))
          (should (equal thread-id (plist-get graph :thread-id)))
          (should (equal (plist-get thread :title) (plist-get graph :thread)))
          (should (equal (plist-get thread :page) (plist-get graph :page-name)))
          ;; The page name Logseq gets is clean: no [[...]] in it.
          (should-not (string-search "[[" (plist-get graph :page-name)))
          (should (equal thread-id
                         (cdr (assoc "thread-id" (plist-get page :properties)))))
          ;; A property-only bullet is the identity, not a node.
          (should (= 1 (length blocks)))
          (should note)
          (should (equal "note" (cdr (assoc "role" (plist-get note :properties)))))
          ;; A note on the thread's own page is not a link to itself.
          (should-not (assoc "thread" (plist-get note :properties)))
          (should (member "Stone Co" (plist-get note :links)))
          (should (member "Stone Co" (plist-get graph :links)))
          ;; The page's own name in a node's `thread' property is not a
          ;; page it links to.
          (should-not (member (plist-get thread :page) (plist-get graph :links)))
          ;; The conversation is captured in the journal, linking the page.
          (should (cl-find-if (lambda (text) (string-match-p "matte" text))
                              backlink-texts))
          (should (cl-find-if (lambda (text) (string-match-p "Noted" text))
                              backlink-texts))
          ;; The note is on the page, and links it: it is a node, not a
          ;; backlink to the page itself.
          (should-not (cl-find-if (lambda (text) (string-match-p "warm grey" text))
                                  backlink-texts)))))))

(ert-deftest harness-workspace-knowledge-graph-explorer-opens-a-node ()
  "A node opens by id, with its children; an unknown node says so."
  (harness-workspace-test-with
    (let* ((workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id)))
      (harness-call 'workspace/prompt id "The tile is matte.")
      (harness-workspace-test-wait-for
       (lambda () (harness-workspace-test-assistant-messages id)))
      (let* ((thread (harness-workspace-test-graph-thread id))
             (thread-id (plist-get thread :id))
             (note (harness-call 'knowledge/write id thread-id 'assistant
                                 "The grout is warm grey."))
             (page (plist-get note :page)))
        ;; A child bullet is what the page's nodes nest under the note.
        (let ((file (harness-logseq-page-file page harness-logseq-directory)))
          (write-region "  - A child note\n" nil file t))
        (let* ((graph (harness-call 'knowledge/graph id (list :thread thread-id)))
               (block (cl-find-if (lambda (item)
                                    (string-match-p "warm grey" (plist-get item :text)))
                                  (plist-get graph :blocks)))
               (detail (harness-call 'knowledge/graph/node id (plist-get block :id)
                                     (list :thread thread-id))))
          (should (equal (plist-get block :id)
                         (plist-get (plist-get detail :block) :id)))
          (should (equal (plist-get block :id)
                         (plist-get (plist-get detail :node) :id)))
          (should (cl-find-if (lambda (child)
                                (string-match-p "child note" (plist-get child :text)))
                              (plist-get detail :children)))
          (let ((missing (harness-call 'knowledge/graph/node id "n-not-a-block"
                                       (list :thread thread-id))))
            (should (null (plist-get missing :node)))
            (should (equal "missing" (plist-get missing :status)))
            (should (equal "no-node" (plist-get missing :why)))))))))

(ert-deftest harness-workspace-knowledge-graph-explorer-opens-a-page ()
  "A page opens by the name a block links; a page not there says so."
  (harness-workspace-test-with
    (let* ((workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id)))
      (harness-call 'workspace/prompt id "Ask [[Stone Co]] for a sample.")
      (harness-workspace-test-wait-for
       (lambda () (harness-workspace-test-assistant-messages id)))
      (let* ((thread (harness-workspace-test-graph-thread id))
             (page (plist-get thread :page)))
        ;; The user can make the linked page in Logseq; the explorer reads it.
        (harness-call 'logseq/page-add "Stone Co" "The stonemason for the tile."
                      (list :root harness-logseq-directory))
        (let ((found (harness-call 'knowledge/graph/page id "Stone Co"))
              (own (harness-call 'knowledge/graph/page id page))
              (missing (harness-call 'knowledge/graph/page id "Nowhere")))
          (should (equal "ready" (plist-get found :status)))
          (should (equal "Stone Co" (plist-get (plist-get found :page) :title)))
          (should (cl-find-if
                   (lambda (block)
                     (string-match-p "stonemason" (plist-get block :text)))
                   (plist-get found :blocks)))
          (should (equal "ready" (plist-get own :status)))
          (should (equal page (plist-get own :page-name)))
          (should (equal "missing" (plist-get missing :status)))
          (should (null (plist-get missing :blocks))))))))

(ert-deftest harness-workspace-knowledge-graph-explorer-without-a-graph ()
  "A graph that cannot be read says why, and the explorer still answers."
  (harness-workspace-test-with
    (let* ((workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id))
           (thread (harness-call 'workspace/thread/create id "Kitchen renovation"))
           (thread-id (plist-get thread :id))
           (blocker (expand-file-name "blocker" harness-state-directory))
           (bad (expand-file-name "not-a-directory/graph/" harness-state-directory)))
      (write-region "x" nil blocker)
      (harness-call 'workspace/update id :graph bad)
      (let ((graph (harness-call 'knowledge/graph id (list :thread thread-id))))
        (should (equal "unavailable" (plist-get graph :status)))
        (should (equal "no-page-directory" (plist-get graph :why)))
        (should (null (plist-get graph :blocks)))
        (should (null (plist-get graph :backlinks)))
        (should (plist-get graph :thread-id)))
      (let ((page (harness-call 'knowledge/graph/page id "Anywhere")))
        (should (equal "unavailable" (plist-get page :status)))
        (should (null (plist-get page :blocks)))))))
