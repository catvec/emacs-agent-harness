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

(ert-deftest harness-session-tmp-dir-is-private-and-goes-with-the-session ()
  "Every local session has its own temporary directory, private to the
user, made again when missing and deleted with the session."
  (harness-session-test-with
    (let* ((harness-session--tmp-root (expand-file-name "root/" (harness-test-temp-dir)))
           (a (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
           (b (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
           (dir (harness-call 'session/tmp-dir a)))
      ;; Made with the session, in the root, named by the id.
      (should (equal (file-name-as-directory (expand-file-name a harness-session--tmp-root)) dir))
      (should (file-directory-p dir))
      (should (= #o700 (file-modes dir)))
      (should (= #o700 (file-modes harness-session--tmp-root)))
      ;; Each session has its own.
      (should-not (equal dir (harness-call 'session/tmp-dir b)))
      ;; A reboot empties /tmp: asking makes it again.
      (delete-directory harness-session--tmp-root t)
      (should (equal dir (harness-call 'session/tmp-dir a)))
      (should (file-directory-p dir))
      ;; Deleting the session deletes it, following no link out of it.
      (let ((outside (harness-test-temp-dir)))
        (with-temp-file (expand-file-name "keep.txt" outside) (insert "keep"))
        (with-temp-file (expand-file-name "scratch.txt" dir) (insert "x"))
        (make-symbolic-link (directory-file-name outside) (expand-file-name "link" dir))
        (harness-call 'session/delete a)
        (should-not (file-exists-p dir))
        (should (file-exists-p (expand-file-name "keep.txt" outside))))
      (should (file-directory-p (harness-call 'session/tmp-dir b))))))

(ert-deftest harness-session-tmp-dir-names-and-remote-sessions ()
  "An id that is no plain name cannot reach outside the root; a remote
session has no temporary directory."
  (harness-session-test-with
    (let ((harness-session--tmp-root (expand-file-name "root/" (harness-test-temp-dir))))
      (dolist (id '("../escape" "a/b" "" "."))
        (let ((dir (harness-session--tmp-path (make-harness-session :id id))))
          (should (equal (file-name-as-directory harness-session--tmp-root)
                         (file-name-directory (directory-file-name dir))))
          (should (string-prefix-p "id-" (file-name-nondirectory (directory-file-name dir))))))
      (should-not (equal (harness-session--tmp-path (make-harness-session :id "a/b"))
                         (harness-session--tmp-path (make-harness-session :id "a_b"))))
      (should-not (harness-session--tmp-path (make-harness-session :id "r" :host "/ssh:box:")))
      (should-not (harness-session--tmp-path (make-harness-session :id "r" :cwd "/ssh:box:/srv/")))
      ;; The default root is the user's own, in the temporary directory.
      (let ((harness-session--tmp-root nil)
            (temporary-file-directory "/var/tmp/"))
        (should (equal (format "/var/tmp/harness-%d/" (user-uid)) (harness-session-tmp-root)))))))

(ert-deftest harness-session-tmp-dir-refuses-what-is-not-the-users-own ()
  "/tmp is shared: a symbolic link, or a directory somebody else owns,
is never handed out, nor deleted with the session."
  (harness-session-test-with
    (let* ((harness-session--tmp-root (expand-file-name "root/" (harness-test-temp-dir)))
           (harness-session--tmp-warned nil)
           (id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
           (dir (harness-call 'session/tmp-dir id))
           (elsewhere (harness-test-temp-dir)))
      (with-temp-file (expand-file-name "precious.txt" elsewhere) (insert "mine"))
      ;; A link planted where the session's directory goes.
      (delete-directory dir t)
      (make-symbolic-link (directory-file-name elsewhere) (directory-file-name dir))
      (should-not (harness-call 'session/tmp-dir id))
      (with-current-buffer (get-buffer-create harness-log-buffer-name)
        (should (string-match-p "no temporary directory" (buffer-string))))
      (harness-call 'session/delete id)
      (should (file-exists-p (expand-file-name "precious.txt" elsewhere)))
      (delete-file (directory-file-name dir))
      ;; A root somebody else owns: nothing is handed out from it.
      (let* ((other (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
             (owner (file-attribute-user-id (file-attributes harness-session--tmp-root 'integer))))
        (cl-letf (((symbol-function 'user-uid) (lambda () (1+ owner))))
          (should-not (harness-call 'session/tmp-dir other)))
        (should (harness-call 'session/tmp-dir other))))))

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

(defvar harness-non-interactive)

(ert-deftest harness-session-set-all-switches-what-differs ()
  "A bulk model switch touches every session not already on that model."
  (harness-session-test-with
    (let* ((cwd (harness-test-temp-dir))
           (a (plist-get (harness-call 'session/create :cwd cwd :model "claude:opus") :id))
           (b (plist-get (harness-call 'session/create :cwd cwd :model "claude:sonnet") :id))
           (c (plist-get (harness-call 'session/create :cwd cwd :model "deepseek:deepseek-flash") :id))
           (events nil))
      (harness-on 'session/updated (lambda (id _ch) (push id events)))
      (let ((changed (harness-call 'session/set-all (list :model "deepseek:deepseek-flash"))))
        (should (= 2 (length changed)))
        (should (member a changed))
        (should (member b changed))
        (should-not (member c changed))
        (should (equal "deepseek:deepseek-flash" (plist-get (harness-call 'session/get a) :model)))
        (should (equal "deepseek:deepseek-flash" (plist-get (harness-call 'session/get b) :model)))
        (should (= 2 (length events))))
      ;; Asking for what every session already has changes nothing.
      (should-not (harness-call 'session/set-all (list :model "deepseek:deepseek-flash")))
      ;; A filter can leave sessions alone, and a second setting rides along.
      (let ((changed (harness-call 'session/set-all (list :model "claude:opus" :thinking "high")
                                   (list :except (list b)))))
        (should (= 2 (length changed)))
        (should (member a changed))
        (should (member c changed))
        (should-not (member b changed))
        (should (equal "deepseek:deepseek-flash" (plist-get (harness-call 'session/get b) :model)))
        (should (equal "high" (plist-get (harness-call 'session/get c) :thinking)))))))

(ert-deftest harness-session-set-all-active-only-leaves-history ()
  "A bulk update with `:active' skips deactivated sessions."
  (harness-session-test-with
    (let* ((cwd (harness-test-temp-dir))
           (live (plist-get (harness-call 'session/create :cwd cwd :model "claude:opus") :id))
           (gone (plist-get (harness-call 'session/create :cwd cwd :model "claude:opus") :id)))
      (harness-call 'session/deactivate gone)
      (let ((changed (harness-call 'session/set-all (list :model "deepseek:deepseek-flash")
                                   (list :active t))))
        (should (equal (list live) changed))
        (should (equal "deepseek:deepseek-flash" (plist-get (harness-call 'session/get live) :model)))
        (should (equal "claude:opus" (plist-get (harness-call 'session/get gone) :model)))))))

(ert-deftest harness-session-set-all-filters-by-project ()
  "A bulk switch can stay inside one project."
  (harness-session-test-with
    (let* ((here (harness-test-temp-dir)) (there (harness-test-temp-dir))
           (a (harness-call 'session/create :cwd here :model "claude:opus"))
           (b (harness-call 'session/create :cwd there :model "claude:opus")))
      (let ((changed (harness-call 'session/set-all (list :model "deepseek:deepseek-flash")
                                   (list :project (plist-get a :project)))))
        (should (equal (list (plist-get a :id)) changed))
        (should (equal "deepseek:deepseek-flash" (plist-get (harness-call 'session/get (plist-get a :id)) :model)))
        (should (equal "claude:opus" (plist-get (harness-call 'session/get (plist-get b :id)) :model)))))))

(ert-deftest harness-session-non-interactive-is-its-own-switch ()
  "A session's non-interactive switch starts from the setting, unless an
explicit false turns it off; it is stored as t or nil; a fork copies
its parent's, off as well as on; and the hint of a change says which."
  (harness-session-test-with
    (let ((cwd (harness-test-temp-dir)))
      (let* ((harness-non-interactive t)
             (on (harness-call 'session/create :cwd cwd))
             (off (harness-call 'session/create :cwd cwd :non-interactive :false)))
        (should (eq t (plist-get on :non-interactive)))
        (should (null (plist-get off :non-interactive)))
        (should (eq t (plist-get (harness-await (harness-call 'session/fork (plist-get on :id))) :non-interactive)))
        (should (null (plist-get (harness-await (harness-call 'session/fork (plist-get off :id))) :non-interactive))))
      (let ((harness-non-interactive nil))
        (should (null (plist-get (harness-call 'session/create :cwd cwd) :non-interactive))))
      ;; Turned off as the UI sends it, JSON false, and on again.
      (let ((id (plist-get (harness-call 'session/create :cwd cwd :non-interactive t) :id)))
        (harness-call 'session/update id :non-interactive :false)
        (should (null (plist-get (harness-call 'session/get id) :non-interactive)))
        (harness-call 'session/update id :non-interactive t)
        (should (eq t (plist-get (harness-call 'session/get id) :non-interactive)))
        (should (equal '("non-interactive off" "non-interactive on")
                       (mapcar (lambda (n) (plist-get n :content)) (harness-call 'session/nodes id))))))))

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

(ert-deftest harness-session-sender-persists-and-reads-in-text ()
  "A message the user did not write keeps its sender through a restart,
and so does a queued one; the searchable transcript says who sent it."
  (harness-session-test-with
    (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id)))
      (harness-call 'session/append id '(:kind user :content "mine"))
      (harness-call 'session/append id (list :kind 'user :content "resolve the conflicts"
                                             :meta (list :from (harness-sender-system "merge queue"))))
      (harness-call 'session/queue id "from elsewhere" nil (harness-sender-session '(:id "s2" :name "Other")))
      (harness-call 'session/queue id "my own")
      (harness-session-flush)
      (clrhash harness-sessions)
      (harness-session--load-all)
      (let ((nodes (harness-call 'session/nodes id)))
        (should-not (harness-node-sender (car nodes)))
        ;; Read back from JSON, its kind is a string; it still reads as the harness.
        (should (eq 'system (harness-sender-kind (harness-node-sender (cadr nodes)))))
        (should (equal "merge queue" (plist-get (harness-node-sender (cadr nodes)) :source))))
      (let ((queue (plist-get (harness-call 'session/get id) :queue)))
        (should (eq 'session (harness-sender-kind (plist-get (car queue) :from))))
        (should (equal "Other" (plist-get (plist-get (car queue) :from) :name)))
        (should-not (plist-member (cadr queue) :from)))
      (should (equal "[user] mine\n[user, from the harness (merge queue)] resolve the conflicts"
                     (harness-call 'session/transcript-text id))))))

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

(ert-deftest harness-session-messages-place-delivered-steering ()
  "A steering message reaches the model where it was delivered, not where it was sent."
  (harness-session-test-with
    (let* ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
           (add (lambda (node) (plist-get (harness-call 'session/append id node) :id)))
           (deliver (lambda (sid after)
                      (harness-call 'session/update-node id sid :meta (list :steering t :delivered-after after))))
           (roles (lambda (msgs) (mapcar (lambda (m) (plist-get m :role)) msgs)))
           (types (lambda (msg) (mapcar (lambda (b) (plist-get b :type)) (plist-get msg :content)))))
      (funcall add '(:kind user :content "go"))
      (funcall add '(:kind tool-call :tool "t" :call-id "c1" :input (:n 1)))
      (funcall add '(:kind tool-call :tool "t" :call-id "c2" :input (:n 2)))
      ;; Sent while the tools ran, delivered with the first result: it
      ;; follows both results, which come first in their message.
      (let ((s1 (funcall add '(:kind user :content "steer one" :meta (:steering t))))
            (r1 (funcall add '(:kind tool-result :call-id "c1" :output "A"))))
        (funcall add '(:kind hint :content "a hint"))
        (funcall add '(:kind tool-result :call-id "c2" :output "B"))
        (funcall deliver s1 r1))
      (funcall add '(:kind thinking :content "hm"))
      ;; Sent while the model thought, delivered once it stopped.
      (let* ((s2 (funcall add '(:kind user :content "steer two" :meta (:steering t))))
             (a (funcall add '(:kind assistant :content "Done."))))
        (funcall deliver s2 a)
        (let ((msgs (harness-call 'session/messages id)))
          (should (equal '(user assistant user assistant user) (funcall roles msgs)))
          (should (equal '("tool_result" "tool_result" "text") (funcall types (nth 2 msgs))))
          (should (equal "steer one" (plist-get (nth 2 (plist-get (nth 2 msgs) :content)) :text)))
          (should (equal '("thinking" "text") (funcall types (nth 3 msgs))))
          (should (equal '("steer two") (mapcar (lambda (b) (plist-get b :text)) (plist-get (nth 4 msgs) :content)))))
        ;; The next message joins it.
        (funcall add '(:kind user :content "next"))
        (should (equal '("steer two" "next")
                       (mapcar (lambda (b) (plist-get b :text))
                               (plist-get (car (last (harness-call 'session/messages id))) :content))))
        ;; Without its delivery point on the path (the head moved back), it stays where it was sent.
        (harness-call 'session/set-head id s2)
        (let ((msgs (harness-call 'session/messages id)))
          (should (equal '(user assistant user assistant user) (funcall roles msgs)))
          (should (equal '("thinking") (funcall types (nth 3 msgs))))
          (should (equal "steer two" (plist-get (car (plist-get (nth 4 msgs) :content)) :text))))))))

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
