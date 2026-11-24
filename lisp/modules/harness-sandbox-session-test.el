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

(ert-deftest harness-sandbox-session-a-quiet-command-outlives-the-lease ()
  "A command that prints nothing is not a transport that has gone.
The lease ends a run whose frames stopped arriving, because silence is
what a pipe nobody reads looks like.  But a command that prints nothing
-- a sleep, a build that is quiet, a clone on a slow link -- writes no
frame either, and it was ended at the lease as if its transport had
gone: 119 of 311 runs in 12.4 hours of this harness's own use, 1031
minutes of work thrown away.  The supervisor says `H' while it waits, so
the harness can tell the two apart, and this holds the run past the
lease."
  (harness-sandbox-session-test-with-bwrap
    (let ((harness-sandbox-session--lease-seconds 2)
          (beat (expand-file-name "quiet-beat.txt" root)))
      ;; A run that prints nothing for longer than the lease, then ends
      ;; on its own.  Its silence must not end it.
      (let ((result (harness-sandbox-session-test-run
                     ctx
                     (format "sleep 5; echo quiet-survived > %s; echo done"
                             (shell-quote-argument beat))
                     30)))
        (should (eql 0 (plist-get result :exit)))
        (should (string-search "done" (plist-get result :stdout)))
        (should (file-exists-p beat)))
      ;; And the sandbox is still the one it was, not one rebuilt after a
      ;; teardown: a quiet command is not a reason to lose a session's work.
      (should (harness-sandbox-session-sandbox sid)))))

(ert-deftest harness-sandbox-session-a-transport-that-is-gone-is-still-ended ()
  "Silence with no heartbeat still ends the run.
The lease must keep working: it is what ends a run whose supervisor has
died, whose pipe nobody reads.  A heartbeat is a frame of that same pipe,
so a run whose frames never come is ended as before."
  (harness-sandbox-session-test-with-bwrap
    (let ((harness-sandbox-session--lease-seconds 1)
          (run (harness-sandbox-session-start-run ctx root "sleep 60" :seconds 120)))
      ;; Take the heartbeat away, as a supervisor that is gone would, and
      ;; make the run's last frame old: the next look must end it.
      (setf (plist-get run :started) (- (float-time) 30))
      (let ((runtime (harness-sandbox-session-sandbox sid)))
        (setf (plist-get runtime :checked) (- (float-time) 30))
        (should (harness-sandbox-session--poll-runtime runtime)))
      (harness-test-wait (lambda () (not (eq (harness-sandbox-session-run-state run) 'running)))
                         15 "the run to be ended")
      (should-not (eq 'running (harness-sandbox-session-run-state run))))))

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
                     (harness-sandbox-session-problem (list :cwd root) root)))
            ;; A backend that cannot promise a runtime's cancel and end is
            ;; refused with the facts it lacks, rather than held and found
            ;; out at the first command nothing can stop.
            (cl-letf (((symbol-function 'harness-sandbox--hold-facts)
                       (lambda (backend)
                         (if (eq backend 'bwrap)
                             (list :exec t :stream t :cancel nil :enumerate nil :destroy t
                                   :why "Seatbelt has no handle to end one command of it")
                           (list :exec t :stream t :cancel t :enumerate t :destroy t)))))
              (let ((why (harness-sandbox-session-problem ctx root)))
                (should (string-search "cannot promise cancel, enumerate" why))
                (should (string-search "which a runtime's cancel and end need" why)))))
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
      ;; find them all rather than guess at a process group.  The supervisor
      ;; accepting the run is not the same moment as its processes existing:
      ;; it says `S' as it starts them, and the `setsid' child has to be
      ;; forked and exec'd before it carries the token.  Counting once here
      ;; read 0 or 2 rather than 3 when the machine was busy -- the run was
      ;; accepted and its processes were a moment behind -- so the count is
      ;; waited for, which is what the assertion is about.
      (let ((count-tagged
             (lambda ()
               (let ((tagged (harness-sandbox-session-test-run
                              ctx (format "grep -lzx 'HARNESS_RUN=%s' /proc/[0-9]*/environ 2>/dev/null | wc -l"
                                          token) 30)))
                 (string-to-number (string-trim (plist-get tagged :stdout)))))))
        (harness-test-wait (lambda () (>= (funcall count-tagged) 3))
                           20 "every process of the run to carry its token"))
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
  (dolist (program '("bash" "base64" "grep" "sed" "mkfifo" "dd" "tr" "ps" "sleep"))
    (skip-unless (executable-find program)))
  (let* ((scratch (harness-test-temp-dir))
         (frames (generate-new-buffer " *supervisor-ownership-test*"))
         (instance (concat "test-" (harness-short-id)))
         (token (concat "run-" (harness-short-id)))
         (process-environment (copy-sequence process-environment))
         supervisor owned foreign)
    (cl-labels ((frame (regexp)
                  ;; The supervisor says `H' while it waits for a control
                  ;; line, which is what keeps a quiet command's silence
                  ;; from reading as a transport that has gone.  This test
                  ;; reads the protocol as the harness does, so a
                  ;; heartbeat is skipped rather than mistaken for the
                  ;; frame it is waiting for.  The frames are read as
                  ;; lines rather than by searching the buffer: a search
                  ;; that can match nothing advances point not at all, so
                  ;; a line-oriented regexp finds the empty end of the
                  ;; buffer for ever and never lets the wait read the
                  ;; supervisor's output.
                  (with-current-buffer frames
                    (cl-find-if (lambda (line)
                                  (and (not (equal line "H"))
                                       (string-match-p regexp line)))
                                (split-string (buffer-string) "\n"))))
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
            ;; A count is numbered with the question it answers, so a `P'
            ;; frame is only believed for the state it counted: the answer
            ;; echoes the number the question carried.
            (process-send-string supervisor "status 7\n")
            (should (equal "P 1 7" (await-frame "^P [0-9]+ [0-9]+$")))
            (should (process-live-p owned))
            (should (process-live-p foreign))
            ;; Start a real command with that token before cancelling it:
            ;; the daemon and command must go, not the foreign bystander.
            ;; The command may run for two minutes: the test ends it with
            ;; `kill', and its own timeout must not get there first.
            (process-send-string
             supervisor (format "run %s 120 %s\n" token
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
            (process-send-string supervisor "status 8\n")
            (should (equal "P 0 8" (await-frame "^P [0-9]+ [0-9]+$"))))
        (when (and supervisor (process-live-p supervisor))
          (ignore-errors
            (process-send-string supervisor (format "kill %s\n" token))
            (await-frame (format "^K %s 0$" token))
            (process-send-string supervisor "quit\n")))
        (dolist (proc (list supervisor owned foreign))
          (when (and proc (process-live-p proc)) (delete-process proc)))
        (kill-buffer frames)
        (delete-directory scratch t)))))

(defun harness-sandbox-session-test--tagged (token)
  "Return how many processes of this machine carry TOKEN as a run's own.
It is read from the process table, as a Mac's supervisor reads it: no
`/proc', and a match on whole `NAME=VALUE' words."
  (let ((pattern (concat " HARNESS_RUN=" token " ")))
    (with-temp-buffer
      (call-process "ps" nil t nil "-A" "-ww" "-o" "pid=,command=" "e")
      (goto-char (point-min))
      (let ((n 0))
        (while (re-search-forward "^ *[0-9]+ " nil t)
          (when (string-search pattern (concat " " (buffer-substring-no-properties
                                                   (line-beginning-position) (line-end-position))
                                              " "))
            (setq n (1+ n))))
        n))))

(ert-deftest harness-sandbox-session-a-supervisor-finds-runs-without-proc ()
  "The supervisor finds and ends a run's processes the way macOS must.
macOS has no `/proc' and ships no coreutils `timeout' or `setsid', so the
program cannot read a process's environment from a file or lean on either
program.  HARNESS_SUPERVISOR_PROCS=ps makes it take the path a Mac takes
-- the process table, asked for each process's environment -- and the two
programs a Mac lacks are hidden from its PATH, so a supervisor that still
needed one would say so in its `R' frame instead of running.

Then, over the protocol itself: a command's output and status are its
own; a command that ignores TERM and leaves a child behind is cancelled,
and both are found by the tag they inherited; a command that never ends is
ended at its time with `timeout''s 124, with no `timeout' program to do
it; and `quit' ends what the instance runs before it says it is going,
which is the whole of what a backend without a namespace to end them with
needs."
  (harness-sandbox-session-test--setup)
  (dolist (program '("bash" "base64" "grep" "sed" "mkfifo" "dd" "tr" "ps" "sleep"))
    (skip-unless (executable-find program)))
  (let* ((scratch (harness-test-temp-dir))
         ;; A PATH with the supervisor's own programs and without the two a
         ;; Mac does not ship.
         (bare (make-temp-file "supervisor-bin-" t))
         (frames (generate-new-buffer " *supervisor-ps-test*"))
         (instance (concat "test-" (harness-short-id)))
         (token (concat "run-" (harness-short-id)))
         (process-environment (copy-sequence process-environment))
         supervisor)
    (unwind-protect
        (progn
          (dolist (program '("bash" "base64" "grep" "sed" "mkfifo" "dd" "tr" "ps" "sleep"
                             "mkdir" "rm" "cat" "head"))
            (let ((path (executable-find program)))
              (when path
                (ignore-errors
                  (make-symbolic-link path (expand-file-name program bare))))))
          (setenv "PATH" bare)
          (setenv "HARNESS_SUPERVISOR_PROCS" "ps")
          (setq supervisor
                (make-process
                 :name "ps-supervisor" :buffer frames :noquery t :connection-type 'pipe
                 ;; The program takes VERSION INSTANCE SCRATCH BEAT, as
                 ;; `harness-sandbox-session--hold-command' gives them.
                 :command (list (expand-file-name "bash" bare)
                                (harness-sandbox-session--write-supervisor scratch)
                                (number-to-string harness-sandbox-session--protocol)
                                instance scratch "1")
                 :coding 'utf-8-unix))
          (cl-labels ((frame (regexp)
                        (with-current-buffer frames
                          (cl-find-if (lambda (line)
                                        (and (not (equal line "H"))
                                             (string-match-p regexp line)))
                                      (split-string (buffer-string) "\n"))))
                      (await-frame (regexp)
                        (harness-test-wait (lambda () (frame regexp)) 40 regexp))
                      (send (fmt &rest args)
                        (process-send-string supervisor (apply #'format fmt args))))
            ;; It is up, and it did not name a program a Mac lacks.
            (should (equal (format "R %s" harness-sandbox-session--protocol)
                           (await-frame "^R [0-9]+$")))
            ;; A command's output and its status are its own.
            (send "run %s 60 %s\n" token
                  (base64-encode-string "echo hello-from-the-run; exit 7" t))
            (should (await-frame (format "^O %s " token)))
            (should (string-match-p
                     (format "^X %s 7 0$" token)
                     (await-frame (format "^X %s [0-9]+ [0-9]+$" token))))
            ;; A command that ignores TERM and leaves a child behind is
            ;; cancelled, and both are found by what they inherited.
            (send "run %s 120 %s\n" (concat token "k")
                  (base64-encode-string
                   "trap '' TERM\nbash -c 'trap \"\" TERM; sleep 300' &\nsleep 300" t))
            (should (await-frame (format "^S %s" (concat token "k"))))
            (harness-test-wait
             (lambda () (>= (harness-sandbox-session-test--tagged (concat token "k")) 2))
             30 "the run's two processes to carry its tag")
            (send "kill %s\n" (concat token "k"))
            (should (equal (format "K %s 0" (concat token "k"))
                           (await-frame (format "^K %s [0-9]+$" (concat token "k")))))
            (should (string-match-p
                     " 0$" (await-frame (format "^X %s [0-9]+ [0-9]+$" (concat token "k")))))
            (with-current-buffer frames (erase-buffer))
            (send "status 1\n")
            (should (equal "P 0 1" (await-frame "^P [0-9]+ [0-9]+$")))
            ;; A command that never ends is ended at its time, and says 124
            ;; as `timeout' did -- there is no `timeout' here to do it.
            (with-current-buffer frames (erase-buffer))
            (send "run %s 1 %s\n" (concat token "t")
                  (base64-encode-string "sleep 300" t))
            (should (string-match-p
                     (format "^X %s 124 0$" (concat token "t"))
                     (await-frame (format "^X %s [0-9]+ [0-9]+$" (concat token "t")))))
            ;; `quit' ends what the instance runs before it says it is
            ;; going: a process the session left behind is gone by `D'.
            (with-current-buffer frames (erase-buffer))
            (send "run %s 120 %s\n" (concat token "q")
                  (base64-encode-string "sleep 300 & echo left-a-process" t))
            (should (await-frame (format "^O %s " (concat token "q"))))
            (send "quit\n")
            (should (equal "D" (await-frame "^D$")))
            (harness-test-wait (lambda () (not (process-live-p supervisor))) 15
                               "the supervisor to go")
            (should (eql 0 (harness-sandbox-session-test--tagged (concat token "q"))))))
      (when (and supervisor (process-live-p supervisor))
        (ignore-errors (delete-process supervisor)))
      (kill-buffer frames)
      (ignore-errors (delete-directory bare t))
      (ignore-errors (delete-directory scratch t)))))

(defun harness-sandbox-session-test--mxc-stand-in (dir)
  "Write a streaming stand-in for mxc-exec-mac in DIR, and return its path.
It couples its standard input and output to the command MXC's
configuration names, as an executor that can hold an instance does (see
`harness-sandbox-test--mxc-stand-in'), and takes the command out of the
configuration as that one does."
  (let ((script (expand-file-name "mxc-exec-mac" dir)))
    (with-temp-file script
      (insert "#!/bin/sh\n"
              "cfg=$(printf '%s' \"$2\" | base64 -d)\n"
              "cmd=$(printf '%s' \"$cfg\" | sed -e 's/.*\\\"commandLine\\\":\\\"//' -e 's/\\\",\\\"cwd\\\".*//')\n"
              "exec sh -c \"$cmd\"\n"))
    (set-file-modes script #o755)
    script))

(ert-deftest harness-sandbox-session-a-runtime-is-held-without-proc ()
  "A session holds its runtime on the backend macOS has, and it ends it.
macOS confines with MXC and has no `/proc', so a runtime there is the
supervisor's own: it finds a run's processes by the environment they
inherited, read from the process table, and ends them.  This runs the
whole manager that way -- a stand-in executor for mxc-exec-mac and
HARNESS_SUPERVISOR_PROCS=ps -- and holds a real session's runtime on it:
a command's output and status come back as in any runtime, a process a
call leaves running is the next call's, one command is cancelled without
the runtime, and ending the runtime ends the process the session left --
which is what a backend with no namespace to end it with needs, and the
whole of what was missing."
  (harness-test-with-temp-state
    (harness-test-reset-bus)
    (harness-sandbox-session-test--setup t)
    (dolist (program '("bash" "base64" "grep" "sed" "mkfifo" "dd" "tr" "ps" "sleep"))
      (skip-unless (executable-find program)))
    (skip-unless (file-executable-p "/bin/sh"))
    (let* ((bin (harness-test-temp-dir))
           (executor (harness-sandbox-session-test--mxc-stand-in bin))
           (root (file-name-as-directory (harness-test-temp-dir)))
           (harness-sandbox-policy 'required)
           (harness-sandbox-session-idle-seconds nil)
           (process-environment (cons "HARNESS_SUPERVISOR_PROCS=ps"
                                      (copy-sequence process-environment)))
           (default-directory root)
           sid ctx runtime)
      (unwind-protect
          (progn
            (let ((system-type 'darwin))
              (cl-letf (((symbol-function 'executable-find)
                         (lambda (name &optional _remote)
                           (and (equal name harness-sandbox-mxc-program) executor))))
                (harness-sandbox-detect)))
            (should (eq 'mxc (plist-get (harness-call 'sandbox/status) :backend)))
            (setq sid (plist-get (harness-call 'session/create :cwd root) :id)
                  ctx (list :session-id sid :cwd root))
            ;; A runtime is held, and it is MXC's.
            (setq runtime (harness-sandbox-session-ensure ctx root))
            (should (eq 'mxc (plist-get runtime :backend)))
            (should (process-live-p (plist-get runtime :process)))
            (harness-test-wait
             (lambda () (eq 'running (harness-sandbox-session-state runtime)))
             20 "the runtime to say it is up")
            ;; A command's output and status are its own, as in any runtime.
            (let ((result (harness-sandbox-session-test-run
                           ctx "echo held-on-mxc; exit 5" 30)))
              (should (string-search "held-on-mxc" (plist-get result :stdout)))
              (should (eql 5 (plist-get result :exit))))
            ;; A process a call leaves running is still there after it, and
            ;; it is this instance's: it carries the run's tag.  Its output
            ;; is not the run's, as with any run: a child that kept the
            ;; fifo open would hold the run's own frames.
            (let ((run (harness-sandbox-session-start-run
                        ctx root "sleep 300 >/dev/null 2>&1 & echo left-a-process"
                        :seconds 30 :done #'ignore)))
              (should (string-search "left-a-process"
                                     (plist-get (harness-test-await
                                                 (harness-sandbox-session-wait run) 60)
                                                :stdout)))
              (harness-test-wait
               (lambda () (>= (harness-sandbox-session-test--tagged (plist-get run :token)) 1))
               20 "the process the call left to carry its tag")
              (should (>= (harness-sandbox-session-test--tagged (plist-get run :token)) 1))
              ;; One command is cancelled without the runtime: the
              ;; supervisor finds the processes of that run alone and ends
              ;; them, and says none is left.
              (let ((doomed (harness-sandbox-session-start-run
                             ctx root "trap '' TERM\nbash -c 'trap \"\" TERM; sleep 300' &\nsleep 300"
                             :seconds 120 :done #'ignore)))
                (harness-test-wait
                 (lambda () (>= (harness-sandbox-session-test--tagged (plist-get doomed :token)) 2))
                 20 "the run's two processes to carry its tag")
                (harness-sandbox-session-kill-run doomed)
                (let ((result (harness-test-await (harness-sandbox-session-wait doomed) 90)))
                  (should (eq 'stopped (plist-get result :state)))
                  (should (eql 0 (or (plist-get result :owned) 0))))
                (should (eql 0 (harness-sandbox-session-test--tagged (plist-get doomed :token)))))
              ;; The runtime is still the session's, and it still runs
              ;; commands: cancelling one did not end the instance.
              (should (process-live-p (plist-get runtime :process)))
              (should (string-search "still-here"
                                     (plist-get (harness-sandbox-session-test-run
                                                 ctx "echo still-here" 30)
                                                :stdout)))
              ;; Ending the runtime ends what the session left in it: the
              ;; supervisor ends them before it says it is going, which is
              ;; what a backend without a namespace to end them with has.
              (harness-sandbox-session-stop-session sid "a test ended it")
              (harness-test-wait
               (lambda () (eql 0 (harness-sandbox-session-test--tagged (plist-get run :token))))
               30 "the runtime to leave nothing behind"))
        (ignore-errors (harness-call 'session/delete sid))
        (harness-sandbox-session-shutdown-for-tests)
        (harness-sandbox-detect)
        (ignore-errors (delete-directory root t))
        (ignore-errors (delete-directory bin t)))))))

(ert-deftest harness-sandbox-session-the-poll-does-not-wait-for-a-runtime-to-go ()
  "Looking at the runtimes never waits on one, so the loop keeps running.
`harness-sandbox-session--stop' answers only when the supervisor's
process is gone, and the poll runs ten times a second: every teardown
blocked the harness's whole event loop, every session's work with it.
The harness's own latency records show 2-7.5 s stalls there, one of 38 s
and one of 341 s.  The poll asks for the end and returns; the sentinel
finishes it -- including when the supervisor will not go, which is what
this makes it do.

The poll is what is driven here, not `--stop-later' on its own: a test
that called the non-waiting function directly would pass with the poll
still blocking, which is the defect.  A supervisor that will not take
`quit' is the worst case, and it is what the settle bound is for."
  (harness-sandbox-session-test-with-bwrap
    (let* ((harness-sandbox-session-idle-seconds 0)
           ;; Long enough that a blocking stop would be obvious, short
           ;; enough that the timer ending the supervisor still runs well
           ;; inside the harness's own 60-second sandbox lease.
           (harness-sandbox-session--settle 12)
           (runtime (harness-sandbox-session-ensure ctx root))
           (proc (plist-get runtime :process))
           ;; The runtime has nothing in flight, so the poll's next look
           ;; is the one that ends it.  It has already been asked and has
           ;; answered that it holds nothing, which is what the idle
           ;; branch decides on.
           (start nil))
      (should (process-live-p proc))
      (harness-test-wait (lambda () (integerp (plist-get runtime :owned)))
                         15 "the supervisor's count of what it holds")
      (setf (plist-get runtime :owned) 0
            (plist-get runtime :asked) (float-time)
            (plist-get runtime :idle-since) (- (float-time) 5)
            (plist-get runtime :checked) (float-time))
      (cl-letf (((symbol-function 'harness-process-send) #'ignore))
        (setq start (float-time))
        ;; One look at the runtime: this is the call the timer makes ten
        ;; times a second, with every session waiting behind it.
        (should-not (harness-sandbox-session--poll-runtime runtime))
        (should (< (- (float-time) start) 5)))
      ;; It asked for the end and returned; the supervisor is still there,
      ;; because nothing waited for it.
      (should (process-live-p proc))
      (should (eq 'stopped (plist-get runtime :state)))
      ;; The bound is the timer's, not the caller's: it ends a supervisor
      ;; that would not go, and the sentinel drops what it held.
      (harness-test-wait (lambda () (not (process-live-p proc))) 30 "the supervisor to be ended")
      (should-not (process-live-p proc))
      (harness-test-wait (lambda () (null (plist-get runtime :scratch)))
                         15 "the scratch to be dropped")
      (should-not (file-exists-p (expand-file-name "runs/" (plist-get runtime :dir))))
      ;; The session gets another runtime at its next call.
      (should (string-search "again"
                             (plist-get (harness-sandbox-session-test-run ctx "echo again" 30)
                                        :stdout))))))

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

(ert-deftest harness-sandbox-session-an-answer-older-than-the-change-is-dropped ()
  "A count taken before a command ended never answers for afterwards.
The supervisor scans while it counts, and passes over every process of a
run still in flight -- that run owns them.  So the `status' sent when the
runtime became ready is answered with a zero when it is read during a
command, and that zero says nothing about what the command leaves behind.
Arriving after the run ended, it used to be believed: the runtime looked
empty, and with no idle time to wait for the poll destroyed it with the
process the run had left in it still running.

The answer is dropped because the epoch it carries is not the runtime's
any more.  The ordering here is the one that matters: the question is
asked, the runtime changes, and only then does the answer arrive -- with
no new question in between, so the answer is not superseded by a fresher
one but simply describes a state that is gone."
  (harness-sandbox-session-test--setup)
  (let* ((runtime (harness-sandbox-session--runtime
                   (list :session "s" :instance "i" :runs (make-hash-table :test 'equal)
                         :state 'running)))
         (run (harness-sandbox-session--new-run
               (list :id "r1" :token "r1" :session "s" :command "true" :cwd "/"
                     :seconds 30 :started (float-time) :deadline (+ (float-time) 30)
                     :state 'running))))
    (puthash "r1" run (plist-get runtime :runs))
    ;; The question goes out with the runtime's epoch, which no command has
    ;; changed yet.
    (harness-sandbox-session--ask runtime)
    (should (null (plist-get runtime :epoch)))
    ;; The command ends, leaving nothing of its own; the runtime has
    ;; changed, and the answer owed to that first question is now old.
    (harness-sandbox-session--ended runtime "r1" "0" "0")
    (should (eql 1 (plist-get runtime :epoch)))
    ;; The old answer arrives, carrying the epoch it was asked under.  It
    ;; says the instance holds nothing; it is not believed, so the count
    ;; stays unanswered.  That is the whole point: the poll decides
    ;; nothing on an unanswered count -- a runtime is not idle because
    ;; nobody has counted what it holds -- where a believed zero would
    ;; have started the idle clock and ended it with the process the
    ;; command left behind still in it.
    (harness-sandbox-session--frame runtime "P 0 0")
    (should-not (integerp (plist-get runtime :owned)))
    ;; Asked again, the answer carries the runtime's own epoch and is kept.
    (harness-sandbox-session--ask runtime)
    (harness-sandbox-session--frame runtime "P 1 1")
    (should (eql 1 (plist-get runtime :owned)))))

(ert-deftest harness-sandbox-session-answers-out-of-order-leave-the-newest ()
  "A late answer to an older question never replaces a newer count.
Two questions can be in the supervisor's pipe at once, and its answers
can come back in either order.  Each carries the epoch it was asked
under, so the older one is recognised even when it arrives last."
  (harness-sandbox-session-test--setup)
  (let* ((runtime (harness-sandbox-session--runtime
                   (list :session "s" :instance "i" :runs (make-hash-table :test 'equal)
                         :state 'running))))
    ;; The first question is asked under epoch 0 and answered: two held.
    (harness-sandbox-session--ask runtime)
    (harness-sandbox-session--frame runtime "P 2 0")
    (should (eql 2 (plist-get runtime :owned)))
    ;; A command starts and ends, so the runtime has moved to epoch 1, and
    ;; a second question is asked under it and answered: none held.
    (harness-sandbox-session--bump-epoch runtime)
    (harness-sandbox-session--ask runtime)
    (harness-sandbox-session--frame runtime "P 0 1")
    (should (eql 0 (plist-get runtime :owned)))
    ;; The first answer, delayed, arrives now -- after the newer one.  It
    ;; is not the answer to the question in hand and does not replace it.
    (harness-sandbox-session--frame runtime "P 2 0")
    (should (eql 0 (plist-get runtime :owned)))
    ;; The current epoch's answer is believed, in its turn.
    (harness-sandbox-session--frame runtime "P 3 1")
    (should (eql 3 (plist-get runtime :owned)))))

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

(ert-deftest harness-sandbox-session-a-cancelled-run-is-not-called-a-timeout ()
  "A run the harness asked to stop reports the cancellation, whatever code it exited with.
The supervisor's kill loop sends TERM and then KILL to what ignored it,
and `timeout --kill-after' turns that same pair into 124 and then 137.
Reading the exit code before the cancellation called an explicit
cancellation a timeout whenever a process took the longer road -- which
is exactly the case a stop is for.  The shell tool then saw a stopped run
whose reason was a timeout, could not tell it from one that really
reached its time, and recorded `timeout' where the call was cancelled;
`harness-tasks-pause-stops-the-tool-the-task-was-running' read that as a
failure under load.  A run nobody cancelled is still a timeout at 124 and
137."
  (harness-sandbox-session-test--setup)
  (let* ((runtime (harness-sandbox-session--runtime
                   (list :session "s" :runs (make-hash-table :test 'equal))))
         (run (harness-sandbox-session--new-run
               (list :id "r1" :token "r1" :session "s" :command "sleep 60" :cwd "/"
                     :seconds 90 :started (float-time) :deadline (+ (float-time) 90)
                     :state 'running :cancelled t
                     :cancelled-reason "explicit voice cancellation"))))
    (puthash "r1" run (plist-get runtime :runs))
    ;; The supervisor's report of the kill, for each code the kill can leave.
    (dolist (code '("143" "137" "124" "0"))
      (setf (plist-get run :state) 'running
            (plist-get run :exit) nil
            (plist-get run :reason) nil)
      (harness-sandbox-session--ended runtime "r1" code "0")
      (should (equal "explicit voice cancellation" (plist-get run :reason)))
      (should (eq 'stopped (harness-sandbox-session-run-state run))))
    ;; A run nobody cancelled is still a timeout at the codes a timeout leaves.
    (dolist (code '("124" "137"))
      (setf (plist-get run :state) 'running
            (plist-get run :exit) nil
            (plist-get run :reason) nil
            (plist-get run :cancelled) nil
            (plist-get run :cancelled-reason) nil)
      (harness-sandbox-session--ended runtime "r1" code "0")
      (should (string-prefix-p "it reached its timeout"
                               (plist-get run :reason))))))

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

;;;; What an instance counts as its own

(ert-deftest harness-sandbox-session-a-foreign-instances-processes-are-not-its-own ()
  "A runtime counts what this instance left, never what an outer sandbox holds.
A runtime started from inside another sandbox inherits that sandbox's
`HARNESS_RUN', so the supervisor and the helpers it starts for itself
carry a token this instance never issued.  Counting every tagged process
as a leftover makes such a runtime look busy for ever and it is never
torn down.  The condition is made real here -- the outer token is in the
environment the runtime is built with -- and a runtime holding nothing
of its own is idle all the same, and goes."
  (harness-sandbox-session-test-with-bwrap
    (let* ((harness-sandbox-session-idle-seconds 0)
           (process-environment
            (cons "HARNESS_RUN=outertoken123"
                  (cons "HARNESS_INSTANCE=outerinstance" process-environment)))
           (runtime (harness-sandbox-session-ensure ctx root)))
      (should (process-live-p (plist-get runtime :process)))
      ;; The outer token really is inside the instance: this is not a
      ;; runtime with a clean environment that would pass anyway.
      (let ((tagged (harness-sandbox-session-test-run
                     ctx (concat "grep -lzx 'HARNESS_RUN=outertoken123'"
                                 " /proc/[0-9]*/environ 2>/dev/null | wc -l")
                     30)))
        (should (>= (string-to-number (string-trim (plist-get tagged :stdout))) 1)))
      ;; Asked what it holds, it answers nothing of its own -- not the
      ;; supervisor's helpers, and not the outer instance's work.
      (harness-test-wait (lambda () (integerp (plist-get runtime :owned)))
                         20 "the instance to count what it owns")
      (should (eql 0 (plist-get runtime :owned)))
      ;; Holding nothing, with no idle time to wait for, it goes.
      (harness-test-wait (lambda () (null (harness-sandbox-session-sandbox sid)))
                         30 "the fresh runtime, holding nothing of its own, to go")
      (should-not (process-live-p (plist-get runtime :process))))))

(ert-deftest harness-sandbox-session-a-server-it-holds-outlives-an-empty-run-and-a-count ()
  "A process the instance holds keeps it alive across a run that leaves nothing.
A run that ends with no survivors of its own is no answer to what the
instance holds: an older background server is still there, and a fresh
count taken after that run says so.  The runtime stays through the
whole answer window and the poll ticks inside it, with no idle time to
wait for, and the server it holds is still the one that answers."
  (harness-sandbox-session-test-with-bwrap
    (let* ((harness-sandbox-session-idle-seconds 0)
           (port (+ 20000 (% (abs (sxhash-equal (format "%s-%s" (float-time) (emacs-pid))))
                             20000)))
           (runtime nil))
      ;; Run A leaves a server the instance holds, and ends itself.
      (let ((first (harness-sandbox-session-test-run
                    ctx (format (concat "printf 'held-by-the-instance\\n' > held.txt\n"
                                        "setsid python3 -m http.server %d --bind 127.0.0.1 >/dev/null 2>&1 &\n"
                                        "echo started")
                                port)
                    30)))
        (should (eql 0 (plist-get first :exit)))
        (should (string-search "started" (plist-get first :stdout))))
      ;; The runtime the server is in is read now, not before: with no
      ;; idle time to wait for, a runtime holding nothing is gone already,
      ;; so the one to watch is the one run A's own leftovers kept.
      (setq runtime (harness-sandbox-session-sandbox sid))
      (should runtime)
      (should (process-live-p (plist-get runtime :process)))
      (should (>= (plist-get runtime :owned) 1))
      ;; Run B completes and leaves nothing of its own: its own count is
      ;; zero, which is what makes the next one the instance's business.
      (let ((second (harness-sandbox-session-test-run ctx "true" 30)))
        (should (eql 0 (plist-get second :exit)))
        (should (eql 0 (or (plist-get second :owned) 0))))
      ;; The empty run's zero is discarded, not read as the instance's
      ;; answer: a count is asked for again, and it finds the server.
      (harness-test-wait (lambda () (and (integerp (plist-get runtime :owned))
                                         (>= (plist-get runtime :owned) 1)))
                         20 "a fresh count after the empty run, finding the server")
      ;; It is not torn down: it stays through a whole answer window and
      ;; the poll ticks inside it, with no idle time to wait for.
      (sleep-for (+ harness-sandbox-session--poll-answer 0.5))
      (accept-process-output nil 0.3)
      (should (eq runtime (harness-sandbox-session-sandbox sid)))
      (should (process-live-p (plist-get runtime :process)))
      (should (>= (plist-get (harness-sandbox-session-sandbox sid) :owned) 1))
      ;; And the server it holds is still the one that answers.
      (unwind-protect
          (let ((reached (harness-sandbox-session-test-run
                          ctx (format "curl -fsS --max-time 2 http://127.0.0.1:%d/held.txt" port) 20)))
            (should (string-search "held-by-the-instance"
                                   (or (plist-get reached :stdout) ""))))
        (ignore-errors
          (harness-sandbox-session-test-run
           ctx (format "pkill -f 'http.server %d' || true" port) 15))))))

(ert-deftest harness-sandbox-session-a-cancel-accounts-for-every-child-and-leaks-no-runtime ()
  "A cancel finds setsid children, a double fork and a nested shell, and leaks nothing.
Every one of them carries the run's token, so the cancel finds them all
rather than guessing at a process group.  The answer is that nothing of
the run is left, the instance holds nothing of it afterwards, and the
runtime it was in is still the session's own -- alive and running the
next command -- rather than leaked or replaced."
  (harness-sandbox-session-test-with-bwrap
    ;; The runtime is not to be torn down under the assertions: what is
    ;; measured here is the cancel, not the idle rule.
    (let* ((harness-sandbox-session-idle-seconds nil)
           (runtime (harness-sandbox-session-ensure ctx root))
           (run (harness-sandbox-session-start-run
                 ctx root
                 (concat
                  ;; The command and its children ignore TERM, so the
                  ;; cancel has to escalate, as it does for a real one.
                  "trap '' TERM\n"
                  ;; A child in a session of its own.
                  "setsid bash -c 'trap \"\" TERM; sleep 300' &\n"
                  ;; A double fork: the middle process goes at once and
                  ;; its child is reparented, still carrying the token.
                  "( setsid bash -c 'trap \"\" TERM; sleep 300' & ) &\n"
                  ;; A nested shell that starts one more of its own.
                  "bash -c 'sleep 300' &\n"
                  "sleep 300")
                 :seconds 200))
           (token (plist-get run :token))
           (count (lambda ()
                    (let ((probe (harness-sandbox-session-test-run
                                  ctx (format (concat "grep -lzx 'HARNESS_RUN=%s'"
                                                      " /proc/[0-9]*/environ 2>/dev/null | wc -l")
                                              token)
                                  30)))
                      (string-to-number
                       (string-trim (or (plist-get probe :stdout) "0")))))))
      (harness-test-wait
       (lambda ()
         (and (eq 'running (harness-sandbox-session-state
                            (harness-sandbox-session-sandbox sid)))
              (harness-sandbox-session-live-runs (harness-sandbox-session-sandbox sid))))
       15 "the supervisor to start the command")
      ;; Every kind of child is found by the token before the cancel.
      (harness-test-wait (lambda () (>= (funcall count) 4)) 15
                        "the command's children to carry its token")
      (harness-sandbox-session-kill-run run)
      (let ((result (harness-test-await (harness-sandbox-session-wait run) 90)))
        (should (eq 'stopped (plist-get result :state)))
        (should (eql 0 (or (plist-get result :owned) 0))))
      ;; Nothing of the token is left in the instance.
      (should (= 0 (funcall count)))
      ;; And no runtime was leaked: the session still has the one it had,
      ;; alive, and the next command runs in it.
      (should (= 1 (length (harness-sandbox-session-sandboxes))))
      (should (eq runtime (harness-sandbox-session-sandbox sid)))
      (should (process-live-p (plist-get runtime :process)))
      (let ((after (harness-sandbox-session-test-run ctx "echo still-here" 30)))
        (should (string-search "still-here" (plist-get after :stdout)))))))

(ert-deftest harness-sandbox-session-cancelling-one-run-does-not-signal-another ()
  "Cancelling one run leaves another run of the same runtime, and the validator, untouched.
Two distinct runs are in flight in one runtime at once, each with its
own token and its own process group.  Cancelling the first ends every
process of it -- setsid children and a double fork included -- and
answers only when nothing of it is left.  The second is still running,
its processes still carry only its own token, it finishes with its own
exit status, and the runtime and the enclosing Emacs are still there:
a cancel reaches the processes the run it names created, and nothing
else."
  (harness-sandbox-session-test-with-bwrap
    ;; The runtime is not to be torn down under the assertions.
    (let* ((harness-sandbox-session-idle-seconds nil)
           (runtime (harness-sandbox-session-ensure ctx root))
           ;; The run to cancel: it ignores TERM so the cancel must escalate.
           (doomed (harness-sandbox-session-start-run
                    ctx root
                    (concat "trap '' TERM\n"
                            "setsid bash -c 'trap \"\" TERM; sleep 300' &\n"
                            "( setsid bash -c 'trap \"\" TERM; sleep 300' & ) &\n"
                            "sleep 300")
                    :seconds 200))
           (doomed-token (plist-get doomed :token))
           ;; The run that must survive it.  It waits for a file this test
           ;; writes only after the cancel, so its end is not a race with
           ;; how long the checks above take.
           (keeper (harness-sandbox-session-start-run
                    ctx root
                    (concat "trap '' TERM\n"
                            ;; The detached child writes nothing and holds
                            ;; none of the run's own descriptors: a reader of
                            ;; those ends at EOF, and a child keeping them
                            ;; open would delay the run's own report past the
                            ;; shell's exit, so the status it exited with
                            ;; would arrive only when that child died.
                            "setsid bash -c 'trap \"\" TERM; sleep 300' >/dev/null 2>&1 &\n"
                            "child=$!\n"
                            "echo keeper-started\n"
                            "while [ ! -f keeper-go ]; do sleep 0.2; done\n"
                            "echo keeper-finished\n"
                            ;; It goes with the run that made it.
                            "kill -KILL -- \"-$child\" 2>/dev/null\n"
                            "kill -KILL \"$child\" 2>/dev/null\n"
                            "exit 7")
                    :seconds 120))
           (keeper-token (plist-get keeper :token))
           (count-of (lambda (token)
                       (let ((probe (harness-sandbox-session-test-run
                                     ctx (format (concat "grep -lzx 'HARNESS_RUN=%s'"
                                                         " /proc/[0-9]*/environ 2>/dev/null | wc -l")
                                                 token)
                                     30)))
                         (string-to-number
                          (string-trim (or (plist-get probe :stdout) "0")))))))
      ;; Both runs are in flight in the one runtime, each under its own token.
      (harness-test-wait
       (lambda ()
         (and (eq 'running (harness-sandbox-session-state
                            (harness-sandbox-session-sandbox sid)))
              (= 2 (length (harness-sandbox-session-live-runs
                            (harness-sandbox-session-sandbox sid))))))
       15 "both runs to be in flight")
      (should-not (equal doomed-token keeper-token))
      (harness-test-wait (lambda () (>= (funcall count-of doomed-token) 3)) 15
                        "the cancelled run's children to carry its token")
      (harness-test-wait (lambda () (>= (funcall count-of keeper-token) 2)) 15
                        "the surviving run's children to carry its token")
      ;; Cancel only the first.
      (harness-sandbox-session-kill-run doomed)
      (let ((result (harness-test-await (harness-sandbox-session-wait doomed) 90)))
        (should (eq 'stopped (plist-get result :state)))
        (should (eql 0 (or (plist-get result :owned) 0))))
      ;; Nothing of the cancelled run is left ...
      (should (= 0 (funcall count-of doomed-token)))
      ;; ... and the other run was not signalled by it: it is still running,
      ;; and its processes are alive under its own token.
      (should (eq 'running (harness-sandbox-session-run-state keeper)))
      (should (>= (funcall count-of keeper-token) 2))
      ;; It finishes on its own, with its own exit status and its own output.
      (with-temp-file (expand-file-name "keeper-go" root) (insert "go\n"))
      (let ((kept (harness-test-await (harness-sandbox-session-wait keeper) 90)))
        (should (eql 7 (plist-get kept :exit)))
        (should (string-search "keeper-started" (plist-get kept :stdout)))
        (should (string-search "keeper-finished" (plist-get kept :stdout))))
      ;; The runtime the two shared is the session's own and alive, and the
      ;; enclosing Emacs is untouched: the cancel named one run's processes.
      (should (= 1 (length (harness-sandbox-session-sandboxes))))
      (should (eq runtime (harness-sandbox-session-sandbox sid)))
      (should (process-live-p (plist-get runtime :process)))
      (let ((after (harness-sandbox-session-test-run ctx "echo validator-alive" 30)))
        (should (string-search "validator-alive" (plist-get after :stdout)))))))

(provide 'harness-sandbox-session-test)
;;; harness-sandbox-session-test.el ends here
