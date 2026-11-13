;;; jobs-demo.el --- Show a job across separate tool calls  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; Plays the workflow `docs/design/tool-call-persistent-jobs.md' is
;; about, in this checkout, with the real bwrap: one session, and each
;; step below a separate `tools/execute' call with its own permission
;; decision and its own transcript entry.
;;
;;   scripts/jobs-demo.sh
;;
;; It needs `bwrap' and `python3', and it says so and stops where bwrap
;; cannot start.  Everything it makes is in a throwaway state directory
;; and a throwaway working directory, and it deletes both.

;;; Code:

(require 'harness-test-helpers)

(defvar jobs-demo--session nil
  "The demo session: one session, many calls.")

(defvar jobs-demo--job nil
  "The id of the job call 1 started.")

(defvar jobs-demo--port nil
  "The port the job listens on, picked so that it is unlikely to be taken.")

(defun jobs-demo--say (format &rest args)
  "Print a line made from FORMAT and ARGS, as a transcript would show it."
  (princ (apply #'format format args))
  (princ "\n"))

(defun jobs-demo--tool (name &rest input)
  "Run tool NAME with INPUT as a call of its own in the demo session."
  (harness-test-await
   (harness-call 'tools/execute jobs-demo--session
                 (list :id (harness-short-id) :name name :input input))
   120))

(defun jobs-demo--text (name &rest input)
  "Run tool NAME with INPUT and return what it said, trimmed."
  (string-trim (or (plist-get (apply #'jobs-demo--tool name input) :content) "")))

(defun jobs-demo--stop-that-job (id)
  "Stop job ID, which the last step started only to read its own output."
  (when (and id (stringp id))
    (ignore-errors (jobs-demo--tool "bash_job" :action "stop" :id id))))

(defun jobs-demo--serve (path)
  "Return what a bash call gets from the job's server at PATH."
  (jobs-demo--text "bash" :command
                   (format "curl -fsS --max-time 5 http://127.0.0.1:%d/%s"
                           jobs-demo--port path)))

(defun jobs-demo--dead ()
  "Non-nil once nothing answers on the job's port any more."
  (string-search "no server any more"
                 (jobs-demo--text
                  "bash" :command
                  (format (concat "curl -fsS --max-time 3 "
                                  "http://127.0.0.1:%d/served.txt 2>/dev/null "
                                  "|| echo 'no server any more'")
                          jobs-demo--port))))

(defun jobs-demo--steps (root)
  "Play the steps in ROOT, a throwaway working directory."
  (jobs-demo--say "\n== Call 1: start a server as a job of the session ==")
  (let* ((result (jobs-demo--tool
                  "bash_job" :action "start" :timeout 120
                  :command (format (concat "printf 'written-in-call-1\\n' > served.txt\n"
                                           "exec python3 -m http.server %d --bind 127.0.0.1")
                                   jobs-demo--port)))
         (id (plist-get (plist-get result :meta) :job)))
    (setq jobs-demo--job id)
    (jobs-demo--say "%s" (string-trim (or (plist-get result :content) "")))
    (unless id (error "The job did not start")))

  (jobs-demo--say "\n== Call 2: a separate bash call reaches it ==")
  (harness-test-wait
   (lambda () (string-search "written-in-call-1" (jobs-demo--serve "served.txt")))
   20 "the job's server answers call 2")
  (jobs-demo--say "call 2 got: %s" (jobs-demo--serve "served.txt"))

  (jobs-demo--say "\n== Call 3: another bash call, another sandbox, still reachable ==")
  (jobs-demo--say "call 3 got: %s"
                  (jobs-demo--text "bash" :command
                                   (format (concat "curl -fsS --max-time 5 "
                                                   "http://127.0.0.1:%d/ | head -1\n"
                                                   "ls -l served.txt | tr -s ' ' "
                                                   "| cut -d' ' -f5,9")
                                           jobs-demo--port)))
  (jobs-demo--say "\n%s" (jobs-demo--text "bash_job" :action "list"))

  (jobs-demo--say "\n== Call 4: the job writes a file the file tools see ==")
  (jobs-demo--say "%s"
                  (with-temp-buffer
                    (insert-file-contents (expand-file-name "served.txt" root))
                    (string-trim (buffer-string))))

  (jobs-demo--say "\n== Call 5: stop, and the file stays ==")
  (jobs-demo--say "%s" (jobs-demo--text "bash_job" :action "stop" :id jobs-demo--job))
  (harness-test-wait #'jobs-demo--dead 15 "the port is dead")
  (jobs-demo--say "call 6 got: %s" (jobs-demo--text "bash" :command
                                                    (format (concat "curl -fsS --max-time 3 "
                                                                    "http://127.0.0.1:%d/served.txt "
                                                                    "2>/dev/null "
                                                                    "|| echo 'no server any more'")
                                                            jobs-demo--port)))
  (jobs-demo--say "served.txt still there: %s"
                  (file-exists-p (expand-file-name "served.txt" root)))

  (jobs-demo--say "\n== Confinement, on a call that runs now ==")
  (jobs-demo--say "%s"
                  (jobs-demo--text "bash" :command "printf 'pid-1: '; cat /proc/1/comm"))

  (jobs-demo--say "\n== What a job cannot reach, in its own output ==")
  (let* ((outside (file-name-as-directory (harness-test-temp-dir)))
         (secret (expand-file-name "secret.txt" outside))
         (marker (format "job-secret-%s" (harness-short-id 8)))
         (id nil))
    (unwind-protect
        (progn
          (with-temp-file secret (insert marker "\n"))
          (setq id (plist-get
                    (plist-get (jobs-demo--tool
                                "bash_job" :action "start" :timeout 60
                                :command (format (concat "printf 'pid-1: '; cat /proc/1/comm\n"
                                                         "printf 'secret outside the session: '\n"
                                                         "(grep -q %s %s && echo VISIBLE || echo hidden) 2>&1\n"
                                                         "sleep 5")
                                                 (shell-quote-argument marker)
                                                 (shell-quote-argument secret)))
                               :meta)
                    :job))
          (harness-test-wait
           (lambda ()
             (string-search "secret outside the session:"
                            (jobs-demo--text "bash_job" :action "logs" :id id :lines 40)))
           20 "the job's own check")
          (jobs-demo--say "%s"
                          (jobs-demo--text "bash_job" :action "logs" :id id :lines 40)))
      (jobs-demo--stop-that-job id)
      (ignore-errors (delete-directory outside t)))))

(defmacro jobs-demo--with-harness (&rest body)
  "Run BODY in a throwaway state with the modules a job needs started."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (module '(store project config provider session tools tools-shell
                              perms readonly access agent))
       (harness-test-load-module module))
     (harness-test-load-module 'sandbox)
     (harness-sandbox-detect)
     (harness-test-load-module 'tools-jobs)
     (harness-test-connect-ui-client)
     (harness-add-filter 'permission/decide
                         (lambda (_decision next &rest _)
                           (funcall next (list :behavior 'allow)))
                         10)
     (unwind-protect (progn ,@body)
       (ignore-errors (harness-call 'store/sqlite-close)))))

(defun jobs-demo-main ()
  "Print what each call of one session saw, with a real bwrap."
  (jobs-demo--with-harness
    (let* ((root (file-name-as-directory (harness-test-temp-dir)))
           (default-directory root))
      (setq jobs-demo--session (plist-get (harness-call 'session/create :cwd root) :id)
            jobs-demo--port (+ 24000 (% (abs (sxhash-equal (float-time))) 2000))
            jobs-demo--job nil)
      (unwind-protect
          (progn
            (jobs-demo--say "Session: %s" jobs-demo--session)
            (jobs-demo--say "Sandbox: %S" (harness-call 'sandbox/status))
            (unless (equal 'bwrap (plist-get (harness-call 'sandbox/status) :backend))
              (error "This demo needs the bwrap backend"))
            (unless (executable-find "python3")
              (error "This demo needs python3"))
            (jobs-demo--steps root))
        (ignore-errors (harness-tools-jobs--stop-all jobs-demo--session "the demo is over"))
        (ignore-errors (harness-call 'session/delete jobs-demo--session))
        (ignore-errors (delete-directory root t))))))

(provide 'jobs-demo)
;;; jobs-demo.el ends here
