;;; harness-mcp-fs-test.el --- The file tools run in the session's sandbox  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; The file tools used to run in the harness process behind a comparison
;; of paths with the session's directories.  Where a sandbox applies they
;; now run in a worker the harness starts in it (lisp/harness-mcp-fs.el),
;; so the kernel decides what a tool can touch.  These tests run the real
;; bwrap and skip where it cannot start.
;;
;; Most of them make the permission chain allow everything, at a stage
;; that ends the chain, so that nothing but the kernel stands between a
;; tool and a file outside the session's directories: the point is that
;; the tools cannot reach it even then.

;;; Code:

(require 'harness-test-helpers)

(defvar harness-sessions)
(defvar harness-sandbox-policy)
(defvar harness-perms--allowed-dirs)
(defvar harness-perms--turn-dirs)
(defvar harness-perms--session-rules)
(defvar harness-perms--once-grants)
(defvar harness-directory)
(defvar harness-tools-fs-jail)

(defun harness-mcp-fs-test--allow-all (_decision next &rest _)
  "Allow every call, for good: the permission chain says nothing more."
  (funcall next (list :behavior 'allow :final t)))

(defun harness-mcp-fs-test--as (session-id name &rest input)
  "Execute the tool NAME with INPUT as SESSION-ID and wait for the result."
  (harness-test-await
   (harness-call 'tools/execute session-id (list :id (harness-short-id) :name name :input input))
   60))

(defvar harness-sandbox-mxc-program)

(defun harness-mcp-fs-test--require-backend (backend)
  "Skip the test unless the sandbox BACKEND is the one in use here, and starts.
BACKEND is `bwrap', which GNU/Linux has, or `mxc', MXC's mxc-exec-mac
on macOS.  Call it after `harness-sandbox-detect'.  A function cannot
use `skip-unless', which ERT gives the body of a test only."
  (let ((in-use (lambda () (eq backend (plist-get (harness-call 'sandbox/status) :backend)))))
    (pcase backend
      ('bwrap
       (unless (executable-find "bwrap") (ert-skip "no bwrap here"))
       (unless (funcall in-use) (ert-skip "bwrap is not the sandbox in use")))
      ('mxc
       (unless (eq system-type 'darwin) (ert-skip "MXC is for macOS"))
       (unless (executable-find harness-sandbox-mxc-program) (ert-skip "no mxc-exec-mac here"))
       (unless (funcall in-use) (ert-skip "MXC is not the sandbox in use"))
       ;; Skipped only when MXC cannot start at all, as on a macOS before
       ;; 15: a worker that does not start under it is what the test is for.
       (let* ((dir (harness-test-temp-dir))
              (probe (unwind-protect
                         (harness-await (harness-run-command (harness-call 'sandbox/wrap dir '("true"))
                                                             :cwd dir :timeout 60)
                                        70)
                       (ignore-errors (delete-directory dir t)))))
         (unless (eql 0 (plist-get probe :exit))
           (ert-skip (format "mxc-exec-mac cannot start here: %s" (string-trim (plist-get probe :stderr)))))))
      (_ (error "Unknown sandbox backend %S" backend)))))

(defmacro harness-mcp-fs-test-with-session-on (backend &rest body)
  "Run BODY with the file tools in a real session, in the sandbox BACKEND.
BACKEND is `bwrap' or `mxc', not quoted; the test skips where it is not
the sandbox in use here or cannot start (see
`harness-mcp-fs-test--require-backend').  `root' is the session's
directory and `outside' one it was not given, with a file `secret' in
it whose text `marker' names.  `link' is a link in `root' that leads to
`outside'.  `(as NAME ...)' runs a tool as the session `sid'.  The
permission chain allows everything."
  (declare (indent 1))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo tools session agent priority perms
                  sandbox tools-shell tools-fs mcp))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-perms--allowed-dirs)
     (clrhash harness-perms--turn-dirs)
     (clrhash harness-perms--session-rules)
     (clrhash harness-perms--once-grants)
     (harness-sandbox-detect)
     (harness-mcp-fs-test--require-backend ',backend)
     (harness-add-filter 'permission/decide #'harness-mcp-fs-test--allow-all 1)
     (let* ((root (file-name-as-directory (harness-test-temp-dir)))
            (outside (file-name-as-directory (harness-test-temp-dir)))
            (marker (format "fs-secret-%s" (harness-short-id 12)))
            (secret (expand-file-name "secret.txt" outside))
            (link (expand-file-name "link" root))
            (default-directory root)
            (harness-sandbox-policy 'required)
            (sid (plist-get (harness-call 'session/create :cwd root :model "demo:scripted"
                                          :permission-mode 'yolo)
                            :id)))
       (cl-flet ((as (name &rest input) (apply #'harness-mcp-fs-test--as sid name input)))
         (with-temp-file secret (insert marker "\n"))
         (make-symbolic-link (directory-file-name outside) link)
         (unwind-protect (progn ,@body)
           (harness-mcp-stop)
           (ignore-errors (delete-directory outside t))
           (ignore-errors (delete-directory root t)))))))

(defmacro harness-mcp-fs-test-with-session (&rest body)
  "Run BODY with the file tools in a real session, in bwrap.
It is `harness-mcp-fs-test-with-session-on' with `bwrap': the tests
skip where bwrap is not the sandbox in use here or cannot start."
  (declare (indent 0))
  `(harness-mcp-fs-test-with-session-on bwrap ,@body))

(ert-deftest harness-mcp-fs-the-worker-starts-under-mxc-on-macos ()
  "On macOS the worker, an Emacs, starts in the real MXC sandbox and serves the tools.
Seatbelt hides ~/Library, and the NS build of Emacs aborts at startup,
even for --batch, when it cannot make its color list there.  The worker
is given a Cocoa home of its own for that (see
`harness-sandbox--mxc-command'); without it every file tool fails with
`The MCP server fs did not start: it exited (134)'.  Skipped except on a
Mac with MXC."
  (harness-mcp-fs-test-with-session-on mxc
    (let ((r (as "write_file" :path "a/b.txt" :content "one\ntwo\n")))
      (should-not (plist-get r :is-error))
      (should (plist-get (plist-get r :meta) :sandboxed)))
    (let ((r (as "read_file" :path "a/b.txt")))
      (should-not (plist-get r :is-error))
      (should (string-search "two" (plist-get r :content)))
      (should (plist-get (plist-get r :meta) :sandboxed)))
    (should (string-search "b.txt" (plist-get (as "list_dir" :path "a") :content)))
    (let ((servers (harness-mcp-fs-test--fs-servers)))
      (should (= 1 (length servers)))
      (should (eq 'ready (plist-get (car servers) :state)))
      (should (plist-get (car servers) :sandboxed)))))

(ert-deftest harness-mcp-fs-the-tools-work-inside-in-the-sandbox ()
  "Each file tool works on the session's own directory, in the worker."
  (harness-mcp-fs-test-with-session
    (let ((r (as "write_file" :path "a/b.txt" :content "one\ntwo\nthree\n")))
      (should-not (plist-get r :is-error))
      (should (equal "fs" (plist-get (plist-get r :meta) :mcp)))
      (should (plist-get (plist-get r :meta) :sandboxed)))
    (should (equal "one\ntwo\nthree\n" (harness-read-file (expand-file-name "a/b.txt" root))))
    (let ((r (as "read_file" :path "a/b.txt")))
      (should-not (plist-get r :is-error))
      (should (string-search "two" (plist-get r :content)))
      (should (plist-get (plist-get r :meta) :sandboxed)))
    (let ((r (as "edit_file" :path "a/b.txt" :old_string "two" :new_string "2")))
      (should-not (plist-get r :is-error)))
    (should (equal "one\n2\nthree\n" (harness-read-file (expand-file-name "a/b.txt" root))))
    (should (string-search "b.txt" (plist-get (as "list_dir" :path "a") :content)))
    (should (string-search "a/b.txt" (plist-get (as "glob" :pattern "**/*.txt") :content)))
    (should (string-search "b.txt:2" (plist-get (as "grep" :pattern "^2$" :path ".") :content)))
    (should (string-search "type: file" (plist-get (as "file_info" :path "a/b.txt") :content)))
    ;; One process serves them all, in the sandbox.
    (let ((servers (cl-remove-if-not (lambda (row) (eq 'fs (plist-get row :server))) (harness-mcp-status))))
      (should (= 1 (length servers)))
      (should (plist-get (car servers) :sandboxed)))))

(defun harness-mcp-fs-test--as-call (session-id call-id name &rest input)
  "Execute the tool NAME with INPUT as SESSION-ID, as the call CALL-ID, and wait."
  (harness-test-await
   (harness-call 'tools/execute session-id (list :id call-id :name name :input input))
   60))

(defun harness-mcp-fs-test--fs-servers ()
  "Return the rows of the file tools' workers in `harness-mcp-status'."
  (cl-remove-if-not (lambda (row) (eq 'fs (plist-get row :server))) (harness-mcp-status)))

(ert-deftest harness-mcp-fs-the-kernel-hides-what-the-chain-let-through ()
  "A file outside the session's directories is out of the tools' reach.
The permission chain is made to allow everything, so the paths below
are not stopped by a comparison: the worker, which the kernel confines,
cannot see them.  They are named every way a tool takes a path, and
each tool is tried; none shows the secret, writes outside, or changes
the file."
  (harness-mcp-fs-test-with-session
    (let ((new (expand-file-name "new.txt" outside))
          (rel (file-relative-name secret root)))
      ;; A tool that fails for some other reason would pass this test.
      (should-not (plist-get (as "write_file" :path "ok.txt" :content "inside\n") :is-error))
      (should (string-search "inside" (plist-get (as "read_file" :path "ok.txt") :content)))
      (dolist (call `(("read_file" :path ,secret)
                      ("read_file" :path ,rel)
                      ("read_file" :path "link/secret.txt")
                      ("file_info" :path ,secret)
                      ("file_info" :path "link/secret.txt")
                      ("list_dir" :path ,outside)
                      ("list_dir" :path "link")
                      ("glob" :pattern "*" :path ,outside)
                      ("glob" :pattern "*" :path "link")
                      ("glob" :pattern "link/*")
                      ("glob" :pattern "**/secret.txt")
                      ("grep" :pattern "fs-secret" :path ,outside)
                      ("grep" :pattern "fs-secret" :path "link")
                      ("grep" :pattern "fs-secret" :path ".")
                      ("write_file" :path ,new :content "x")
                      ("write_file" :path "link/new.txt" :content "x")
                      ("edit_file" :path ,secret :old_string ,marker :new_string "changed")
                      ("edit_file" :path "link/secret.txt" :old_string ,marker :new_string "changed")))
        (let ((r (apply #'as call)))
          (should-not (string-search marker (plist-get r :content)))
          ;; Every one of them went through the worker, which is the point.
          (should (plist-get (plist-get r :meta) :sandboxed))))
      (should (plist-get (as "read_file" :path secret) :is-error))
      (should (plist-get (as "write_file" :path new :content "x") :is-error))
      (should (plist-get (as "edit_file" :path secret :old_string marker :new_string "x") :is-error))
      (should-not (file-exists-p new))
      (should-not (file-exists-p (expand-file-name "new.txt" root)))
      (should (equal (concat marker "\n") (harness-read-file secret)))
      ;; Where the tools run in the harness (the escape hatch), only the
      ;; permission chain stands between them and the file, and here it
      ;; allows everything: this is what the worker is for.
      (let ((harness-tools-fs-jail nil))
        (should (string-search marker (plist-get (as "read_file" :path secret) :content)))))))

(ert-deftest harness-mcp-fs-where-the-tools-run ()
  "The tools run in the sandbox where one applies, and here where none does.
The sandbox policy `off', the escape hatch and a call on another host
each run a call in the harness process; `required' with no backend runs
it nowhere."
  (harness-mcp-fs-test-with-session
    (write-region "hello\n" nil (expand-file-name "f.txt" root) nil 'silent)
    (let ((where (lambda ()
                   (let ((r (as "read_file" :path "f.txt")))
                     (should-not (plist-get r :is-error))
                     (and (plist-get (plist-get r :meta) :sandboxed) t)))))
      (should (funcall where))
      (let ((harness-tools-fs-jail nil)) (should-not (funcall where)))
      (let ((harness-sandbox-policy 'off)) (should-not (funcall where)))
      ;; A path of another host is that host's to confine.
      (let ((r (as "read_file" :path "/ssh:nowhere.invalid:/etc/hostname")))
        (should (plist-get r :is-error))
        (should-not (plist-get (plist-get r :meta) :sandboxed)))
      ;; The policy `required' with no backend: refused, never run unconfined.
      (let ((harness-sandbox-policy 'required)
            (harness-sandbox--backend 'none))
        ;; A worker that runs, confined, would serve the call: stop it.
        (harness-mcp-stop)
        (let ((r (as "read_file" :path "f.txt")))
          (should (plist-get r :is-error))
          (should-not (string-search "hello" (plist-get r :content))))))))

(ert-deftest harness-mcp-fs-a-written-file-is-announced ()
  "A file a tool writes in the sandbox is announced to the harness.
The user's Emacs reverts the buffers that visit it on `tools/file-written'."
  (harness-mcp-fs-test-with-session
    (let (seen)
      (harness-on 'tools/file-written (lambda (path) (push path seen)))
      (as "write_file" :path "w.txt" :content "x\n")
      (as "edit_file" :path "w.txt" :old_string "x" :new_string "y")
      (should (equal (list (expand-file-name "w.txt" root) (expand-file-name "w.txt" root)) seen)))))

(ert-deftest harness-mcp-fs-a-granted-directory-is-shown-from-then-on ()
  "A directory granted to the session is shown to the next call.
The mounts are fixed when the worker starts, so the grant starts a new
one; before it the file is not there, after it it is."
  (harness-mcp-fs-test-with-session
    (should (plist-get (as "read_file" :path secret) :is-error))
    (let ((before (plist-get (car (harness-mcp-fs-test--fs-servers)) :pid)))
      (harness-call 'permission/allow-dir sid outside)
      (let ((r (as "read_file" :path secret)))
        (should-not (plist-get r :is-error))
        (should (string-search marker (plist-get r :content))))
      (should-not (equal before (plist-get (car (harness-mcp-fs-test--fs-servers)) :pid))))
    ;; And withdrawn, it is gone again.
    (harness-call 'permission/revoke-dir sid outside)
    (should (plist-get (as "read_file" :path secret) :is-error))))

(ert-deftest harness-mcp-fs-exempt-reads-are-mounted-for-the-call-that-needs-them ()
  "The harness's own files are read through a mount of exactly that path.
The permission jail lets every call that only reads read the harness
itself, less its credentials; the worker is shown the path the call
names, read-only, and the call is given a worker of its own for it.  A
credential is not an exemption, so no mount is made and the kernel says
it is not there; nor is the neighbour of an exempt file."
  (harness-mcp-fs-test-with-session
    (let ((notes (expand-file-name "notes.txt" harness-state-directory))
          (token (expand-file-name "acp-token" harness-state-directory))
          (readme (expand-file-name "README.md" harness-directory)))
      (write-region "state-notes\n" nil notes nil 'silent)
      (write-region (concat marker "\n") nil token nil 'silent)
      (let ((r (as "read_file" :path notes)))
        (should-not (plist-get r :is-error))
        (should (string-search "state-notes" (plist-get r :content))))
      (when (file-readable-p readme)
        (should-not (plist-get (as "read_file" :path readme :limit 3) :is-error)))
      ;; The credential: not read, and not by listing the directory it is in.
      (should (plist-get (as "read_file" :path token) :is-error))
      (should-not (string-search marker (plist-get (as "read_file" :path token) :content)))
      (should-not (string-search marker (plist-get (as "grep" :pattern "fs-secret" :path harness-state-directory) :content)))
      ;; It is not writable either: the mount is read-only.
      (should (plist-get (as "write_file" :path notes :content "changed\n") :is-error))
      (should (equal "state-notes\n" (harness-read-file notes)))
      ;; The session's own worker was not restarted for these calls.
      (should (cl-some (lambda (row) (equal sid (plist-get row :scope))) (harness-mcp-fs-test--fs-servers))))))

(ert-deftest harness-mcp-fs-a-directory-allowed-once-is-shown-to-that-call-only ()
  "A directory the user allowed for one call is shown to that call.
The grant is the permission module's note of the call (the chain's
\"allow once\"), and the call is given a worker with the directory
mounted as its kind says: a read can read, and does not change what a
call that was not allowed sees."
  (harness-mcp-fs-test-with-session
    (puthash "once-1" (list (concat (directory-file-name outside) "/**")) harness-perms--once-grants)
    (let ((r (harness-mcp-fs-test--as-call sid "once-1" "read_file" :path secret)))
      (should-not (plist-get r :is-error))
      (should (string-search marker (plist-get r :content))))
    ;; Another call is not shown it.
    (should (plist-get (harness-mcp-fs-test--as-call sid "other-2" "read_file" :path secret) :is-error))
    ;; A grant is for one call: it is forgotten when the call is done.
    (should (plist-get (harness-mcp-fs-test--as-call sid "once-1" "read_file" :path secret) :is-error))
    ;; The grant of a call that writes lets it write; the same call's read does not.
    (puthash "once-3" (list (concat (directory-file-name outside) "/**")) harness-perms--once-grants)
    (let ((r (harness-mcp-fs-test--as-call sid "once-3" "write_file"
                                           :path (expand-file-name "w.txt" outside) :content "w\n")))
      (should-not (plist-get r :is-error)))
    (should (equal "w\n" (harness-read-file (expand-file-name "w.txt" outside))))
    ;; The session's own worker is still the same one.
    (should (cl-some (lambda (row) (equal sid (plist-get row :scope))) (harness-mcp-fs-test--fs-servers)))))

(ert-deftest harness-mcp-fs-a-call-the-user-approved-is-shown-what-it-names ()
  "A call the user approved after it was denied reaches the paths it names.
The user said yes to that very call, and the rest of the machine stays
hidden from it."
  (harness-mcp-fs-test-with-session
    (let ((other (expand-file-name "other.txt" (harness-test-temp-dir))))
      (write-region "other\n" nil other nil 'silent)
      (let ((r (harness-test-await
                (harness-call 'tools/execute-approved sid
                              (list :id "approved-1" :name "read_file" :input (list :path secret)))
                60)))
        (should-not (plist-get r :is-error))
        (should (string-search marker (plist-get r :content))))
      ;; The approved call did not open the neighbour it did not name.
      (should (plist-get (as "read_file" :path other) :is-error))
      (let ((new (expand-file-name "made.txt" outside)))
        (let ((r (harness-test-await
                  (harness-call 'tools/execute-approved sid
                                (list :id "approved-2" :name "write_file"
                                      :input (list :path new :content "made\n")))
                  60)))
          (should-not (plist-get r :is-error)))
        (should (equal "made\n" (harness-read-file new)))))))

(ert-deftest harness-mcp-fs-the-sandbox-gives-the-answers-the-harness-process-gives ()
  "The same calls, in the sandbox and in the harness, answer the same.
The worker runs the very handlers, so a difference is a bug of the
plumbing: options not forwarded, a result that did not cross, an error
that came out another way.  Each side works on a tree of its own, made
the same, since some of the calls change files."
  (harness-mcp-fs-test-with-session
    (delete-file link)                  ; the trees must be the same
    (let* ((root2 (file-name-as-directory (harness-test-temp-dir)))
           (sid2 (plist-get (harness-call 'session/create :cwd root2 :model "demo:scripted"
                                          :permission-mode 'yolo)
                            :id))
           (harness-tools-max-output-chars 1200))
      (unwind-protect
          (progn
            (dolist (dir (list root root2))
              (make-directory (expand-file-name "src" dir) t)
              (make-directory (expand-file-name "d/e" dir) t)
              (write-region (concat (mapconcat (lambda (i) (format "(defun fn-%d () %d)" i i))
                                               (number-sequence 1 120) "\n")
                                    "\n")
                            nil (expand-file-name "src/a.el" dir) nil 'silent)
              (write-region "alpha\nbeta\ngamma\n" nil (expand-file-name "src/b.txt" dir) nil 'silent)
              (write-region "" nil (expand-file-name "empty.txt" dir) nil 'silent)
              (let ((coding-system-for-write 'binary))
                (write-region "ab\0cd" nil (expand-file-name "bin.dat" dir) nil 'silent)))
            (let ((calls '(("read_file" :path "src/b.txt")
                           ("read_file" :path "src/b.txt" :offset 2 :limit 1)
                           ("read_file" :path "src/b.txt" :offset 9)
                           ("read_file" :path "src/a.el")
                           ("read_file" :path "empty.txt")
                           ("read_file" :path "bin.dat")
                           ("read_file" :path "d")
                           ("read_file" :path "nope.txt")
                           ("edit_file" :path "src/b.txt" :old_string "nope" :new_string "x")
                           ("edit_file" :path "src/b.txt" :old_string "a" :new_string "x")
                           ("edit_file" :path "src/b.txt" :old_string "beta" :new_string "BETA")
                           ("read_file" :path "src/b.txt")
                           ("list_dir")
                           ("list_dir" :path "." :depth 2)
                           ("list_dir" :path "src/b.txt")
                           ("glob" :pattern "**/*.el")
                           ("glob" :pattern "*.zip")
                           ("glob" :pattern "../*")
                           ("grep" :pattern "BETA" :path "src")
                           ("grep" :pattern "zzzz" :path ".")
                           ("file_info" :path "src/b.txt")
                           ("file_info" :path "nope")
                           ("write_file" :path "d/e/new.txt" :content "n\n")
                           ("write_file" :path "d" :content "x")
                           ("read_file" :path "d/e/new.txt"))))
              (dolist (call calls)
                (let* ((jailed (apply #'harness-mcp-fs-test--as sid call))
                       (here (let ((harness-tools-fs-jail nil))
                               (apply #'harness-mcp-fs-test--as sid2 call)))
                       (normalise (lambda (r)
                                    ;; The tree each side worked in, the order of lists
                                    ;; that have none, and the times of files.
                                    (let ((text (replace-regexp-in-string
                                                 (regexp-quote root2) "ROOT/"
                                                 (replace-regexp-in-string
                                                  (regexp-quote root) "ROOT/"
                                                  (or (plist-get r :content) "")))))
                                      (list (and (plist-get r :is-error) t)
                                            (sort (split-string
                                                   (replace-regexp-in-string "modified: [^\n]*" "" text)
                                                   "\n")
                                                  #'string<))))))
                  (should (plist-get (plist-get jailed :meta) :sandboxed))
                  (should-not (plist-get (plist-get here :meta) :sandboxed))
                  (should (equal (funcall normalise here) (funcall normalise jailed)))))
              ;; And the trees ended the same.
              (dolist (file '("src/b.txt" "d/e/new.txt"))
                (should (equal (harness-read-file (expand-file-name file root))
                               (harness-read-file (expand-file-name file root2)))))))
        (ignore-errors (delete-directory root2 t))))))

(ert-deftest harness-mcp-fs-a-long-output-can-be-read-back ()
  "The output a tool saved because it was long is read back through the worker.
`outputs' under the state directory is made when the first long output
is saved, which may be after the worker started and fixed what it is
shown; it is made before, so the worker sees it."
  (harness-mcp-fs-test-with-session
    ;; The worker starts first, with no `outputs' yet.
    (should-not (plist-get (as "write_file" :path "big.txt" :content
                               (mapconcat (lambda (i) (format "line %04d of a long file" i))
                                          (number-sequence 1 400) "\n"))
                           :is-error))
    (let* ((harness-tools-max-output-chars 800)
           (r (as "grep" :pattern "line" :path "big.txt"))
           (text (plist-get r :content))
           (saved (and (string-match "saved to \\([^ ]+\\.txt\\)" text) (match-string 1 text))))
      (should saved)
      (should (string-prefix-p (expand-file-name "outputs/" harness-state-directory) saved))
      ;; Read in ranges, as the message says.
      (let ((back (as "read_file" :path saved :offset 1 :limit 3)))
        (should-not (plist-get back :is-error))
        (should (string-search "line 0001" (plist-get back :content)))
        (should (plist-get (plist-get back :meta) :sandboxed)))
      ;; Read-only: the tools only read what the harness saved there.
      (should (plist-get (as "write_file" :path saved :content "x") :is-error)))))

(ert-deftest harness-mcp-fs-a-copy-of-an-image-is-made-where-the-harness-can-read-it ()
  "An image made smaller for the model is a file in the session's temporary directory.
ffmpeg runs in the worker, whose /tmp is its own; the copy is for the
model, which the harness reads from, so it is made where both see it."
  (skip-unless (executable-find "ffmpeg"))
  (harness-mcp-fs-test-with-session
    (let ((png (expand-file-name "big.png" root)))
      (should (zerop (call-process "ffmpeg" nil nil nil "-loglevel" "error" "-f" "lavfi" "-i"
                                   "color=c=red:s=96x96" "-frames:v" "1" "-y" png)))
      (let* ((harness-tools-fs-image-max-side 16)
             (r (as "read_file" :path "big.png"))
             (image (car (plist-get r :images)))
             (tmp (harness-call 'session/tmp-dir sid)))
        (should-not (plist-get r :is-error))
        (should (plist-get (plist-get r :meta) :sandboxed))
        (should image)
        ;; The user is shown the file as it is; the model, the copy.
        (should (equal png (plist-get (car (plist-get r :attachments)) :path)))
        (should (string-prefix-p (expand-file-name "model-images/" tmp) (plist-get image :path)))
        (should (file-exists-p (plist-get image :path)))
        (should (equal "image/png" (plist-get image :mime)))))))

(ert-deftest harness-mcp-fs-a-worker-that-dies-is-replaced ()
  "A worker that exits is replaced by the next call, which is served."
  (harness-mcp-fs-test-with-session
    (write-region "x\n" nil (expand-file-name "f.txt" root) nil 'silent)
    (should-not (plist-get (as "read_file" :path "f.txt") :is-error))
    (let ((pid (plist-get (car (harness-mcp-fs-test--fs-servers)) :pid)))
      (should pid)
      (signal-process pid 'kill)
      (harness-test-wait (lambda () (null (harness-mcp-fs-test--fs-servers))) 10 "the worker gone")
      (let ((r (as "read_file" :path "f.txt")))
        (should-not (plist-get r :is-error))
        (should (string-search "x" (plist-get r :content))))
      (should-not (equal pid (plist-get (car (harness-mcp-fs-test--fs-servers)) :pid))))))

(ert-deftest harness-mcp-fs-a-deleted-session-takes-its-workers-with-it ()
  "The worker of a session, and one a call of its own got, go with the session."
  (harness-mcp-fs-test-with-session
    (write-region "x\n" nil (expand-file-name "f.txt" root) nil 'silent)
    (as "read_file" :path "f.txt")
    (puthash "once-9" (list (directory-file-name outside)) harness-perms--once-grants)
    (harness-mcp-fs-test--as-call sid "once-9" "read_file" :path secret)
    (should (= 2 (length (harness-mcp-fs-test--fs-servers))))
    (harness-emit 'session/deleted sid)
    (harness-test-wait (lambda () (null (harness-mcp-fs-test--fs-servers))) 10 "the workers gone")))

(provide 'harness-mcp-fs-test)
;;; harness-mcp-fs-test.el ends here
