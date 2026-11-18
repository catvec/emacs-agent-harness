;;; harness-tools-jobs-test.el --- Tests for a session's long-lived jobs  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; What `bash_job' promises, and what it does with a real bwrap: a job
;; started in one call is reached by the next and by a later one, its
;; files stay, it is listed and stopped only by its own session, it ends
;; with its timeout, its session and the module, a permission change
;; rebuilds or stops it, and a backend that cannot hold one refuses it
;; rather than leaving a process nothing ends.
;;
;; The tests that need the real bwrap skip where it cannot start, as
;; `harness-sandbox-containment-test' does.

;;; Code:

(require 'harness-test-helpers)

(defvar harness-tools-jobs--jobs)
(defvar harness-tools-jobs--by-session)
(defvar harness-tools-jobs--timer)
(defvar harness-tools-jobs-ttl)
(defvar harness-tools-jobs-max-per-session)

(defun harness-tools-jobs-test--allow (_decision next &rest _)
  "Permissive permission filter for the tests."
  (funcall next (list :behavior 'allow)))

(defun harness-tools-jobs-test--setup (&optional sandbox)
  "Load what the jobs need, and a real sandbox when SANDBOX is non-nil.
The permission and access modules are loaded too, after the modules they
require: what a job may reach is the directory jail's answer, and a test
that did not load it would test a harness without one."
  (dolist (m '(store project config provider session tools tools-shell perms readonly access agent))
    (harness-test-load-module m))
  (when sandbox
    (harness-test-load-module 'sandbox)
    (harness-sandbox-detect))
  (harness-test-load-module 'sandbox-session)
  (harness-test-load-module 'tools-jobs)
  (harness-test-connect-ui-client)
  (harness-add-filter 'permission/decide #'harness-tools-jobs-test--allow 10)
  (clrhash harness-tools-jobs--jobs)
  (clrhash harness-tools-jobs--by-session)
  ;; Every runtime a test made is ended here: a runtime of an earlier
  ;; test is one the sandbox layer would hand the next test's session,
  ;; and its sessions are gone.
  (when (fboundp 'harness-sandbox-session-sandboxes)
    (dolist (runtime (harness-sandbox-session-sandboxes))
      (harness-sandbox-session--stop runtime "a test started"))
    (when (boundp 'harness-sandbox-session--runtimes)
      (clrhash harness-sandbox-session--runtimes))))

(defmacro harness-tools-jobs-test-with-methods (methods &rest body)
  "Run BODY with the bus METHODS, an alist of name to function, registered."
  (declare (indent 1))
  `(let ((saved (mapcar (lambda (m) (cons (car m) (gethash (car m) harness--methods))) ,methods)))
     (dolist (m ,methods) (harness-register-method (car m) (cdr m)))
     (unwind-protect (progn ,@body)
       (dolist (m saved)
         (if (cdr m) (puthash (car m) (cdr m) harness--methods) (remhash (car m) harness--methods))))))

(defmacro harness-tools-jobs-test-in-dir (&rest body)
  "Run BODY with `root' a fresh directory and `default-directory' in it."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (harness-test-temp-dir)))
          (default-directory root))
     (unwind-protect (progn ,@body)
       (ignore-errors (delete-directory root t)))))

