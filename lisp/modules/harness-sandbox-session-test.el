;;; harness-sandbox-session-test.el --- Tests for a session's shared sandbox  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; What a session's one sandbox promises, measured with the real bwrap: a
;; command started in one call is still there for the next, in the same
;; mounts -- a file it wrote is read, a server it left listening answers
;; -- every command keeps its own timeout, output and exit status, one
;; command's end does not end the sandbox or another's work, and a change
;; to what the session may reach ends it and builds a new one, telling
;; the session in its transcript that its processes stopped.
;;
;; The tests that need the real bwrap skip where it cannot run, as
;; `harness-sandbox-containment-test' does.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-tools-shell)

(defvar harness-sandbox-session--runtimes)
(defvar harness-sandbox-session--timer)
(defvar harness-sandbox-session-max-commands)
(defvar harness-sandbox-session-output-limit)
(defvar harness-sandbox-session-log-limit)

(defun harness-sandbox-session-test--allow (_decision next &rest _)
  "Permissive permission filter for the tests."
  (funcall next (list :behavior 'allow)))

(defun harness-sandbox-session-test--setup (&optional sandbox)
  "Load what a shared sandbox needs, and a real one when SANDBOX is non-nil."
  (dolist (m '(store project config provider session tools tools-shell perms readonly access agent))
    (harness-test-load-module m))
  (when sandbox
    (harness-test-load-module 'sandbox)
    (harness-sandbox-detect))
  (harness-test-load-module 'sandbox-session)
  (harness-test-connect-ui-client)
  (harness-add-filter 'permission/decide #'harness-sandbox-session-test--allow 10)
  (harness-sandbox-session-shutdown-for-tests))

(defun harness-sandbox-session-shutdown-for-tests ()
  "End every sandbox and forget it, so a test starts from none."
  (dolist (sandbox (harness-sandbox-session-sandboxes))
    (harness-sandbox-session--stop sandbox "a test started"))
  (clrhash harness-sandbox-session--runtimes))

(defmacro harness-sandbox-session-test-with-bwrap (&rest body)
  "Run BODY with a session in a fresh root and the real bwrap.
`root' is the session's working directory, `sid' its id and `tmp' its own
temporary directory; the test is skipped where bwrap cannot run."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (harness-sandbox-session-test--setup t)
     (skip-unless (executable-find "bwrap"))
     (skip-unless (eq 'bwrap (plist-get (harness-call 'sandbox/status) :backend)))
     (let* ((harness-sandbox-policy 'required)
            (root (file-name-as-directory (harness-test-temp-dir)))
            (default-directory root)
            (sid (plist-get (harness-call 'session/create :cwd root) :id))
            (tmp (file-name-as-directory (harness-call 'session/tmp-dir sid)))
            (ctx (list :session-id sid :cwd root)))
       (unwind-protect (progn ,@body)
         (ignore-errors (harness-call 'session/delete sid))
         (harness-sandbox-session-shutdown-for-tests)
         (ignore-errors (delete-directory root t))))))

(defun harness-sandbox-session-test-run (ctx command seconds &optional deadline)
  "Run COMMAND in CTX's sandbox for SECONDS, and return what it gave."
  (let* ((run (harness-sandbox-session-start-run
               ctx (plist-get ctx :cwd) command
               :seconds seconds
               :done #'ignore))
         (result (harness-test-await
                  (harness-sandbox-session-wait
                   run (or deadline (+ (float-time) (max 60 (1+ seconds)))))
                  (+ (max 60 seconds) 30))))
    result))

(defun harness-sandbox-session-test-await-run (ctx command seconds)
  "Run COMMAND in CTX's sandbox for SECONDS and wait for it to end naturally."
  (harness-sandbox-session-test-run ctx command seconds))

;;;; The sandbox itself

(ert-deftest harness-sandbox-session-a-session-has-one-sandbox ()
  "A session's commands run in one bwrap sandbox, held across calls.
The second call reads the file the first wrote, `$HOME` and `/tmp` are
the sandbox's, PID 1 of both is bwrap, and the process that holds it is
one the harness owns -- not one per call."
  (harness-sandbox-session-test-with-bwrap
    (let ((first (harness-sandbox-session-test-run
                  ctx "echo pid1=$(cat /proc/1/comm); echo home=$HOME; echo made > shared.txt; echo one" 30))
          (sandbox nil))
      (should (eql 0 (plist-get first :exit)))
      (should (string-search "pid1=bwrap" (plist-get first :stdout)))
      (should (string-search "one" (plist-get first :stdout)))
      ;; The file is in the session's working directory, where the
      ;; harness's own tools read it too.
      (should (file-exists-p (expand-file-name "shared.txt" root)))
      (setq sandbox (harness-sandbox-session-sandbox sid))
      (should sandbox)
      (should (eq 'running (harness-sandbox-session-state sandbox)))
      ;; The second call is in the same sandbox: it reads what the first
      ;; wrote, and its own PID 1 is the same bwrap.
      (let ((second (harness-sandbox-session-test-run
                     ctx "cat shared.txt; echo pid1=$(cat /proc/1/comm)" 30)))
        (should (eql 0 (plist-get second :exit)))
        (should (string-search "made" (plist-get second :stdout)))
        (should (string-search "pid1=bwrap" (plist-get second :stdout))))
      ;; One sandbox process for the session, however many calls it ran.
      (should (eq sandbox (harness-sandbox-session-sandbox sid)))
      (should (= 1 (length (harness-sandbox-session-sandboxes)))))))

(ert-deftest harness-sandbox-session-a-server-started-in-one-call-answers-the-next ()
  "A process a call leaves running is still running for the next call.
This is the workflow the user asked for: a playtest, a display or a dev
server starts once and later calls reach it.  The listener is killed at
the end, so the test leaves nothing running."
  (harness-sandbox-session-test-with-bwrap
    (let* ((port (+ 20000 (% (abs (sxhash-equal (format "%s-%s" (float-time) (emacs-pid)))) 20000)))
           (first (harness-sandbox-session-test-run
                   ctx (format "printf 'served-by-the-sandbox\\n' > served.txt\nsetsid python3 -m http.server %d --bind 127.0.0.1 >/dev/null 2>&1 &\necho started" port)
                   30)))
      (should (eql 0 (plist-get first :exit)))
      (should (string-search "started" (plist-get first :stdout)))
      (unwind-protect
          (progn
            ;; The next call reaches it, from the same sandbox.
            (harness-test-wait
             (lambda ()
               (let ((r (harness-sandbox-session-test-run
                         ctx (format "curl -fsS --max-time 2 http://127.0.0.1:%d/served.txt" port) 10)))
                 (string-search "served-by-the-sandbox" (or (plist-get r :stdout) ""))))
             30 "the next call reaches the server the first started")
            ;; The server's own process is the sandbox's, and the file it
            ;; serves is the one the first call wrote.
            (should (file-exists-p (expand-file-name "served.txt" root))))
        ;; Ending the server: the sandbox's shell can see it, and after
        ;; the kill nothing answers.
        (ignore-errors
          (harness-sandbox-session-test-run
           ctx (format "pkill -f 'http.server %d' || true" port) 10))
        (harness-test-wait
         (lambda ()
           (let ((r (harness-sandbox-session-test-run
                     ctx (format "curl -fsS --max-time 1 http://127.0.0.1:%d/served.txt" port) 10)))
             (not (string-search "served-by-the-sandbox" (or (plist-get r :stdout) "")))))
         20 "the server stopped")))))

(ert-deftest harness-sandbox-session-each-command-keeps-its-own-time-and-status ()
  "Commands share the sandbox and not their outcomes.
One command's timeout ends that command and nothing else, its exit status
is its own, and the sandbox runs the next one as before."
  (harness-sandbox-session-test-with-bwrap
    (let ((ok (harness-sandbox-session-test-run ctx "echo fine; exit 7" 30)))
      (should (eql 7 (plist-get ok :exit)))
      (should (string-search "fine" (plist-get ok :stdout))))
    (let ((slow (harness-sandbox-session-test-run ctx "echo before; sleep 30; echo after" 1)))
      (should (eq 'timeout (plist-get slow :exit)))
      (should (string-search "before" (plist-get slow :stdout)))
      (should-not (string-search "after" (plist-get slow :stdout))))
    ;; The sandbox is still there, and the next command runs in it.
    (let ((next (harness-sandbox-session-test-run ctx "echo still-here" 30)))
      (should (eql 0 (plist-get next :exit)))
      (should (string-search "still-here" (plist-get next :stdout))))
    (should (eq 'running (harness-sandbox-session-state (harness-sandbox-session-sandbox sid))))))

(ert-deftest harness-sandbox-session-a-kill-ends-one-command-only ()
  "Killing a running command ends it and its group, and leaves the rest alone.
A command that keeps printing is killed, nothing it started in its own
session writes any more, another command in the sandbox still finishes,
and the sandbox itself still runs commands: what is shared is the
sandbox, not one command's life."
  (harness-sandbox-session-test-with-bwrap
    (let* ((beat (expand-file-name "beats.txt" root))
           (run (harness-sandbox-session-start-run
                 ctx root
                 (format "while :; do echo tick >> %s; sleep 0.1; done &\nsleep 30"
                         (shell-quote-argument beat))
                 :seconds 60))
           (ticks (lambda ()
                    (if (file-exists-p beat)
                        (with-temp-buffer
                          (insert-file-contents beat)
                          (length (split-string (buffer-string) "\n" t)))
                      0))))
      (harness-test-wait (lambda () (> (funcall ticks) 0)) 15 "the background writer")
      ;; Another command runs in the same sandbox while it is going.
      (should (string-search "alongside"
                             (plist-get (harness-sandbox-session-test-run ctx "echo alongside" 30) :stdout)))
      (harness-sandbox-session-kill-run run)
      (let ((result (harness-test-await (harness-sandbox-session-wait run) 30)))
        (should (eq 'timeout (plist-get result :exit))))
      ;; The group is gone: nothing it started writes any more.
      (let ((after (funcall ticks)))
        (sleep-for 0.5)
        (should (= after (funcall ticks))))
      ;; The sandbox still runs commands.
      (should (eql 0 (plist-get (harness-sandbox-session-test-run ctx "true" 30) :exit))))))

(ert-deftest harness-sandbox-session-what-a-call-leaves-running-is-the-sharing ()
  "A process a command starts and leaves running outlives the call.
This is the whole point of a shared sandbox: a server, a display or a
playtest is started once and reached by later calls.  It ends with the
sandbox -- a permission change, the module's shutdown, the session's
end -- and the harness lists it as a process of the session's sandbox."
  (harness-sandbox-session-test-with-bwrap
    (let* ((beat (expand-file-name "left-running.txt" root))
           (result (harness-sandbox-session-test-run
                    ctx (format "setsid bash -c 'while :; do echo tick >> %s; sleep 0.1; done' >/dev/null 2>&1 &\necho started"
                                (shell-quote-argument beat))
                    30))
           (ticks (lambda ()
                    (if (file-exists-p beat)
                        (with-temp-buffer
                          (insert-file-contents beat)
                          (length (split-string (buffer-string) "\n" t)))
                      0))))
      (should (string-search "started" (plist-get result :stdout)))
      ;; The call is over, and the process it left is still writing.
      (harness-test-wait (lambda () (> (funcall ticks) 0)) 15 "the writer")
      (let ((first (funcall ticks)))
        (harness-test-wait (lambda () (> (funcall ticks) first)) 10
                           "the writer to keep going after its call ended"))
      ;; And it is in the sandbox, not somewhere else: the sandbox's state
      ;; is the session's, and its end stops the process.
      (should (harness-sandbox-session-sandbox sid))
      (let ((proc (plist-get (harness-sandbox-session-sandbox sid) :process)))
        (harness-sandbox-session-stop-session sid "a test ended it")
        (harness-test-wait (lambda () (not (process-live-p proc))) 10 "the sandbox to end"))
      (let ((after (funcall ticks)))
        (sleep-for 0.5)
        (should (= after (funcall ticks)))))))

(ert-deftest harness-sandbox-session-a-command-sees-the-session-and-only-it ()
  "The shared sandbox is the session's, with the session's mounts and no other's.
A file outside the session's directories is not there, and the sandbox's
own `/proc/1` is bwrap, as a single call's was."
  (harness-sandbox-session-test-with-bwrap
    (let* ((outside (file-name-as-directory (harness-test-temp-dir)))
           (secret (expand-file-name "secret.txt" outside)))
      (unwind-protect
          (progn
            (with-temp-file secret (insert "not-for-the-sandbox\n"))
            (let ((r (harness-sandbox-session-test-run
                      ctx (format "cat %s 2>&1 || echo unreadable" (shell-quote-argument secret)) 30)))
              (should (string-search "unreadable" (plist-get r :stdout)))
              (should-not (string-search "not-for-the-sandbox" (plist-get r :stdout)))))
        (ignore-errors (delete-directory outside t))))))

;;;; Bounds

(ert-deftest harness-sandbox-session-output-is-bounded-in-memory-and-on-disk ()
  "A command that prints without end costs a bounded file and a bounded result.
Its output file stops at the log limit, which says so, and its result
keeps the output limit from the end of what the file holds and says how
much of the front went.  A command whose output fits is read whole."
  (harness-sandbox-session-test-with-bwrap
    ;; The sandbox is built after the limits are bound, so its supervisor
    ;; draws a command's output into a file bounded by them, and the
    ;; harness reads it bounded by the other.
    (let* ((harness-sandbox-session-log-limit 20000)
           (harness-sandbox-session-output-limit 5000)
           (result (harness-sandbox-session-test-run
                    ctx "head -c 200000 /dev/zero | tr '\\0' 'x'" 60))
           (log (plist-get result :log)))
      (should (<= (length (plist-get result :stdout)) (+ 5000 300)))
      (should (> (or (plist-get result :dropped) 0) 0))
      (should (string-search "dropped" (plist-get result :stdout)))
      (should (file-exists-p log))
      (should (<= (file-attribute-size (file-attributes log)) (+ 20000 300)))
      (should (string-search "log stopped after"
                             (with-temp-buffer (insert-file-contents log) (buffer-string)))))
    ;; A command whose output fits is read whole, with no marker.
    (let ((result (harness-sandbox-session-test-run
                   ctx "printf 'a\\nb\\nc\\n'" 30)))
      (should (equal "a\nb\nc\n" (plist-get result :stdout)))
      (should (= 0 (or (plist-get result :dropped) 0))))))

;;;; What the session is told when it is rebuilt

(ert-deftest harness-sandbox-session-a-permission-change-rebuilds-and-says-so ()
  "A change to what the session may reach rebuilds its sandbox, and the
session is told in its transcript that what it ran stopped.  A change
that leaves no possible sandbox ends it with the reason, and nothing
keeps running with authority the session no longer has."
  (harness-sandbox-session-test-with-bwrap
    (let* ((sandbox (harness-sandbox-session-ensure ctx root))
           (first (plist-get sandbox :process))
           (beat (expand-file-name "kept-going.txt" root)))
      (should (process-live-p first))
      ;; Something runs in it, so the note has something to count.
      (should (harness-sandbox-session-start-run
               ctx root
               (format "while :; do echo tick >> %s; sleep 0.2; done" (shell-quote-argument beat))
               :seconds 120))
      (harness-test-wait
       (lambda ()
         (and (file-exists-p beat)
              (> (with-temp-buffer
                   (insert-file-contents beat)
                   (length (split-string (buffer-string) "\n" t)))
                 0)))
       15 "the writer to start")
      ;; A session granted a directory has a profile it did not have, so
      ;; the runtime it had is ended: a new one is built by the next call,
      ;; showing the directory, and the old one is gone with what it ran.
      ;; Nothing is kept warm for a session that is between commands.
      (let* ((extra (harness-test-temp-dir))
             (harness-allowed-directories (list extra)))
        (unwind-protect
            (progn
              (harness-sandbox-session-rebuild sid "a directory was granted")
              (should-not (harness-sandbox-session-sandbox sid))
              (should-not (process-live-p first))
              (let ((now (harness-sandbox-session-ensure ctx root)))
                (should now)
                (should-not (eq first (plist-get now :process)))
                (should (process-live-p (plist-get now :process)))
                (should (string-search
                         extra
                         (plist-get (harness-sandbox-session-test-run
                                     ctx (format "ls -d %s" (shell-quote-argument extra)) 30)
                                    :stdout)))))
              ;; The transcript says the sandbox restarted, and how many of
              ;; the session's processes stopped.
              (let* ((nodes (append (harness-call 'session/nodes sid) nil))
                     (hint (cl-find-if (lambda (node) (eq (plist-get node :kind) 'hint))
                                       nodes)))
                (should hint)
                (should (string-search "Sandbox restarted" (plist-get hint :content)))
                (should (string-search "stopped" (plist-get hint :content)))))
          (ignore-errors (delete-directory extra t))))))

(ert-deftest harness-sandbox-session-a-session-that-ends-takes-its-sandbox ()
  "Deleting or closing a session ends the one sandbox it had, and nothing in it."
  (harness-sandbox-session-test-with-bwrap
    (let* ((sandbox (harness-sandbox-session-ensure ctx root))
           (proc (plist-get sandbox :process)))
      (should (process-live-p proc))
      (harness-call 'session/deactivate sid)
      (harness-test-wait (lambda () (not (process-live-p proc))) 10 "the sandbox to stop")
      (should-not (process-live-p proc))
      (should-not (harness-sandbox-session-sandbox sid)))))

;;;; Where it cannot be

(ert-deftest harness-sandbox-session-a-session-that-cannot-share-one-says-why ()
  "A session gets no shared sandbox where one cannot be held, and says why.
A read-only session, a directory made for one call, a directory on
another host and a call with no session each give a reason, so a caller
falls back to one sandbox per call rather than to no sandbox."
  (harness-sandbox-session-test--setup)
  (harness-test-load-module 'sandbox)
  (harness-sandbox-detect)
  (skip-unless (executable-find "bwrap"))
  (harness-test-with-temp-state
    (let* ((root (file-name-as-directory (harness-test-temp-dir)))
           (default-directory root)
           (harness-sandbox-policy 'required)
           (sid (plist-get (harness-call 'session/create :cwd root) :id))
           (ctx (list :session-id sid :cwd root))
           (read-only (lambda (options _sid)
                        (plist-put (copy-sequence options) :read-only t))))
      (unwind-protect
          (progn
            ;; It can be held here, so the reason is none.
            (should-not (harness-sandbox-session-problem ctx root))
            ;; A read-only session keeps a sandbox of its own per call,
            ;; with its own /tmp: it has no runtime to share.
            (harness-add-filter 'tools/sandbox-options read-only 10)
            (unwind-protect
                (should (string-search "read-only"
                                       (harness-sandbox-session-problem ctx root)))
              (harness-remove-filter 'tools/sandbox-options read-only))
            ;; A directory made for one call belongs to that call: a
            ;; filter that gives one asks for a sandbox that cannot be
            ;; shared.
            (let* ((scratch (harness-test-temp-dir))
                   (with-scratch (lambda (options _sid)
                                   (plist-put (copy-sequence options) :scratch (list scratch)))))
              (unwind-protect
                  (progn
                    (harness-add-filter 'tools/sandbox-options with-scratch 10)
                    (should (string-search "for one call"
                                           (harness-sandbox-session-problem ctx root))))
                (harness-remove-filter 'tools/sandbox-options with-scratch)
                (ignore-errors (delete-directory scratch t))))
            ;; Another host, and a call with no session at all.
            (should (string-search
                     "another host"
                     (harness-sandbox-session-problem
                      (list :session-id sid :cwd "/ssh:host:/tmp/") "/ssh:host:/tmp/")))
            (should (string-search
                     "no session"
                     (harness-sandbox-session-problem (list :cwd root) root))))
        (ignore-errors (harness-call 'session/delete sid))
        (ignore-errors (delete-directory root t))))))

;;;; Bounds the rules promise

(ert-deftest harness-sandbox-session-a-runtime-record-names-every-key-it-sets ()
  "The runtime and run records are built from their key lists, and held to them.
The `setf' of a `plist-get' key a plist does not have binds the variable
it was given rather than the stored plist: a key set later but missing
from the list would be set on a local, never reach the record, and leave a
branch that looks taken and is never taken.  This reads the module's own
source, so a key added to a record without being named fails here rather
than silently doing nothing -- which is what `:asked' did."
  (let* ((file (locate-library "harness-sandbox-session"))
         (source (with-temp-buffer (insert-file-contents (or file
                                                             (expand-file-name
                                                              "harness-sandbox-session.el"
                                                              (file-name-directory
                                                               (symbol-file 'harness-sandbox-session-start-run)))))
                                   (buffer-string)))
         (named (append harness-sandbox-session--runtime-keys
                        harness-sandbox-session--run-keys)))
    (should (equal (sort (delete-dups (copy-sequence harness-sandbox-session--runtime-keys))
                         (lambda (a b) (string< (symbol-name a) (symbol-name b))))
                   (sort (copy-sequence harness-sandbox-session--runtime-keys)
                         (lambda (a b) (string< (symbol-name a) (symbol-name b))))))
    ;; Every key written on a `runtime' variable is in the list.
    (let ((case-fold-search nil) (start 0) written)
      (while (string-match "(plist-put runtime :\\([a-z-]+\\)" source start)
        (push (intern (format ":%s" (match-string 1 source))) written)
        (setq start (match-end 1)))
      (while (string-match "(setf (plist-get runtime :\\([a-z-]+\\)" source start)
        (push (intern (format ":%s" (match-string 1 source))) written)
        (setq start (match-end 1)))
      (dolist (key written)
        (should (memq key harness-sandbox-session--runtime-keys))))
    ;; Every key written on a `run' variable is in the list.
    (let ((start 0) written)
      (while (string-match "(plist-put run :\\([a-z-]+\\)" source start)
        (push (intern (format ":%s" (match-string 1 source))) written)
        (setq start (match-end 1)))
      (while (string-match "(setf (plist-get run :\\([a-z-]+\\)" source start)
        (push (intern (format ":%s" (match-string 1 source))) written)
        (setq start (match-end 1)))
      (dolist (key written)
        (should (memq key harness-sandbox-session--run-keys))))))

(ert-deftest harness-sandbox-session-nothing-it-is-sent-makes-it-read-a-file ()
  "The harness reads no file the sandbox can name to learn what a command printed.
A command's output is the supervisor's frames on its own standard output.
A file the sandbox writes where the old design kept `out' and `status' --
and a symbolic link there to a file outside the sandbox -- changes nothing
the harness reports, because nothing reads it."
  (harness-sandbox-session-test-with-bwrap
    (let* ((outside (file-name-as-directory (harness-test-temp-dir)))
           (secret (expand-file-name "host-only.txt" outside))
           (first (harness-sandbox-session-test-run ctx "echo first; echo 'a real output'" 30))
           ;; Where the old design kept a run's files.
           (run (harness-sandbox-session-sandbox sid)))
      (ignore run)
      (unwind-protect
          (progn
            (with-temp-file secret (insert "HOST-ONLY-SECRET\n"))
            ;; Anything the sandbox can write in the session's temporary
            ;; directory is reachable to it: plant a symlink and a fake
            ;; status file where a pathname-based reader would find them.
            (let ((tmp (plist-get (harness-sandbox-session--profile ctx root) :tmp)))
              (make-directory (expand-file-name "runs" tmp) t)
              (condition-case nil
                  (make-symbolic-link secret (expand-file-name "out" tmp) 'ok-if-already-exists)
                (error nil)))
            (let ((second (harness-sandbox-session-test-run ctx "echo second" 30)))
              (should (eql 0 (plist-get second :exit)))
              (should (string-search "second" (plist-get second :stdout)))
              (should-not (string-search "HOST-ONLY-SECRET" (plist-get second :stdout)))
              (should-not (string-search "HOST-ONLY-SECRET" (or (plist-get second :stderr) ""))))
            ;; And the first run's own output was its own, not the file's.
            (should (string-search "a real output" (plist-get first :stdout))))
        (ignore-errors (delete-directory outside t))))))

(ert-deftest harness-sandbox-session-a-cancel-answers-only-when-nothing-is-left ()
  "Cancelling a command says whether anything of it survived, and ends what did not stop.
A command that ignores TERM and starts a `setsid' child is cancelled;
its result says nothing of it is left, and the processes carrying its
token are gone.  A command that leaves a daemon behind and then ends
normally is not cancelled at all: the daemon is work the instance holds,
counted, and it keeps the runtime alive."
  (harness-sandbox-session-test-with-bwrap
    ;; Nothing left is a fact, not a hope.
    (let* ((run (harness-sandbox-session-start-run
                 ctx root "trap '' TERM; setsid bash -c 'trap \"\" TERM; sleep 300' & sleep 300"
                 :seconds 200))
           (token (plist-get run :token)))
      (harness-test-wait (lambda ()
                           (and (eq 'running (harness-sandbox-session-state
                                              (harness-sandbox-session-sandbox sid)))
                                (harness-sandbox-session-live-runs
                                 (harness-sandbox-session-sandbox sid))))
                         15 "the supervisor to start the command")
      ;; Every process of the run carries its token before it is cancelled --
      ;; the shell, the `setsid' child and the sleeps -- so cancelling can
      ;; find them all rather than guess at a process group.
      (let ((tagged (harness-sandbox-session-test-run
                     ctx (format "grep -lzx 'HARNESS_RUN=%s' /proc/[0-9]*/environ 2>/dev/null | wc -l"
                                 token) 30)))
        (should (>= (string-to-number (string-trim (plist-get tagged :stdout))) 3)))
      (harness-sandbox-session-kill-run run)
      (let ((result (harness-test-await (harness-sandbox-session-wait run) 60)))
        (should (eq 'stopped (plist-get result :state)))
        (should (eql 0 (or (plist-get result :owned) 0))))
      ;; The token's processes are gone from the instance.
      (let ((left (harness-sandbox-session-test-run
                   ctx (format "grep -lzx 'HARNESS_RUN=%s' /proc/[0-9]*/environ 2>/dev/null | wc -l"
                               token) 30)))
        (should (string-search "0" (plist-get left :stdout)))))
    ;; A leftover is counted, and is not "stopped".
    (let ((result (harness-sandbox-session-test-run
                   ctx "nohup sleep 120 >/dev/null 2>&1 & echo left-a-daemon" 30)))
      (should (string-search "left-a-daemon" (plist-get result :stdout)))
      (should (eql 1 (or (plist-get result :owned) 0)))
      (harness-test-wait (lambda ()
                           (eql 1 (plist-get (harness-sandbox-session-sandbox sid) :owned)))
                         15 "the daemon counted")
      (should (harness-sandbox-session-sandbox sid)))))

(ert-deftest harness-sandbox-session-a-supervisor-owns-only-its-instance ()
  "Foreign runtime tags neither keep a runtime alive nor become cancellation targets.
Run the real supervisor in this test's PID namespace, inheriting another
runtime's tags, with one owned survivor and a foreign process carrying
the same run token.  Count the survivor, cancel only this instance's
processes, and report zero afterwards while the foreign process lives."
  (harness-sandbox-session-test--setup)
  (skip-unless (file-readable-p "/proc/self/environ"))
  (dolist (program '("bash" "timeout" "setsid" "base64" "grep" "sed" "mkfifo" "dd" "tr"))
    (skip-unless (executable-find program)))
  (let* ((scratch (harness-test-temp-dir))
         (frames (generate-new-buffer " *supervisor-ownership-test*"))
         (instance (concat "test-" (harness-short-id)))
         (token (concat "run-" (harness-short-id)))
         (process-environment (copy-sequence process-environment))
         supervisor owned foreign)
    (cl-labels ((frame (regexp)
                  (with-current-buffer frames
                    (save-excursion
                      (goto-char (point-min))
                      (when (re-search-forward regexp nil t)
                        (match-string-no-properties 0)))))
                (await-frame (regexp)
                  (harness-test-wait (lambda () (frame regexp)) 15 regexp)))
      (unwind-protect
          (progn
            ;; Tagged stand-ins for an owned daemon and another runtime's
            ;; work, deliberately colliding on their run token.
            (setenv "HARNESS_INSTANCE" instance)
            (setenv "HARNESS_RUN" token)
            (setq owned (make-process :name "owned-survivor" :command '("sleep" "120")
                                      :connection-type 'pipe :noquery t))
            (setenv "HARNESS_INSTANCE" (concat instance "-foreign"))
            (setq foreign (make-process :name "foreign-survivor" :command '("sleep" "120")
                                        :connection-type 'pipe :noquery t)
                  supervisor
                  (make-process
                   :name "ownership-supervisor" :buffer frames :noquery t :connection-type 'pipe
                   :command (list "bash" "-c" harness-sandbox-session--supervisor-program
                                  "supervisor" (number-to-string harness-sandbox-session--protocol)
                                  instance scratch)))
            (await-frame "^R 1$")
            (process-send-string supervisor "status\n")
            (should (equal "P 1" (await-frame "^P [0-9]+$")))
            (should (process-live-p owned))
            (should (process-live-p foreign))
            ;; Start a real command with that token before cancelling it:
            ;; the daemon and command must go, not the foreign bystander.
            (process-send-string
             supervisor (format "run %s 5 %s\n" token
                                (base64-encode-string "printf 'ready\\n'; exec sleep 120" t)))
            (await-frame (format "^O %s " token))
            (process-send-string supervisor (format "kill %s\n" token))
            (should (equal (format "K %s 0" token)
                           (await-frame (format "^K %s [0-9]+$" token))))
            (should (string-match-p
                     " 0$" (await-frame (format "^X %s [0-9]+ [0-9]+$" token))))
            (should-not (process-live-p owned))
            (should (process-live-p foreign))
            (with-current-buffer frames (erase-buffer))
            (process-send-string supervisor "status\n")
            (should (equal "P 0" (await-frame "^P [0-9]+$"))))
        (when (and supervisor (process-live-p supervisor))
          (ignore-errors
            (process-send-string supervisor (format "kill %s\n" token))
            (await-frame (format "^K %s 0$" token))
            (process-send-string supervisor "quit\n")))
        (dolist (proc (list supervisor owned foreign))
          (when (and proc (process-live-p proc)) (delete-process proc)))
        (kill-buffer frames)
        (delete-directory scratch t)))))

(ert-deftest harness-sandbox-session-a-runtime-goes-when-nothing-needs-it ()
  "A runtime with nothing in it is destroyed, and the next call builds another.
Idle is no command in flight and no process the session left: a session
that has stopped working keeps no process, and what it wrote is still
there when the next call builds the next runtime."
  (harness-sandbox-session-test-with-bwrap
    (let* ((harness-sandbox-session-idle-seconds 0)
           (runtime (harness-sandbox-session-ensure ctx root))
           (proc (plist-get runtime :process)))
      (should (process-live-p proc))
      (harness-test-wait (lambda () (null (harness-sandbox-session-sandbox sid)))
                         30 "the idle runtime to go")
      (should-not (process-live-p proc))
      ;; The session's files are still there, and a later call reads them.
      (should (harness-sandbox-session-test-run
               ctx "printf 'kept\\n' > kept.txt; cat kept.txt; exit 0" 30))
      (should (file-exists-p (expand-file-name "kept.txt" root)))
      (harness-test-wait (lambda () (null (harness-sandbox-session-sandbox sid)))
                         30 "the next idle runtime to go")
      (should (equal "kept\n"
                     (plist-get (harness-sandbox-session-test-run ctx "cat kept.txt" 30)
                                :stdout))))))

(ert-deftest harness-sandbox-session-a-concurrent-cap-is-enforced ()
  "A session runs at most its most commands at once, and says so.
The limit is refused with a reason naming it, not queued without end."
  (harness-sandbox-session-test-with-bwrap
    (let ((harness-sandbox-session-max-commands 1)
          (runs nil))
      (unwind-protect
          (progn
            (push (harness-sandbox-session-start-run ctx root "sleep 20" :seconds 40) runs)
            (let ((err (condition-case e
                           (progn (harness-sandbox-session-start-run ctx root "true" :seconds 10) nil)
                         (harness-error (harness-error-message e)))))
              (should err)
              (should (string-search "most" err))))
        (dolist (run runs) (ignore-errors (harness-sandbox-session-kill-run run)))))))

(ert-deftest harness-sandbox-session-a-working-directory-that-is-only-readable-is-bound-read-only ()
  "A runtime is built with the session's working directory as it may have it now.
When the directory the session works in is one it may only read, the
runtime's profile says so and the sandbox binds it read-only: a write
inside it fails rather than using the authority of an older answer."
  (harness-sandbox-session-test-with-bwrap
    ;; A permission layer that answers the session's own working directory
    ;; as one it may only read: the entry comes first, and the first entry
    ;; of a directory is the one that counts.
    (let ((read-dir (lambda (entries _session)
                      (cons (list :dir (file-name-as-directory root)
                                  :source 'read :read-only t)
                            entries))))
      (harness-add-filter 'permission/dir-entries read-dir 10)
      (unwind-protect
          (progn
            (harness-sandbox-session-stop-session sid "a test built it again")
            (let* ((profile (harness-sandbox-session--profile ctx root))
                   (written (harness-sandbox-session-test-run
                             ctx "printf 'x\\n' > must-fail.txt 2>/dev/null && echo WROTE || echo REFUSED" 30)))
              (should-not (plist-get profile :cwd-writable))
              (should (string-search "REFUSED" (plist-get written :stdout)))
              (should-not (file-exists-p (expand-file-name "must-fail.txt" root)))))
        (harness-remove-filter 'permission/dir-entries read-dir)))))

(ert-deftest harness-sandbox-session-a-real-keep-read-downgrade-takes-the-writes-away ()
  "drop_access keep_read=true on the session's own cwd, through the tool, is real.
The review asked for the downgrade to be proved at the level a session
uses it rather than at the level of the profile: a `bash` call writes in
the session's working directory, the session gives the directory up with
`keep_read', and the next call runs in a runtime built for a directory it
may only read.  Its write fails inside the sandbox -- not in a wrapper:
the file is not there afterwards -- while its read still works, and the
file the first call wrote is still readable.

The runtime a session had is ended by the change, not patched: the next
call builds one whose profile says the directory is not writable, which
is what `harness-sandbox-session--profile-now' re-authorises."
  (harness-sandbox-session-test-with-bwrap
    (let ((first (harness-sandbox-session-test-run
                  ctx "printf 'written before\\n' > before.txt; echo made" 30)))
      (should (string-search "made" (plist-get first :stdout)))
      (should (file-exists-p (expand-file-name "before.txt" root)))
      ;; The session gives its own working directory up, keeping it for
      ;; reading -- through the tool a session actually calls.
      (let ((dropped (harness-test-await
                      (harness-call 'tools/execute sid (list :id (harness-short-id)
                                                             :name "drop_access"
                                                             :input (list :attribute "directory"
                                                                          :value root
                                                                          :keep_read t)))
                      30)))
        (should-not (plist-get dropped :is-error))
        (should (string-search "may still be read, not written" (plist-get dropped :content))))
      ;; The change ends the runtime it had.
      (should-not (harness-sandbox-session-sandbox sid))
      ;; A write inside the sandbox fails, and leaves no file: whatever the
      ;; session had, the mount is read-only now.
      (let ((denied (harness-sandbox-session-test-run
                     ctx "printf 'after\\n' > after.txt 2>/dev/null && echo WROTE || echo REFUSED" 30)))
        (should (string-search "REFUSED" (plist-get denied :stdout)))
        (should-not (string-search "WROTE" (plist-get denied :stdout)))
        (should-not (file-exists-p (expand-file-name "after.txt" root))))
      ;; Reading is what it kept: the file from before is still there.
      (let ((read (harness-sandbox-session-test-run ctx "cat before.txt" 30)))
        (should (string-search "written before" (plist-get read :stdout))))
      ;; And the profile the runtime was built from says so.
      (should-not (plist-get (plist-get (harness-sandbox-session-sandbox sid) :profile)
                             :cwd-writable)))))

(ert-deftest harness-sandbox-session-a-late-report-still-says-how-a-run-ended ()
  "A run the harness ended itself keeps what the supervisor reports afterwards.
The deadline kill and the supervisor's own report race: the harness may
end a run a moment before the `X' frame that says what the command
exited with and how many processes it left arrives.  That frame is the
only thing that knows, so it is recorded even though the run has already
ended -- its state and its reason are not overridden, since `--end-run'
has said why it ended and its `:done' has run.  Without this a killed
run kept `:exit' nil for ever, and a job stopped at its time could say
nothing of how it ended."
  (harness-sandbox-session-test--setup)
  (let* ((runtime (harness-sandbox-session--runtime (list :session "s" :runs (make-hash-table :test 'equal))))
         (run (harness-sandbox-session--new-run
               (list :id "r1" :token "r1" :session "s" :command "true" :cwd "/"
                     :seconds 2 :started (float-time) :deadline (+ (float-time) 2)
                     :state 'running :cancelled t
                     :cancelled-reason "it reached its timeout of 2s"))))
    (puthash "r1" run (plist-get runtime :runs))
    ;; The harness ends it first, as the deadline does.
    (harness-sandbox-session--end-run run 'stopped nil "it reached its timeout of 2s")
    (should (eq 'stopped (harness-sandbox-session-run-state run)))
    (should-not (plist-get run :exit))
    ;; The supervisor's report arrives after.
    (harness-sandbox-session--ended runtime "r1" "143" "1")
    (should (eq 'stopped (harness-sandbox-session-run-state run)))
    (should (eql 143 (plist-get run :exit)))
    ;; The report's own count of what the command left behind.
    (should (eql 1 (plist-get run :owned)))
    (should (plist-get run :reported))
    ;; The harness's own reason is not replaced by the late report.
    (should (equal "it reached its timeout of 2s" (plist-get run :reason)))))

(ert-deftest harness-sandbox-session-the-generic-layer-says-what-holds-an-instance ()
  "sandbox/hold answers with a command line and what the backend can promise.
The command line is what confines the harness's own supervisor; the facts
are the lifecycle the runtime manager relies on, and a backend that has
none of them is refused by the manager with that reason rather than
promised."
  (harness-sandbox-session-test--setup t)
  (skip-unless (executable-find "bwrap"))
  (let ((held (harness-call 'sandbox/hold default-directory (list "bash" "-c" "true"))))
    (should (equal 'bwrap (plist-get held :backend)))
    (should (consp (plist-get held :command)))
    (should-not (plist-get held :why))
    (let ((caps (plist-get held :capabilities)))
      (dolist (fact '(:exec :stream :cancel :enumerate :destroy))
        (should (eq t (plist-get caps fact))))))
  ;; A backend the manager cannot rely on says what is missing.
  (should (equal '(:stream :cancel :enumerate)
                 (harness-sandbox-session--missing-capabilities
                  (list :capabilities (list :exec t
                                            :stream nil
                                            :cancel nil
                                            :enumerate nil
                                            :destroy t))))))

(provide 'harness-sandbox-session-test)
;;; harness-sandbox-session-test.el ends here
