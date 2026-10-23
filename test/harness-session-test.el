;;; harness-session-test.el --- Tests for the session module  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defvar harness-tasks-context-limit)
;; The tasks module is not loaded here; declaring the option special lets
;; a test bind it, as the tool that reads it binds it in reality.

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

(ert-deftest harness-session-tmp-root-keeps-off-the-ram-disk ()
  "The sessions' temporary directories go where the user chose; else where
the system's temporary directory was set to (TMPDIR); else to the disk's
temporary directory, not the stock /tmp, a RAM disk on many systems;
and to /tmp after all where there is no such directory."
  (harness-session-test-with
    (let* ((harness-session--tmp-root nil)
           (uid (user-uid))
           (disk (harness-test-temp-dir))
           (chosen (harness-test-temp-dir))
           (harness-session--disk-tmp disk)
           (harness-session-tmp-directory nil)
           (temporary-file-directory "/tmp/")
           (under (lambda (base) (expand-file-name (format "harness-%d/" uid) base))))
      ;; Nothing chose a place: the disk's.
      (should (equal (funcall under disk) (harness-session-tmp-root)))
      ;; Unless that is no directory to write in.
      (let ((harness-session--disk-tmp (expand-file-name "missing/" disk)))
        (should (equal (format "/tmp/harness-%d/" uid) (harness-session-tmp-root))))
      (let ((harness-session--disk-tmp nil))
        (should (equal (format "/tmp/harness-%d/" uid) (harness-session-tmp-root))))
      ;; TMPDIR, or the user's own setting of the variable, is a choice.
      (let ((temporary-file-directory "/data/scratch"))
        (should (equal (format "/data/scratch/harness-%d/" uid) (harness-session-tmp-root))))
      ;; The option wins over all of that; it can name /tmp to have RAM again.
      (let ((harness-session-tmp-directory chosen))
        (should (equal (funcall under chosen) (harness-session-tmp-root))))
      (let ((harness-session-tmp-directory "/tmp"))
        (should (equal (format "/tmp/harness-%d/" uid) (harness-session-tmp-root))))
      ;; A blank option names nothing.
      (let ((harness-session-tmp-directory "  "))
        (should (equal (funcall under disk) (harness-session-tmp-root))))
      ;; The internal root, which the tests set, beats the option.
      (let ((harness-session-tmp-directory chosen)
            (harness-session--tmp-root (expand-file-name "mine/" disk)))
        (should (equal (expand-file-name "mine/" disk) (harness-session-tmp-root)))
        (should (equal (list (expand-file-name "mine/" disk)) (harness-session-tmp-roots)))))))

(ert-deftest harness-session-tmp-roots-include-the-one-earlier-harnesses-used ()
  "What earlier harnesses made in the system's temporary directory is
cleaned up all the same, so the old root follows the one in use."
  (harness-session-test-with
    (let* ((harness-session--tmp-root nil)
           (uid (user-uid))
           (system (harness-test-temp-dir))
           (disk (harness-test-temp-dir))
           (temporary-file-directory system)
           (harness-session--disk-tmp disk)
           (harness-session-tmp-directory disk))
      (should (equal (list (expand-file-name (format "harness-%d/" uid) disk)
                           (expand-file-name (format "harness-%d/" uid) system))
                     (harness-session-tmp-roots)))
      ;; The same place twice is one.
      (let ((harness-session-tmp-directory nil))
        (should (equal (list (expand-file-name (format "harness-%d/" uid) system))
                       (harness-session-tmp-roots)))))))

