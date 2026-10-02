;;; harness-session-test.el --- Tests for the session module  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defmacro harness-session-test-with (&rest body)
  "Load the state modules into a fresh bus and temp state dir, then run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider session)) (harness-test-load-module m))
     (clrhash harness-sessions)
     (let ((default-directory dir))
       ,@body)))

(ert-deftest harness-session-create-defaults-and-list ()
  (harness-session-test-with
    (let* ((cwd (harness-test-temp-dir))
           (s (harness-call 'session/create :cwd cwd)))
      (should (equal (plist-get s :cwd) cwd))
      (should (equal (plist-get s :model) harness-model))
      (should (eq (plist-get s :status) 'idle))
      (should (eq (plist-get s :permission-mode) 'ask))
      (should (numberp (plist-get s :context-window)))
      (should (= 1 (length (harness-call 'session/list))))
      (should (= 1 (length (harness-call 'session/list (list :project (plist-get s :project))))))
      (should (= 0 (length (harness-call 'session/list (list :status 'running)))))
      (should (file-exists-p (harness-store-path (format "sessions/%s.json" (plist-get s :id))))))))

(ert-deftest harness-session-update-adds-hint-and-persists ()
  (harness-session-test-with
    (let* ((s (harness-call 'session/create :cwd (harness-test-temp-dir)))
           (id (plist-get s :id))
           (events nil))
      (harness-on 'session/updated (lambda (_id ch) (push ch events)))
      (harness-call 'session/update id :name "Refactor" :permission-mode 'yolo)
      (should (equal "Refactor" (plist-get (harness-call 'session/get id) :name)))
      (should (eq 'yolo (plist-get (harness-call 'session/get id) :permission-mode)))
      (should (equal '(:name "Refactor" :permission-mode yolo) (car events)))
      (let ((nodes (harness-call 'session/nodes id)))
        (should (= 2 (length nodes)))
        (should (cl-every (lambda (n) (eq (plist-get n :kind) 'hint)) nodes))))))

(ert-deftest harness-session-nodes-append-update-and-reload ()
  (harness-session-test-with
    (let* ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
           (u (harness-call 'session/append id '(:kind user :content "hi")))
           (a (harness-call 'session/append id '(:kind assistant :content "he"))))
      (should (equal (plist-get a :parent) (plist-get u :id)))
      (should (equal (plist-get a :id) (plist-get (harness-call 'session/get id) :head)))
      (harness-call 'session/update-node id (plist-get a :id) :content "hello" :transient t)
      (should (equal "hello" (plist-get (harness-call 'session/node id (plist-get a :id)) :content)))
      (harness-call 'session/update-node id (plist-get a :id) :content "hello!" :meta '(:done t))
      ;; Simulate a restart: forget everything in memory and reload from disk.
      (harness-session-flush)
      (clrhash harness-sessions)
      (harness-session--load-all)
      (should (eq 'inactive (plist-get (harness-call 'session/get id) :status)))
      (let ((nodes (harness-call 'session/nodes id)))
        (should (= 2 (length nodes)))
        ;; The transient update was never written; the final one was.
        (should (equal "hello!" (plist-get (cadr nodes) :content)))
        (should (eq 'assistant (plist-get (cadr nodes) :kind))))
      (harness-call 'session/resume id)
      (should (eq 'idle (plist-get (harness-call 'session/get id) :status)))
      (should (equal '(:limit-check t) '(:limit-check t)))
      (should (= 1 (length (harness-call 'session/nodes id '(:limit 1))))))))

(ert-deftest harness-session-fork-shares-history-and-tree ()
  (harness-session-test-with
    (let* ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :name "main") :id)))
      (harness-call 'session/append id '(:kind user :content "q1"))
      (harness-call 'session/append id '(:kind assistant :content "a1"))
      (let* ((child (harness-await (harness-call 'session/fork id :kind 'fork :name "side")))
             (cid (plist-get child :id)))
        (should (equal id (plist-get child :parent-id)))
        (should (equal (plist-get (harness-call 'session/get id) :head) (plist-get child :fork-node)))
        (should (eq 'fork (plist-get child :kind)))
        (should (equal (mapcar (lambda (n) (plist-get n :id)) (harness-call 'session/nodes id))
                       (mapcar (lambda (n) (plist-get n :id)) (harness-call 'session/nodes cid))))
        (harness-call 'session/append cid '(:kind user :content "q2-side"))
        (harness-call 'session/append id '(:kind user :content "q2-main"))
        (let ((tree (harness-call 'session/tree cid)))
          (should (= 2 (length (plist-get tree :sessions))))
          (should (= 4 (length (plist-get tree :nodes))))
          (should (= 3 (cl-count id (plist-get tree :nodes) :key (lambda (n) (plist-get n :session)) :test #'equal))))
        (should (= 1 (length (harness-call 'session/list (list :parent-id id)))))))))

(ert-deftest harness-session-directory-grants-persist-and-fork ()
  (harness-session-test-with
    (harness-test-load-module 'tools)
    (harness-test-load-module 'perms)
    (let* ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
           (extra (harness-test-temp-dir)))
      (harness-call 'permission/allow-dir id extra)
      (should (equal (list extra) (plist-get (harness-call 'session/get id) :allowed-dirs)))
      ;; Granting is silent: no hint lands in the transcript.
      (should (null (harness-call 'session/nodes id)))
      (harness-session-flush)
      (clrhash harness-sessions)
      (clrhash harness-perms--allowed-dirs)
      (harness-session--load-all)
      (should (member extra (harness-call 'permission/allowed-dirs id)))
      (let ((child (harness-await (harness-call 'session/fork id :kind 'fork))))
        (should (equal (list extra) (plist-get child :allowed-dirs)))
        (harness-call 'permission/revoke-dir (plist-get child :id) extra)
        (should-not (member extra (harness-call 'permission/allowed-dirs (plist-get child :id))))
        ;; The parent keeps its grant.
        (should (member extra (harness-call 'permission/allowed-dirs id)))))))

(ert-deftest harness-session-btw-is-a-new-session-sharing-nothing ()
  "Every BTW over a session is a new, empty session of its own.
Two in a row over one session are two sessions, neither with the
parent's transcript, fork node, provider state or directory grants, nor
with anything of the other.  Each works where the parent does, with its
model, and is listed under it; the parent is left as it was."
  (harness-session-test-with
    (let* ((cwd (harness-test-temp-dir))
           (worktree (harness-test-temp-dir))
           (id (plist-get (harness-call 'session/create :cwd cwd :name "main" :model "demo:scripted"
                                        :worktree worktree :permission-mode 'accept-edits :thinking "high"
                                        :non-interactive t :budget '(:amount 5.0 :hard t))
                          :id))
           (state '(:cli-session-id "parent-cli" :model "m")))
      (harness-call 'session/append id '(:kind user :content "q1"))
      (harness-call 'session/append id '(:kind assistant :content "a1"))
      (harness-call 'session/set-provider-state id state)
      (harness-call 'session/update id :allowed-dirs (list (harness-test-temp-dir)) :silent t)
      (let* ((parent (harness-call 'session/get id))
             (nodes (harness-call 'session/nodes id))
             (one (harness-call 'session/btw id "btw"))
             (two (harness-call 'session/btw id)))
        (should-not (equal (plist-get one :id) (plist-get two :id)))
        (should-not (member id (list (plist-get one :id) (plist-get two :id))))
        (dolist (btw (list one two))
          (let ((s (harness-call 'session/get (plist-get btw :id))))
            (should (eq 'btw (plist-get s :kind)))
            ;; Nothing of the parent's.
            (should-not (harness-call 'session/nodes (plist-get s :id)))
            (should-not (plist-get s :head))
            (should-not (plist-get s :fork-node))
            (should-not (plist-get s :provider-state))
            (should-not (plist-get s :allowed-dirs))
            (should-not (plist-get s :budget))
            (should-not (plist-get s :non-interactive))
            ;; Where the parent works, with its model.
            (should (equal cwd (plist-get s :cwd)))
            (should (equal (plist-get parent :project) (plist-get s :project)))
            (should (equal worktree (plist-get s :worktree)))
            (should (equal "demo:scripted" (plist-get s :model)))
            (should (equal "high" (plist-get s :thinking)))
            (should (eq 'accept-edits (plist-get s :permission-mode)))
            ;; Under the parent, for the lists only.
            (should (equal id (plist-get s :parent-id)))))
        (should (equal "btw" (plist-get one :name)))
        (should-not (plist-get two :name))
        ;; What happens in one BTW stays there.
        (harness-call 'session/append (plist-get one :id) '(:kind user :content "side question"))
        (harness-call 'session/set-provider-state (plist-get one :id) '(:cli-session-id "btw-cli"))
        (should-not (harness-call 'session/nodes (plist-get two :id)))
        (should-not (plist-get (harness-call 'session/get (plist-get two :id)) :provider-state))
        ;; The parent is as it was.
        (let ((after (harness-call 'session/get id)))
          (should (equal nodes (harness-call 'session/nodes id)))
          (should (equal (plist-get parent :head) (plist-get after :head)))
          (should (equal state (plist-get after :provider-state))))
        ;; Both are listed under it.
        (should (equal (sort (list (plist-get one :id) (plist-get two :id)) #'string<)
                       (sort (mapcar (lambda (s) (plist-get s :id))
                                     (harness-call 'session/list (list :parent-id id)))
                             #'string<)))))))

(ert-deftest harness-session-fork-never-takes-the-parents-provider-state ()
  "A fork has the provider state `provider/fork' derives, or none.
Never the parent's own: copied as is, a Claude Code parent's state would
make the fork resume, and write into, the parent's CLI session.  So a
fork has none when its provider cannot fork, when the fork fails, and
when it is forked to a model of a provider that cannot."
  (harness-session-test-with
    (let ((state '(:cli-session-id "parent-cli" :model "m")))
      (unwind-protect
          (progn
            (harness-define-provider 'test-plain :complete #'ignore)
            (harness-define-provider 'test-broken :complete #'ignore
                                     :fork (lambda (_model _state)
                                             (harness-rejected (list 'harness-error "no fork today"))))
            (harness-define-provider 'test-forky :complete #'ignore
                                     :fork (lambda (_model st)
                                             (harness-resolved (list :forked-from (plist-get st :cli-session-id)))))
            (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "test-forky:m")
                                 :id))
                  (fork-state (lambda (id &rest plist)
                                (let* ((child (harness-test-await
                                               (apply #'harness-call 'session/fork id :kind 'fork plist)))
                                       (stored (harness-call 'session/get (plist-get child :id))))
                                  (should (equal (plist-get child :provider-state) (plist-get stored :provider-state)))
                                  (plist-get stored :provider-state)))))
              (harness-call 'session/set-provider-state id state)
              ;; A provider that forks: the fork has the state it derives.
              (should (equal '(:forked-from "parent-cli") (funcall fork-state id)))
              ;; Forked to the model of a provider that cannot fork: none.
              (should-not (funcall fork-state id :model "test-plain:m"))
              ;; A provider that cannot fork, or whose fork fails: none.
              (harness-call 'session/update id :model "test-plain:m" :silent t)
              (should-not (funcall fork-state id))
              (harness-call 'session/update id :model "test-broken:m" :silent t)
              (should-not (funcall fork-state id))
              ;; The parent keeps its own.
              (should (equal state (plist-get (harness-call 'session/get id) :provider-state)))))
        (dolist (p '(test-plain test-broken test-forky))
          (remhash p harness-providers))))))

(defun harness-session-test-kinds (id)
  (mapcar (lambda (n) (plist-get n :kind)) (harness-call 'session/nodes id)))

(ert-deftest harness-session-interrupted-turn-settled-on-load ()
  "A session saved mid-turn comes back closed, its tool calls answered."
  (harness-session-test-with
    (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id)))
      (harness-call 'session/append id '(:kind user :content "look around"))
      (harness-call 'session/append id '(:kind tool-call :tool "read_file" :call-id "c1" :input (:path "a")))
      (harness-call 'session/append id '(:kind tool-call :tool "bash" :call-id "c2" :input (:command "make")))
      (harness-call 'session/append id '(:kind tool-result :call-id "c1" :output "A"))
      ;; The process dies mid-turn: nothing is flushed, so the status
      ;; change alone has to have reached the disk.
      (harness-call 'session/set-status id 'running)
      (clrhash harness-sessions)
      (harness-session--load-all)
      (should (eq 'inactive (plist-get (harness-call 'session/get id) :status)))
      (should (equal '(user tool-call tool-call tool-result tool-result hint) (harness-session-test-kinds id)))
      (let* ((nodes (harness-call 'session/nodes id))
             (closed (nth 4 nodes)))
        (should (equal "c2" (plist-get closed :call-id)))
        (should (plist-get closed :is-error))
        (should (equal harness-session-interrupted-output (plist-get closed :output)))
        (should (equal "Interrupted: the harness stopped during this turn" (plist-get (nth 5 nodes) :content))))
      ;; Every call has its result, as providers that pair them require.
      (should (equal '("tool_result" "tool_result")
                     (mapcar (lambda (b) (plist-get b :type))
                             (plist-get (car (last (harness-call 'session/messages id))) :content))))
      ;; Settled once: the next start leaves it alone.
      (clrhash harness-sessions)
      (harness-session--load-all)
      (should (= 1 (cl-count 'hint (harness-session-test-kinds id))))
      ;; Sessions that were idle load untouched.
      (let ((quiet (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id)))
        (harness-call 'session/append quiet '(:kind tool-call :tool "bash" :call-id "c9"))
        (harness-session-flush)
        (clrhash harness-sessions)
        (harness-session--load-all)
        (should (equal '(tool-call) (harness-session-test-kinds quiet)))))))

(ert-deftest harness-session-interrupted-question-named-in-hint ()
  (harness-session-test-with
    (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id)))
      (harness-call 'session/append id '(:kind user :content "pick one"))
      (harness-call 'session/append id '(:kind tool-call :tool "ask_user" :call-id "q1" :input (:question "Which colour?")))
      (harness-call 'session/set-status id 'running)
      (harness-call 'session/pending-add id '(:kind question :payload (:question "Which colour?\nAny will do." :call-id "q1")))
      (should (eq 'blocked (plist-get (harness-call 'session/get id) :status)))
      (harness-session-flush)
      (clrhash harness-sessions)
      (harness-session--load-all)
      (let ((s (harness-call 'session/get id)))
        (should (eq 'inactive (plist-get s :status)))
        ;; The turn that would read the answer is gone with the process.
        (should-not (plist-get s :pending)))
      (should (equal '(user tool-call tool-result hint) (harness-session-test-kinds id)))
      (should (equal "Interrupted: the harness stopped while waiting for an answer to: Which colour?"
                     (plist-get (car (last (harness-call 'session/nodes id))) :content))))))

(ert-deftest harness-session-queue-and-pending ()
  (harness-session-test-with
    (let* ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
           (statuses nil))
      (harness-on 'session/status (lambda (_ st) (push st statuses)))
      (let ((q (harness-call 'session/queue id "later")))
        (harness-call 'session/queue-update id (plist-get q :id) "later, edited")
        (should (equal "later, edited" (plist-get (car (plist-get (harness-call 'session/get id) :queue)) :text)))
        (harness-call 'session/queue id "second")
        (should (= 2 (length (harness-call 'session/queue-take id))))
        (should (null (plist-get (harness-call 'session/get id) :queue))))
      (harness-call 'session/set-status id 'running)
      (let ((pid (harness-call 'session/pending-add id '(:kind question :payload (:question "?")))))
        (should (eq 'blocked (plist-get (harness-call 'session/get id) :status)))
        (should (harness-call 'session/pending-resolve id pid '(:answer "yes")))
        (should (eq 'running (plist-get (harness-call 'session/get id) :status))))
      (should (equal '(running blocked running) (reverse statuses))))))

(ert-deftest harness-session-usage-accumulates ()
  (harness-session-test-with
    (let* ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id)))
      (harness-call 'session/usage-add id '(:input 100 :output 10 :cost 0.5 :context 1000))
      (let ((u (harness-call 'session/usage-add id '(:input 50 :output 5 :cache-read 40 :cost 0.25 :context 1500 :turns 1))))
        (should (= 150 (plist-get u :input)))
        (should (= 15 (plist-get u :output)))
        (should (= 40 (plist-get u :cache-read)))
        (should (= 0.75 (plist-get u :cost)))
        (should (= 1500 (plist-get u :context)))
        (should (= 1 (plist-get u :turns)))))))

(ert-deftest harness-session-messages-merge-rules ()
  (harness-session-test-with
    (let* ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id)))
      (harness-call 'session/append id '(:kind user :content "read it"))
      (harness-call 'session/append id '(:kind hint :content "model → x"))
      (harness-call 'session/append id '(:kind thinking :content "hm"))
      (harness-call 'session/append id '(:kind assistant :content "Sure."))
      (harness-call 'session/append id '(:kind tool-call :tool "read_file" :call-id "c1" :input (:path "a")))
      (harness-call 'session/append id '(:kind tool-call :tool "read_file" :call-id "c2" :input (:path "b")))
      (harness-call 'session/append id '(:kind tool-result :call-id "c1" :output "A"))
      (harness-call 'session/append id '(:kind tool-result :call-id "c2" :output "B" :is-error t))
      (harness-call 'session/append id '(:kind assistant :content "Done"))
      (let ((msgs (harness-call 'session/messages id)))
        (should (equal '(user assistant user assistant) (mapcar (lambda (m) (plist-get m :role)) msgs)))
        (should (equal '("thinking" "text" "tool_use" "tool_use")
                       (mapcar (lambda (b) (plist-get b :type)) (plist-get (nth 1 msgs) :content))))
        (should (equal '("tool_result" "tool_result")
                       (mapcar (lambda (b) (plist-get b :type)) (plist-get (nth 2 msgs) :content))))
        (should (eq t (plist-get (cadr (plist-get (nth 2 msgs) :content)) :is_error))))
      ;; A compaction node restarts the transcript.
      (harness-call 'session/append id '(:kind compaction :content "Earlier: user asked to read a and b."))
      (harness-call 'session/append id '(:kind user :content "next"))
      (let ((msgs (harness-call 'session/messages id)))
        (should (= 1 (length msgs)))
        (should (string-prefix-p "Summary of the conversation so far"
                                 (plist-get (car (plist-get (car msgs) :content)) :text)))
        (should (= 2 (length (plist-get (car msgs) :content))))))))

;;;; Context windows

(defvar harness-providers)
(defvar harness-session--window-slot-holds-overrides)
(declare-function harness-define-provider "harness-provider")
(declare-function harness-provider--forget "harness-provider")

(defun harness-session-test-provider (windows)
  "Define provider `test-win', listing at once a model per (NAME . WINDOW) in WINDOWS."
  (harness-define-provider 'test-win
    :complete #'ignore
    :models (lambda ()
              (harness-resolved (mapcar (lambda (w) (list :name (car w) :context-window (cdr w)))
                                        windows)))))

(defun harness-session-test-drop-provider ()
  "Remove the provider `harness-session-test-provider' defined."
  (remhash 'test-win harness-providers)
  (harness-provider--forget 'test-win))

(defun harness-session-test-window (id)
  "Return the context window session ID shows."
  (plist-get (harness-call 'session/get id) :context-window))

(ert-deftest harness-session-window-follows-the-model-catalogue ()
  "A session's context window is its model's, as the catalogue says now.
Sessions once kept the window the catalogue gave when they were
created, the 128000 stand-in when it had not listed their model yet.
When the catalogue changes, the sessions whose window moved are
announced, so the UI does not keep showing the old one."
  (harness-session-test-with
    (unwind-protect
        (let ((changed nil) (updated nil))
          (harness-session-test-provider '(("big" . 1000000) ("small" . 200000)))
          (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "test-win:big")
                               :id)))
            (should (= 1000000 (harness-session-test-window id)))
            (should-not (plist-get (harness-call 'session/get id) :context-window-override))
            (harness-call 'session/update id :model "test-win:small" :silent t)
            (should (= 200000 (harness-session-test-window id)))
            (harness-on 'session/changed (lambda (sid s) (push (cons sid (plist-get s :context-window)) changed)))
            (harness-on 'provider/models-updated (lambda (_) (setq updated t)))
            ;; The catalogue changes (a reload, say).
            (harness-session-test-provider '(("big" . 1000000) ("small" . 400000)))
            (should (= 400000 (harness-session-test-window id)))
            (harness-test-wait (lambda () (assoc id changed)) 2 "the session to be announced")
            (should (equal (list (cons id 400000)) changed))
            ;; It changes again, but not for this session: nothing is announced.
            (setq changed nil updated nil)
            (harness-session-test-provider '(("big" . 900000) ("small" . 400000)))
            (harness-call 'provider/models)
            (harness-test-wait (lambda () updated) 2 "provider/models-updated")
            (should-not changed)))
      (harness-session-test-drop-provider))))

(ert-deftest harness-session-window-set-for-the-session ()
  "A window set for a session is kept across restarts, until the model changes."
  (harness-session-test-with
    (unwind-protect
        (progn
          (harness-session-test-provider '(("big" . 1000000) ("small" . 200000)))
          (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                             :model "test-win:big" :context-window 8000)
                               :id)))
            (should (= 8000 (harness-session-test-window id)))
            (harness-session-flush)
            (clrhash harness-sessions)
            (harness-session--load-all)
            (should (= 8000 (harness-session-test-window id)))
            (should (= 8000 (plist-get (harness-call 'session/get id) :context-window-override)))
            ;; A new model brings its own window, unless one is set with it.
            (harness-call 'session/update id :model "test-win:small" :silent t)
            (should (= 200000 (harness-session-test-window id)))
            (harness-call 'session/update id :context-window 50000 :model "test-win:big" :silent t)
            (should (= 50000 (harness-session-test-window id)))
            ;; Unset, the model's applies again.
            (harness-call 'session/update id :context-window nil :silent t)
            (should (= 1000000 (harness-session-test-window id)))))
      (harness-session-test-drop-provider))))

(ert-deftest harness-session-record-window-copy-ignored-on-load ()
  "Records used to keep `:context-window', a copy of the model's window.
That copy may be the 128000 stand-in; a session loads with its model's
window as the catalogue gives it now."
  (harness-session-test-with
    (unwind-protect
        (progn
          (harness-session-test-provider '(("big" . 1000000)))
          (let* ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "test-win:big")
                                :id))
                 (name (format "sessions/%s.json" id)))
            ;; The record as it used to be written.
            (harness-call 'store/save name (plist-put (harness-plist-remove (harness-call 'store/load name)
                                                                            :context-window-override)
                                                      :context-window 128000))
            (clrhash harness-sessions)
            (harness-session--load-all)
            (should (= 1000000 (harness-session-test-window id)))
            (should-not (plist-get (harness-call 'session/get id) :context-window-override))))
      (harness-session-test-drop-provider))))

(ert-deftest harness-session-reload-drops-window-copies-once ()
  "Loaded into a running harness, this version drops the window copies
that the sessions loaded by the old one hold; later loads keep windows
set for sessions."
  (harness-session-test-with
    (unwind-protect
        (progn
          (harness-session-test-provider '(("big" . 1000000)))
          (let* ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "test-win:big")
                                :id))
                 (s (gethash id harness-sessions)))
            ;; What the old version left in the slot.
            (aset s (cl-struct-slot-offset 'harness-session 'context-window) 128000)
            (should (= 128000 (harness-session-test-window id)))
            (let ((harness-session--window-slot-holds-overrides nil))
              (harness-test-load-module 'session))
            (should (= 1000000 (harness-session-test-window id)))
            (harness-call 'session/update id :context-window 9000 :silent t)
            (harness-test-load-module 'session)
            (should (= 9000 (harness-session-test-window id)))))
      (harness-session-test-drop-provider))))

(ert-deftest harness-session-delete-and-events ()
  (harness-session-test-with
    (let* ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
           (deleted nil))
      (harness-on 'session/deleted (lambda (did _) (setq deleted did)))
      (harness-call 'session/append id '(:kind user :content "x"))
      (harness-call 'session/delete id)
      (should (equal id deleted))
      (should-not (harness-call 'session/exists-p id))
      (should-not (file-exists-p (harness-store-path (format "sessions/%s.nodes.jsonl" id)))))))

(provide 'harness-session-test)
;;; harness-session-test.el ends here
