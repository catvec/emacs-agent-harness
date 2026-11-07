;;; harness-workspace-test.el --- Tests for workspace mode  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

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
(defvar harness-workspace-memory--db)
(defvar harness-workspace-memory--schema)
(defvar harness-workspace-memory--fts)
(defvar harness-workspace-memory--subscribed)

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
           (default-directory dir))
       (dolist (module '(store project config provider provider-demo tools session agent
                               workspace-memory workspace-box workspace))
         (harness-test-load-module module))
       (clrhash harness-sessions)
       (clrhash harness-tools)
       (clrhash harness-agent--turns)
       (clrhash harness-workspace--table)
       (setq harness-workspace--loaded nil
             harness-workspace--subscribed nil
             harness-workspace-memory--db nil
             harness-workspace-memory--schema nil
             harness-workspace-memory--fts nil
             harness-workspace-memory--subscribed nil)
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
        (should (= 1 (length threads)))
        (should (equal "live" (plist-get thread :state)))
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

(ert-deftest harness-workspace-memory-recalls-a-note ()
  "A turn is remembered and a later search finds it."
  (harness-workspace-test-with
    (let* ((workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id)))
      (harness-call 'workspace/prompt id "Remember that the grout is warm grey.")
      (harness-workspace-test-wait-for
       (lambda () (harness-workspace-test-assistant-messages id)))
      (let ((status (harness-call 'memory/status id))
            (found (harness-call 'memory/search id "warm grey")))
        (should (>= (plist-get status :notes) 2))
        (should found)
        (should (string-match-p "warm grey" (plist-get (car found) :text)))))))

(ert-deftest harness-workspace-survives-a-restart ()
  "A workspace, its threads and its memory survive a fresh load."
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
        (should (harness-call 'memory/search id "matte"))))))

(ert-deftest harness-workspace-brief-names-the-thread-and-memory ()
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
        (should (plist-get brief :memory))))))

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

(ert-deftest harness-workspace-memory-tools-answer-in-an-episode ()
  "memory_search and memory_write work with a workspace episode's context."
  (harness-workspace-test-with
    (let* ((workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id)))
      (harness-call 'workspace/prompt id "The tile is matte.")
      (harness-workspace-test-wait-for
       (lambda () (harness-workspace-test-assistant-messages id)))
      (let* ((session (plist-get (car (plist-get (harness-call 'workspace/get id) :threads)) :live))
             (ctx (list :session-id session))
             (searched (harness-workspace-memory--tool-search '(:query "matte") ctx))
             (written (harness-workspace-memory--tool-write
                       '(:text "The grout is warm grey.") ctx)))
        (should-not (plist-get searched :is-error))
        (should (string-match-p "matte" (plist-get searched :content)))
        (should-not (plist-get written :is-error))
        (should (harness-call 'memory/search id "warm grey"))))))

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

(ert-deftest harness-workspace-memory-read-and-forget ()
  "A note can be read by id, paged by thread, recalled and forgotten."
  (harness-workspace-test-with
    (let* ((workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id))
           (thread (harness-call 'workspace/thread/create id "Notes"))
           (note (harness-call 'memory/write id (plist-get thread :id)
                               'user "The grout is warm grey."))
           (read (harness-call 'memory/get id note))
           (pages (harness-call 'memory/pages id))
           (page (harness-call 'memory/page id (plist-get thread :id)))
           (recall (harness-call 'memory/recall-test id "warm grey"))
           (reindex (harness-call 'memory/reindex id))
           (sync (harness-call 'memory/sync id)))
      (should (equal "The grout is warm grey." (plist-get read :text)))
      (should (cl-find-if (lambda (item) (equal (plist-get thread :id)
                                                (plist-get item :id)))
                          pages))
      (should (= 1 (length page)))
      (should (string-match-p "warm grey" (plist-get (car recall) :text)))
      (should (equal 1 (plist-get reindex :notes)))
      (should (equal 1 (plist-get sync :notes)))
      (should (equal t (plist-get (harness-call 'memory/forget id note) :deleted)))
      (should (null (harness-call 'memory/page id (plist-get thread :id))))
      (should (equal nil (plist-get (harness-call 'memory/forget id note) :deleted))))))

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
