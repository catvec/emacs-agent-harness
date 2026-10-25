;;; harness-containment-test.el --- No tool reaches what the jail hides  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; The contract docs/trust-model.md states: the kernel confines a
;; session's work to the directories it may use, and that is the only
;; thing that does.  Reading a command for its intent may say what to
;; ask the user about, never what may run: `python3 -c ...' shows a
;; script where a file is, and the script can read anything.  A tool
;; that does not run in the jail must not be able to do what one that
;; does cannot.
;;
;; These tests ask the same thing through every route an agent has --
;; a bash command, the background Emacs of the elisp tool, a command
;; whose intent the parser cannot see -- and check that what the jail
;; hides stays hidden, and that the route that used to step outside it,
;; free-form Lisp in the user's Emacs, is gone rather than guarded.
;;
;; The sandbox tests need the real bwrap; they skip where it cannot
;; start, as `harness-sandbox-test' does.

;;; Code:

(require 'harness-test-helpers)

(defun harness-containment-test--allow (_decision next &rest _)
  "Permissive permission filter for the tests."
  (funcall next (list :behavior 'allow)))

(defun harness-containment-test--call (name &rest input)
  "Execute tool NAME with INPUT through tools/execute and wait."
  (harness-test-await (harness-call 'tools/execute nil (list :id "c1" :name name :input input)) 30))

(defmacro harness-containment-test-with-jail (&rest body)
  "Run BODY with a session root and a required, real bwrap sandbox.
`root' is the session's working directory, `outside' a directory the
session was not given, and `secret' a file in it whose text `marker'
names.  The tests skip when bwrap cannot start here."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (harness-test-load-module 'project)
     (harness-test-load-module 'config)
     (harness-test-load-module 'sandbox)
     (harness-test-load-module 'tools)
     (harness-test-load-module 'tools-shell)
     (harness-test-connect-ui-client)
     (harness-add-filter 'permission/decide #'harness-containment-test--allow 10)
     (harness-sandbox-detect)
     (skip-unless (executable-find "bwrap"))
     (skip-unless (eq 'bwrap (plist-get (harness-call 'sandbox/status) :backend)))
     (let* ((root (file-name-as-directory (harness-test-temp-dir)))
            (outside (file-name-as-directory (harness-test-temp-dir)))
            (marker (format "containment-secret-%s" (harness-short-id 12)))
            (secret (expand-file-name "secret.txt" outside))
            (default-directory root)
            (harness-sandbox-policy 'required))
       (with-temp-file secret (insert marker "\n"))
       (unwind-protect
           (progn ,@body)
         (ignore-errors (delete-directory outside t))
         (ignore-errors (delete-directory root t))))))

;;;; Reading outside the directories the session may use

(ert-deftest harness-containment-a-command-cannot-read-outside ()
  "A bash command cannot read a file outside the session's directories.
The path check that might have refused it is not what does: the file is
asked for by a program whose intent no parser reads."
  (harness-containment-test-with-jail
    (let ((r (harness-containment-test--call
              "bash" :command (format "cat %s" (shell-quote-argument secret)))))
      (should (plist-get r :is-error))
      (should-not (string-search marker (plist-get r :content))))))

(ert-deftest harness-containment-a-script-cannot-read-what-it-was-not-shown ()
  "A command that looks like it reads only its script can read nothing else.
`python3 -c ...' is the case the old command parser could not decide:
it shows no file to check, and the code it is given reads one.
The jail, not the reading of the command, is what stops it."
  (harness-containment-test-with-jail
    (skip-unless (executable-find "python3"))
    (let ((r (harness-containment-test--call
              "bash"
              :command
              (format "python3 -c %s %s"
                      (shell-quote-argument "import sys; print(open(sys.argv[1]).read())")
                      (shell-quote-argument secret)))))
      (should-not (string-search marker (plist-get r :content))))))

(ert-deftest harness-containment-a-command-cannot-remove-outside ()
  "A command cannot remove a directory outside the session's directories.
`rm -rf' is refused by the command parser as exec; the same removal by a
program the parser cannot read is refused by the kernel, which is the
point: the parser is a courtesy, the jail is the boundary."
  (harness-containment-test-with-jail
    (let ((victim (expand-file-name "victim" outside)))
      (make-directory victim)
      (with-temp-file (expand-file-name "keep.txt" victim) (insert marker))
      ;; What the command parser would refuse may be refused before it
      ;; runs, or may run and find nothing; either way it is not removed.
      (harness-containment-test--call
       "bash" :command (format "rm -rf %s" (shell-quote-argument victim)))
      (should (file-exists-p victim))
      ;; The same removal, by a script, is not the parser's to see.
      (skip-unless (executable-find "python3"))
      (harness-containment-test--call
       "bash"
       :command
       (format "python3 -c %s %s"
               (shell-quote-argument "import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)")
               (shell-quote-argument victim)))
      (should (file-exists-p (expand-file-name "keep.txt" victim))))))

;;;; The elisp tool runs in the same jail

(ert-deftest harness-containment-elisp-runs-in-the-same-jail ()
  "Code the elisp tool runs sees no more than a bash command of the session.
It evaluates in a background Emacs wrapped in the session's profile, not
in the harness and not in the user's Emacs."
  (harness-containment-test-with-jail
    (let ((r (harness-containment-test--call
              "elisp"
              :code (format "(with-temp-buffer (insert-file-contents %S) (buffer-string))" secret))))
      (should-not (string-search marker (plist-get r :content))))
    ;; A file in the session's own directory is readable, so the test is
    ;; not passing because the elisp tool failed for another reason.
    (let ((inside (expand-file-name "inside.txt" root)))
      (with-temp-file inside (insert marker))
      (let ((r (harness-containment-test--call
                "elisp" :code (format "(with-temp-buffer (insert-file-contents %S) (buffer-string))" inside))))
        (should (string-search marker (plist-get r :content)))))))

;;;; The route that left the jail is gone, not guarded

(ert-deftest harness-containment-there-is-no-tool-that-evaluates-in-the-user-emacs ()
  "No tool evaluates Lisp in the user's Emacs, and none can be called by a name.
The incident this work answers began with such a call reaching a
privileged harness method; a call to it is now a call to a tool that
does not exist."
  (harness-test-reset-bus)
  (harness-test-load-module 'tools)
  (harness-test-load-module 'tools-shell)
  (harness-test-load-module 'tools-emacs)
  (harness-add-filter 'permission/decide #'harness-containment-test--allow 10)
  (require 'harness-emacs-endpoint)
  (let ((names (mapcar (lambda (spec) (plist-get spec :name)) (harness-call 'tools/list))))
    (should (member "elisp" names))
    (should-not (member "emacs_eval" names))
    (should-not (cl-some (lambda (name) (string-match-p "emacs-eval\\|emacs_eval" name)) names)))
  (let ((r (harness-containment-test--call "emacs_eval" :code "(+ 1 2)")))
    (should (plist-get r :is-error)))
  ;; The options and the bridge that existed for it are gone, not off.
  (should-not (boundp 'harness-emacs-eval))
  (should-not (fboundp 'harness-emacs-eval-p))
  (should-not (boundp 'harness-call-fallback-function))
  (should-not (fboundp 'harness-acp-call-lisp))
  ;; The elisp tool never evaluates in the user's Emacs, whatever it is asked.
  (let ((r (harness-containment-test--call "elisp" :code "(+ 1 2)" :emacs "user")))
    (should (plist-get r :is-error))
    (should (string-search "never evaluates in the user's Emacs" (plist-get r :content)))))

(ert-deftest harness-containment-the-lent-emacs-has-no-tool-that-runs-code ()
  "The Emacs a client lends offers typed tools, and no tool takes code.
Its MCP server is the whole vocabulary: a tool it does not list cannot
be called, whether or not the message says it is one."
  (require 'harness-emacs-endpoint)
  (let* ((server harness-emacs-endpoint-server)
         (names (mapcar #'harness-mcp-tool-name (harness-mcp-server-tools server))))
    (should (equal '("buffers" "windows" "buffer" "open" "insert" "save"
                     "describe" "definition" "trace" "messages" "snapshot")
                   names))
    (dolist (name names)
      (let ((tool (harness-mcp-server-tool server name)))
        ;; Each carries a schema of its arguments, and none names code.
        (should (harness-mcp-tool-schema tool))
        (let ((schema (format "%S" (harness-mcp-tool-schema tool))))
          (should-not (string-match-p "code-eval\\|eval-code\\|:lisp" schema)))))
    ;; A call to a tool that is not listed is an error of the protocol.
    (let* ((message (harness-mcp-request 1 "tools/call"
                                         (list :name "eval" :arguments (list :code "(+ 1 2)"))))
           (response (harness-mcp-serve server message)))
      (should (equal "2.0" (plist-get response :jsonrpc)))
      (should (plist-get response :error))
      (should (string-search "Unknown tool: eval" (plist-get (plist-get response :error) :message))))))

;;;; The typed tools are judged against the session's directories
;;
;; The tools that take a path are not jailed by the kernel: they run in
;; the harness, behind the permission jail, which compares the paths a
;; call names with the session's directories.  That comparison is the
;; boundary for them (docs/trust-model.md says what it is worth), so
;; these tests drive the whole chain, with the session in yolo mode, which
;; the jail never yields to, and try to reach a file the session was not
;; given by every way a tool takes a path: written out, with `..', through
;; a link, in a pattern, and through something that is not a path at all.

(defvar harness-perms--allowed-dirs)
(defvar harness-perms--turn-dirs)
(defvar harness-perms--session-rules)
(defvar harness-containment-test--submitted nil
  "The (CWD PROMPT OPTS) of each task the fake `task/submit' was asked for.")

(defun harness-containment-test--as (session-id name &rest input)
  "Execute tool NAME with INPUT as SESSION-ID through the whole chain, and wait."
  (harness-test-await
   (harness-call 'tools/execute session-id (list :id (harness-short-id) :name name :input input))
   30))

(defvar harness-sessions)

(defmacro harness-containment-test-with-chain (&rest body)
  "Run BODY with the real permission chain judging a session confined to `root'.
`root' is the session's directory, `outside' one it was not given, with
a file `secret' in it whose text `marker' names, and `link' a link in
`root' that leads to `outside'.  The session `sid' is in yolo mode, so
the jail, which no mode yields to, is what decides.  `(as NAME ...)' runs
a tool as that session, and `(as-in SID NAME ...)' as another."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo tools session agent priority perms
                  tools-fs tools-emacs tools-sessions))
       (harness-test-load-module m))
     (harness-test-connect-ui-client)
     (clrhash harness-sessions)
     (clrhash harness-perms--allowed-dirs)
     (clrhash harness-perms--turn-dirs)
     (clrhash harness-perms--session-rules)
     (setq harness-containment-test--submitted nil)
     (let* ((root (file-name-as-directory (harness-test-temp-dir)))
            (outside (file-name-as-directory (harness-test-temp-dir)))
            (marker (format "chain-secret-%s" (harness-short-id 12)))
            (secret (expand-file-name "secret.txt" outside))
            (link (expand-file-name "link" root))
            (default-directory root)
            ;; Nobody is there to answer: a path outside is refused, where
            ;; for a user who is there the jail would ask.
            (sid (plist-get (harness-call 'session/create :cwd root :model "demo:scripted"
                                          :permission-mode 'yolo :non-interactive t)
                            :id)))
       (cl-labels ((as-in (id name &rest input) (apply #'harness-containment-test--as id name input))
                   (as (name &rest input) (apply #'harness-containment-test--as sid name input)))
         (ignore #'as-in)
         (harness-register-method 'task/list (lambda (&rest _) nil))
         (harness-register-method 'task/submit
                                  (lambda (cwd prompt &optional opts)
                                    (push (list cwd prompt opts) harness-containment-test--submitted)
                                    (list :id "t-fake" :column 'review :state 'review :prompt prompt)))
         (with-temp-file secret (insert marker "\n"))
         (make-symbolic-link (directory-file-name outside) link)
         (unwind-protect (progn ,@body)
           (ignore-errors (delete-directory outside t))
           (ignore-errors (delete-directory root t)))))))

(ert-deftest harness-containment-the-file-tools-cannot-reach-outside ()
  "Every file tool is refused a file the session was not given, however it is named.
The refusal is the jail's, before the tool runs: nothing is read, listed
or written, and the answer does not hold the secret.  The tools do work
inside, and in the same place once the directory is granted, so the
refusals are the jail's and not a tool that fails."
  (harness-containment-test-with-chain
    (let ((rel (file-relative-name secret root))
          (new (expand-file-name "new.txt" outside)))
      (dolist (call `(("read_file" :path ,secret)
                      ("read_file" :path ,rel)
                      ("read_file" :path "link/secret.txt")
                      ("file_info" :path ,secret)
                      ("file_info" :path "link/secret.txt")
                      ("list_dir" :path ,outside)
                      ("list_dir" :path "link")
                      ("grep" :pattern "chain" :path ,outside)
                      ("grep" :pattern "chain" :path "link")
                      ("glob" :pattern "*" :path ,outside)
                      ("glob" :pattern "*" :path "link")
                      ("write_file" :path ,new :content "x")
                      ("write_file" :path "link/new.txt" :content "x")
                      ("edit_file" :path ,secret :old_string "chain" :new_string "pwned")
                      ("edit_file" :path "link/secret.txt" :old_string "chain" :new_string "pwned")))
        (let ((r (apply #'as call)))
          (should (plist-get r :is-error))
          (should (string-search "outside the allowed directories" (plist-get r :content)))
          (should-not (string-search marker (plist-get r :content)))))
      ;; Nothing was written, and nothing changed.
      (should-not (file-exists-p new))
      (should-not (file-exists-p (expand-file-name "new.txt" root)))
      (should (equal (concat marker "\n") (harness-read-file secret)))
      ;; Inside, the same tools work ...
      (with-temp-file (expand-file-name "inside.txt" root) (insert "inside\n"))
      (should-not (plist-get (as "read_file" :path "inside.txt") :is-error))
      (should-not (plist-get (as "write_file" :path "made.txt" :content "x") :is-error))
      (should (file-exists-p (expand-file-name "made.txt" root)))
      ;; ... and outside once the directory is granted, which is the user's to do.
      (harness-call 'permission/allow-dir sid outside)
      (let ((r (as "read_file" :path secret)))
        (should-not (plist-get r :is-error))
        (should (string-search marker (plist-get r :content)))))))

(ert-deftest harness-containment-a-glob-pattern-cannot-name-what-the-path-does-not ()
  "The jail judges the `path' of a glob; its pattern cannot go beyond it.
The pattern is matched below the path, so one written to leave it (an
absolute one, one with `..', one through a link) must list nothing the
jail did not see."
  (harness-containment-test-with-chain
    (with-temp-file (expand-file-name "inside.txt" root) (insert "inside\n"))
    (dolist (pattern (list (concat outside "*") "/etc/pass*" "~/*" "../*"
                           (concat (file-relative-name outside root) "*")))
      (let ((r (as "glob" :pattern pattern)))
        (should (plist-get r :is-error))
        (should-not (string-search "secret.txt" (plist-get r :content)))
        (should-not (string-search "newest first" (plist-get r :content)))))
    (dolist (pattern '("link/*" "li*/secret.txt" "**/secret.txt"))
      (let ((r (as "glob" :pattern pattern)))
        (should-not (string-search "newest first" (plist-get r :content)))))
    ;; The ordinary pattern still lists the directory it is asked in.
    (should (string-search "inside.txt" (plist-get (as "glob" :pattern "*.txt") :content)))))

(ert-deftest harness-containment-a-buffer-of-the-users-emacs-is-the-file-it-visits ()
  "The Emacs tools that change a buffer are bounded by the jail's directories.
emacs_insert and emacs_save_buffer name a buffer, not a path, so the jail
sees nothing to judge: a buffer that visits the user's init file, or a
link to a file outside, would be written as the user.  The tools ask which
file the buffer visits, and the session may write only where the jail
lets it."
  (harness-containment-test-with-chain
    (let* ((victim (expand-file-name "victim.txt" outside))
           (buffers nil))
      (unwind-protect
          (progn
            (with-temp-file victim (insert "victim\n"))
            (let ((direct (find-file-noselect victim t))
                  (via-link (find-file-noselect (expand-file-name "link/secret.txt" root) t)))
              (setq buffers (list direct via-link))
              (with-current-buffer direct (insert "attack\n"))
              (dolist (buffer buffers)
                (let ((r (as "emacs_insert" :name (buffer-name buffer) :text "x")))
                  (should (plist-get r :is-error))
                  (should (string-search "outside the directories this session may write"
                                         (plist-get r :content))))
                (let ((r (as "emacs_save_buffer" :name (buffer-name buffer))))
                  (should (plist-get r :is-error))
                  (should (string-search "outside the directories this session may write"
                                         (plist-get r :content)))))
              ;; The files are what they were.
              (should (equal "victim\n" (harness-read-file victim)))
              (should (equal (concat marker "\n") (harness-read-file secret)))
              ;; Granted, the same call works: the refusal was the jail's.
              (harness-call 'permission/allow-dir sid outside)
              (with-current-buffer direct (set-buffer-modified-p nil) (erase-buffer) (insert "victim\n"))
              (let ((r (as "emacs_save_buffer" :name (buffer-name direct))))
                (should-not (plist-get r :is-error)))))
        (dolist (buffer buffers)
          (when (buffer-live-p buffer)
            (with-current-buffer buffer (set-buffer-modified-p nil))
            (kill-buffer buffer)))))))

(ert-deftest harness-containment-a-task-works-where-the-session-may ()
  "task_submit names the directory its task works in, and the jail judges it.
A task is a session that works in the directory it is given; one made
anywhere the caller likes would be a directory granted without the
user.  The directory is the caller's own by default, and, for a task in
the main tree of the project, the main checkout, which a worktree
session does not hold."
  (harness-containment-test-with-chain
    (let ((main (file-name-as-directory (harness-test-temp-dir))))
      (unwind-protect
          (progn
            ;; A task in the session's own directory is not refused.
            (should-not (plist-get (as "task_submit" :prompt "inside") :is-error))
            (should-not (plist-get (as "task_submit" :prompt "inside too" :cwd ".") :is-error))
            (should (= 2 (length harness-containment-test--submitted)))
            (setq harness-containment-test--submitted nil)
            ;; In a directory it does not hold, it is.
            (dolist (call `((:prompt "elsewhere" :cwd ,outside)
                            (:prompt "elsewhere" :cwd ,(file-relative-name outside root))
                            (:prompt "through a link" :cwd "link")))
              (let ((r (apply #'as "task_submit" call)))
                (should (plist-get r :is-error))
                (should (string-search "outside the allowed directories" (plist-get r :content)))))
            (should-not harness-containment-test--submitted)
            ;; A worktree session holds its worktree, not the checkout the
            ;; worktree belongs to: a task in the main tree is work there.
            (make-directory (expand-file-name ".git/worktrees/wt" main) t)
            (let ((wt (file-name-as-directory (expand-file-name "wt" main))))
              (make-directory wt)
              (with-temp-file (expand-file-name ".git" wt)
                (insert (format "gitdir: %s\n" (expand-file-name ".git/worktrees/wt" main))))
              (with-temp-file (expand-file-name ".git/worktrees/wt/commondir" main) (insert "../..\n"))
              (let ((wt-sid (plist-get (harness-call 'session/create :cwd wt :model "demo:scripted"
                                                     :permission-mode 'yolo :non-interactive t)
                                       :id)))
                (let ((r (as-in wt-sid "task_submit" :prompt "in the checkout" :main_tree t)))
                  (should (plist-get r :is-error))
                  (should (string-search "outside the allowed directories" (plist-get r :content))))
                (should-not harness-containment-test--submitted)
                ;; A task of its own worktree, which is the default, is fine.
                (should-not (plist-get (as-in wt-sid "task_submit" :prompt "in a worktree") :is-error))
                (should (= 1 (length harness-containment-test--submitted)))
                ;; And once the user grants the checkout, the main-tree task is too.
                (harness-call 'permission/allow-dir wt-sid main)
                (should-not (plist-get (as-in wt-sid "task_submit" :prompt "in the checkout" :main_tree t)
                                       :is-error)))))
        (ignore-errors (delete-directory main t))))))

(provide 'harness-containment-test)
;;; harness-containment-test.el ends here