(defun harness-tools-jobs-test--call (sid &rest input)
  "Execute `bash_job' with INPUT in SID and wait."
  (harness-test-await
   (harness-call 'tools/execute sid (list :id (harness-short-id) :name "bash_job" :input input))
   60))

(defun harness-tools-jobs-test--call-tool (sid name &rest input)
  "Execute tool NAME with INPUT in SID and wait."
  (harness-test-await
   (harness-call 'tools/execute sid (list :id (harness-short-id) :name name :input input))
   60))

(defun harness-tools-jobs-test--job-id (result)
  "Return the id of the job RESULT started."
  (or (plist-get (plist-get result :meta) :job)
      (and (string-match "\\`\\(job-[a-z0-9]+\\) started" (plist-get result :content))
           (match-string 1 (plist-get result :content)))))

(defmacro harness-tools-jobs-test-with-jail (&rest body)
  "Run BODY with a session in a fresh root, and a real bwrap sandbox.
`root' is the session's working directory, `sid' its id, and `sandboxed'
tells whether bwrap really runs here; the tests skip when it does not."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (harness-tools-jobs-test--setup t)
     (skip-unless (executable-find "bwrap"))
     (skip-unless (eq 'bwrap (plist-get (harness-call 'sandbox/status) :backend)))
     (let* ((harness-sandbox-policy 'required)
            (root (file-name-as-directory (harness-test-temp-dir)))
            (default-directory root)
            (sid (plist-get (harness-call 'session/create :cwd root) :id)))
       (unwind-protect (progn ,@body)
         (ignore-errors (harness-call 'session/delete sid))
         (ignore-errors (delete-directory root t))))))

(defun harness-tools-jobs-test--process (id)
  "Return the process that runs job ID, or nil when it runs in the sandbox.
A job is a run of its session's one sandbox (see
`harness-sandbox-session'): it has a process of its own only where the
session cannot share a sandbox, and nil here says so."
  (let ((job (gethash id harness-tools-jobs--jobs)))
    (and job (not (plist-get job :shared)) (plist-get job :process))))

(defun harness-tools-jobs-test--running-p (id)
  "Non-nil while job ID runs, in its own process or the session's sandbox."
  (when-let* ((job (gethash id harness-tools-jobs--jobs)))
    (harness-tools-jobs--running-p job)))

(defun harness-tools-jobs-test--sandbox-process (sid)
  "Return the process of SID's shared sandbox, or nil."
  (let ((sandbox (and (fboundp 'harness-sandbox-session-sandbox)
                      (harness-sandbox-session-sandbox sid))))
    (and sandbox (plist-get sandbox :process))))

(defun harness-tools-jobs-test--alive-p (proc-or-job)
  "Non-nil while what holds a job is running.
A job of the session's one sandbox is held by that sandbox's process,
which outlives the job's own run; a job of its own is held by its
process.  Either way, what a caller watches to see a job go is this."
  (let ((proc (if (stringp proc-or-job)
                  (let ((job (gethash proc-or-job harness-tools-jobs--jobs)))
                    (and job (plist-get job :process)))
                proc-or-job)))
    (and proc (process-live-p proc))))

(defun harness-tools-jobs-test--stopped-p (id &optional session)
  "Non-nil once job ID, of SESSION, has stopped running.
A job of a shared sandbox has no process of its own: what ended it is
the sandbox's end, which is what is asked about then."
  (let ((job (gethash id harness-tools-jobs--jobs)))
    (cond
     ((null job) t)
     ((harness-tools-jobs--running-p job) nil)
     ((plist-get job :shared)
      (let ((sandbox (harness-sandbox-session-sandbox (plist-get job :session))))
        (or (null sandbox)
            (not (eq 'running (harness-sandbox-session-state sandbox))))))
     (t (not (process-live-p (plist-get job :process)))))))

(defun harness-tools-jobs-test--free-port ()
  "Return a TCP port nothing is listening on now.
A port chosen by hashing the time and the pid is a guess: two suites of a
full run can pick the same one, and then one test's server answers
another's call -- a failure that has nothing to do with the code under
test.  Binding a port asks the kernel, which is the only thing that knows."
  (let* ((server (make-network-process :name "harness-test-free-port"
                                        :server t :host "127.0.0.1" :service t
                                        :family 'ipv4 :noquery t))
         (port (process-contact server :service)))
    (delete-process server)
    (should (integer-or-marker-p port))
    port))

(defun harness-tools-jobs-test--curl (sid port path)
  "Return what a `bash' call in SID gets from PORT/PATH, as text."
  (plist-get (harness-tools-jobs-test--call-tool
              sid "bash"
              :command (format "curl -fsS --max-time 5 http://127.0.0.1:%d/%s" port path))
             :content))

;;;; The tool a model reads

(ert-deftest harness-jobs-the-tool-is-described-and-offered ()
  "`bash_job' is a tool of the harness, with the actions a session needs.
Its description names the job's lifetime, its ownership, the record of
how it ended and the backends it cannot have, and its schema offers the
seven actions, each with what it needs: an agent that reads only the
tool list must be able to start, find, read and stop a job from it."
  (harness-tools-jobs-test--setup)
  (let* ((spec (cl-find "bash_job" (harness-call 'tools/list)
                        :key (lambda (spec) (plist-get spec :name)) :test #'equal))
         (schema (plist-get spec :schema))
         (properties (plist-get schema :properties))
         (description (plist-get spec :description)))
    (should spec)
    (should (equal "Bash job" (plist-get spec :label)))
    (should (equal '("action") (plist-get schema :required)))
    (should (equal ["start" "list" "status" "logs" "evidence" "stop" "restart"]
                   (plist-get (plist-get properties :action) :enum)))
    (dolist (key '(:command :id :cwd :timeout :lines))
      (should (plist-get properties key)))
    ;; The model is told what persists, what ends it, and who owns it.
    (dolist (sentence
             '("it starts in this call, keeps running after it, and later calls reach it"
               "The harness holds the process, so it is the same sandbox for every call"
               "A job ends when its time is up, when stop names it, when its session is closed or deleted, when its task is done or cancelled or paused, and when the harness shuts down"
               "A job belongs to the session that started it: no other session lists, reads or stops it."
               "A job runs in this session's shared runtime, which the sandbox layer holds on demand, and it needs a backend that can promise a verifiable cancel and teardown"
               "a job is refused with that reason, because its processes there would not be confined or would not end with it"))
      (should (string-search sentence description)))
    ;; The network is the machine's, and the model is told so: a job's id
    ;; is ownership, not an isolated network.
    (should (string-search "The network is the machine's, as it is for bash" description))
    (should (string-search "two jobs cannot bind the same address and port" description))
    ;; And the record of how it ended is named, with what an unexplained
    ;; end reads as: a model asking after the fact must know to look.
    (should (string-search "evidence (id, or all of the session's: how each job started" description))
    (should (string-search "an end with no stop request behind it reads as unexplained" description))))

(ert-deftest harness-jobs-every-key-the-module-sets-is-in-the-record ()
  "Every key the module sets on a job is one its record is given.
`setf' of a `plist-get' key a plist does not have binds the variable it
was given, not the stored plist, so the set looks taken and is not: the
job goes on as if the line were not there.  `:was-running' was such a
key, and a job whose sandbox was rebuilt was never started again in the
new one (`harness-tools-jobs--rebuild-shared' reads it).  This holds the
record to the source: every `(plist-get job :K)' the module writes must
name a key of `harness-tools-jobs--job-keys', and the file the module is
read from is the one on disk, so the test cannot drift from it."
  (harness-tools-jobs-test--setup)
  (let* ((file (expand-file-name "lisp/modules/harness-tools-jobs.el" harness-test-root))
         (written
          (with-temp-buffer
            (insert-file-contents file)
            ;; Comments say what the keys are for; the code is what is
            ;; held to them.
            (goto-char (point-min))
            (while (re-search-forward ";.*$" nil t) (replace-match ""))
            (goto-char (point-min))
            (let (all)
              (while (re-search-forward "plist-get job :\\([a-z-]+\\)" nil t)
                (cl-pushnew (intern (match-string 1)) all))
              all)))
         (known (mapcar (lambda (key) (intern (substring (symbol-name key) 1)))
                        harness-tools-jobs--job-keys)))
    (should written)
    ;; The key this test was written for: set by the rebuild pass and read
    ;; by the one that restarts the job, and not in the record before it.
    (should (member 'was-running written))
    (should (equal nil (cl-remove-if (lambda (key) (memq key known)) written)))))

(ert-deftest harness-jobs-a-new-job-has-every-key ()
  "A job made for a start has a place for every value set on it later.
The record is built from `harness-tools-jobs--job-keys', so a key a
branch sets without being in the list is caught here rather than by a
branch that silently never runs."
  (harness-tools-jobs-test--setup)
  (let ((job (harness-tools-jobs--new-job :id "job-x" :session "s" :command "true")))
    (dolist (key harness-tools-jobs--job-keys)
      (should (member key job)))
    (should (equal "job-x" (plist-get job :id)))
    (should (equal "true" (plist-get job :command)))
    ;; A value set on it is in the record itself, not in a local.
    (setf (plist-get job :was-running) t)
    (should (eq t (plist-get job :was-running)))))

(defun harness-tools-jobs-test--hold-of (backend &optional why)
  "Return what `sandbox/hold' answers for BACKEND, a stub of the adapter.
BACKEND's own facts come from `harness-sandbox--hold-facts', so a test
says which backend it means rather than writing what that backend can do:
a backend that cannot promise a job's stop is refused by what the generic
layer says of it, and a job module that knew the answers itself would not
be asking."
  (let ((facts (harness-sandbox--hold-facts backend)))
    (list :command (if (eq (plist-get facts :exec) t) (list "held-command") nil)
          :backend backend
          :capabilities facts
          :why (or why (plist-get facts :why)))))

(ert-deftest harness-jobs-a-refused-backend-says-why ()
  "Where the sandbox cannot hold a job, the tool says why and starts nothing.
MXC has no handle to end one command, OpenShell a sandbox per command
that its wrapper deletes, systemd-run no PID namespace to verify a stop
in, the `off' policy no jail and no backend none at all: a job there
would be a process nothing confines or nothing ends.  Every answer is the
generic sandbox layer's (`sandbox/hold'), so a backend added there is
refused or allowed by what it promises rather than by a list here."
  (harness-tools-jobs-test--setup)
  (dolist (pair '((mxc . "Seatbelt has no handle to end one command of it")
                  (openshell . "its wrapper deletes the sandbox with the command that made it")
                  (systemd . "its unit has no PID namespace of its own")))
    (harness-tools-jobs-test-with-methods
        (list (cons 'sandbox/status
                    (lambda () (list :backend (car pair) :available (list (car pair))
                                     :policy 'preferred :limits nil)))
              (cons 'sandbox/hold
                    (lambda (&rest _) (harness-tools-jobs-test--hold-of (car pair)))))
      (let ((problem (harness-tools-jobs--backend-problem)))
        (should (string-search (format "The sandbox backend %s cannot hold a job" (car pair))
                               problem))
        (should (string-search (cdr pair) problem)))))
  (harness-tools-jobs-test-with-methods
      (list (cons 'sandbox/status
                  (lambda () (list :backend 'bwrap :available '(bwrap) :policy 'off :limits nil))))
    (should (string-search "harness-sandbox-policy is `off'" (harness-tools-jobs--backend-problem))))
  (harness-tools-jobs-test-with-methods
      (list (cons 'sandbox/status
                  (lambda () (list :backend nil :available nil :policy 'preferred :limits nil))))
    (should (string-search "No sandbox backend can hold a job"
                           (harness-tools-jobs--backend-problem))))
  ;; The backend that can say nothing is not refused: what it promises is
  ;; what a job needs, and the question is asked of it rather than known.
  (harness-tools-jobs-test-with-methods
      (list (cons 'sandbox/status
                  (lambda () (list :backend 'bwrap :available '(bwrap)
                                   :policy 'required :limits nil)))
            (cons 'sandbox/hold (lambda (&rest _) (harness-tools-jobs-test--hold-of 'bwrap))))
    (should-not (harness-tools-jobs--backend-problem)))
  ;; And a start there leaves no job behind.
  (harness-tools-jobs-test-with-methods
      (list (cons 'sandbox/status
                  (lambda () (list :backend 'mxc :available '(mxc) :policy 'preferred :limits nil)))
            (cons 'sandbox/hold (lambda (&rest _) (harness-tools-jobs-test--hold-of 'mxc))))
    (harness-tools-jobs-test-in-dir
      (let* ((sid (plist-get (harness-call 'session/create :cwd root) :id))
             (r (harness-tools-jobs-test--call sid :action "start" :command "sleep 30")))
        (should (plist-get r :is-error))
        (should (string-search "cannot hold a job" (plist-get r :content)))
        (should (= 0 (hash-table-count harness-tools-jobs--jobs)))
        (ignore-errors (harness-call 'session/delete sid))))))

;;;; A job, across real calls

(ert-deftest harness-jobs-a-server-started-in-one-call-is-used-in-later-ones ()
  "A server a call starts as a job answers the next calls, and keeps its files.
This is the workflow the review asked for and the one the failing agent
had to do without: call one starts a job that writes and serves a file,
call two reads it over the network, call three reads it again, and the
file is still in the working directory after the job is stopped.  The
job is a run in the session's shared runtime -- the session's mounts, and
one PID namespace the session's calls share -- so it outlives the call
that started it, nothing it leaves reaches where the session may not go,
and stopping it ends its run while the runtime and the files stay."
  (harness-tools-jobs-test-with-jail
    (let* ((port (harness-tools-jobs-test--free-port))
           (script (format "printf 'served-by-the-job\\n' > served.txt\nprintf 'listening\\n'\nexec python3 -m http.server %d --bind 127.0.0.1" port))
           (first (harness-tools-jobs-test--call sid :action "start" :command script :timeout 120))
           (id (harness-tools-jobs-test--job-id first)))
      (should-not (plist-get first :is-error))
      (should id)
      (unwind-protect
          (progn
            ;; The job writes in the session's working directory, where
            ;; the harness's own tools see it too.
            (harness-test-wait (lambda () (file-exists-p (expand-file-name "served.txt" root))) 20
                               "the job wrote its file")
            (should (equal "served-by-the-job\n"
                           (with-temp-buffer
                             (insert-file-contents (expand-file-name "served.txt" root))
                             (buffer-string))))
            ;; The next call reaches it over the network -- the job's
            ;; process outlived the call that started it.  The listener
            ;; takes a moment to bind, so the call is retried as a caller
            ;; waits for one.
            (harness-test-wait
             (lambda ()
               (string-search "served-by-the-job"
                              (harness-tools-jobs-test--curl sid port "served.txt")))
             20 "the job's server answers the next call")
            ;; And a later one does too.
            (should (string-search "served-by-the-job"
                                   (harness-tools-jobs-test--curl sid port "served.txt")))
            ;; The session lists it as running, and reads its output.
            (let ((list (harness-tools-jobs-test--call sid :action "list")))
              (should (string-search id (plist-get list :content)))
              ;; The line says what it is doing, how long of its time it
              ;; has run and the time it may run, in exact words: a
              ;; caller reads both numbers, and neither is a guess.
              (should (string-match-p
                       (format "\\`%s  running · \\([0-9]+ms\\|[0-9.]+s\\|[0-9]+m[0-9]+s\\) of 2m00s · pid [0-9]+  "
                               (regexp-quote id))
                       (plist-get list :content))))
            (should (string-search "running"
                                   (plist-get (harness-tools-jobs-test--call sid :action "status" :id id)
                                              :content)))
            ;; The job's output is kept, and logs reads it back: the
            ;; listener's own line and the requests it answered.
            (harness-test-wait
             (lambda ()
               (string-search "served.txt"
                              (plist-get (harness-tools-jobs-test--call sid :action "logs" :id id
                                                                        :lines 20)
                                         :content)))
             10 "the job's log has its requests"))
        ;; Stopping it ends the server, and the file stays.
        (let ((stopped (harness-tools-jobs-test--call sid :action "stop" :id id)))
          (should-not (plist-get stopped :is-error))
          (should (string-search "stopped" (plist-get stopped :content))))
        (should (file-exists-p (expand-file-name "served.txt" root)))
        ;; The stop records the job stopped at once; the supervisor ends
        ;; its run asynchronously, so the server answering is what says
        ;; the run is really gone -- waiting on the job's own state would
        ;; pass before the kill landed.
        (should-not (eq 'running (plist-get (car (harness-tools-jobs-session-entries sid)) :state)))
        (harness-test-wait
         (lambda ()
           (not (eq 'running (plist-get (car (harness-tools-jobs-session-entries sid)) :state))))
         5 "the job stopped")
        ;; Stopping ends the job's run: the server stops answering.  The
        ;; record says stopped as soon as the stop is asked for, and the
        ;; kernel ends the run a moment later, so the answer is waited
        ;; for rather than read in the same instant -- on a loaded
        ;; machine the kill has not landed yet when the call returns.
        (harness-test-wait
         (lambda ()
           (not (string-search "served-by-the-job"
                               (harness-tools-jobs-test--curl sid port "served.txt"))))
         20 "the stopped job's server to stop answering")))))

(ert-deftest harness-jobs-a-job-is-its-own-sessions ()
  "One session cannot list, read or stop another's job.
A job is the session's that started it: its id is not found from
another session, its log is not read, and a stop named at it stops
nothing, so what one session runs is not another's to see or end."
  (harness-tools-jobs-test-with-jail
    (let* ((other-root (harness-test-temp-dir))
           (other (plist-get (harness-call 'session/create :cwd other-root) :id))
           (first (harness-tools-jobs-test--call sid :action "start"
                                                 :command "echo mine; sleep 120" :timeout 120))
           (id (harness-tools-jobs-test--job-id first)))
      (unwind-protect
          (progn
            (should id)
            ;; The other session's list is empty.
            (should (equal "No jobs in this session"
                           (plist-get (harness-tools-jobs-test--call other :action "list") :content)))
            ;; Its status and logs do not find the job.
            (dolist (action '("status" "logs" "stop"))
              (let ((r (harness-tools-jobs-test--call other :action action :id id)))
                (should (plist-get r :is-error))
                (should (string-search "No job" (plist-get r :content)))))
            ;; And it still runs for the session that owns it.
            (should (eq 'running (plist-get (car (harness-tools-jobs-session-entries sid)) :state)))
            (harness-test-wait
             (lambda ()
               (string-search "mine" (plist-get (harness-tools-jobs-test--call sid :action "logs" :id id)
                                                :content)))
             10 "the job's own session reads its output"))
        (ignore-errors (harness-call 'session/delete other))
        (ignore-errors (delete-directory other-root t))))))

(ert-deftest harness-jobs-a-job-ends-when-its-time-is-up ()
  "A job past its timeout is stopped by the harness, and says why.
The sandbox's own `timeout' ends it at the same moment whatever the
harness is doing, so nothing of it is left for the next call."
  (harness-tools-jobs-test-with-jail
    (let* ((start (float-time))
           (first (harness-tools-jobs-test--call sid :action "start"
                                                 :command "echo started; sleep 60" :timeout 2))
           (id (harness-tools-jobs-test--job-id first)))
      (should id)
      (should (eq 'running (plist-get (car (harness-tools-jobs-session-entries sid)) :state)))
      ;; A job whose cancel the harness has asked for reads as stopped at
      ;; once -- that is the session's answer -- while the run itself ends
      ;; a moment later, when the supervisor reports what it ended and
      ;; what is left.  The reason therefore comes with the report, not
      ;; with the job's state, and this waits for the reason rather than
      ;; reading it the instant the state changes.
      (harness-test-wait
       (lambda ()
         (let ((entry (car (harness-tools-jobs-session-entries sid))))
           (and entry (eq 'stopped (plist-get entry :state))
                (string-search "timeout" (or (plist-get entry :reason) "")))))
       30 "the job stopped at its timeout, and said why")
      (should (< (float-time) (+ start 30)))
      (let ((entry (car (harness-tools-jobs-session-entries sid))))
        (should (string-search "timeout" (or (plist-get entry :reason) "")))
        ;; And the run it was has really ended: the report says so.
        (should (eq 'stopped
                    (harness-sandbox-session-run-state
                     (plist-get (gethash id harness-tools-jobs--jobs) :run))))))))

(ert-deftest harness-jobs-a-job-ends-with-its-session ()
  "Deleting a session stops its jobs, and closing it does too.
Nothing of a session outlives the session: the sandbox's init goes, and
the kernel ends the processes of its namespace with it."
  (harness-tools-jobs-test-with-jail
    (let* ((first (harness-tools-jobs-test--call sid :action "start"
                                                 :command "sleep 120" :timeout 120))
           (id (harness-tools-jobs-test--job-id first))
           (sandbox-proc (harness-tools-jobs-test--sandbox-process sid)))
      (should id)
      (should (harness-tools-jobs-test--running-p id))
      (should (process-live-p sandbox-proc))
      (harness-call 'session/delete sid)
      (harness-test-wait (lambda () (not (process-live-p sandbox-proc))) 10
                         "the session's sandbox, and its job, gone")
      (should-not (process-live-p sandbox-proc))
      (should-not (gethash id harness-tools-jobs--jobs)))
    ;; A session that is closed stops them the same way.
    (let* ((sid2 (plist-get (harness-call 'session/create :cwd root) :id))
           (first (harness-tools-jobs-test--call sid2 :action "start"
                                                 :command "sleep 120" :timeout 120))
           (id (harness-tools-jobs-test--job-id first))
           (sandbox-proc (harness-tools-jobs-test--sandbox-process sid2)))
      (should (process-live-p sandbox-proc))
      (harness-call 'session/deactivate sid2)
      (harness-test-wait (lambda () (not (process-live-p sandbox-proc))) 10
                         "the session's sandbox, and its job, gone")
      (should-not (process-live-p sandbox-proc)))))

(ert-deftest harness-jobs-a-permission-change-rebuilds-or-stops-a-job ()
  "A change to what a session may reach restarts its job in the new sandbox.
The mounts of a sandbox are fixed when it starts, so a session given a
directory later must not keep a job that cannot see it, and a session
turned read-only must not keep one that can write: the job is run again
in the profile the session has now.  A change that leaves no profile at
all stops it with the reason, so nothing keeps authority the session no
longer has."
  (harness-tools-jobs-test-with-jail
    (let* ((first (harness-tools-jobs-test--call sid :action "start"
                                                 :command "echo up; sleep 120" :timeout 120))
           (id (harness-tools-jobs-test--job-id first))
           (job (gethash id harness-tools-jobs--jobs))
           (sandbox (harness-sandbox-session-sandbox sid))
           (before (plist-get sandbox :process)))
      (should id)
      (should (process-live-p before))
      ;; The command has said what it says before anything changes.
      (harness-test-wait
       (lambda ()
         (with-temp-buffer
           (insert (or (plist-get (harness-tools-jobs-test--call sid :action "logs" :id id)
                                  :content)
                       ""))
           (goto-char (point-min))
           (>= (how-many "^up$") 1)))
       10 "the command's first line")
      ;; A change that leaves the profile alone rebuilds nothing.
      (harness-emit 'access/changed sid)
      (should (< (or (plist-get (car (harness-tools-jobs-session-entries sid)) :restarts) 0) 1))
      (should (eq before (plist-get (harness-sandbox-session-sandbox sid) :process)))
      ;; A change the sandbox cannot absorb rebuilds it, and the job runs
      ;; again in the new one.  A directory granted to the session is such
      ;; a change: the sandbox mounts it, and it is fixed once built.
      (let ((granted (file-name-as-directory (harness-test-temp-dir))))
        (harness-call 'permission/allow-dir sid granted 'session)
        (harness-emit 'access/changed sid)
        (harness-test-wait
         (lambda ()
           (let ((entry (car (harness-tools-jobs-session-entries sid))))
             (and entry (>= (or (plist-get entry :restarts) 0) 1))))
         30 "the job restarted")
        (let ((entry (car (harness-tools-jobs-session-entries sid))))
          (should (>= (plist-get entry :restarts) 1))
          (should (eq 'running (plist-get entry :state)))
          ;; The command ran again in the new sandbox, and its earlier
          ;; output is still in the log under it.
          (harness-test-wait
           (lambda ()
             ;; The command said "up" once in each run, and the log has
             ;; both lines: what the first run said is not lost.
             (with-temp-buffer
               (insert (or (plist-get (harness-tools-jobs-test--call sid :action "logs" :id id)
                                      :content)
                           ""))
               (goto-char (point-min))
               (>= (how-many "^up$") 2)))
           20 "the command ran again")
          ;; The earlier run's output is the log's too, not lost by the
          ;; restart.
          (should (string-search "up"
                                 (plist-get (harness-tools-jobs-test--call sid :action "logs" :id id)
                                            :content))))))))

(ert-deftest harness-jobs-a-session-that-may-no-longer-run-stops-its-job ()
  "A session that may no longer have a sandbox stops its job, saying why.
The `off' policy leaves nothing that could hold the job: the sandbox ends
and takes the run with it, and the job is stopped with the session's own
reason rather than left looking like one that broke."
  (harness-tools-jobs-test-with-jail
    (let* ((first (harness-tools-jobs-test--call sid :action "start"
                                                 :command "echo up; sleep 120" :timeout 120))
           (id (harness-tools-jobs-test--job-id first))
           (sandbox (harness-sandbox-session-sandbox sid))
           (before (plist-get sandbox :process)))
      (should id)
      (should (process-live-p before))
      (let ((harness-sandbox-policy 'off))
        (harness-emit 'access/changed sid)
        (harness-test-wait (lambda () (not (process-live-p before))) 30
                           "the session's sandbox ended")
        (harness-test-wait
         (lambda ()
           (let ((entry (car (harness-tools-jobs-session-entries sid))))
             (and entry (eq 'stopped (plist-get entry :state)))))
         30 "the job stopped when its session could not have a sandbox")
        (let ((entry (car (harness-tools-jobs-session-entries sid))))
          (should (eq 'stopped (plist-get entry :state)))
          ;; The reason is the session's own, as the header of a refused
          ;; call reads it: the policy, not "Harness error" around it.
          (should (string-search "harness-sandbox-policy is `off'" (or (plist-get entry :reason) "")))
          (should-not (string-match-p "Harness error" (or (plist-get entry :reason) ""))))))))

(ert-deftest harness-jobs-a-job-with-a-changed-mount-is-its-own-namespace ()
  "A job is confined as a bash command of its session is.
The job sees the session's directories and not what the jail hides: a
file outside them is not readable from it, which is what makes it safe
to leave a process running there rather than run it plainly."
  (harness-tools-jobs-test-with-jail
    (let* ((outside (harness-test-temp-dir))
           (marker (format "job-secret-%s" (harness-short-id 10)))
           (secret (expand-file-name "secret.txt" outside))
           (first nil) (id nil))
      (unwind-protect
          (progn
            (with-temp-file secret (insert marker "\n"))
            (setq first (harness-tools-jobs-test--call
                         sid :action "start"
                         :command (format "cat %s 2>&1; echo; printf 'pid-1: '; cat /proc/1/comm; sleep 60"
                                          (shell-quote-argument secret))
                         :timeout 120)
                  id (harness-tools-jobs-test--job-id first))
            (should id)
            ;; Wait for the process name itself, not the `pid-1' prefix
            ;; the command prints before it: the log holds the prefix as
            ;; soon as its bytes arrive, and the name is still a read
            ;; behind it on a loaded machine.  A wait weaker than what
            ;; the assertion reads passes there and fails on the check.
            (harness-test-wait
             (lambda ()
               (string-match-p "pid-1: bwrap"
                               (or (plist-get (harness-tools-jobs-test--call sid :action "logs" :id id)
                                              :content)
                                   "")))
             20 "the job's own sandbox reported itself")
            (let ((log (plist-get (harness-tools-jobs-test--call sid :action "logs" :id id) :content)))
              (should-not (string-search marker log))
              ;; The job's PID 1 is its sandbox, not the harness's.
              (should (string-match-p "pid-1: bwrap" log))))
        (ignore-errors (harness-call 'session/delete sid))
        (ignore-errors (delete-directory outside t))))))

(ert-deftest harness-jobs-a-start-that-cannot-run-leaves-no-job ()
  "A start whose command cannot be wrapped, or whose directory is gone, keeps nothing.
A job that never started must not be listed, and must not count against
the session's jobs."
  (harness-tools-jobs-test-with-jail
    (let ((r (harness-tools-jobs-test--call sid :action "start" :command "true"
                                            :cwd (expand-file-name "no-such-dir" root))))
      (should (plist-get r :is-error))
      (should (string-search "Working directory does not exist" (plist-get r :content))))
    (should (= 0 (hash-table-count harness-tools-jobs--jobs)))
    (should (equal "No jobs in this session"
                   (plist-get (harness-tools-jobs-test--call sid :action "list") :content)))
    ;; A job a session has no room for is refused, with the way out.
    (let ((harness-tools-jobs-max-per-session 1)
          (first (harness-tools-jobs-test--call sid :action "start" :command "sleep 60")))
      (should (harness-tools-jobs-test--job-id first))
      (unwind-protect
          (let ((second (harness-tools-jobs-test--call sid :action "start" :command "sleep 60")))
            (should (plist-get second :is-error))
            (should (string-search "its most" (plist-get second :content))))
        (harness-tools-jobs--stop-all sid "the test is done")))))

(ert-deftest harness-jobs-a-job-of-another-host-is-refused ()
  "A remote directory is refused: a job there would run outside the sandbox.
Remote commands are not sandboxed at all, so nothing would confine a job
that outlives its call, or end it with the session.  The refusal is the
job's own, before any call to the host: nothing connects to it."
  (harness-tools-jobs-test--setup)
  (harness-tools-jobs-test-in-dir
    (let* ((sid (plist-get (harness-call 'session/create :cwd root) :id))
           (ctx (list :session-id sid :cwd root)))
      (unwind-protect
          (progn
            ;; The check itself, with no call and no connection.
            (should (string-search "another host"
                                   (or (harness-tools-jobs--backend-problem
                                        "/ssh:some-host:/tmp/")
                                       "")))
            (should (string-search "another host"
                                   (or (harness-tools-jobs--confinement-problem
                                        "/ssh:some-host:/tmp/")
                                       "")))
            ;; And the tool: a start in a remote directory is refused, and
            ;; the job's own directory check is what says so.
            (let ((r (condition-case err
                         (progn (harness-tools-jobs--cwd (list :cwd "/ssh:some-host:/tmp/") ctx)
                                nil)
                       (error (harness-error-message err)))))
              (should r)
              (should (string-search "another host" r)))
            (should (= 0 (hash-table-count harness-tools-jobs--jobs))))
        (ignore-errors (harness-call 'session/delete sid))))))

;;;; The ways a job ends, and what it says

(ert-deftest harness-jobs-a-job-ends-when-its-task-is-done ()
  "A task's job stops when the task is done: the work it served is over.
The job is the session's, and a session whose task is done has nobody
left to reach it, so it ends rather than run to its timeout."
  (harness-tools-jobs-test-with-jail
    (let* ((first (harness-tools-jobs-test--call sid :action "start"
                                                 :command "sleep 120" :timeout 120))
           (id (harness-tools-jobs-test--job-id first))
           (sandbox-proc (harness-tools-jobs-test--sandbox-process sid)))
      (should (process-live-p sandbox-proc))
      (harness-emit 'task/done (list :id "t-whatever" :session sid) 'verified)
      (harness-test-wait (lambda () (not (process-live-p sandbox-proc))) 10
                         "the session's sandbox, and its job, gone")
      (should-not (process-live-p sandbox-proc))
      (let ((entry (car (harness-tools-jobs-session-entries sid))))
        (should (eq 'stopped (plist-get entry :state)))
        (should (string-search "its task is done" (or (plist-get entry :reason) ""))))
      ;; A task whose session is not this one's stops nothing here.
      (let* ((second (harness-tools-jobs-test--call sid :action "start"
                                                    :command "sleep 120" :timeout 120))
             (id2 (harness-tools-jobs-test--job-id second))
             (proc2 (plist-get (gethash id2 harness-tools-jobs--jobs) :process)))
        (harness-emit 'task/done (list :id "t-other" :session "some-other-session") 'verified)
        (should (process-live-p proc2))
        (harness-tools-jobs--stop-all sid "the test is done")))))

(ert-deftest harness-jobs-a-job-ends-when-the-harness-shuts-down ()
  "Shutting the module down stops every job, and its timer.
Nothing of a session's may outlive the harness: a job whose module is
gone has nobody to stop it, so the shutdown does."
  (harness-tools-jobs-test-with-jail
    (let* ((first (harness-tools-jobs-test--call sid :action "start"
                                                 :command "sleep 120" :timeout 120))
           (id (harness-tools-jobs-test--job-id first))
           (sandbox-proc (harness-tools-jobs-test--sandbox-process sid)))
      (should (process-live-p sandbox-proc))
      (should (timerp harness-tools-jobs--timer))
      (harness-tools-jobs--shutdown)
      ;; What the job ran stops with the module; the session's sandbox is
      ;; the session's, and the module that holds it ends it.
      (should-not (harness-tools-jobs-test--running-p id))
      (should-not harness-tools-jobs--timer)
      (let ((entry (car (harness-tools-jobs-session-entries sid))))
        (should (eq 'stopped (plist-get entry :state)))
        (should (string-search "the harness is shutting down" (or (plist-get entry :reason) ""))))
      ;; The module initialises again, and the timer is back for the
      ;; rest of the suite.
      (harness-tools-jobs--init)
      (should (timerp harness-tools-jobs--timer)))))

(ert-deftest harness-jobs-restart-runs-the-command-again-and-says-so ()
  "The restart action re-runs a job's command, counts it and keeps the log.
A session whose job was left in a bad state, or whose sandbox it wants
built again, restarts it rather than starting another: the same id, the
same command, one more run, and what the first run said is still there."
  (harness-tools-jobs-test-with-jail
    (let* ((first (harness-tools-jobs-test--call sid :action "start"
                                                 :command "echo run-one; sleep 120" :timeout 120))
           (id (harness-tools-jobs-test--job-id first))
           ;; A job of the session's shared sandbox has no process of its
           ;; own: what a restart replaces is its run in that sandbox, and
           ;; the sandbox itself goes on serving the session's calls.
           (before (plist-get (gethash id harness-tools-jobs--jobs) :run)))
      ;; The first run said its line before the restart.
      (harness-test-wait
       (lambda ()
         (string-search "run-one"
                        (plist-get (harness-tools-jobs-test--call sid :action "logs" :id id)
                                   :content)))
       10 "the first run's line")
      (let ((r (harness-tools-jobs-test--call sid :action "restart" :id id)))
        (should-not (plist-get r :is-error))
        (should (string-search id (plist-get r :content))))
      (let ((job (gethash id harness-tools-jobs--jobs)))
        (should job)
        (should (eq 'running (plist-get job :state)))
        (should (= 1 (plist-get job :restarts)))
        (should before)
        (should-not (eq before (plist-get job :run)))
        ;; One sandbox still: a restart runs in the session's, not a new one.
        (should (eq (plist-get job :process)
                    (harness-tools-jobs-test--sandbox-process sid))))
      ;; The second run is in the log under the first one's line.
      (harness-test-wait
       (lambda ()
         (let ((log (plist-get (harness-tools-jobs-test--call sid :action "logs" :id id) :content)))
           (and (string-search "run-one" log)
                (>= (with-temp-buffer (insert (or log ""))
                                     (goto-char (point-min))
                                     (how-many "^run-one$"))
                    2))))
       20 "the command ran again")
      ;; One job, not two: a restart is the same job.
      (should (= 1 (length (harness-tools-jobs-session-entries sid))))
      (harness-tools-jobs--stop-all sid "the test is done"))))

(ert-deftest harness-jobs-logs-returns-the-lines-asked-for ()
  "The logs action returns the last lines it was asked for, and its default.
A long-running job writes a lot; a caller reading it back says how much
it wants, and gets the tail of it rather than the whole log."
  (harness-tools-jobs-test-with-jail
    (let* ((first (harness-tools-jobs-test--call
                   sid :action "start" :timeout 120
                   :command "for n in 1 2 3 4 5 6 7 8 9 10; do echo line-$n; done; sleep 120"))
           (id (harness-tools-jobs-test--job-id first))
           (lines-of (lambda (text)
                       (with-temp-buffer
                         (insert (or text ""))
                         (goto-char (point-min))
                         (let (out)
                           (while (re-search-forward "^line-\\([0-9]+\\)$" nil t)
                             (push (string-to-number (match-string 1)) out))
                           (nreverse out))))))
      (should id)
      (harness-test-wait
       (lambda () (>= (length (funcall lines-of
                                       (plist-get (harness-tools-jobs-test--call
                                                   sid :action "logs" :id id :lines 100)
                                                  :content)))
                      10))
       20 "the command's ten lines")
      ;; Three lines are the last three.
      (let ((tail (funcall lines-of (plist-get (harness-tools-jobs-test--call
                                                sid :action "logs" :id id :lines 3)
                                               :content))))
        (should (<= (length tail) 3))
        (should (equal '(10) (last tail))))
      ;; And asking for more than there are returns them all.
      (let ((all (funcall lines-of (plist-get (harness-tools-jobs-test--call
                                               sid :action "logs" :id id :lines 1000)
                                              :content))))
        (should (= 10 (length all)))
        (should (equal (number-sequence 1 10) all)))
      (harness-tools-jobs--stop-all sid "the test is done"))))

;;;; Confinement is the job's own directory, on every spawn

(ert-deftest harness-jobs-a-project-that-says-off-refuses-a-job ()
  "A project whose own settings turn the sandbox off refuses a job there.
The review's first finding: `sandbox/status' reports the *global* policy,
while `sandbox/wrap' reads the policy of the directory it is given, so a
project whose .dir-locals.el says `off' would pass a global check and a
job there would run unconfined.  The check is the effective one for the
job's directory, and the start fails closed with nothing spawned."
  (harness-tools-jobs-test-with-jail
    (let* ((project (file-name-as-directory (harness-test-temp-dir)))
           (gated (file-name-as-directory (expand-file-name "gated" project))))
      (unwind-protect
          (progn
            (make-directory gated t)
            (make-directory (expand-file-name ".git" project) t)
            (with-temp-file (expand-file-name ".dir-locals.el" gated)
              (insert "((nil . ((harness-sandbox-policy . off))))\n"))
            (let* ((psid (plist-get (harness-call 'session/create :cwd project) :id))
                   (r (harness-tools-jobs-test--call psid :action "start" :command "sleep 30"
                                                      :cwd (expand-file-name "gated" project))))
              (unwind-protect
                  (progn
                    ;; The global view says bwrap, required: the refusal
                    ;; can only come from the directory's own policy.
                    (should (eq 'bwrap (plist-get (harness-call 'sandbox/status) :backend)))
                    (should (string-search "`off'" (or (harness-tools-jobs--backend-problem gated) "")))
                    (should (plist-get r :is-error))
                    (should (string-search "`off'" (plist-get r :content)))
                    ;; The policy of the project itself is what it was.
                    (should (eq 'required
                                (harness-call 'config/get 'harness-sandbox-policy project)))
                    ;; Nothing was spawned: no job, no process.
                    (should (= 0 (length (harness-tools-jobs-session-entries psid)))))
                (harness-tools-jobs--stop-all psid "the test is done")
                (ignore-errors (harness-call 'session/delete psid)))))
        (ignore-errors (delete-directory project t))))))

(ert-deftest harness-jobs-a-global-off-policy-refuses-a-job ()
  "With the sandbox off everywhere, a job is refused before it starts.
The same finding from the other side: the global policy is the
directory's policy when the directory has none of its own, and the
refusal names it, so no start can spawn an unconfined job."
  (harness-tools-jobs-test--setup)
  (harness-tools-jobs-test-in-dir
    (let* ((harness-sandbox-policy 'off)
           (sid (plist-get (harness-call 'session/create :cwd root) :id))
           (r (harness-tools-jobs-test--call sid :action "start" :command "sleep 30")))
      (unwind-protect
          (progn
            (should (plist-get r :is-error))
            (should (string-search "`off'" (plist-get r :content)))
            (should (= 0 (hash-table-count harness-tools-jobs--jobs))))
        (ignore-errors (harness-call 'session/delete sid))))))

(ert-deftest harness-jobs-a-backend-that-cannot-hold-one-refuses-a-restart ()
  "A restart under a backend that cannot hold a job is refused, not revived.
The review's finding on the restart path: it built a profile and spawned,
without asking whether a job can run at all, so a job started under bwrap
could be restarted under the `off' policy or systemd-run.  A restart
asks the same question a start does, and a job that cannot be restarted
is stopped with the reason rather than left running or spawned anew."
  (harness-tools-jobs-test-with-jail
    (let* ((first (harness-tools-jobs-test--call sid :action "start"
                                                 :command "echo once; sleep 120" :timeout 120))
           (id (harness-tools-jobs-test--job-id first))
           (job (gethash id harness-tools-jobs--jobs))
           (proc (plist-get job :process)))
      (should id)
      (should (process-live-p proc))
      ;; The backend is systemd-run now: one that cannot hold a job.
      (harness-tools-jobs-test-with-methods
          (list (cons 'sandbox/status
                      (lambda () (list :backend 'systemd :available '(systemd)
                                       :policy 'required :limits nil)))
                (cons 'sandbox/hold
                      (lambda (&rest _) (harness-tools-jobs-test--hold-of 'systemd))))
        (let ((r (harness-tools-jobs-test--call sid :action "restart" :id id)))
          (should (plist-get r :is-error))
          (should (string-search "its unit has no PID namespace of its own"
                                 (plist-get r :content))))
        ;; The job stops: what it ran ends, while the session's runtime,
        ;; which is not the job's, keeps going.
        (harness-test-wait (lambda () (not (harness-tools-jobs-test--running-p id))) 10
                           "the job stopped")
        (should (process-live-p proc))
        (let ((entry (car (harness-tools-jobs-session-entries sid))))
          (should (eq 'stopped (plist-get entry :state)))
          (should (string-search "its restart failed" (or (plist-get entry :reason) ""))))
        ;; A start under it is refused too, with the reason.
        (let ((s (harness-tools-jobs-test--call sid :action "start" :command "sleep 30")))
          (should (plist-get s :is-error))
          (should (string-search "cannot hold a job" (plist-get s :content)))))
      (harness-tools-jobs--stop-all sid "the test is done"))))

(ert-deftest harness-jobs-the-built-command-is-what-is-checked ()
  "The command that would run is the check, not only the backend's description.
`harness-tools-jobs--confinement-problem' asks `sandbox/profiles' about
the job's directory, builds the command `sandbox/wrap' would run there,
and asks `sandbox/hold' what that backend promises: a command that comes
back unchanged -- what the `off' policy, a remote directory or no backend
give -- is refused, and so is a backend that cannot promise a job's stop,
whichever half says so.  Neither half is a program name: a backend this
module has never heard of is allowed by what it promises and refused by
what it does not."
  (harness-tools-jobs-test--setup)
  (harness-tools-jobs-test-in-dir
    (let ((sid (plist-get (harness-call 'session/create :cwd root) :id)))
      (unwind-protect
          (progn
            ;; The wrap is the command itself: unconfined.
            (harness-tools-jobs-test-with-methods
                (list (cons 'sandbox/status
                            (lambda () (list :backend 'bwrap :available '(bwrap)
                                             :policy 'required :limits nil)))
                      (cons 'sandbox/profiles
                            (lambda (&optional _cwd)
                              (list :backend 'bwrap :profiles '(default) :hide t :why nil)))
                      (cons 'sandbox/wrap (lambda (_cwd command &rest _opts) command)))
              (should (string-search "unconfined"
                                     (or (harness-tools-jobs--confinement-problem root) ""))))
            ;; The command is confined, but the backend promises no
            ;; verifiable cancel: a job there is refused with its reason,
            ;; though neither the profile nor the wrap said anything.
            (harness-tools-jobs-test-with-methods
                (list (cons 'sandbox/status
                            (lambda () (list :backend 'systemd :available '(systemd)
                                             :policy 'required :limits nil)))
                      (cons 'sandbox/profiles
                            (lambda (&optional _cwd)
                              (list :backend 'systemd :profiles '(default) :hide t :why nil)))
                      (cons 'sandbox/wrap (lambda (_cwd command &rest _opts)
                                            (cons "held-command" command)))
                      (cons 'sandbox/hold
                            (lambda (&rest _) (harness-tools-jobs-test--hold-of 'systemd))))
              (should (string-search "cannot hold a job"
                                     (or (harness-tools-jobs--confinement-problem root) ""))))
            ;; One that promises all of it is confined: no complaint,
            ;; though this module knows nothing of the backend's name.
            (harness-tools-jobs-test-with-methods
                (list (cons 'sandbox/status
                            (lambda () (list :backend 'quux :available '(quux)
                                             :policy 'required :limits nil)))
                      (cons 'sandbox/profiles
                            (lambda (&optional _cwd)
                              (list :backend 'quux :profiles '(default) :hide t :why nil)))
                      (cons 'sandbox/wrap (lambda (_cwd command &rest _opts)
                                            (cons "held-command" command)))
                      (cons 'sandbox/hold
                            (lambda (&rest _) (list :command (list "held-command")
                                                    :backend 'quux
                                                    :capabilities
                                                    '(:exec t :stream t :cancel t
                                                      :enumerate t :destroy t)))))
              (should-not (harness-tools-jobs--confinement-problem root))))
        (ignore-errors (harness-call 'session/delete sid))))))

;;;; The directory a job may still run in

(ert-deftest harness-jobs-a-revoked-directory-stops-the-job ()
  "A job started in a directory the session only had by grant stops when the grant goes.
The review's second finding: the job keeps its cwd, and bwrap mounts the
cwd writable at its own path, so a grant revoked while a job ran was
mounted again by the next restart.  The directory is authorised against
`permission/dirs' before every spawn, and a job whose directory the
session lost is stopped with the reason instead of being rebuilt there."
  (harness-tools-jobs-test-with-jail
    (let* ((outside (file-name-as-directory (harness-test-temp-dir)))
           (id nil) (proc nil))
      (unwind-protect
          (progn
            ;; The session may write OUTSIDE only because it was granted.
            (harness-call 'permission/allow-dir sid outside 'session)
            (let* ((started (harness-tools-jobs-test--call
                             sid :action "start" :timeout 120
                             :command "echo in-the-grant; sleep 120"
                             :cwd outside)))
              (setq id (harness-tools-jobs-test--job-id started)
                    proc (plist-get (gethash id harness-tools-jobs--jobs) :process))
              (should id)
              (should (process-live-p proc))
              (should (equal outside (plist-get (gethash id harness-tools-jobs--jobs) :cwd)))
              ;; The grant goes; the directory is not the session's any more.
              (harness-call 'permission/revoke-dir sid outside)
              (should-not (harness-tools-jobs--cwd-authorized-p
                           outside (plist-get (gethash id harness-tools-jobs--jobs) :ctx)))
              (harness-emit 'permission/dir-revoked sid outside)
              (harness-test-wait (lambda () (not (process-live-p proc))) 15
                                 "the job in the revoked directory stopped")
              (should-not (process-live-p proc))
              (let ((entry (car (harness-tools-jobs-session-entries sid))))
                (should (eq 'stopped (plist-get entry :state)))
                (should (string-search "may no longer reach" (or (plist-get entry :reason) ""))))
              ;; And a restart does not bring it back.
              (let ((r (harness-tools-jobs-test--call sid :action "restart" :id id)))
                (should (plist-get r :is-error))
                (should (string-search "may no longer reach" (plist-get r :content))))
              (should-not (process-live-p proc))
              (let ((entry (car (harness-tools-jobs-session-entries sid))))
                (should (eq 'stopped (plist-get entry :state))))))
        (harness-tools-jobs--stop-all sid "the test is done")
        (ignore-errors (harness-call 'session/delete sid))
        (ignore-errors (delete-directory outside t))))))

(ert-deftest harness-jobs-a-session-that-moves-stops-its-job ()
  "A job stops when its session moves, and a restart does not run it in the old place.
The review's second finding, the move form: the job's context and
directory were those of the call that started it, so a session moved
elsewhere could restart a job in the directory it no longer works in.
`session/moved' stops the jobs, and the spawn path authorises the
directory again, so neither a handler that did not run nor a restart can
put a job back where the session was."
  (harness-tools-jobs-test-with-jail
    (let* ((moved-to (file-name-as-directory (harness-test-temp-dir)))
           (first (harness-tools-jobs-test--call sid :action "start"
                                                 :command "sleep 120" :timeout 120))
           (id (harness-tools-jobs-test--job-id first))
           (sandbox-proc (harness-tools-jobs-test--sandbox-process sid)))
      (unwind-protect
          (progn
            (should (process-live-p sandbox-proc))
            (harness-call 'session/move sid moved-to)
            (harness-test-wait (lambda () (not (process-live-p sandbox-proc))) 10
                               "the session's sandbox, and its job, gone on the move")
            (should-not (process-live-p sandbox-proc))
            (let ((entry (car (harness-tools-jobs-session-entries sid))))
              (should (eq 'stopped (plist-get entry :state)))
              ;; The move handler stops it, or the directory check does
              ;; when the handler ran second: either names the change.
              (should (or (string-search "moved" (or (plist-get entry :reason) ""))
                          (string-search "may no longer" (or (plist-get entry :reason) "")))))
            ;; A restart does not run in the directory the session left.
            (let ((r (harness-tools-jobs-test--call sid :action "restart" :id id)))
              (should (plist-get r :is-error))
              (should (string-search "may no longer reach" (plist-get r :content))))
            (should-not (process-live-p sandbox-proc)))
        (harness-tools-jobs--stop-all sid "the test is done")
        (ignore-errors (harness-call 'session/delete sid))
        (ignore-errors (delete-directory moved-to t))))))

;;;; Every access input is in what is compared

(ert-deftest harness-jobs-a-read-only-mount-taken-away-cannot-be-read ()
  "A global read-only directory removed from the settings is gone from a running job.
The review's third finding: `harness-sandbox-extra-read-only-dirs' is
consumed by `sandbox/wrap' itself, not by the profile the job compared,
so taking it away left the mount in place with the profiles still equal.
The value is part of the profile now, so removing it rebuilds the job, and
the test proves the old path cannot be read rather than that a counter
moved: the first run's output has the file's text and the second run's
has the reader's error."
  (harness-tools-jobs-test-with-jail
    (let* ((shared (file-name-as-directory (harness-test-temp-dir)))
           (marker (format "mounted-for-now-%s" (harness-short-id 8)))
           (file (expand-file-name "readable.txt" shared))
           (harness-sandbox-extra-read-only-dirs (list shared))
           (id nil) (proc nil)
           (seen nil))
      (unwind-protect
          (progn
            (with-temp-file file (insert marker "\n"))
            (let* ((started (harness-tools-jobs-test--call
                             sid :action "start" :timeout 120
                             :command (format "cat %s 2>&1; echo; exec sleep 120"
                                              (shell-quote-argument file))))
                   (log (lambda ()
                          (plist-get (harness-tools-jobs-test--call sid :action "logs" :id id
                                                                    :lines 400)
                                     :content))))
              (setq id (harness-tools-jobs-test--job-id started)
                    proc (plist-get (gethash id harness-tools-jobs--jobs) :process))
              (should (process-live-p proc))
              ;; It reads what the setting mounts read-only.
              (harness-test-wait (lambda () (string-search marker (or (funcall log) ""))) 20
                                 "the job read the read-only directory")
              ;; Take the mount away: the profile changes and the job is
              ;; rebuilt without it.
              (setq harness-sandbox-extra-read-only-dirs nil)
              (harness-emit 'config/changed 'harness-sandbox-extra-read-only-dirs)
              (harness-test-wait
               (lambda ()
                 (let ((text (funcall log)))
                   (and text
                        (>= (or (plist-get (car (harness-tools-jobs-session-entries sid))
                                           :restarts)
                                0)
                            1))))
               30 "the job restarted without the mount")
              ;; The restarted job cannot read the file: its reader says
              ;; so, and no second copy of the marker is written.
              (harness-test-wait
               (lambda ()
                 (string-search "No such file or directory" (or (funcall log) "")))
               20 "the restarted job could not read the path")
              (setq seen (funcall log))
              (with-temp-buffer
                (insert (or seen ""))
                (goto-char (point-min))
                ;; One run saw the file; the other was refused it.
                (should (= 1 (how-many (regexp-quote marker)))))
              (should (string-search "No such file or directory" seen))))
        (harness-tools-jobs--stop-all sid "the test is done")
        (ignore-errors (harness-call 'session/delete sid))
        (ignore-errors (delete-directory shared t))))))

(ert-deftest harness-jobs-a-read-only-session-keeps-no-write-authority ()
  "A session made read-only keeps no job that can write, and cannot start one.
The review's sixth finding asked for a read-only change that is real.  A
read-only session has no shared runtime -- it keeps a sandbox of its own
per call, with a /tmp of its own (`harness-sandbox-session-problem') --
so the job it was running has nowhere to run: it is stopped, its reason is
the session's own, and what it had written stays where it wrote it.  The
tool is not offered either: a read-only session may only read, and a call
that asks anyway is refused with the session's own reason.  Writing back
restores both.  The network is measured the same way, as a second access
input a change of which restarts a job that can still have a sandbox."
  (harness-tools-jobs-test-with-jail
    (let* ((id nil) (proc nil)
           (command "printf 'can-write\\n' > wrote.txt 2>&1; cat wrote.txt 2>&1; echo ---; exec sleep 120"))
      (unwind-protect
          (progn
            (let* ((started (harness-tools-jobs-test--call sid :action "start" :timeout 120
                                                           :command command))
                   (text (lambda ()
                           ;; Read from the harness's side, not through the
                           ;; tool: a read-only session may not call it.
                           (let ((entry (car (harness-tools-jobs-session-entries sid))))
                             (and entry (harness-tools-jobs-log-text entry 400))))))
              (setq id (harness-tools-jobs-test--job-id started)
                    proc (plist-get (gethash id harness-tools-jobs--jobs) :process))
              (should (process-live-p proc))
              ;; It can write while the session may.
              (harness-test-wait (lambda () (file-exists-p (expand-file-name "wrote.txt" root)))
                                 20 "the writable job wrote its file")
              (harness-test-wait (lambda () (string-search "can-write" (or (funcall text) "")))
                                 20 "the job's log has what it wrote")
              (delete-file (expand-file-name "wrote.txt" root))
              ;; Read-only now: a read-only session has no shared sandbox,
              ;; so the job has nowhere to run and stops, saying so.
              (harness-call 'access/set-read-only sid t)
              (harness-emit 'access/changed sid)
              (harness-test-wait
               (lambda ()
                 (let ((entry (car (harness-tools-jobs-session-entries sid))))
                   (and entry (eq 'stopped (plist-get entry :state)))))
               30 "the job stopped when its session turned read-only")
              (let ((entry (car (harness-tools-jobs-session-entries sid))))
                (should (eq 'stopped (plist-get entry :state)))
                (should (string-search "read-only session"
                                       (downcase (or (plist-get entry :reason) ""))))
                ;; What it wrote before the change is still there to read.
                (should (string-search "can-write" (or (funcall text) ""))))
              (should-not (file-exists-p (expand-file-name "wrote.txt" root)))
              ;; And the session cannot start one at all: the tool is not
              ;; offered, and the call is refused with the reason.
              (should-not (member "bash_job"
                                  (mapcar (lambda (spec) (plist-get spec :name))
                                          (harness-call 'tools/list sid))))
              (let ((r (harness-tools-jobs-test--call sid :action "start" :command "sleep 30")))
                (should (plist-get r :is-error))
                (should (string-search "read-only" (plist-get r :content))))
              ;; Writing back, the tool and a writable job come back.
              (harness-call 'access/set-read-only sid nil)
              (should (member "bash_job"
                              (mapcar (lambda (spec) (plist-get spec :name))
                                      (harness-call 'tools/list sid))))
              (let* ((again (harness-tools-jobs-test--call sid :action "start" :timeout 60
                                                           :command "exec sleep 60"))
                     (id2 (harness-tools-jobs-test--job-id again)))
                (should id2)
                (should (harness-tools-jobs-test--running-p id2))
                (harness-tools-jobs--stop-all sid "the test is done"))
              ;; The network is another input: cutting it rebuilds the job.
              (let* ((netted (harness-tools-jobs-test--call sid :action "start" :timeout 60
                                                            :command "exec sleep 60"))
                     (id3 (harness-tools-jobs-test--job-id netted)))
                (should id3)
                (harness-call 'access/set-network sid nil)
                (harness-emit 'access/changed sid)
                (harness-test-wait
                 (lambda ()
                   (>= (or (plist-get (gethash id3 harness-tools-jobs--jobs) :restarts) 0) 1))
                 30 "the offline job restarted")
                ;; The sandbox it runs in is the session's, and its
                ;; profile is what the change made of it: the session's
                ;; commands run offline now, and `:network nil' is how
                ;; the access module says so.
                (let* ((sandbox (harness-sandbox-session-sandbox sid))
                       (options (plist-get (plist-get sandbox :profile) :options)))
                  (should sandbox)
                  (should (equal '(:network nil) options))))))
        (harness-tools-jobs--stop-all sid "the test is done")
        (ignore-errors (harness-call 'session/delete sid))))))

;;;; Pause, cancel and return stop the work, and the processes are gone

(ert-deftest harness-jobs-returning-a-task-stops-its-jobs ()
  "A job stops when its task is returned to the queue, and only that task's.
The review's fourth finding: `task/return-to-pending', `task/pause' and a
pre-emption stop what a session left running through
`agent/stop-outstanding', and the jobs module was not a handler of it, so
a task could be stopped while its server ran on.  The filter is measured
here, and so is the other half: a second session's job is untouched, which
is what \"without stopping unrelated tasks\" asks for."
  (harness-tools-jobs-test-with-jail
    (let* ((other-root (harness-test-temp-dir))
           (other (plist-get (harness-call 'session/create :cwd other-root) :id))
           (mine (harness-tools-jobs-test--call sid :action "start" :command "sleep 120" :timeout 120))
           (theirs (harness-tools-jobs-test--call other :action "start" :command "sleep 120" :timeout 120))
           (my-id (harness-tools-jobs-test--job-id mine))
           (their-id (harness-tools-jobs-test--job-id theirs)))
      (unwind-protect
          (progn
            ;; A job of the shared sandbox is a run in it: what says it is
            ;; running is the run, not a process of its own.  The
            ;; sandboxes go on serving their sessions, as they should.
            (should (harness-tools-jobs-test--running-p my-id))
            (should (harness-tools-jobs-test--running-p their-id))
            ;; What the tasks module calls when it returns or pauses a task.
            (let ((text (harness-call 'agent/stop-outstanding sid "its task waits for a slot")))
              (should (stringp text))
              (should (string-search "Bash 1 job stopped" text)))
            (harness-test-wait (lambda () (not (harness-tools-jobs-test--running-p my-id)))
                               10 "my job stopped")
            (should-not (harness-tools-jobs-test--running-p my-id))
            (let ((entry (car (harness-tools-jobs-session-entries sid))))
              (should (eq 'stopped (plist-get entry :state)))
              (should (string-search "its task waits for a slot" (or (plist-get entry :reason) ""))))
            ;; The other session's job is untouched.
            (should (harness-tools-jobs-test--running-p their-id))
            (should (eq 'running (plist-get (car (harness-tools-jobs-session-entries other))
                                            :state)))
            ;; A session with nothing running says nothing was stopped.
            (should-not (harness-call 'agent/stop-outstanding sid "its task waits for a slot")))
        (harness-tools-jobs--stop-all sid "the test is done")
        (harness-tools-jobs--stop-all other "the test is done")
        (ignore-errors (harness-call 'session/delete other))
        (ignore-errors (delete-directory other-root t))))))

(ert-deftest harness-jobs-a-cancelled-task-stops-its-jobs ()
  "A task the user cancels stops its session's jobs, and says why.
`task/cancel' is not a turn ending: `agent/cancel' lets a turn's gate go,
and the task goes on being a task.  So `task/cancel' emits
`task/cancelled', and the jobs module listens for it: what the session
left running -- a server, a display, a playtest -- stops with the work
the user ended.  The job and its run are what is checked, and the reason
it was stopped is the session's own."
  (harness-tools-jobs-test-with-jail
    (let* ((first (harness-tools-jobs-test--call sid :action "start" :command "sleep 120" :timeout 120))
           (id (harness-tools-jobs-test--job-id first)))
      ;; A cancelled task ends its session's sandbox whole, and the run
      ;; of the job in it with it.
      (should (process-live-p (harness-tools-jobs-test--sandbox-process sid)))
      (harness-emit 'task/cancelled (list :id "t-the-task" :session sid))
      (harness-test-wait (lambda () (not (harness-tools-jobs-test--running-p id))) 10
                         "the cancelled task's job stopped")
      (should-not (harness-tools-jobs-test--running-p id))
      (let ((entry (car (harness-tools-jobs-session-entries sid))))
        (should (eq 'stopped (plist-get entry :state)))
        (should (string-search "its task was cancelled" (or (plist-get entry :reason) ""))))
      ;; A task that is not this session's stops nothing here: the
      ;; session's sandbox is built again for a start, and the second
      ;; job's run goes on as if no cancel had been emitted.
      (let* ((second (harness-tools-jobs-test--call sid :action "start" :command "sleep 120" :timeout 120))
             (id2 (harness-tools-jobs-test--job-id second)))
        (should (harness-tools-jobs-test--running-p id2))
        (harness-emit 'task/cancelled (list :id "t-other" :session "some-other-session"))
        (should (harness-tools-jobs-test--running-p id2)))
      (harness-tools-jobs--stop-all sid "the test is done"))))

(ert-deftest harness-jobs-a-paused-task-takes-its-listener-with-it ()
  "The job a pause stops takes its listening process with it, not just its entry.
A pid that is gone and a state that says `stopped' are not the same thing
as a server that can no longer be reached.  This one starts a listener
that serves a file, proves it answers, pauses the task through the filter
the tasks module calls, and then proves the port is dead from a call that
runs afterwards."
  (harness-tools-jobs-test-with-jail
    (let* ((port (harness-tools-jobs-test--free-port))
           (id nil) (proc nil))
      (unwind-protect
          (progn
            ;; The file the listener serves: what proves it is reachable.
            (with-temp-file (expand-file-name "marker.txt" root)
              (insert "listening\n"))
            (let* ((started (harness-tools-jobs-test--call
                             sid :action "start" :timeout 120
                             :command (format "printf 'up\\n'; exec python3 -m http.server %d --bind 127.0.0.1"
                                              port)))
                   (says (lambda (text)
                           (string-search text
                                          (or (plist-get (harness-tools-jobs-test--call
                                                          sid :action "logs" :id id :lines 40)
                                                         :content)
                                              "")))))
              (setq id (harness-tools-jobs-test--job-id started)
                    proc (plist-get (gethash id harness-tools-jobs--jobs) :process))
              (harness-test-wait (lambda () (funcall says "up")) 20 "the listener started")
              ;; It serves what the session wrote: reachable from a call.
              (harness-test-wait
               (lambda () (string-search "listening" (harness-tools-jobs-test--curl sid port "marker.txt")))
               20 "the job's server answers")
              (harness-call 'agent/stop-outstanding sid "its task was paused")
              (harness-test-wait (lambda () (not (harness-tools-jobs-test--running-p id))) 10
                                 "the job stopped")
              (should-not (harness-tools-jobs-test--running-p id))
              ;; Nothing answers the port from a call that runs after it.
              (harness-test-wait
               (lambda ()
                 (not (string-search "listening" (harness-tools-jobs-test--curl sid port "marker.txt"))))
               15 "the port is dead")
              (should-not (string-search "listening"
                                         (harness-tools-jobs-test--curl sid port "marker.txt")))))
        (harness-tools-jobs--stop-all sid "the test is done")
        (ignore-errors (harness-call 'session/delete sid))))))

;;;; Bounded output, and bounds a restart cannot evade

(ert-deftest harness-jobs-output-is-bounded-and-says-so ()
  "A job that floods its output keeps a bounded buffer and a bounded log.
The review's fifth finding: the filter appended every chunk to a buffer
with no limit, so a noisy job could exhaust the harness process.  The
buffer and the log are cut to `harness-tools-jobs-output-limit' from the
front -- the end is what a caller reads -- and the buffer says how much
went, so a tail is never taken for the whole."
  (harness-tools-jobs-test-with-jail
    (let* ((harness-tools-jobs-output-limit 4096)
           (first (harness-tools-jobs-test--call
                   sid :action "start" :timeout 120
                   :command "for n in $(seq 1 4000); do echo line-$n; done; exec sleep 120"))
           (id (harness-tools-jobs-test--job-id first)))
      (should id)
      (harness-test-wait
       (lambda ()
         (let* ((job (gethash id harness-tools-jobs--jobs))
                (buffer (plist-get job :buffer)))
           (and (buffer-live-p buffer)
                (plist-get job :dropped)
                (with-current-buffer buffer
                  (string-search "line-4000" (buffer-string))))))
       20 "the job finished its flood")
      (let* ((job (gethash id harness-tools-jobs--jobs))
             (buffer (plist-get job :buffer))
             (size (with-current-buffer buffer (buffer-size))))
        ;; The buffer holds no more than the limit and the line saying what
        ;; was dropped, whatever the job printed.
        (should (< size (+ harness-tools-jobs-output-limit 200)))
        (should (with-current-buffer buffer
                  (string-search "of earlier output dropped" (buffer-string))))
        ;; The log is bounded too, and keeps the end: a caller reads the
        ;; last line, and there is only one file however long it runs.
        (let ((log (plist-get job :log)))
          (should (file-exists-p log))
          ;; The file is written while the job runs, so it holds what it
          ;; has said, not only the header of its first moment.
          (harness-test-wait
           (lambda ()
             (with-temp-buffer
               (insert-file-contents log)
               (string-search "line-4000" (buffer-string))))
           20 "the log holds the job's latest output")
          (should (< (file-attribute-size (file-attributes log))
                     (+ harness-tools-jobs-output-limit 400)))
          (with-temp-buffer
            (insert-file-contents log)
            (should (string-search "line-4000" (buffer-string)))
            (should (string-search "of output dropped" (buffer-string))))))
      ;; A restart runs the rest of the job's own time, not another span.
      (let ((deadline (plist-get (gethash id harness-tools-jobs--jobs) :deadline)))
        (should deadline)
        (let ((r (harness-tools-jobs-test--call sid :action "restart" :id id)))
          (should-not (plist-get r :is-error)))
        (should (= deadline (plist-get (gethash id harness-tools-jobs--jobs) :deadline))))
      (harness-tools-jobs--stop-all sid "the test is done"))))

(ert-deftest harness-jobs-a-never-ending-flood-stays-bounded ()
  "A job that prints for as long as it runs is still bounded a moment later.
The bound is not a limit on one write: it has to hold while the output
keeps coming, which is the case a long-running server or playtest makes.
The buffer is read twice, with more output in between, and never grows
past the limit."
  (harness-tools-jobs-test-with-jail
    (let* ((harness-tools-jobs-output-limit 2048)
           (first (harness-tools-jobs-test--call
                   sid :action "start" :timeout 120
                   :command "while true; do echo spam-line; done"))
           (id (harness-tools-jobs-test--job-id first))
           (size (lambda ()
                   (let ((buffer (plist-get (gethash id harness-tools-jobs--jobs) :buffer)))
                     (and (buffer-live-p buffer) (with-current-buffer buffer (buffer-size))))))
           (dropped (lambda () (plist-get (gethash id harness-tools-jobs--jobs) :dropped))))
      (should id)
      (harness-test-wait (lambda () (and (funcall dropped) (> (funcall dropped) 0))) 20
                         "the flood was cut")
      (let ((first-size (funcall size)))
        (should (<= first-size (+ harness-tools-jobs-output-limit 200)))
        (harness-test-wait (lambda () (> (or (funcall dropped) 0) 20000)) 20
                           "a great deal more was printed and dropped")
        ;; Far more output later, and the buffer is the same size but for
        ;; the line at its top saying how much went: that line's own
        ;; length follows the number in it, so a byte or two more is the
        ;; marker, not growth.
        (should (<= (funcall size) (+ harness-tools-jobs-output-limit 200)))
        (should (<= (abs (- first-size (funcall size))) 16)))
      (harness-tools-jobs--stop-all sid "the test is done"))))

(ert-deftest harness-jobs-restarts-stop-at-the-limit ()
  "A job whose sandbox keeps changing is stopped, not restarted for ever.
The review's fifth finding, the capacity half: `access/changed' can come
from any part of the harness, and each restart spawned another process,
so a job could be restarted without end.  Restarts are counted and
capped, and the job is stopped with the reason when the cap is reached."
  (harness-tools-jobs-test-with-jail
    (let* ((harness-tools-jobs-max-restarts 2)
           (first (harness-tools-jobs-test--call sid :action "start"
                                                 :command "sleep 120" :timeout 120))
           (id (harness-tools-jobs-test--job-id first))
           (shared (file-name-as-directory (harness-test-temp-dir))))
      (should id)
      (should (harness-tools-jobs--running-p (gethash id harness-tools-jobs--jobs)))
      (unwind-protect
          (progn
            ;; Each read-only directory change is a different sandbox.
            (harness-call 'access/add-read-dir sid shared)
            (harness-emit 'access/changed sid)
            (harness-test-wait
             (lambda () (>= (or (plist-get (gethash id harness-tools-jobs--jobs) :restarts) 0) 1))
             30 "the first restart")
            (harness-call 'access/remove-read-dir sid shared)
            (harness-emit 'access/changed sid)
            (harness-test-wait
             (lambda () (>= (or (plist-get (gethash id harness-tools-jobs--jobs) :restarts) 0) 2))
             30 "the second restart")
            ;; One change more than the cap: the job stops.
            (harness-call 'access/add-read-dir sid shared)
            (harness-emit 'access/changed sid)
            (harness-test-wait
             (lambda ()
               (let ((entry (car (harness-tools-jobs-session-entries sid))))
                 (and entry (eq 'stopped (plist-get entry :state)))))
             30 "the job stopped at the restart cap")
            (let ((entry (car (harness-tools-jobs-session-entries sid))))
              (should (eq 'stopped (plist-get entry :state)))
              (should (string-search "not restarted again" (or (plist-get entry :reason) "")))))
        (harness-tools-jobs--stop-all sid "the test is done")
        (ignore-errors (delete-directory shared t))))))

;;;; The lifecycle evidence

(defun harness-tools-jobs-test--evidence (sid &optional id)
  "Return the recorded lifecycle of SID's jobs, or of job ID."
  (harness-tools-jobs-evidence sid id))

(defun harness-tools-jobs-test--event (records event &optional path)
  "Return the first of RECORDS whose `:event' is EVENT and `:path' PATH."
  (cl-find-if (lambda (record)
                (and (equal event (plist-get record :event))
                     (or (null path) (equal path (plist-get record :path)))))
              records))

(defmacro harness-tools-jobs-test-with-record (&rest body)
  "Run BODY with a job record and a session to write its lifecycle under.
`sid' is the session, `job' the record, and `dir' a fresh directory it
runs in.  Nothing is spawned: these tests drive the module's own record
functions, which is what a sentinel, a shared run's end and a stop call."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-tools-jobs-test--setup)
     (let* ((dir (harness-test-temp-dir))
            (sid (plist-get (harness-call 'session/create :cwd dir) :id))
            (job (harness-tools-jobs--new-job
                  :id "job-evidence" :session sid :command "echo secret-command-body"
                  :cwd dir :seconds 60 :state 'running :started (float-time)
                  :deadline (+ (float-time) 60)
                  :log (expand-file-name "job-evidence.log" dir))))
       (unwind-protect (progn ,@body)
         (ignore-errors (harness-call 'session/delete sid))
         (ignore-errors (delete-directory dir t))))))

(ert-deftest harness-jobs-evidence-records-a-start-with-the-run-and-sandbox ()
  "A job that starts records the ids that put it, its session and its run together.
The record names the job, its session, the sandbox run it is in and the
runtime instance, and nothing of what the job runs: no command, no output."
  (harness-tools-jobs-test-with-record
    (let ((run (harness-sandbox-session--new-run
                (list :id "job-evidence" :token "r-abc123" :session sid
                      :command "echo secret-command-body" :state 'running
                      :started (float-time) :seconds 60))))
      (setf (plist-get job :run) run
            (plist-get job :shared) t)
      (harness-tools-jobs--evidence-running job)
      (let* ((records (harness-tools-jobs-test--evidence sid "job-evidence"))
             (start (harness-tools-jobs-test--event records "start")))
        (should (= 1 (length records)))
        (should (equal "job-evidence" (plist-get start :job)))
        (should (equal sid (plist-get start :session)))
        (should (equal "r-abc123" (plist-get start :run)))
        (should (equal "running" (plist-get start :state)))
        (should (equal (plist-get job :log) (plist-get start :log)))
        (should (numberp (plist-get start :at)))
        ;; Nothing of the command, and no output, is in the record.
        (let ((text (harness-read-file (harness-tools-jobs--evidence-path))))
          (should-not (string-search "secret-command-body" text))
          (should-not (string-search "echo " text)))))))

(ert-deftest harness-jobs-evidence-says-which-path-stopped-a-job ()
  "A stop records the path that asked for it, and the end says so.
The tool's stop, the deadline, the access view, a task and the shutdown
are different paths, and a later reading has to tell them apart: that
is what the debug line it replaces could not do."
  (harness-tools-jobs-test-with-record
    (let ((run (harness-sandbox-session--new-run
                (list :id "job-evidence" :token "r-stop" :session sid
                      :state 'running :started (float-time) :seconds 60))))
      (setf (plist-get job :run) run
            (plist-get job :shared) t)
      (harness-tools-jobs--evidence-running job)
      (harness-tools-jobs--stop job "stopped by its session" "stop")
      ;; The run ends where the sandbox's own poll ends it, and the job's
      ;; `:done' is what records that end.
      (harness-sandbox-session--end-run run 'stopped 143 "stopped by its session")
      (funcall (harness-tools-jobs--shared-done job) run)
      (let* ((records (harness-tools-jobs-test--evidence sid "job-evidence"))
             (stop (harness-tools-jobs-test--event records "stop"))
             (end (harness-tools-jobs-test--event records "end")))
        (should (equal '("start" "stop" "end")
                       (mapcar (lambda (r) (plist-get r :event)) records)))
        (should (equal "stop" (plist-get stop :path)))
        (should (equal "stopped by its session" (plist-get stop :reason)))
        (should (equal "harness-stop" (plist-get end :teardown)))
        (should (equal "stop" (plist-get end :path)))
        (should (equal "stopped" (plist-get end :state)))))))

(ert-deftest harness-jobs-evidence-names-an-end-no-stop-request-explains ()
  "A job killed by a signal nothing in the harness sent reads as unexplained.
This is the shape the two hung jobs had: exit 143 -- TERM -- with no
reason and nothing saying who asked.  The record keeps the status and
names the signal, and says no stop request was made rather than blaming
a path that never ran."
  (harness-tools-jobs-test-with-record
    (harness-tools-jobs--evidence-running job)
    (setf (plist-get job :exit) 143
          (plist-get job :state) 'failed)
    (harness-tools-jobs--evidence-end job 'failed 143)
    (let* ((records (harness-tools-jobs-test--evidence sid "job-evidence"))
           (end (harness-tools-jobs-test--event records "end")))
      (should (equal "failed" (plist-get end :state)))
      (should (= 143 (plist-get end :exit)))
      (should (equal "TERM" (plist-get end :signal)))
      (should-not (plist-get end :path))
      (should (equal "unexplained" (plist-get end :teardown)))))
  ;; A command that ends by itself is not unexplained: it exited.
  (harness-tools-jobs-test-with-record
    (harness-tools-jobs--evidence-running job)
    (harness-tools-jobs--evidence-end job 'exited 0)
    (let ((end (harness-tools-jobs-test--event (harness-tools-jobs-test--evidence sid)
                                               "end")))
      (should (equal "exit" (plist-get end :teardown)))
      (should (= 0 (plist-get end :exit)))
      (should-not (plist-get end :signal)))))

(ert-deftest harness-jobs-evidence-records-an-end-once-per-run ()
  "A run's end is written once, however many paths report it.
The sentinel, the shared run's `:done' and a stop all see the end of a
job; one end in the record is what keeps a reading of it honest."
  (harness-tools-jobs-test-with-record
    (harness-tools-jobs--evidence-running job)
    (harness-tools-jobs--evidence-end job 'failed 143)
    (harness-tools-jobs--evidence-end job 'stopped 143)
    (harness-tools-jobs--evidence-end job 'exited 0)
    (should (= 1 (length (cl-remove-if-not (lambda (r) (equal "end" (plist-get r :event)))
                                           (harness-tools-jobs-test--evidence sid)))))
    ;; A restart is a new run, and its own end.
    (harness-tools-jobs--evidence-running job)
    (harness-tools-jobs--evidence-end job 'exited 0)
    (should (= 2 (length (cl-remove-if-not (lambda (r) (equal "end" (plist-get r :event)))
                                           (harness-tools-jobs-test--evidence sid)))))))

(ert-deftest harness-jobs-evidence-is-bounded ()
  "The lifecycle file is cut from the front, at a line, to its limit.
A harness that runs for months keeps a bounded record rather than every
job it ever ran, and what is left is whole records."
  (harness-tools-jobs-test-with-record
    (let ((harness-tools-jobs-evidence-limit 1200)
          (records 40))
      (harness-tools-jobs--evidence-running job)
      (dotimes (n records)
        (harness-tools-jobs--evidence-write job "end" :state "exited" :exit 0 :nth n))
      (let* ((path (harness-tools-jobs--evidence-path))
             (text (harness-read-file path))
             (lines (split-string text "\n" t)))
        (should (<= (length (encode-coding-string text 'utf-8-unix))
                    harness-tools-jobs-evidence-limit))
        (should (< (length lines) (1+ records)))
        ;; Every line left is a whole record.
        (dolist (line lines)
          (should (plist-get (harness-json-parse line) :event)))
        ;; The newest end is the one kept.
        (should (= (1- records)
                   (plist-get (harness-json-parse (car (last lines))) :nth)))))))

(ert-deftest harness-jobs-evidence-is-read-back-for-its-own-session-only ()
  "The evidence is read per session, and one session cannot read another's.
It is the same rule as the job list: a job belongs to the session that
started it, and so does the record of how it ended."
  (harness-tools-jobs-test-with-record
    (harness-tools-jobs--evidence-running job)
    (harness-tools-jobs--evidence-end job 'exited 0)
    (should (= 2 (length (harness-tools-jobs-test--evidence sid))))
    (should (= 2 (length (harness-tools-jobs-test--evidence sid "job-evidence"))))
    (should-not (harness-tools-jobs-test--evidence "some-other-session"))
    (should-not (harness-tools-jobs-test--evidence sid "job-other"))
    ;; The method the access view and a client read is the same answer.
    (should (equal (harness-tools-jobs-test--evidence sid)
                   (harness-call 'sandbox/job-evidence sid)))))

(ert-deftest harness-jobs-evidence-the-tool-reads-it-back ()
  "`bash_job' action evidence returns the records, as lines.
The tool is how a model asks how a job ended after the fact; the lines
name the end and whether the harness asked for it."
  (harness-tools-jobs-test-with-record
    (harness-tools-jobs--evidence-running job)
    (harness-tools-jobs--evidence-end job 'failed 143)
    (let ((r (harness-tools-jobs-test--call sid :action "evidence" :id "job-evidence")))
      (should-not (plist-get r :is-error))
      (should (string-search "job-evidence  start" (plist-get r :content)))
      (should (string-search "end · failed · exit 143 (TERM)" (plist-get r :content)))
      (should (string-search "no recorded stop request: unexplained" (plist-get r :content)))
      (should (= 2 (plist-get (plist-get r :meta) :records))))
    ;; The whole session's, and a job that has none yet.
    (should (string-search "job-evidence"
                           (plist-get (harness-tools-jobs-test--call sid :action "evidence")
                                      :content)))
    (harness-tools-jobs--stop-all sid "the test is done")))

(ert-deftest harness-jobs-a-real-job-records-how-it-started-and-ended ()
  "A job in the real sandbox records its start and its end, with its run.
This is the end-to-end half: the record is written by the code that
starts and ends a job, not by the test calling it, and it names the
sandbox run the job was in."
  (harness-tools-jobs-test-with-jail
    (let* ((first (harness-tools-jobs-test--call sid :action "start"
                                                 :command "printf 'up\\n'; sleep 120" :timeout 120))
           (id (harness-tools-jobs-test--job-id first)))
      (should id)
      (let* ((records (harness-tools-jobs-test--evidence sid id))
             (start (harness-tools-jobs-test--event records "start")))
        (should (equal "job-" (substring (plist-get start :job) 0 4)))
        (should (plist-get start :run))
        (should (plist-get start :sandbox))
        (should (integerp (plist-get start :generation))))
      (harness-tools-jobs-test--call sid :action "stop" :id id)
      (harness-test-wait
       (lambda () (harness-tools-jobs-test--event (harness-tools-jobs-test--evidence sid id) "end"))
       15 "the job's end was recorded")
      (let* ((records (harness-tools-jobs-test--evidence sid id))
             (stop (harness-tools-jobs-test--event records "stop"))
             (end (harness-tools-jobs-test--event records "end")))
        (should (equal "stop" (plist-get stop :path)))
        (should (equal "stopped by its session" (plist-get stop :reason)))
        (should (equal "harness-stop" (plist-get end :teardown)))
        (should (equal "stop" (plist-get end :path)))
        (should (equal (plist-get (gethash id harness-tools-jobs--jobs) :log)
                       (plist-get end :log)))
        ;; The same run the start named is the one the end names.
        (should (equal (plist-get stop :run) (plist-get end :run)))))))

(ert-deftest harness-jobs-evidence-records-the-path-a-deadline-stopped-by ()
  "A job the deadline stopped records that path, not a generic stop.
The tick and the sandbox's own timeout both end a job at its time; the
record says which of them the harness asked, so the reason a later
reading sees is the one the harness gave."
  (harness-tools-jobs-test-with-record
    (let ((run (harness-sandbox-session--new-run
                (list :id "job-evidence" :token "r-timeout" :session sid
                      :state 'running :started (float-time) :seconds 2))))
      (setf (plist-get job :run) run
            (plist-get job :shared) t
            (plist-get job :deadline) (- (float-time) 1))
      (puthash (plist-get job :id) job harness-tools-jobs--jobs)
      (puthash sid (list (plist-get job :id)) harness-tools-jobs--by-session)
      (harness-tools-jobs--evidence-running job)
      (harness-tools-jobs--tick-all)
      (let* ((records (harness-tools-jobs-test--evidence sid "job-evidence"))
             (stop (harness-tools-jobs-test--event records "stop")))
        (should (equal "timeout" (plist-get stop :path)))
        (should (string-search "its timeout" (or (plist-get stop :reason) ""))))
      (harness-tools-jobs--stop-all sid "the test is done")
      (remhash (plist-get job :id) harness-tools-jobs--jobs)
      (puthash sid nil harness-tools-jobs--by-session))))

(ert-deftest harness-jobs-evidence-records-a-task-cancellation-and-a-shutdown ()
  "The task's cancel and the module's shutdown record their own paths, in order.
The stop request comes before the end, so a reading of the record can
tell that the harness asked for the teardown before anything ended."
  ;; A cancelled task.
  (harness-tools-jobs-test-with-record
    (let ((run (harness-sandbox-session--new-run
                (list :id "job-evidence" :token "r-task" :session sid
                      :state 'running :started (float-time) :seconds 60))))
      (setf (plist-get job :run) run
            (plist-get job :shared) t)
      (puthash (plist-get job :id) job harness-tools-jobs--jobs)
      (puthash sid (list (plist-get job :id)) harness-tools-jobs--by-session)
      (harness-tools-jobs--evidence-running job)
      (harness-emit 'task/cancelled (list :id "t-the-task" :session sid))
      (let* ((records (harness-tools-jobs-test--evidence sid "job-evidence"))
             (stop (harness-tools-jobs-test--event records "stop")))
        (should (equal "task-cancelled" (plist-get stop :path)))
        (should (equal "its task was cancelled" (plist-get stop :reason))))
      (remhash (plist-get job :id) harness-tools-jobs--jobs)
      (puthash sid nil harness-tools-jobs--by-session)))
  ;; The shutdown, which stops every running job and says so.
  (harness-tools-jobs-test-with-record
    (let ((run (harness-sandbox-session--new-run
                (list :id "job-evidence" :token "r-shutdown" :session sid
                      :state 'running :started (float-time) :seconds 60))))
      (setf (plist-get job :run) run
            (plist-get job :shared) t)
      (puthash (plist-get job :id) job harness-tools-jobs--jobs)
      (puthash sid (list (plist-get job :id)) harness-tools-jobs--by-session)
      (harness-tools-jobs--evidence-running job)
      (harness-tools-jobs--shutdown)
      (let* ((records (harness-tools-jobs-test--evidence sid "job-evidence"))
             (stop (harness-tools-jobs-test--event records "stop")))
        (should (equal "shutdown" (plist-get stop :path)))
        (should (equal "the harness is shutting down" (plist-get stop :reason))))
      (harness-tools-jobs--init)
      (remhash (plist-get job :id) harness-tools-jobs--jobs)
      (puthash sid nil harness-tools-jobs--by-session))))

(ert-deftest harness-jobs-evidence-records-a-process-that-exits-by-itself ()
  "A job whose own process exits records an exit, not a stop.
Nothing asked it to end: the record says the command exited, with the
status it exited with."
  (harness-tools-jobs-test-with-record
    (let ((proc (make-process :name "harness-job-evidence-test"
                              :command '("sh" "-c" "sleep 0.3; exit 7")
                              :connection-type 'pipe :noquery t
                              :buffer (generate-new-buffer " *job evidence test*" t))))
      (unwind-protect
          (progn
            (setf (plist-get job :process) proc
                  (plist-get job :started) (float-time))
            (harness-tools-jobs--evidence-running job)
            (harness-test-wait (lambda () (not (process-live-p proc))) 10 "the process exited")
            (funcall (harness-tools-jobs--sentinel job) proc "exited\n")
            (let* ((records (harness-tools-jobs-test--evidence sid "job-evidence"))
                   (start (harness-tools-jobs-test--event records "start"))
                   (end (harness-tools-jobs-test--event records "end")))
              ;; The run of a job of its own is named by its process.
              (should (string-prefix-p "pid-" (plist-get start :run)))
              (should (= 7 (plist-get end :exit)))
              (should (equal "failed" (plist-get end :state)))
              (should (equal "unexplained" (plist-get end :teardown)))
              (should-not (plist-get end :signal))))
        (when (process-live-p proc) (delete-process proc))
        (when (buffer-live-p (plist-get job :buffer)) (kill-buffer (plist-get job :buffer)))
        (when (buffer-live-p (get-buffer " *job evidence test*"))
          (kill-buffer " *job evidence test*"))))))

(ert-deftest harness-jobs-evidence-records-a-session-that-ends ()
  "A session deleted or deactivated stops its jobs by its own path.
The jobs are forgotten with the session, so the record is the only
thing left saying the session's end, and not a signal, stopped them."
  (harness-tools-jobs-test-with-record
    (let ((run (harness-sandbox-session--new-run
                (list :id "job-evidence" :token "r-session" :session sid
                      :state 'running :started (float-time) :seconds 60))))
      (setf (plist-get job :run) run
            (plist-get job :shared) t)
      (puthash (plist-get job :id) job harness-tools-jobs--jobs)
      (puthash sid (list (plist-get job :id)) harness-tools-jobs--by-session)
      (harness-tools-jobs--evidence-running job)
      ;; The module's own wiring, as its init does it.
      (harness-tools-jobs--init)
      (harness-emit 'session/deleted sid)
      (let* ((records (harness-tools-jobs-test--evidence sid "job-evidence"))
             (stop (harness-tools-jobs-test--event records "stop")))
        (should (equal "session-ended" (plist-get stop :path)))
        (should (equal "its session ended" (plist-get stop :reason)))
        ;; Forgotten with the session: nothing of it is left to list.
        (should-not (harness-tools-jobs--job (plist-get job :id))))
      (harness-tools-jobs--shutdown)
      (remhash (plist-get job :id) harness-tools-jobs--jobs)
      (puthash sid nil harness-tools-jobs--by-session))))

(provide 'harness-tools-jobs-test)
;;; harness-tools-jobs-test.el ends here