(defun harness-session-test--make (cwd &rest args)
  "Make a session in CWD with ARGS, a `session/create' plist; return its id."
  (plist-get (apply #'harness-call 'session/create :cwd cwd args) :id))

(defun harness-session-test--age (id days)
  "Make the last change of session ID DAYS days old."
  (aset (harness-session--get id) (cl-struct-slot-offset 'harness-session 'updated)
        (- (float-time) (* days 86400))))

(defun harness-session-test--await-trash (root)
  "Wait until the directories being deleted in ROOT are gone."
  (harness-test-wait (lambda () (not (directory-files root nil "\\`\\.trash-")))
                     10 "the deletions in the background to finish"))

(ert-deftest harness-session-tmp-finished-p-follows-the-task-or-the-closing ()
  "A task's session is over when the task is done, a sub-agent's with its
task's; a session of no task when it is closed.  One at work, or waiting
for the user, never is."
  (harness-session-test-with
    (let* ((cwd (harness-test-temp-dir))
           (tasks nil)
           (finished (lambda (id) (and (harness-session--tmp-finished-p (harness-session--get id)) t))))
      (harness-register-method 'task/for-session
                               (lambda (id) (when-let* ((c (cdr (assoc id tasks)))) (list :id "t-1" :column c))))
      (let* ((open (harness-session-test--make cwd))
             (closed (harness-session-test--make cwd))
             (done (harness-session-test--make cwd))
             (review (harness-session-test--make cwd))
             (kid-done (harness-session-test--make cwd :kind 'subagent :parent-id done))
             (kid-review (harness-session-test--make cwd :kind 'subagent :parent-id review))
             (kid-closed (harness-session-test--make cwd :kind 'subagent :parent-id closed))
             (kid-open (harness-session-test--make cwd :kind 'subagent :parent-id open))
             (grandkid (harness-session-test--make cwd :kind 'subagent :parent-id kid-done))
             (fork (harness-session-test--make cwd :parent-id done)))
        (setq tasks (list (cons done 'done) (cons review 'review)))
        ;; Open (idle) is not over, task or none, unless the task is done.
        (should-not (funcall finished open))
        (should-not (funcall finished review))
        (should (funcall finished done))
        (should (funcall finished kid-done))
        (should (funcall finished grandkid))
        (should-not (funcall finished kid-review))
        (should-not (funcall finished kid-open))
        ;; A sub-agent of a conversation of no task is over when it is closed.
        (should-not (funcall finished kid-closed))
        (dolist (id (list closed review kid-open kid-closed fork))
          (harness-call 'session/deactivate id))
        (should-not (funcall finished open))
        (should (funcall finished closed))
        ;; A task in review keeps its session's files, closed or not.
        (should-not (funcall finished review))
        (should-not (funcall finished kid-review))
        (should (funcall finished kid-open))
        (should (funcall finished kid-closed))
        ;; A fork of a done task's session is a conversation of its own.
        (should (funcall finished fork))
        (harness-call 'session/resume fork)
        (should-not (funcall finished fork))
        ;; At work, or waiting on the user: never.
        (dolist (status '(running blocked))
          (harness-call 'session/set-status done status)
          (harness-call 'session/set-status closed status)
          (should-not (funcall finished done))
          (should-not (funcall finished closed)))
        ;; Without the tasks module, only closing counts.
        (harness-unregister-method 'task/for-session)
        (harness-call 'session/set-status done 'idle)
        (should-not (funcall finished done))
        (harness-call 'session/deactivate done)
        (should (funcall finished done))))))

(ert-deftest harness-session-tmp-sweep-deletes-the-directories-of-finished-sessions ()
  "A sweep deletes the temporary directory of each session that is over and
has been quiet long enough, at once, and what was in it in the
background -- links not followed.  What belongs to a session still open or
at work, a task in review, a session that changed lately, a session of
some other harness (the root is shared), a link and the dev sockets'
directory stays."
  (harness-session-test-with
    (let* ((harness-session--tmp-root (expand-file-name "root/" (harness-test-temp-dir)))
           (harness-session--tmp-warned nil)
           (cwd (harness-test-temp-dir))
           (elsewhere (harness-test-temp-dir))
           (tasks nil)
           (dir-of (lambda (id)
                     (let ((dir (harness-call 'session/tmp-dir id)))
                       (with-temp-file (expand-file-name "scratch.txt" dir) (insert "x"))
                       dir))))
      (with-temp-file (expand-file-name "precious.txt" elsewhere) (insert "mine"))
      (harness-register-method 'task/for-session
                               (lambda (id) (when-let* ((c (cdr (assoc id tasks)))) (list :id "t-1" :column c))))
      (let* ((open (harness-session-test--make cwd))
             (closed (harness-session-test--make cwd))
             (recent (harness-session-test--make cwd))
             (done (harness-session-test--make cwd))
             (kid (harness-session-test--make cwd :kind 'subagent :parent-id done))
             (review (harness-session-test--make cwd))
             (busy (harness-session-test--make cwd))
             (linked (harness-session-test--make cwd))
             (bare (harness-session-test--make cwd))
             (dirs (mapcar (lambda (id) (cons id (funcall dir-of id)))
                           (list open closed recent done kid review busy linked)))
             (dir (lambda (id) (cdr (assoc id dirs))))
             (stranger (expand-file-name "0a0a0a0a-0a0a-4a0a-8a0a-0a0a0a0a0a0a/" harness-session--tmp-root))
             (sockets (expand-file-name ".dev/" harness-session--tmp-root)))
        (setq tasks (list (cons done 'done) (cons review 'review) (cons busy 'done)))
        (dolist (id (list closed done kid review linked bare))
          (harness-call 'session/deactivate id))
        (harness-call 'session/set-status busy 'running)
        (harness-call 'session/deactivate recent)
        ;; A directory another harness made for a session of its own.
        (make-directory stranger t)
        (with-temp-file (expand-file-name "theirs.txt" stranger) (insert "theirs"))
        (make-directory sockets t)
        ;; A link where one session's directory goes, and none for another.
        (delete-directory (funcall dir linked) t)
        (make-symbolic-link (directory-file-name elsewhere) (directory-file-name (funcall dir linked)))
        (delete-directory (harness-call 'session/tmp-dir bare) t)
        ;; Everything but the recent one has been quiet for a week.
        (dolist (id (list open closed done kid review busy linked bare))
          (harness-session-test--age id 7))
        (let ((due (sort (mapcar (lambda (f) (plist-get f :id)) (harness-session--tmp-sweep t)) #'string<)))
          ;; A dry run says what would go, and deletes nothing.
          (should (equal (sort (list closed done kid) #'string<) due))
          (dolist (id (list closed done kid))
            (should (file-directory-p (funcall dir id)))))
        (let ((gone (harness-call 'session/tmp-sweep)))
          (should (equal (sort (list closed done kid) #'string<)
                         (sort (mapcar (lambda (f) (plist-get f :id)) gone) #'string<)))
          (should (equal (funcall dir closed) (plist-get (cl-find closed gone :key (lambda (f) (plist-get f :id))) :dir))))
        ;; Gone at once, whatever the removal in the background is at.
        (dolist (id (list closed done kid))
          (should-not (file-exists-p (funcall dir id))))
        (dolist (id (list open recent review busy))
          (should (file-exists-p (expand-file-name "scratch.txt" (funcall dir id)))))
        (should (file-symlink-p (directory-file-name (funcall dir linked))))
        (should (file-exists-p (expand-file-name "precious.txt" elsewhere)))
        (should (file-exists-p (expand-file-name "theirs.txt" stranger)))
        (should (file-directory-p sockets))
        (harness-session-test--await-trash harness-session--tmp-root)
        ;; Nothing is left to do, and a session that comes back gets a new directory.
        (should-not (harness-session--tmp-sweep t))
        (should (file-directory-p (harness-call 'session/tmp-dir closed)))
        (should-not (directory-files (harness-call 'session/tmp-dir closed) nil "\\`[^.]"))))))

(ert-deftest harness-session-tmp-sweep-waits-for-the-retention ()
  "A finished session's directory goes once the session has been quiet
for `harness-session-tmp-retention-days'; with none, it goes with its
session only; with a retention of 0, at the next sweep."
  (harness-session-test-with
    (let* ((harness-session--tmp-root (expand-file-name "root/" (harness-test-temp-dir)))
           (cwd (harness-test-temp-dir))
           (id (harness-session-test--make cwd))
           (dir (harness-call 'session/tmp-dir id)))
      (harness-call 'session/deactivate id)
      (harness-session-test--age id 2)
      (let ((harness-session-tmp-retention-days 3))
        (should-not (harness-session--tmp-sweep)))
      (let ((harness-session-tmp-retention-days nil))
        (should-not (harness-session--tmp-sweep)))
      (should (file-directory-p dir))
      (let ((harness-session-tmp-retention-days 1))
        (should (equal (list (list :id id :dir dir)) (harness-session--tmp-sweep t))))
      (harness-session-test--age id 0)
      (let ((harness-session-tmp-retention-days 1))
        (should-not (harness-session--tmp-sweep)))
      (let ((harness-session-tmp-retention-days 0))
        (should (equal (list (list :id id :dir dir)) (harness-session--tmp-sweep))))
      (should-not (file-exists-p dir))
      (harness-session-test--await-trash harness-session--tmp-root))))

(ert-deftest harness-session-tmp-sweep-counts-from-the-day-a-task-was-accepted ()
  "A task that waited a week in review is over from the day it was accepted
or finished, not from the session's last change, so that what its report
shows outlives the review by the whole retention; a sub-agent follows its
task."
  (harness-session-test-with
    (let* ((harness-session--tmp-root (expand-file-name "root/" (harness-test-temp-dir)))
           (cwd (harness-test-temp-dir))
           (now (float-time))
           (tasks nil))
      (harness-register-method 'task/for-session (lambda (id) (cdr (assoc id tasks))))
      (let* ((lately (harness-session-test--make cwd))
             (kid (harness-session-test--make cwd :kind 'subagent :parent-id lately))
             (long-ago (harness-session-test--make cwd))
             (unreviewed (harness-session-test--make cwd))
             (undated (harness-session-test--make cwd)))
        (setq tasks
              (list (cons lately (list :id "t-1" :column 'done :finished (- now (* 5 86400)) :verified-at now))
                    (cons long-ago (list :id "t-2" :column 'done :finished (- now (* 9 86400))
                                         :verified-at (- now (* 3 86400))))
                    ;; Done with no review: a verification of false (JSON's), no time.
                    (cons unreviewed (list :id "t-3" :column 'done :finished (- now (* 9 86400)) :verified-at :false))
                    ;; A record that says nothing of times: the session's own.
                    (cons undated (list :id "t-4" :column 'done))))
        (dolist (id (list lately kid long-ago unreviewed undated))
          (harness-call 'session/deactivate id)
          (harness-session-test--age id 10))
        (should (> (harness-session--tmp-over-since (harness-session--get lately)) (- now 5)))
        (should (> (harness-session--tmp-over-since (harness-session--get kid)) (- now 5)))
        (should (= (- now (* 9 86400))
                   (harness-session--tmp-over-since (harness-session--get unreviewed))))
        (should (equal (sort (list long-ago unreviewed undated) #'string<)
                       (sort (mapcar (lambda (f) (plist-get f :id)) (harness-session--tmp-sweep t))
                             #'string<)))
        ;; With a longer retention, only what has been over longer is due.
        (let ((harness-session-tmp-retention-days 6))
          (should (equal (sort (list unreviewed undated) #'string<)
                         (sort (mapcar (lambda (f) (plist-get f :id)) (harness-session--tmp-sweep t))
                               #'string<))))))))

(ert-deftest harness-session-tmp-sweep-touches-only-what-is-the-users-own ()
  "A root, or a directory, somebody else owns is left alone by a sweep, as
by the deletion of its session: the temporary directory is shared."
  (harness-session-test-with
    (let* ((harness-session--tmp-root (expand-file-name "root/" (harness-test-temp-dir)))
           (cwd (harness-test-temp-dir))
           (id (harness-session-test--make cwd))
           (other (harness-session-test--make cwd))
           (dir (harness-call 'session/tmp-dir id))
           (other-dir (harness-call 'session/tmp-dir other))
           (owner (file-attribute-user-id (file-attributes harness-session--tmp-root 'integer))))
      (harness-call 'session/deactivate id)
      (harness-session-test--age id 7)
      (cl-letf (((symbol-function 'user-uid) (lambda () (1+ owner))))
        (should-not (harness-session--tmp-sweep))
        (harness-call 'session/delete other))
      (should (file-directory-p dir))
      (should (file-directory-p other-dir))
      (should (equal (list (list :id id :dir dir)) (harness-session--tmp-sweep)))
      (should-not (file-exists-p dir))
      (harness-session-test--await-trash harness-session--tmp-root))))

(ert-deftest harness-session-tmp-sweep-and-deletion-reach-the-old-root ()
  "The directories earlier harnesses made in the system's temporary
directory go too: with their session, or once it is finished."
  (harness-session-test-with
    (let* ((harness-session--tmp-root nil)
           (system (harness-test-temp-dir))
           (new (harness-test-temp-dir))
           (temporary-file-directory system)
           (harness-session-tmp-directory new)
           (old-root (expand-file-name (format "harness-%d/" (user-uid)) system))
           (cwd (harness-test-temp-dir))
           (closed (harness-session-test--make cwd))
           (gone (harness-session-test--make cwd))
           (open (harness-session-test--make cwd))
           (old (lambda (id) (expand-file-name (concat id "/") old-root))))
      (with-file-modes #o700 (make-directory old-root t))
      (dolist (id (list closed gone open))
        (with-file-modes #o700 (make-directory (funcall old id)))
        (with-temp-file (expand-file-name "scratch.txt" (funcall old id)) (insert "x")))
      (harness-call 'session/deactivate closed)
      (harness-session-test--age closed 7)
      (should (equal (list (list :id closed :dir (funcall old closed)) )
                     (cl-remove-if-not (lambda (f) (equal (plist-get f :dir) (funcall old closed)))
                                       (harness-session--tmp-sweep t))))
      (harness-session--tmp-sweep)
      (should-not (file-exists-p (funcall old closed)))
      (should (file-directory-p (funcall old open)))
      (harness-call 'session/delete gone)
      (should-not (file-exists-p (funcall old gone)))
      (should (file-directory-p (funcall old open)))
      (harness-session-test--await-trash old-root)
      (harness-session-test--await-trash (harness-session-tmp-root)))))

(ert-deftest harness-session-tmp-sweep-purges-what-a-deletion-left ()
  "A directory still named for deletion an hour after it was set aside was
left by an `rm' that failed, or a harness that stopped: the next sweep
deletes it, and nothing else of the root."
  (harness-session-test-with
    (let* ((harness-session--tmp-root (expand-file-name "root/" (harness-test-temp-dir)))
           (leftover (expand-file-name ".trash-abc-123456/" harness-session--tmp-root))
           (other (expand-file-name "not-trash/" harness-session--tmp-root)))
      (with-file-modes #o700
        (make-directory leftover t)
        (make-directory other t))
      (with-temp-file (expand-file-name "x" leftover) (insert "x"))
      (harness-session--tmp-sweep)
      ;; Fresh: its `rm' may be running.
      (should (file-directory-p leftover))
      (let ((later (time-add (current-time) 7200)))
        (cl-letf (((symbol-function 'current-time) (lambda () later)))
          (harness-session--tmp-sweep)))
      (harness-session-test--await-trash harness-session--tmp-root)
      (should-not (file-exists-p leftover))
      (should (file-directory-p other)))))

(ert-deftest harness-session-tmp-sweep-runs-on-a-timer-the-module-stops ()
  "The module sweeps by itself a while after it starts and then every half
hour, and stops sweeping when it stops; no delay sets no timer."
  (harness-session-test-with
    (let ((harness-session--tmp-timer nil)
          (harness-session--tmp-sweep-delay nil))
      (harness-session--tmp-arm)
      (should-not harness-session--tmp-timer)
      (let ((harness-session--tmp-sweep-delay 3600))
        (harness-session--tmp-arm)
        (should (timerp harness-session--tmp-timer))
        (should (= harness-session--tmp-sweep-interval (timer--repeat-delay harness-session--tmp-timer)))
        ;; Started again, as a reload does: the same timer.
        (let ((timer harness-session--tmp-timer))
          (harness-session--tmp-arm)
          (should (eq timer harness-session--tmp-timer)))
        (harness-session--shutdown)
        (should-not harness-session--tmp-timer)
        (should-not (memq 'harness-session--tmp-sweep-on-timer
                          (mapcar #'timer--function timer-list)))))))

(ert-deftest harness-session-tmp-sweep-waits-for-the-tasks-it-must-ask ()
  "Without the tasks module's say, the session of a task in review would
pass for a closed conversation: a sweep does not run while the module is
there and not ready, and a session whose task cannot be told is kept
while the rest is swept."
  (harness-session-test-with
    (let* ((harness-session--tmp-root (expand-file-name "root/" (harness-test-temp-dir)))
           (harness-session-tmp-retention-days 0)
           (cwd (harness-test-temp-dir))
           (trouble (harness-session-test--make cwd))
           (closed (harness-session-test--make cwd))
           (dir (lambda (id) (harness-call 'session/tmp-dir id))))
      (dolist (id (list trouble closed))
        (harness-call 'session/deactivate id)
        (harness-session-test--age id 7))
      ;; The module is defined, and has not started: nothing may go.
      (harness-define-module 'tasks :doc "the tasks, not started")
      (should-not (harness-module-ready-p 'tasks))
      (should-error (harness-session--tmp-sweep) :type 'harness-error)
      (should-error (harness-call 'session/tmp-sweep t) :type 'harness-error)
      ;; The timer says so in the debug log, and goes on.
      (let ((harness-log-level 'debug))
        (harness-session--tmp-sweep-on-timer))
      (with-current-buffer (get-buffer-create harness-log-buffer-name)
        (should (string-match-p "not sweeping the temporary directories: the tasks module is not ready"
                                (buffer-string))))
      (should (file-directory-p (funcall dir closed)))
      ;; Ready, and one session whose task it cannot tell: that one stays.
      (harness-define-module 'tasks :doc "the tasks" :init #'ignore)
      (harness-module-start 'tasks)
      (should (harness-module-ready-p 'tasks))
      (harness-register-method 'task/for-session
                               (lambda (id) (if (equal id trouble) (error "no task board") nil)))
      (should (equal (list (list :id closed :dir (funcall dir closed))) (harness-session--tmp-sweep)))
      (should (file-directory-p (funcall dir trouble)))
      (with-current-buffer (get-buffer-create harness-log-buffer-name)
        (should (string-match-p (format "keeping the temporary directory of %s" trouble) (buffer-string))))
      (harness-session-test--await-trash harness-session--tmp-root))))

(ert-deftest harness-session-tmp-sweep-timer-sweeps ()
  "The timer the module sets runs the sweep, by itself."
  (harness-session-test-with
    (let* ((harness-session--tmp-root (expand-file-name "root/" (harness-test-temp-dir)))
           (harness-session-tmp-retention-days 0)
           (harness-session--tmp-timer nil)
           (id (harness-session-test--make (harness-test-temp-dir)))
           (dir (harness-call 'session/tmp-dir id))
           (kept (harness-session-test--make (harness-test-temp-dir)))
           (kept-dir (harness-call 'session/tmp-dir kept)))
      (harness-call 'session/deactivate id)
      (harness-session-test--age id 1)
      (unwind-protect
          (let ((harness-session--tmp-sweep-delay 0.05))
            (harness-session--tmp-arm)
            (harness-test-wait (lambda () (not (file-exists-p dir))) 10 "the timer's sweep")
            (should (file-directory-p kept-dir)))
        (harness-session--tmp-disarm))
      (harness-session-test--await-trash harness-session--tmp-root))))

(ert-deftest harness-session-tmp-sweep-method-takes-a-dry-run-from-json ()
  "A client asks for a dry run with true; a false is a real sweep."
  (harness-session-test-with
    (let* ((harness-session--tmp-root (expand-file-name "root/" (harness-test-temp-dir)))
           (id (harness-session-test--make (harness-test-temp-dir)))
           (dir (harness-call 'session/tmp-dir id)))
      (harness-call 'session/deactivate id)
      (harness-session-test--age id 7)
      (should (equal (list (list :id id :dir dir)) (harness-call 'session/tmp-sweep t)))
      (should (file-directory-p dir))
      (should (equal (list (list :id id :dir dir)) (harness-call 'session/tmp-sweep :false)))
      (should-not (file-exists-p dir))
      (harness-session-test--await-trash harness-session--tmp-root))))

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

(defun harness-session-test-ids (sessions)
  "Return the ids of the session plists SESSIONS, sorted."
  (sort (mapcar (lambda (s) (plist-get s :id)) sessions) #'string<))

(ert-deftest harness-session-list-takes-ids ()
  "`:ids' names the only sessions that match; without it, or empty, all do."
  (harness-session-test-with
    (let* ((cwd (harness-test-temp-dir))
           (a (plist-get (harness-call 'session/create :cwd cwd) :id))
           (b (plist-get (harness-call 'session/create :cwd cwd) :id))
           (c (plist-get (harness-call 'session/create :cwd cwd) :id))
           (listed (lambda (filter) (harness-session-test-ids (harness-call 'session/list filter)))))
      (should (equal (sort (list a b c) #'string<) (funcall listed nil)))
      (should (equal (sort (list a b c) #'string<) (funcall listed (list :ids nil))))
      (should (equal (list a) (funcall listed (list :ids (list a)))))
      ;; An id no session has names nothing.
      (should (equal (sort (list b c) #'string<) (funcall listed (list :ids (list c "gone" b)))))
      (should-not (funcall listed (list :ids (list "gone"))))
      ;; The other keys narrow it further.
      (harness-call 'session/deactivate c)
      (should (equal (list b) (funcall listed (list :ids (list b c) :active t))))
      ;; `session/select' passes it on, and `:except' still takes sessions out.
      (should (equal (list a) (harness-session-test-ids
                               (harness-call 'session/select (list :ids (list a b) :except (list b)))))))))

(ert-deftest harness-session-set-all-changes-only-the-sessions-ids-names ()
  "A bulk change with `:ids' reaches those sessions and no other, even when
`:tasks' adds the sessions of the current tasks."
  (harness-session-test-with
    (let* ((cwd (harness-test-temp-dir))
           (a (plist-get (harness-call 'session/create :cwd cwd :model "claude:opus") :id))
           (b (plist-get (harness-call 'session/create :cwd cwd :model "claude:opus") :id))
           (task (plist-get (harness-call 'session/create :cwd cwd :model "claude:opus") :id))
           (model (lambda (id) (plist-get (harness-call 'session/get id) :model))))
      (should (equal (list a) (harness-call 'session/set-all (list :model "deepseek:deepseek-flash")
                                            (list :ids (list a)))))
      (should (equal "deepseek:deepseek-flash" (funcall model a)))
      (should (equal "claude:opus" (funcall model b)))
      (should (equal "claude:opus" (funcall model task)))
      ;; Ids that name no session change nothing, and `:except' still holds.
      (should-not (harness-call 'session/set-all (list :model "claude:sonnet") (list :ids (list "gone"))))
      (should-not (harness-call 'session/set-all (list :model "claude:sonnet")
                                (list :ids (list b) :except (list b))))
      (should (equal "claude:opus" (funcall model b)))
      ;; The sessions of the current tasks join a selection, but not
      ;; those `:ids' leaves out.
      (harness-call 'session/deactivate task)
      (harness-register-method 'task/session-ids
                               (lambda (&optional filter)
                                 (unless (equal '("done") (plist-get filter :columns)) (list task))))
      (should (equal (list b) (harness-session-test-ids
                               (harness-call 'session/select (list :ids (list b) :active t :tasks t)))))
      (should (equal (sort (list b task) #'string<)
                     (harness-session-test-ids
                      (harness-call 'session/select (list :ids (list b task) :active t :tasks t)))))
      (should (equal (list b) (harness-call 'session/set-all (list :model "claude:sonnet")
                                            (list :ids (list b) :active t :tasks t))))
      (should (equal "claude:sonnet" (funcall model b)))
      (should (equal "claude:opus" (funcall model task))))))

(ert-deftest harness-session-setting-equal-p-reads-json-values ()
  "Settings compare as they mean: a false non-interactive is off however
it is spelt, and a mode's name is the mode."
  (should (harness-setting-equal-p :non-interactive nil :false))
  (should (harness-setting-equal-p :non-interactive :false nil))
  (should (harness-setting-equal-p :non-interactive t t))
  (should-not (harness-setting-equal-p :non-interactive t :false))
  (should-not (harness-setting-equal-p :non-interactive nil t))
  (should (harness-setting-equal-p :permission-mode 'yolo "yolo"))
  (should (harness-setting-equal-p :permission-mode "ask" 'ask))
  (should-not (harness-setting-equal-p :permission-mode 'ask "yolo"))
  (should (harness-setting-equal-p :model "claude:opus" "claude:opus"))
  (should-not (harness-setting-equal-p :model "claude:opus" "claude:sonnet"))
  ;; Elsewhere a false is a value of its own.
  (should-not (harness-setting-equal-p :thinking nil :false)))

(ert-deftest harness-session-set-all-takes-in-the-sessions-of-tasks ()
  "With `:tasks', a bulk switch also reaches the closed session a current
task goes on in, but not one `:except' names; a non-interactive switch
compares as a boolean, so a session that is off stays untouched when
asked for a false."
  (harness-session-test-with
    (let* ((cwd (harness-test-temp-dir))
           (open (plist-get (harness-call 'session/create :cwd cwd) :id))
           (task (plist-get (harness-call 'session/create :cwd cwd) :id))
           (left (plist-get (harness-call 'session/create :cwd cwd) :id))
           (skip (plist-get (harness-call 'session/create :cwd cwd) :id)))
      (harness-call 'session/deactivate task)
      (harness-call 'session/deactivate left)
      (harness-register-method 'task/session-ids
                               (lambda (&optional filter)
                                 (unless (equal '("done") (plist-get filter :columns))
                                   (list task skip "gone"))))
      (should (equal (sort (list open skip task) #'string<)
                     (sort (mapcar (lambda (s) (plist-get s :id))
                                   (harness-call 'session/select (list :active t :tasks t)))
                           #'string<)))
      (should-not (harness-call 'session/set-all (list :non-interactive :false) (list :active t :tasks t)))
      (let ((changed (harness-call 'session/set-all (list :non-interactive t)
                                   (list :active t :tasks t :except (list skip)))))
        (should (equal (sort (list open task) #'string<) (sort changed #'string<)))
        (should (harness-json-true-p (plist-get (harness-call 'session/get task) :non-interactive)))
        (should-not (plist-get (harness-call 'session/get left) :non-interactive))
        (should-not (plist-get (harness-call 'session/get skip) :non-interactive))))))

(ert-deftest harness-session-select-leaves-out-the-sessions-of-done-tasks ()
  "With `:tasks', a completed task's session is left out of the selection,
and so of every bulk change, even while that session is active and of
every project; the current tasks' sessions stay in."
  (harness-session-test-with
    (let* ((cwd (harness-test-temp-dir))
           (open (plist-get (harness-call 'session/create :cwd cwd) :id))
           (done (plist-get (harness-call 'session/create :cwd cwd) :id))
           (task (plist-get (harness-call 'session/create :cwd cwd) :id))
           (everything (list :active t :tasks t)))
      (harness-call 'session/deactivate task)
      (harness-register-method 'task/session-ids
                               (lambda (&optional filter)
                                 (if (equal '("done") (plist-get filter :columns))
                                     (list done)
                                   (list task))))
      (should (equal (sort (list open task) #'string<)
                     (sort (mapcar (lambda (s) (plist-get s :id))
                                   (harness-call 'session/select everything))
                           #'string<)))
      (should (equal (sort (list open task) #'string<)
                     (sort (harness-call 'session/set-all (list :non-interactive t) everything)
                           #'string<)))
      (should-not (plist-get (harness-call 'session/get done) :non-interactive))
      (should (harness-json-true-p (plist-get (harness-call 'session/get open) :non-interactive))))))

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

(ert-deftest harness-session-last-message-moves-with-messages-only ()
  "A user or assistant node sets `:last-message' to its `:ts', its kind a
symbol or a string.  A hint, thinking, a tool call or result, a
compaction node, a setting and usage leave it alone, though `:updated'
moves with each; the record keeps it, and one written without it has none."
  (harness-session-test-with
    (let ((now 1000.0))
      (cl-letf (((symbol-function 'float-time) (lambda (&optional _) now)))
        (let* ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
               (get (lambda (key) (plist-get (harness-call 'session/get id) key)))
               (append-node (lambda (node) (harness-call 'session/append id node))))
          (should-not (funcall get :last-message))
          ;; A message is written now, unless its node says when.
          (setq now 2000.0)
          (funcall append-node '(:kind user :content "q1"))
          (should (= 2000.0 (funcall get :last-message)))
          (setq now 3000.0)
          (funcall append-node '(:kind assistant :content "a1" :ts 2500.0))
          (should (= 2500.0 (funcall get :last-message)))
          (should (= 3000.0 (funcall get :updated)))
          ;; Nothing else is a message.
          (dolist (node '((:kind thinking :content "hm")
                          (:kind tool-call :call-id "c1" :name "read_file" :input (:path "x"))
                          (:kind tool-result :call-id "c1" :output "ok")
                          (:kind compaction :content "the story so far")))
            (cl-incf now 100.0)
            (funcall append-node node)
            (should (= 2500.0 (funcall get :last-message)))
            (should (= now (funcall get :updated))))
          (cl-incf now 100.0)
          (harness-call 'session/hint id "a hint")
          (should (= 2500.0 (funcall get :last-message)))
          (should (= now (funcall get :updated)))
          (cl-incf now 100.0)
          (harness-call 'session/update id :name "Renamed")
          (should (equal "Renamed" (funcall get :name)))
          (should (= 2500.0 (funcall get :last-message)))
          (should (= now (funcall get :updated)))
          (cl-incf now 100.0)
          (harness-call 'session/usage-add id '(:input 10 :output 5))
          (should (= 2500.0 (funcall get :last-message)))
          (should (= now (funcall get :updated)))
          ;; The kind may be a string, as a node from the wire has it.
          (cl-incf now 100.0)
          (funcall append-node '(:kind "user" :content "q2"))
          (should (= now (funcall get :last-message)))
          ;; The record keeps it.
          (let ((written now))
            (harness-session-flush)
            (clrhash harness-sessions)
            (harness-session--load-all)
            (should (= written (funcall get :last-message))))
          ;; A record written before sessions kept it has none.
          (let ((name (harness-session--meta-name id)))
            (harness-call 'store/save name (harness-plist-remove (harness-call 'store/load name) :last-message)))
          (clrhash harness-sessions)
          (harness-session--load-all)
          (should (equal "Renamed" (funcall get :name)))
          (should-not (funcall get :last-message)))))))

(ert-deftest harness-session-append-leaves-the-session-as-it-was-when-the-log-cannot-be-written ()
  "A node that cannot be written to the node log never becomes the head.
Kept in memory only, it would parent the nodes appended after it; a
reload would find that parent missing in the log, cutting the
transcript there (see `harness-session--persist-node',
`session/append').  The failing append signals, and nothing it did not
finish shows up: not the head, not the node, not a stray row for a
tool call with no result to answer it."
  (harness-session-test-with
    (let* ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
           (first (harness-call 'session/append id '(:kind user :content "q1")))
           (head-before (plist-get (harness-call 'session/get id) :head)))
      (should (equal (plist-get first :id) head-before))
      (cl-letf (((symbol-function 'harness-method/store/append)
                 (lambda (&rest _) (error "disk full"))))
        (should-error (harness-call 'session/append id '(:kind user :content "q2"))))
      (should (equal head-before (plist-get (harness-call 'session/get id) :head)))
      (should (= 1 (length (harness-call 'session/nodes id))))
      ;; Not even after a reload: it was never on disk to load back.
      (harness-session-flush)
      (clrhash harness-sessions)
      (harness-session--load-all)
      (should (= 1 (length (harness-call 'session/nodes id))))
      (should (equal head-before (plist-get (harness-call 'session/get id) :head))))))

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
           ;; Made before the last five slots: provider-node, move, ext,
           ;; last-message and steering.
           (old (apply #'record (cl-loop for i below (- (length s) 5) collect (aref s i)))))
      (puthash id old harness-sessions)
      (should-error (harness-session-provider-node old))
      (should-error (harness-session-move old))
      (should-error (harness-session-ext old))
      (should-error (harness-session-last-message old))
      (should-error (harness-session-steering old))
      (harness-session--upgrade-records)
      (let ((new (gethash id harness-sessions)))
        (should (= (length s) (length new)))
        (should (equal "old" (harness-session-name new)))
        (should-not (harness-session-provider-node new))
        (should-not (harness-session-move new))
        (should-not (harness-session-ext new))
        (should-not (harness-session-last-message new))
        (should-not (harness-session-steering new))
        (should (equal "old" (plist-get (harness-call 'session/get id) :name)))
        ;; The slots are there to use.
        (harness-call 'session/set-ext id :supervisor t)
        (should (equal '(:supervisor t) (harness-session-ext (gethash id harness-sessions))))
        (harness-call 'session/append id '(:kind user :content "hi" :ts 5.0))
        (should (= 5.0 (harness-session-last-message (gethash id harness-sessions))))))))

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

(ert-deftest harness-session-queue-take-some-items ()
  "Taking some queued items leaves the others queued, and says what is left.
The items come in queue order, whatever order the ids are given in, as a
list or a vector; an id with no item is skipped.  The session is
announced changed only when something was taken."
  (harness-session-test-with
    (let* ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
           (qid (lambda (text) (plist-get (harness-call 'session/queue id text) :id)))
           (a (funcall qid "first"))
           (b (funcall qid "second"))
           (c (funcall qid "third"))
           (d (funcall qid "fourth"))
           (left nil)
           (changed 0)
           (texts (lambda (items) (mapcar (lambda (it) (plist-get it :text)) items))))
      (harness-on 'session/queue-changed (lambda (_ items) (push (funcall texts items) left)))
      (harness-on 'session/changed (lambda (&rest _) (cl-incf changed)))
      (should (equal '("first" "third") (funcall texts (harness-call 'session/queue-take id (list c "nope" a)))))
      (should (equal '(("second" "fourth")) left))
      (should (= 1 changed))
      (should (equal '("second" "fourth") (funcall texts (plist-get (harness-call 'session/get id) :queue))))
      (should (equal (list b d) (mapcar (lambda (it) (plist-get it :id))
                                        (plist-get (harness-call 'session/get id) :queue))))
      ;; A vector of ids, as JSON may give them.
      (should (equal '("fourth") (funcall texts (harness-call 'session/queue-take id (vector d)))))
      (should (equal '(("second") ("second" "fourth")) left))
      ;; Nothing taken: no news, and the others stay.
      (setq left nil changed 0)
      (should (null (harness-call 'session/queue-take id (list "nope" a))))
      (should (null left))
      (should (= 0 changed))
      (should (equal '("second") (funcall texts (plist-get (harness-call 'session/get id) :queue))))
      ;; Without ids, everything goes.
      (should (equal '("second") (funcall texts (harness-call 'session/queue-take id))))
      (should (null (plist-get (harness-call 'session/get id) :queue)))
      (should (null (harness-call 'session/queue-take id))))))

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

(ert-deftest harness-session-usage-note-adds-the-streamed-totals ()
  "`session/usage-note' adds the two streamed totals and nothing else, in a
new plist each time.  Usage records keep them as they find them, a restart
keeps them, and a session that is gone is left alone."
  (harness-session-test-with
    (let* ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
           (usage (lambda () (plist-get (harness-call 'session/get id) :usage)))
           (announced 0))
      (harness-on 'session/changed (lambda (sid _) (when (equal sid id) (cl-incf announced))))
      (should-not (plist-member (funcall usage) :stream-output))
      (let* ((before (funcall usage))
             (totals (harness-call 'session/usage-note id
                                   '(:stream-output 100 :stream-seconds 2.5 :input 7 :cost 1.0))))
        (should (= 100 (plist-get totals :stream-output)))
        (should (= 2.5 (plist-get totals :stream-seconds)))
        ;; Anything else in the record is ignored.
        (should (= 0 (plist-get totals :input)))
        (should (= 0.0 (plist-get totals :cost)))
        ;; The totals the caller held do not change under it.
        (should-not (eq before totals))
        (should-not (plist-member before :stream-output))
        (should (equal totals (funcall usage)))
        (should (= 1 announced)))
      (harness-call 'session/usage-note id '(:stream-output 50 :stream-seconds 1.0))
      (should (= 150 (plist-get (funcall usage) :stream-output)))
      (should (= 3.5 (plist-get (funcall usage) :stream-seconds)))
      ;; Usage records, a compaction's among them, keep them.
      (harness-call 'session/usage-add id '(:input 10 :output 5 :cost 0.5 :context 100 :turns 1))
      (harness-call 'session/usage-add id '(:input 20 :output 8 :cache-read 50 :context 130))
      (harness-call 'session/usage-add id '(:input 30 :output 9 :context 40 :cache-reset t))
      (should (= 150 (plist-get (funcall usage) :stream-output)))
      (should (= 3.5 (plist-get (funcall usage) :stream-seconds)))
      (should (= 60 (plist-get (funcall usage) :input)))
      ;; A record with neither number changes nothing, announces nothing.
      (let ((seen announced))
        (should (equal (funcall usage) (harness-call 'session/usage-note id '(:input 99))))
        (should (= seen announced))
        (should (= 60 (plist-get (funcall usage) :input))))
      ;; A restart keeps them.
      (harness-session-flush)
      (clrhash harness-sessions)
      (harness-session--load-all)
      (should (= 150 (plist-get (funcall usage) :stream-output)))
      (should (= 3.5 (plist-get (funcall usage) :stream-seconds)))
      (should-not (harness-call 'session/usage-note "gone" '(:stream-output 1 :stream-seconds 1.0))))))

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

(ert-deftest harness-session-cache-time-alone-is-no-cache-use ()
  "A request's time stamps the cache only when its tokens say it used one.
A provider that cannot tell what a request did to the cache (Claude
Code through a gateway) still gives the time of the turn's last request;
the turn's tokens say whether the cache was used at all."
  (harness-session-test-with
    (let* ((harness-cache-ttl 300)
           (harness-cache-ttl-overrides nil)
           (id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
           (m (plist-get (harness-call 'session/get id) :model))
           (cache (lambda () (plist-get (harness-call 'session/get id) :cache))))
      (harness-call 'session/usage-add id '(:input 100 :output 10 :context 110
                                             :cache-at 1000.0 :cache-ttl 3600))
      (should-not (funcall cache))
      (should-not (plist-member (plist-get (harness-call 'session/get id) :usage) :cache-at))
      ;; The same turn having read the cache: the time is the request's.
      (harness-call 'session/usage-add id '(:input 100 :output 10 :cache-read 5000 :context 5110
                                             :cache-at 2000.0))
      (should (equal `(:at 2000.0 :ttl 300 :expires 2300.0 :model ,m) (funcall cache)))
      ;; A later turn that used none drops it, whatever time it names.
      (harness-call 'session/usage-add id '(:input 100 :output 10 :context 5110 :cache-at 3000.0))
      (should-not (funcall cache)))))

(ert-deftest harness-session-cache-stamp-follows-a-turn-request-by-request ()
  "A hosted loop says each request it makes, and the session's cache moves with it.
Its usage comes only when the turn is over, so until then the cache
would read as of the turn before, lapsed or about to, while the turn
reads it with every request.  A request moves the stamp on, the
lifetime its provider says goes with it, and the model it went to is
the cache's; nothing else of the usage changes."
  (harness-session-test-with
    (let* ((harness-cache-ttl 300)
           (harness-cache-ttl-overrides nil)
           (id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
           (m (plist-get (harness-call 'session/get id) :model))
           (cache (lambda () (plist-get (harness-call 'session/get id) :cache)))
           (changed nil))
      (harness-on 'session/changed (lambda (sid _s) (push sid changed)))
      (harness-call 'session/usage-add id '(:input 10 :output 10 :cache-read 900 :context 920
                                             :cache-at 1000.0 :cache-ttl 3600))
      (let ((before (copy-sequence (plist-get (harness-call 'session/get id) :usage))))
        (setq changed nil)
        ;; A request of the next turn, read from the cache.
        (should (equal `(:at 5000.0 :ttl 3600 :expires 8600.0 :model ,m)
                       (harness-call 'session/cache-stamp id '(:at 5000.0 :used t))))
        (should (equal `(:at 5000.0 :ttl 3600 :expires 8600.0 :model ,m) (funcall cache)))
        (should (equal (list id) changed))
        ;; Nothing else of what the session used moved.
        (let ((after (plist-get (harness-call 'session/get id) :usage)))
          (dolist (key '(:input :output :cache-read :cost :context :turns))
            (should (equal (plist-get before key) (plist-get after key)))))
        ;; The lifetime the request says is the cache's; one it does not say stays.
        (harness-call 'session/cache-stamp id '(:at 5100.0 :ttl 300 :used t))
        (should (equal `(:at 5100.0 :ttl 300 :expires 5400.0 :model ,m) (funcall cache)))
        (harness-call 'session/cache-stamp id '(:at 5200.0 :used t))
        (should (equal `(:at 5200.0 :ttl 300 :expires 5500.0 :model ,m) (funcall cache)))
        ;; A request that says nothing of the cache moves a cache that exists.
        (harness-call 'session/cache-stamp id '(:at 5300.0))
        (should (= 5300.0 (plist-get (funcall cache) :at)))
        ;; It is kept with the session.
        (harness-session-flush)
        (clrhash harness-sessions)
        (harness-session--load-all)
        (should (= 5300.0 (plist-get (funcall cache) :at)))))))

(ert-deftest harness-session-cache-stamp-never-takes-the-stamp-back ()
  "A request older than the stamp changes nothing: the later request is the cache's."
  (harness-session-test-with
    (let* ((harness-cache-ttl 300)
           (harness-cache-ttl-overrides nil)
           (id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
           (m (plist-get (harness-call 'session/get id) :model))
           (changed nil))
      (harness-call 'session/usage-add id '(:input 10 :output 10 :cache-read 900 :context 920
                                             :cache-at 2000.0))
      (harness-on 'session/changed (lambda (sid _s) (push sid changed)))
      (dolist (at '(2000.0 1500.0))
        (harness-call 'session/cache-stamp id (list :at at :ttl 3600 :used t))
        (should (equal `(:at 2000.0 :ttl 300 :expires 2300.0 :model ,m)
                       (plist-get (harness-call 'session/get id) :cache))))
      (should-not changed))))

(ert-deftest harness-session-cache-stamp-makes-no-cache-of-its-own ()
  "A request that did not use the cache stamps one only where one exists.
A session that never had a cache, or none left, is not made to look
warm by a request whose usage says it read and wrote nothing; one whose
usage says it did starts one, and a session without a context has none
to report whatever the stamp says."
  (harness-session-test-with
    (let* ((harness-cache-ttl 300)
           (harness-cache-ttl-overrides nil)
           (id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
           (m (plist-get (harness-call 'session/get id) :model))
           (cache (lambda () (plist-get (harness-call 'session/get id) :cache)))
           (stamp (lambda () (plist-get (plist-get (harness-call 'session/get id) :usage) :cache-at))))
      (harness-call 'session/usage-add id '(:input 100 :output 10 :context 110))
      (should-not (harness-call 'session/cache-stamp id '(:at 1000.0)))
      (should-not (funcall stamp))
      (should-not (funcall cache))
      ;; One that used it starts a cache, the first request's.
      (harness-call 'session/cache-stamp id '(:at 2000.0 :used t))
      (should (equal `(:at 2000.0 :ttl 300 :expires 2300.0 :model ,m) (funcall cache)))
      ;; No context, no cache to report.
      (let ((empty (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id)))
        (harness-call 'session/cache-stamp empty '(:at 2000.0 :used t))
        (should (plist-get (plist-get (harness-call 'session/get empty) :usage) :cache-at))
        (should-not (plist-get (harness-call 'session/get empty) :cache)))
      ;; A model the request names is the cache's.
      (harness-call 'session/cache-stamp id '(:at 3000.0 :used t :model "other:model"))
      (should (equal "other:model" (plist-get (funcall cache) :model)))
      ;; A session that is gone says so, as the usage does.
      (should-error (harness-call 'session/cache-stamp "nonesuch" '(:at 1.0 :used t))))))

(ert-deftest harness-session-cache-stamp-is-a-new-cache ()
  "A request that stamps is a new cache: what a redaction or a compaction marked is cleared.
A cache a redaction dropped is gone from the drop on; the request that
follows writes a new one.  A compaction that remembers the cache it
replaced (`:cache-pending') stamps the first request that follows
whether or not it says it used the cache."
  (harness-session-test-with-loop
    (let* ((harness-cache-ttl 300)
           (harness-cache-ttl-overrides nil)
           (m "test-loop:l")
           (id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model m) :id))
           (cache (lambda () (plist-get (harness-call 'session/get id) :cache)))
           (usage (lambda () (plist-get (harness-call 'session/get id) :usage))))
      (harness-call 'session/usage-add id '(:input 10 :output 10 :cache-read 900 :context 920
                                             :cache-at 1000.0))
      ;; Dropped by a redaction's reset of the provider conversation.
      (cl-letf (((symbol-function 'float-time) (lambda (&optional _) 1100.0)))
        (harness-call 'session/reset-provider id))
      (should (equal 1100.0 (plist-get (funcall cache) :dropped)))
      (harness-call 'session/cache-stamp id '(:at 2000.0 :used t))
      (should-not (plist-member (funcall usage) :cache-dropped))
      (should (equal `(:at 2000.0 :ttl 300 :expires 2300.0 :model ,m) (funcall cache)))
      ;; Compacted: the next request is the new cache, used or not.
      (harness-call 'session/usage-add id '(:input 900 :output 200 :cache-read 900 :context 200
                                             :cache-reset t))
      (should-not (funcall cache))
      (should (plist-get (funcall usage) :cache-pending))
      (harness-call 'session/cache-stamp id '(:at 3000.0))
      (should (equal `(:at 3000.0 :ttl 300 :expires 3300.0 :model ,m) (funcall cache)))
      (should-not (plist-member (funcall usage) :cache-pending)))))

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

(ert-deftest harness-session-cache-restamps-on-the-first-request-after-a-reset ()
  "A compaction of a conversation that had a cache remembers it.
The first request that follows stamps the new cache even when the
provider reports no cache tokens for it, as an OpenAI-compatible
provider's first request after the conversation starts over does; the
pending marker survives a restart.  A conversation that never had a
cache is not made to look warm."
  (harness-session-test-with
    (let* ((harness-cache-ttl 300)
           (harness-cache-ttl-overrides nil)
           (id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
           (model (plist-get (harness-call 'session/get id) :model))
           (cache (lambda () (plist-get (harness-call 'session/get id) :cache))))
      (harness-call 'session/usage-add id '(:input 10 :output 10 :cache-read 900 :context 920
                                             :cache-at 1000.0))
      (should (funcall cache))
      ;; The compaction clears the stamp and remembers that one existed.
      (harness-call 'session/usage-add id '(:input 900 :output 200 :cache-read 900 :context 200
                                             :cache-reset t))
      (should-not (funcall cache))
      (should (plist-get (plist-get (harness-call 'session/get id) :usage) :cache-pending))
      ;; The first request after it is a miss, with no cache tokens: it
      ;; stamps the new cache with the model's default lifetime.
      (cl-letf (((symbol-function 'float-time) (lambda (&optional _) 5000.0)))
        (harness-call 'session/usage-add id '(:input 200 :output 10 :context 210)))
      (let ((c (funcall cache)))
        (should (= 5000.0 (plist-get c :at)))
        (should (= 300 (plist-get c :ttl)))
        (should (= 5300.0 (plist-get c :expires)))
        (should (equal model (plist-get c :model))))
      (should-not (plist-get (plist-get (harness-call 'session/get id) :usage) :cache-pending))
      ;; The marker survives a restart, and the next request after it stamps.
      (harness-call 'session/usage-add id '(:input 10 :output 10 :cache-read 900 :context 920
                                             :cache-at 6000.0))
      (harness-call 'session/usage-add id '(:input 100 :output 10 :context 110 :cache-reset t))
      (harness-session-flush)
      (clrhash harness-sessions)
      (harness-session--load-all)
      (should (plist-get (plist-get (harness-call 'session/get id) :usage) :cache-pending))
      (cl-letf (((symbol-function 'float-time) (lambda (&optional _) 7000.0)))
        (harness-call 'session/usage-add id '(:input 200 :output 10 :context 210)))
      (should (= 7000.0 (plist-get (funcall cache) :at)))
      (should-not (plist-get (plist-get (harness-call 'session/get id) :usage) :cache-pending))
      ;; A conversation that never had a cache is not made to look warm.
      (let ((fresh (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id)))
        (harness-call 'session/usage-add fresh '(:input 10 :output 10 :context 20 :cache-reset t))
        (should-not (plist-get (plist-get (harness-call 'session/get fresh) :usage) :cache-pending))
        (harness-call 'session/usage-add fresh '(:input 100 :output 10 :context 110))
        (should-not (plist-get (harness-call 'session/get fresh) :cache))))))

(ert-deftest harness-session-restamp-names-the-model-that-made-the-request ()
  "The first request after a compaction stamps its own time and model.
A brief compaction is summarised by another, cheaper model, and its
record, which names that model, drops the stamp rather than set it: a
cache the summariser's request wrote is no cache of the session's
conversation.  The request that follows, on the session's model, stamps
the new one, as of when it was made, and a counted turn or a repeated
record of the compaction in between changes nothing."
  (harness-session-test-with-loop
    (let* ((harness-cache-ttl 300)
           (harness-cache-ttl-overrides nil)
           (id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "test-api:a") :id))
           (cache (lambda () (plist-get (harness-call 'session/get id) :cache))))
      (harness-call 'session/usage-add id '(:input 10 :output 10 :cache-read 900 :context 920
                                             :cache-at 1000.0 :model "test-api:a"))
      (should (equal '(:at 1000.0 :ttl 300 :expires 1300.0 :model "test-api:a") (funcall cache)))
      ;; The summariser's tokens count, its cache is not the session's.
      (harness-call 'session/usage-add id '(:input 900 :output 200 :cache-read 900 :cache-write 900
                                             :context 200 :cache-at 1500.0 :cache-reset t
                                             :model "test-api:b"))
      (should-not (funcall cache))
      (harness-call 'session/usage-add id '(:turns 1))
      (should-not (funcall cache))
      ;; The first request after it wrote the new conversation's cache.
      (harness-call 'session/usage-add id '(:input 200 :output 10 :cache-write 200 :context 210
                                             :cache-at 2000.0 :model "test-api:a"))
      (should (equal '(:at 2000.0 :ttl 300 :expires 2300.0 :model "test-api:a") (funcall cache)))
      (should-not (plist-get (plist-get (harness-call 'session/get id) :usage) :cache-pending))
      (harness-call 'session/usage-add id '(:turns 1))
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

(ert-deftest harness-session-messages-hold-the-results-before-a-message-recorded-between-them ()
  "A steering message the turn recorded between the results of a batch follows them all.
A hosted loop gets it with the first result, so it is a node between
the results; a request holds every result first, and the words after
them, in the order the messages were recorded."
  (harness-session-test-with
    (let* ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
           (add (lambda (node) (plist-get (harness-call 'session/append id node) :id)))
           (types (lambda (msg) (mapcar (lambda (b) (plist-get b :type)) (plist-get msg :content)))))
      (funcall add '(:kind user :content "go"))
      (funcall add '(:kind tool-call :tool "t" :call-id "c1" :input (:n 1)))
      (funcall add '(:kind tool-call :tool "t" :call-id "c2" :input (:n 2)))
      (funcall add '(:kind tool-call :tool "t" :call-id "c3" :input (:n 3)))
      (funcall add '(:kind tool-result :call-id "c1" :output "A"))
      (funcall add '(:kind user :content "steer one" :meta (:steering t)))
      (funcall add '(:kind user :content "steer two" :meta (:steering t)))
      (funcall add '(:kind tool-result :call-id "c2" :output "B"))
      (funcall add '(:kind tool-result :call-id "c3" :output "C"))
      (funcall add '(:kind assistant :content "Done."))
      (let ((msgs (harness-call 'session/messages id)))
        (should-not (harness-session-test-unpaired msgs))
        (should (equal '(user assistant user assistant) (mapcar (lambda (m) (plist-get m :role)) msgs)))
        (should (equal '("tool_result" "tool_result" "tool_result" "text" "text") (funcall types (nth 2 msgs))))
        (should (equal '("A" "B" "C" "steer one" "steer two")
                       (mapcar (lambda (b) (or (plist-get b :content) (plist-get b :text)))
                               (plist-get (nth 2 msgs) :content)))))
      ;; Recorded after the last result, or where no result follows, nothing moves.
      (funcall add '(:kind user :content "steer three" :meta (:steering t)))
      (funcall add '(:kind user :content "plain" :meta (:steering nil)))
      (let ((msgs (harness-call 'session/messages id)))
        (should (equal '("steer three" "plain")
                       (mapcar (lambda (b) (plist-get b :text)) (plist-get (car (last msgs)) :content))))))))

(ert-deftest harness-session-steering-is-listed-and-announced-when-it-changes ()
  "The messages a running turn has not taken are the session's `:steering'.
`session/set-steering' replaces the list, `session/steering-changed' says
so, and a list that is the one the session has already says nothing."
  (harness-session-test-with
    (let* ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
           (seen nil)
           (item '(:id "n-1" :text "change of plan" :ts 100.0)))
      (harness-on 'session/steering-changed (lambda (sid items) (push (cons sid items) seen)))
      (should-not (plist-get (harness-call 'session/get id) :steering))
      (should (equal (list item) (harness-call 'session/set-steering id (list item))))
      (should (equal (list item) (plist-get (harness-call 'session/get id) :steering)))
      ;; The same list changes nothing and tells nobody.
      (harness-call 'session/set-steering id (list (copy-sequence item)))
      (should (equal (list (cons id (list item))) seen))
      (harness-call 'session/set-steering id nil)
      (should-not (plist-get (harness-call 'session/get id) :steering))
      (should (equal (list (list id) (cons id (list item))) seen))
      (should-error (harness-call 'session/set-steering "nope" nil) :type 'harness-error))))

(ert-deftest harness-session-load-queues-again-the-messages-a-turn-never-took ()
  "A harness that stops while a turn has messages waiting gives them back in the queue.
The turn ended with the process, and no other will take them; the
record kept them, and the next start queues them again (only their text
survives), to be sent when the user is ready.  A message that is a node
already -- recorded before the harness stopped, the record written too
late -- is not sent twice, and a session loaded by a reload keeps what
its turn holds."
  (harness-session-test-with
    (let* ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
           (other (harness-sender-session '(:id "s-other" :name "Other"))))
      (harness-call 'session/append id '(:kind user :content "go"))
      (harness-call 'session/append id '(:kind user :id "n-done" :content "already here" :meta (:steering t)))
      (harness-call 'session/set-steering
                    id (list (list :id "n-1" :text "change of plan" :ts 100.0)
                             (list :id "n-done" :text "already here" :ts 101.0)
                             (list :id "n-2" :text "from elsewhere" :ts 102.0 :from other)))
      (harness-session-flush)
      ;; A reload does not touch a session that is loaded.
      (harness-session--load-all)
      (should (= 3 (length (plist-get (harness-call 'session/get id) :steering))))
      (should-not (plist-get (harness-call 'session/get id) :queue))
      ;; A start does.
      (clrhash harness-sessions)
      (harness-session--load-all)
      (let ((session (harness-call 'session/get id)))
        (should-not (plist-get session :steering))
        (should (equal '("change of plan" "from elsewhere") (mapcar (lambda (it) (plist-get it :text))
                                                                    (plist-get session :queue))))
        ;; Who sent it survives the record, a symbol read back from a string.
        (should (eq 'session (harness-sender-kind (plist-get (cadr (plist-get session :queue)) :from))))
        (should (equal "s-other" (plist-get (plist-get (cadr (plist-get session :queue)) :from) :id))))
      ;; Saved so too.
      (harness-session-flush)
      (clrhash harness-sessions)
      (harness-session--load-all)
      (should-not (plist-get (harness-call 'session/get id) :steering))
      (should (= 2 (length (plist-get (harness-call 'session/get id) :queue)))))))

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

;;;; Settings that modules keep for a session (ext)

(defconst harness-session-test--ext
  '(:supervisor t :off :false :tier "cheap" :budget 12 :ratio 0.5
    :tiers (:fast "demo:fast" :deep "demo:deep") :models ("a" "b"))
  "An ext plist with every kind of value the JSON store of a record keeps.")

(defun harness-session-test--ext-of (id)
  "Return the ext plist of session ID."
  (plist-get (harness-call 'session/get id) :ext))

(ert-deftest harness-session-ext-sets-and-gets ()
  "A setting is set to a value, an explicit off is a value, and nil removes it."
  (harness-session-test-with
    (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id)))
      (should-not (harness-session-test--ext-of id))
      ;; The session plist comes back, with the setting in it.
      (should (equal '(:supervisor t) (plist-get (harness-call 'session/set-ext id :supervisor t) :ext)))
      (should (equal id (plist-get (harness-call 'session/set-ext id :tier "cheap") :id)))
      (should (equal '(:supervisor t :tier "cheap") (harness-session-test--ext-of id)))
      (let ((before (harness-session-test--ext-of id)))
        ;; An explicit off is stored as it is, in its place.
        (harness-call 'session/set-ext id :supervisor :false)
        (should (equal '(:supervisor :false :tier "cheap") (harness-session-test--ext-of id)))
        ;; Whoever held the plist before keeps what it saw.
        (should (equal '(:supervisor t :tier "cheap") before)))
      ;; nil removes the setting; one removed twice, or never set, is no error.
      (harness-call 'session/set-ext id :supervisor nil)
      (should (equal '(:tier "cheap") (harness-session-test--ext-of id)))
      (harness-call 'session/set-ext id :supervisor nil)
      (harness-call 'session/set-ext id :nothing nil)
      (should (equal '(:tier "cheap") (harness-session-test--ext-of id)))
      (harness-call 'session/set-ext id :tier nil)
      (should-not (harness-session-test--ext-of id))
      ;; Every kind of value.
      (cl-loop for (k v) on harness-session-test--ext by #'cddr
               do (harness-call 'session/set-ext id k v))
      (should (equal harness-session-test--ext (harness-session-test--ext-of id)))
      (should-error (harness-call 'session/set-ext "no-such-session" :supervisor t)))))

(ert-deftest harness-session-ext-key-may-be-a-name ()
  "A client on the wire names a setting with a string, with or without the colon."
  (harness-session-test-with
    (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id)))
      (dolist (key (list :a 'b "c" ":d"))
        (harness-call 'session/set-ext id key t))
      (should (equal '(:a t :b t :c t :d t) (harness-session-test--ext-of id)))
      (harness-call 'session/set-ext id "a" nil)
      (harness-call 'session/set-ext id ":b" :false)
      (should (equal '(:b :false :c t :d t) (harness-session-test--ext-of id)))
      (dolist (key (list nil t "" 7))
        (should-error (harness-call 'session/set-ext id key t) :type 'harness-error))
      (should (equal '(:b :false :c t :d t) (harness-session-test--ext-of id))))))

(ert-deftest harness-session-ext-survives-the-store ()
  "The settings are stored with the record and read back as they were."
  (harness-session-test-with
    (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id)))
      (cl-loop for (k v) on harness-session-test--ext by #'cddr
               do (harness-call 'session/set-ext id k v))
      ;; The record, as JSON writes it and `harness-session--from-plist' reads it.
      (let* ((record (harness-session-plist (gethash id harness-sessions)))
             (stored (harness-json-parse (harness-json-encode record))))
        (should (equal harness-session-test--ext (harness-session-ext (harness-session--from-plist stored)))))
      ;; And from the store itself, after the harness exited and started again.
      (harness-session-flush)
      (clrhash harness-sessions)
      (harness-session--load-all)
      (should (equal harness-session-test--ext (harness-session-test--ext-of id)))
      ;; A setting that was removed is gone for good.
      (harness-call 'session/set-ext id :supervisor nil)
      (harness-session-flush)
      (clrhash harness-sessions)
      (harness-session--load-all)
      (should-not (plist-member (harness-session-test--ext-of id) :supervisor))
      (should (eq :false (plist-get (harness-session-test--ext-of id) :off))))))

(ert-deftest harness-session-ext-reads-only-a-plist ()
  "A stored value that is no plist reads as no settings, and a key set to null as none."
  (harness-session-test-with
    (dolist (junk (list "junk" 7 t :false '("a" "b") '(:a) '(1 2)))
      (should-not (harness-session-ext (harness-session--from-plist (list :id "x" :cwd "/tmp/" :ext junk)))))
    (should-not (harness-session-ext (harness-session--from-plist (list :id "x" :cwd "/tmp/"))))
    (should (equal '(:a 1) (harness-session-ext
                            (harness-session--from-plist (list :id "x" :cwd "/tmp/" :ext '(:a 1 :b nil))))))))

(ert-deftest harness-session-create-takes-initial-ext ()
  "`session/create' accepts the settings a session starts with."
  (harness-session-test-with
    (let* ((cwd (harness-test-temp-dir))
           (s (harness-call 'session/create :cwd cwd :ext '(:supervisor t :off :false :unset nil))))
      (should (equal '(:supervisor t :off :false) (plist-get s :ext)))
      (should (equal '(:supervisor t :off :false) (harness-session-test--ext-of (plist-get s :id))))
      (should-not (plist-get (harness-call 'session/create :cwd cwd) :ext))
      (should-not (plist-get (harness-call 'session/create :cwd cwd :ext "junk") :ext)))))

(ert-deftest harness-session-fork-does-not-copy-ext ()
  "A fork, a sub-agent and a BTW start without their parent's settings.
A module that wants its fork to have some gives them when it forks."
  (harness-session-test-with
    (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                       :ext '(:supervisor t :tier "cheap"))
                         :id)))
      (dolist (kind '(fork subagent))
        (let ((child (harness-await (harness-call 'session/fork id :kind kind))))
          (should-not (plist-get child :ext))
          (should-not (harness-session-test--ext-of (plist-get child :id)))))
      (should-not (plist-get (harness-call 'session/btw id) :ext))
      (let ((child (harness-await (harness-call 'session/fork id :kind 'fork :ext '(:supervisor :false)))))
        (should (equal '(:supervisor :false) (plist-get child :ext))))
      (should (equal '(:supervisor t :tier "cheap") (harness-session-test--ext-of id))))))

(ert-deftest harness-session-ext-change-is-announced ()
  "A change emits `session/ext-changed' once the session holds it, and `session/changed' too."
  (harness-session-test-with
    (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
          (events nil)
          (changed nil))
      (harness-on 'session/ext-changed
                  (lambda (sid key value)
                    (push (list sid key value (plist-get (harness-session-test--ext-of sid) key)) events)))
      (harness-on 'session/changed (lambda (_sid session) (push (plist-get session :ext) changed)))
      (harness-call 'session/set-ext id :supervisor t)
      (harness-call 'session/set-ext id "tier" "cheap")
      (harness-call 'session/set-ext id :supervisor nil)
      ;; The key is the keyword, the value what was asked, and the session
      ;; already held it when the event came.
      (should (equal (list (list id :supervisor t t) (list id :tier "cheap" "cheap") (list id :supervisor nil nil))
                     (reverse events)))
      (should (equal '((:supervisor t) (:supervisor t :tier "cheap") (:tier "cheap"))
                     (reverse changed))))))

(ert-deftest harness-session-ext-hint-is-added ()
  "A hint that is a string lands in the transcript as a hint, any other does not."
  (harness-session-test-with
    (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id)))
      (harness-call 'session/set-ext id :supervisor t "Supervisor mode on")
      (let ((node (car (last (harness-call 'session/nodes id)))))
        (should (eq 'hint (plist-get node :kind)))
        (should (equal "Supervisor mode on" (plist-get node :content))))
      (harness-call 'session/set-ext id :supervisor :false)
      (harness-call 'session/set-ext id :tier "x" nil)
      (harness-call 'session/set-ext id :tier "y" 5)
      (should (equal '(hint) (harness-session-test-kinds id)))
      (should (equal '(:supervisor :false :tier "y") (harness-session-test--ext-of id))))))

(ert-deftest harness-session-ext-warns-of-a-value-the-store-would-change ()
  "A value JSON does not keep as it is (a symbol, say) is kept, and logged."
  (harness-session-test-with
    (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id)))
      (harness-call 'session/set-ext id :mode 'auto)
      (should (eq 'auto (plist-get (harness-session-test--ext-of id) :mode)))
      (with-current-buffer (get-buffer-create harness-log-buffer-name)
        (should (string-match-p "ext :mode would not survive the JSON store" (buffer-string))))
      (should (harness-session--ext-json-p harness-session-test--ext))
      (dolist (bad (list 'auto [1 2] (lambda () 1) '(:a auto) '("a" auto) '(:a 1 :b)))
        (should-not (harness-session--ext-json-p bad))))))

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

(ert-deftest harness-session-context-limit-source-names-the-cap ()
  "The limit's source names the setting that made it, best effort: a
sub-agent's kind says the sub-agent cap, the tasks module's own cap
value says a task's, and another limit is one set for the session.  No
limit, no source."
  (harness-session-test-with
    (unwind-protect
        (progn
          (harness-session-test-provider '(("big" . 1000000)))
          (let ((plain (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                                :model "test-win:big") :id))
                (sub (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                              :model "test-win:big" :kind 'subagent
                                              :context-window-limit 96000) :id))
                (other (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                                :model "test-win:big"
                                                :context-window-limit 200000) :id)))
            (should-not (harness-session-context-limit-source (harness-call 'session/get plain)))
            (should (equal "a sub-agent cap (harness-subagent-context-limit)"
                           (harness-session-context-limit-source (harness-call 'session/get sub))))
            (should (equal "set for this session"
                           (harness-session-context-limit-source (harness-call 'session/get other))))
            ;; A limit equal to the tasks module's own cap is a task's.
            (let ((harness-tasks-context-limit 200000))
              (should (equal "a task cap (harness-tasks-context-limit)"
                             (harness-session-context-limit-source
                              (harness-call 'session/get other)))))))
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

(defun harness-session-test--start-again ()
  "Start the session module as a new harness does: it reads the saved sessions.
A module that is ready initialises again instead, as a reload has it,
and reads none."
  (setf (harness-module-state (harness-module-get 'session)) 'registered)
  (should (harness-module-start 'session)))

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
      (harness-session-test--start-again)
      (dolist (id (cons fresh old))
        (should-not (plist-get (harness-call 'session/get id) :budget))
        (should-not (plist-get (harness-call 'store/load (format "sessions/%s.json" id)) :budget)))
      (should (= 2 (plist-get (harness-call 'store/load harness-session--budget-copies-marker) :dropped)))
      ;; Once only: a budget given to a session from now on stays.
      (harness-call 'session/update (car old) :budget '(:amount 2.0) :silent t)
      (harness-session-flush)
      (clrhash harness-sessions)
      (harness-session-test--start-again)
      (should (equal '(:amount 2.0) (plist-get (harness-call 'session/get (car old)) :budget)))
      ;; Loaded over the old version in a running harness, this one drops
      ;; the copies the loaded sessions hold, as the reload initialises
      ;; the module again.
      (harness-call 'store/delete harness-session--budget-copies-marker)
      (harness-test-load-module 'session)
      (should-not (plist-get (harness-call 'session/get (car old)) :budget))
      (should (harness-call 'store/load harness-session--budget-copies-marker)))))

(ert-deftest harness-session-reload-reads-no-session ()
  "A reload initialises the module again, but reads no saved session.
The sessions are in memory already; reading them would settle the turns
found running and make the moves waiting for them, while those turns
run on.  A start reads them."
  (harness-session-test-with
    (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id)))
      (harness-session-flush)
      (clrhash harness-sessions)
      (should (harness-module-ready-p 'session))
      (harness-test-load-module 'session)
      (should (harness-module-ready-p 'session))
      (should-not (gethash id harness-sessions))
      (harness-session-test--start-again)
      (should (gethash id harness-sessions)))))

;;;; The thinking level of a BTW

(defvar harness-thinking)
(defvar harness-btw-thinking)

(defmacro harness-session-test-with-thinker (&rest body)
  "Run BODY in `harness-session-test-with' with provider `test-think' defined.
Its model thinker has the thinking levels low, medium and high; its
model plain has none.  Its model deep has low, high and max, as
DeepSeek's do (no medium), and its model steep only high and max.  The
provider names no cheap tier and prices no model, so a BTW over any of
them stays on it."
  (declare (indent 0))
  `(harness-session-test-with
     (unwind-protect
         (progn
           (harness-define-provider 'test-think
             :complete #'ignore
             :models (lambda ()
                       (harness-resolved (list (list :name "thinker" :thinking-levels '("low" "medium" "high"))
                                               (list :name "deep" :thinking-levels '("low" "high" "max"))
                                               (list :name "steep" :thinking-levels '("high" "max"))
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
keeps its own.  A model the catalogue lists the level for gets it; one
that lacks it gets the nearest level it lists below it, never the
parent's.  A model the catalogue lists no levels for keeps the parent's
level, as nil does.  The setting layers: a .dir-locals.el sets it for
its directory.  The BTW can be changed afterwards like any session."
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
      ;; Another level, when the model offers it; else the strongest it
      ;; offers below it: here the top level, whatever the parent's.
      (let ((harness-btw-thinking "medium"))
        (should (equal "medium" (harness-session-test-btw-level high))))
      (let ((harness-btw-thinking "max"))
        (should (equal "high" (harness-session-test-btw-level high)))
        (should (equal "high" (harness-session-test-btw-level default))))
      ;; nil: the parent's level, as before BTWs had one of their own.
      (let ((harness-btw-thinking nil))
        (should (equal "high" (harness-session-test-btw-level high)))
        (should-not (harness-session-test-btw-level default)))
      ;; A model without levels: nothing to fit to, so the parent's level
      ;; stays, the setting asking for another or not.
      (dolist (setting '("low" "max" nil))
        (let ((harness-btw-thinking setting))
          (should (equal "high" (harness-session-test-btw-level plain)))))
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
the BTW level fitted to the levels its model offers, else at
`harness-thinking' (no level configured, or a model that lists none).  A
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
        ;; A level its model lacks is the nearest below it, else the model's
        ;; weakest -- not `harness-thinking', which a BTW falls back on
        ;; only where nothing can be fitted (the plain model has no levels).
        (let ((harness-btw-thinking "medium")
              (harness-thinking "max"))
          (should (equal "medium" (level :kind 'btw :model "test-think:thinker")))
          (should (equal "low" (level :kind 'btw :model "test-think:deep")))
          (should (equal "high" (level :kind 'btw :model "test-think:steep")))
          (should (equal "max" (level :kind 'btw :model "test-think:plain")))
          (should (equal "max" (level :model "test-think:deep"))))
        (let ((harness-btw-thinking nil))
          (should (equal "high" (level :kind 'btw :model "test-think:thinker"))))))))

(ert-deftest harness-session-btw-thinks-lower-on-its-sessions-own-model ()
  "A BTW that stays on its session's model still thinks lower, whatever the session's level.
The provider has no cheaper tier here.  A model that lacks the level (a
DeepSeek-like one has low, high and max, no medium) gives the nearest it
has below it, never the session's own; one whose levels are all
stronger than the one asked for gives its weakest."
  (harness-session-test-with-thinker
    (let* ((harness-btw-thinking "low")
           (harness-thinking nil)
           (cwd (harness-test-temp-dir))
           (deep (plist-get (harness-call 'session/create :cwd cwd :model "test-think:deep" :thinking "max")
                            :id))
           (steep (plist-get (harness-call 'session/create :cwd cwd :model "test-think:steep" :thinking "max")
                             :id)))
      (cl-flet ((on (id) (let ((btw (harness-call 'session/btw id)))
                           (cons (plist-get btw :model) (plist-get btw :thinking)))))
        ;; The default: the model has it.
        (should (equal '("test-think:deep" . "low") (on deep)))
        ;; Medium: it has none, and gets low, not the session's max.
        (let ((harness-btw-thinking "medium"))
          (should (equal '("test-think:deep" . "low") (on deep))))
        ;; The nearest it has below, whichever level is asked for.
        (let ((harness-btw-thinking "high"))
          (should (equal '("test-think:deep" . "high") (on deep))))
        (let ((harness-btw-thinking "xhigh"))
          (should (equal '("test-think:deep" . "high") (on deep))))
        ;; Every level it has is stronger than the one asked for: its weakest.
        (should (equal '("test-think:steep" . "high") (on steep)))
        (let ((harness-btw-thinking "medium"))
          (should (equal '("test-think:steep" . "high") (on steep))))
        ;; Nothing configured: the session's own level, which its model has.
        (let ((harness-btw-thinking nil))
          (should (equal '("test-think:deep" . "max") (on deep))))
        ;; The sessions keep theirs.
        (should (equal "max" (plist-get (harness-call 'session/get deep) :thinking)))
        (should (equal "max" (plist-get (harness-call 'session/get steep) :thinking)))))))

;;;; The model of a BTW

(defvar harness-model)
(defvar harness-btw-model)
(defvar harness-allowed-models)

(defmacro harness-session-test-with-tiers (&rest body)
  "Run BODY in `harness-session-test-with-thinker' with provider `test-tier' defined too.
Its cheap tier is the model small, which offers the thinking levels
low, medium and high; its model big offers up to max.  Provider
`test-think' names no tier and prices no model."
  (declare (indent 0))
  `(harness-session-test-with-thinker
     (unwind-protect
         (progn
           (harness-define-provider 'test-tier
             :complete #'ignore
             :tiers '(:cheap "small")
             :models (lambda ()
                       (harness-resolved
                        (list (list :name "big" :thinking-levels '("low" "medium" "high" "xhigh" "max"))
                              (list :name "small" :thinking-levels '("low" "medium" "high"))))))
           ,@body)
       (remhash 'test-tier harness-providers)
       (harness-provider--forget 'test-tier))))

(defun harness-session-test-parent (model &rest plist)
  "Create a session on MODEL with PLIST in a directory of its own; return its id."
  (plist-get (apply #'harness-call 'session/create :cwd (harness-test-temp-dir) :model model plist) :id))

(defun harness-session-test-btw (parent &rest args)
  "Start a BTW over session PARENT with ARGS after its name; return the session."
  (apply #'harness-call 'session/btw parent "side" args))

(ert-deftest harness-session-btw-runs-on-the-cheap-tier ()
  "A BTW runs on the cheap tier of its model's provider, not on its session's.
Over a session on the provider's top model it is made on the cheap one,
as `session/get' says too, thinking at the BTW level; the session keeps
its model and level, and a BTW already on the cheap tier stays there."
  (harness-session-test-with-tiers
    (let* ((harness-btw-thinking "low")
           (harness-thinking nil)
           (parent (harness-session-test-parent "test-tier:big" :thinking "max"
                                                :permission-mode 'accept-edits))
           (btw (harness-session-test-btw parent)))
      (should (eq 'auto (eval (car (get 'harness-btw-model 'standard-value)) t)))
      (should (eq 'btw (plist-get btw :kind)))
      (should (equal parent (plist-get btw :parent-id)))
      (should (equal "test-tier:small" (plist-get btw :model)))
      (should (equal "test-tier:small" (plist-get (harness-call 'session/get (plist-get btw :id)) :model)))
      (should (equal "low" (plist-get btw :thinking)))
      (should (eq 'accept-edits (plist-get btw :permission-mode)))
      (let ((session (harness-call 'session/get parent)))
        (should (equal "test-tier:big" (plist-get session :model)))
        (should (equal "max" (plist-get session :thinking))))
      (let ((small (harness-session-test-parent "test-tier:small" :thinking "medium")))
        (should (equal "test-tier:small" (plist-get (harness-session-test-btw small) :model)))))))

(ert-deftest harness-session-btw-model-setting ()
  "`harness-btw-model' picks the model of a BTW: `auto' the cheap tier, a model that model, nil its session's.
It layers like the other settings: a .dir-locals.el sets it for its directory."
  (harness-session-test-with-tiers
    (let* ((harness-btw-thinking "low")
           (cwd (harness-test-temp-dir))
           (big (plist-get (harness-call 'session/create :cwd cwd :model "test-tier:big") :id))
           (think (plist-get (harness-call 'session/create :cwd cwd :model "test-think:thinker") :id)))
      (cl-flet ((model-of (id) (plist-get (harness-session-test-btw id) :model)))
        ;; The default, spelled as the symbol or as a string.
        (dolist (auto '(auto "auto"))
          (let ((harness-btw-model auto))
            (should (equal "test-tier:small" (model-of big)))))
        ;; A model: that one, whoever the session's provider is.
        (let ((harness-btw-model "test-tier:big"))
          (should (equal "test-tier:big" (model-of big)))
          (should (equal "test-tier:big" (model-of think))))
        (let ((harness-btw-model "test-tier:small"))
          (should (equal "test-tier:small" (model-of think))))
        ;; nil, or nothing: the session's own.
        (dolist (own '(nil ""))
          (let ((harness-btw-model own))
            (should (equal "test-tier:big" (model-of big)))
            (should (equal "test-think:thinker" (model-of think)))))
        ;; Configured for the directory the session works in.
        (with-temp-file (expand-file-name ".dir-locals.el" cwd)
          (insert "((nil . ((harness-btw-model . nil))))\n"))
        (should (equal "test-tier:big" (model-of big)))
        (with-temp-file (expand-file-name ".dir-locals.el" cwd)
          (insert "((nil . ((harness-btw-model . \"test-think:thinker\"))))\n"))
        (should (equal "test-think:thinker" (model-of big)))
        (with-temp-file (expand-file-name ".dir-locals.el" cwd)
          (insert "((nil . ((harness-btw-model . auto))))\n"))
        (let ((harness-btw-model nil))
          (should (equal "test-tier:small" (model-of big))))))))

(ert-deftest harness-session-btw-model-setting-must-be-allowed ()
  "A `harness-btw-model' that `harness-allowed-models' leaves out is not used.
The BTW stays on its session's model, and the log says why."
  (harness-session-test-with-tiers
    (let ((think (harness-session-test-parent "test-think:thinker"))
          (harness-btw-model "test-tier:big"))
      (should (equal "test-tier:big" (plist-get (harness-session-test-btw think) :model)))
      (harness-test-with-policy '((harness-allowed-models "test-think"))
        (should (equal "test-think:thinker" (plist-get (harness-session-test-btw think) :model)))))))

(ert-deftest harness-session-btw-model-can-be-chosen-for-one-btw ()
  "A model given to `session/btw' runs that BTW on it, over the setting and the cheap tier.
A blank one is none.  It is chosen at the start: the BTW is a session
like any from then on, whose model can be switched, and its session
keeps its own."
  (harness-session-test-with-tiers
    (let ((parent (harness-session-test-parent "test-tier:big" :thinking "max")))
      ;; Over the cheap tier.
      (should (equal "test-tier:big" (plist-get (harness-session-test-btw parent "test-tier:big") :model)))
      (should (equal "test-think:thinker"
                     (plist-get (harness-session-test-btw parent "test-think:thinker") :model)))
      ;; Over the setting.
      (let ((harness-btw-model "test-tier:small"))
        (should (equal "test-think:thinker"
                       (plist-get (harness-session-test-btw parent "test-think:thinker") :model)))
        (should (equal "test-tier:small" (plist-get (harness-session-test-btw parent) :model))))
      (let ((harness-btw-model nil))
        (should (equal "test-tier:small" (plist-get (harness-session-test-btw parent "test-tier:small") :model)))
        (should (equal "test-tier:big" (plist-get (harness-session-test-btw parent) :model))))
      ;; Blank is none.
      (dolist (blank '(nil "" "  "))
        (should (equal "test-tier:small" (plist-get (harness-session-test-btw parent blank) :model))))
      ;; Chosen once: after that the BTW switches models like any session.
      (let ((id (plist-get (harness-session-test-btw parent "test-tier:big") :id)))
        (harness-call 'session/update id :model "test-think:thinker" :silent t)
        (should (equal "test-think:thinker" (plist-get (harness-call 'session/get id) :model))))
      (should (equal "test-tier:big" (plist-get (harness-call 'session/get parent) :model))))))

(ert-deftest harness-session-btw-model-and-thinking-are-independent ()
  "The BTW level is checked against the model the BTW runs on, not its session's.
`harness-btw-thinking' lowers the effort on the cheap model as on any
other; a level that model lacks is not carried over from a session that
had it, nor is the usual one used: the BTW gets the nearest level the
model has below it."
  (harness-session-test-with-tiers
    (let* ((harness-thinking nil)
           (max (harness-session-test-parent "test-tier:big" :thinking "max"))
           (high (harness-session-test-parent "test-tier:big" :thinking "high")))
      (cl-flet ((on (id) (let ((btw (harness-session-test-btw id)))
                           (cons (plist-get btw :model) (plist-get btw :thinking)))))
        ;; The effort is low on the cheap model, whatever the session's.
        (let ((harness-btw-thinking "low"))
          (should (equal '("test-tier:small" . "low") (on max)))
          (should (equal '("test-tier:small" . "low") (on high))))
        (let ((harness-btw-thinking "medium"))
          (should (equal '("test-tier:small" . "medium") (on max))))
        ;; A level the cheap model lacks is the nearest it has below it.
        (let ((harness-btw-thinking "max"))
          (should (equal '("test-tier:small" . "high") (on max)))
          (should (equal '("test-tier:small" . "high") (on high))))
        (let ((harness-btw-thinking "xhigh")
              (harness-thinking "low"))
          (should (equal '("test-tier:small" . "high") (on max))))
        ;; The session's level, when the cheap model has it; else the usual one.
        (let ((harness-btw-thinking nil))
          (should (equal '("test-tier:small" . nil) (on max)))
          (should (equal '("test-tier:small" . "high") (on high)))
          (let ((harness-thinking "medium"))
            (should (equal '("test-tier:small" . "medium") (on max)))))
        ;; On the session's own model nothing is lost.
        (let ((harness-btw-model nil))
          (let ((harness-btw-thinking "low"))
            (should (equal '("test-tier:big" . "low") (on max))))
          (let ((harness-btw-thinking nil))
            (should (equal '("test-tier:big" . "max") (on max)))))
        ;; A model chosen for the BTW, too.
        (let ((harness-btw-thinking nil))
          (should (equal '("test-tier:big" . "max")
                         (let ((btw (harness-session-test-btw max "test-tier:big")))
                           (cons (plist-get btw :model) (plist-get btw :thinking)))))
          (should (equal '("test-tier:small" . "high")
                         (let ((btw (harness-session-test-btw high "test-tier:small")))
                           (cons (plist-get btw :model) (plist-get btw :thinking))))))))))

(ert-deftest harness-session-btw-keeps-the-model-without-a-cheap-tier ()
  "A provider that names no cheap model and prices none leaves a BTW on its session's.
So does a model whose provider nobody registered.  The level is fitted
to the levels of the model it stays on; a model the catalogue lists no
levels for has none to fit to, so its level is the session's, whatever
`harness-btw-thinking' says."
  (harness-session-test-with-tiers
    (let ((harness-btw-thinking "low")
          (think (harness-session-test-parent "test-think:thinker" :thinking "high"))
          (plain (harness-session-test-parent "test-think:plain" :thinking "high"))
          (nobody (harness-session-test-parent "nobody:model" :thinking "high")))
      (should (equal "test-think:thinker" (plist-get (harness-session-test-btw think) :model)))
      (should (equal "low" (plist-get (harness-session-test-btw think) :thinking)))
      (should (equal "test-think:plain" (plist-get (harness-session-test-btw plain) :model)))
      (should (equal "high" (plist-get (harness-session-test-btw plain) :thinking)))
      (should (equal "nobody:model" (plist-get (harness-session-test-btw nobody) :model)))
      (should (equal "high" (plist-get (harness-session-test-btw nobody) :thinking)))
      ;; Nothing configured either: the session's level, as before.
      (let ((harness-btw-thinking nil))
        (should (equal "high" (plist-get (harness-session-test-btw plain) :thinking)))
        (should (equal "high" (plist-get (harness-session-test-btw nobody) :thinking)))))))

(ert-deftest harness-session-btw-created-without-a-model ()
  "A `btw' session created without a model, as a task board's is, runs on `harness-btw-model'.
That is applied to `harness-model' as configured at its directory.  A
model it is given wins, and other kinds of session are left alone."
  (harness-session-test-with-tiers
    (let ((harness-model "test-tier:big")
          (harness-thinking "high")
          (harness-btw-thinking "low")
          (cwd (harness-test-temp-dir)))
      (cl-flet ((create (&rest plist) (apply #'harness-call 'session/create :cwd cwd plist)))
        (should (equal "test-tier:small" (plist-get (create :kind 'btw) :model)))
        (should (equal "low" (plist-get (create :kind 'btw) :thinking)))
        (should (equal "test-tier:big" (plist-get (create :kind 'btw :model "test-tier:big") :model)))
        (should (equal "test-tier:big" (plist-get (create) :model)))
        (should (equal "test-tier:big" (plist-get (create :kind 'fork) :model)))
        (let ((harness-btw-model nil))
          (should (equal "test-tier:big" (plist-get (create :kind 'btw) :model))))
        (let ((harness-btw-model "test-think:thinker"))
          (should (equal "test-think:thinker" (plist-get (create :kind 'btw) :model))))
        ;; The model the directory configures is the one the tier comes from.
        (with-temp-file (expand-file-name ".dir-locals.el" cwd)
          (insert "((nil . ((harness-model . \"test-think:thinker\"))))\n"))
        (should (equal "test-think:thinker" (plist-get (create :kind 'btw) :model)))
        (with-temp-file (expand-file-name ".dir-locals.el" cwd)
          (insert "((nil . ((harness-model . \"test-tier:big\"))))\n"))
        (should (equal "test-tier:small" (plist-get (create :kind 'btw) :model)))))))

(ert-deftest harness-session-policy-fixes-the-model-of-a-btw ()
  "A policy on `harness-model' fixes a BTW's model as every session's.
Not the cheap tier then: neither `harness-btw-model' nor a model asked
for changes it, and a model that is another is refused, creating
nothing.  The level is not fixed, so it stays the BTW level."
  (harness-session-test-with-tiers
    (harness-test-with-policy '((harness-model . "test-tier:big"))
      (let* ((harness-btw-thinking "low")
             (cwd (harness-test-temp-dir))
             (parent (plist-get (harness-call 'session/create :cwd cwd :thinking "max") :id)))
        (should (equal "test-tier:big" (plist-get (harness-call 'session/get parent) :model)))
        (should (equal "test-tier:big" (plist-get (harness-session-test-btw parent) :model)))
        (should (equal "low" (plist-get (harness-session-test-btw parent) :thinking)))
        (should (equal "test-tier:big" (plist-get (harness-call 'session/create :cwd cwd :kind 'btw) :model)))
        (should (equal "test-tier:big"
                       (plist-get (harness-call 'session/create :cwd cwd :kind 'btw :model "test-tier:small")
                                  :model)))
        (let ((harness-btw-model "test-think:thinker"))
          (should (equal "test-tier:big" (plist-get (harness-session-test-btw parent) :model))))
        ;; The policy's own model is no change.
        (should (equal "test-tier:big" (plist-get (harness-session-test-btw parent "test-tier:big") :model)))
        (let* ((sessions (length (harness-call 'session/list)))
               (err (should-error (harness-session-test-btw parent "test-tier:small"))))
          (should (string-match-p "harness-model is set by policy" (cadr err)))
          (should (= sessions (length (harness-call 'session/list)))))))))

(ert-deftest harness-session-btw-model-asked-for-must-be-allowed ()
  "A model asked for that `harness-allowed-models' leaves out is refused, creating nothing."
  (harness-session-test-with-tiers
    (let ((parent (harness-session-test-parent "test-tier:big"))
          (sessions (length (harness-call 'session/list))))
      (harness-test-with-policy '((harness-allowed-models "test-tier"))
        (should (equal "test-tier:small" (plist-get (harness-session-test-btw parent "test-tier:small") :model)))
        (let ((err (should-error (harness-session-test-btw parent "test-think:thinker"))))
          (should (string-match-p "test-think:thinker is not allowed" (cadr err))))
        (should (= (1+ sessions) (length (harness-call 'session/list))))))))

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


(ert-deftest harness-session-discards-nodes-and-keeps-the-chain-whole ()
  "Nodes dropped from the transcript leave it a chain, in memory and after a reload.
The step a turn is about to try again wrote an assistant node; a hint
was written after it, and a checkpoint may sit on it.  Dropping the
step's node must not cut the transcript at the hint, and must not come
back when the session is loaded again."
  (harness-session-test-with
    (let* ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
           (u (plist-get (harness-call 'session/append id '(:kind user :content "q")) :id))
           (half (plist-get (harness-call 'session/append id '(:kind assistant :content "half")) :id))
           (hint (plist-get (harness-call 'session/append id '(:kind hint :content "Error: reset")) :id))
           (again (plist-get (harness-call 'session/append id '(:kind assistant :content "again")) :id))
           (removed nil) (moves nil))
      (harness-on 'session/nodes-removed (lambda (_sid ids) (push ids removed)))
      (harness-on 'session/head-moved (lambda (_sid node) (push node moves)))
      ;; The partial node goes, the hint after it stays and is re-parented.
      (should (equal (list half) (harness-call 'session/discard-nodes id (list half))))
      (should-not (harness-call 'session/node id half))
      (should (equal u (plist-get (harness-call 'session/node id hint) :parent)))
      (should (equal (list u hint again)
                     (mapcar (lambda (n) (plist-get n :id)) (harness-call 'session/nodes id))))
      (should (equal (list (list half)) removed))
      (should-not moves)                    ; the head was not one of them
      ;; The newest node goes too: the head moves to the one kept.
      (should (equal (list again) (harness-call 'session/discard-nodes id (list again))))
      (should (equal hint (plist-get (harness-call 'session/get id) :head)))
      (should (equal (list hint) moves))
      ;; Ids that name nothing change nothing.
      (should-not (harness-call 'session/discard-nodes id '("n-nope")))
      (should (equal (list u hint)
                     (mapcar (lambda (n) (plist-get n :id)) (harness-call 'session/nodes id))))
      ;; Loaded again, the dropped nodes are still gone and the chain whole.
      (harness-session-flush)
      (clrhash harness-sessions)
      (harness-session--load-all)
      (should-not (harness-call 'session/node id half))
      (should-not (harness-call 'session/node id again))
      (should (equal u (plist-get (harness-call 'session/node id hint) :parent)))
      (should (equal (list u hint)
                     (mapcar (lambda (n) (plist-get n :id)) (harness-call 'session/nodes id)))))))

(ert-deftest harness-session-messages-carry-the-images-a-result-returned ()
  "A tool result's images ride on its tool_result block, as paths.
The block's content stays a string, so everything that reads the text of
a conversation (a summary, a title, the judge) is unaffected.  Results
with no image keep the shape they had, a failed call has none, a stand-in
for a missing result has none, and the images outlive a restart."
  (harness-session-test-with
    (let* ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
           (images '((:path "/a/shot.png" :mime "image/png") (:path "/a/photo.jpg" :mime "image/jpeg"))))
      (harness-call 'session/append id '(:kind user :content "look"))
      (dolist (c '("c1" "c2" "c3" "c4"))
        (harness-call 'session/append id (list :kind 'tool-call :tool "read_file" :call-id c :input '(:path "x"))))
      (harness-call 'session/append id (list :kind 'tool-result :call-id "c1" :output "Image shot.png attached."
                                             :attachments '((:path "/a/shot.png" :mime "image/png"))
                                             :images images))
      (harness-call 'session/append id '(:kind tool-result :call-id "c2" :output "plain text"))
      (harness-call 'session/append id (list :kind 'tool-result :call-id "c3" :output "failed" :is-error t
                                             :images images))
      ;; c4 is never answered.
      (let ((expected
             (list (list :type "tool_result" :tool_use_id "c1" :content "Image shot.png attached." :is_error nil
                         :images '((:type "image" :mime "image/png" :path "/a/shot.png")
                                   (:type "image" :mime "image/jpeg" :path "/a/photo.jpg")))
                   ;; No `:images' key at all when there are none.
                   '(:type "tool_result" :tool_use_id "c2" :content "plain text" :is_error nil)
                   ;; A failed call's result is text: a provider takes nothing else of one.
                   '(:type "tool_result" :tool_use_id "c3" :content "failed" :is_error t)
                   (list :type "tool_result" :tool_use_id "c4" :content harness-session-missing-result-output
                         :is_error t))))
        (should (equal expected (plist-get (nth 2 (harness-call 'session/messages id)) :content)))
        ;; The images are kept as paths on the node; no bytes are there.
        (should (equal images (plist-get (harness-session-test-result id "c1") :images)))
        ;; A restart reads them back from the node log as they were.
        (harness-session-flush)
        (clrhash harness-sessions)
        (harness-session--load-all)
        (should (equal images (plist-get (harness-session-test-result id "c1") :images)))
        (should (equal expected (plist-get (nth 2 (harness-call 'session/messages id)) :content)))))))

(ert-deftest harness-session-messages-image-results-pair-with-their-calls ()
  "Pairing a call with its result keeps the images of the result, and a result
that answers no call becomes text, which has no image."
  (harness-session-test-with
    (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
          (images '((:path "/a/shot.png" :mime "image/png"))))
      (harness-call 'session/append id '(:kind user :content "look"))
      (harness-call 'session/append id '(:kind tool-call :tool "read_file" :call-id "c1" :input (:path "x")))
      (harness-call 'session/append id (list :kind 'tool-result :call-id "c1" :output "one" :images images))
      ;; The same call answered again, and a call nobody made: both stray.
      (harness-call 'session/append id (list :kind 'tool-result :call-id "c1" :output "again" :images images))
      (harness-call 'session/append id (list :kind 'tool-result :call-id "c9" :output "stray" :images images))
      (let* ((msgs (harness-call 'session/messages id))
             (blocks (plist-get (nth 2 msgs) :content)))
        (should-not (harness-session-test-unpaired msgs))
        (should (equal '("tool_result" "text" "text") (mapcar (lambda (b) (plist-get b :type)) blocks)))
        (should (equal '((:type "image" :mime "image/png" :path "/a/shot.png")) (plist-get (car blocks) :images)))
        (should-not (cl-some (lambda (b) (plist-member b :images)) (cdr blocks)))))))

(provide 'harness-session-test)
(provide 'harness-session-test)
;;; harness-session-test.el ends here
