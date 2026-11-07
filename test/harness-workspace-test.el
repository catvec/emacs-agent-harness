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

(defconst harness-workspace-test-script
  '((:type text :delta "Noted.")
    (:type done :stop-reason end-turn)))

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
                               workspace-memory workspace))
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

(ert-deftest harness-workspace-resources-answer-blocked-and-hold-no-values ()
  "The resources methods exist, answer box-staged, and never carry a value."
  (harness-workspace-test-with
    (let* ((workspace (harness-workspace-test-workspace))
           (id (plist-get workspace :id))
           (status (harness-call 'workspace/resources/status id))
           (clear (harness-call 'workspace/browser/clear id "site"
                                "https://stoneco.example" '("cookies" "storage")))
           (forget (harness-call 'workspace/browser/login/forget id "lg-1"))
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
      (dolist (answer (list status clear forget create revoke decide))
        (should (equal "unavailable" (plist-get answer :status)))
        (should (equal "box-staged" (plist-get answer :reason)))
        (should (eq t (plist-get answer :metadata-only)))
        (should-not (plist-get answer :changed))
        (should-not (plist-get answer :browser))
        (should-not (plist-get answer :wallet))
        (should-not (plist-get answer :access))
        (should-not (plist-get answer :audit))
        (dolist (forbidden '(:value :secret :token :password :pan :cvv :number))
          (should-not (plist-get answer forbidden))))
      (should (equal "site" (plist-get clear :scope)))
      (should (equal "https://stoneco.example" (plist-get clear :origin)))
      (should (equal '("cookies" "storage") (plist-get clear :kinds)))
      (should (equal "lg-1" (plist-get forget :login)))
      (should (equal "auth-1" (plist-get revoke :authorization)))
      (should (equal "buy-1" (plist-get decide :purchase)))
      (should (equal "allow" (plist-get decide :decision)))
      (should-not (plist-get create :plist))
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
        ;; The browser and wallet are still blocked, and say so.
        (should-not (plist-get answer :browser))
        (should-not (plist-get answer :wallet))
        (should (equal "unavailable" (plist-get answer :browser-status)))))))
