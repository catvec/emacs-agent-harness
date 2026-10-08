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
            ;; No catalogue lists the model's levels here (no demo provider),
            ;; so the BTW level does not apply: the parent's level does.
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
              ;; A provider that forks: the fork has the state it derives,
              ;; which names the provider it belongs to.
              (should (equal '(:forked-from "parent-cli" :provider "test-forky") (funcall fork-state id)))
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

(ert-deftest harness-session-provider-state-belongs-to-its-provider ()
  "Only models of the provider a state belongs to can continue it.
A state names its provider.  One from before states did belongs to the
provider that answered last: another provider answering since means
the state's own never saw those turns, so it counts as no state."
  (harness-session-test-with
    (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "claude:a") :id)))
      (should-not (harness-call 'session/provider-state id))
      (harness-call 'session/set-provider-state id '(:cli-session-id "x" :provider "claude"))
      (should (equal '(:cli-session-id "x" :provider "claude") (harness-call 'session/provider-state id)))
      (should (harness-call 'session/provider-state id "claude:b"))
      (should-not (harness-call 'session/provider-state id "deepseek:flash"))
      ;; A state that does not say: nothing answered yet, so the session's provider's.
      (harness-call 'session/set-provider-state id '(:cli-session-id "old"))
      (should (equal '(:cli-session-id "old") (harness-call 'session/provider-state id)))
      ;; Claude answered last: still Claude's, after a switch away too.
      (harness-call 'session/append id '(:kind assistant :content "from claude" :meta (:model "claude:a")))
      (harness-call 'session/update id :model "deepseek:flash" :silent t)
      (should-not (harness-call 'session/provider-state id))
      (should (harness-call 'session/provider-state id "claude:a"))
      ;; Another provider answered since, which Claude's conversation never
      ;; saw: Claude cannot continue it.
      (harness-call 'session/append id '(:kind assistant :content "from deepseek" :meta (:model "deepseek:flash")))
      (should-not (harness-call 'session/provider-state id "claude:a"))
      ;; The record itself is left as it is.
      (should (equal '(:cli-session-id "old") (plist-get (harness-call 'session/get id) :provider-state))))))
(defmacro harness-session-test-with-cut-provider (&rest body)
  "Run BODY with the provider `test-cut', which can fork at a checkpoint.
Its fork of a whole state is (:whole CLI-SESSION-ID), of a checkpoint
\(:cut CHECKPOINT)."
  (declare (indent 0))
  `(unwind-protect
       (progn
         (harness-define-provider 'test-cut :complete #'ignore
                                  :fork (lambda (_model st &optional checkpoint)
                                          (harness-resolved (if checkpoint (list :cut checkpoint)
                                                              (list :whole (plist-get st :cli-session-id))))))
         ,@body)
     (remhash 'test-cut harness-providers)))

(defun harness-session-test-conversation (id)
  "Give session ID two exchanges whose replies carry checkpoints c1 and c2.
The provider conversation is S and reached the second reply.  Return
the node ids (u1 a1 u2 a2)."
  (let ((ids (mapcar (lambda (n) (plist-get (harness-call 'session/append id n) :id))
                     '((:kind user :content "q1") (:kind assistant :content "a1" :checkpoint (:at "c1"))
                       (:kind user :content "q2") (:kind assistant :content "a2" :checkpoint (:at "c2"))))))
    (harness-call 'session/set-provider-state id '(:cli-session-id "S"))
    (harness-call 'session/set-provider-node id (nth 3 ids))
    ids))

(ert-deftest harness-session-fork-at-a-node-cuts-the-provider-conversation ()
  "A fork at a node holds the provider conversation up to that node, never more.
At the parent's head it forks the whole conversation; at an earlier
node, the conversation cut at the last checkpoint up to the node; with
no checkpoint before the node, none.  The parent's head never moves,
and a parent whose head was moved off its conversation forks it cut
too, even at its head."
  (harness-session-test-with
    (harness-session-test-with-cut-provider
      (let* ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "test-cut:m") :id))
             (ids (harness-session-test-conversation id))
             (fork (lambda (&optional node)
                     (harness-call 'session/get
                                   (plist-get (harness-test-await
                                               (apply #'harness-call 'session/fork id :kind 'fork
                                                      (and node (list :node node))))
                                              :id)))))
        (pcase-let ((`(,u1 ,a1 ,u2 ,a2) ids))
          (let ((at-head (funcall fork)))
            (should (equal '(:whole "S" :provider "test-cut") (plist-get at-head :provider-state)))
            (should (equal a2 (plist-get at-head :fork-node)))
            (should (equal a2 (plist-get at-head :provider-node))))
          (let ((at-u2 (funcall fork u2)))
            (should (equal '(:cut (:at "c1") :provider "test-cut") (plist-get at-u2 :provider-state)))
            (should (equal u2 (plist-get at-u2 :head)))
            (should (equal u2 (plist-get at-u2 :fork-node)))
            (should (equal u2 (plist-get at-u2 :provider-node)))
            (should (equal (list u1 a1 u2) (mapcar (lambda (n) (plist-get n :id))
                                                   (harness-call 'session/nodes (plist-get at-u2 :id))))))
          (should-not (plist-get (funcall fork u1) :provider-state))
          (should-error (funcall fork "n-nowhere"))
          ;; The parent is where it was.
          (should (equal a2 (plist-get (harness-call 'session/get id) :head)))
          (should (equal '(:cli-session-id "S") (plist-get (harness-call 'session/get id) :provider-state)))
          ;; Its head moved back to the first reply: a fork at the head is cut.
          (harness-call 'session/set-head id a1)
          (should (equal '(:cut (:at "c1") :provider "test-cut") (plist-get (funcall fork) :provider-state))))))))

(ert-deftest harness-session-provider-continuation-follows-the-head ()
  "Where the head is says how the provider conversation goes on.
At or after the node it reached, as it stands; elsewhere, cut at the
last checkpoint up to the head, or anew when there is none.  A session
that never recorded where its conversation got to goes on as it
stands."
  (harness-session-test-with
    (let* ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
           (ids (harness-session-test-conversation id)))
      (pcase-let ((`(,u1 ,a1 ,_u2 ,a2) ids))
        (should (equal '(:mode current) (harness-call 'session/provider-continuation id)))
        (harness-call 'session/append id '(:kind user :content "q3"))
        (harness-call 'session/hint id "a hint")
        (should (equal '(:mode current) (harness-call 'session/provider-continuation id)))
        (harness-call 'session/set-head id a1)
        (should (equal (list :mode 'checkpoint :checkpoint '(:at "c1") :node a1)
                       (harness-call 'session/provider-continuation id)))
        (harness-call 'session/set-head id u1)
        (should (equal '(:mode fresh) (harness-call 'session/provider-continuation id)))
        ;; Asked about another node than the head.
        (should (equal (list :mode 'checkpoint :checkpoint '(:at "c2") :node a2)
                       (harness-call 'session/provider-continuation id a2)))
        (harness-call 'session/set-head id a2)
        (should (equal '(:mode current) (harness-call 'session/provider-continuation id)))
        ;; Nothing recorded (a session older than that): as it stands at
        ;; its newest node, but not once its head was moved back.
        (harness-call 'session/set-provider-node id nil)
        (let ((newest (plist-get (car (last (plist-get (harness-call 'session/tree id) :nodes))) :id)))
          (harness-call 'session/set-head id newest))
        (should (equal '(:mode current) (harness-call 'session/provider-continuation id)))
        (harness-call 'session/set-head id a1)
        (should (equal (list :mode 'checkpoint :checkpoint '(:at "c1") :node a1)
                       (harness-call 'session/provider-continuation id)))))))

(ert-deftest harness-session-old-fork-at-an-earlier-node-starts-anew ()
  "A fork made before forks were cut, at an earlier node, does not go on as it was.
The tree once forked a session at an earlier node by forking its whole
provider conversation, which knew what came after the node.  Such a
fork, which recorded no node its conversation reached, starts anew from
its transcript; one made at its parent's head goes on."
  (harness-session-test-with
    (let* ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
           (ids (mapcar (lambda (n) (plist-get (harness-call 'session/append id n) :id))
                        '((:kind user :content "q1") (:kind assistant :content "a1")
                          (:kind user :content "q2") (:kind assistant :content "a2"))))
           (old-fork (lambda (node)
                       (let ((child (plist-get (harness-test-await (harness-call 'session/fork id :node node)) :id)))
                         ;; As the old code left it: the parent's whole state, nothing recorded.
                         (harness-call 'session/set-provider-state child '(:cli-session-id "whole"))
                         (harness-call 'session/set-provider-node child nil)
                         child))))
      (let ((early (funcall old-fork (nth 1 ids)))
            (at-head (funcall old-fork (nth 3 ids))))
        (should (equal '(:mode fresh) (harness-call 'session/provider-continuation early)))
        (should (equal '(:mode current) (harness-call 'session/provider-continuation at-head)))
        ;; Its own later turns do not change that it was cut short.
        (harness-call 'session/append early '(:kind user :content "q-fork"))
        (should (equal '(:mode fresh) (harness-call 'session/provider-continuation early)))))))

(ert-deftest harness-session-provider-state-and-node-persist ()
  "A new provider state is announced once; the node it reached survives a restart."
  (harness-session-test-with
    (let* ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
           (node (plist-get (harness-call 'session/append id '(:kind user :content "q1")) :id))
           (events nil))
      (harness-on 'session/provider-state-changed (lambda (sid state) (push (list sid state) events)))
      (harness-call 'session/set-provider-state id '(:cli-session-id "S"))
      (harness-call 'session/set-provider-state id '(:cli-session-id "S"))
      (harness-call 'session/set-provider-state id nil)
      (should (equal (list (list id nil) (list id '(:cli-session-id "S"))) events))
      (harness-call 'session/set-provider-node id node)
      (harness-session-flush)
      (clrhash harness-sessions)
      (harness-session--load-all)
      (should (equal node (plist-get (harness-call 'session/get id) :provider-node))))))

(ert-deftest harness-session-set-head-refuses-while-running ()
  "The head stays put under a running turn, which would write after it."
  (harness-session-test-with
    (let* ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
           (first (plist-get (harness-call 'session/append id '(:kind user :content "q1")) :id)))
      (harness-call 'session/append id '(:kind assistant :content "a1"))
      (harness-call 'session/set-status id 'running)
      (should-error (harness-call 'session/set-head id first))
      (harness-call 'session/set-status id 'idle)
      (harness-call 'session/set-head id first)
      (should (equal first (plist-get (harness-call 'session/get id) :head))))))

(ert-deftest harness-session-reload-upgrades-old-records ()
  "A session made by an earlier layout of the struct gets the slots added since."
  (harness-session-test-with
    (let* ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :name "old") :id))
           (s (gethash id harness-sessions))
           ;; Made before the last two slots, provider-node and move.
           (old (apply #'record (cl-loop for i below (- (length s) 2) collect (aref s i)))))
      (puthash id old harness-sessions)
      (should-error (harness-session-provider-node old))
      (should-error (harness-session-move old))
      (harness-session--upgrade-records)
      (let ((new (gethash id harness-sessions)))
        (should (= (length s) (length new)))
        (should (equal "old" (harness-session-name new)))
        (should-not (harness-session-provider-node new))
        (should-not (harness-session-move new))
        (should (equal "old" (plist-get (harness-call 'session/get id) :name)))))))

(defun harness-session-test-kinds (id)
  (mapcar (lambda (n) (plist-get n :kind)) (harness-call 'session/nodes id)))

(defun harness-session-test-unpaired (messages)
  "Return the tool calls in MESSAGES that the message after them leaves unanswered.
Also return, as (:stray ID), each result answering no call of the
message before it.  Providers that pair calls with results, DeepSeek
among them, reject a request when this is not nil."
  (let ((problems nil) (asked nil))
    (dolist (m messages)
      (let ((blocks (plist-get m :content)))
        (if (eq (plist-get m :role) 'user)
            (let ((answered (delq nil (mapcar (lambda (b) (and (equal (plist-get b :type) "tool_result")
                                                               (plist-get b :tool_use_id)))
                                              blocks))))
              (dolist (id asked) (unless (member id answered) (push id problems)))
              (dolist (id answered) (unless (member id asked) (push (list :stray id) problems)))
              (setq asked nil))
          (dolist (id asked) (push id problems))
          (setq asked (delq nil (mapcar (lambda (b) (and (equal (plist-get b :type) "tool_use") (plist-get b :id)))
                                        blocks))))))
    (dolist (id asked) (push id problems))
    (nreverse problems)))

(defun harness-session-test-node-ids (id)
  (mapcar (lambda (n) (plist-get n :id)) (harness-call 'session/nodes id)))

(defun harness-session-test-result (id call-id)
  "Return the tool result node answering CALL-ID in session ID, or nil."
  (cl-find-if (lambda (n) (and (eq (plist-get n :kind) 'tool-result) (equal (plist-get n :call-id) call-id)))
              (harness-call 'session/nodes id)))

(ert-deftest harness-session-fork-mid-turn-answers-the-running-calls ()
  "A session forked in the middle of a turn copies the calls still
running: the spawn_agent call forking it, and any other call of its
step.  Their results only ever reach the parent, so the fork answers
each of them itself -- the forking call with the news that the fork is
the sub-agent it started -- and its first request pairs every call with
a result.  Unanswered, DeepSeek refused that request with HTTP 400.
The parent is left as it was, and the answers persist."
  (harness-session-test-with
    (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id)))
      (harness-call 'session/append id '(:kind user :content "look into it"))
      (harness-call 'session/append id '(:kind thinking :content "I will read and delegate."))
      (harness-call 'session/append id '(:kind assistant :content "Reading first."))
      (harness-call 'session/append id '(:kind tool-call :tool "read_file" :call-id "c1" :input (:path "a")))
      (harness-call 'session/append id '(:kind tool-call :tool "spawn_agent" :call-id "c2"
                                                :input (:prompt "dig deeper" :fork t)))
      (harness-call 'session/append id '(:kind tool-call :tool "bash" :call-id "c3" :input (:command "make")))
      (harness-call 'session/append id '(:kind tool-result :call-id "c1" :output "A"))
      (let* ((parent-ids (harness-session-test-node-ids id))
             (head (plist-get (harness-call 'session/get id) :head))
             (child (harness-await (harness-call 'session/fork id :kind 'subagent :call-id "c2")))
             (cid (plist-get child :id))
             (nodes (harness-call 'session/nodes cid))
             (spawned (harness-session-test-result cid "c2"))
             (running (harness-session-test-result cid "c3")))
        ;; The parent's transcript, then an answer for each running call, in order.
        (should (equal parent-ids (seq-take (mapcar (lambda (n) (plist-get n :id)) nodes) (length parent-ids))))
        (should (equal '(tool-result tool-result) (mapcar (lambda (n) (plist-get n :kind))
                                                          (nthcdr (length parent-ids) nodes))))
        (should (equal '("c2" "c3") (mapcar (lambda (n) (plist-get n :call-id)) (nthcdr (length parent-ids) nodes))))
        (should (equal head (plist-get child :fork-node)))
        (should (equal (plist-get running :id) (plist-get child :head)))
        ;; The forking call says who the fork is; the other one says where its result went.
        (should (equal harness-session-spawned-output (plist-get spawned :output)))
        (should-not (plist-get spawned :is-error))
        (should (equal harness-session-forked-output (plist-get running :output)))
        (should (plist-get running :is-error))
        (should (plist-get (plist-get spawned :meta) :forked))
        (should (plist-get (plist-get running :meta) :forked))
        ;; They are the fork's own nodes, not the parent's.
        (should (equal cid (plist-get spawned :session)))
        (should (equal parent-ids (harness-session-test-node-ids id)))
        (should-not (harness-session-test-result id "c2"))
        ;; The fork's first request: every call answered, the task last.
        (harness-call 'session/append cid '(:kind user :content "dig deeper"))
        (let ((msgs (harness-call 'session/messages cid)))
          (should-not (harness-session-test-unpaired msgs))
          (should (equal '(user assistant user) (mapcar (lambda (m) (plist-get m :role)) msgs)))
          (should (equal '("tool_result" "tool_result" "tool_result" "text")
                         (mapcar (lambda (b) (plist-get b :type)) (plist-get (nth 2 msgs) :content)))))
        ;; The answers outlive a restart, and a fork that was idle is not settled again.
        (let ((before (harness-session-test-node-ids cid)))
          (harness-session-flush)
          (clrhash harness-sessions)
          (harness-session--load-all)
          (should (equal before (harness-session-test-node-ids cid)))
          (should (equal harness-session-spawned-output (plist-get (harness-session-test-result cid "c2") :output))))))))

(ert-deftest harness-session-fork-answers-calls-only-when-needed ()
  "A fork of a session whose calls all have results adds nothing; one
forked at a head moved back between a call and its result answers that
call, whose result stays the parent's; and calls before the last
compaction, which reach no provider, are left alone."
  (harness-session-test-with
    (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id)))
      (harness-call 'session/append id '(:kind user :content "go"))
      (let ((call (harness-call 'session/append id '(:kind tool-call :tool "read_file" :call-id "c1"))))
        (harness-call 'session/append id '(:kind tool-result :call-id "c1" :output "A"))
        (harness-call 'session/append id '(:kind assistant :content "Done."))
        ;; Every call answered: the fork is the parent's transcript, no more.
        (let ((child (harness-await (harness-call 'session/fork id))))
          (should (equal (harness-session-test-node-ids id) (harness-session-test-node-ids (plist-get child :id)))))
        ;; Forked from the call itself, as the tree's fork at a node does.
        (let ((head (plist-get (harness-call 'session/get id) :head)))
          (harness-call 'session/set-head id (plist-get call :id))
          (let* ((child (harness-await (harness-call 'session/fork id)))
                 (cid (plist-get child :id)))
            (harness-call 'session/set-head id head)
            (should (equal '(user tool-call tool-result) (harness-session-test-kinds cid)))
            (should (equal harness-session-forked-output (plist-get (harness-session-test-result cid "c1") :output)))
            (should (equal "A" (plist-get (harness-session-test-result id "c1") :output)))
            (harness-call 'session/append cid '(:kind user :content "again"))
            (should-not (harness-session-test-unpaired (harness-call 'session/messages cid))))))
      ;; A call left unanswered before a compaction is summarised, not sent.
      (harness-call 'session/append id '(:kind tool-call :tool "bash" :call-id "c8"))
      (harness-call 'session/append id '(:kind compaction :content "Earlier: a bash call."))
      (harness-call 'session/append id '(:kind user :content "next"))
      (harness-call 'session/append id '(:kind tool-call :tool "bash" :call-id "c9"))
      (let ((cid (plist-get (harness-await (harness-call 'session/fork id)) :id)))
        (should-not (harness-session-test-result cid "c8"))
        (should (harness-session-test-result cid "c9"))
        (should-not (harness-session-test-unpaired (harness-call 'session/messages cid))))
      ;; So does a harness that stopped mid-turn.
      (harness-call 'session/set-status id 'running)
      (clrhash harness-sessions)
      (harness-session--load-all)
      (should-not (harness-session-test-result id "c8"))
      (should (equal harness-session-interrupted-output (plist-get (harness-session-test-result id "c9") :output))))))

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

(ert-deftest harness-session-messages-leave-out-calls-the-harness-recorded ()
  "A tool call and result the harness recorded (`harness-outside-node-p'),
even in the middle of a turn, never reach the model, answered or not;
steering delivered right after such a call still stands where the
model got it."
  (harness-session-test-with
    (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
          (from (harness-sender-system "merge queue")))
      (harness-call 'session/append id '(:kind user :content "go"))
      (harness-call 'session/append id '(:kind tool-call :tool "bash" :call-id "c1" :input (:command "make")))
      ;; Sent while the call ran; the model got it with the call's result.
      (let ((steer (harness-call 'session/append id '(:kind user :content "also test")))
            (outside (harness-call 'session/append id (list :kind 'tool-call :tool "spawn_agent" :call-id "m1"
                                                            :input '(:name "Merge child" :prompt "resolve")
                                                            :meta (list :from from :child-id "r1")))))
        (harness-call 'session/update-node id (plist-get steer :id)
                      :meta (list :delivered-after (plist-get outside :id))))
      (harness-call 'session/append id '(:kind tool-result :call-id "c1" :output "built"))
      (harness-call 'session/append id '(:kind assistant :content "Done."))
      ;; One the harness never answered, and one it did.
      (harness-call 'session/append id (list :kind 'tool-call :tool "spawn_agent" :call-id "m2"
                                             :input '(:name "Other" :prompt "x") :meta (list :from from)))
      (harness-call 'session/append id (list :kind 'tool-result :call-id "m1" :output "Resolved."
                                             :meta (list :from from :child-id "r1")))
      (should (harness-outside-node-p (car (last (harness-call 'session/nodes id)))))
      (let ((msgs (harness-call 'session/messages id)))
        (should-not (harness-session-test-unpaired msgs))
        (should (equal '(user assistant user assistant) (mapcar (lambda (m) (plist-get m :role)) msgs)))
        (should (equal '("tool_result" "text") (mapcar (lambda (b) (plist-get b :type)) (plist-get (nth 2 msgs) :content))))
        (should (equal "also test" (plist-get (nth 1 (plist-get (nth 2 msgs) :content)) :text)))
        (should (equal '("Done.") (mapcar (lambda (b) (plist-get b :text)) (plist-get (nth 3 msgs) :content))))))))

(ert-deftest harness-session-settle-answers-the-call-recorded-for-a-sub-agent ()
  "A call the harness recorded in a session for its sub-agent (the merge
queue's conflict resolver, as a spawn_agent call) is answered when that
sub-agent is settled after a restart: the session holding the call was
not running, so nothing else would answer it.  The answer is the
harness's too, so the model never sees either, and comes once."
  (harness-session-test-with
    (let* ((parent (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
           (sub (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :kind 'subagent
                                         :parent-id parent)
                           :id))
           (from (harness-sender-system "merge queue")))
      (harness-call 'session/append parent '(:kind user :content "work"))
      (harness-call 'session/append parent '(:kind assistant :content "Done."))
      (harness-call 'session/append parent (list :kind 'tool-call :tool "spawn_agent" :call-id "m1"
                                                 :input '(:name "Merge child" :prompt "resolve")
                                                 :meta (list :from from :child-id sub)))
      ;; One the harness recorded for another session is not this one's to answer.
      (harness-call 'session/append parent (list :kind 'tool-call :tool "spawn_agent" :call-id "m2"
                                                 :input '(:name "Other" :prompt "x")
                                                 :meta (list :from from :child-id "someone-else")))
      (harness-call 'session/append sub '(:kind user :content "resolve"))
      (harness-call 'session/append sub '(:kind tool-call :tool "bash" :call-id "b1" :input (:command "git merge")))
      (harness-call 'session/set-status sub 'running)
      (harness-session-flush)
      (clrhash harness-sessions)
      (harness-session--load-all)
      (let ((answer (harness-session-test-result parent "m1")))
        (should (plist-get answer :is-error))
        (should (equal harness-session-interrupted-output (plist-get answer :output)))
        (should (harness-outside-node-p answer))
        (should (equal sub (plist-get (plist-get answer :meta) :child-id))))
      (should-not (harness-session-test-result parent "m2"))
      (should (harness-session-test-result sub "b1"))
      ;; The parent was idle: it is not settled itself.
      (should-not (memq 'hint (harness-session-test-kinds parent)))
      (harness-call 'session/append parent '(:kind user :content "next"))
      (let ((msgs (harness-call 'session/messages parent)))
        (should-not (harness-session-test-unpaired msgs))
        (should (equal '(user assistant user) (mapcar (lambda (m) (plist-get m :role)) msgs))))
      ;; Once: the next start leaves both alone.
      (harness-session-flush)
      (clrhash harness-sessions)
      (harness-session--load-all)
      (should (= 1 (cl-count "m1" (harness-call 'session/nodes parent)
                             :key (lambda (n) (and (eq (plist-get n :kind) 'tool-result) (plist-get n :call-id)))
                             :test #'equal))))))

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

(ert-deftest harness-session-usage-keeps-the-output-after-the-prompt ()
  "`:last-output' is what the request the context measures wrote after its prompt.
Together they are the size of the conversation, which the next request
sends back.  A record of one request wrote its own output; a hosted
loop's turn says what its last request wrote; a record without a
context leaves both."
  (harness-session-test-with
    (let* ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
           (usage (lambda () (plist-get (harness-call 'session/get id) :usage))))
      (should-not (plist-get (funcall usage) :last-output))
      (harness-call 'session/usage-add id '(:input 100 :output 30 :context 1000))
      (should (= 1000 (plist-get (funcall usage) :context)))
      (should (= 30 (plist-get (funcall usage) :last-output)))
      ;; A turn of several requests: its output is theirs together, its
      ;; last request's is what follows the context.
      (harness-call 'session/usage-add id '(:input 50 :output 300 :context 1200 :last-output 20))
      (should (= 1200 (plist-get (funcall usage) :context)))
      (should (= 20 (plist-get (funcall usage) :last-output)))
      (should (= 330 (plist-get (funcall usage) :output)))
      ;; Usage that measures no prompt leaves the conversation's size.
      (harness-call 'session/usage-add id '(:input 5 :output 7))
      (harness-call 'session/usage-add id '(:turns 1))
      (should (= 1200 (plist-get (funcall usage) :context)))
      (should (= 20 (plist-get (funcall usage) :last-output)))
      ;; It is kept with the session.
      (harness-session-flush)
      (clrhash harness-sessions)
      (harness-session--load-all)
      (should (= 20 (plist-get (funcall usage) :last-output))))))

(defvar harness-cache-ttl)
(defvar harness-cache-ttl-overrides)

(ert-deftest harness-session-usage-stamps-the-prompt-cache ()
  "A request that read or wrote the prompt cache stamps when, and the
lifetime its provider reported; the session's `:cache' says when the
cache lapses, and survives a restart.  A record without tokens leaves
the stamp; a request that used no cache drops it."
  (harness-session-test-with
    (let* ((harness-cache-ttl 300)
           (harness-cache-ttl-overrides nil)
           (id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
           (m (plist-get (harness-call 'session/get id) :model))
           (cache (lambda () (plist-get (harness-call 'session/get id) :cache))))
      ;; A new session knows of no cache.
      (should-not (funcall cache))
      ;; A request that did not use one stamps nothing.
      (harness-call 'session/usage-add id '(:input 100 :output 10 :context 110))
      (should-not (funcall cache))
      ;; One that read it did so now, as the clock says, and the
      ;; provider said nothing of a lifetime: the default's.
      (cl-letf (((symbol-function 'float-time) (lambda (&optional _) 1000.0)))
        (harness-call 'session/usage-add id '(:input 10 :output 10 :cache-read 900 :context 920)))
      (should (equal `(:at 1000.0 :ttl 300 :expires 1300.0 :model ,m) (funcall cache)))
      ;; The time and lifetime the provider reported win.
      (harness-call 'session/usage-add id '(:input 10 :output 10 :cache-write 50 :context 980
                                             :cache-at 2000.0 :cache-ttl 3600))
      (should (equal `(:at 2000.0 :ttl 3600 :expires 5600.0 :model ,m) (funcall cache)))
      ;; A turn counted is no request.
      (harness-call 'session/usage-add id '(:turns 1))
      (should (equal `(:at 2000.0 :ttl 3600 :expires 5600.0 :model ,m) (funcall cache)))
      ;; It is kept with the session.
      (harness-session-flush)
      (clrhash harness-sessions)
      (harness-session--load-all)
      (should (equal `(:at 2000.0 :ttl 3600 :expires 5600.0 :model ,m) (funcall cache)))
      ;; A request without a lifetime of its own has the default's again.
      (harness-call 'session/usage-add id '(:input 10 :output 10 :cache-read 990 :context 1000
                                             :cache-at 3000.0))
      (should (equal `(:at 3000.0 :ttl 300 :expires 3300.0 :model ,m) (funcall cache)))
      ;; A request that used no cache: nothing is cached to lose.
      (harness-call 'session/usage-add id '(:input 1000 :output 10 :context 1010))
      (should-not (funcall cache))
      (should-not (plist-member (plist-get (harness-call 'session/get id) :usage) :cache-at))
      (should-not (plist-member (plist-get (harness-call 'session/get id) :usage) :cache-model)))))

(ert-deftest harness-session-cache-needs-context ()
  "A session whose usage says no context has nothing cached to lose."
  (harness-session-test-with
    (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id)))
      (harness-call 'session/usage-add id '(:input 0 :output 0 :cache-read 10 :cache-at 1000.0))
      (should (plist-get (plist-get (harness-call 'session/get id) :usage) :cache-at))
      (should-not (plist-get (harness-call 'session/get id) :cache)))))

(defmacro harness-session-test-with-loop (&rest body)
  "Run BODY in `harness-session-test-with' with providers `test-api' and `test-loop'.
`test-api' (models a and b) is sent the whole conversation at every
request; `test-loop' (model l) keeps a conversation of its own, a
hosted loop."
  (declare (indent 0))
  `(harness-session-test-with
     (unwind-protect
         (progn
           (harness-define-provider 'test-api :complete #'ignore
             :models (lambda () (harness-resolved (list (list :name "a") (list :name "b")))))
           (harness-define-provider 'test-loop :complete #'ignore
             :capabilities '(:hosted-loop t)
             :models (lambda () (harness-resolved (list (list :name "l")))))
           ,@body)
       (dolist (p '(test-api test-loop))
         (remhash p harness-providers)
         (harness-provider--forget p)))))

(ert-deftest harness-session-cache-is-the-models-own ()
  "A cache serves the model whose request wrote it.
Switched to another model, the session still reports the old model's
cache, with that model's lifetime: the new model reads none of it, and
switched back while it lasts, it is the session's own again.  A
request still sent to the old model stamps that model's cache."
  (harness-session-test-with-loop
    (let* ((harness-cache-ttl 300)
           (harness-cache-ttl-overrides '(("\\`test-api:a\\'" . 600)))
           (id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "test-api:a") :id))
           (cache (lambda () (plist-get (harness-call 'session/get id) :cache))))
      (harness-call 'session/usage-add id '(:input 10 :output 10 :cache-read 900 :context 920 :cache-at 1000.0))
      (should (equal '(:at 1000.0 :ttl 600 :expires 1600.0 :model "test-api:a") (funcall cache)))
      (harness-call 'session/update id :model "test-api:b" :silent t)
      (should (equal '(:at 1000.0 :ttl 600 :expires 1600.0 :model "test-api:a") (funcall cache)))
      ;; A step a began ends after the switch: a's cache, used later.
      (harness-call 'session/usage-add id '(:input 10 :output 10 :cache-read 920 :context 940
                                             :cache-at 1100.0 :model "test-api:a"))
      (should (equal '(:at 1100.0 :ttl 600 :expires 1700.0 :model "test-api:a") (funcall cache)))
      (harness-call 'session/update id :model "test-api:a" :silent t)
      (should (equal '(:at 1100.0 :ttl 600 :expires 1700.0 :model "test-api:a") (funcall cache)))
      ;; b's first request caches the conversation for b.
      (harness-call 'session/update id :model "test-api:b" :silent t)
      (harness-call 'session/usage-add id '(:input 940 :output 10 :cache-write 940 :context 950
                                             :cache-at 1200.0 :model "test-api:b"))
      (should (equal '(:at 1200.0 :ttl 300 :expires 1500.0 :model "test-api:b") (funcall cache)))
      ;; It is kept with the session.
      (harness-session-flush)
      (clrhash harness-sessions)
      (harness-session--load-all)
      (should (equal '(:at 1200.0 :ttl 300 :expires 1500.0 :model "test-api:b") (funcall cache))))))

(ert-deftest harness-session-cache-goes-when-the-conversation-starts-over ()
  "Nothing is cached once the conversation starts over.
A compaction replaces it with a summary (`:cache-reset'), whatever the
summariser's own request cached.  A hosted loop that holds none of
the session's conversation starts one of its own, sent none of the old
one; one that holds it carries it on, uncached for its model."
  (harness-session-test-with-loop
    (let* ((harness-cache-ttl 300)
           (harness-cache-ttl-overrides nil)
           (id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "test-api:a") :id))
           (cache (lambda () (plist-get (harness-call 'session/get id) :cache)))
           (stamp (lambda (at)
                    (harness-call 'session/usage-add id (list :input 10 :output 10 :cache-read 900
                                                              :context 920 :cache-at at)))))
      (funcall stamp 1000.0)
      (should (funcall cache))
      (let ((u (harness-call 'session/usage-add id '(:input 900 :output 200 :cache-read 900 :context 200
                                                      :cache-reset t))))
        (should-not (plist-member u :cache-at))
        (should-not (plist-member u :cache-model))
        (should (= 1800 (plist-get u :cache-read)))
        (should (= 200 (plist-get u :context))))
      (should-not (funcall cache))
      ;; A hosted loop with none of the session's conversation.
      (funcall stamp 2000.0)
      (harness-call 'session/update id :model "test-loop:l" :silent t)
      (should-not (funcall cache))
      ;; Back on a, the cache is a's again.
      (harness-call 'session/update id :model "test-api:a" :silent t)
      (should (equal '(:at 2000.0 :ttl 300 :expires 2300.0 :model "test-api:a") (funcall cache)))
      ;; A hosted loop holding the session's conversation carries it on.
      (harness-call 'session/set-provider-state id (harness-tag-provider-state '(:conv "c1") "test-loop:l"))
      (harness-call 'session/update id :model "test-loop:l" :silent t)
      (should (equal '(:at 2000.0 :ttl 300 :expires 2300.0 :model "test-api:a") (funcall cache))))))

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
        (should (= 2 (length (plist-get (car msgs) :content)))))
      ;; One that points at a transcript file is sent as it is: no summary.
      (harness-call 'session/append id '(:kind compaction :content "Read /x/t.md first."
                                         :meta (:compaction "transcript" :file "/x/t.md")))
      (should (equal "Read /x/t.md first."
                     (plist-get (car (plist-get (car (harness-call 'session/messages id)) :content)) :text))))))

(ert-deftest harness-session-write-transcript ()
  "The transcript goes to a new file in the session's directory, which git ignores."
  (harness-session-test-with
    (let* ((cwd (harness-test-temp-dir))
           (id (plist-get (harness-call 'session/create :cwd cwd :name "parser work") :id)))
      (harness-call 'session/append id '(:kind user :content "fix the parser"))
      (harness-call 'session/append id '(:kind assistant :content "Fixed."))
      (let* ((written (harness-call 'session/write-transcript id))
             (file (plist-get written :file))
             (text (harness-read-file file)))
        (should (equal (expand-file-name ".harness/transcripts/" cwd) (file-name-directory file)))
        (should (string-prefix-p (substring id 0 8) (file-name-nondirectory file)))
        (should (equal "*\n" (harness-read-file (expand-file-name ".harness/transcripts/.gitignore" cwd))))
        (should (string-prefix-p (format "# Conversation\n\n- Session: parser work (%s)\n- Working directory: %s\n" id cwd)
                                 text))
        (should (string-match-p "oldest first, one entry per message" text))
        (should (string-match-p "^\\[user\\] fix the parser\n\\[assistant\\] Fixed\\.\n\\'" text))
        (should (= (plist-get written :lines) (1+ (cl-count ?\n text)))))
      ;; Another directory, a title and a line about it.
      (let* ((written (harness-call 'session/write-transcript id '(:directory "elsewhere/" :title "Handed over"
                                                                    :about "Handed over from A to B")))
             (text (harness-read-file (plist-get written :file))))
        (should (file-in-directory-p (plist-get written :file) (expand-file-name "elsewhere/" cwd)))
        (should (string-prefix-p "# Handed over\n\n- Session: parser work" text))
        (should (string-match-p "^- Handed over from A to B$" text)))
      ;; Without its directory, nothing is written.
      (delete-directory cwd t)
      (should-error (harness-call 'session/write-transcript id) :type 'harness-error)
      (should-not (file-exists-p cwd)))))

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

(ert-deftest harness-session-messages-answer-every-call ()
  "Every tool call is answered in the message right after it, whatever
the path holds.  A call without its result there -- its turn was
cancelled, or the head moved back between them -- gets a stand-in
error result, and a result answering no call of the message before it,
one that came after its turn ended say, becomes text: providers that
pair calls with results reject a request with either.  The transcript
itself is left alone."
  (harness-session-test-with
    (let* ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
           (add (lambda (node) (harness-call 'session/append id node)))
           (types (lambda (msg) (mapcar (lambda (b) (plist-get b :type)) (plist-get msg :content)))))
      (funcall add '(:kind user :content "go"))
      (funcall add '(:kind tool-call :tool "t" :call-id "c1"))
      (funcall add '(:kind tool-call :tool "t" :call-id "c2"))
      ;; Sent mid-step and never delivered: the turn was cancelled.
      (funcall add '(:kind user :content "stop that" :meta (:steering t)))
      (funcall add '(:kind tool-result :call-id "c2" :output "B"))
      (let* ((msgs (harness-call 'session/messages id))
             (answers (plist-get (nth 2 msgs) :content)))
        (should-not (harness-session-test-unpaired msgs))
        (should (equal '("tool_result" "tool_result" "text") (funcall types (nth 2 msgs))))
        (should (equal '("c2" "c1") (mapcar (lambda (b) (plist-get b :tool_use_id)) (seq-take answers 2))))
        (should (equal harness-session-missing-result-output (plist-get (cadr answers) :content)))
        (should (plist-get (cadr answers) :is_error))
        (should (equal "stop that" (plist-get (nth 2 answers) :text))))
      ;; The cancelled call's result arrives once the next turn is under way.
      (funcall add '(:kind assistant :content "Stopped."))
      (funcall add '(:kind user :content "next"))
      (funcall add '(:kind tool-result :call-id "c1" :output "A, late" :is-error t))
      (let* ((msgs (harness-call 'session/messages id))
             (last (car (last msgs))))
        (should-not (harness-session-test-unpaired msgs))
        (should (equal '("text" "text") (funcall types last)))
        (should (equal "[Result of tool call c1, an error]\nA, late" (plist-get (cadr (plist-get last :content)) :text))))
      ;; A call at the very end gets a message of its own; a second
      ;; result for a call it already has is text.
      (funcall add '(:kind tool-call :tool "t" :call-id "c3"))
      (let ((msgs (harness-call 'session/messages id)))
        (should-not (harness-session-test-unpaired msgs))
        (should (equal '(user assistant user assistant user assistant user)
                       (mapcar (lambda (m) (plist-get m :role)) msgs)))
        (should (equal "c3" (plist-get (car (plist-get (car (last msgs)) :content)) :tool_use_id))))
      (funcall add '(:kind tool-result :call-id "c3" :output "C"))
      (funcall add '(:kind tool-result :call-id "c3" :output "C again"))
      (let ((last (car (last (harness-call 'session/messages id)))))
        (should (equal '("tool_result" "text") (funcall types last)))
        (should (equal "C" (plist-get (car (plist-get last :content)) :content))))
      ;; Nothing was added to the transcript.
      (should (equal '(user tool-call tool-call user tool-result assistant user tool-result tool-call
                            tool-result tool-result)
                     (harness-session-test-kinds id))))))

;;;; Context windows

(defvar harness-providers)
(defvar harness-session--window-slot-holds-overrides)
(defvar harness-provider-fallback-context-window)
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

(ert-deftest harness-session-window-of-a-model-nobody-lists ()
  "A session on a model its provider does not list gets an estimate, not a small stand-in.
The bug once was a new slug the catalogue did not know, which got a
small window and compacted far too early."
  (harness-session-test-with
    (unwind-protect
        (progn
          (harness-session-test-provider '(("claude-opus-5-5" . 1000000) ("claude-haiku-4-5" . 200000)))
          (let ((newer (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                                :model "test-win:claude-opus-5-6")
                                  :id))
                (gone (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                               :model "nobody:some-model")
                                 :id)))
            (should (= 1000000 (harness-session-test-window newer)))
            (should (= harness-provider-fallback-context-window (harness-session-test-window gone)))))
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

(ert-deftest harness-session-window-limit-caps-the-model-window ()
  "A session can cap its context window at a number of tokens.
The cap follows a model change (it never raises the model's window), an
outright window wins over it, and nil gives the model's window back."
  (harness-session-test-with
    (unwind-protect
        (progn
          (harness-session-test-provider '(("big" . 1000000) ("small" . 200000)))
          (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                             :model "test-win:big" :context-window-limit 256000)
                               :id)))
            (should (= 256000 (harness-session-test-window id)))
            (should (= 256000 (plist-get (harness-call 'session/get id) :context-window-limit)))
            ;; A model with less than the limit brings its own window.
            (harness-call 'session/update id :model "test-win:small" :silent t)
            (should (= 200000 (harness-session-test-window id)))
            ;; An outright window wins over the limit; unset, the limit
            ;; applies again.
            (harness-call 'session/update id :context-window 8000 :silent t)
            (should (= 8000 (harness-session-test-window id)))
            (harness-call 'session/update id :context-window nil :silent t)
            (should (= 200000 (harness-session-test-window id)))
            ;; It is kept across restarts, and a fork inherits it.
            (harness-session-flush)
            (clrhash harness-sessions)
            (harness-session--load-all)
            (should (= 200000 (harness-session-test-window id)))
            (let ((fork (harness-await (harness-call 'session/fork id :kind 'fork))))
              (should (= 256000 (plist-get fork :context-window-limit)))
              (should (= 200000 (plist-get fork :context-window))))
            ;; nil is the model's window, as for any session.
            (harness-call 'session/update id :context-window-limit nil :silent t)
            (should-not (plist-get (harness-call 'session/get id) :context-window-limit))
            (should (= 200000 (harness-session-test-window id)))
            (harness-call 'session/update id :model "test-win:big" :silent t)
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

(defvar harness-budget)

(ert-deftest harness-session-budget-setting-copies-dropped-once ()
  "Sessions used to copy the Budget setting into a budget of their own:
one budget per session, where the setting is one for them all.  A new
session no longer does, and the next start drops the copies saved, once:
a budget given to a session after that stays."
  (harness-session-test-with
    (let* ((harness-budget '(:amount 5.0 :hard t))
           (fresh (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
           ;; Sessions as the old version saved them, each with its copy.
           (old (cl-loop repeat 2
                         collect (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                                          :budget harness-budget)
                                            :id))))
      (should-not (plist-get (harness-call 'session/get fresh) :budget))
      ;; The old version left no marker.
      (harness-call 'store/delete harness-session--budget-copies-marker)
      (clrhash harness-sessions)
      (harness-session--init)
      (dolist (id (cons fresh old))
        (should-not (plist-get (harness-call 'session/get id) :budget))
        (should-not (plist-get (harness-call 'store/load (format "sessions/%s.json" id)) :budget)))
      (should (= 2 (plist-get (harness-call 'store/load harness-session--budget-copies-marker) :dropped)))
      ;; Once only: a budget given to a session from now on stays.
      (harness-call 'session/update (car old) :budget '(:amount 2.0) :silent t)
      (harness-session-flush)
      (clrhash harness-sessions)
      (harness-session--init)
      (should (equal '(:amount 2.0) (plist-get (harness-call 'session/get (car old)) :budget)))
      ;; Loaded over the old version in a running harness, this one drops
      ;; the copies the loaded sessions hold.
      (harness-call 'store/delete harness-session--budget-copies-marker)
      (harness-test-load-module 'session)
      (should-not (plist-get (harness-call 'session/get (car old)) :budget))
      (should (harness-call 'store/load harness-session--budget-copies-marker)))))

;;;; The thinking level of a BTW

(defvar harness-thinking)
(defvar harness-btw-thinking)

(defmacro harness-session-test-with-thinker (&rest body)
  "Run BODY in `harness-session-test-with' with provider `test-think' defined.
Its model thinker has the thinking levels low, medium and high; its
model plain has none."
  (declare (indent 0))
  `(harness-session-test-with
     (unwind-protect
         (progn
           (harness-define-provider 'test-think
             :complete #'ignore
             :models (lambda ()
                       (harness-resolved (list (list :name "thinker" :thinking-levels '("low" "medium" "high"))
                                               (list :name "plain")))))
           ,@body)
       (remhash 'test-think harness-providers)
       (harness-provider--forget 'test-think))))

(defun harness-session-test-btw-level (parent)
  "Return the thinking level of a new BTW over session PARENT."
  (plist-get (harness-call 'session/btw parent) :thinking))

(ert-deftest harness-session-btw-thinks-at-the-btw-level ()
  "A BTW starts at `harness-btw-thinking', low unless configured otherwise.
It does whatever the level of the session it is opened over, which
keeps its own.  A model the catalogue lists no such level for keeps the
parent's level, as nil does.  The setting layers: a .dir-locals.el sets
it for its directory.  The BTW can be changed afterwards like any
session."
  (harness-session-test-with-thinker
    (should (equal "low" (eval (car (get 'harness-btw-thinking 'standard-value)) t)))
    (let* ((harness-btw-thinking "low")
           (harness-thinking nil)
           (cwd (harness-test-temp-dir))
           (high (plist-get (harness-call 'session/create :cwd cwd :model "test-think:thinker" :thinking "high")
                            :id))
           (default (plist-get (harness-call 'session/create :cwd cwd :model "test-think:thinker") :id))
           (plain (plist-get (harness-call 'session/create :cwd cwd :model "test-think:plain" :thinking "high")
                             :id)))
      ;; Low, below a session's level or its model's default alike.
      (should (equal "low" (harness-session-test-btw-level high)))
      (should (equal "low" (harness-session-test-btw-level default)))
      (should (equal "high" (plist-get (harness-call 'session/get high) :thinking)))
      ;; A model without levels gets no level it did not have.
      (should (equal "high" (harness-session-test-btw-level plain)))
      ;; Another level, when the model offers it; else the parent's.
      (let ((harness-btw-thinking "medium"))
        (should (equal "medium" (harness-session-test-btw-level high))))
      (let ((harness-btw-thinking "max"))
        (should (equal "high" (harness-session-test-btw-level high)))
        (should-not (harness-session-test-btw-level default)))
      ;; nil: the parent's level, as before BTWs had one of their own.
      (let ((harness-btw-thinking nil))
        (should (equal "high" (harness-session-test-btw-level high)))
        (should-not (harness-session-test-btw-level default)))
      ;; Changed in the BTW, like in any session.
      (let ((btw (plist-get (harness-call 'session/btw high) :id)))
        (harness-call 'session/update btw :thinking "high" :silent t)
        (should (equal "high" (plist-get (harness-call 'session/get btw) :thinking))))
      ;; Configured for the directory the parent works in.
      (with-temp-file (expand-file-name ".dir-locals.el" cwd)
        (insert "((nil . ((harness-btw-thinking . \"medium\"))))\n"))
      (should (equal "medium" (harness-session-test-btw-level high)))
      (with-temp-file (expand-file-name ".dir-locals.el" cwd)
        (insert "((nil . ((harness-btw-thinking . nil))))\n"))
      (should (equal "high" (harness-session-test-btw-level high))))))

(ert-deftest harness-session-btw-created-without-a-level ()
  "A `btw' session created without a level, as a task board's is, starts at
the BTW level when its model offers it, else at `harness-thinking'.  A
level given to it wins, and other kinds of session are left alone."
  (harness-session-test-with-thinker
    (let ((harness-btw-thinking "low")
          (harness-thinking "high")
          (cwd (harness-test-temp-dir)))
      (cl-flet ((level (&rest plist)
                  (plist-get (apply #'harness-call 'session/create :cwd cwd plist) :thinking)))
        (should (equal "low" (level :kind 'btw :model "test-think:thinker")))
        (should (equal "high" (level :kind 'btw :model "test-think:plain")))
        (should (equal "medium" (level :kind 'btw :model "test-think:thinker" :thinking "medium")))
        (should (equal "high" (level :model "test-think:thinker")))
        (should (equal "high" (level :kind 'fork :model "test-think:thinker")))
        (let ((harness-btw-thinking nil))
          (should (equal "high" (level :kind 'btw :model "test-think:thinker"))))))))

;;;; Moving to another directory

(defun harness-session-test-repo ()
  "Make a git repository with a directory sub/ in it; return its root."
  (let ((root (harness-test-temp-dir)))
    (with-temp-buffer
      (let ((default-directory root))
        (unless (zerop (call-process "git" nil t nil "init" "-q"))
          (error "git init failed: %s" (buffer-string)))))
    (make-directory (expand-file-name "sub" root))
    root))

(defun harness-session-test-hints (id)
  "Return the hint texts of session ID, oldest first."
  (delq nil (mapcar (lambda (n) (and (eq (plist-get n :kind) 'hint) (plist-get n :content)))
                    (harness-call 'session/nodes id))))

(ert-deftest harness-session-move-changes-directory-project-and-grants ()
  "A move gives the session another working directory and the project
of that directory, keeps what its grants named, drops its provider
conversation, says so and is written at once."
  (harness-session-test-with
    (let* ((old (harness-test-temp-dir))
           (repo (harness-session-test-repo))
           (new (file-name-as-directory (expand-file-name "sub" repo)))
           (extra (harness-test-temp-dir))
           (id (plist-get (harness-call 'session/create :cwd old :name "wanderer") :id))
           (moved nil) (states nil))
      (harness-call 'session/update id :allowed-dirs (list "lib/" extra) :silent t)
      (harness-call 'session/set-provider-state id '(:cli-session-id "abc"))
      (harness-on 'session/moved (lambda (&rest args) (push args moved)))
      (harness-on 'session/provider-state-changed (lambda (_ state) (push state states)))
      ;; What would happen, without changing anything.
      (let ((check (harness-call 'session/move-check id new)))
        (should (equal new (plist-get check :cwd)))
        (should (equal repo (plist-get check :project)))
        (should (equal old (plist-get check :old-cwd)))
        (should-not (plist-get check :defer))
        (should (equal old (plist-get (harness-call 'session/get id) :cwd))))
      (let ((s (harness-call 'session/move id new)))
        (should (equal new (plist-get s :cwd)))
        (should (equal repo (plist-get s :project)))
        (should-not (plist-get s :move))
        ;; A grant relative to the old directory still names what it named;
        ;; the old directory itself is not kept.
        (should (equal (list (expand-file-name "lib/" old) extra) (plist-get s :allowed-dirs)))
        (should-not (plist-get s :provider-state)))
      (should (equal (list (list id old new)) moved))
      (should (equal '(nil) states))
      (should (equal "Moved to %s (was %s); the next turn starts a new provider conversation there, which gets the transcript"
                     (replace-regexp-in-string
                      (regexp-quote (abbreviate-file-name old)) "%s"
                      (replace-regexp-in-string (regexp-quote (abbreviate-file-name new)) "%s"
                                                (car (last (harness-session-test-hints id)))))))
      ;; The session list files it under its new project.
      (should (= 1 (length (harness-call 'session/list (list :project repo)))))
      ;; Written at once: a restart finds it moved.
      (clrhash harness-sessions)
      (harness-session--load-all)
      (let ((s (harness-call 'session/get id)))
        (should (equal new (plist-get s :cwd)))
        (should (equal repo (plist-get s :project)))
        (should (equal (list (expand-file-name "lib/" old) extra) (plist-get s :allowed-dirs)))))))

(ert-deftest harness-session-move-relative-keeping-the-old-directory ()
  "A relative directory is relative to the working directory.  With
`:keep-old-dir' the old directory stays allowed, unless the new one
holds it; `:project' files the session under another root."
  (harness-session-test-with
    (let* ((base (harness-test-temp-dir))
           (a (file-name-as-directory (expand-file-name "a" base)))
           (b (file-name-as-directory (expand-file-name "b" base)))
           (id (progn (make-directory a) (make-directory b)
                      (plist-get (harness-call 'session/create :cwd a) :id))))
      (let ((s (harness-call 'session/move id "../b" :keep-old-dir t :project base)))
        (should (equal b (plist-get s :cwd)))
        (should (equal base (plist-get s :project)))
        (should (equal (list a) (plist-get s :allowed-dirs)))
        (should (string-match-p "stays allowed" (car (last (harness-session-test-hints id))))))
      ;; Into the directory that holds it: nothing to keep.
      (let ((s (harness-call 'session/move id base :keep-old-dir t)))
        (should (equal base (plist-get s :cwd)))
        (should (equal (list a) (plist-get s :allowed-dirs))))
      ;; Without a conversation, the hint says nothing about one.
      (should-not (string-match-p "conversation" (car (last (harness-session-test-hints id))))))))

(ert-deftest harness-session-move-refusals ()
  "A move is refused for a session in a worktree, to a directory that is
not one, on another host or where the session is, and when a module
vetoes it through `session/before-move'."
  (harness-session-test-with
    (cl-letf* ((real-root (symbol-function 'harness-files-project-root))
               ;; Never open a connection to the made-up host.
               ((symbol-function 'harness-files-project-root)
                (lambda (dir) (if (file-remote-p dir) (file-name-as-directory dir) (funcall real-root dir)))))
      (let* ((cwd (harness-test-temp-dir))
             (other (harness-test-temp-dir))
             (id (plist-get (harness-call 'session/create :cwd cwd :name "stay") :id))
             (wt (plist-get (harness-call 'session/create :cwd other :worktree other :name "wt") :id))
             (remote "far"))
        (puthash remote (make-harness-session :id remote :name "far" :kind 'main :cwd "/ssh:box:/srv/app/"
                                              :host "/ssh:box:" :project "/ssh:box:/srv/app/")
                 harness-sessions)
        (cl-flet ((refused (regexp sid dir)
                    (let ((err (should-error (harness-call 'session/move sid dir) :type 'harness-error)))
                      (should (string-match-p regexp (harness-error-message err))))))
          (refused "worktree" wt cwd)
          (refused "not a directory" id (expand-file-name "missing" cwd))
          (refused "another host" id "/ssh:box:/srv/")
          (refused "another host" remote "/ssh:elsewhere:/srv/")
          (refused "absolute path on /ssh:box:" remote "~/elsewhere")
          (refused "works in .* already" id cwd)
          (refused "works in .* already" remote "/srv/app")
          (refused "Give the directory" id "  ")
          (harness-add-filter 'session/before-move
                              (lambda (gate session dir)
                                (if (equal dir other)
                                    (list :proceed nil :reason (format "%s is busy" (plist-get session :name)))
                                  gate)))
          (refused "Session stay cannot move: stay is busy" id other))
        ;; Nothing changed.
        (should (equal cwd (plist-get (harness-call 'session/get id) :cwd)))
        ;; A remote session moves on its host: a local name is a path there.
        (let ((s (harness-call 'session/move remote "../other")))
          (should (equal "/ssh:box:/srv/other/" (plist-get s :cwd)))
          (should (equal "/ssh:box:" (plist-get s :host)))
          (should (equal "/ssh:box:/srv/other/" (plist-get s :project))))))))

(ert-deftest harness-session-move-waits-for-the-turn ()
  "A session running a turn moves when the turn ends.  Until then the
move waits in its record, and moving it back to where it works cancels
it.  A move that cannot be made any more when the turn ends is dropped,
and a hint says why."
  (harness-session-test-with
    (let* ((cwd (harness-test-temp-dir))
           (new (harness-test-temp-dir))
           (id (plist-get (harness-call 'session/create :cwd cwd) :id)))
      (harness-call 'session/set-status id 'running)
      (let ((s (harness-call 'session/move id new :keep-old-dir t)))
        (should (equal cwd (plist-get s :cwd)))
        (should (equal new (plist-get (plist-get s :move) :cwd)))
        (should (plist-get (plist-get s :move) :keep-old-dir)))
      (should (string-match-p "when this turn ends" (car (last (harness-session-test-hints id)))))
      ;; Back where it works: the move is cancelled.
      (should-not (plist-get (harness-call 'session/move id cwd) :move))
      (harness-emit 'agent/turn-ended id 'end-turn)
      (should (equal cwd (plist-get (harness-call 'session/get id) :cwd)))
      ;; Again, and this time the turn ends.
      (harness-call 'session/move id new :keep-old-dir t)
      (harness-call 'session/set-status id 'idle)
      (harness-emit 'agent/turn-ended id 'end-turn)
      (let ((s (harness-call 'session/get id)))
        (should (equal new (plist-get s :cwd)))
        (should-not (plist-get s :move))
        (should (equal (list cwd) (plist-get s :allowed-dirs))))
      ;; A directory gone by the end of the turn: no move.
      (let ((gone (harness-test-temp-dir)))
        (harness-call 'session/set-status id 'running)
        (harness-call 'session/move id gone)
        (delete-directory gone)
        (harness-call 'session/set-status id 'idle)
        (harness-emit 'agent/turn-ended id 'end-turn)
        (let ((s (harness-call 'session/get id)))
          (should (equal new (plist-get s :cwd)))
          (should-not (plist-get s :move)))
        ;; Said plainly, not as Emacs prints the error.
        (should (string-match-p "\\`Not moved to [^:]*: [^\"]* is not a directory\\'"
                                (car (last (harness-session-test-hints id)))))))))

(ert-deftest harness-session-move-made-after-a-restart ()
  "A move waiting for a turn that a stop of the harness ended is made
as the session loads again."
  (harness-session-test-with
    (let* ((cwd (harness-test-temp-dir))
           (new (harness-test-temp-dir))
           (id (plist-get (harness-call 'session/create :cwd cwd) :id)))
      (harness-call 'session/set-status id 'running)
      (harness-call 'session/move id new)
      (harness-session-flush)
      (clrhash harness-sessions)
      (harness-session--load-all)
      (let ((s (harness-call 'session/get id)))
        (should (equal new (plist-get s :cwd)))
        (should-not (plist-get s :move))))))

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

;;;; A policy

(defvar harness-model)
(defvar harness-permission-mode)
(defvar harness-thinking)
(defvar harness-allowed-models)

(ert-deftest harness-session-policy-fixes-the-settings-of-every-session ()
  "A model, permission mode or non-interactive switch the policy sets is
every session's: one created asking for another, one saved before the
policy came, one running when it came.  Another value is refused."
  (harness-session-test-with
    (let* ((cwd (harness-test-temp-dir))
           (old (plist-get (harness-call 'session/create :cwd cwd :permission-mode 'yolo
                                         :model "deepseek:deepseek-flash")
                           :id))
           (saved (plist-get (harness-call 'session/create :cwd cwd :permission-mode 'yolo) :id))
           (events nil))
      (harness-session-flush)
      (harness-on 'session/updated (lambda (id changes) (push (cons id changes) events)))
      (harness-test-with-policy '((harness-permission-mode . ask) (harness-model . "claude:opus")
                                  (harness-non-interactive . t))
        (let* ((s (harness-call 'session/create :cwd cwd :permission-mode 'yolo
                                :model "deepseek:deepseek-flash" :non-interactive nil))
               (id (plist-get s :id)))
          (should (eq 'ask (plist-get s :permission-mode)))
          (should (equal "claude:opus" (plist-get s :model)))
          (should (eq t (plist-get s :non-interactive)))
          ;; Another value is refused, and nothing else of the update happens.
          (let ((err (should-error (harness-call 'session/update id :name "Renamed" :permission-mode 'yolo))))
            (should (string-match-p "harness-permission-mode is set by policy" (cadr err))))
          (should-not (equal "Renamed" (plist-get (harness-call 'session/get id) :name)))
          (should-error (harness-call 'session/update id :model "deepseek:deepseek-flash"))
          (should-error (harness-call 'session/update id :non-interactive nil))
          (should-error (harness-call 'session/set-all (list :permission-mode 'yolo)))
          ;; The policy's own value changes nothing, and the rest goes through.
          (harness-call 'session/update id :name "Renamed" :permission-mode "ask")
          (should (equal "Renamed" (plist-get (harness-call 'session/get id) :name)))
          ;; Thinking is not fixed: the policy does not set it.
          (harness-call 'session/update id :thinking "high")
          (should (equal "high" (plist-get (harness-call 'session/get id) :thinking))))
        ;; A session running when the policy came takes it at the reload
        ;; that reads it, and says so.
        (harness-emit 'harness/reloaded)
        (let ((s (harness-call 'session/get old)))
          (should (eq 'ask (plist-get s :permission-mode)))
          (should (equal "claude:opus" (plist-get s :model)))
          (should (eq t (plist-get s :non-interactive))))
        (should (assoc old events))
        ;; One saved before takes it as it is read.
        (clrhash harness-sessions)
        (harness-session--load-all)
        (let ((s (harness-call 'session/get saved)))
          (should (eq 'ask (plist-get s :permission-mode)))
          (should (equal "claude:opus" (plist-get s :model))))))))

(ert-deftest harness-session-policy-refuses-a-model-it-does-not-allow ()
  "A model `harness-allowed-models' leaves out is refused to a session."
  (harness-session-test-with
    (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                       :model "claude:opus")
                         :id)))
      (harness-test-with-policy '((harness-allowed-models "claude"))
        (harness-call 'session/update id :model "claude:sonnet")
        (let ((err (should-error (harness-call 'session/update id :model "deepseek:deepseek-flash"))))
          (should (string-match-p "deepseek:deepseek-flash is not allowed" (cadr err)))
          (should (string-match-p "set by policy" (cadr err))))
        (should (equal "claude:sonnet" (plist-get (harness-call 'session/get id) :model)))))))

(provide 'harness-session-test)
;;; harness-session-test.el ends here
